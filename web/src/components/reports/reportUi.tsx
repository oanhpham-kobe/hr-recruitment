import type { ReactNode } from "react";
import {
  type InterviewerReportRound,
  REPORT_FIELD_KEYS,
  type ReportFieldKey,
  type ReportFields,
} from "@/lib/reports/model";

export type ReportLocale = "vi" | "en";
export type ReportMode = "view" | "edit";
export type ReportFeedbackCode =
  | "NO_CHANGES"
  | "STALE_RELOADED"
  | "SAVE_FAILED"
  | "SAVE_SUCCEEDED"
  | "ACTION_FAILED";

export type ReportFeedback = {
  kind: "success" | "error" | "warning";
  code: ReportFeedbackCode;
} | null;

export const REPORT_FIELD_LABELS: Record<
  ReportFieldKey,
  [string, string, "evaluation" | "decision"]
> = {
  professional_knowledge: [
    "Kiến thức chuyên môn",
    "Professional Knowledge",
    "evaluation",
  ],
  necessary_skills: ["Kỹ năng cần thiết", "Necessary Skills", "evaluation"],
  qualities_personality: [
    "Phẩm chất, tính cách",
    "Qualities and Personality",
    "evaluation",
  ],
  strengths_limitations: [
    "Điểm mạnh và hạn chế",
    "Strengths and Limitations",
    "evaluation",
  ],
  other_comment: ["Khác", "Other", "evaluation"],
  conclusion: ["Kết luận", "Conclusion", "decision"],
  expected_specific_job_assigned: [
    "Dự kiến công việc cụ thể được phân công",
    "Expected Specific Job Assigned",
    "decision",
  ],
  expected_recruitment_time: [
    "Thời gian dự kiến tuyển dụng",
    "Expected Recruitment Time",
    "decision",
  ],
};

export function reportFeedbackMessage(
  feedback: Exclude<ReportFeedback, null>,
  locale: ReportLocale,
): string {
  const labels: Record<ReportFeedbackCode, [string, string]> = {
    NO_CHANGES: ["Không có thay đổi để lưu.", "There are no changes to save."],
    STALE_RELOADED: [
      "Báo cáo đã thay đổi ở nơi khác. Dữ liệu đã được tải lại.",
      "This report changed elsewhere. Fresh data has been loaded.",
    ],
    SAVE_FAILED: ["Không thể lưu báo cáo.", "The report could not be saved."],
    SAVE_SUCCEEDED: ["Đã lưu báo cáo.", "Report saved."],
    ACTION_FAILED: [
      "Không thể hoàn tất thao tác. Vui lòng thử lại.",
      "The action could not be completed. Please try again.",
    ],
  };
  return labels[feedback.code][locale === "vi" ? 0 : 1];
}

export function cloneReportFields(value: ReportFields): ReportFields {
  return Object.fromEntries(
    REPORT_FIELD_KEYS.map((key) => [key, value[key]]),
  ) as ReportFields;
}

export function displayReportText(value: string | null): string {
  return value?.trim() ? value : "—";
}

export function reportPosition(
  round: InterviewerReportRound,
  locale: ReportLocale,
): string {
  return locale === "en"
    ? round.positionNameEn || round.positionNameVi
    : round.positionNameVi;
}

export function reportFormatName(
  round: InterviewerReportRound,
  locale: ReportLocale,
): string {
  const value =
    locale === "en"
      ? round.formatNameEn || round.formatNameVi
      : round.formatNameVi;
  return value || "—";
}

export function formatReportTime(
  value: string | null,
  locale: ReportLocale,
): string {
  if (!value || Number.isNaN(new Date(value).getTime())) return "—";
  return new Intl.DateTimeFormat(locale === "vi" ? "vi-VN" : "en-US", {
    timeZone: "Asia/Ho_Chi_Minh",
    hour: "2-digit",
    minute: "2-digit",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(new Date(value));
}

export function reportStatusTone(
  status: InterviewerReportRound["displayReportStatus"],
): "success" | "danger" | "warning" | "info" | "neutral" {
  if (status === "REPORT_SUBMITTED") return "success";
  if (status === "REJECTED") return "danger";
  if (status === "AWAITING_INTERVIEW" || status === "WAITING_FOR_REPORT") {
    return "warning";
  }
  if (status === "INTERVIEW_SCHEDULING") return "info";
  return "neutral";
}

export function ReportFieldValues({
  fields,
  locale,
}: {
  fields: ReportFields;
  locale: ReportLocale;
}) {
  return (
    <dl className="interviewer-report__field-list">
      {REPORT_FIELD_KEYS.map((key) => (
        <div className="interviewer-report__field-value" key={key}>
          <dt>{REPORT_FIELD_LABELS[key][locale === "vi" ? 0 : 1]}</dt>
          <dd>{displayReportText(fields[key])}</dd>
        </div>
      ))}
    </dl>
  );
}

export function ReportSection({ children }: { children: ReactNode }) {
  return <section className="interviewer-report__panel">{children}</section>;
}
