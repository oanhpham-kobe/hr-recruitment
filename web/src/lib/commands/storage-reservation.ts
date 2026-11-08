import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { createCommandRunner } from "@/lib/commands/runner";
import {
  CommandErrorCode,
  CommandExecutionError,
  type CommandResult,
  type TrustedCommandDefinition,
  type VerifiedActor,
} from "@/lib/commands/types";
import {
  extractExtension,
  isAllowedMimeForExtension,
  isApprovedExtension,
} from "@/lib/storage/buckets";
import { createServerClient } from "@/lib/supabase/server";

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// -----------------------------------------------------------------------------
// Type Definitions
// -----------------------------------------------------------------------------

export type ReserveCandidateFormUploadInput = {
  candidateFormSessionId: string;
  intendedDocumentTypeId: string;
  originalFilename: string;
  declaredMimeType?: string | null;
  expectedMaxSize?: number;
  idempotencyKey?: string;
};

export type UploadReservationData = {
  upload_reservation_id: string;
  candidate_form_session_id: string;
  intended_document_type_id: string;
  temp_bucket: string;
  temp_path: string;
  original_filename: string;
  declared_mime_type: string | null;
  expected_max_size_bytes: number;
  status_code: string;
  expires_at: string;
};

export type CreateSignedUploadUrlInput = {
  uploadReservationId: string;
};

export type SignedUploadUrlData = {
  signedUrl: string;
  path: string;
  token: string;
  expiresAt: string;
  signedUploadExpiresAt: string;
};

export type RecordUploadCompletedInput = {
  uploadReservationId: string;
  actualSizeBytes: number;
  checksumSha256?: string | null;
};

export type RecordUploadCompletedData = {
  upload_reservation_id: string;
  status_code: "UPLOADED";
  malware_scan_status: "PENDING";
};

export type RecordInspectedUploadInput = {
  uploadReservationId: string;
  actualSizeBytes: number;
  detectedMimeType: string;
  checksumSha256: string;
  magicBytesVerified: boolean;
};

export type PendingDocumentScanData = {
  kind: "PENDING_SCAN";
  document_scan_request_id: string;
  upload_reservation_id: string;
};

export type StagedDocumentScanData = {
  kind: "STAGED";
  change_id: string;
};

export type RequestCandidateDocumentScanInput = {
  candidateFormSessionId: string;
  uploadReservationId: string;
  actionCode: "ADD" | "REPLACE";
  targetLogicalDocumentId?: string | null;
};

export type ClaimedDocumentScanRequest = {
  document_scan_request_id: string;
  upload_reservation_id: string;
  attempt_id: string;
  fencing_token: string;
  leased_until: string;
};

export type CompleteDocumentScanAttemptInput = {
  documentScanRequestId: string;
  attemptId: string;
  fencingToken: string;
  workerId: string;
  outcome: "CLEAN" | "INFECTED" | "ERROR";
  errorCode?: string | null;
};
export type AuthorizeCandidateUploadScanInput = {
  candidateFormSessionId: string;
  uploadReservationId: string;
};

export type AuthorizeCandidateUploadScanData = {
  candidate_form_session_id: string;
  upload_reservation_id: string;
};

export type StageCandidateDocumentChangeInput = {
  candidateFormSessionId: string;
  actionCode: "ADD" | "REPLACE" | "DELETE";
  intendedDocumentTypeId: string;
  uploadReservationId?: string | null;
  targetLogicalDocumentId?: string | null;
};

export type StagedDocumentChangeData = {
  candidate_form_document_change_id: string;
  candidate_form_session_id: string;
  action_code: "ADD" | "REPLACE" | "DELETE";
  intended_document_type_id: string;
  upload_reservation_id: string | null;
  target_logical_document_id: string | null;
  status_code: "PENDING";
};
export type CancelCandidateDocumentChangeInput = {
  candidateFormSessionId: string;
  changeId: string;
};

export type CancelCandidateDocumentChangeData = {
  candidate_form_session_id: string;
  candidate_form_document_change_id: string;
  status_code: "CANCELLED";
};

export type ClaimedStorageCleanupJob = {
  storage_cleanup_id: string;
  source_type: string;
  bucket_name: string;
  object_path: string;
  reason_code: string;
  attempts: number;
  not_before: string;
  leased_until: string;
  attempt_id: string;
  fencing_token: string;
};

export type AuthorizeStorageCleanupAttemptInput = {
  storageCleanupId: string;
  attemptId: string;
  fencingToken: string;
  workerId: string;
};

export type AuthorizedStorageCleanupJob = {
  storage_cleanup_id: string;
  bucket_name: string;
  object_path: string;
  reason_code: string;
  attempt_id: string;
  fencing_token: string;
  leased_until: string;
};

export type StorageReservationCommandDeps = {
  client?: SupabaseClient;
  resolveActor?: () => Promise<VerifiedActor | null>;
};

// -----------------------------------------------------------------------------
// Actor Resolution
// -----------------------------------------------------------------------------

async function defaultResolveActor(
  client?: SupabaseClient,
): Promise<VerifiedActor | null> {
  const supabase = client ?? (await createServerClient());
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user || !user.email) {
    return null;
  }

  const { data: candidate } = await supabase
    .from("candidates")
    .select("candidate_id, is_active")
    .eq("auth_user_id", user.id)
    .maybeSingle();

  if (!candidate || typeof candidate !== "object") {
    return null;
  }

  const isActive = Boolean(
    "is_active" in candidate && candidate.is_active === true,
  );

  return {
    authUserId: user.id,
    email: user.email,
    isActive,
    roles: ["CANDIDATE"],
    permissions: ["candidate.self"],
  };
}

// -----------------------------------------------------------------------------
// 1. Reserve Candidate Form Upload Command
// -----------------------------------------------------------------------------

export function createReserveCandidateFormUploadCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  ReserveCandidateFormUploadInput,
  string | undefined,
  ReserveCandidateFormUploadInput,
  UploadReservationData
> {
  return {
    name: "reserve_candidate_form_upload",
    extractTarget(input) {
      return input.candidateFormSessionId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");

      if (!isCandidate) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Candidate authorization required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (
        !input.candidateFormSessionId ||
        !UUID_REGEX.test(input.candidateFormSessionId)
      ) {
        return {
          success: false,
          error: "Invalid candidateFormSessionId UUID",
        };
      }

      if (
        !input.intendedDocumentTypeId ||
        !UUID_REGEX.test(input.intendedDocumentTypeId)
      ) {
        return {
          success: false,
          error: "Invalid intendedDocumentTypeId UUID",
        };
      }

      const filename = input.originalFilename?.trim();
      if (!filename || filename.length > 255) {
        return {
          success: false,
          error: "Original filename must be between 1 and 255 characters",
        };
      }

      const ext = extractExtension(filename);
      if (!ext || !isApprovedExtension(ext)) {
        return {
          success: false,
          error:
            "File extension not permitted. Approved formats: PDF, DOC, DOCX, PPT, PPTX, PNG, JPG, JPEG",
        };
      }

      if (input.declaredMimeType) {
        if (!isAllowedMimeForExtension(ext, input.declaredMimeType)) {
          return {
            success: false,
            error: "Declared MIME type does not match approved extension list",
          };
        }
      }

      const size = input.expectedMaxSize ?? 5242880;
      if (size <= 0 || size > 5242880) {
        return {
          success: false,
          error: "Expected max size must be between 1 and 5242880 bytes (5 MB)",
        };
      }

      if (input.idempotencyKey && !UUID_REGEX.test(input.idempotencyKey)) {
        return {
          success: false,
          error: "Idempotency key must be a valid UUID",
        };
      }

      return {
        success: true,
        data: {
          ...input,
          originalFilename: filename,
          expectedMaxSize: size,
        },
      };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "reserve_candidate_form_upload",
        {
          p_candidate_form_session_id: validated.candidateFormSessionId,
          p_intended_document_type_id: validated.intendedDocumentTypeId,
          p_original_filename: validated.originalFilename,
          p_declared_mime_type: validated.declaredMimeType ?? null,
          p_expected_max_size_bytes: validated.expectedMaxSize ?? 5242880,
          p_idempotency_key: validated.idempotencyKey ?? crypto.randomUUID(),
        },
      );

      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message,
          error,
        );
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: UploadReservationData;
      };

      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message: result.message || "Failed to reserve upload",
          },
        };
      }

      return {
        success: true,
        data: result.data,
      };
    },
  };
}

// -----------------------------------------------------------------------------
// 2. Create Signed Upload URL For Reservation Command
// Derives bucket and path EXCLUSIVELY from reservation row; upsert: false;
// zero token/URL persistence.
// -----------------------------------------------------------------------------

export function createSignedUploadUrlForReservationCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  CreateSignedUploadUrlInput,
  string | undefined,
  CreateSignedUploadUrlInput,
  SignedUploadUrlData
> {
  return {
    name: "create_signed_upload_url_for_reservation",
    extractTarget(input) {
      return input.uploadReservationId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");

      if (!isCandidate) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Candidate authorization required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (
        !input.uploadReservationId ||
        !UUID_REGEX.test(input.uploadReservationId)
      ) {
        return {
          success: false,
          error: "Invalid uploadReservationId UUID",
        };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      // Step 1: Pre-call durable token expiry registration via prepare_signed_upload RPC.
      // Locks reservation row in deterministic hierarchy and records signed_upload_expires_at
      // with latency buffer BEFORE Storage API is invoked.
      const { data: prepareData, error: prepareError } = await supabase.rpc(
        "prepare_signed_upload",
        {
          p_upload_reservation_id: validated.uploadReservationId,
        },
      );

      if (prepareError) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          prepareError.message,
          prepareError,
        );
      }

      const prepResult = prepareData as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: {
          upload_reservation_id: string;
          temp_bucket: string;
          temp_path: string;
          expires_at: string;
          signed_upload_expires_at: string;
        };
      };

      if (!prepResult.success || !prepResult.data) {
        const rawCode = prepResult.error_code
          ? String(prepResult.error_code)
          : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message: prepResult.message || "Failed to prepare signed upload",
          },
        };
      }
      const res = prepResult.data;

      // Step 2: Mint signed upload URL using Storage API.
      // Bucket and path are derived EXCLUSIVELY from the database row.
      // upsert is strictly set to false.
      const { data: signData, error: signError } = await supabase.storage
        .from(res.temp_bucket)
        .createSignedUploadUrl(res.temp_path, { upsert: false });

      if (signError || !signData) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          signError?.message || "Storage service failed to generate signed URL",
          signError,
        );
      }

      // Step 3: Return signed URL and metadata.
      // Zero persistence or logging of token or signed URL.
      return {
        signedUrl: signData.signedUrl,
        path: signData.path,
        token: signData.token,
        expiresAt: res.expires_at,
        signedUploadExpiresAt: res.signed_upload_expires_at,
      };
    },
  };
}

// -----------------------------------------------------------------------------
// 3. Authorize Candidate Upload Scan Command
// -----------------------------------------------------------------------------

export function createAuthorizeCandidateUploadScanCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  AuthorizeCandidateUploadScanInput,
  string | undefined,
  AuthorizeCandidateUploadScanInput,
  AuthorizeCandidateUploadScanData
> {
  return {
    name: "authorize_candidate_upload_scan",
    extractTarget(input) {
      return input.candidateFormSessionId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");
      return isCandidate
        ? { authorized: true }
        : {
            authorized: false,
            code: CommandErrorCode.FORBIDDEN,
            reason: "Candidate authorization required",
          };
    },
    validate(input) {
      if (
        !UUID_REGEX.test(input.candidateFormSessionId) ||
        !UUID_REGEX.test(input.uploadReservationId)
      ) {
        return {
          success: false,
          error: "candidateFormSessionId and uploadReservationId must be UUIDs",
        };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "authorize_candidate_upload_scan",
        {
          p_candidate_form_session_id: validated.candidateFormSessionId,
          p_upload_reservation_id: validated.uploadReservationId,
        },
      );

      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message,
          error,
        );
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: AuthorizeCandidateUploadScanData;
      };
      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message:
              result.message || "Upload reservation authorization failed",
          },
        };
      }
      return { success: true, data: result.data };
    },
  };
}

// -----------------------------------------------------------------------------
// 3. Record Candidate Upload Completed Command
// -----------------------------------------------------------------------------

export function createRecordCandidateUploadCompletedCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  RecordUploadCompletedInput,
  string | undefined,
  RecordUploadCompletedInput,
  RecordUploadCompletedData
> {
  return {
    name: "record_candidate_upload_completed",
    extractTarget(input) {
      return input.uploadReservationId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");

      if (!isCandidate) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Candidate authorization required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (
        !input.uploadReservationId ||
        !UUID_REGEX.test(input.uploadReservationId)
      ) {
        return {
          success: false,
          error: "Invalid uploadReservationId UUID",
        };
      }

      if (
        typeof input.actualSizeBytes !== "number" ||
        input.actualSizeBytes <= 0 ||
        input.actualSizeBytes > 5242880
      ) {
        return {
          success: false,
          error: "actualSizeBytes must be between 1 and 5242880 bytes (5 MB)",
        };
      }

      if (
        input.checksumSha256 &&
        !/^[0-9a-fA-F]{64}$/.test(input.checksumSha256)
      ) {
        return {
          success: false,
          error: "checksumSha256 must be a 64-character hexadecimal string",
        };
      }

      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "record_candidate_upload_completed",
        {
          p_upload_reservation_id: validated.uploadReservationId,
          p_actual_size_bytes: validated.actualSizeBytes,
          p_checksum_sha256: validated.checksumSha256 ?? null,
        },
      );

      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message,
          error,
        );
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: RecordUploadCompletedData;
      };

      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message: result.message || "Failed to record upload completion",
          },
        };
      }

      return {
        success: true,
        data: result.data,
      };
    },
  };
}

// -----------------------------------------------------------------------------
// 4. Stage Candidate Document Change Command
// -----------------------------------------------------------------------------

export function createStageCandidateDocumentChangeCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  StageCandidateDocumentChangeInput,
  string | undefined,
  StageCandidateDocumentChangeInput,
  StagedDocumentChangeData
> {
  return {
    name: "stage_candidate_document_change",
    extractTarget(input) {
      return input.candidateFormSessionId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");

      if (!isCandidate) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Candidate authorization required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (
        !input.candidateFormSessionId ||
        !UUID_REGEX.test(input.candidateFormSessionId)
      ) {
        return {
          success: false,
          error: "Invalid candidateFormSessionId UUID",
        };
      }

      if (
        !input.intendedDocumentTypeId ||
        !UUID_REGEX.test(input.intendedDocumentTypeId)
      ) {
        return {
          success: false,
          error: "Invalid intendedDocumentTypeId UUID",
        };
      }

      if (!["ADD", "REPLACE", "DELETE"].includes(input.actionCode)) {
        return {
          success: false,
          error: "actionCode must be ADD, REPLACE, or DELETE",
        };
      }

      if (input.actionCode === "ADD") {
        if (!input.uploadReservationId) {
          return {
            success: false,
            error: "ADD action requires an uploadReservationId",
          };
        }
        if (input.targetLogicalDocumentId) {
          return {
            success: false,
            error: "ADD action cannot have a targetLogicalDocumentId",
          };
        }
      } else if (input.actionCode === "REPLACE") {
        if (!input.uploadReservationId || !input.targetLogicalDocumentId) {
          return {
            success: false,
            error:
              "REPLACE action requires both uploadReservationId and targetLogicalDocumentId",
          };
        }
      } else if (input.actionCode === "DELETE") {
        if (input.uploadReservationId) {
          return {
            success: false,
            error: "DELETE action cannot have an uploadReservationId",
          };
        }
        if (!input.targetLogicalDocumentId) {
          return {
            success: false,
            error: "DELETE action requires a targetLogicalDocumentId",
          };
        }
      }

      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "stage_candidate_document_change",
        {
          p_candidate_form_session_id: validated.candidateFormSessionId,
          p_action_code: validated.actionCode,
          p_intended_document_type_id: validated.intendedDocumentTypeId,
          p_upload_reservation_id: validated.uploadReservationId ?? null,
          p_target_logical_document_id:
            validated.targetLogicalDocumentId ?? null,
        },
      );

      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message,
          error,
        );
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: StagedDocumentChangeData;
      };

      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message: result.message || "Failed to stage document change",
          },
        };
      }

      return {
        success: true,
        data: result.data,
      };
    },
  };
}

// -----------------------------------------------------------------------------
// 5. Cancel Candidate Document Change Command
// -----------------------------------------------------------------------------

export function createCancelCandidateDocumentChangeCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  CancelCandidateDocumentChangeInput,
  string | undefined,
  CancelCandidateDocumentChangeInput,
  CancelCandidateDocumentChangeData
> {
  return {
    name: "cancel_candidate_form_document_change",
    extractTarget(input) {
      return input.candidateFormSessionId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");
      return isCandidate
        ? { authorized: true }
        : {
            authorized: false,
            code: CommandErrorCode.FORBIDDEN,
            reason: "Candidate authorization required",
          };
    },
    validate(input) {
      if (
        !UUID_REGEX.test(input.candidateFormSessionId) ||
        !UUID_REGEX.test(input.changeId)
      ) {
        return {
          success: false,
          error: "candidateFormSessionId and changeId must be UUIDs",
        };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "cancel_candidate_form_document_change",
        {
          p_session_id: validated.candidateFormSessionId,
          p_change_id: validated.changeId,
        },
      );

      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message,
          error,
        );
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: CancelCandidateDocumentChangeData;
      };
      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message: result.message || "Failed to cancel document change",
          },
        };
      }

      return { success: true, data: result.data };
    },
  };
}

// -----------------------------------------------------------------------------
// 6. Public Helper Functions
// -----------------------------------------------------------------------------

export async function reserveCandidateFormUpload(
  input: ReserveCandidateFormUploadInput,
  deps: StorageReservationCommandDeps = {},
): Promise<CommandResult<UploadReservationData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createReserveCandidateFormUploadCommand(supabase), input);
}

export async function createSignedUploadUrlForReservation(
  input: CreateSignedUploadUrlInput,
  deps: StorageReservationCommandDeps = {},
): Promise<CommandResult<SignedUploadUrlData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createSignedUploadUrlForReservationCommand(supabase), input);
}

export async function authorizeCandidateUploadScan(
  input: AuthorizeCandidateUploadScanInput,
  deps: StorageReservationCommandDeps = {},
): Promise<CommandResult<AuthorizeCandidateUploadScanData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createAuthorizeCandidateUploadScanCommand(supabase), input);
}

export async function recordCandidateUploadCompleted(
  input: RecordUploadCompletedInput,
  deps: StorageReservationCommandDeps = {},
): Promise<CommandResult<RecordUploadCompletedData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createRecordCandidateUploadCompletedCommand(supabase), input);
}

type ScanRpcSuccess<T> = { success: true; data: T };
type ScanRpcFailure = {
  success: false;
  error: { code: string; message: string };
};

async function runScanRpc<T>(
  client: SupabaseClient,
  functionName: string,
  args: Record<string, unknown>,
): Promise<ScanRpcSuccess<T> | ScanRpcFailure> {
  const { data, error } = await client.rpc(functionName, args);
  if (error) {
    return {
      success: false,
      error: { code: CommandErrorCode.INTERNAL_ERROR, message: error.message },
    };
  }
  const result = data as {
    success?: boolean;
    error_code?: string;
    message?: string;
    data?: T;
  };
  if (!result.success || !result.data) {
    return {
      success: false,
      error: {
        code: result.error_code ?? CommandErrorCode.INTERNAL_ERROR,
        message: result.message ?? "Document scan command failed",
      },
    };
  }
  return { success: true, data: result.data };
}

export async function recordInspectedUploadReservation(
  input: RecordInspectedUploadInput,
  client: SupabaseClient,
): Promise<ScanRpcSuccess<RecordUploadCompletedData> | ScanRpcFailure> {
  return runScanRpc<RecordUploadCompletedData>(
    client,
    "record_inspected_upload_reservation",
    {
      p_upload_reservation_id: input.uploadReservationId,
      p_actual_size_bytes: input.actualSizeBytes,
      p_detected_mime_type: input.detectedMimeType,
      p_checksum_sha256: input.checksumSha256,
      p_magic_bytes_verified: input.magicBytesVerified,
    },
  );
}

export async function requestCandidateDocumentScan(
  input: RequestCandidateDocumentScanInput,
  client: SupabaseClient,
): Promise<ScanRpcSuccess<PendingDocumentScanData> | ScanRpcFailure> {
  return runScanRpc<PendingDocumentScanData>(
    client,
    "request_candidate_document_scan",
    {
      p_candidate_form_session_id: input.candidateFormSessionId,
      p_upload_reservation_id: input.uploadReservationId,
      p_action_code: input.actionCode,
      p_target_logical_document_id: input.targetLogicalDocumentId ?? null,
    },
  );
}

export async function continueCleanCandidateDocumentScan(
  candidateFormSessionId: string,
  uploadReservationId: string,
  client: SupabaseClient,
): Promise<ScanRpcSuccess<StagedDocumentScanData> | ScanRpcFailure> {
  return runScanRpc<StagedDocumentScanData>(
    client,
    "continue_clean_candidate_document_scan",
    {
      p_candidate_form_session_id: candidateFormSessionId,
      p_upload_reservation_id: uploadReservationId,
    },
  );
}

export async function claimDocumentScanRequests(
  workerId: string,
  limit: number,
  leaseSeconds: number,
  workerClient: SupabaseClient,
): Promise<ScanRpcSuccess<ClaimedDocumentScanRequest[]> | ScanRpcFailure> {
  return runScanRpc<ClaimedDocumentScanRequest[]>(
    workerClient,
    "claim_document_scan_requests",
    {
      p_worker_id: workerId,
      p_limit: limit,
      p_lease_seconds: leaseSeconds,
    },
  );
}

export async function completeDocumentScanAttempt(
  input: CompleteDocumentScanAttemptInput,
  workerClient: SupabaseClient,
): Promise<ScanRpcSuccess<{ status_code: string }> | ScanRpcFailure> {
  return runScanRpc<{ status_code: string }>(
    workerClient,
    "complete_document_scan_attempt",
    {
      p_document_scan_request_id: input.documentScanRequestId,
      p_attempt_id: input.attemptId,
      p_fencing_token: input.fencingToken,
      p_worker_id: input.workerId,
      p_outcome: input.outcome,
      p_error_code: input.errorCode ?? null,
    },
  );
}

export async function stageCandidateDocumentChange(
  input: StageCandidateDocumentChangeInput,
  deps: StorageReservationCommandDeps = {},
): Promise<CommandResult<StagedDocumentChangeData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createStageCandidateDocumentChangeCommand(supabase), input);
}
export async function cancelCandidateDocumentChange(
  input: CancelCandidateDocumentChangeInput,
  deps: StorageReservationCommandDeps = {},
): Promise<CommandResult<CancelCandidateDocumentChangeData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createCancelCandidateDocumentChangeCommand(supabase), input);
}

type StorageCleanupRpcSuccess<T> = { success: true; data: T };
type StorageCleanupRpcFailure = {
  success: false;
  error_code?: string;
};

async function runStorageCleanupRpc<T>(
  workerClient: SupabaseClient,
  functionName: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await workerClient.rpc(functionName, args);
  if (error) {
    throw new Error(`${functionName} error: RPC_FAILURE`);
  }
  const result = data as StorageCleanupRpcSuccess<T> | StorageCleanupRpcFailure;
  if (!result.success) {
    throw new Error(`${functionName} error: ${result.error_code ?? "UNKNOWN"}`);
  }
  return result.data;
}

export async function discoverExpiredStorageCleanup(
  limit = 50,
  workerClient: SupabaseClient,
): Promise<{ captured_count: number }> {
  return runStorageCleanupRpc<{ captured_count: number }>(
    workerClient,
    "discover_expired_storage_cleanup",
    { p_limit: limit },
  );
}

export async function claimStorageCleanupJobs(
  workerId: string,
  limit = 10,
  leaseSeconds = 300,
  workerClient: SupabaseClient,
): Promise<ClaimedStorageCleanupJob[]> {
  return runStorageCleanupRpc<ClaimedStorageCleanupJob[]>(
    workerClient,
    "claim_storage_cleanup_jobs",
    {
      p_worker_id: workerId,
      p_limit: limit,
      p_lease_seconds: leaseSeconds,
    },
  );
}

export async function authorizeStorageCleanupAttempt(
  input: AuthorizeStorageCleanupAttemptInput,
  workerClient: SupabaseClient,
): Promise<AuthorizedStorageCleanupJob> {
  return runStorageCleanupRpc<AuthorizedStorageCleanupJob>(
    workerClient,
    "authorize_storage_cleanup_attempt",
    {
      p_storage_cleanup_id: input.storageCleanupId,
      p_attempt_id: input.attemptId,
      p_fencing_token: input.fencingToken,
      p_worker_id: input.workerId,
    },
  );
}

export async function completeStorageCleanupAttempt(
  input: AuthorizeStorageCleanupAttemptInput & {
    success: boolean;
    errorCode?: string | null;
  },
  workerClient: SupabaseClient,
): Promise<{ status_code: string; replay?: boolean }> {
  return runStorageCleanupRpc<{ status_code: string; replay?: boolean }>(
    workerClient,
    "complete_storage_cleanup_attempt",
    {
      p_storage_cleanup_id: input.storageCleanupId,
      p_attempt_id: input.attemptId,
      p_fencing_token: input.fencingToken,
      p_worker_id: input.workerId,
      p_success: input.success,
      p_error_code: input.errorCode ?? null,
    },
  );
}
