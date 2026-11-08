import { assignmentOptions } from "./inbox-actions";
import {
  hasPermission,
  isRoot,
  mutate,
  ok,
  read,
  type State,
  simpleFail,
} from "./store";
export async function listInternalUsersAction() {
  return ok(read().users);
}
export async function getUserPermissionsAction(target: string) {
  return ok(
    read().users.find((u) => u.appUserId === target)?.permissions ?? [],
  );
}
export async function getUserManagementDependenciesAction() {
  return { units: assignmentOptions().units };
}
export async function createInternalUserAction(input: {
  email: string;
  fullName: string;
  jobTitle?: string | null;
  unitId?: string | null;
}) {
  return mutate("Tạo nhân sự mẫu / Create user", (s) => {
    if (!isRoot(s)) return simpleFail("FORBIDDEN");
    if (
      !/^[^@]+@eiu\.edu\.vn$/i.test(input.email) ||
      s.users.some((u) => u.email === input.email)
    )
      return simpleFail("VALIDATION_ERROR");
    const uid = crypto.randomUUID();
    s.users.push({
      appUserId: uid,
      email: input.email,
      fullName: input.fullName,
      jobTitle: input.jobTitle ?? null,
      unitId: input.unitId ?? null,
      isActive: true,
      isRootAdmin: false,
      isHr: false,
      identityBound: false,
      versionNo: 1,
      permissions: [],
    });
    return ok({ app_user_id: uid });
  });
}
function userChange(
  target: string,
  version: number,
  label: string,
  fn: (u: State["users"][number]) => void,
) {
  return mutate(label, (s) => {
    if (!isRoot(s)) return simpleFail("FORBIDDEN");
    const u = s.users.find((u) => u.appUserId === target);
    if (!u) return simpleFail("NOT_FOUND");
    if (u.isRootAdmin) return simpleFail("ROOT_ADMIN_PROTECTED");
    if (u.versionNo !== version) return simpleFail("STALE_VERSION");
    fn(u);
    u.versionNo++;
    return ok({ app_user_id: u.appUserId, version_no: u.versionNo });
  });
}
export async function updateInternalUserDirectoryAction(
  target: string,
  payload: {
    email?: string;
    fullName?: string;
    jobTitle?: string | null;
    unitId?: string | null;
  },
  version: number,
) {
  const u = read().users.find((u) => u.appUserId === target);
  if (payload.email && u?.identityBound && payload.email !== u.email)
    return simpleFail("IDENTITY_CHANGE_REQUIRED");
  return userChange(target, version, "Sửa danh bạ / Edit user", (u) =>
    Object.assign(u, payload),
  );
}
export async function setInternalUserActiveAction(
  target: string,
  active: boolean,
  version: number,
) {
  return userChange(
    target,
    version,
    "Trạng thái nhân sự / User active",
    (u) => {
      u.isActive = active;
    },
  );
}
export async function assignHrRoleAction(target: string, version: number) {
  return userChange(target, version, "Gán vai HR / Grant HR", (u) => {
    u.isHr = true;
    u.permissions = ["submissions.view", "interviews.view", "reports.view"];
  });
}
export async function revokeHrRoleAction(target: string, version: number) {
  return userChange(target, version, "Thu hồi HR / Revoke HR", (u) => {
    u.isHr = false;
    u.permissions = [];
  });
}
export async function grantHrPermissionAction(
  target: string,
  permission: string,
  version: number,
) {
  return userChange(target, version, "Cấp quyền / Grant permission", (u) => {
    if (!u.permissions.includes(permission)) u.permissions.push(permission);
  });
}
export async function revokeHrPermissionAction(
  target: string,
  permission: string,
  version: number,
) {
  return userChange(
    target,
    version,
    "Thu hồi quyền / Revoke permission",
    (u) => {
      u.permissions = u.permissions.filter((p) => p !== permission);
    },
  );
}
export async function getMasterDataItemsAction(
  type: string,
  includeInactive = true,
) {
  return ok(
    (read().catalogs[type] ?? []).filter((v) => includeInactive || v.isActive),
  );
}
export async function getMasterDataDependenciesAction() {
  const o = assignmentOptions();
  return {
    units: o.units,
    teams: o.department_teams,
    positionGroups: read()
      .catalogs.position_groups.filter((v) => v.isActive)
      .map((v) => ({
        position_group_id: v.id,
        code: v.code,
        name_vi: v.nameVi,
      })),
  };
}
export async function createMasterItemAction(
  type: string,
  payload: Record<string, unknown>,
) {
  return mutate("Tạo danh mục / Create master", (s) => {
    if (!hasPermission(s, "master_data.manage")) return simpleFail("FORBIDDEN");
    if (
      !s.catalogs[type] ||
      !payload.code ||
      !(payload.name_vi || payload.display_name)
    )
      return simpleFail("VALIDATION_ERROR");
    if (s.catalogs[type].some((v) => v.code === payload.code))
      return simpleFail("DUPLICATE_CODE");
    const mid = crypto.randomUUID();
    s.catalogs[type].push({
      id: mid,
      code: String(payload.code),
      nameVi: String(payload.name_vi ?? payload.display_name),
      nameEn: String(payload.name_en ?? ""),
      isActive: true,
      versionNo: 1,
      metadata: { ...payload },
    });
    return ok({ id: mid, master_id: mid });
  });
}
export async function updateMasterItemAction(
  type: string,
  masterId: string,
  payload: Record<string, unknown>,
  version: number,
) {
  return mutate("Sửa danh mục / Update master", (s) => {
    if (!hasPermission(s, "master_data.manage")) return simpleFail("FORBIDDEN");
    const v = s.catalogs[type]?.find((v) => v.id === masterId);
    if (!v) return simpleFail("NOT_FOUND");
    if (v.versionNo !== version) return simpleFail("STALE_VERSION");
    if (
      referenced(s, masterId) &&
      [
        "unit_id",
        "department_team_id",
        "position_group_id",
        "scope_code",
        "requires_room",
        "requires_meeting_link",
      ].some((k) => payload[k] !== undefined && payload[k] !== v.metadata?.[k])
    )
      return simpleFail("REFERENCED_STRUCTURE_IMMUTABLE");
    if (payload.name_vi !== undefined || payload.display_name !== undefined)
      v.nameVi = String(payload.name_vi ?? payload.display_name);
    if (payload.name_en !== undefined) v.nameEn = String(payload.name_en);
    if (payload.is_active !== undefined)
      v.isActive = Boolean(payload.is_active);
    v.metadata = { ...v.metadata, ...payload };
    v.versionNo++;
    return ok({ master_id: masterId, version_no: v.versionNo });
  });
}
function referenced(s: State, mid: string) {
  return (
    s.applications.some(
      (a) =>
        [a.unitId, a.departmentTeamId, a.positionId].includes(mid) ||
        a.rounds.some((r) => r.roomId === mid || r.interviewFormatId === mid),
    ) ||
    s.submissions.some((v) =>
      v.documents.some((d) => d.document_type_id === mid),
    ) ||
    s.users.some((u) => u.unitId === mid) ||
    s.submissions.some(
      (v) =>
        v.recruitment_source_id === mid ||
        v.education.some((e) => e.qualification_id === mid),
    ) ||
    Object.values(s.catalogs).some((items) =>
      items.some((v) =>
        Object.entries(v.metadata ?? {}).some(
          ([key, value]) => key.endsWith("_id") && value === mid,
        ),
      ),
    )
  );
}
export async function deleteOrInactivateMasterItemAction(
  type: string,
  masterId: string,
  version: number,
) {
  return mutate("Xóa/ngừng danh mục / Remove master", (s) => {
    if (!hasPermission(s, "master_data.manage")) return simpleFail("FORBIDDEN");
    const v = s.catalogs[type]?.find((v) => v.id === masterId);
    if (!v) return simpleFail("NOT_FOUND");
    if (v.versionNo !== version) return simpleFail("STALE_VERSION");
    const used = referenced(s, masterId);
    if (used) {
      v.isActive = false;
      v.versionNo++;
    } else s.catalogs[type] = s.catalogs[type].filter((v) => v.id !== masterId);
    return ok({
      master_id: masterId,
      action: used ? "INACTIVATED" : "DELETED",
      operation: used ? "INACTIVATED" : "DELETED",
    });
  });
}
