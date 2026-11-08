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
// Types
// -----------------------------------------------------------------------------

export type SetCandidateActiveInput = {
  candidateId: string;
  active: boolean;
  expectedVersion: number;
  idempotencyKey?: string;
};

export type SetCandidateActiveData = {
  candidate_id: string;
  is_active: boolean;
  inactive_at: string | null;
  inactive_by: string | null;
  version_no: number;
};

export type BulkCandidateActiveItemInput = {
  candidateId: string;
  expectedVersion: number;
};

export type BulkSetCandidateActiveInput = {
  items: BulkCandidateActiveItemInput[];
  active: boolean;
  idempotencyKey: string;
};

export type BulkSetCandidateActiveData = {
  items: Array<{
    candidate_id: string;
    is_active: boolean;
    inactive_at: string | null;
    inactive_by: string | null;
    version_no: number;
  }>;
  count: number;
  idempotency_key: string;
};

export type CandidateLifecycleCommandDeps = {
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

// -----------------------------------------------------------------------------
// 1. Single Candidate Active Command
// -----------------------------------------------------------------------------

export function createSetCandidateActiveCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  SetCandidateActiveInput,
  string,
  SetCandidateActiveInput,
  SetCandidateActiveData
> {
  return {
    name: "set_candidate_active",
    extractTarget(input) {
      return input.candidateId;
    },
    authorize(actor) {
      if (!actor.isActive) {
        return {
          authorized: false,
          code: CommandErrorCode.USER_INACTIVE,
          reason: "Actor account is inactive",
        };
      }

      const isRoot = actor.roles.includes("ROOT_ADMIN");
      const canManage = actor.permissions.includes("candidates.active_manage");

      if (!isRoot && !canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission candidates.active_manage required",
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

      if (typeof input.active !== "boolean") {
        return {
          success: false,
          error: "Property active must be a boolean",
        };
      }

      if (
        typeof input.expectedVersion !== "number" ||
        !Number.isInteger(input.expectedVersion) ||
        input.expectedVersion <= 0
      ) {
        return {
          success: false,
          error: "expectedVersion must be a positive integer",
        };
      }

      if (
        input.idempotencyKey !== undefined &&
        !UUID_REGEX.test(input.idempotencyKey)
      ) {
        return {
          success: false,
          error: "idempotencyKey must be a valid UUID",
        };
      }

      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc("set_candidate_active", {
        p_candidate_id: validated.candidateId,
        p_active: validated.active,
        p_expected_version: validated.expectedVersion,
        p_idempotency_key: validated.idempotencyKey ?? null,
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
        data?: SetCandidateActiveData;
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
              result.message || "Failed to update candidate active status",
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
// 2. Bulk Set Candidate Active Command
// -----------------------------------------------------------------------------

export function createBulkSetCandidateActiveCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  BulkSetCandidateActiveInput,
  string,
  BulkSetCandidateActiveInput,
  BulkSetCandidateActiveData
> {
  return {
    name: "bulk_set_candidate_active",
    extractTarget(input) {
      return input.idempotencyKey;
    },
    authorize(actor) {
      if (!actor.isActive) {
        return {
          authorized: false,
          code: CommandErrorCode.USER_INACTIVE,
          reason: "Actor account is inactive",
        };
      }

      const isRoot = actor.roles.includes("ROOT_ADMIN");
      const canManage = actor.permissions.includes("candidates.active_manage");

      if (!isRoot && !canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission candidates.active_manage required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!Array.isArray(input.items) || input.items.length === 0) {
        return {
          success: false,
          error: "At least one candidate must be provided",
        };
      }

      if (typeof input.active !== "boolean") {
        return {
          success: false,
          error: "Property active must be a boolean",
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
          return {
            success: false,
            error: "All items must have a valid candidateId UUID",
          };
        }

        if (candidateIds.has(item.candidateId)) {
          return {
            success: false,
            error: "Duplicate candidateId detected in batch",
          };
        }
        candidateIds.add(item.candidateId);

        if (
          typeof item.expectedVersion !== "number" ||
          !Number.isInteger(item.expectedVersion) ||
          item.expectedVersion <= 0
        ) {
          return {
            success: false,
            error: "All items must have a positive integer expectedVersion",
          };
        }
      }

      return { success: true, data: input };
    },
    async execute(_actor, validated) {
      const candidateIds = validated.items.map((item) => item.candidateId);
      const expectedVersions = validated.items.map(
        (item) => item.expectedVersion,
      );

      const { data, error } = await supabase.rpc("bulk_set_candidate_active", {
        p_candidate_ids: candidateIds,
        p_active: validated.active,
        p_expected_versions: expectedVersions,
        p_idempotency_key: validated.idempotencyKey,
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
        data?: BulkSetCandidateActiveData;
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
              result.message ||
              "Failed to execute bulk candidate active status",
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

export async function setCandidateActive(
  input: SetCandidateActiveInput,
  deps: CandidateLifecycleCommandDeps = {},
): Promise<CommandResult<SetCandidateActiveData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createSetCandidateActiveCommand(supabase), input);
}

export async function bulkSetCandidateActive(
  input: BulkSetCandidateActiveInput,
  deps: CandidateLifecycleCommandDeps = {},
): Promise<CommandResult<BulkSetCandidateActiveData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({ resolveActor });
  return runner(createBulkSetCandidateActiveCommand(supabase), input);
}
