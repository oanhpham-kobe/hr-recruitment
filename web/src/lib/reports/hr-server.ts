import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { type AppSession, getServerSession } from "@/lib/auth/session";
import { createServerClient } from "@/lib/supabase/server";
import {
  HR_REPORT_STATUSES,
  type HrReportFilters,
  type HrReportPageData,
  normalizeHrReportFilters,
  parseHrReportPageRpc,
} from "./hr-model";
import { REPORT_FIELD_KEYS, type ReportFields } from "./model";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class HrReportAccessError extends Error {
  constructor() {
    super("HR Report access is required");
  }
}

export class HrReportReadError extends Error {
  constructor(message = "HR Report data could not be loaded") {
    super(message);
  }
}

export interface HrReportReadDeps {
  client?: SupabaseClient;
  resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
  filters?: Partial<HrReportFilters>;
}

export type HrReportCommandResult =
  | { success: true; data: Record<string, unknown> }
  | { success: false; error: { code: string; message?: string } };

export interface HrReportStatusInput {
  interviewId: string;
  status: (typeof HR_REPORT_STATUSES)[number];
  expectedVersionNo: number;
}

export interface BulkHrReportStatusInput {
  targets: Array<{ interviewId: string; expectedVersionNo: number }>;
  status: (typeof HR_REPORT_STATUSES)[number];
}

export interface HrReportVisibilityInput {
  interviewId: string;
  visible: boolean;
  expectedVersionNo: number;
}

export interface HrReportNoteInput {
  interviewId: string;
  note: string | null;
  expectedVersionNo: number;
}

export interface SaveHrParticipantReportInput {
  interviewParticipantId: string;
  expectedVersionNo: number;
  patches: Partial<ReportFields>;
  baseValues: Partial<ReportFields>;
}

export interface DeleteHrParticipantReportInput {
  interviewReportId: string;
  expectedVersionNo: number;
}

function canViewHrReports(session: AppSession): boolean {
  return Boolean(
    session.user?.isInternal &&
      (session.user.roles.includes("ROOT_ADMIN") ||
        session.user.permissions.includes("reports.view")),
  );
}

export function sessionUsesHrReportExperience(session: AppSession): boolean {
  return canViewHrReports(session);
}

function validUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

function validVersion(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 1;
}

function commandError(code: string, message?: string): HrReportCommandResult {
  return { success: false, error: { code, message } };
}

function normalizeCommandResponse(
  data: unknown,
  transportError: { message?: string } | null,
): HrReportCommandResult {
  if (transportError)
    return commandError("COMMAND_FAILED", transportError.message);
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return commandError("INVALID_RESPONSE");
  }
  const record = data as Record<string, unknown>;
  if (record.success === true) {
    const payload =
      record.data &&
      typeof record.data === "object" &&
      !Array.isArray(record.data)
        ? (record.data as Record<string, unknown>)
        : {};
    return { success: true, data: payload };
  }
  return commandError(
    typeof record.error_code === "string"
      ? record.error_code
      : "COMMAND_FAILED",
    typeof record.message === "string" ? record.message : undefined,
  );
}

async function authorizedClient(
  client?: SupabaseClient,
  resolveSession: (
    client: SupabaseClient,
  ) => Promise<AppSession> = getServerSession,
): Promise<SupabaseClient> {
  const resolved = client ?? (await createServerClient());
  const session = await resolveSession(resolved);
  if (!canViewHrReports(session)) throw new HrReportAccessError();
  return resolved;
}

export async function loadHrReportPage(
  deps: HrReportReadDeps = {},
): Promise<HrReportPageData> {
  const client = await authorizedClient(
    deps.client,
    deps.resolveSession ?? getServerSession,
  );
  const filters = normalizeHrReportFilters(deps.filters);
  const { data, error } = await client.rpc("get_hr_report_page", {
    p_page: filters.page,
    p_page_size: filters.pageSize,
    p_status_code: filters.status,
    p_visibility: filters.visibility,
    p_search: filters.search || null,
    p_sort: filters.sort,
  });
  if (error) throw new HrReportReadError(error.message);
  try {
    return parseHrReportPageRpc(data);
  } catch (cause) {
    throw new HrReportReadError(
      cause instanceof Error ? cause.message : undefined,
    );
  }
}

export async function changeHrReportStatus(
  input: HrReportStatusInput,
): Promise<HrReportCommandResult> {
  if (
    !validUuid(input.interviewId) ||
    !validVersion(input.expectedVersionNo) ||
    !HR_REPORT_STATUSES.includes(input.status)
  ) {
    return commandError("VALIDATION_ERROR");
  }
  const client = await authorizedClient();
  const { data, error } = await client.rpc("change_report_status", {
    p_interview_id: input.interviewId,
    p_report_status_code: input.status,
    p_expected_version: input.expectedVersionNo,
  });
  return normalizeCommandResponse(data, error);
}

export async function bulkChangeHrReportStatus(
  input: BulkHrReportStatusInput,
): Promise<HrReportCommandResult> {
  if (
    !Array.isArray(input.targets) ||
    input.targets.length < 1 ||
    input.targets.length > 100 ||
    !HR_REPORT_STATUSES.includes(input.status) ||
    input.targets.some(
      (target) =>
        !validUuid(target.interviewId) ||
        !validVersion(target.expectedVersionNo),
    ) ||
    new Set(input.targets.map((target) => target.interviewId)).size !==
      input.targets.length
  ) {
    return commandError("VALIDATION_ERROR");
  }
  const client = await authorizedClient();
  const { data, error } = await client.rpc("bulk_change_report_status", {
    p_interview_ids: input.targets.map((target) => target.interviewId),
    p_report_status_code: input.status,
    p_expected_versions: input.targets.map(
      (target) => target.expectedVersionNo,
    ),
  });
  return normalizeCommandResponse(data, error);
}

export async function setHrReportVisibility(
  input: HrReportVisibilityInput,
): Promise<HrReportCommandResult> {
  if (
    !validUuid(input.interviewId) ||
    !validVersion(input.expectedVersionNo) ||
    typeof input.visible !== "boolean"
  ) {
    return commandError("VALIDATION_ERROR");
  }
  const client = await authorizedClient();
  const { data, error } = await client.rpc("set_report_visibility", {
    p_interview_id: input.interviewId,
    p_visible_to_interviewers: input.visible,
    p_expected_version: input.expectedVersionNo,
  });
  return normalizeCommandResponse(data, error);
}

export async function updateHrReportNote(
  input: HrReportNoteInput,
): Promise<HrReportCommandResult> {
  if (
    !validUuid(input.interviewId) ||
    !validVersion(input.expectedVersionNo) ||
    (input.note !== null && typeof input.note !== "string")
  ) {
    return commandError("VALIDATION_ERROR");
  }
  const client = await authorizedClient();
  const { data, error } = await client.rpc("update_hr_report_note", {
    p_interview_id: input.interviewId,
    p_hr_report_note: input.note,
    p_expected_version: input.expectedVersionNo,
  });
  return normalizeCommandResponse(data, error);
}

function validReportPatch(value: Partial<ReportFields>): boolean {
  const entries = Object.entries(value);
  if (entries.length < 1) return false;
  return entries.every(
    ([key, fieldValue]) =>
      REPORT_FIELD_KEYS.includes(key as (typeof REPORT_FIELD_KEYS)[number]) &&
      (fieldValue === null || typeof fieldValue === "string"),
  );
}

export async function saveHrParticipantReport(
  input: SaveHrParticipantReportInput,
): Promise<HrReportCommandResult> {
  if (
    !validUuid(input.interviewParticipantId) ||
    !validVersion(input.expectedVersionNo) ||
    !validReportPatch(input.patches) ||
    Object.keys(input.patches).some((key) => !(key in input.baseValues)) ||
    !Object.values(input.baseValues).every(
      (value) => value === null || typeof value === "string",
    )
  ) {
    return commandError("VALIDATION_ERROR");
  }
  const client = await authorizedClient();
  const { data, error } = await client.rpc("save_interviewer_report", {
    p_interview_participant_id: input.interviewParticipantId,
    p_field_patches: input.patches,
    p_expected_version_no: input.expectedVersionNo,
    p_base_values: input.baseValues,
  });
  return normalizeCommandResponse(data, error);
}

export async function deleteHrParticipantReport(
  input: DeleteHrParticipantReportInput,
): Promise<HrReportCommandResult> {
  if (
    !validUuid(input.interviewReportId) ||
    !validVersion(input.expectedVersionNo)
  ) {
    return commandError("VALIDATION_ERROR");
  }
  const client = await authorizedClient();
  const { data, error } = await client.rpc("delete_or_inactivate_report", {
    p_interview_report_id: input.interviewReportId,
    p_expected_version: input.expectedVersionNo,
  });
  return normalizeCommandResponse(data, error);
}
