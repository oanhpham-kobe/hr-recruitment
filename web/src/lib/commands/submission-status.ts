import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import {
  getCurrentInternalBindingStatus,
  getServerSession,
} from "@/lib/auth/session";
import { createCommandRunner } from "@/lib/commands/runner";
import {
  CommandErrorCode,
  type CommandResult,
  type TrustedCommandDefinition,
  type VerifiedActor,
} from "@/lib/commands/types";
import { createServerClient } from "@/lib/supabase/server";

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// -----------------------------------------------------------------------------
// Type Definitions
// -----------------------------------------------------------------------------

export type OpenSubmissionInput = {
  submissionId: string;
};

export type OpenSubmissionData = {
  submission_id: string;
  candidate_id: string;
  status_code: string;
  full_name: string;
  email: string;
  phone: string | null;
  date_of_birth: string | null;
  gender: string | null;
  address: string | null;
  candidate_notes: string | null;
  submitted_at: string;
  version_no: number;
};

export type SetSubmissionManualStatusInput = {
  candidateId: string;
  statusCode: "NEW" | "READ";
  expectedLatestSubmissionId: string;
  expectedVersion: number;
  idempotencyKey?: string;
};

export type SetSubmissionManualStatusData = {
  submission_id: string;
  status_code: "NEW" | "READ";
  version_no: number;
};

export type RecalculateSubmissionStatusInput = {
  submissionId: string;
};

export type RecalculateSubmissionStatusData = {
  submission_id: string;
  status_code: string;
  previous_status_code: string;
};

export type CorrectSubmissionCandidateFieldsInput = {
  submissionId: string;
  fullName?: string | null;
  phone?: string | null;
  dateOfBirth?: string | null;
  gender?: "MALE" | "FEMALE" | null;
  currentAddress?: string | null;
  expectedVersion: number;
  reason?: string | null;
};

export type CorrectSubmissionCandidateFieldsData = {
  submission_id: string;
  version_no: number;
  changed_fields: string[];
};

export type UpdateSubmissionAggregateInput = {
  submissionId: string;
  expectedVersion: number;
  fullName?: string | null;
  phone?: string | null;
  dateOfBirth?: string | null;
  genderCode?: string | null;
  currentAddress?: string | null;
  recruitmentSourceId?: string | null;
  hrNote?: string | null;
  education?: Array<{
    periodText?: string | null;
    institutionName?: string | null;
    majorName?: string | null;
    degreeName?: string | null;
    qualificationId?: string | null;
  }> | null;
  reason?: string | null;
};

export type UpdateSubmissionAggregateData = {
  submission_id: string;
  version_no: number;
  changed_fields: string[];
};
export type BulkLatestSubmissionStatusItemInput = {
  candidateId: string;
  expectedLatestSubmissionId: string;
  expectedVersion: number;
};

export type BulkSetLatestSubmissionManualStatusInput = {
  items: BulkLatestSubmissionStatusItemInput[];
  statusCode: "NEW" | "READ";
  idempotencyKey: string;
};

export type BulkSetLatestSubmissionManualStatusData = {
  items: Array<{
    candidate_id: string;
    submission_id: string;
    status_code: "NEW" | "READ";
    version_no: number;
  }>;
  count: number;
  idempotency_key: string;
};

function mapRpcErrorCode(rawCode: string | undefined): CommandErrorCode {
  return (
    CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
    CommandErrorCode.INTERNAL_ERROR
  );
}

function isValidPositiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

async function defaultResolveBulkActor(
  client?: SupabaseClient,
): Promise<VerifiedActor | null> {
  const supabase = client ?? (await createServerClient());
  const session = await getServerSession(supabase);

  if (!session.user) {
    return null;
  }

  if (!session.user.isInternal) {
    return {
      authUserId: session.user.authUserId,
      email: session.user.email,
      isActive: true,
      roles: session.user.roles,
      permissions: session.user.permissions,
    };
  }

  return {
    authUserId: session.user.authUserId,
    email: session.user.email,
    isActive: true,
    roles: session.user.roles,
    permissions: session.user.permissions,
  };
}

export type SubmissionStatusCommandDeps = {
  client?: SupabaseClient;
  resolveActor?: () => Promise<VerifiedActor | null>;
};

// -----------------------------------------------------------------------------
// Default Actor Resolution
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

  const session = await getServerSession(supabase);
  if (session.user?.isInternal) {
    return {
      authUserId: session.user.authUserId,
      email: session.user.email,
      isActive: true,
      roles: session.user.roles,
      permissions: session.user.permissions,
    };
  }

  if (user.email.toLowerCase().endsWith("@eiu.edu.vn")) {
    const binding = await getCurrentInternalBindingStatus(supabase);
    if (binding?.bound && !binding.isActive) {
      return {
        authUserId: user.id,
        email: user.email,
        isActive: false,
        roles: [],
        permissions: [],
      };
    }
  }

  return {
    authUserId: user.id,
    email: user.email,
    isActive: true,
    roles: ["GUEST"],
    permissions: [],
  };
}

// -----------------------------------------------------------------------------
// 1. Open Submission Command
// -----------------------------------------------------------------------------

export function createOpenSubmissionCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  OpenSubmissionInput,
  string | undefined,
  OpenSubmissionInput,
  OpenSubmissionData
> {
  return {
    name: "open_submission",
    extractTarget(input) {
      return input.submissionId;
    },
    authorize(actor) {
      const canView =
        actor.permissions.includes("submissions.view") ||
        actor.roles.includes("ROOT_ADMIN") ||
        actor.roles.includes("HR");

      if (!canView) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission submissions.view required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input.submissionId || !UUID_REGEX.test(input.submissionId)) {
        return {
          success: false,
          error: "Invalid submissionId UUID",
        };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc("open_submission", {
        p_submission_id: validated.submissionId,
      });

      if (error) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.INTERNAL_ERROR,
            message: error.message,
          },
        };
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: OpenSubmissionData;
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
            message: result.message || "Failed to open submission",
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
// 2. Set Submission Manual Status Command (NEW <-> READ)
// -----------------------------------------------------------------------------

export function createSetSubmissionManualStatusCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  SetSubmissionManualStatusInput,
  string | undefined,
  SetSubmissionManualStatusInput,
  SetSubmissionManualStatusData
> {
  return {
    name: "set_submission_manual_status",
    extractTarget(input) {
      return input.expectedLatestSubmissionId;
    },
    authorize(actor) {
      const canChangeStatus =
        actor.permissions.includes("submissions.status") ||
        actor.roles.includes("ROOT_ADMIN") ||
        actor.roles.includes("HR");

      if (!canChangeStatus) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission submissions.status required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input.candidateId || !UUID_REGEX.test(input.candidateId)) {
        return {
          success: false,
          error: "Invalid candidateId UUID",
        };
      }

      if (
        !input.expectedLatestSubmissionId ||
        !UUID_REGEX.test(input.expectedLatestSubmissionId)
      ) {
        return {
          success: false,
          error: "Invalid expectedLatestSubmissionId UUID",
        };
      }

      if (!["NEW", "READ"].includes(input.statusCode)) {
        return {
          success: false,
          error:
            "Manual status change permits only NEW or READ. PROCESSED, DONE, and CLOSED are system-derived.",
        };
      }

      if (
        typeof input.expectedVersion !== "number" ||
        input.expectedVersion < 1
      ) {
        return {
          success: false,
          error: "expectedVersion must be a positive integer",
        };
      }

      if (input.idempotencyKey && !UUID_REGEX.test(input.idempotencyKey)) {
        return {
          success: false,
          error: "idempotencyKey must be a valid UUID",
        };
      }

      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "set_submission_manual_status",
        {
          p_candidate_id: validated.candidateId,
          p_status_code: validated.statusCode,
          p_expected_latest_submission_id: validated.expectedLatestSubmissionId,
          p_expected_version: validated.expectedVersion,
          p_idempotency_key: validated.idempotencyKey ?? crypto.randomUUID(),
        },
      );

      if (error) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.INTERNAL_ERROR,
            message: error.message,
          },
        };
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: SetSubmissionManualStatusData;
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
              result.message || "Failed to update submission manual status",
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
// 3. Bulk Latest Submission Manual Status Command
// -----------------------------------------------------------------------------

export function createBulkSetLatestSubmissionManualStatusCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  BulkSetLatestSubmissionManualStatusInput,
  string | undefined,
  BulkSetLatestSubmissionManualStatusInput,
  BulkSetLatestSubmissionManualStatusData
> {
  return {
    name: "bulk_set_latest_submission_manual_status",
    authorize(actor) {
      if (
        !actor.permissions.includes("submissions.status") &&
        !actor.roles.includes("ROOT_ADMIN")
      ) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission submissions.status required",
        };
      }
      return { authorized: true };
    },
    validate(input) {
      if (!Array.isArray(input.items) || input.items.length === 0) {
        return { success: false, error: "At least one item is required" };
      }
      if (!["NEW", "READ"].includes(input.statusCode)) {
        return {
          success: false,
          error: "Bulk manual status permits only NEW or READ",
        };
      }
      if (!input.idempotencyKey || !UUID_REGEX.test(input.idempotencyKey)) {
        return {
          success: false,
          error: "idempotencyKey must be a valid UUID",
        };
      }

      const candidateIds = new Set<string>();
      for (const item of input.items) {
        if (!item.candidateId || !UUID_REGEX.test(item.candidateId)) {
          return { success: false, error: "Invalid candidateId UUID" };
        }
        if (
          !item.expectedLatestSubmissionId ||
          !UUID_REGEX.test(item.expectedLatestSubmissionId)
        ) {
          return {
            success: false,
            error: "Invalid expectedLatestSubmissionId UUID",
          };
        }
        if (!isValidPositiveInteger(item.expectedVersion)) {
          return {
            success: false,
            error: "expectedVersion must be a positive safe integer",
          };
        }
        if (candidateIds.has(item.candidateId)) {
          return {
            success: false,
            error: "Duplicate candidateId is not allowed",
          };
        }
        candidateIds.add(item.candidateId);
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "bulk_set_latest_submission_manual_status",
        {
          p_candidate_ids: validated.items.map((item) => item.candidateId),
          p_status_code: validated.statusCode,
          p_expected_latest_submission_ids: validated.items.map(
            (item) => item.expectedLatestSubmissionId,
          ),
          p_expected_versions: validated.items.map(
            (item) => item.expectedVersion,
          ),
          p_idempotency_key: validated.idempotencyKey,
        },
      );

      if (error) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.INTERNAL_ERROR,
            message: error.message,
          },
        };
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: BulkSetLatestSubmissionManualStatusData;
      };

      if (!result.success || !result.data) {
        return {
          success: false,
          error: {
            code: mapRpcErrorCode(result.error_code),
            message: result.message || "Failed to update latest Submissions",
          },
        };
      }

      return { success: true, data: result.data };
    },
  };
}

// -----------------------------------------------------------------------------
// 4. Recalculate Submission Status Command
// -----------------------------------------------------------------------------

export function createRecalculateSubmissionStatusCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  RecalculateSubmissionStatusInput,
  string | undefined,
  RecalculateSubmissionStatusInput,
  RecalculateSubmissionStatusData
> {
  return {
    name: "recalculate_submission_status",
    extractTarget(input) {
      return input.submissionId;
    },
    authorize(actor) {
      const isInternal =
        actor.roles.includes("HR") ||
        actor.roles.includes("ROOT_ADMIN") ||
        actor.roles.includes("SERVICE_ROLE");

      if (!isInternal) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Internal staff authorization required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input.submissionId || !UUID_REGEX.test(input.submissionId)) {
        return {
          success: false,
          error: "Invalid submissionId UUID",
        };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "recalculate_submission_status",
        {
          p_submission_id: validated.submissionId,
        },
      );

      if (error) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.INTERNAL_ERROR,
            message: error.message,
          },
        };
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: RecalculateSubmissionStatusData;
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
              result.message || "Failed to recalculate submission status",
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
// Public Helpers
// -----------------------------------------------------------------------------

export async function openSubmission(
  input: OpenSubmissionInput,
  deps: SubmissionStatusCommandDeps = {},
): Promise<CommandResult<OpenSubmissionData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createOpenSubmissionCommand(supabase), input);
}

export async function setSubmissionManualStatus(
  input: SetSubmissionManualStatusInput,
  deps: SubmissionStatusCommandDeps = {},
): Promise<CommandResult<SetSubmissionManualStatusData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createSetSubmissionManualStatusCommand(supabase), input);
}

export async function bulkSetLatestSubmissionManualStatus(
  input: BulkSetLatestSubmissionManualStatusInput,
  deps: SubmissionStatusCommandDeps = {},
): Promise<CommandResult<BulkSetLatestSubmissionManualStatusData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveBulkActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(
    createBulkSetLatestSubmissionManualStatusCommand(supabase),
    input,
  );
}

export async function recalculateSubmissionStatus(
  input: RecalculateSubmissionStatusInput,
  deps: SubmissionStatusCommandDeps = {},
): Promise<CommandResult<RecalculateSubmissionStatusData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createRecalculateSubmissionStatusCommand(supabase), input);
}

export function createCorrectSubmissionCandidateFieldsCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  CorrectSubmissionCandidateFieldsInput,
  string,
  CorrectSubmissionCandidateFieldsInput,
  CorrectSubmissionCandidateFieldsData
> {
  return {
    name: "correct_submission_candidate_fields_by_hr",

    extractTarget(rawInput) {
      return rawInput.submissionId;
    },

    async authorize(actor) {
      const hasEdit = actor.permissions.includes("submissions.edit");
      const isRoot =
        actor.roles.includes("root_admin") || actor.roles.includes("root");
      if (!hasEdit && !isRoot) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission submissions.edit required",
        };
      }
      return { authorized: true };
    },

    validate(rawInput) {
      if (!rawInput.submissionId || !UUID_REGEX.test(rawInput.submissionId)) {
        return { success: false, error: "Invalid submissionId UUID" };
      }

      const hasAnyField =
        (rawInput.fullName !== undefined && rawInput.fullName !== null) ||
        (rawInput.phone !== undefined && rawInput.phone !== null) ||
        (rawInput.dateOfBirth !== undefined && rawInput.dateOfBirth !== null) ||
        (rawInput.gender !== undefined && rawInput.gender !== null) ||
        (rawInput.currentAddress !== undefined &&
          rawInput.currentAddress !== null);

      if (!hasAnyField) {
        return {
          success: false,
          error: "At least one candidate field must be provided for correction",
        };
      }

      if (rawInput.fullName !== undefined && rawInput.fullName !== null) {
        const name = rawInput.fullName.trim();
        if (!name || name.length > 200) {
          return {
            success: false,
            error:
              "Full name must not be empty and must not exceed 200 characters",
          };
        }
      }

      if (rawInput.phone !== undefined && rawInput.phone !== null) {
        const phone = rawInput.phone.trim();
        if (!phone || phone.length > 32) {
          return {
            success: false,
            error:
              "Phone number must not be empty and must not exceed 32 characters",
          };
        }
      }

      if (rawInput.dateOfBirth !== undefined && rawInput.dateOfBirth !== null) {
        const dob = rawInput.dateOfBirth.trim();
        const today = new Date().toISOString().split("T")[0];
        if (dob < "1900-01-01" || dob > today) {
          return {
            success: false,
            error: "Date of birth must be between 1900-01-01 and today",
          };
        }
      }

      if (rawInput.gender !== undefined && rawInput.gender !== null) {
        const gender = rawInput.gender.toUpperCase().trim();
        if (!["MALE", "FEMALE"].includes(gender)) {
          return {
            success: false,
            error: "Gender must be MALE or FEMALE",
          };
        }
      }

      if (
        rawInput.currentAddress !== undefined &&
        rawInput.currentAddress !== null
      ) {
        const address = rawInput.currentAddress.trim();
        if (!address || address.length > 500) {
          return {
            success: false,
            error:
              "Address must not be empty and must not exceed 500 characters",
          };
        }
      }

      if (
        typeof rawInput.expectedVersion !== "number" ||
        rawInput.expectedVersion <= 0
      ) {
        return {
          success: false,
          error: "Expected version is required and must be a positive number",
        };
      }
      return { success: true, data: rawInput };
    },

    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "correct_submission_candidate_fields_by_hr",
        {
          p_submission_id: validated.submissionId,
          p_full_name: validated.fullName?.trim() || null,
          p_phone: validated.phone?.trim() || null,
          p_date_of_birth: validated.dateOfBirth?.trim() || null,
          p_gender: validated.gender
            ? validated.gender.toUpperCase().trim()
            : null,
          p_current_address: validated.currentAddress?.trim() || null,
          p_expected_version: validated.expectedVersion,
          p_reason: validated.reason?.trim() || null,
        },
      );

      if (error) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.INTERNAL_ERROR,
            message: error.message,
          },
        };
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        submission_id?: string;
        version_no?: number;
        changed_fields?: string[];
      };

      if (!result.success) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message:
              result.message || "Failed to correct submission candidate fields",
          },
        };
      }

      return {
        success: true,
        data: {
          submission_id: result.submission_id ?? "",
          version_no: result.version_no ?? 1,
          changed_fields: result.changed_fields || [],
        },
      };
    },
  };
}

export async function correctSubmissionCandidateFieldsByHr(
  input: CorrectSubmissionCandidateFieldsInput,
  deps: SubmissionStatusCommandDeps = {},
): Promise<CommandResult<CorrectSubmissionCandidateFieldsData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createCorrectSubmissionCandidateFieldsCommand(supabase), input);
}

export function createUpdateSubmissionAggregateCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  UpdateSubmissionAggregateInput,
  string,
  UpdateSubmissionAggregateInput,
  UpdateSubmissionAggregateData
> {
  return {
    name: "update_submission_aggregate_by_hr",
    extractTarget(input) {
      return input.submissionId;
    },
    authorize(actor) {
      const canEdit =
        actor.permissions.includes("submissions.edit") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canEdit) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission submissions.edit required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input.submissionId || !UUID_REGEX.test(input.submissionId)) {
        return {
          success: false,
          error: "Invalid submissionId UUID",
        };
      }

      if (
        typeof input.expectedVersion !== "number" ||
        input.expectedVersion <= 0 ||
        !Number.isInteger(input.expectedVersion)
      ) {
        return {
          success: false,
          error: "expectedVersion must be a positive integer",
        };
      }

      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "update_submission_aggregate_by_hr",
        {
          p_submission_id: validated.submissionId,
          p_expected_version: validated.expectedVersion,
          p_full_name:
            validated.fullName !== undefined
              ? validated.fullName?.trim() || null
              : null,
          p_phone:
            validated.phone !== undefined
              ? validated.phone?.trim() || null
              : null,
          p_date_of_birth:
            validated.dateOfBirth !== undefined
              ? validated.dateOfBirth?.trim() || null
              : null,
          p_gender_code:
            validated.genderCode !== undefined
              ? validated.genderCode?.toUpperCase().trim() || null
              : null,
          p_current_address:
            validated.currentAddress !== undefined
              ? validated.currentAddress?.trim() || null
              : null,
          p_recruitment_source_id:
            validated.recruitmentSourceId !== undefined
              ? validated.recruitmentSourceId || null
              : null,
          p_hr_note: validated.hrNote !== undefined ? validated.hrNote : null,
          p_education: validated.education
            ? validated.education.map((e) => ({
                period_text: e.periodText?.trim() || null,
                institution_name: e.institutionName?.trim() || "",
                major_name: e.majorName?.trim() || "",
                degree_name: e.degreeName?.trim() || "",
                qualification_id: e.qualificationId || null,
              }))
            : null,
          p_reason: validated.reason?.trim() || null,
        },
      );

      if (error) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.INTERNAL_ERROR,
            message: error.message,
          },
        };
      }

      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        submission_id?: string;
        version_no?: number;
        changed_fields?: string[];
      };

      if (!result.success) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message:
              result.message || "Failed to update submission aggregate by HR",
          },
        };
      }

      return {
        success: true,
        data: {
          submission_id: result.submission_id ?? "",
          version_no: result.version_no ?? 1,
          changed_fields: result.changed_fields || [],
        },
      };
    },
  };
}

export async function updateSubmissionAggregateByHr(
  input: UpdateSubmissionAggregateInput,
  deps: SubmissionStatusCommandDeps = {},
): Promise<CommandResult<UpdateSubmissionAggregateData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createUpdateSubmissionAggregateCommand(supabase), input);
}
