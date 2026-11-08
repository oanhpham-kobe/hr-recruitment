export interface NavItem {
  href: string;
  labelVi: string;
  labelEn: string;
}

const APPLICATIONS_NAV_ITEM: NavItem = {
  href: "/",
  labelVi: "Quản lý phiếu ứng tuyển",
  labelEn: "Applications",
};

const INTERVIEWS_NAV_ITEM: NavItem = {
  href: "/interviews",
  labelVi: "Lịch phỏng vấn",
  labelEn: "Interviews",
};

const REPORTS_NAV_ITEM: NavItem = {
  href: "/reports",
  labelVi: "Báo cáo phỏng vấn",
  labelEn: "Interview Reports",
};
const FEEDBACK_NAV_ITEM: NavItem = {
  href: "/interview-feedback",
  labelVi: "Nhận xét phỏng vấn",
  labelEn: "Interview feedback",
};
const MASTER_DATA_NAV_ITEM: NavItem = {
  href: "/master-data",
  labelVi: "Danh mục",
  labelEn: "Master Data",
};
const USERS_NAV_ITEM: NavItem = {
  href: "/users",
  labelVi: "Người dùng & Phân quyền",
  labelEn: "Users & Permissions",
};

export const DEFAULT_NAV_ITEMS: readonly NavItem[] = [
  APPLICATIONS_NAV_ITEM,
  INTERVIEWS_NAV_ITEM,
  REPORTS_NAV_ITEM,
  FEEDBACK_NAV_ITEM,
  MASTER_DATA_NAV_ITEM,
  USERS_NAV_ITEM,
];

export interface InternalNavigationIdentity {
  roles: readonly string[];
  permissions: readonly string[];
}

export function resolveInternalNavItems(
  identity: InternalNavigationIdentity | null | undefined,
): NavItem[] {
  if (!identity) return [];

  if (identity.roles.includes("ROOT_ADMIN")) {
    return [...DEFAULT_NAV_ITEMS];
  }

  const items: NavItem[] = [];
  if (identity.permissions.includes("submissions.view")) {
    items.push(APPLICATIONS_NAV_ITEM);
  }
  if (identity.permissions.includes("interviews.view")) {
    items.push(INTERVIEWS_NAV_ITEM);
  }

  // Reports are shared: HR uses reports.view while Interviewer access is
  // contextual and is enforced by the report read/write backend contracts.
  items.push(REPORTS_NAV_ITEM);
  items.push(FEEDBACK_NAV_ITEM);

  if (identity.permissions.includes("master_data.manage")) {
    items.push(MASTER_DATA_NAV_ITEM);
  }
  if (
    identity.permissions.includes("users.directory_read") ||
    identity.permissions.includes("users.directory_manage") ||
    identity.permissions.includes("users.permissions_manage")
  ) {
    items.push(USERS_NAV_ITEM);
  }
  return items;
}
