import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  HR_REPORT_STATUS_LABELS,
  HR_REPORT_STATUSES,
  normalizeHrReportFilters,
  parseHrReportPageRpc,
} from "@/lib/reports/hr-model";

const applicationId = "11111111-1111-4111-8111-111111111111";
const interviewId = "22222222-2222-4222-8222-222222222222";
const participantId = "33333333-3333-4333-8333-333333333333";
const reportId = "44444444-4444-4444-8444-444444444444";

function canonicalPayload() {
  return {
    success: true,
    data: {
      rows: [
        {
          application_id: applicationId,
          interview_id: interviewId,
          round_no: 2,
          interview_version_no: 5,
          candidate_name: "Candidate A",
          position_name_vi: "Giảng viên",
          position_name_en: "Lecturer",
          start_at: "2026-09-10T02:00:00Z",
          end_at: "2026-09-10T03:00:00Z",
          format_name_vi: "Trực tuyến",
          format_name_en: "Online",
          room_name: null,
          report_status_code: "FOLLOW_UP",
          hr_report_note: "HR authored content",
          visible_to_interviewers: true,
          last_updated_at: "2026-09-10T03:10:00Z",
          last_updated_by_name: "HR Owner",
          drawer: {
            hr_owner_name: "HR Owner",
            participants: [
              {
                interview_participant_id: participantId,
                participant_order: 1,
                name: "Interviewer A",
                job_title: "Lecturer",
                interview_report_id: reportId,
                report_version_no: 3,
                report: {
                  professional_knowledge: "Strong",
                  necessary_skills: "SQL",
                  qualities_personality: null,
                  strengths_limitations: null,
                  other_comment: null,
                  conclusion: "Proceed",
                  expected_specific_job_assigned: null,
                  expected_recruitment_time: null,
                },
                updated_at: "2026-09-10T03:00:00Z",
                updated_by_name: "Interviewer A",
              },
            ],
            final_decision: {
              source_interview_report_id: reportId,
              source_participant_name: "Interviewer A",
              conclusion: "Proceed",
              expected_specific_job_assigned: null,
              expected_recruitment_time: null,
              updated_at: "2026-09-10T03:00:00Z",
              updated_by_name: "Interviewer A",
            },
          },
        },
      ],
      page: 1,
      page_size: 20,
      total: 1,
      page_count: 1,
      permissions: {
        manage_status: true,
        visibility: true,
        edit_interviewer: true,
        delete: true,
      },
    },
  };
}

test("HR report DTO parser accepts the minimum-safe canonical projection", () => {
  const parsed = parseHrReportPageRpc(canonicalPayload());
  assert.equal(parsed.rows.length, 1);
  assert.equal(parsed.rows[0].applicationId, applicationId);
  assert.equal(parsed.rows[0].interviewId, interviewId);
  assert.equal(parsed.rows[0].reportStatus, "FOLLOW_UP");
  assert.equal(parsed.rows[0].hrReportNote, "HR authored content");
  assert.equal(
    parsed.rows[0].drawer.participants[0].report.professional_knowledge,
    "Strong",
  );
  assert.equal(
    parsed.rows[0].drawer.finalDecision.sourceInterviewReportId,
    reportId,
  );
  assert.equal("meetingLink" in parsed.rows[0], false);
});

test("HR report DTO rejects raw meeting links and unrelated private metadata", () => {
  for (const forbiddenKey of [
    "meeting_link",
    "submission_id",
    "candidate_id",
    "email_snapshot",
    "candidate_phone",
    "auth_user_id",
  ]) {
    const next = structuredClone(canonicalPayload());
    (next.data.rows[0] as Record<string, unknown>)[forbiddenKey] =
      forbiddenKey === "meeting_link"
        ? "https://meet.example.test/private"
        : "leak";
    assert.throws(
      () => parseHrReportPageRpc(next),
      /Unexpected HR report DTO key/,
      forbiddenKey,
    );
  }
});

test("HR keeps all eight raw Report statuses without Interviewer projection", () => {
  assert.deepEqual(HR_REPORT_STATUSES, [
    "INTERVIEW_SCHEDULING",
    "AWAITING_INTERVIEW",
    "WAITING_FOR_REPORT",
    "REPORT_SUBMITTED",
    "FOLLOW_UP",
    "ON_HOLD",
    "HIRED",
    "REJECTED",
  ]);
  for (const status of HR_REPORT_STATUSES) {
    assert.ok(HR_REPORT_STATUS_LABELS[status].vi.length > 0, status);
    assert.ok(HR_REPORT_STATUS_LABELS[status].en.length > 0, status);
  }
});

test("HR filter normalization is bounded and keeps PII search in component state", () => {
  assert.deepEqual(
    normalizeHrReportFilters({
      page: -9,
      pageSize: 999,
      status: "FOLLOW_UP",
      visibility: "HIDDEN",
      search: `  ${"x".repeat(300)}  `,
      sort: "UPDATED_DESC",
    }),
    {
      page: 1,
      pageSize: 20,
      status: "FOLLOW_UP",
      visibility: "HIDDEN",
      search: "x".repeat(256),
      sort: "UPDATED_DESC",
    },
  );
});

test("HR Report source preserves fluid columns, status targets and structured reflow", () => {
  const css = readFileSync(
    new URL("../components/reports/HrReportView.module.css", import.meta.url),
    "utf8",
  );
  const view = readFileSync(
    new URL("../components/reports/HrReportView.tsx", import.meta.url),
    "utf8",
  );

  assert.match(css, /\.table \{[\s\S]*?width:\s*100%/);
  assert.match(css, /\.table \{[\s\S]*?min-width:\s*0/);
  assert.match(css, /table-layout:\s*fixed/);
  assert.match(css, /left:\s*48px/);
  assert.match(css, /--badge-width-interview-operational/);
  assert.match(css, /scroll-margin-inline-start:\s*300px/);
  assert.doesNotMatch(css, /overflow-wrap:\s*anywhere/);
  assert.match(css, /@container \(max-width: 1100px\)/);
  assert.match(view, /workflow-note-excerpt/);
  assert.doesNotMatch(css, /!important/);

  assert.match(view, /<colgroup>/);
  const columns = view.match(/<col(?: style=\{\{[^}]+\}\})? \/>/g) ?? [];
  assert.equal(
    columns.length,
    8,
    "Header and rows share all eight semantic columns",
  );
  assert.match(view, /width: 48/, "Selection column reserves its touch target");
  assert.match(
    view,
    /width: 168/,
    "Status column reserves the144px badge plus padding",
  );
  assert.match(view, /width: 100/, "Action column reserves a usable button");
  assert.match(view, /<TableScrollContainer/);
  assert.match(view, /Đã chọn/);
  assert.match(view, /Delete \/ Inactivate/);
  assert.doesNotMatch(view, /meetingLink/);
});
