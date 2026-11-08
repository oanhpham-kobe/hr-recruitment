import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { type AppSession, getServerSession } from "@/lib/auth/session";
import {
  createOrUpdateApplication,
  updateSubmissionByHr,
} from "@/lib/commands/application-lifecycle";
import {
  createDriveTransport,
  driveLocation,
  driveServerConfig,
  driveServerRpc,
} from "@/lib/storage/drive-gateway";
import type { DriveTransport } from "@/lib/storage/drive-protocol";
import { createAdminClient } from "@/lib/supabase/admin";
import { createServerClient } from "@/lib/supabase/server";
import {
  type AssignmentOptions,
  DOCUMENT_SIGNED_URL_TTL_SECONDS,
  isPreviewableDocument,
  type SubmissionDetail,
} from "./submission-detail-model";

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class SubmissionDetailAccessError extends Error {
  constructor(
    message = "Bạn không có quyền xem thông tin chi tiết phiếu ứng tuyển.",
  ) {
    super(message);
    this.name = "SubmissionDetailAccessError";
  }
}

export class SubmissionDetailNotFoundError extends Error {
  constructor(message = "Không tìm thấy phiếu ứng tuyển.") {
    super(message);
    this.name = "SubmissionDetailNotFoundError";
  }
}

export class SubmissionDetailReadError extends Error {
  constructor(
    message = "Không thể tải chi tiết phiếu ứng tuyển. Vui lòng thử lại.",
  ) {
    super(message);
    this.name = "SubmissionDetailReadError";
  }
}

export class DocumentNotPreviewableError extends Error {
  constructor(
    message = "Tài liệu không hỗ trợ xem trực tuyến. Vui lòng tải xuống để xem.",
  ) {
    super(message);
    this.name = "DocumentNotPreviewableError";
  }
}

export interface SubmissionDetailDeps {
  client?: SupabaseClient;
  adminClient?: SupabaseClient | null;
  resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
}

export function isAuthorizedForSubmissionDetail(
  session: AppSession,
  isRootAdmin: boolean,
): boolean {
  return Boolean(
    session.user?.isInternal &&
      (isRootAdmin || session.user.permissions.includes("submissions.view")),
  );
}

export function isAuthorizedForApplicationCreate(
  session: AppSession,
  isRootAdmin: boolean,
): boolean {
  if (!session.user?.isInternal) return false;
  if (isRootAdmin) return true;
  const hasView = session.user.permissions.includes("submissions.view");
  const hasManage =
    session.user.permissions.includes("applications.create") ||
    session.user.permissions.includes("applications.manage");
  return hasView && hasManage;
}

export async function loadSubmissionDetail(
  submissionId: string,
  deps: SubmissionDetailDeps = {},
): Promise<SubmissionDetail> {
  if (!submissionId || !UUID_REGEX.test(submissionId)) {
    throw new SubmissionDetailNotFoundError();
  }

  const supabase = deps.client ?? (await createServerClient());
  const session = await (deps.resolveSession ?? getServerSession)(supabase);

  if (!session.user?.isInternal) {
    throw new SubmissionDetailAccessError();
  }

  const isRootAdmin = session.user.roles.includes("ROOT_ADMIN");

  if (!isAuthorizedForSubmissionDetail(session, isRootAdmin)) {
    throw new SubmissionDetailAccessError();
  }

  const { data, error } = await supabase.rpc("get_submission_detail", {
    p_submission_id: submissionId,
  });

  if (error) {
    throw new SubmissionDetailReadError(error.message);
  }

  const result = data as {
    success: boolean;
    error_code?: string;
    message?: string;
    data?: SubmissionDetail;
  };

  if (!result?.success || !result.data) {
    if (result?.error_code === "FORBIDDEN") {
      throw new SubmissionDetailAccessError(result.message);
    }
    if (result?.error_code === "NOT_FOUND") {
      throw new SubmissionDetailNotFoundError(result.message);
    }
    throw new SubmissionDetailReadError(result?.message);
  }

  return result.data;
}

export async function generateDocumentSignedUrl(
  options: {
    submissionId: string;
    documentId: string;
    logicalDocumentId: string;
    mode: "preview" | "download";
  },
  deps: SubmissionDetailDeps = {},
): Promise<{
  signedUrl: string;
  originalFilename: string;
  mimeType: string;
  transport?: DriveTransport;
}> {
  const { submissionId, documentId, logicalDocumentId, mode } = options;

  if (
    !submissionId ||
    !UUID_REGEX.test(submissionId) ||
    !documentId ||
    !UUID_REGEX.test(documentId) ||
    !logicalDocumentId ||
    !UUID_REGEX.test(logicalDocumentId)
  ) {
    throw new SubmissionDetailNotFoundError("Thông tin tài liệu không hợp lệ.");
  }

  const supabase = deps.client ?? (await createServerClient());
  const session = await (deps.resolveSession ?? getServerSession)(supabase);

  if (!session.user?.isInternal) {
    throw new SubmissionDetailAccessError();
  }

  const isRootAdmin = session.user.roles.includes("ROOT_ADMIN");

  if (!isAuthorizedForSubmissionDetail(session, isRootAdmin)) {
    throw new SubmissionDetailAccessError();
  }

  // Query document record
  const { data: doc, error: docError } = await supabase
    .from("submission_documents")
    .select(
      "document_id, logical_document_id, storage_bucket, storage_path, original_filename, mime_type",
    )
    .eq("document_id", documentId)
    .single();

  if (docError || !doc) {
    throw new SubmissionDetailNotFoundError("Không tìm thấy tài liệu.");
  }

  if (doc.logical_document_id !== logicalDocumentId) {
    throw new SubmissionDetailNotFoundError("Tài liệu không khớp.");
  }

  // Validate preview eligibility
  if (mode === "preview" && !isPreviewableDocument(doc.mime_type)) {
    throw new DocumentNotPreviewableError();
  }

  if (
    driveServerConfig() &&
    (await driveLocation(doc.storage_bucket, doc.storage_path))
  ) {
    // The narrow command checks current context/CLEAN and commits access audit
    // before minting. The byte gateway repeats it on every redemption.
    await driveServerRpc("authorize_drive_document_read", {
      p_actor_auth_user_id: session.user.authUserId,
      p_submission_id: submissionId,
      p_logical_document_id: logicalDocumentId,
      p_document_id: documentId,
      p_purpose: mode,
    });
    const transport = await createDriveTransport({
      actor: session.user.authUserId,
      purpose: mode,
      submissionId,
      logicalDocumentId,
      documentId,
      filename: doc.original_filename,
      mimeType: doc.mime_type,
    });
    return {
      signedUrl: "",
      originalFilename: doc.original_filename,
      mimeType: doc.mime_type,
      transport,
    };
  }

  // Mandatory Security Audit Logging via RPC FIRST:
  // Must succeed before generating or returning signed document access
  const { data: auditData, error: auditError } = await supabase.rpc(
    "record_document_access_audit",
    {
      p_submission_id: submissionId,
      p_logical_document_id: logicalDocumentId,
      p_document_id: documentId,
    },
  );

  const auditResult = auditData as {
    success?: boolean;
    error_code?: string;
    message?: string;
  } | null;

  if (auditError || !auditResult?.success) {
    throw new SubmissionDetailReadError(
      auditResult?.message || "Không thể ghi nhật ký truy cập tài liệu.",
    );
  }

  // Obtain administrative client for signed URL generation on quarantine bucket
  const adminClient =
    deps.adminClient !== undefined ? deps.adminClient : createAdminClient();
  const signingClient = adminClient ?? (deps.client ? deps.client : null);
  if (!signingClient) {
    throw new SubmissionDetailReadError(
      "Không thể khởi tạo client quản trị để tạo liên kết tài liệu.",
    );
  }

  // Generate short-lived signed URL with strictly bounded TTL [60s, 300s]
  const { data: signedData, error: signedError } = await signingClient.storage
    .from(doc.storage_bucket)
    .createSignedUrl(
      doc.storage_path,
      DOCUMENT_SIGNED_URL_TTL_SECONDS,
      mode === "download" ? { download: doc.original_filename } : undefined,
    );

  if (signedError || !signedData?.signedUrl) {
    throw new SubmissionDetailReadError("Không thể tạo liên kết tải tài liệu.");
  }
  return {
    signedUrl: signedData.signedUrl,
    originalFilename: doc.original_filename,
    mimeType: doc.mime_type,
  };
}

export async function getDocumentPreviewStream(
  options: {
    documentId: string;
    submissionId?: string;
    logicalDocumentId?: string;
  },
  deps: SubmissionDetailDeps & { fetchFn?: typeof fetch } = {},
): Promise<{
  stream: ReadableStream<Uint8Array>;
  mimeType: string;
  filename: string;
}> {
  const { documentId } = options;
  if (!documentId || !UUID_REGEX.test(documentId)) {
    throw new SubmissionDetailNotFoundError("Thông tin tài liệu không hợp lệ.");
  }

  const supabase = deps.client ?? (await createServerClient());
  let submissionId = options.submissionId;
  let logicalDocumentId = options.logicalDocumentId;

  if (!submissionId || !logicalDocumentId) {
    const { data: docRecord, error: docRecordError } = await supabase
      .from("submission_documents")
      .select("logical_document_id")
      .eq("document_id", documentId)
      .maybeSingle();

    if (docRecordError || !docRecord) {
      throw new SubmissionDetailNotFoundError("Không tìm thấy tài liệu.");
    }
    logicalDocumentId = docRecord.logical_document_id;

    const { data: logicalRecord, error: logicalRecordError } = await supabase
      .from("submission_document_logicals")
      .select("submission_id")
      .eq("logical_document_id", logicalDocumentId)
      .maybeSingle();

    if (logicalRecordError || !logicalRecord) {
      throw new SubmissionDetailNotFoundError(
        "Không tìm thấy phiếu ứng tuyển cho tài liệu.",
      );
    }
    submissionId = logicalRecord.submission_id;
  }

  if (!submissionId || !logicalDocumentId) {
    throw new SubmissionDetailNotFoundError("Không tìm thấy tài liệu.");
  }
  // Re-authenticates, authorizes submissions.view/root, checks preview eligibility,
  // logs access audit fail-closed, and creates signed URL with strictly 60–300s TTL
  const { signedUrl, originalFilename, mimeType, transport } =
    await generateDocumentSignedUrl(
      {
        submissionId,
        documentId,
        logicalDocumentId,
        mode: "preview",
      },
      deps,
    );
  if (transport)
    throw new SubmissionDetailReadError(
      "Use authenticated direct gateway transport for this document.",
    );

  // Stream bytes from signed URL on server side; never expose signed URL to browser
  let response: Response;
  const fetchFn = deps.fetchFn ?? fetch;
  try {
    response = await fetchFn(signedUrl);
  } catch {
    throw new SubmissionDetailReadError(
      "Không thể tải nội dung tài liệu từ lưu trữ.",
    );
  }

  if (!response.ok || !response.body) {
    throw new SubmissionDetailReadError(
      "Không thể tải nội dung tài liệu từ lưu trữ.",
    );
  }

  return {
    stream: response.body as ReadableStream<Uint8Array>,
    mimeType,
    filename: originalFilename,
  };
}

export async function loadAssignmentOptions(
  deps: SubmissionDetailDeps = {},
): Promise<AssignmentOptions> {
  const supabase = deps.client ?? (await createServerClient());
  const session = await (deps.resolveSession ?? getServerSession)(supabase);

  if (!session.user?.isInternal) {
    throw new SubmissionDetailAccessError();
  }

  const isRootAdmin = session.user.roles.includes("ROOT_ADMIN");

  if (!isAuthorizedForApplicationCreate(session, isRootAdmin)) {
    throw new SubmissionDetailAccessError(
      "Bạn không có quyền tạo hoặc gán Application.",
    );
  }

  const { data, error } = await supabase.rpc(
    "get_application_assignment_options",
  );

  if (error) {
    throw new SubmissionDetailReadError(error.message);
  }

  const result = data as {
    success: boolean;
    error_code?: string;
    message?: string;
    data?: AssignmentOptions;
  };

  if (!result?.success || !result.data) {
    throw new SubmissionDetailReadError(
      result?.message || "Không thể tải danh sách chọn vị trí.",
    );
  }

  return result.data;
}

export async function saveSubmissionHrNote(
  submissionId: string,
  hrNote: string | null,
  expectedVersion: number,
  deps: SubmissionDetailDeps = {},
) {
  const supabase = deps.client ?? (await createServerClient());
  return updateSubmissionByHr(
    {
      submissionId,
      hrNote,
      expectedVersion,
    },
    { client: supabase },
  );
}

export async function createSubmissionApplication(
  input: {
    submissionId: string;
    unitId: string;
    departmentTeamId?: string;
    positionId: string;
    hrOwnerId: string;
    idempotencyKey?: string;
    confirmDuplicate?: boolean;
  },
  deps: SubmissionDetailDeps = {},
) {
  const supabase = deps.client ?? (await createServerClient());
  return createOrUpdateApplication(input, { client: supabase });
}
