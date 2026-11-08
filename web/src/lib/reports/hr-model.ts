import {
  EMPTY_REPORT_FIELDS,
  type RawReportStatus,
  REPORT_FIELD_KEYS,
  type ReportFields,
} from "./model";

export const HR_REPORT_STATUSES: RawReportStatus[] = [
  "INTERVIEW_SCHEDULING",
  "AWAITING_INTERVIEW",
  "WAITING_FOR_REPORT",
  "REPORT_SUBMITTED",
  "FOLLOW_UP",
  "ON_HOLD",
  "HIRED",
  "REJECTED",
];

export const HR_REPORT_STATUS_LABELS: Record<
  RawReportStatus,
  { vi: string; en: string }
> = {
  INTERVIEW_SCHEDULING: { vi: "Chờ xếp lịch", en: "Interview Scheduling" },
  AWAITING_INTERVIEW: { vi: "Chờ phỏng vấn", en: "Awaiting Interview" },
  WAITING_FOR_REPORT: { vi: "Chờ báo report", en: "Waiting for Report" },
  REPORT_SUBMITTED: { vi: "Đã gửi Báo cáo", en: "Report Submitted" },
  FOLLOW_UP: { vi: "Theo dõi thêm", en: "Follow Up" },
  ON_HOLD: { vi: "Tạm hoãn", en: "On Hold" },
  HIRED: { vi: "Tuyển dụng", en: "Hired" },
  REJECTED: { vi: "Từ chối", en: "Rejected" },
};

export type HrReportVisibilityFilter = "ALL" | "VISIBLE" | "HIDDEN";
export type HrReportSort = "CANDIDATE_ASC" | "CANDIDATE_DESC" | "UPDATED_DESC";

export interface HrReportFilters {
  page: number;
  pageSize: number;
  status: RawReportStatus | null;
  visibility: HrReportVisibilityFilter;
  search: string;
  sort: HrReportSort;
}

export const INITIAL_HR_REPORT_FILTERS: HrReportFilters = {
  page: 1,
  pageSize: 20,
  status: null,
  visibility: "ALL",
  search: "",
  sort: "CANDIDATE_ASC",
};

export interface HrReportPermissions {
  manageStatus: boolean;
  visibility: boolean;
  editInterviewer: boolean;
  delete: boolean;
}

export interface HrReportParticipant {
  interviewParticipantId: string;
  participantOrder: number;
  name: string;
  jobTitle: string | null;
  interviewReportId: string | null;
  reportVersionNo: number;
  report: ReportFields;
  updatedAt: string | null;
  updatedByName: string | null;
}

export interface HrReportFinalDecision {
  sourceInterviewReportId: string | null;
  sourceParticipantName: string | null;
  conclusion: string | null;
  expectedSpecificJobAssigned: string | null;
  expectedRecruitmentTime: string | null;
  updatedAt: string | null;
  updatedByName: string | null;
}

export interface HrReportDrawerData {
  hrOwnerName: string | null;
  participants: HrReportParticipant[];
  finalDecision: HrReportFinalDecision;
}

export interface HrReportRow {
  applicationId: string;
  interviewId: string;
  roundNo: number;
  interviewVersionNo: number;
  candidateName: string;
  positionNameVi: string;
  positionNameEn: string | null;
  startAt: string | null;
  endAt: string | null;
  formatNameVi: string | null;
  formatNameEn: string | null;
  roomName: string | null;
  reportStatus: RawReportStatus;
  hrReportNote: string | null;
  visibleToInterviewers: boolean;
  lastUpdatedAt: string | null;
  lastUpdatedByName: string | null;
  drawer: HrReportDrawerData;
}

export interface HrReportPageData {
  rows: HrReportRow[];
  page: number;
  pageSize: number;
  total: number;
  pageCount: number;
  permissions: HrReportPermissions;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  context: string,
): void {
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!allowedSet.has(key)) {
      throw new Error(`Unexpected HR report DTO key at ${context}: ${key}`);
    }
  }
}

function requiredString(value: unknown, context: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Invalid HR report string at ${context}`);
  }
  return value;
}

function nullableString(value: unknown, context: string): string | null {
  if (value === null) return null;
  if (typeof value !== "string") {
    throw new Error(`Invalid HR report nullable string at ${context}`);
  }
  return value;
}

function positiveInteger(value: unknown, context: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1) {
    throw new Error(`Invalid HR report integer at ${context}`);
  }
  return value;
}

function nonNegativeInteger(value: unknown, context: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid HR report integer at ${context}`);
  }
  return value;
}

function uuid(value: unknown, context: string): string {
  const parsed = requiredString(value, context);
  if (!UUID_RE.test(parsed))
    throw new Error(`Invalid HR report UUID at ${context}`);
  return parsed;
}

function reportStatus(value: unknown, context: string): RawReportStatus {
  if (
    typeof value !== "string" ||
    !HR_REPORT_STATUSES.includes(value as RawReportStatus)
  ) {
    throw new Error(`Invalid HR report status at ${context}`);
  }
  return value as RawReportStatus;
}

function reportFields(value: unknown, context: string): ReportFields {
  if (!isRecord(value))
    throw new Error(`Invalid HR report fields at ${context}`);
  exactKeys(value, REPORT_FIELD_KEYS, context);
  const result = { ...EMPTY_REPORT_FIELDS };
  for (const key of REPORT_FIELD_KEYS) {
    result[key] = nullableString(value[key], `${context}.${key}`);
  }
  return result;
}

function participant(value: unknown, index: number): HrReportParticipant {
  const context = `data.rows[].drawer.participants[${index}]`;
  if (!isRecord(value)) throw new Error(`Invalid HR participant at ${context}`);
  exactKeys(
    value,
    [
      "interview_participant_id",
      "participant_order",
      "name",
      "job_title",
      "interview_report_id",
      "report_version_no",
      "report",
      "updated_at",
      "updated_by_name",
    ],
    context,
  );
  return {
    interviewParticipantId: uuid(
      value.interview_participant_id,
      `${context}.interview_participant_id`,
    ),
    participantOrder: positiveInteger(
      value.participant_order,
      `${context}.participant_order`,
    ),
    name: requiredString(value.name, `${context}.name`),
    jobTitle: nullableString(value.job_title, `${context}.job_title`),
    interviewReportId:
      value.interview_report_id === null
        ? null
        : uuid(value.interview_report_id, `${context}.interview_report_id`),
    reportVersionNo: positiveInteger(
      value.report_version_no,
      `${context}.report_version_no`,
    ),
    report: reportFields(value.report, `${context}.report`),
    updatedAt: nullableString(value.updated_at, `${context}.updated_at`),
    updatedByName: nullableString(
      value.updated_by_name,
      `${context}.updated_by_name`,
    ),
  };
}

function finalDecision(value: unknown): HrReportFinalDecision {
  const context = "data.rows[].drawer.final_decision";
  if (!isRecord(value))
    throw new Error(`Invalid HR final decision at ${context}`);
  exactKeys(
    value,
    [
      "source_interview_report_id",
      "source_participant_name",
      "conclusion",
      "expected_specific_job_assigned",
      "expected_recruitment_time",
      "updated_at",
      "updated_by_name",
    ],
    context,
  );
  return {
    sourceInterviewReportId:
      value.source_interview_report_id === null
        ? null
        : uuid(
            value.source_interview_report_id,
            `${context}.source_interview_report_id`,
          ),
    sourceParticipantName: nullableString(
      value.source_participant_name,
      `${context}.source_participant_name`,
    ),
    conclusion: nullableString(value.conclusion, `${context}.conclusion`),
    expectedSpecificJobAssigned: nullableString(
      value.expected_specific_job_assigned,
      `${context}.expected_specific_job_assigned`,
    ),
    expectedRecruitmentTime: nullableString(
      value.expected_recruitment_time,
      `${context}.expected_recruitment_time`,
    ),
    updatedAt: nullableString(value.updated_at, `${context}.updated_at`),
    updatedByName: nullableString(
      value.updated_by_name,
      `${context}.updated_by_name`,
    ),
  };
}

function row(value: unknown): HrReportRow {
  const context = "data.rows[]";
  if (!isRecord(value)) throw new Error(`Invalid HR report row at ${context}`);
  exactKeys(
    value,
    [
      "application_id",
      "interview_id",
      "round_no",
      "interview_version_no",
      "candidate_name",
      "position_name_vi",
      "position_name_en",
      "start_at",
      "end_at",
      "format_name_vi",
      "format_name_en",
      "room_name",
      "report_status_code",
      "hr_report_note",
      "visible_to_interviewers",
      "last_updated_at",
      "last_updated_by_name",
      "drawer",
    ],
    context,
  );
  if (!isRecord(value.drawer))
    throw new Error(`Invalid HR drawer at ${context}.drawer`);
  exactKeys(
    value.drawer,
    ["hr_owner_name", "participants", "final_decision"],
    `${context}.drawer`,
  );
  if (!Array.isArray(value.drawer.participants)) {
    throw new Error(
      `Invalid HR participants at ${context}.drawer.participants`,
    );
  }
  if (typeof value.visible_to_interviewers !== "boolean") {
    throw new Error(
      `Invalid HR visibility at ${context}.visible_to_interviewers`,
    );
  }
  return {
    applicationId: uuid(value.application_id, `${context}.application_id`),
    interviewId: uuid(value.interview_id, `${context}.interview_id`),
    roundNo: positiveInteger(value.round_no, `${context}.round_no`),
    interviewVersionNo: positiveInteger(
      value.interview_version_no,
      `${context}.interview_version_no`,
    ),
    candidateName: requiredString(
      value.candidate_name,
      `${context}.candidate_name`,
    ),
    positionNameVi: requiredString(
      value.position_name_vi,
      `${context}.position_name_vi`,
    ),
    positionNameEn: nullableString(
      value.position_name_en,
      `${context}.position_name_en`,
    ),
    startAt: nullableString(value.start_at, `${context}.start_at`),
    endAt: nullableString(value.end_at, `${context}.end_at`),
    formatNameVi: nullableString(
      value.format_name_vi,
      `${context}.format_name_vi`,
    ),
    formatNameEn: nullableString(
      value.format_name_en,
      `${context}.format_name_en`,
    ),
    roomName: nullableString(value.room_name, `${context}.room_name`),
    reportStatus: reportStatus(
      value.report_status_code,
      `${context}.report_status_code`,
    ),
    hrReportNote: nullableString(
      value.hr_report_note,
      `${context}.hr_report_note`,
    ),
    visibleToInterviewers: value.visible_to_interviewers,
    lastUpdatedAt: nullableString(
      value.last_updated_at,
      `${context}.last_updated_at`,
    ),
    lastUpdatedByName: nullableString(
      value.last_updated_by_name,
      `${context}.last_updated_by_name`,
    ),
    drawer: {
      hrOwnerName: nullableString(
        value.drawer.hr_owner_name,
        `${context}.drawer.hr_owner_name`,
      ),
      participants: value.drawer.participants.map(participant),
      finalDecision: finalDecision(value.drawer.final_decision),
    },
  };
}

export function parseHrReportPageRpc(value: unknown): HrReportPageData {
  if (!isRecord(value)) throw new Error("Invalid HR Report RPC response");
  exactKeys(value, ["success", "data"], "root");
  if (value.success !== true || !isRecord(value.data)) {
    throw new Error("HR Report RPC did not return success data");
  }
  exactKeys(
    value.data,
    ["rows", "page", "page_size", "total", "page_count", "permissions"],
    "data",
  );
  if (!Array.isArray(value.data.rows) || !isRecord(value.data.permissions)) {
    throw new Error("Invalid HR Report page data");
  }
  exactKeys(
    value.data.permissions,
    ["manage_status", "visibility", "edit_interviewer", "delete"],
    "data.permissions",
  );
  for (const key of [
    "manage_status",
    "visibility",
    "edit_interviewer",
    "delete",
  ] as const) {
    if (typeof value.data.permissions[key] !== "boolean") {
      throw new Error(`Invalid HR Report permission: ${key}`);
    }
  }
  return {
    rows: value.data.rows.map(row),
    page: positiveInteger(value.data.page, "data.page"),
    pageSize: positiveInteger(value.data.page_size, "data.page_size"),
    total: nonNegativeInteger(value.data.total, "data.total"),
    pageCount: nonNegativeInteger(value.data.page_count, "data.page_count"),
    permissions: {
      manageStatus: value.data.permissions.manage_status as boolean,
      visibility: value.data.permissions.visibility as boolean,
      editInterviewer: value.data.permissions.edit_interviewer as boolean,
      delete: value.data.permissions.delete as boolean,
    },
  };
}

export function normalizeHrReportFilters(
  value: Partial<HrReportFilters> | undefined,
): HrReportFilters {
  const status = HR_REPORT_STATUSES.includes(value?.status as RawReportStatus)
    ? (value?.status as RawReportStatus)
    : null;
  const visibility: HrReportVisibilityFilter =
    value?.visibility === "VISIBLE" || value?.visibility === "HIDDEN"
      ? value.visibility
      : "ALL";
  const sort: HrReportSort =
    value?.sort === "CANDIDATE_DESC" || value?.sort === "UPDATED_DESC"
      ? value.sort
      : "CANDIDATE_ASC";
  const page =
    typeof value?.page === "number" &&
    Number.isInteger(value.page) &&
    value.page > 0
      ? value.page
      : 1;
  const pageSize =
    typeof value?.pageSize === "number" &&
    Number.isInteger(value.pageSize) &&
    value.pageSize >= 1 &&
    value.pageSize <= 100
      ? value.pageSize
      : 20;
  return {
    page,
    pageSize,
    status,
    visibility,
    search:
      typeof value?.search === "string"
        ? value.search.trim().slice(0, 256)
        : "",
    sort,
  };
}

export function hrReportStatusTone(
  status: RawReportStatus,
): "success" | "danger" | "warning" | "info" | "neutral" {
  if (status === "HIRED" || status === "REPORT_SUBMITTED") return "success";
  if (status === "REJECTED") return "danger";
  if (
    status === "AWAITING_INTERVIEW" ||
    status === "WAITING_FOR_REPORT" ||
    status === "ON_HOLD"
  ) {
    return "warning";
  }
  if (status === "INTERVIEW_SCHEDULING" || status === "FOLLOW_UP")
    return "info";
  return "neutral";
}
