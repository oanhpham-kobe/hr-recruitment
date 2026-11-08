import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { AppSession } from "@/lib/auth/session";
import {
  createFeedbackCollection,
  loadFeedbackInvitation,
  loadFeedbackWorkspace,
  publishFeedbackTemplate,
  revokeFeedbackInvitation,
  saveFeedbackConsolidation,
  saveFeedbackResponse,
} from "@/lib/interview-feedback/server";

const id = "10100000-0000-4000-8000-000000000001";
const internal = (permissions: string[] = []): AppSession => ({
  isAuthenticated: true,
  user: {
    authUserId: id,
    email: "trial@eiu.edu.vn",
    isInternal: true,
    isCandidate: false,
    roles: [],
    permissions,
  },
});
const manager = internal(["interviews.manage", "reports.view"]);
const workspace = {
  can_manage: true,
  templates: [],
  interviews: [],
  collections: [],
  invitations: [],
};
const invitation = {
  invitation_id: id,
  participant_id: id,
  evaluator_name: "Evaluator",
  state: "DRAFT",
  answers: {},
  version_no: 2,
  submitted_at: null,
  available: true,
  delivery_state: "PROVIDER_PAUSED",
};
function deps(
  session: AppSession,
  payload: unknown = { success: true, data: workspace },
  transportError: unknown = null,
) {
  const calls: { name: string; args: unknown }[] = [];
  const client = {
    rpc: async (name: string, args: unknown) => {
      calls.push({ name, args });
      return { data: payload, error: transportError };
    },
  } as unknown as SupabaseClient;
  return { client, resolveSession: async () => session, calls };
}
test("Feedback adapter rejects anonymous/candidate callers before RPC and requires both HR permissions", async () => {
  for (const session of [
    { isAuthenticated: false, user: null } as AppSession,
    {
      isAuthenticated: true,
      user: {
        authUserId: id,
        email: "candidate@example.org",
        roles: [],
        permissions: [],
        isInternal: false,
        isCandidate: true,
      },
    },
    internal(["interviews.manage"]),
    internal(["reports.view"]),
  ]) {
    const d = deps(session);
    const r = await publishFeedbackTemplate(
      {
        name: "Trial",
        questions: [{ key: "other_comment", label: "Other", required: false }],
        previousTemplateId: null,
        idempotencyKey: id,
      },
      d,
    );
    assert.equal(r.success, false);
    assert.equal(d.calls.length, 0);
  }
});
test("Feedback workspace accepts authenticated own access; malformed successful payloads fail safely", async () => {
  const d = deps(internal());
  assert.deepEqual(await loadFeedbackWorkspace(50, d), {
    success: true,
    data: workspace,
  });
  assert.deepEqual(d.calls[0], {
    name: "get_interview_feedback_workspace",
    args: { p_limit: 50, p_offset: 50 },
  });
  for (const data of [
    {},
    { ...workspace, invitations: [{ invitation_id: id }] },
    { ...workspace, can_manage: "yes" },
  ]) {
    assert.deepEqual(
      await loadFeedbackWorkspace(0, deps(manager, { success: true, data })),
      { success: false, error: { code: "INVALID_RESPONSE" } },
    );
  }
});
test("Feedback adapter strips raw transport errors and arbitrary RPC messages", async () => {
  const secret = "https://private.invalid/document?token=secret";
  assert.deepEqual(
    await loadFeedbackWorkspace(0, deps(manager, null, { message: secret })),
    { success: false, error: { code: "COMMAND_FAILED" } },
  );
  assert.deepEqual(
    await loadFeedbackWorkspace(
      0,
      deps(manager, {
        success: false,
        error_code: "STALE_VERSION",
        message: secret,
      }),
    ),
    { success: false, error: { code: "STALE_VERSION" } },
  );
});
test("Publish validates bounded plain questions before forwarding immutable version and retry key", async () => {
  const input = {
    name: "Trial",
    questions: [{ key: "knowledge", label: "Knowledge", required: false }],
    previousTemplateId: null,
    idempotencyKey: id,
  };
  const d = deps(manager, {
    success: true,
    data: {
      template_id: id,
      family_id: id,
      version_no: 1,
      name: "Trial",
      questions: input.questions,
      published_at: "2026-11-05T00:00:00Z",
    },
  });
  assert.equal((await publishFeedbackTemplate(input, d)).success, true);
  assert.deepEqual(d.calls[0].args, {
    p_name: "Trial",
    p_questions: input.questions,
    p_previous_template_id: null,
    p_idempotency_key: id,
  });
  for (const questions of [
    [],
    [...input.questions, ...input.questions],
    [{ key: "bad key", label: "a", required: false }],
    [{ key: "valid", label: "a", required: false, html: "<script>" }],
  ]) {
    const invalid = deps(manager);
    assert.equal(
      (await publishFeedbackTemplate({ ...input, questions }, invalid)).success,
      false,
    );
    assert.equal(invalid.calls.length, 0);
  }
});
test("Create adapter forwards exact interview, participant identities, nullable deadline and idempotency key", async () => {
  const c = {
    collection_id: id,
    interview_id: id,
    template_id: id,
    deadline_at: null,
    created_at: "2026-11-05T00:00:00Z",
  };
  const d = deps(manager, { success: true, data: c });
  assert.equal(
    (
      await createFeedbackCollection(
        {
          interviewId: id,
          templateId: id,
          participantIds: [id],
          deadlineAt: null,
          idempotencyKey: id,
        },
        d,
      )
    ).success,
    true,
  );
  assert.deepEqual(d.calls[0].args, {
    p_interview_id: id,
    p_template_id: id,
    p_participant_ids: [id],
    p_deadline_at: null,
    p_idempotency_key: id,
  });
  const invalid = deps(manager);
  assert.equal(
    (
      await createFeedbackCollection(
        {
          interviewId: id,
          templateId: id,
          participantIds: [id, id],
          deadlineAt: null,
          idempotencyKey: id,
        },
        invalid,
      )
    ).success,
    false,
  );
  assert.equal(invalid.calls.length, 0);
});
test("Response adapter forwards optimistic version and submit flag, preserves RPC conflict without fabricating success", async () => {
  const d = deps(internal(), { success: true, data: invitation });
  const input = {
    invitationId: id,
    answers: { other_comment: "<script>plain text</script>" },
    expectedVersionNo: 1,
    submit: false,
  };
  assert.equal((await saveFeedbackResponse(input, d)).success, true);
  assert.deepEqual(d.calls[0].args, {
    p_invitation_id: id,
    p_answers: input.answers,
    p_expected_version_no: 1,
    p_submit: false,
  });
  assert.deepEqual(
    await saveFeedbackResponse(
      input,
      deps(internal(), { success: false, error_code: "STALE_VERSION" }),
    ),
    { success: false, error: { code: "STALE_VERSION" } },
  );
  const invalid = deps(internal());
  assert.equal(
    (
      await saveFeedbackResponse(
        { ...input, answers: { other_comment: "x".repeat(10001) } },
        invalid,
      )
    ).success,
    false,
  );
  assert.equal(invalid.calls.length, 0);
});
test("Own invitation read rejects malformed HR-shaped data and invalid identifiers", async () => {
  assert.equal(
    (
      await loadFeedbackInvitation(
        id,
        deps(internal(), { success: true, data: { mode: "HR" } }),
      )
    ).success,
    false,
  );
  const d = deps(internal());
  assert.equal((await loadFeedbackInvitation("../other", d)).success, false);
  assert.equal(d.calls.length, 0);
});
test("Revocation requires HR permissions and forwards expected version", async () => {
  const d = deps(manager, {
    success: true,
    data: { ...invitation, state: "REVOKED" },
  });
  assert.equal(
    (
      await revokeFeedbackInvitation(
        { invitationId: id, expectedVersionNo: 2 },
        d,
      )
    ).success,
    true,
  );
  assert.deepEqual(d.calls[0].args, {
    p_invitation_id: id,
    p_expected_version_no: 2,
  });
  const own = deps(internal());
  assert.equal(
    (
      await revokeFeedbackInvitation(
        { invitationId: id, expectedVersionNo: 2 },
        own,
      )
    ).success,
    false,
  );
  assert.equal(own.calls.length, 0);
});
test("Consolidation cannot approve expected version zero and maps backend completeness rejection", async () => {
  const input = {
    collectionId: id,
    title: "Report",
    overallSummary: "Summary",
    expectedVersionNo: 0,
    approve: true,
  };
  const d = deps(manager);
  assert.equal((await saveFeedbackConsolidation(input, d)).success, false);
  assert.equal(d.calls.length, 0);
  const blocked = deps(manager, {
    success: false,
    error_code: "COMPLETENESS_REQUIRED",
  });
  assert.deepEqual(
    await saveFeedbackConsolidation({ ...input, approve: false }, blocked),
    { success: false, error: { code: "COMPLETENESS_REQUIRED" } },
  );
  assert.deepEqual(blocked.calls[0].args, {
    p_collection_id: id,
    p_title: "Report",
    p_overall_summary: "Summary",
    p_expected_version_no: 0,
    p_approve: false,
  });
});
