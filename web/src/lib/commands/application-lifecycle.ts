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

export type CreateOrUpdateApplicationInput = {
  submissionId: string;
  unitId: string;
  departmentTeamId?: string | null;
  positionId: string;
  hrOwnerId: string;
  idempotencyKey?: string;
  confirmDuplicate?: boolean;
};

export type CreateOrUpdateApplicationData = {
  application_id: string;
  submission_id: string;
  is_active: boolean;
  version_no: number;
  round1_interview_id?: string;
};

export type DeleteOrInactivateApplicationInput = {
  applicationId: string;
};

export type DeleteOrInactivateApplicationData = {
  application_id: string;
  action: "DELETED" | "INACTIVATED";
  submission_id: string;
};

export type UpdateSubmissionByHrInput = {
  submissionId: string;
  hrNote?: string | null;
  expectedVersion: number;
};

export type UpdateSubmissionByHrData = {
  submission_id: string;
  hr_note: string | null;
  version_no: number;
};

export type BulkCreateOrUpdateApplicationsInput = {
  submissionIds: string[];
  unitId: string;
  departmentTeamId: string | null;
  positionId: string;
  hrOwnerId: string;
  idempotencyKey: string;
};

export type BulkCreateOrUpdateApplicationsData = {
  items: Array<{
    submission_id: string;
    application_id: string;
    action: "CREATED" | "UPDATED";
    version_no: number;
    round1_interview_id: string;
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

export type ApplicationLifecycleCommandDeps = {
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
  if (session.user) {
    return {
      authUserId: session.user.authUserId,
      email: session.user.email,
      isActive: true,
      roles: session.user.roles,
      permissions: session.user.permissions,
    };
  }

  // Authoritative fallback: check if app_user exists but is inactive
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

  return {
    authUserId: user.id,
    email: user.email,
    isActive: false,
    roles: ["GUEST"],
    permissions: [],
  };
}

const defaultResolveBulkActor = defaultResolveActor;

// -----------------------------------------------------------------------------
// 1. Create or Update Application Command
// -----------------------------------------------------------------------------

export function createCreateOrUpdateApplicationCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  CreateOrUpdateApplicationInput,
  string | undefined,
  CreateOrUpdateApplicationInput,
  CreateOrUpdateApplicationData
> {
  return {
    name: "create_or_update_application",
    extractTarget(input) {
      return input.submissionId;
    },
    authorize(actor) {
      const isRoot = actor.roles.includes("ROOT_ADMIN");
      const canView = isRoot || actor.permissions.includes("submissions.view");
      const canManage =
        isRoot ||
        actor.permissions.includes("applications.create") ||
        actor.permissions.includes("applications.manage");

      if (!canView || !canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason:
            "Permission submissions.view and (applications.create or applications.manage) required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input.submissionId || !UUID_REGEX.test(input.submissionId)) {
        return { success: false, error: "Invalid submissionId UUID" };
      }
      if (!input.unitId || !UUID_REGEX.test(input.unitId)) {
        return { success: false, error: "Invalid unitId UUID" };
      }
      if (input.departmentTeamId && !UUID_REGEX.test(input.departmentTeamId)) {
        return { success: false, error: "Invalid departmentTeamId UUID" };
      }
      if (!input.positionId || !UUID_REGEX.test(input.positionId)) {
        return { success: false, error: "Invalid positionId UUID" };
      }
      if (!input.hrOwnerId || !UUID_REGEX.test(input.hrOwnerId)) {
        return { success: false, error: "Invalid hrOwnerId UUID" };
      }
      if (input.idempotencyKey && !UUID_REGEX.test(input.idempotencyKey)) {
        return { success: false, error: "Invalid idempotencyKey UUID" };
      }
      if (
        input.confirmDuplicate !== undefined &&
        typeof input.confirmDuplicate !== "boolean"
      ) {
        return {
          success: false,
          error: "Invalid confirmDuplicate: must be a boolean or undefined",
        };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "create_or_update_application",
        {
          p_submission_id: validated.submissionId,
          p_unit_id: validated.unitId,
          p_department_team_id: validated.departmentTeamId ?? null,
          p_position_id: validated.positionId,
          p_hr_owner_id: validated.hrOwnerId,
          p_idempotency_key: validated.idempotencyKey ?? crypto.randomUUID(),
          p_confirm_duplicate: validated.confirmDuplicate ?? false,
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
        data?: CreateOrUpdateApplicationData;
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
            message: result.message || "Failed to create or update application",
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
// 2. Delete or Inactivate Application Command
// -----------------------------------------------------------------------------

export function createDeleteOrInactivateApplicationCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  DeleteOrInactivateApplicationInput,
  string | undefined,
  DeleteOrInactivateApplicationInput,
  DeleteOrInactivateApplicationData
> {
  return {
    name: "delete_or_inactivate_application",
    extractTarget(input) {
      return input.applicationId;
    },
    authorize(actor) {
      const canDelete =
        actor.permissions.includes("applications.delete") ||
        actor.permissions.includes("applications.manage") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canDelete) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission applications.delete required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input.applicationId || !UUID_REGEX.test(input.applicationId)) {
        return { success: false, error: "Invalid applicationId UUID" };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "delete_or_inactivate_application",
        {
          p_application_id: validated.applicationId,
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
        data?: DeleteOrInactivateApplicationData;
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
              result.message || "Failed to delete or inactivate application",
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
// 3. Update Submission by HR Command
// -----------------------------------------------------------------------------

export function createUpdateSubmissionByHrCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  UpdateSubmissionByHrInput,
  string | undefined,
  UpdateSubmissionByHrInput,
  UpdateSubmissionByHrData
> {
  return {
    name: "update_submission_by_hr",
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
        return { success: false, error: "Invalid submissionId UUID" };
      }
      if (
        !Number.isSafeInteger(input.expectedVersion) ||
        input.expectedVersion < 1
      ) {
        return {
          success: false,
          error: "expectedVersion must be a positive safe integer",
        };
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc("update_submission_by_hr", {
        p_submission_id: validated.submissionId,
        p_hr_note: validated.hrNote?.trim() || null,
        p_expected_version: validated.expectedVersion,
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
        data?: UpdateSubmissionByHrData;
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
            message: result.message || "Failed to update submission by HR",
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
// 4. Bulk Common Application Assignment Command
// -----------------------------------------------------------------------------

export function createBulkCreateOrUpdateApplicationsCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  BulkCreateOrUpdateApplicationsInput,
  string | undefined,
  BulkCreateOrUpdateApplicationsInput,
  BulkCreateOrUpdateApplicationsData
> {
  return {
    name: "bulk_create_or_update_applications",
    authorize(actor) {
      const canManage =
        actor.permissions.includes("applications.manage") &&
        actor.permissions.includes("submissions.view");
      if (!canManage && !actor.roles.includes("ROOT_ADMIN")) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason:
            "Permissions applications.manage and submissions.view required",
        };
      }
      return { authorized: true };
    },
    validate(input) {
      if (
        !Array.isArray(input.submissionIds) ||
        input.submissionIds.length === 0
      ) {
        return {
          success: false,
          error: "At least one submissionId is required",
        };
      }
      if (!input.unitId || !UUID_REGEX.test(input.unitId)) {
        return { success: false, error: "Invalid unitId UUID" };
      }
      if (
        input.departmentTeamId !== null &&
        !UUID_REGEX.test(input.departmentTeamId)
      ) {
        return { success: false, error: "Invalid departmentTeamId UUID" };
      }
      if (!input.positionId || !UUID_REGEX.test(input.positionId)) {
        return { success: false, error: "Invalid positionId UUID" };
      }
      if (!input.hrOwnerId || !UUID_REGEX.test(input.hrOwnerId)) {
        return { success: false, error: "Invalid hrOwnerId UUID" };
      }
      if (!input.idempotencyKey || !UUID_REGEX.test(input.idempotencyKey)) {
        return { success: false, error: "idempotencyKey must be a valid UUID" };
      }

      const submissionIds = new Set<string>();
      for (const submissionId of input.submissionIds) {
        if (!submissionId || !UUID_REGEX.test(submissionId)) {
          return { success: false, error: "Invalid submissionId UUID" };
        }
        if (submissionIds.has(submissionId)) {
          return {
            success: false,
            error: "Duplicate submissionId is not allowed",
          };
        }
        submissionIds.add(submissionId);
      }
      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "bulk_create_or_update_applications",
        {
          p_submission_ids: validated.submissionIds,
          p_unit_id: validated.unitId,
          p_department_team_id: validated.departmentTeamId,
          p_position_id: validated.positionId,
          p_hr_owner_id: validated.hrOwnerId,
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
        data?: BulkCreateOrUpdateApplicationsData;
      };

      if (!result.success || !result.data) {
        return {
          success: false,
          error: {
            code: mapRpcErrorCode(result.error_code),
            message: result.message || "Failed to assign Applications",
          },
        };
      }

      return { success: true, data: result.data };
    },
  };
}

// -----------------------------------------------------------------------------
// Public Helpers
// -----------------------------------------------------------------------------

export async function createOrUpdateApplication(
  input: CreateOrUpdateApplicationInput,
  deps: ApplicationLifecycleCommandDeps = {},
): Promise<CommandResult<CreateOrUpdateApplicationData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createCreateOrUpdateApplicationCommand(supabase), input);
}

export async function deleteOrInactivateApplication(
  input: DeleteOrInactivateApplicationInput,
  deps: ApplicationLifecycleCommandDeps = {},
): Promise<CommandResult<DeleteOrInactivateApplicationData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createDeleteOrInactivateApplicationCommand(supabase), input);
}

export async function updateSubmissionByHr(
  input: UpdateSubmissionByHrInput,
  deps: ApplicationLifecycleCommandDeps = {},
): Promise<CommandResult<UpdateSubmissionByHrData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createUpdateSubmissionByHrCommand(supabase), input);
}

export async function bulkCreateOrUpdateApplications(
  input: BulkCreateOrUpdateApplicationsInput,
  deps: ApplicationLifecycleCommandDeps = {},
): Promise<CommandResult<BulkCreateOrUpdateApplicationsData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveBulkActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createBulkCreateOrUpdateApplicationsCommand(supabase), input);
}
