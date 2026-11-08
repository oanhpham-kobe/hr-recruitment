import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { AppSession } from "@/lib/auth/session";
import {
  addInterviewParticipant,
  changeInterviewScheduleStatus,
  copyInterviewSchedule,
  createNextInterviewRound,
  reactivateApplication,
  readdInterviewParticipant,
  removeInterviewParticipant,
  reorderInterviewParticipants,
  rescheduleConfirmedInterview,
  saveInterviewSchedule,
} from "@/lib/commands/interview-lifecycle";

const ids = {
  application: "11111111-1111-4111-8111-111111111111",
  interview: "22222222-2222-4222-8222-222222222222",
  targetRound: "33333333-3333-4333-8333-333333333333",
  user: "44444444-4444-4444-8444-444444444444",
  participant: "55555555-5555-4555-8555-555555555555",
  participant2: "66666666-6666-4666-8666-666666666666",
  format: "77777777-7777-4777-8777-777777777777",
  room: "88888888-8888-4888-8888-888888888888",
  key: "99999999-9999-4999-8999-999999999999",
};

function session(permissions: string[]): AppSession {
  return {
    isAuthenticated: true,
    user: {
      authUserId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      email: "hr@eiu.edu.vn",
      isInternal: true,
      isCandidate: false,
      appUserId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      roles: ["HR"],
      permissions,
    },
  };
}

function rpcRecorder() {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const client = {
    rpc: async (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      return { data: { success: true, data: { ok: true } }, error: null };
    },
  } as unknown as SupabaseClient;
  return { client, calls };
}

test("create-next passes the caller-owned idempotency key unchanged", async () => {
  const { client, calls } = rpcRecorder();
  const result = await createNextInterviewRound(
    { applicationId: ids.application, idempotencyKey: ids.key },
    { client, resolveSession: async () => session(["interviews.manage"]) },
  );
  assert.equal(result.success, true);
  assert.deepEqual(calls, [
    {
      name: "create_next_interview_round",
      args: {
        p_application_id: ids.application,
        p_idempotency_key: ids.key,
      },
    },
  ]);
});

test("schedule wrapper uses the exact accepted named RPC surface", async () => {
  const { client, calls } = rpcRecorder();
  await saveInterviewSchedule(
    {
      interviewId: ids.interview,
      startAt: "2026-05-20T07:00:00.000Z",
      endAt: "2026-05-20T08:30:00.000Z",
      interviewFormatId: ids.format,
      roomId: ids.room,
      meetingLink: null,
      demoTopic: "Demo",
      interviewNote: "Note",
      expectedVersion: 4,
      idempotencyKey: ids.key,
    },
    { client, resolveSession: async () => session(["interviews.manage"]) },
  );
  assert.equal(calls[0]?.name, "save_interview_schedule");
  assert.deepEqual(calls[0]?.args, {
    p_interview_id: ids.interview,
    p_start_at: "2026-05-20T07:00:00.000Z",
    p_end_at: "2026-05-20T08:30:00.000Z",
    p_interview_format_id: ids.format,
    p_room_id: ids.room,
    p_meeting_link: null,
    p_demo_topic: "Demo",
    p_interview_note: "Note",
    p_expected_version: 4,
    p_idempotency_key: ids.key,
  });
});

test("copy schedule remains one atomic trusted RPC with optimistic tokens", async () => {
  const { client, calls } = rpcRecorder();
  await copyInterviewSchedule(
    {
      sourceInterviewId: ids.interview,
      targetApplicationId: ids.application,
      expectedSourceVersion: 5,
      expectedTargetApplicationVersion: 7,
      expectedTargetRoundId: ids.targetRound,
      expectedTargetRoundVersion: 3,
      startAt: null,
      endAt: null,
      interviewFormatId: null,
      roomId: null,
      meetingLink: null,
      interviewNote: "Draft note",
      participantAppUserIds: [ids.user],
      idempotencyKey: ids.key,
    },
    {
      client,
      resolveSession: async () =>
        session(["interviews.manage", "interviews.view"]),
    },
  );
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.name, "copy_interview_schedule");
  assert.equal(calls[0]?.args.p_expected_source_version, 5);
  assert.equal(calls[0]?.args.p_expected_target_application_version, 7);
  assert.equal(calls[0]?.args.p_expected_target_round_id, ids.targetRound);
  assert.equal(calls[0]?.args.p_expected_target_round_version, 3);
  assert.deepEqual(calls[0]?.args.p_participant_app_user_ids, [ids.user]);
  assert.equal(calls[0]?.args.p_idempotency_key, ids.key);
});

test("participant add and reorder use repaired S04-005 public signatures", async () => {
  const { client, calls } = rpcRecorder();
  const resolveSession = async () =>
    session(["interviews.view", "interviews.participants"]);
  await addInterviewParticipant(
    {
      interviewId: ids.interview,
      appUserId: ids.user,
      idempotencyKey: ids.key,
    },
    { client, resolveSession },
  );
  await reorderInterviewParticipants(
    {
      interviewId: ids.interview,
      participantIds: [ids.participant, ids.participant2],
      expectedVersions: [2, 3],
    },
    { client, resolveSession },
  );
  assert.deepEqual(calls[0], {
    name: "add_interview_participant",
    args: {
      p_interview_id: ids.interview,
      p_app_user_id: ids.user,
      p_idempotency_key: ids.key,
    },
  });
  assert.deepEqual(calls[1], {
    name: "reorder_interview_participants",
    args: {
      p_interview_id: ids.interview,
      p_ordered_participant_ids: [ids.participant, ids.participant2],
      p_expected_versions: [2, 3],
    },
  });
});

test("Application Reactivate is permission-bound and distinct from Interview lifecycle", async () => {
  const { client, calls } = rpcRecorder();
  const denied = await reactivateApplication(
    { applicationId: ids.application, expectedVersion: 6 },
    { client, resolveSession: async () => session(["interviews.manage"]) },
  );
  assert.equal(denied.success, false);
  assert.equal(calls.length, 0);

  const allowed = await reactivateApplication(
    { applicationId: ids.application, expectedVersion: 6 },
    { client, resolveSession: async () => session(["applications.manage"]) },
  );
  assert.equal(allowed.success, true);
  assert.deepEqual(calls[0], {
    name: "reactivate_application",
    args: {
      p_application_id: ids.application,
      p_expected_version: 6,
    },
  });
});

test("same intended retry keeps the same caller-owned key for create-next and Save Copy", async () => {
  const { client, calls } = rpcRecorder();
  const manage = async () => session(["interviews.manage", "interviews.view"]);
  const createInput = {
    applicationId: ids.application,
    idempotencyKey: ids.key,
  };
  await createNextInterviewRound(createInput, {
    client,
    resolveSession: manage,
  });
  await createNextInterviewRound(createInput, {
    client,
    resolveSession: manage,
  });
  assert.equal(calls[0]?.args.p_idempotency_key, ids.key);
  assert.equal(calls[1]?.args.p_idempotency_key, ids.key);

  const copyInput = {
    sourceInterviewId: ids.interview,
    targetApplicationId: ids.application,
    expectedSourceVersion: 5,
    expectedTargetApplicationVersion: 7,
    expectedTargetRoundId: ids.targetRound,
    expectedTargetRoundVersion: 3,
    startAt: null,
    endAt: null,
    interviewFormatId: null,
    roomId: null,
    meetingLink: null,
    interviewNote: null,
    participantAppUserIds: [ids.user],
    idempotencyKey: ids.key,
  };
  await copyInterviewSchedule(copyInput, { client, resolveSession: manage });
  await copyInterviewSchedule(copyInput, { client, resolveSession: manage });
  assert.equal(calls[2]?.args.p_idempotency_key, ids.key);
  assert.equal(calls[3]?.args.p_idempotency_key, ids.key);
});

test("remove and re-add forward the repaired S04-005 arguments exactly", async () => {
  const { client, calls } = rpcRecorder();
  const resolveSession = async () =>
    session(["interviews.view", "interviews.participants"]);
  await removeInterviewParticipant(
    { interviewParticipantId: ids.participant, expectedVersion: 8 },
    { client, resolveSession },
  );
  await readdInterviewParticipant(
    {
      interviewParticipantId: ids.participant,
      restoreMode: "RESTORE_OLD_REPORT",
      idempotencyKey: ids.key,
    },
    { client, resolveSession },
  );
  assert.deepEqual(calls[0], {
    name: "remove_interview_participant",
    args: {
      p_interview_participant_id: ids.participant,
      p_expected_version: 8,
    },
  });
  assert.deepEqual(calls[1], {
    name: "readd_interview_participant",
    args: {
      p_interview_participant_id: ids.participant,
      p_restore_mode: "RESTORE_OLD_REPORT",
      p_idempotency_key: ids.key,
    },
  });
});

test("Application Reactivate exposes stable structured owner, participant and conflict errors", async () => {
  const codes = [
    "STALE_VERSION",
    "ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED",
    "CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED",
    "SCHEDULE_CONFLICT_CANDIDATE",
    "SCHEDULE_CONFLICT_ROOM",
    "SCHEDULE_CONFLICT_INTERVIEWER",
  ];
  for (const code of codes) {
    const client = {
      rpc: async () => ({
        data: { success: false, error_code: code },
        error: null,
      }),
    } as unknown as SupabaseClient;
    const result = await reactivateApplication(
      { applicationId: ids.application, expectedVersion: 6 },
      { client, resolveSession: async () => session(["applications.manage"]) },
    );
    assert.equal(result.success, false);
    if (!result.success) {
      assert.equal(result.error.code, code);
      assert.doesNotMatch(
        result.error.message,
        /sql|postgres|function public/i,
      );
    }
  }
});

test("public server seam rejects malformed status and half-filled copy interval before RPC", async () => {
  const { client, calls } = rpcRecorder();
  const resolveSession = async () =>
    session(["interviews.view", "interviews.status", "interviews.manage"]);
  const badStatus = await changeInterviewScheduleStatus(
    { interviewId: ids.interview, status: "NOT_A_STATUS", expectedVersion: 2 },
    { client, resolveSession },
  );
  assert.equal(badStatus.success, false);
  const halfCopy = await copyInterviewSchedule(
    {
      sourceInterviewId: ids.interview,
      targetApplicationId: ids.application,
      expectedSourceVersion: 5,
      expectedTargetApplicationVersion: 7,
      expectedTargetRoundId: ids.targetRound,
      expectedTargetRoundVersion: 3,
      startAt: "2026-05-20T07:00:00.000Z",
      endAt: null,
      interviewFormatId: ids.format,
      roomId: null,
      meetingLink: null,
      interviewNote: null,
      participantAppUserIds: [ids.user],
      idempotencyKey: ids.key,
    },
    { client, resolveSession },
  );
  assert.equal(halfCopy.success, false);
  assert.equal(calls.length, 0);
});

test("confirmed reschedule rejects non-UUID format identifiers before RPC", async () => {
  const { client, calls } = rpcRecorder();
  const result = await rescheduleConfirmedInterview(
    {
      interviewId: ids.interview,
      startAt: "2026-05-20T07:00:00.000Z",
      endAt: "2026-05-20T08:30:00.000Z",
      interviewFormatId: "not-a-uuid",
      roomId: null,
      meetingLink: null,
      expectedVersion: 2,
      idempotencyKey: ids.key,
    },
    { client, resolveSession: async () => session(["interviews.manage"]) },
  );
  assert.equal(result.success, false);
  assert.equal(calls.length, 0);
});
