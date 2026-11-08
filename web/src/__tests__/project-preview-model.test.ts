import assert from "node:assert/strict";
import test from "node:test";
import {
  deleteOrInactivateMasterItemAction,
  revokeHrPermissionAction,
  setInternalUserActiveAction,
} from "./fixtures/project-preview/admin-actions";
import { previewApi } from "./fixtures/project-preview/feedback";
import {
  createApplicationAction,
  openSubmissionAction,
} from "./fixtures/project-preview/inbox-actions";
import {
  addInterviewParticipantAction,
  changeInterviewStatusAction,
  createNextRoundAction,
  deleteOrInactivateApplicationAction,
  deleteOrInactivateInterviewAction,
  interviewData,
  reactivateApplicationAction,
  saveInterviewScheduleAction,
} from "./fixtures/project-preview/interview-actions";
import {
  bulkReportStatus,
  hrData,
  reportMutation,
  saveReport,
} from "./fixtures/project-preview/reports";
import {
  id,
  PEOPLE,
  read,
  reset,
  save,
} from "./fixtures/project-preview/store";

const assignment = (submissionId = id(10)) => ({
  submissionId,
  unitId: id(100),
  departmentTeamId: id(101),
  positionId: id(102),
  hrOwnerId: id(2),
});
function persona(value: Parameters<typeof previewApi>[0]) {
  const s = read();
  s.persona = value;
  save(s);
}
async function assigned() {
  const result = await createApplicationAction(assignment());
  assert.equal(result.success, true);
  return read().applications[0].rounds[0];
}
test("Synthetic shared model preserves exact assignments, rejects conflicts atomically and derives current outcomes", async () => {
  reset();
  await openSubmissionAction(id(10));
  assert.equal(read().submissions[0].status_code, "READ");
  let r = await assigned();
  assert.equal(read().submissions[0].status_code, "PROCESSED");
  await addInterviewParticipantAction({
    interviewId: r.interviewId,
    appUserId: PEOPLE.interviewerA.id,
  });
  r = read().applications[0].rounds[0];
  const schedule = {
    idempotencyKey: crypto.randomUUID(),
    interviewId: r.interviewId,
    expectedVersion: r.versionNo,
    startAt: "2027-01-01T03:00:00Z",
    endAt: "2027-01-01T04:00:00Z",
    interviewFormatId: id(105),
    roomId: id(104),
    meetingLink: null,
    demoTopic: null,
    interviewNote: null,
  };
  assert.equal((await saveInterviewScheduleAction(schedule)).success, true);
  assert.equal(
    (await createApplicationAction(assignment(id(11)))).success,
    true,
  );
  const other = read().applications[1].rounds[0];
  const before = JSON.stringify(read());
  assert.equal(
    (
      await saveInterviewScheduleAction({
        ...schedule,
        interviewId: other.interviewId,
        expectedVersion: other.versionNo,
      })
    ).success,
    false,
  );
  assert.equal(JSON.stringify(read()), before);
  const app = read().applications[0];
  await deleteOrInactivateApplicationAction(app.applicationId);
  assert.equal(
    (await createApplicationAction({ ...assignment(), confirmDuplicate: true }))
      .success,
    false,
  );
  assert.equal(read().applications.length, 2);
  assert.equal(
    (
      await reactivateApplicationAction({
        applicationId: app.applicationId,
        expectedVersion: read().applications[0].versionNo,
      })
    ).success,
    true,
  );
  assert.equal(
    (await createNextRoundAction({ applicationId: app.applicationId })).success,
    true,
  );
  assert.equal(
    (
      await deleteOrInactivateInterviewAction({
        interviewId: r.interviewId,
        expectedVersion: read().applications[0].rounds[0].versionNo,
      })
    ).success,
    false,
  );
});
test("Synthetic questionnaire uses assigned production round, preserves own draft and blocks writes after round advances", async () => {
  reset();
  const r = await assigned();
  await addInterviewParticipantAction({
    interviewId: r.interviewId,
    appUserId: PEOPLE.interviewerA.id,
  });
  const participant = read().applications[0].rounds[0].participants[0];
  const api = previewApi("hr");
  const created = await api.create({
    interviewId: r.interviewId,
    templateId: id(200),
    participantIds: [participant.interviewParticipantId],
    deadlineAt: null,
    idempotencyKey: crypto.randomUUID(),
  });
  assert.equal(created.success, true);
  persona("interviewerA");
  const own = previewApi("interviewerA");
  const invitation = read().feedback.invitations[0];
  assert.equal(
    (
      await own.respond({
        invitationId: invitation.invitation_id,
        answers: { other_comment: "Saved local draft" },
        expectedVersionNo: invitation.version_no,
        submit: false,
      })
    ).success,
    true,
  );
  assert.equal(
    read().feedback.invitations[0].answers.other_comment,
    "Saved local draft",
  );
  assert.equal(
    (await previewApi("interviewerB").invitation(invitation.invitation_id))
      .success,
    false,
  );
  persona("hr");
  await createNextRoundAction({
    applicationId: read().applications[0].applicationId,
  });
  persona("interviewerA");
  const before = read().feedback.invitations[0];
  assert.equal(
    (
      await own.respond({
        invitationId: before.invitation_id,
        answers: { other_comment: "not accepted" },
        expectedVersionNo: before.version_no,
        submit: true,
      })
    ).success,
    false,
  );
  assert.equal(
    read().feedback.invitations[0].answers.other_comment,
    "Saved local draft",
  );
});
test("Synthetic reports preserve decision source on evaluation edit and allow authorized HR correction after final status", async () => {
  reset();
  const r = await assigned();
  await addInterviewParticipantAction({
    interviewId: r.interviewId,
    appUserId: PEOPLE.interviewerA.id,
  });
  const participant = read().applications[0].rounds[0].participants[0];
  persona("interviewerA");
  assert.equal(
    (
      await saveReport({
        interviewParticipantId: participant.interviewParticipantId,
        expectedVersionNo: 0,
        patches: { conclusion: "Suitable" },
        baseValues: { conclusion: null },
      })
    ).success,
    true,
  );
  const decisionAt = read().reports[0].decisionAt;
  persona("hr");
  await reportMutation({
    interviewId: r.interviewId,
    expectedVersionNo: read().applications[0].rounds[0].versionNo,
    status: "HIRED",
  });
  assert.equal(read().submissions[0].status_code, "DONE");
  assert.equal(
    (
      await saveReport(
        {
          interviewParticipantId: participant.interviewParticipantId,
          expectedVersionNo: 1,
          patches: { other_comment: "HR correction" },
          baseValues: { other_comment: null },
        },
        true,
      )
    ).success,
    true,
  );
  assert.equal(read().reports[0].decisionAt, decisionAt);
  assert.equal(hrData().rows[0].drawer.finalDecision.conclusion, "Suitable");
});
test("Synthetic Root permissions and referenced catalogs affect later operations", async () => {
  reset();
  persona("root");
  const hr = read().users.find((u) => u.appUserId === PEOPLE.hr.id);
  assert.ok(hr);
  assert.equal(
    (
      await revokeHrPermissionAction(
        hr.appUserId,
        "interviews.manage",
        hr.versionNo,
      )
    ).success,
    true,
  );
  persona("hr");
  assert.equal(interviewData().permissions.canManage, false);
  persona("root");
  assert.equal(
    (await setInternalUserActiveAction(PEOPLE.root.id, false, 1)).success,
    false,
  );
  assert.equal(
    (await deleteOrInactivateMasterItemAction("position_groups", id(103), 1))
      .success,
    true,
  );
  assert.equal(read().catalogs.position_groups[0]?.isActive, false);
  reset();
  assert.equal(read().applications.length, 0);
});

test("Synthetic bulk report status is atomic and canonical permission revocation takes effect", async () => {
  reset();
  await assigned();
  await createApplicationAction(assignment(id(11)));
  assert.equal(hrData().permissions.manageStatus, true);
  const targets = read().applications.map((a) => ({
    interviewId: a.rounds[0].interviewId,
    expectedVersionNo: a.rounds[0].versionNo,
  }));
  const before = JSON.stringify(read());
  assert.equal(
    (
      await bulkReportStatus({
        targets: [targets[0], { ...targets[1], expectedVersionNo: 999 }],
        status: "REJECTED",
      })
    ).success,
    false,
  );
  assert.equal(JSON.stringify(read()), before);
  persona("root");
  const hr = read().users.find((u) => u.appUserId === PEOPLE.hr.id);
  assert.ok(hr);
  await revokeHrPermissionAction(
    hr.appUserId,
    "reports.manage_status",
    hr.versionNo,
  );
  persona("hr");
  assert.equal(hrData().permissions.manageStatus, false);
  assert.equal(
    (await bulkReportStatus({ targets, status: "REJECTED" })).success,
    false,
  );
});

test("Synthetic read projections close after view revocation or account inactivation", async () => {
  reset();
  await assigned();
  assert.equal(hrData().rows.length, 1);
  assert.equal(interviewData().groups.length, 1);
  persona("root");
  for (const permission of ["reports.view", "interviews.view"]) {
    const hr = read().users.find((user) => user.appUserId === PEOPLE.hr.id);
    assert.ok(hr);
    assert.equal(
      (await revokeHrPermissionAction(hr.appUserId, permission, hr.versionNo))
        .success,
      true,
    );
  }
  persona("hr");
  assert.equal(hrData().rows.length, 0);
  assert.equal(interviewData().groups.length, 0);
  assert.equal(interviewData().permissions.canView, false);
  for (const property of ["isActive", "identityBound"] as const) {
    reset();
    await assigned();
    const state = read();
    const hr = state.users.find((user) => user.appUserId === PEOPLE.hr.id);
    assert.ok(hr);
    hr[property] = false;
    save(state);
    assert.equal(hrData().rows.length, 0);
    assert.equal(interviewData().groups.length, 0);
  }
});

test("Synthetic existing rounds retain inactive format history while new selection is blocked", async () => {
  reset();
  let round = await assigned();
  const input = {
    idempotencyKey: crypto.randomUUID(),
    interviewId: round.interviewId,
    expectedVersion: round.versionNo,
    startAt: "2027-01-10T03:00:00Z",
    endAt: "2027-01-10T04:00:00Z",
    interviewFormatId: id(105),
    roomId: id(104),
    meetingLink: null,
    demoTopic: null,
    interviewNote: null,
  };
  assert.equal((await saveInterviewScheduleAction(input)).success, true);
  persona("root");
  assert.equal(
    (await deleteOrInactivateMasterItemAction("interview_formats", id(105), 1))
      .success,
    true,
  );
  assert.equal(
    read().catalogs.interview_formats.find((format) => format.id === id(105))
      ?.isActive,
    false,
  );
  persona("hr");
  round = read().applications[0].rounds[0];
  assert.equal(
    (
      await changeInterviewStatusAction({
        interviewId: round.interviewId,
        expectedVersion: round.versionNo,
        status: "SCHEDULED",
      })
    ).success,
    true,
  );
  assert.equal(
    (
      await addInterviewParticipantAction({
        interviewId: round.interviewId,
        appUserId: PEOPLE.interviewerA.id,
      })
    ).success,
    true,
  );
  assert.equal(
    (
      await createNextRoundAction({
        applicationId: read().applications[0].applicationId,
      })
    ).success,
    true,
  );
  const newest = read().applications[0].rounds.at(-1);
  assert.ok(newest);
  const rejected = await saveInterviewScheduleAction({
    ...input,
    interviewId: newest.interviewId,
    expectedVersion: newest.versionNo,
    startAt: "2027-01-10T06:00:00Z",
    endAt: "2027-01-10T07:00:00Z",
    idempotencyKey: crypto.randomUUID(),
  });
  assert.equal(rejected.success, false);
  if (!rejected.success)
    assert.equal(rejected.error.code, "INACTIVE_FORMAT_NOT_SELECTABLE");
  assert.equal(read().applications[0].rounds.at(-1)?.interviewFormatId, null);
});
