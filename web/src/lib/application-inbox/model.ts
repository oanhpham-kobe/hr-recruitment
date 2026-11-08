export const APPLICATION_INBOX_COLUMNS = [
  { key: "select", label: "Chọn", width: 48 },
  { key: "name", label: "Tên", width: 220 },
  { key: "email", label: "Email", width: 250 },
  { key: "dateOfBirth", label: "Ngày sinh", width: 130 },
  { key: "gender", label: "Giới tính", width: 100 },
  { key: "phone", label: "SĐT", width: 150 },
  { key: "status", label: "Trạng thái", width: 150 },
  { key: "hrNote", label: "HR Note", width: 420 },
  { key: "action", label: "Thao tác", width: 92 },
] as const;

export const APPLICATION_INBOX_PAGE_SIZES = [25, 50, 100] as const;
export type ApplicationInboxPageSize =
  (typeof APPLICATION_INBOX_PAGE_SIZES)[number];
export const DEFAULT_APPLICATION_INBOX_PAGE_SIZE: ApplicationInboxPageSize = 25;

export function normalizeApplicationInboxPageSize(
  value: unknown,
): ApplicationInboxPageSize {
  return typeof value === "number" &&
    Number.isSafeInteger(value) &&
    APPLICATION_INBOX_PAGE_SIZES.includes(value as ApplicationInboxPageSize)
    ? (value as ApplicationInboxPageSize)
    : DEFAULT_APPLICATION_INBOX_PAGE_SIZE;
}

export type SubmissionStatus = "NEW" | "READ" | "PROCESSED" | "DONE" | "CLOSED";

export interface ApplicationInboxSubmission {
  submissionId: string;
  candidateId: string;
  status: SubmissionStatus;
  fullName: string;
  dateOfBirth: string | null;
  gender: "MALE" | "FEMALE" | null;
  phone: string | null;
  hrNote: string | null;
  submittedAt: string;
  hasApplication: boolean;
  hasActiveApplication?: boolean;
  applications?: Array<{
    applicationId?: string;
    is_active?: boolean;
    isActive?: boolean;
    [key: string]: unknown;
  }>;
  versionNo: number;
}

export interface ApplicationInboxGroup {
  candidateId: string;
  email: string;
  isCandidateActive: boolean;
  candidateVersionNo: number;
  latestSubmissionId: string;
  latestSubmissionVersionNo: number;
  hasActiveApplication?: boolean;
  applications?: Array<{
    applicationId?: string;
    is_active?: boolean;
    isActive?: boolean;
    [key: string]: unknown;
  }>;
  submissions: ApplicationInboxSubmission[];
}

export interface ApplicationInboxFilters {
  query: string;
  status: "ALL" | SubmissionStatus;
  dateFrom: string;
  dateTo: string;
  candidateActivity: "ALL" | "ACTIVE" | "INACTIVE";
  newRead: "ALL" | "NEW" | "READ";
  application: "ALL" | "HAS_APPLICATION" | "NO_APPLICATION";
}

export const INITIAL_APPLICATION_INBOX_FILTERS: ApplicationInboxFilters = {
  query: "",
  status: "ALL",
  dateFrom: "",
  dateTo: "",
  candidateActivity: "ALL",
  newRead: "ALL",
  application: "ALL",
};

function compareLatestSubmission(
  left: ApplicationInboxSubmission,
  right: ApplicationInboxSubmission,
): number {
  const submittedAtDifference = right.submittedAt.localeCompare(
    left.submittedAt,
  );
  return submittedAtDifference !== 0
    ? submittedAtDifference
    : right.submissionId.localeCompare(left.submissionId);
}

export function projectApplicationInboxGroups(
  submissions: ApplicationInboxSubmission[],
): ApplicationInboxGroup[] {
  const groups = new Map<string, ApplicationInboxGroup>();

  for (const submission of submissions) {
    const group = groups.get(submission.candidateId);
    if (group) {
      group.submissions.push(submission);
      continue;
    }

    groups.set(submission.candidateId, {
      candidateId: submission.candidateId,
      email: "",
      isCandidateActive: true,
      candidateVersionNo: 1,
      latestSubmissionId: submission.submissionId,
      latestSubmissionVersionNo: submission.versionNo,
      submissions: [submission],
    });
  }

  return [...groups.values()]
    .map((group) => {
      const sorted = group.submissions.toSorted(compareLatestSubmission);
      const latest = sorted[0];
      return {
        ...group,
        latestSubmissionId: latest
          ? latest.submissionId
          : group.latestSubmissionId,
        latestSubmissionVersionNo: latest
          ? latest.versionNo
          : group.latestSubmissionVersionNo,
        submissions: sorted,
      };
    })
    .toSorted((left, right) => {
      const latestDifference = compareLatestSubmission(
        left.submissions[0],
        right.submissions[0],
      );
      return latestDifference !== 0
        ? latestDifference
        : left.candidateId.localeCompare(right.candidateId);
    });
}

export function latestSubmission(group: ApplicationInboxGroup) {
  return group.submissions[0];
}

export function nextExpandedCandidateId(
  currentCandidateId: string | null,
  candidateId: string,
): string | null {
  return currentCandidateId === candidateId ? null : candidateId;
}
function matchesQuery(group: ApplicationInboxGroup, query: string): boolean {
  const normalizedQuery = query.trim().toLocaleLowerCase("vi-VN");
  if (!normalizedQuery) return true;

  return group.submissions.some((submission) =>
    [group.email, submission.fullName, submission.phone ?? ""].some((value) =>
      value.toLocaleLowerCase("vi-VN").includes(normalizedQuery),
    ),
  );
}

function matchesSubmissionFilters(
  submission: ApplicationInboxSubmission,
  filters: ApplicationInboxFilters,
): boolean {
  const submittedDate = submission.submittedAt.slice(0, 10);

  if (filters.status !== "ALL" && submission.status !== filters.status) {
    return false;
  }
  if (filters.newRead !== "ALL" && submission.status !== filters.newRead) {
    return false;
  }
  if (filters.dateFrom && submittedDate < filters.dateFrom) return false;
  if (filters.dateTo && submittedDate > filters.dateTo) return false;
  if (filters.application === "HAS_APPLICATION" && !submission.hasApplication) {
    return false;
  }
  if (filters.application === "NO_APPLICATION" && submission.hasApplication) {
    return false;
  }
  return true;
}

export function filterApplicationInboxGroups(
  groups: ApplicationInboxGroup[],
  filters: ApplicationInboxFilters,
): ApplicationInboxGroup[] {
  return groups.filter((group) => {
    const latest = latestSubmission(group);
    if (!matchesQuery(group, filters.query)) return false;
    if (
      filters.candidateActivity !== "ALL" &&
      (filters.candidateActivity === "ACTIVE") !== group.isCandidateActive
    ) {
      return false;
    }
    return matchesSubmissionFilters(latest, filters);
  });
}

export function paginateApplicationInboxGroups(
  groups: ApplicationInboxGroup[],
  requestedPage: number,
  pageSize: number,
) {
  const pageCount = Math.max(1, Math.ceil(groups.length / pageSize));
  const page = Math.min(Math.max(requestedPage, 1), pageCount);
  const start = (page - 1) * pageSize;

  return {
    groups: groups.slice(start, start + pageSize),
    page,
    pageCount,
  };
}
