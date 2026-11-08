import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { getServerSession } from "@/lib/auth/session";
import { createCommandRunner } from "@/lib/commands/runner";
import {
  CommandErrorCode,
  type CommandResult,
  type TrustedCommandDefinition,
  type VerifiedActor,
} from "@/lib/commands/types";
import { createServerClient } from "@/lib/supabase/server";

export type MasterDataType =
  | "organizational_units"
  | "department_teams"
  | "positions"
  | "position_groups"
  | "rooms"
  | "interview_formats"
  | "qualification_levels"
  | "recruitment_sources"
  | "document_types"
  | "cancellation_reasons"
  | "rejection_reasons";

export const VALID_MASTER_TYPES: readonly MasterDataType[] = [
  "organizational_units",
  "department_teams",
  "positions",
  "position_groups",
  "rooms",
  "interview_formats",
  "qualification_levels",
  "recruitment_sources",
  "document_types",
  "cancellation_reasons",
  "rejection_reasons",
] as const;

export interface MasterCommandDeps {
  client?: SupabaseClient;
  resolveActor?: (client: SupabaseClient) => Promise<VerifiedActor | null>;
}

async function defaultResolveActor(
  client: SupabaseClient,
): Promise<VerifiedActor | null> {
  const session = await getServerSession(client);
  if (!session.user?.isInternal) {
    return null;
  }
  return {
    authUserId: session.user.authUserId,
    email: session.user.email,
    isActive: true,
    roles: session.user.roles,
    permissions: session.user.permissions,
  };
}

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// -----------------------------------------------------------------------------
// 1. Create Master Item Command
// -----------------------------------------------------------------------------

export interface CreateMasterItemInput {
  masterType: MasterDataType;
  payload: Record<string, unknown>;
  idempotencyKey?: string;
}

export interface CreateMasterItemData {
  master_type: string;
  master_id: string;
  version_no: number;
  is_active: boolean;
  [key: string]: unknown;
}

export function createCreateMasterItemCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  CreateMasterItemInput,
  string,
  CreateMasterItemInput,
  CreateMasterItemData
> {
  return {
    name: "create_master_item",
    extractTarget(input: CreateMasterItemInput) {
      return input.masterType;
    },
    authorize(actor: VerifiedActor) {
      const canManage =
        actor.permissions.includes("master_data.manage") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission master_data.manage required",
        };
      }
      return { authorized: true };
    },
    validate(input: CreateMasterItemInput) {
      if (!VALID_MASTER_TYPES.includes(input.masterType)) {
        return { success: false, error: "Invalid masterType" };
      }
      if (
        !input.payload ||
        typeof input.payload !== "object" ||
        Array.isArray(input.payload)
      ) {
        return { success: false, error: "payload must be an object" };
      }
      return { success: true, data: input };
    },
    async execute(_actor: VerifiedActor, validated: CreateMasterItemInput) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();
      const { data, error } = await supabase.rpc("create_master_item", {
        p_master_type: validated.masterType,
        p_payload: validated.payload,
        p_idempotency_key: idempotencyKey,
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
        data?: CreateMasterItemData;
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
            message: result.message || "Failed to create master item",
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

export async function createMasterItem(
  input: CreateMasterItemInput,
  deps: MasterCommandDeps = {},
): Promise<CommandResult<CreateMasterItemData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createCreateMasterItemCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 2. Update Master Item Command
// -----------------------------------------------------------------------------

export interface UpdateMasterItemInput {
  masterType: MasterDataType;
  masterId: string;
  payload: Record<string, unknown>;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface UpdateMasterItemData {
  master_type: string;
  master_id: string;
  version_no: number;
  is_active: boolean;
  [key: string]: unknown;
}

export function createUpdateMasterItemCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  UpdateMasterItemInput,
  string,
  UpdateMasterItemInput,
  UpdateMasterItemData
> {
  return {
    name: "update_master_item",
    extractTarget(input: UpdateMasterItemInput) {
      return `${input.masterType}:${input.masterId}`;
    },
    authorize(actor: VerifiedActor) {
      const canManage =
        actor.permissions.includes("master_data.manage") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission master_data.manage required",
        };
      }
      return { authorized: true };
    },
    validate(input: UpdateMasterItemInput) {
      if (!VALID_MASTER_TYPES.includes(input.masterType)) {
        return { success: false, error: "Invalid masterType" };
      }
      if (!input.masterId || !UUID_REGEX.test(input.masterId)) {
        return { success: false, error: "Invalid masterId UUID" };
      }
      if (
        typeof input.expectedVersionNo !== "number" ||
        input.expectedVersionNo < 1 ||
        !Number.isInteger(input.expectedVersionNo)
      ) {
        return {
          success: false,
          error: "expectedVersionNo must be a positive integer",
        };
      }
      if (
        !input.payload ||
        typeof input.payload !== "object" ||
        Object.keys(input.payload).length === 0
      ) {
        return { success: false, error: "payload must be a non-empty object" };
      }
      return { success: true, data: input };
    },
    async execute(_actor: VerifiedActor, validated: UpdateMasterItemInput) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();
      const { data, error } = await supabase.rpc("update_master_item", {
        p_master_type: validated.masterType,
        p_master_id: validated.masterId,
        p_payload: validated.payload,
        p_expected_version_no: validated.expectedVersionNo,
        p_idempotency_key: idempotencyKey,
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
        data?: UpdateMasterItemData;
      };

      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        const message =
          code === CommandErrorCode.STALE_VERSION
            ? "Dữ liệu đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng tải lại dữ liệu."
            : result.message || "Failed to update master item";
        return {
          success: false,
          error: {
            code,
            message,
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

export async function updateMasterItem(
  input: UpdateMasterItemInput,
  deps: MasterCommandDeps = {},
): Promise<CommandResult<UpdateMasterItemData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createUpdateMasterItemCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 3. Delete Or Inactivate Master Item Command
// -----------------------------------------------------------------------------

export interface DeleteOrInactivateMasterItemInput {
  masterType: MasterDataType;
  masterId: string;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface DeleteOrInactivateMasterItemData {
  master_type: string;
  master_id: string;
  version_no: number;
  outcome: "DELETED" | "INACTIVATED";
}

export function createDeleteOrInactivateMasterItemCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  DeleteOrInactivateMasterItemInput,
  string,
  DeleteOrInactivateMasterItemInput,
  DeleteOrInactivateMasterItemData
> {
  return {
    name: "delete_or_inactivate_master_item",
    extractTarget(input: DeleteOrInactivateMasterItemInput) {
      return `${input.masterType}:${input.masterId}`;
    },
    authorize(actor: VerifiedActor) {
      const canManage =
        actor.permissions.includes("master_data.manage") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission master_data.manage required",
        };
      }
      return { authorized: true };
    },
    validate(input: DeleteOrInactivateMasterItemInput) {
      if (!VALID_MASTER_TYPES.includes(input.masterType)) {
        return { success: false, error: "Invalid masterType" };
      }
      if (!input.masterId || !UUID_REGEX.test(input.masterId)) {
        return { success: false, error: "Invalid masterId UUID" };
      }
      if (
        typeof input.expectedVersionNo !== "number" ||
        input.expectedVersionNo < 1 ||
        !Number.isInteger(input.expectedVersionNo)
      ) {
        return {
          success: false,
          error: "expectedVersionNo must be a positive integer",
        };
      }
      return { success: true, data: input };
    },
    async execute(
      _actor: VerifiedActor,
      validated: DeleteOrInactivateMasterItemInput,
    ) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();
      const { data, error } = await supabase.rpc(
        "delete_or_inactivate_master_item",
        {
          p_master_type: validated.masterType,
          p_master_id: validated.masterId,
          p_expected_version_no: validated.expectedVersionNo,
          p_idempotency_key: idempotencyKey,
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
        data?: DeleteOrInactivateMasterItemData;
      };

      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        const message =
          code === CommandErrorCode.STALE_VERSION
            ? "Dữ liệu đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng tải lại dữ liệu."
            : result.message || "Failed to delete or inactivate master item";
        return {
          success: false,
          error: {
            code,
            message,
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

export async function deleteOrInactivateMasterItem(
  input: DeleteOrInactivateMasterItemInput,
  deps: MasterCommandDeps = {},
): Promise<CommandResult<DeleteOrInactivateMasterItemData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createDeleteOrInactivateMasterItemCommand(supabase), input);
}
