import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { createServerClient } from "@/lib/supabase/server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FINGERPRINT = /^[0-9a-f]{64}$/i;

export type InterviewEmailType =
  | "INTERVIEW_INVITATION"
  | "INTERVIEW_PARTICIPANT_INVITATION";

const EMAIL_TYPES = new Set<InterviewEmailType>([
  "INTERVIEW_INVITATION",
  "INTERVIEW_PARTICIPANT_INVITATION",
]);

export type EmailCommandError = { code: string; message: string };
export type EmailCommandResult<T> =
  | { success: true; data: T }
  | { success: false; error: EmailCommandError };

export interface EmailCommandDeps {
  client?: SupabaseClient;
}

export interface EmailPreviewInput {
  emailType: InterviewEmailType;
  interviewId: string;
  applicationId: string;
  submissionId: string;
}

export interface EmailPreviewData {
  recipients: { to: string[]; cc: string[] };
  subject: string;
  body_text: string;
  template_version: string;
  environment_code: "TEST" | "PRODUCTION";
  context_fingerprint: string;
  preview_fingerprint: string;
  email_type: InterviewEmailType;
  interview_id: string;
  application_id: string;
  submission_id: string;
}

export interface EmailEnqueueInput {
  email_type: InterviewEmailType;
  interview_id: string;
  application_id: string;
  submission_id: string;
  preview_fingerprint: string;
}

export interface BulkEmailItemResult {
  id: string;
  email_type?: InterviewEmailType;
  application_id?: string;
  submission_id?: string;
  email_outbox_id?: string;
  error_code?: string;
}

export interface BulkEmailResult {
  success: BulkEmailItemResult[];
  failed: BulkEmailItemResult[];
}

export type EmailHistoryStatus = "SENT" | "FAILED" | "CANCELLED" | "ABANDONED";
const HISTORY_STATUSES = new Set<EmailHistoryStatus>([
  "SENT",
  "FAILED",
  "CANCELLED",
  "ABANDONED",
]);

export interface EmailHistoryEntry {
  email_history_id: string;
  interview_id: string;
  email_type: string;
  environment_code: "TEST" | "PRODUCTION";
  recipients: { to?: string[]; cc?: string[] } | string[];
  subject: string | null;
  template_version: string | null;
  sent_at: string | null;
  created_at: string;
  status_code: EmailHistoryStatus;
  error_code: string | null;
}

function messageFor(code: string): string {
  const messages: Record<string, string> = {
    FORBIDDEN: "Bạn không có quyền thực hiện thao tác email này.",
    VALIDATION_ERROR: "Dữ liệu email chưa hợp lệ.",
    BATCH_LIMIT_EXCEEDED: "Danh sách email vượt giới hạn cho phép.",
    UNSUPPORTED_EMAIL_TYPE: "Loại email không được hỗ trợ.",
    INVALID_EMAIL_CONTEXT: "Ngữ cảnh email không hợp lệ.",
    EMAIL_RECIPIENTS_UNAVAILABLE: "Không có địa chỉ email người nhận hợp lệ.",
    CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED:
      "Có người tham dự hiện tại đã ngừng hoạt động. Vui lòng thay thế trước khi gửi.",
    PREVIEW_REQUIRED: "Vui lòng xem trước email trước khi gửi.",
    STALE_PREVIEW:
      "Thông tin phỏng vấn đã thay đổi, vui lòng xem lại bản xem trước.",
    IDEMPOTENCY_CONFLICT: "Yêu cầu gửi bị trùng khóa với nội dung khác.",
    INVALID_CLEANUP_CLASSIFICATION:
      "Phân loại hoặc lý do xóa Email History không hợp lệ.",
  };
  return (
    messages[code] ?? "Không thể hoàn tất thao tác email. Vui lòng thử lại."
  );
}

function invalid(message: string): EmailCommandResult<never> {
  return { success: false, error: { code: "VALIDATION_ERROR", message } };
}

async function clientFor(deps: EmailCommandDeps): Promise<SupabaseClient> {
  return deps.client ?? (await createServerClient());
}

function rpcResult<T>(data: unknown): EmailCommandResult<T> {
  const result = data as {
    success?: boolean;
    error_code?: unknown;
    data?: T;
  } | null;
  if (!result?.success || result.data === undefined) {
    const code =
      typeof result?.error_code === "string"
        ? result.error_code
        : "INTERNAL_ERROR";
    return { success: false, error: { code, message: messageFor(code) } };
  }
  return { success: true, data: result.data };
}

function bulkRpcResult(data: unknown): EmailCommandResult<BulkEmailResult> {
  const result = data as {
    success?: unknown;
    failed?: unknown;
    error_code?: unknown;
  } | null;
  if (Array.isArray(result?.success) && Array.isArray(result?.failed)) {
    return {
      success: true,
      data: {
        success: result.success as BulkEmailItemResult[],
        failed: result.failed as BulkEmailItemResult[],
      },
    };
  }
  const code =
    typeof result?.error_code === "string"
      ? result.error_code
      : "INTERNAL_ERROR";
  return { success: false, error: { code, message: messageFor(code) } };
}

function validContext(input: EmailPreviewInput): boolean {
  return (
    EMAIL_TYPES.has(input.emailType) &&
    UUID.test(input.interviewId) &&
    UUID.test(input.applicationId) &&
    UUID.test(input.submissionId)
  );
}

function validRequest(input: EmailEnqueueInput): boolean {
  return (
    EMAIL_TYPES.has(input.email_type) &&
    UUID.test(input.interview_id) &&
    UUID.test(input.application_id) &&
    UUID.test(input.submission_id) &&
    FINGERPRINT.test(input.preview_fingerprint)
  );
}

export async function previewInterviewEmail(
  input: EmailPreviewInput,
  deps: EmailCommandDeps = {},
): Promise<EmailCommandResult<EmailPreviewData>> {
  if (!validContext(input))
    return invalid(
      "Interview, Application, Submission hoặc loại email không hợp lệ.",
    );
  const client = await clientFor(deps);
  const { data, error } = await client.rpc("preview_email", {
    p_email_type: input.emailType,
    p_interview_id: input.interviewId,
    p_application_id: input.applicationId,
    p_submission_id: input.submissionId,
  });
  if (error) {
    console.error("[email-command] preview_email RPC error", error.message);
    return {
      success: false,
      error: { code: "INTERNAL_ERROR", message: messageFor("INTERNAL_ERROR") },
    };
  }
  return rpcResult<EmailPreviewData>(data);
}

export async function enqueueInterviewEmail(
  input: EmailEnqueueInput,
  idempotencyKey: string,
  deps: EmailCommandDeps = {},
): Promise<EmailCommandResult<{ email_outbox_id: string }>> {
  if (!validRequest(input) || !UUID.test(idempotencyKey))
    return invalid(
      "Email request, preview fingerprint hoặc idempotency key không hợp lệ.",
    );
  const client = await clientFor(deps);
  const request = {
    email_type: input.email_type,
    interview_id: input.interview_id,
    application_id: input.application_id,
    submission_id: input.submission_id,
    preview_fingerprint: input.preview_fingerprint,
  };
  const { data, error } = await client.rpc("enqueue_email", {
    p_request: request,
    p_idempotency_key: idempotencyKey,
  });
  if (error) {
    console.error("[email-command] enqueue_email RPC error", error.message);
    return {
      success: false,
      error: { code: "INTERNAL_ERROR", message: messageFor("INTERNAL_ERROR") },
    };
  }
  return rpcResult<{ email_outbox_id: string }>(data);
}

export async function bulkEnqueueInterviewEmails(
  requests: EmailEnqueueInput[],
  idempotencyKey: string,
  deps: EmailCommandDeps = {},
): Promise<EmailCommandResult<BulkEmailResult>> {
  if (
    requests.length < 1 ||
    requests.length > 100 ||
    requests.some((request) => !validRequest(request)) ||
    !UUID.test(idempotencyKey)
  )
    return invalid(
      "Danh sách email phải có 1–100 request hợp lệ và đã được preview.",
    );
  const client = await clientFor(deps);
  const { data, error } = await client.rpc("bulk_enqueue_email", {
    p_requests: requests.map((request) => ({
      email_type: request.email_type,
      interview_id: request.interview_id,
      application_id: request.application_id,
      submission_id: request.submission_id,
      preview_fingerprint: request.preview_fingerprint,
    })),
    p_idempotency_key: idempotencyKey,
  });
  if (error) {
    console.error(
      "[email-command] bulk_enqueue_email RPC error",
      error.message,
    );
    return {
      success: false,
      error: { code: "INTERNAL_ERROR", message: messageFor("INTERNAL_ERROR") },
    };
  }
  return bulkRpcResult(data);
}

export async function deleteEmailHistoryEntry(
  emailHistoryId: string,
  classification: "TEST_RECORD" | "WRONG_RECORD",
  reason: string | null,
  deps: EmailCommandDeps = {},
): Promise<EmailCommandResult<{ email_history_id: string }>> {
  const normalizedReason = reason?.trim() || null;
  if (!UUID.test(emailHistoryId))
    return invalid("Email history ID không hợp lệ.");
  if (classification !== "TEST_RECORD" && classification !== "WRONG_RECORD")
    return invalid("Phân loại xóa không hợp lệ.");
  if (classification === "WRONG_RECORD" && !normalizedReason)
    return invalid("WRONG_RECORD yêu cầu lý do xóa.");
  if ((normalizedReason?.length ?? 0) > 1000)
    return invalid("Lý do xóa tối đa 1000 ký tự.");

  const client = await clientFor(deps);
  const { data, error } = await client.rpc("delete_email_history", {
    p_email_history_id: emailHistoryId,
    p_classification: classification,
    p_reason: normalizedReason,
  });
  if (error) {
    console.error(
      "[email-command] delete_email_history RPC error",
      error.message,
    );
    return {
      success: false,
      error: { code: "INTERNAL_ERROR", message: messageFor("INTERNAL_ERROR") },
    };
  }
  return rpcResult<{ email_history_id: string }>(data);
}

export async function loadInterviewEmailHistory(
  interviewId: string,
  deps: EmailCommandDeps = {},
): Promise<EmailCommandResult<EmailHistoryEntry[]>> {
  if (!UUID.test(interviewId)) return invalid("Interview ID không hợp lệ.");
  const client = await clientFor(deps);
  const { data, error } = await client
    .from("email_history")
    .select(
      "email_history_id,interview_id,email_type,environment_code,recipients,subject,template_version,sent_at,created_at,status_code,error_code",
    )
    .eq("interview_id", interviewId)
    .order("created_at", { ascending: false });
  if (error) {
    console.error("[email-command] email_history query error", error.message);
    return {
      success: false,
      error: { code: "INTERNAL_ERROR", message: messageFor("INTERNAL_ERROR") },
    };
  }
  const rows = (data ?? []) as EmailHistoryEntry[];
  if (rows.some((row) => !HISTORY_STATUSES.has(row.status_code))) {
    return {
      success: false,
      error: {
        code: "INTERNAL_ERROR",
        message: "Email History chứa trạng thái ngoài contract đã chấp nhận.",
      },
    };
  }
  return { success: true, data: rows };
}
