"use server";

import { getServerSession } from "@/lib/auth/session";
import {
  type CreateMasterItemData,
  createMasterItem,
  type DeleteOrInactivateMasterItemData,
  deleteOrInactivateMasterItem,
  type MasterCommandDeps,
  type MasterDataType,
  type UpdateMasterItemData,
  updateMasterItem,
  VALID_MASTER_TYPES,
} from "@/lib/commands/master-data";
import { createServerClient } from "@/lib/supabase/server";

export interface MasterDataItemRecord {
  id: string;
  code: string;
  nameVi: string;
  nameEn?: string | null;
  isActive: boolean;
  versionNo: number;
  metadata?: Record<string, unknown>;
}

const MASTER_TYPE_PK: Record<MasterDataType, string> = {
  organizational_units: "unit_id",
  department_teams: "department_team_id",
  positions: "position_id",
  position_groups: "position_group_id",
  rooms: "room_id",
  interview_formats: "interview_format_id",
  qualification_levels: "qualification_id",
  recruitment_sources: "recruitment_source_id",
  document_types: "document_type_id",
  cancellation_reasons: "cancellation_reason_id",
  rejection_reasons: "rejection_reason_id",
};

export async function getMasterDataItemsAction(
  masterType: MasterDataType,
  includeInactive = true,
  deps: MasterCommandDeps = {},
): Promise<
  | { success: true; data: MasterDataItemRecord[] }
  | { success: false; error: string; code?: string }
> {
  try {
    if (!VALID_MASTER_TYPES.includes(masterType)) {
      return {
        success: false,
        error: "Loại danh mục không hợp lệ.",
        code: "VALIDATION_ERROR",
      };
    }

    const supabase = deps.client ?? (await createServerClient());
    const session = await (deps.resolveActor
      ? null
      : getServerSession(supabase));
    if (session && !session.user?.isInternal) {
      return {
        success: false,
        error: "Bạn không có quyền xem danh mục.",
        code: "FORBIDDEN",
      };
    }

    const pk = MASTER_TYPE_PK[masterType];
    let query = supabase.from(masterType).select("*");
    if (!includeInactive) {
      query = query.eq("is_active", true);
    }

    const { data, error } = await query;
    if (error) {
      return { success: false, error: error.message, code: "INTERNAL_ERROR" };
    }

    const records: MasterDataItemRecord[] = (data || []).map(
      (row: Record<string, unknown>) => {
        const id = String(row[pk] ?? "");
        const code = String(row.code ?? "");
        const nameVi = String(row.display_name ?? row.name_vi ?? code);
        const nameEn = row.name_en ? String(row.name_en) : null;
        const isActive = Boolean(row.is_active ?? true);
        const versionNo =
          typeof row.version_no === "number" ? row.version_no : 1;

        // Extract specific metadata fields based on master type
        const metadata: Record<string, unknown> = {};
        for (const [k, v] of Object.entries(row)) {
          if (
            ![
              pk,
              "code",
              "name_vi",
              "name_en",
              "display_name",
              "is_active",
              "version_no",
              "created_at",
              "updated_at",
            ].includes(k)
          ) {
            metadata[k] = v;
          }
        }

        return {
          id,
          code,
          nameVi,
          nameEn,
          isActive,
          versionNo,
          metadata,
        };
      },
    );

    return { success: true, data: records };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : "Không thể tải danh mục.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function createMasterItemAction(
  masterType: MasterDataType,
  payload: Record<string, unknown>,
  idempotencyKey?: string,
  deps: MasterCommandDeps = {},
): Promise<
  | { success: true; data: CreateMasterItemData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await createMasterItem(
      { masterType, payload, idempotencyKey },
      deps,
    );
    if (!result.success) {
      return {
        success: false,
        error: result.error?.message ?? "Không thể tạo mục danh mục.",
        code: result.error?.code,
      };
    }
    return { success: true, data: result.data };
  } catch (error) {
    return {
      success: false,
      error:
        error instanceof Error ? error.message : "Không thể tạo mục danh mục.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function updateMasterItemAction(
  masterType: MasterDataType,
  masterId: string,
  payload: Record<string, unknown>,
  expectedVersionNo: number,
  idempotencyKey?: string,
  deps: MasterCommandDeps = {},
): Promise<
  | { success: true; data: UpdateMasterItemData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await updateMasterItem(
      { masterType, masterId, payload, expectedVersionNo, idempotencyKey },
      deps,
    );
    if (!result.success) {
      return {
        success: false,
        error: result.error?.message ?? "Không thể cập nhật mục danh mục.",
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
          : "Không thể cập nhật mục danh mục.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function deleteOrInactivateMasterItemAction(
  masterType: MasterDataType,
  masterId: string,
  expectedVersionNo: number,
  idempotencyKey?: string,
  deps: MasterCommandDeps = {},
): Promise<
  | { success: true; data: DeleteOrInactivateMasterItemData }
  | { success: false; error: string; code?: string }
> {
  try {
    const result = await deleteOrInactivateMasterItem(
      { masterType, masterId, expectedVersionNo, idempotencyKey },
      deps,
    );
    if (!result.success) {
      return {
        success: false,
        error:
          result.error?.message ??
          "Không thể xóa hoặc ngừng hoạt động mục danh mục.",
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
          : "Không thể xóa hoặc ngừng hoạt động mục danh mục.",
      code: "INTERNAL_ERROR",
    };
  }
}

export async function getMasterDataDependenciesAction(
  deps: MasterCommandDeps = {},
): Promise<{
  units: Array<{ unit_id: string; code: string; name_vi: string }>;
  teams: Array<{
    department_team_id: string;
    unit_id: string;
    code: string;
    name_vi: string;
  }>;
  positionGroups: Array<{
    position_group_id: string;
    code: string;
    name_vi: string;
  }>;
}> {
  const supabase = deps.client ?? (await createServerClient());
  const [unitsRes, teamsRes, groupsRes] = await Promise.all([
    supabase
      .from("organizational_units")
      .select("unit_id, code, name_vi")
      .eq("is_active", true)
      .order("name_vi"),
    supabase
      .from("department_teams")
      .select("department_team_id, unit_id, code, name_vi")
      .eq("is_active", true)
      .order("name_vi"),
    supabase
      .from("position_groups")
      .select("position_group_id, code, name_vi")
      .eq("is_active", true)
      .order("name_vi"),
  ]);

  return {
    units:
      (unitsRes.data as Array<{
        unit_id: string;
        code: string;
        name_vi: string;
      }> | null) || [],
    teams:
      (teamsRes.data as Array<{
        department_team_id: string;
        unit_id: string;
        code: string;
        name_vi: string;
      }> | null) || [],
    positionGroups:
      (groupsRes.data as Array<{
        position_group_id: string;
        code: string;
        name_vi: string;
      }> | null) || [],
  };
}
