export type InterviewActivityFilter = "ACTIVE" | "INACTIVE" | "ALL";
export type InterviewScheduleStatus =
  | "AVAILABLE"
  | "SCHEDULED"
  | "AWAITING"
  | "CONFIRMED"
  | "CANCELLED";

export const INTERVIEW_STATUS_LABEL: Record<InterviewScheduleStatus, string> = {
  AVAILABLE: "Sẵn sàng",
  SCHEDULED: "Đã xếp lịch",
  AWAITING: "Chờ xác nhận",
  CONFIRMED: "Đã xác nhận",
  CANCELLED: "Hủy",
};

// Selection/status/actions stay usable while content shares the remaining workspace.
export const INTERVIEW_COLUMNS = [
  48,
  "26%",
  "18%",
  "14%",
  168,
  undefined,
  100,
] as const;

export interface InterviewParticipant {
  interviewParticipantId: string;
  appUserId: string;
  order: number;
  name: string;
  email: string;
  jobTitle: string | null;
  isCurrent: boolean;
  removedAt: string | null;
  versionNo: number;
  hasReportHistory: boolean;
}

export interface InterviewRound {
  interviewId: string;
  applicationId: string;
  roundNo: number;
  demoTopic: string | null;
  startAt: string | null;
  endAt: string | null;
  interviewFormatId: string | null;
  roomId: string | null;
  meetingLink: string | null;
  scheduleStatus: InterviewScheduleStatus;
  reportStatus: string;
  interviewNote: string | null;
  isActive: boolean;
  versionNo: number;
  updatedAt: string;
  participants: InterviewParticipant[];
}

export interface InterviewApplicationGroup {
  applicationId: string;
  submissionId: string;
  candidateId: string;
  candidateName: string;
  candidateEmail: string;
  candidatePhone: string;
  submissionDate: string;
  submissionStatus: string;
  unitId: string;
  unitName: string;
  departmentTeamId: string | null;
  departmentTeamName: string | null;
  positionId: string;
  positionName: string;
  hrOwnerId: string;
  hrOwnerName: string;
  isActive: boolean;
  versionNo: number;
  rounds: InterviewRound[];
}

export interface InterviewFormatOption {
  id: string;
  code: string;
  name: string;
  requiresRoom: boolean;
  requiresMeetingLink: boolean;
  isActive: boolean;
}

export interface InterviewRoomOption {
  id: string;
  code: string | null;
  name: string;
  building: string | null;
  isActive: boolean;
}

export interface InterviewUserOption {
  id: string;
  name: string;
  email: string;
  jobTitle: string | null;
}

export interface SubmissionSelectorOption {
  submissionId: string;
  candidateName: string;
  verifiedEmail: string;
  submittedAt: string;
  status: string;
}

export interface ApplicationSelectorOption {
  applicationId: string;
  label: string;
  candidateName: string;
  candidateEmail: string;
  versionNo: number;
  latestRoundId: string;
  latestRoundVersionNo: number;
  latestRoundNo: number;
}

export interface InterviewPermissions {
  canView: boolean;
  canManage: boolean;
  canChangeStatus: boolean;
  canManageParticipants: boolean;
  canCreateApplication: boolean;
  canReactivateApplication: boolean;
  canDeleteApplication: boolean;
}

export interface InterviewFilterUnitOption {
  id: string;
  name: string;
}

export interface InterviewFilterTeamOption extends InterviewFilterUnitOption {
  unitId: string;
}

export interface InterviewFilterPositionOption
  extends InterviewFilterUnitOption {
  unitId: string;
  departmentTeamId: string | null;
}

export interface InterviewPageFilters {
  query: string;
  activity: InterviewActivityFilter;
  unitId: string;
  departmentTeamId: string;
  positionId: string;
  scheduleStatus: InterviewScheduleStatus | "";
  dateFrom: string;
  dateTo: string;
  location: string;
  interviewFormatId: string;
  participantAppUserId: string;
  hrOwnerId: string;
}

export interface InterviewPageData {
  groups: InterviewApplicationGroup[];
  page: number;
  pageCount: number;
  formats: InterviewFormatOption[];
  rooms: InterviewRoomOption[];
  participantUsers: InterviewUserOption[];
  filterUnits: InterviewFilterUnitOption[];
  filterTeams: InterviewFilterTeamOption[];
  filterPositions: InterviewFilterPositionOption[];
  filterHrOwners: InterviewUserOption[];
  permissions: InterviewPermissions;
}

export const INITIAL_INTERVIEW_FILTERS: InterviewPageFilters = {
  query: "",
  activity: "ACTIVE",
  unitId: "",
  departmentTeamId: "",
  positionId: "",
  scheduleStatus: "",
  dateFrom: "",
  dateTo: "",
  location: "",
  interviewFormatId: "",
  participantAppUserId: "",
  hrOwnerId: "",
};

const FILTER_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FILTER_DATE = /^\d{4}-\d{2}-\d{2}$/;
const FILTER_STATUSES = new Set<InterviewScheduleStatus>([
  "AVAILABLE",
  "SCHEDULED",
  "AWAITING",
  "CONFIRMED",
  "CANCELLED",
]);

function normalizedUuid(value: unknown): string {
  return typeof value === "string" && FILTER_UUID.test(value) ? value : "";
}

function normalizedDate(value: unknown): string {
  return typeof value === "string" && FILTER_DATE.test(value) ? value : "";
}

export function normalizeInterviewFilters(
  value: Partial<InterviewPageFilters> | undefined,
): InterviewPageFilters {
  const activity =
    value?.activity === "INACTIVE" || value?.activity === "ALL"
      ? value.activity
      : "ACTIVE";
  const scheduleStatus =
    typeof value?.scheduleStatus === "string" &&
    FILTER_STATUSES.has(value.scheduleStatus as InterviewScheduleStatus)
      ? (value.scheduleStatus as InterviewScheduleStatus)
      : "";
  const rawLocation = typeof value?.location === "string" ? value.location : "";
  const location =
    rawLocation === "ONLINE" ||
    (rawLocation.startsWith("ROOM:") && FILTER_UUID.test(rawLocation.slice(5)))
      ? rawLocation
      : "";
  return {
    query:
      typeof value?.query === "string" ? value.query.trim().slice(0, 256) : "",
    activity,
    unitId: normalizedUuid(value?.unitId),
    departmentTeamId: normalizedUuid(value?.departmentTeamId),
    positionId: normalizedUuid(value?.positionId),
    scheduleStatus,
    dateFrom: normalizedDate(value?.dateFrom),
    dateTo: normalizedDate(value?.dateTo),
    location,
    interviewFormatId: normalizedUuid(value?.interviewFormatId),
    participantAppUserId: normalizedUuid(value?.participantAppUserId),
    hrOwnerId: normalizedUuid(value?.hrOwnerId),
  };
}

export function nextExpandedApplicationId(
  currentId: string | null,
  clickedId: string,
): string | null {
  return currentId === clickedId ? null : clickedId;
}

export function formatInterviewTime(
  startAt: string | null,
  endAt: string | null,
  locale: "vi" | "en" = "vi",
): string {
  if (!startAt || !endAt) return "Chưa xếp lịch";
  const start = new Date(startAt);
  const end = new Date(endAt);
  const language = locale === "en" ? "en-GB" : "vi-VN";
  const time = new Intl.DateTimeFormat(language, {
    timeZone: "Asia/Ho_Chi_Minh",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const date = new Intl.DateTimeFormat(language, {
    timeZone: "Asia/Ho_Chi_Minh",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  });
  return `${time.format(start)} – ${time.format(end)} · ${date.format(start)}`;
}
