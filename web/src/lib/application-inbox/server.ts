import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { type AppSession, getServerSession } from "@/lib/auth/session";
import { createServerClient } from "@/lib/supabase/server";
import {
  type ApplicationInboxFilters,
  type ApplicationInboxGroup,
  type ApplicationInboxSubmission,
  normalizeApplicationInboxPageSize,
  projectApplicationInboxGroups,
  type SubmissionStatus,
} from "./model";

const MAX_SEARCH_LENGTH = 256;

export class ApplicationInboxAccessError extends Error {
  constructor() {
    super("Application Inbox access is required");
  }
}

export class ApplicationInboxReadError extends Error {
  constructor() {
    super("Application Inbox could not be loaded");
  }
}

interface InboxRow {
  submission_id: unknown;
  submission_version_no?: unknown;
  candidate_id: unknown;
  status_code: unknown;
  full_name: unknown;
  date_of_birth: unknown;
  gender_code: unknown;
  phone: unknown;
  hr_note: unknown;
  submitted_at: unknown;
  email: unknown;
  is_candidate_active: unknown;
  candidate_version_no?: unknown;
  latest_submission_id?: unknown;
  latest_submission_version_no?: unknown;
  has_application: unknown;
  total_count: unknown;
}

export interface ApplicationInboxReadDeps {
  client?: SupabaseClient;
  filters?: Partial<ApplicationInboxFilters>;
  page?: number;
  pageSize?: number;
  resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
}

export interface ApplicationInboxReadResult {
  groups: ApplicationInboxGroup[];
  page: number;
  pageCount: number;
}

function submissionStatus(value: unknown): SubmissionStatus {
  return value === "NEW" ||
    value === "READ" ||
    value === "PROCESSED" ||
    value === "DONE" ||
    value === "CLOSED"
    ? value
    : "READ";
}

function isOneOf<T extends string>(
  value: unknown,
  values: readonly T[],
): value is T {
  return typeof value === "string" && values.includes(value as T);
}

export function normalizeApplicationInboxFilters(
  input: Partial<ApplicationInboxFilters> | undefined,
): ApplicationInboxFilters {
  return {
    query:
      typeof input?.query === "string"
        ? input.query.trim().slice(0, MAX_SEARCH_LENGTH)
        : "",
    status: isOneOf(input?.status, [
      "ALL",
      "NEW",
      "READ",
      "PROCESSED",
      "DONE",
      "CLOSED",
    ] as const)
      ? input.status
      : "ALL",
    dateFrom:
      typeof input?.dateFrom === "string" &&
      /^\d{4}-\d{2}-\d{2}$/.test(input.dateFrom)
        ? input.dateFrom
        : "",
    dateTo:
      typeof input?.dateTo === "string" &&
      /^\d{4}-\d{2}-\d{2}$/.test(input.dateTo)
        ? input.dateTo
        : "",
    candidateActivity: isOneOf(input?.candidateActivity, [
      "ALL",
      "ACTIVE",
      "INACTIVE",
    ] as const)
      ? input.candidateActivity
      : "ALL",
    newRead: isOneOf(input?.newRead, ["ALL", "NEW", "READ"] as const)
      ? input.newRead
      : "ALL",
    application: isOneOf(input?.application, [
      "ALL",
      "HAS_APPLICATION",
      "NO_APPLICATION",
    ] as const)
      ? input.application
      : "ALL",
  };
}

function mapInboxRow(row: InboxRow): {
  submission: ApplicationInboxSubmission;
  email: string;
  isActive: boolean;
  candidateVersionNo: number;
  latestSubmissionId: string;
  latestSubmissionVersionNo: number;
} | null {
  if (
    typeof row.email !== "string" ||
    typeof row.submission_id !== "string" ||
    typeof row.candidate_id !== "string" ||
    typeof row.full_name !== "string" ||
    typeof row.submitted_at !== "string"
  )
    return null;

  const versionNo =
    typeof row.submission_version_no === "number"
      ? row.submission_version_no
      : 1;
  const candidateVersionNo =
    typeof row.candidate_version_no === "number" ? row.candidate_version_no : 1;
  const latestSubmissionId =
    typeof row.latest_submission_id === "string"
      ? row.latest_submission_id
      : row.submission_id;
  const latestSubmissionVersionNo =
    typeof row.latest_submission_version_no === "number"
      ? row.latest_submission_version_no
      : versionNo;

  return {
    submission: {
      submissionId: row.submission_id,
      candidateId: row.candidate_id,
      status: submissionStatus(row.status_code),
      fullName: row.full_name,
      dateOfBirth:
        typeof row.date_of_birth === "string" ? row.date_of_birth : null,
      gender:
        row.gender_code === "MALE" || row.gender_code === "FEMALE"
          ? row.gender_code
          : null,
      phone: typeof row.phone === "string" ? row.phone : null,
      hrNote: typeof row.hr_note === "string" ? row.hr_note : null,
      submittedAt: row.submitted_at,
      hasApplication: row.has_application === true,
      versionNo,
    },
    email: row.email,
    isActive: row.is_candidate_active === true,
    candidateVersionNo,
    latestSubmissionId,
    latestSubmissionVersionNo,
  };
}

export function isAuthorizedForApplicationInbox(
  session: AppSession,
  isRootAdmin: boolean,
): boolean {
  return Boolean(
    session.user?.isInternal &&
      (isRootAdmin || session.user.permissions.includes("submissions.view")),
  );
}

export async function loadApplicationInbox(
  deps: ApplicationInboxReadDeps = {},
): Promise<ApplicationInboxReadResult> {
  const supabase = deps.client ?? (await createServerClient());
  const session = await (deps.resolveSession ?? getServerSession)(supabase);
  if (!session.user?.isInternal) throw new ApplicationInboxAccessError();

  const isRootAdmin = session.user.roles.includes("ROOT_ADMIN");
  if (!isAuthorizedForApplicationInbox(session, isRootAdmin))
    throw new ApplicationInboxAccessError();

  const filters = normalizeApplicationInboxFilters(deps.filters);
  const pageSize = normalizeApplicationInboxPageSize(deps.pageSize);
  const requestedPage =
    typeof deps.page === "number" &&
    Number.isSafeInteger(deps.page) &&
    deps.page > 0
      ? deps.page
      : 1;
  const { data, error } = await supabase.rpc("list_application_inbox", {
    p_query: filters.query,
    p_status: filters.status,
    p_date_from: filters.dateFrom || null,
    p_date_to: filters.dateTo || null,
    p_candidate_activity: filters.candidateActivity,
    p_new_read: filters.newRead,
    p_application: filters.application,
    p_page: requestedPage,
    p_page_size: pageSize,
  });
  if (error || !Array.isArray(data)) throw new ApplicationInboxReadError();

  const rows = data as InboxRow[];
  const totalCount =
    typeof rows[0]?.total_count === "number" ? rows[0].total_count : 0;
  const pageCount = Math.max(1, Math.ceil(totalCount / pageSize));
  const details = new Map<
    string,
    {
      email: string;
      isActive: boolean;
      candidateVersionNo: number;
      latestSubmissionId: string;
      latestSubmissionVersionNo: number;
    }
  >();
  const submissions = rows.map(mapInboxRow).filter(
    (
      value,
    ): value is {
      submission: ApplicationInboxSubmission;
      email: string;
      isActive: boolean;
      candidateVersionNo: number;
      latestSubmissionId: string;
      latestSubmissionVersionNo: number;
    } => value !== null,
  );
  for (const row of submissions)
    details.set(row.submission.candidateId, {
      email: row.email,
      isActive: row.isActive,
      candidateVersionNo: row.candidateVersionNo,
      latestSubmissionId: row.latestSubmissionId,
      latestSubmissionVersionNo: row.latestSubmissionVersionNo,
    });

  return {
    groups: projectApplicationInboxGroups(
      submissions.map((row) => row.submission),
    ).map((group) => {
      const candidateDetails = details.get(group.candidateId);
      return {
        ...group,
        email: candidateDetails?.email ?? "",
        isCandidateActive: candidateDetails?.isActive ?? false,
        candidateVersionNo:
          candidateDetails?.candidateVersionNo ?? group.candidateVersionNo,
        latestSubmissionId:
          candidateDetails?.latestSubmissionId ?? group.latestSubmissionId,
        latestSubmissionVersionNo:
          candidateDetails?.latestSubmissionVersionNo ??
          group.latestSubmissionVersionNo,
      };
    }),
    page: Math.min(requestedPage, pageCount),
    pageCount,
  };
}
