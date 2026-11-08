export const REPORT_FIELD_KEYS = [
  "professional_knowledge",
  "necessary_skills",
  "qualities_personality",
  "strengths_limitations",
  "other_comment",
  "conclusion",
  "expected_specific_job_assigned",
  "expected_recruitment_time",
] as const;

export type ReportFieldKey = (typeof REPORT_FIELD_KEYS)[number];

export type ReportFields = Record<ReportFieldKey, string | null>;

export const EMPTY_REPORT_FIELDS: ReportFields = {
  professional_knowledge: null,
  necessary_skills: null,
  qualities_personality: null,
  strengths_limitations: null,
  other_comment: null,
  conclusion: null,
  expected_specific_job_assigned: null,
  expected_recruitment_time: null,
};

export type InterviewerReportDisplayStatus =
  | "INTERVIEW_SCHEDULING"
  | "AWAITING_INTERVIEW"
  | "WAITING_FOR_REPORT"
  | "REPORT_SUBMITTED"
  | "REJECTED";

export type RawReportStatus =
  | InterviewerReportDisplayStatus
  | "FOLLOW_UP"
  | "ON_HOLD"
  | "HIRED";

export interface ReportPreviewParticipant {
  participantOrder: number;
  name: string;
  jobTitle: string | null;
  report: ReportFields;
}

export interface ReportFinalDecision {
  conclusion: string | null;
  expectedSpecificJobAssigned: string | null;
  expectedRecruitmentTime: string | null;
}

export interface ReportPreview {
  participants: ReportPreviewParticipant[];
  finalDecision: ReportFinalDecision;
}

export interface InterviewerReportRound {
  applicationId: string;
  interviewId: string;
  roundNo: number;
  isCurrentRound: boolean;
  candidateName: string;
  positionNameVi: string;
  positionNameEn: string | null;
  startAt: string | null;
  endAt: string | null;
  formatNameVi: string | null;
  formatNameEn: string | null;
  roomName: string | null;
  meetingLink: string | null;
  displayReportStatus: InterviewerReportDisplayStatus;
  canEdit: boolean;
  interviewParticipantId: string;
  hasOwnReport: boolean;
  ownVersionNo: number;
  ownReport: ReportFields;
  preview: ReportPreview | null;
}

export interface InterviewerReportPageData {
  rounds: InterviewerReportRound[];
}

export interface ReportApplicationGroup {
  applicationId: string;
  candidateName: string;
  positionNameVi: string;
  positionNameEn: string | null;
  rounds: InterviewerReportRound[];
  primaryRound: InterviewerReportRound;
}

export const REPORT_STATUS_LABELS: Record<
  InterviewerReportDisplayStatus,
  { vi: string; en: string }
> = {
  INTERVIEW_SCHEDULING: {
    vi: "Chờ xếp lịch",
    en: "Interview Scheduling",
  },
  AWAITING_INTERVIEW: {
    vi: "Chờ phỏng vấn",
    en: "Awaiting Interview",
  },
  WAITING_FOR_REPORT: {
    vi: "Chờ báo report",
    en: "Waiting for Report",
  },
  REPORT_SUBMITTED: {
    vi: "Đã gửi Báo cáo",
    en: "Report Submitted",
  },
  REJECTED: {
    vi: "Từ chối",
    en: "Rejected",
  },
};

export function projectInterviewerReportStatus(
  raw: RawReportStatus,
): InterviewerReportDisplayStatus {
  if (raw === "FOLLOW_UP" || raw === "ON_HOLD" || raw === "HIRED") {
    return "REPORT_SUBMITTED";
  }
  return raw;
}

export function groupInterviewerReportRounds(
  rounds: InterviewerReportRound[],
): ReportApplicationGroup[] {
  const grouped = new Map<string, InterviewerReportRound[]>();
  for (const round of rounds) {
    const current = grouped.get(round.applicationId);
    if (current) current.push(round);
    else grouped.set(round.applicationId, [round]);
  }

  return [...grouped.entries()]
    .map(([applicationId, applicationRounds]) => {
      const sorted = [...applicationRounds].sort(
        (a, b) => b.roundNo - a.roundNo,
      );
      const primaryRound =
        sorted.find((round) => round.isCurrentRound) ?? sorted[0];
      return {
        applicationId,
        candidateName: primaryRound.candidateName,
        positionNameVi: primaryRound.positionNameVi,
        positionNameEn: primaryRound.positionNameEn,
        rounds: sorted,
        primaryRound,
      };
    })
    .sort((a, b) =>
      a.candidateName.localeCompare(b.candidateName, "vi", {
        sensitivity: "base",
      }),
    );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertExactKeys(
  value: Record<string, unknown>,
  allowedKeys: readonly string[],
  context: string,
): void {
  const allowed = new Set(allowedKeys);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      throw new Error(
        `Unexpected Interviewer report DTO key at ${context}: ${key}`,
      );
    }
  }
}

const REPORT_FIELDS_DTO_KEYS = [...REPORT_FIELD_KEYS] as const;
const FINAL_DECISION_DTO_KEYS = [
  "conclusion",
  "expected_specific_job_assigned",
  "expected_recruitment_time",
] as const;
const PREVIEW_PARTICIPANT_DTO_KEYS = [
  "participant_order",
  "name",
  "job_title",
  "report",
] as const;
const PREVIEW_DTO_KEYS = ["participants", "final_decision"] as const;
const ROUND_DTO_KEYS = [
  "application_id",
  "interview_id",
  "round_no",
  "is_current_round",
  "candidate_name",
  "position_name_vi",
  "position_name_en",
  "start_at",
  "end_at",
  "format_name_vi",
  "format_name_en",
  "room_name",
  "meeting_link",
  "display_report_status",
  "can_edit",
  "interview_participant_id",
  "has_own_report",
  "own_version_no",
  "own_report",
  "preview",
] as const;

function stringValue(
  value: unknown,
  field: string,
  nullable = false,
): string | null {
  if (value === null && nullable) return null;
  if (typeof value === "string") return value;
  throw new Error(`Invalid Interviewer report DTO field: ${field}`);
}

function numberValue(value: unknown, field: string): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  throw new Error(`Invalid Interviewer report DTO field: ${field}`);
}

function booleanValue(value: unknown, field: string): boolean {
  if (typeof value === "boolean") return value;
  throw new Error(`Invalid Interviewer report DTO field: ${field}`);
}

function reportStatus(value: unknown): InterviewerReportDisplayStatus {
  if (
    value === "INTERVIEW_SCHEDULING" ||
    value === "AWAITING_INTERVIEW" ||
    value === "WAITING_FOR_REPORT" ||
    value === "REPORT_SUBMITTED" ||
    value === "REJECTED"
  ) {
    return value;
  }
  throw new Error("Unsafe or invalid Interviewer report status");
}

function reportFields(value: unknown): ReportFields {
  if (!isRecord(value)) {
    throw new Error("Invalid Interviewer report fields");
  }
  assertExactKeys(value, REPORT_FIELDS_DTO_KEYS, "report");

  const parsed = { ...EMPTY_REPORT_FIELDS };
  for (const key of REPORT_FIELD_KEYS) {
    const fieldValue = value[key];
    if (fieldValue === null) {
      parsed[key] = null;
    } else if (typeof fieldValue === "string") {
      parsed[key] = fieldValue;
    } else {
      throw new Error(`Invalid Interviewer report field: ${key}`);
    }
  }
  return parsed;
}

function previewValue(value: unknown): ReportPreview | null {
  if (value === null) return null;
  if (!isRecord(value) || !Array.isArray(value.participants)) {
    throw new Error("Invalid Interviewer report preview");
  }
  assertExactKeys(value, PREVIEW_DTO_KEYS, "preview");

  const participants = value.participants.map((item) => {
    if (!isRecord(item)) throw new Error("Invalid preview participant");
    assertExactKeys(item, PREVIEW_PARTICIPANT_DTO_KEYS, "preview.participant");
    return {
      participantOrder: numberValue(
        item.participant_order,
        "participant_order",
      ),
      name: stringValue(item.name, "participant.name") as string,
      jobTitle: stringValue(item.job_title, "participant.job_title", true),
      report: reportFields(item.report),
    };
  });

  if (!isRecord(value.final_decision)) {
    throw new Error("Invalid Interviewer final decision");
  }
  assertExactKeys(
    value.final_decision,
    FINAL_DECISION_DTO_KEYS,
    "preview.final_decision",
  );

  return {
    participants,
    finalDecision: {
      conclusion: stringValue(
        value.final_decision.conclusion,
        "final_decision.conclusion",
        true,
      ),
      expectedSpecificJobAssigned: stringValue(
        value.final_decision.expected_specific_job_assigned,
        "final_decision.expected_specific_job_assigned",
        true,
      ),
      expectedRecruitmentTime: stringValue(
        value.final_decision.expected_recruitment_time,
        "final_decision.expected_recruitment_time",
        true,
      ),
    },
  };
}

function roundValue(value: unknown): InterviewerReportRound {
  if (!isRecord(value)) throw new Error("Invalid Interviewer report round");
  assertExactKeys(value, ROUND_DTO_KEYS, "round");

  return {
    applicationId: stringValue(
      value.application_id,
      "application_id",
    ) as string,
    interviewId: stringValue(value.interview_id, "interview_id") as string,
    roundNo: numberValue(value.round_no, "round_no"),
    isCurrentRound: booleanValue(value.is_current_round, "is_current_round"),
    candidateName: stringValue(
      value.candidate_name,
      "candidate_name",
    ) as string,
    positionNameVi: stringValue(
      value.position_name_vi,
      "position_name_vi",
    ) as string,
    positionNameEn: stringValue(
      value.position_name_en,
      "position_name_en",
      true,
    ),
    startAt: stringValue(value.start_at, "start_at", true),
    endAt: stringValue(value.end_at, "end_at", true),
    formatNameVi: stringValue(value.format_name_vi, "format_name_vi", true),
    formatNameEn: stringValue(value.format_name_en, "format_name_en", true),
    roomName: stringValue(value.room_name, "room_name", true),
    meetingLink: stringValue(value.meeting_link, "meeting_link", true),
    displayReportStatus: reportStatus(value.display_report_status),
    canEdit: booleanValue(value.can_edit, "can_edit"),
    interviewParticipantId: stringValue(
      value.interview_participant_id,
      "interview_participant_id",
    ) as string,
    hasOwnReport: booleanValue(value.has_own_report, "has_own_report"),
    ownVersionNo: numberValue(value.own_version_no, "own_version_no"),
    ownReport: reportFields(value.own_report),
    preview: previewValue(value.preview),
  };
}

export function parseInterviewerReportPageRpc(
  value: unknown,
): InterviewerReportPageData {
  if (!isRecord(value))
    throw new Error("Invalid Interviewer report RPC response");

  if (value.success !== true) {
    assertExactKeys(
      value,
      ["success", "error_code", "message"],
      "error response",
    );
    const code =
      typeof value.error_code === "string" ? value.error_code : "READ_FAILED";
    throw new Error(code);
  }

  assertExactKeys(value, ["success", "data"], "success response");
  if (!isRecord(value.data)) {
    throw new Error("Invalid Interviewer report data payload");
  }
  assertExactKeys(value.data, ["rounds"], "data");
  if (!Array.isArray(value.data.rounds)) {
    throw new Error("Invalid Interviewer report rounds payload");
  }
  return { rounds: value.data.rounds.map(roundValue) };
}

export function safeMeetingHref(value: string | null): string | null {
  if (!value) return null;
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" || parsed.protocol === "http:"
      ? parsed.href
      : null;
  } catch {
    return null;
  }
}

export function reportFieldsEqual(
  left: ReportFields,
  right: ReportFields,
): boolean {
  return REPORT_FIELD_KEYS.every((key) => left[key] === right[key]);
}

export function changedReportFields(
  base: ReportFields,
  next: ReportFields,
): {
  patches: Partial<ReportFields>;
  baseValues: Partial<ReportFields>;
} {
  const patches: Partial<ReportFields> = {};
  const baseValues: Partial<ReportFields> = {};
  for (const key of REPORT_FIELD_KEYS) {
    if (base[key] !== next[key]) {
      patches[key] = next[key];
      baseValues[key] = base[key];
    }
  }
  return { patches, baseValues };
}
