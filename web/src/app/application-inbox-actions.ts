"use server";

import {
  type ApplicationInboxFilters,
  type ApplicationInboxPageSize,
  normalizeApplicationInboxPageSize,
} from "@/lib/application-inbox/model";
import {
  type ApplicationInboxReadResult,
  loadApplicationInbox,
} from "@/lib/application-inbox/server";
import {
  type AssignmentOptions,
  isPreviewableDocument,
  type SubmissionDetail,
} from "@/lib/application-inbox/submission-detail-model";
import {
  DocumentNotPreviewableError,
  generateDocumentSignedUrl,
  loadAssignmentOptions,
  loadSubmissionDetail,
  SubmissionDetailAccessError,
  SubmissionDetailNotFoundError,
  saveSubmissionHrNote,
} from "@/lib/application-inbox/submission-detail-server";
import {
  type CreateOrUpdateApplicationData,
  createOrUpdateApplication,
  type UpdateSubmissionByHrData,
} from "@/lib/commands/application-lifecycle";
import {
  type BulkSetCandidateActiveData,
  bulkSetCandidateActive,
  type SetCandidateActiveData,
  setCandidateActive,
} from "@/lib/commands/candidate-lifecycle";
import {
  type BulkSetLatestSubmissionManualStatusData,
  bulkSetLatestSubmissionManualStatus,
  type OpenSubmissionData,
  openSubmission,
  type SubmissionStatusCommandDeps,
  type UpdateSubmissionAggregateData,
  type UpdateSubmissionAggregateInput,
  updateSubmissionAggregateByHr,
} from "@/lib/commands/submission-status";
import { driveServerConfig } from "@/lib/storage/drive-gateway";
import type { DriveTransport } from "@/lib/storage/drive-protocol";
import { createServerClient } from "@/lib/supabase/server";

export async function queryApplicationInbox(input: {
  filters: ApplicationInboxFilters;
  page: number;
  pageSize: ApplicationInboxPageSize;
}): Promise<ApplicationInboxReadResult> {
  return loadApplicationInbox({
    filters: input.filters,
    page: input.page,
    pageSize: normalizeApplicationInboxPageSize(input.pageSize),
  });
}

export async function getSubmissionDetailAction(
  submissionId: string,
): Promise<
  | { success: true; data: SubmissionDetail }
  | { success: false; error: string; code?: string }
> {
  try {
    const detail = await loadSubmissionDetail(submissionId);
    return { success: true, data: detail };
  } catch (error) {
    if (error instanceof SubmissionDetailAccessError) {
      return { success: false, error: error.message, code: "FORBIDDEN" };
    }
    if (error instanceof SubmissionDetailNotFoundError) {
      return { success: false, error: error.message, code: "NOT_FOUND" };
    }
    return {
      success: false,
      error:
        error instanceof Error
          ? error.message
          : "Không thể tải thông tin chi tiết phiếu ứng tuyển.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function openSubmissionAction(
  submissionId: string,
  deps: SubmissionStatusCommandDeps = {},
): Promise<
  | { success: true; data: OpenSubmissionData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await openSubmission({ submissionId }, deps);
    if (!result.success) {
      return {
        success: false,
        error: result.error?.message ?? "Không thể mở phiếu ứng tuyển.",
        code: result.error?.code,
      };
    }
    return { success: true, data: result.data };
  } catch (error) {
    return {
      success: false,
      error:
        error instanceof Error
          ? error.message
          : "Không thể mở phiếu ứng tuyển.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function updateSubmissionAggregateAction(
  input: UpdateSubmissionAggregateInput,
  deps: SubmissionStatusCommandDeps = {},
): Promise<
  | { success: true; data: UpdateSubmissionAggregateData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await updateSubmissionAggregateByHr(input, deps);
    if (!result.success) {
      return {
        success: false,
        error:
          result.error?.message ??
          "Không thể cập nhật thông tin phiếu ứng tuyển.",
        code: result.error?.code,
      };
    }
    return { success: true, data: result.data };
  } catch (error) {
    return {
      success: false,
      error:
        error instanceof Error
          ? error.message
          : "Không thể cập nhật thông tin phiếu ứng tuyển.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function getRecruitmentSourcesAction(): Promise<
  Array<{ recruitment_source_id: string; code: string; name_vi: string }>
> {
  const supabase = await createServerClient();
  const { data } = await supabase
    .from("recruitment_sources")
    .select("recruitment_source_id, code, name_vi")
    .eq("is_active", true)
    .order("name_vi", { ascending: true });
  return (
    (data as Array<{
      recruitment_source_id: string;
      code: string;
      name_vi: string;
    }> | null) || []
  ).map((r) => ({
    recruitment_source_id: r.recruitment_source_id,
    code: r.code,
    name_vi: r.name_vi,
  }));
}

export async function getQualificationLevelsAction(): Promise<
  Array<{ qualification_id: string; code: string; name_vi: string }>
> {
  const supabase = await createServerClient();
  const { data } = await supabase
    .from("qualification_levels")
    .select("qualification_id, code, name_vi")
    .eq("is_active", true)
    .order("code", { ascending: true });
  return (
    (data as Array<{
      qualification_id: string;
      code: string;
      name_vi: string;
    }> | null) || []
  ).map((q) => ({
    qualification_id: q.qualification_id,
    code: q.code,
    name_vi: q.name_vi,
  }));
}

export async function getDocumentSignedUrlAction(options: {
  submissionId: string;
  documentId: string;
  logicalDocumentId: string;
  mode: "preview" | "download";
}): Promise<
  | {
      success: true;
      signedUrl: string;
      previewUrl?: string;
      originalFilename: string;
      mimeType: string;
      transport?: DriveTransport;
    }
  | { success: false; error: string; code?: string }
> {
  try {
    if (driveServerConfig()) {
      const result = await generateDocumentSignedUrl(options);
      if (result.transport) return { success: true, ...result };
      if (options.mode === "download") return { success: true, ...result };
    }
    if (options.mode === "preview") {
      const detail = await loadSubmissionDetail(options.submissionId);
      const doc = detail.documents.find(
        (d) => d.document_id === options.documentId,
      );
      if (!doc) {
        throw new SubmissionDetailNotFoundError("Không tìm thấy tài liệu.");
      }
      if (!isPreviewableDocument(doc.mime_type)) {
        throw new DocumentNotPreviewableError();
      }
      const previewUrl = `/api/documents/preview/${encodeURIComponent(options.documentId)}?submissionId=${encodeURIComponent(options.submissionId)}&logicalDocumentId=${encodeURIComponent(options.logicalDocumentId)}`;
      return {
        success: true,
        signedUrl: previewUrl,
        previewUrl,
        originalFilename: doc.original_filename,
        mimeType: doc.mime_type,
      };
    }

    const result = await generateDocumentSignedUrl(options);
    return {
      success: true,
      signedUrl: result.signedUrl,
      originalFilename: result.originalFilename,
      mimeType: result.mimeType,
    };
  } catch (error) {
    if (error instanceof DocumentNotPreviewableError) {
      return {
        success: false,
        error: error.message,
        code: "NOT_PREVIEWABLE",
      };
    }
    if (error instanceof SubmissionDetailAccessError) {
      return { success: false, error: error.message, code: "FORBIDDEN" };
    }
    if (error instanceof SubmissionDetailNotFoundError) {
      return { success: false, error: error.message, code: "NOT_FOUND" };
    }
    return {
      success: false,
      error:
        error instanceof Error
          ? error.message
          : "Không thể lấy liên kết tải tài liệu.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function getAssignmentOptionsAction(): Promise<
  | { success: true; data: AssignmentOptions }
  | { success: false; error: string; code?: string }
> {
  try {
    const options = await loadAssignmentOptions();
    return { success: true, data: options };
  } catch (error) {
    if (error instanceof SubmissionDetailAccessError) {
      return { success: false, error: error.message, code: "FORBIDDEN" };
    }
    console.error(
      "[application-inbox-actions] getAssignmentOptionsAction failed:",
      error,
    );
    return {
      success: false,
      error: "Không thể tải danh sách chọn vị trí.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function updateSubmissionHrNoteAction(input: {
  submissionId: string;
  hrNote: string | null;
  expectedVersion: number;
}): Promise<
  | { success: true; data: UpdateSubmissionByHrData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await saveSubmissionHrNote(
      input.submissionId,
      input.hrNote,
      input.expectedVersion,
    );

    if (!result.success) {
      return {
        success: false,
        error: result.error.message,
        code: result.error.code,
      };
    }

    return {
      success: true,
      data: result.data,
    };
  } catch (error) {
    return {
      success: false,
      error:
        error instanceof Error
          ? error.message
          : "Không thể cập nhật ghi chú HR.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function createApplicationAction(input: {
  submissionId: string;
  unitId: string;
  departmentTeamId?: string;
  positionId: string;
  hrOwnerId: string;
  idempotencyKey?: string;
  confirmDuplicate?: boolean;
}): Promise<
  | { success: true; data: CreateOrUpdateApplicationData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await createOrUpdateApplication(input);

    if (!result.success) {
      if (result.error.code === "INTERNAL_ERROR") {
        console.error(
          "[application-inbox-actions] createApplicationAction internal command error:",
          result.error.message,
        );
        return {
          success: false,
          error: "Không thể tạo hoặc cập nhật Application.",
          code: "INTERNAL_ERROR",
        };
      }
      return {
        success: false,
        error: result.error.message,
        code: result.error.code,
      };
    }

    return {
      success: true,
      data: result.data,
    };
  } catch (error) {
    console.error(
      "[application-inbox-actions] createApplicationAction unexpected error:",
      error,
    );
    return {
      success: false,
      error: "Không thể tạo hoặc cập nhật Application.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function bulkSetLatestSubmissionManualStatusAction(input: {
  items: Array<{
    candidateId: string;
    expectedLatestSubmissionId: string;
    expectedVersion: number;
  }>;
  statusCode: "NEW" | "READ";
}): Promise<
  | { success: true; data: BulkSetLatestSubmissionManualStatusData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await bulkSetLatestSubmissionManualStatus({
      items: input.items,
      statusCode: input.statusCode,
      idempotencyKey: crypto.randomUUID(),
    });

    if (!result.success) {
      if (result.error.code === "INTERNAL_ERROR") {
        console.error(
          "[application-inbox-actions] bulkSetLatestSubmissionManualStatusAction internal error:",
          result.error.message,
        );
        return {
          success: false,
          error: "Không thể cập nhật trạng thái phiếu hàng loạt.",
          code: "INTERNAL_ERROR",
        };
      }
      return {
        success: false,
        error: result.error.message,
        code: result.error.code,
      };
    }

    return {
      success: true,
      data: result.data,
    };
  } catch (error) {
    console.error(
      "[application-inbox-actions] bulkSetLatestSubmissionManualStatusAction unexpected error:",
      error,
    );
    return {
      success: false,
      error: "Không thể cập nhật trạng thái phiếu hàng loạt.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function setCandidateActiveAction(input: {
  candidateId: string;
  active: boolean;
  expectedVersion: number;
}): Promise<
  | { success: true; data: SetCandidateActiveData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await setCandidateActive({
      candidateId: input.candidateId,
      active: input.active,
      expectedVersion: input.expectedVersion,
      idempotencyKey: crypto.randomUUID(),
    });

    if (!result.success) {
      if (result.error.code === "INTERNAL_ERROR") {
        console.error(
          "[application-inbox-actions] setCandidateActiveAction internal error:",
          result.error.message,
        );
        return {
          success: false,
          error: "Không thể cập nhật trạng thái tài khoản Candidate.",
          code: "INTERNAL_ERROR",
        };
      }
      return {
        success: false,
        error: result.error.message,
        code: result.error.code,
      };
    }

    return {
      success: true,
      data: result.data,
    };
  } catch (error) {
    console.error(
      "[application-inbox-actions] setCandidateActiveAction unexpected error:",
      error,
    );
    return {
      success: false,
      error: "Không thể cập nhật trạng thái tài khoản Candidate.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function bulkSetCandidateActiveAction(input: {
  items: Array<{
    candidateId: string;
    expectedVersion: number;
  }>;
  active: boolean;
}): Promise<
  | { success: true; data: BulkSetCandidateActiveData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await bulkSetCandidateActive({
      items: input.items,
      active: input.active,
      idempotencyKey: crypto.randomUUID(),
    });

    if (!result.success) {
      if (result.error.code === "INTERNAL_ERROR") {
        console.error(
          "[application-inbox-actions] bulkSetCandidateActiveAction internal error:",
          result.error.message,
        );
        return {
          success: false,
          error: "Không thể cập nhật trạng thái tài khoản hàng loạt.",
          code: "INTERNAL_ERROR",
        };
      }
      return {
        success: false,
        error: result.error.message,
        code: result.error.code,
      };
    }

    return {
      success: true,
      data: result.data,
    };
  } catch (error) {
    console.error(
      "[application-inbox-actions] bulkSetCandidateActiveAction unexpected error:",
      error,
    );
    return {
      success: false,
      error: "Không thể cập nhật trạng thái tài khoản hàng loạt.",
      code: "INTERNAL_ERROR",
    };
  }
}
