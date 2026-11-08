import assert from "node:assert/strict";
import test from "node:test";
import {
  changedReportFields,
  EMPTY_REPORT_FIELDS,
  groupInterviewerReportRounds,
  parseInterviewerReportPageRpc,
  projectInterviewerReportStatus,
  type RawReportStatus,
  safeMeetingHref,
} from "@/lib/reports/model";

test("Interviewer status projection masks HR-only decision stages", () => {
  const expected: Record<RawReportStatus, string> = {
    INTERVIEW_SCHEDULING: "INTERVIEW_SCHEDULING",
    AWAITING_INTERVIEW: "AWAITING_INTERVIEW",
    WAITING_FOR_REPORT: "WAITING_FOR_REPORT",
    REPORT_SUBMITTED: "REPORT_SUBMITTED",
    FOLLOW_UP: "REPORT_SUBMITTED",
    ON_HOLD: "REPORT_SUBMITTED",
    HIRED: "REPORT_SUBMITTED",
    REJECTED: "REJECTED",
  };

  for (const [raw, visible] of Object.entries(expected)) {
    assert.equal(
      projectInterviewerReportStatus(raw as RawReportStatus),
      visible,
      raw,
    );
  }
});

test("Interviewer DTO parser fails closed on HR/private metadata", () => {
  assert.throws(
    () =>
      parseInterviewerReportPageRpc({
        success: true,
        data: {
          rounds: [
            {
              hr_report_note: "private",
            },
          ],
        },
      }),
    /Unexpected Interviewer report DTO key/,
  );

  assert.throws(
    () =>
      parseInterviewerReportPageRpc({
        success: true,
        data: {
          rounds: [
            {
              report_status_code: "HIRED",
            },
          ],
        },
      }),
    /Unexpected Interviewer report DTO key/,
  );

  assert.throws(
    () =>
      parseInterviewerReportPageRpc({
        success: true,
        data: {
          rounds: [
            {
              unexpected_private_field: "future backend drift",
            },
          ],
        },
      }),
    /Unexpected Interviewer report DTO key/,
  );
});

test("Interviewer DTO accepts safe current and historical rounds", () => {
  const baseRound = {
    application_id: "11111111-1111-4111-8111-111111111111",
    interview_id: "22222222-2222-4222-8222-222222222222",
    round_no: 2,
    is_current_round: true,
    candidate_name: "Candidate A",
    position_name_vi: "Giảng viên",
    position_name_en: "Lecturer",
    start_at: "2026-09-08T02:00:00Z",
    end_at: "2026-09-08T03:00:00Z",
    format_name_vi: "Trực tuyến",
    format_name_en: "Online",
    room_name: null,
    meeting_link: "https://meet.example.test/abc",
    display_report_status: "REPORT_SUBMITTED",
    can_edit: true,
    interview_participant_id: "33333333-3333-4333-8333-333333333333",
    has_own_report: true,
    own_version_no: 4,
    own_report: {
      ...EMPTY_REPORT_FIELDS,
      professional_knowledge: "Strong",
    },
    preview: {
      participants: [
        {
          participant_order: 1,
          name: "Interviewer One",
          job_title: "Lecturer",
          report: {
            ...EMPTY_REPORT_FIELDS,
            professional_knowledge: "Strong",
          },
        },
      ],
      final_decision: {
        conclusion: "Proceed",
        expected_specific_job_assigned: null,
        expected_recruitment_time: null,
      },
    },
  };

  const parsed = parseInterviewerReportPageRpc({
    success: true,
    data: {
      rounds: [
        baseRound,
        {
          ...baseRound,
          interview_id: "44444444-4444-4444-8444-444444444444",
          round_no: 1,
          is_current_round: false,
          can_edit: false,
          preview: null,
        },
      ],
    },
  });

  assert.equal(parsed.rounds.length, 2);
  assert.equal(parsed.rounds[0].preview?.participants.length, 1);
  assert.equal(parsed.rounds[1].preview, null);

  const groups = groupInterviewerReportRounds(parsed.rounds);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].primaryRound.roundNo, 2);
  assert.deepEqual(
    groups[0].rounds.map((round) => round.roundNo),
    [2, 1],
  );
});

test("report patch builder sends only changed fields with matching base values", () => {
  const base = { ...EMPTY_REPORT_FIELDS, necessary_skills: "SQL" };
  const next = {
    ...base,
    necessary_skills: "SQL + TypeScript",
    conclusion: "",
  };

  const changed = changedReportFields(base, next);
  assert.deepEqual(changed.patches, {
    necessary_skills: "SQL + TypeScript",
    conclusion: "",
  });
  assert.deepEqual(changed.baseValues, {
    necessary_skills: "SQL",
    conclusion: null,
  });
});

test("meeting links allow only HTTP(S) protocols", () => {
  assert.equal(
    safeMeetingHref("https://meet.example.test/room"),
    "https://meet.example.test/room",
  );
  assert.equal(safeMeetingHref("javascript:alert(1)"), null);
  assert.equal(safeMeetingHref("data:text/html,test"), null);
  assert.equal(safeMeetingHref("not a url"), null);
});
