import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { getServerSession } from "@/lib/auth/session";
import { createServerClient } from "@/lib/supabase/server";
import {
  type InterviewerReportPageData,
  parseInterviewerReportPageRpc,
  REPORT_FIELD_KEYS,
  type ReportFieldKey,
  type ReportFields,
} from "./model";

export class InterviewerReportAccessError extends Error {
  constructor(message = "Interviewer report access is required") {
    super(message);
  }
}

export class InterviewerReportReadError extends Error {
  constructor(message = "Interviewer report data could not be loaded") {
    super(message);
  }
}

export interface SaveInterviewerReportInput {
  interviewParticipantId: string;
  expectedVersionNo: number;
  patches: Partial<ReportFields>;
  baseValues: Partial<ReportFields>;
}

export type SaveInterviewerReportResult =
  | { success: true; data: { interviewReportId: string; versionNo: number } }
  | { success: false; error: { code: string; message: string } };

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function normalizeFieldMap(
  value: Partial<ReportFields>,
): Partial<Record<ReportFieldKey, string | null>> | null {
  const normalized: Partial<Record<ReportFieldKey, string | null>> = {};
  for (const [key, fieldValue] of Object.entries(value)) {
    if (!REPORT_FIELD_KEYS.includes(key as ReportFieldKey)) return null;
    if (fieldValue !== null && typeof fieldValue !== "string") return null;
    normalized[key as ReportFieldKey] = fieldValue;
  }
  return normalized;
}

function parseSaveResult(value: unknown): SaveInterviewerReportResult {
  if (!isRecord(value) || typeof value.success !== "boolean") {
    return {
      success: false,
      error: {
        code: "INVALID_RESPONSE",
        message: "Invalid report save response",
      },
    };
  }

  if (!value.success) {
    return {
      success: false,
      error: {
        code:
          typeof value.error_code === "string"
            ? value.error_code
            : "SAVE_FAILED",
        message:
          typeof value.message === "string"
            ? value.message
            : "Report could not be saved",
      },
    };
  }

  const data = value.data;
  if (
    !isRecord(data) ||
    typeof data.interview_report_id !== "string" ||
    typeof data.version_no !== "number"
  ) {
    return {
      success: false,
      error: {
        code: "INVALID_RESPONSE",
        message: "Invalid report save response",
      },
    };
  }

  return {
    success: true,
    data: {
      interviewReportId: data.interview_report_id,
      versionNo: data.version_no,
    },
  };
}

export async function loadInterviewerReportPage(
  client?: SupabaseClient,
): Promise<InterviewerReportPageData> {
  const supabase = client ?? (await createServerClient());
  const session = await getServerSession(supabase);
  if (!session.user?.isInternal || !session.user.appUserId) {
    throw new InterviewerReportAccessError();
  }

  const { data, error } = await supabase.rpc("get_interviewer_report_page");
  if (error) throw new InterviewerReportReadError();

  try {
    return parseInterviewerReportPageRpc(data);
  } catch (parseError) {
    if (
      parseError instanceof Error &&
      (parseError.message === "UNAUTHENTICATED" ||
        parseError.message === "FORBIDDEN" ||
        parseError.message === "USER_INACTIVE")
    ) {
      throw new InterviewerReportAccessError();
    }
    throw new InterviewerReportReadError();
  }
}

export async function saveOwnInterviewerReport(
  input: SaveInterviewerReportInput,
  client?: SupabaseClient,
): Promise<SaveInterviewerReportResult> {
  const supabase = client ?? (await createServerClient());
  const session = await getServerSession(supabase);
  if (!session.user?.isInternal || !session.user.appUserId) {
    return {
      success: false,
      error: {
        code: "UNAUTHENTICATED",
        message: "Authenticated internal user required",
      },
    };
  }

  if (
    !isUuid(input.interviewParticipantId) ||
    !Number.isSafeInteger(input.expectedVersionNo) ||
    input.expectedVersionNo < 1
  ) {
    return {
      success: false,
      error: { code: "VALIDATION_ERROR", message: "Invalid report request" },
    };
  }

  const patches = normalizeFieldMap(input.patches);
  const baseValues = normalizeFieldMap(input.baseValues);
  if (!patches || !baseValues) {
    return {
      success: false,
      error: { code: "VALIDATION_ERROR", message: "Invalid report fields" },
    };
  }

  const patchKeys = Object.keys(patches) as ReportFieldKey[];
  if (patchKeys.length === 0 || patchKeys.some((key) => !(key in baseValues))) {
    return {
      success: false,
      error: {
        code: "VALIDATION_ERROR",
        message: "Each patched field requires its base value",
      },
    };
  }

  const { data, error } = await supabase.rpc("save_own_interviewer_report", {
    p_interview_participant_id: input.interviewParticipantId,
    p_field_patches: patches,
    p_expected_version_no: input.expectedVersionNo,
    p_base_values: baseValues,
  });

  if (error) {
    return {
      success: false,
      error: { code: "SAVE_FAILED", message: "Report could not be saved" },
    };
  }

  return parseSaveResult(data);
}
