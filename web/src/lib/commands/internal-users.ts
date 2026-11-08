import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import {
  DELEGABLE_PERMISSIONS,
  type PermissionDefinition,
} from "@/lib/auth/permissions";
import { getServerSession } from "@/lib/auth/session";
import { createCommandRunner } from "@/lib/commands/runner";
import {
  CommandErrorCode,
  type CommandResult,
  type TrustedCommandDefinition,
  type VerifiedActor,
} from "@/lib/commands/types";
import { createServerClient } from "@/lib/supabase/server";

export { DELEGABLE_PERMISSIONS, type PermissionDefinition };

export interface UserCommandDeps {
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

const EIU_EMAIL_REGEX = /^[^@\s]+@eiu\.edu\.vn$/i;

// -----------------------------------------------------------------------------
// 1. Create Internal User
// -----------------------------------------------------------------------------

export interface CreateInternalUserInput {
  email: string;
  fullName: string;
  jobTitle?: string | null;
  unitId?: string | null;
  idempotencyKey?: string;
}

export interface CreateInternalUserData {
  app_user_id: string;
  email: string;
  full_name: string;
  job_title: string | null;
  unit_id: string | null;
  is_active: boolean;
  is_root_admin: boolean;
  version_no: number;
}

export function createCreateInternalUserCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  CreateInternalUserInput,
  string,
  CreateInternalUserInput,
  CreateInternalUserData
> {
  return {
    name: "create_internal_user",
    extractTarget(input: CreateInternalUserInput) {
      return input.email.toLowerCase();
    },
    authorize(actor: VerifiedActor) {
      const canManage =
        actor.permissions.includes("users.directory_manage") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission users.directory_manage required",
        };
      }
      return { authorized: true };
    },
    validate(input: CreateInternalUserInput) {
      if (!input.email || !EIU_EMAIL_REGEX.test(input.email.trim())) {
        return { success: false, error: "Email phải thuộc miền @eiu.edu.vn" };
      }
      if (!input.fullName?.trim()) {
        return { success: false, error: "Họ và tên không được để trống" };
      }
      if (input.unitId && !UUID_REGEX.test(input.unitId)) {
        return { success: false, error: "unitId không hợp lệ" };
      }
      return { success: true, data: input };
    },
    async execute(_actor: VerifiedActor, validated: CreateInternalUserInput) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();
      const payload: Record<string, unknown> = {
        email: validated.email.trim().toLowerCase(),
        full_name: validated.fullName.trim(),
      };
      if (validated.jobTitle?.trim()) {
        payload.job_title = validated.jobTitle.trim();
      }
      if (validated.unitId) {
        payload.unit_id = validated.unitId;
      }

      const { data, error } = await supabase.rpc("create_internal_user", {
        p_payload: payload,
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
        data?: CreateInternalUserData;
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
            message: result.message || "Failed to create internal user",
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

export async function createInternalUser(
  input: CreateInternalUserInput,
  deps: UserCommandDeps = {},
): Promise<CommandResult<CreateInternalUserData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createCreateInternalUserCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 2. Update Internal User Directory
// -----------------------------------------------------------------------------

export interface UpdateInternalUserDirectoryInput {
  targetUserId: string;
  fullName?: string | null;
  jobTitle?: string | null;
  unitId?: string | null;
  email?: string | null;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface UpdateInternalUserDirectoryData {
  app_user_id: string;
  email: string;
  full_name: string;
  job_title: string | null;
  unit_id: string | null;
  version_no: number;
}

export function createUpdateInternalUserDirectoryCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  UpdateInternalUserDirectoryInput,
  string,
  UpdateInternalUserDirectoryInput,
  UpdateInternalUserDirectoryData
> {
  return {
    name: "update_internal_user_directory",
    extractTarget(input: UpdateInternalUserDirectoryInput) {
      return input.targetUserId;
    },
    authorize(actor: VerifiedActor) {
      const canManage =
        actor.permissions.includes("users.directory_manage") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission users.directory_manage required",
        };
      }
      return { authorized: true };
    },
    validate(input: UpdateInternalUserDirectoryInput) {
      if (!input.targetUserId || !UUID_REGEX.test(input.targetUserId)) {
        return { success: false, error: "targetUserId không hợp lệ" };
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
      if (input.email && !EIU_EMAIL_REGEX.test(input.email.trim())) {
        return { success: false, error: "Email phải thuộc miền @eiu.edu.vn" };
      }
      return { success: true, data: input };
    },
    async execute(
      _actor: VerifiedActor,
      validated: UpdateInternalUserDirectoryInput,
    ) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();
      const patch: Record<string, unknown> = {};

      if (validated.fullName !== undefined) {
        patch.full_name = validated.fullName?.trim() || null;
      }
      if (validated.jobTitle !== undefined) {
        patch.job_title = validated.jobTitle?.trim() || null;
      }
      if (validated.unitId !== undefined) {
        patch.unit_id = validated.unitId || null;
      }
      if (validated.email !== undefined) {
        patch.email = validated.email?.trim().toLowerCase() || null;
      }

      const { data, error } = await supabase.rpc(
        "update_internal_user_directory",
        {
          p_target_user_id: validated.targetUserId,
          p_patch: patch,
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
        data?: UpdateInternalUserDirectoryData;
      };

      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        const message =
          code === CommandErrorCode.STALE_VERSION
            ? "Dữ liệu người dùng đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng tải lại trang."
            : result.message || "Failed to update internal user directory";
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

export async function updateInternalUserDirectory(
  input: UpdateInternalUserDirectoryInput,
  deps: UserCommandDeps = {},
): Promise<CommandResult<UpdateInternalUserDirectoryData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createUpdateInternalUserDirectoryCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 3. Set Internal User Active (Lock / Unlock)
// -----------------------------------------------------------------------------

export interface SetInternalUserActiveInput {
  targetUserId: string;
  active: boolean;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface SetInternalUserActiveData {
  app_user_id: string;
  is_active: boolean;
  version_no: number;
}

export function createSetInternalUserActiveCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  SetInternalUserActiveInput,
  string,
  SetInternalUserActiveInput,
  SetInternalUserActiveData
> {
  return {
    name: "set_internal_user_active",
    extractTarget(input: SetInternalUserActiveInput) {
      return input.targetUserId;
    },
    authorize(actor: VerifiedActor) {
      const canManage =
        actor.permissions.includes("users.directory_manage") ||
        actor.roles.includes("ROOT_ADMIN");

      if (!canManage) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Permission users.directory_manage required",
        };
      }
      return { authorized: true };
    },
    validate(input: SetInternalUserActiveInput) {
      if (!input.targetUserId || !UUID_REGEX.test(input.targetUserId)) {
        return { success: false, error: "targetUserId không hợp lệ" };
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
      validated: SetInternalUserActiveInput,
    ) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();

      const { data, error } = await supabase.rpc("set_internal_user_active", {
        p_target_user_id: validated.targetUserId,
        p_active: validated.active,
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
        data?: SetInternalUserActiveData;
      };

      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        const message =
          code === CommandErrorCode.STALE_VERSION
            ? "Dữ liệu người dùng đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng tải lại trang."
            : result.message || "Failed to set user active status";
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

export async function setInternalUserActive(
  input: SetInternalUserActiveInput,
  deps: UserCommandDeps = {},
): Promise<CommandResult<SetInternalUserActiveData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createSetInternalUserActiveCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 4. Assign HR Role With Defaults (Root Admin only)
// -----------------------------------------------------------------------------

export interface AssignHrRoleInput {
  targetUserId: string;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface AssignHrRoleData {
  app_user_id: string;
  role_code: string;
  granted_permissions: string[];
  version_no: number;
}

export function createAssignHrRoleCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  AssignHrRoleInput,
  string,
  AssignHrRoleInput,
  AssignHrRoleData
> {
  return {
    name: "assign_hr_role_with_defaults",
    extractTarget(input: AssignHrRoleInput) {
      return input.targetUserId;
    },
    authorize(actor: VerifiedActor) {
      if (!actor.roles.includes("ROOT_ADMIN")) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Chỉ Root Admin mới có quyền phân quyền vai trò HR",
        };
      }
      return { authorized: true };
    },
    validate(input: AssignHrRoleInput) {
      if (!input.targetUserId || !UUID_REGEX.test(input.targetUserId)) {
        return { success: false, error: "targetUserId không hợp lệ" };
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
    async execute(_actor: VerifiedActor, validated: AssignHrRoleInput) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();

      const { data, error } = await supabase.rpc(
        "assign_hr_role_with_defaults",
        {
          p_target_user_id: validated.targetUserId,
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
        data?: AssignHrRoleData;
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
            message: result.message || "Failed to assign HR role",
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

export async function assignHrRole(
  input: AssignHrRoleInput,
  deps: UserCommandDeps = {},
): Promise<CommandResult<AssignHrRoleData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createAssignHrRoleCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 5. Revoke HR Role And Permissions (Root Admin only)
// -----------------------------------------------------------------------------

export interface RevokeHrRoleInput {
  targetUserId: string;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface RevokeHrRoleData {
  app_user_id: string;
  revoked_role: string;
  revoked_permissions: string[];
  version_no: number;
}

export function createRevokeHrRoleCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  RevokeHrRoleInput,
  string,
  RevokeHrRoleInput,
  RevokeHrRoleData
> {
  return {
    name: "revoke_hr_role_and_permissions",
    extractTarget(input: RevokeHrRoleInput) {
      return input.targetUserId;
    },
    authorize(actor: VerifiedActor) {
      if (!actor.roles.includes("ROOT_ADMIN")) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Chỉ Root Admin mới có quyền thu hồi vai trò HR",
        };
      }
      return { authorized: true };
    },
    validate(input: RevokeHrRoleInput) {
      if (!input.targetUserId || !UUID_REGEX.test(input.targetUserId)) {
        return { success: false, error: "targetUserId không hợp lệ" };
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
    async execute(_actor: VerifiedActor, validated: RevokeHrRoleInput) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();

      const { data, error } = await supabase.rpc("remove_hr_role", {
        p_target_user_id: validated.targetUserId,
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
        data?: RevokeHrRoleData;
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
            message: result.message || "Failed to revoke HR role",
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

export async function revokeHrRole(
  input: RevokeHrRoleInput,
  deps: UserCommandDeps = {},
): Promise<CommandResult<RevokeHrRoleData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createRevokeHrRoleCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 6. Grant HR Permission (Root Admin only)
// -----------------------------------------------------------------------------

export interface GrantHrPermissionInput {
  targetUserId: string;
  permissionCode: string;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface GrantHrPermissionData {
  app_user_id: string;
  permission_code: string;
  granted: boolean;
  version_no: number;
}

export function createGrantHrPermissionCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  GrantHrPermissionInput,
  string,
  GrantHrPermissionInput,
  GrantHrPermissionData
> {
  return {
    name: "grant_hr_permission",
    extractTarget(input: GrantHrPermissionInput) {
      return `${input.targetUserId}:${input.permissionCode}`;
    },
    authorize(actor: VerifiedActor) {
      if (!actor.roles.includes("ROOT_ADMIN")) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Chỉ Root Admin mới có quyền phân quyền",
        };
      }
      return { authorized: true };
    },
    validate(input: GrantHrPermissionInput) {
      if (!input.targetUserId || !UUID_REGEX.test(input.targetUserId)) {
        return { success: false, error: "targetUserId không hợp lệ" };
      }
      if (!input.permissionCode?.trim()) {
        return { success: false, error: "permissionCode không được để trống" };
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
    async execute(_actor: VerifiedActor, validated: GrantHrPermissionInput) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();

      const { data, error } = await supabase.rpc("grant_hr_permission", {
        p_target_user_id: validated.targetUserId,
        p_permission_code: validated.permissionCode.trim(),
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
        data?: GrantHrPermissionData;
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
            message: result.message || "Failed to grant HR permission",
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

export async function grantHrPermission(
  input: GrantHrPermissionInput,
  deps: UserCommandDeps = {},
): Promise<CommandResult<GrantHrPermissionData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createGrantHrPermissionCommand(supabase), input);
}

// -----------------------------------------------------------------------------
// 7. Revoke HR Permission (Root Admin only)
// -----------------------------------------------------------------------------

export interface RevokeHrPermissionInput {
  targetUserId: string;
  permissionCode: string;
  expectedVersionNo: number;
  idempotencyKey?: string;
}

export interface RevokeHrPermissionData {
  app_user_id: string;
  permission_code: string;
  revoked: boolean;
  version_no: number;
}

export function createRevokeHrPermissionCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  RevokeHrPermissionInput,
  string,
  RevokeHrPermissionInput,
  RevokeHrPermissionData
> {
  return {
    name: "revoke_hr_permission",
    extractTarget(input: RevokeHrPermissionInput) {
      return `${input.targetUserId}:${input.permissionCode}`;
    },
    authorize(actor: VerifiedActor) {
      if (!actor.roles.includes("ROOT_ADMIN")) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Chỉ Root Admin mới có quyền thu hồi quyền",
        };
      }
      return { authorized: true };
    },
    validate(input: RevokeHrPermissionInput) {
      if (!input.targetUserId || !UUID_REGEX.test(input.targetUserId)) {
        return { success: false, error: "targetUserId không hợp lệ" };
      }
      if (!input.permissionCode?.trim()) {
        return { success: false, error: "permissionCode không được để trống" };
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
    async execute(_actor: VerifiedActor, validated: RevokeHrPermissionInput) {
      const idempotencyKey = validated.idempotencyKey ?? crypto.randomUUID();

      const { data, error } = await supabase.rpc("revoke_hr_permission", {
        p_target_user_id: validated.targetUserId,
        p_permission_code: validated.permissionCode.trim(),
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
        data?: RevokeHrPermissionData;
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
            message: result.message || "Failed to revoke HR permission",
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

export async function revokeHrPermission(
  input: RevokeHrPermissionInput,
  deps: UserCommandDeps = {},
): Promise<CommandResult<RevokeHrPermissionData>> {
  const supabase = deps.client ?? (await createServerClient());
  const resolveActor =
    deps.resolveActor ?? (() => defaultResolveActor(supabase));
  const runner = createCommandRunner({
    resolveActor: () => resolveActor(supabase),
  });
  return runner(createRevokeHrPermissionCommand(supabase), input);
}
