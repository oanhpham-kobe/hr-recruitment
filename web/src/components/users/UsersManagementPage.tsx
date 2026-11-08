"use client";

import type React from "react";
import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  assignHrRoleAction,
  createInternalUserAction,
  getUserManagementDependenciesAction,
  getUserPermissionsAction,
  grantHrPermissionAction,
  type InternalUserDirectoryRecord,
  listInternalUsersAction,
  revokeHrPermissionAction,
  revokeHrRoleAction,
  setInternalUserActiveAction,
  updateInternalUserDirectoryAction,
} from "@/app/users/actions";
import { useAppLocale } from "@/components/shell/LocaleProvider";
import type { InternalNavigationIdentity } from "@/components/shell/navigation";
import { PageContext } from "@/components/ui/PageContext";
import { RowActions } from "@/components/ui/RowActions";
import { DELEGABLE_PERMISSIONS } from "@/lib/auth/permissions";

export interface UsersManagementPageProps {
  identity?: InternalNavigationIdentity | null;
  initialUsers?: InternalUserDirectoryRecord[];
  initialDependencies?: {
    units: Array<{ unit_id: string; code: string; name_vi: string }>;
  };
}

export function UsersManagementPage({
  identity,
  initialUsers = [],
  initialDependencies = { units: [] },
}: UsersManagementPageProps) {
  const { locale } = useAppLocale();
  const t = (vi: string, en: string) => (locale === "vi" ? vi : en);
  const [users, setUsers] =
    useState<InternalUserDirectoryRecord[]>(initialUsers);
  const [loading, setLoading] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const [statusFilter, setStatusFilter] = useState<
    "ALL" | "ACTIVE" | "INACTIVE"
  >("ALL");
  const [roleFilter, setRoleFilter] = useState<"ALL" | "ROOT" | "HR" | "STAFF">(
    "ALL",
  );
  const [dependencies, setDependencies] = useState(initialDependencies);

  // Global alerts
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [modalError, setModalError] = useState<string | null>(null);

  // Modal states
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [editingUser, setEditingUser] =
    useState<InternalUserDirectoryRecord | null>(null);
  const [statusUser, setStatusUser] =
    useState<InternalUserDirectoryRecord | null>(null);
  const [permissionsUser, setPermissionsUser] =
    useState<InternalUserDirectoryRecord | null>(null);
  const [userPermissions, setUserPermissions] = useState<string[]>([]);
  const [loadingPermissions, setLoadingPermissions] = useState(false);

  // Form states
  const [formEmail, setFormEmail] = useState("");
  const [formFullName, setFormFullName] = useState("");
  const [formJobTitle, setFormJobTitle] = useState("");
  const [formUnitId, setFormUnitId] = useState("");
  const [formSubmitting, setFormSubmitting] = useState(false);

  // Post-refresh focus target key
  const [focusTargetKey, setFocusTargetKey] = useState<string | null>(null);

  // Focus management refs
  const createTriggerRef = useRef<HTMLButtonElement>(null);
  const actionTriggerRefs = useRef<Record<string, HTMLButtonElement | null>>(
    {},
  );
  const lastActiveTriggerRef = useRef<HTMLElement | null>(null);
  const activeModalRef = useRef<HTMLDivElement>(null);

  const searchInputId = useId();
  const statusFilterId = useId();
  const roleFilterId = useId();

  const isRootAdmin = useMemo(() => {
    if (!identity) return false;
    return identity.roles.includes("ROOT_ADMIN");
  }, [identity]);

  const canManageDirectory = useMemo(() => {
    if (!identity) return false;
    return (
      isRootAdmin || identity.permissions.includes("users.directory_manage")
    );
  }, [identity, isRootAdmin]);

  const canViewDirectory = useMemo(() => {
    if (!identity) return false;
    return (
      canManageDirectory ||
      identity.permissions.includes("users.directory_read") ||
      identity.permissions.includes("users.permissions_manage")
    );
  }, [identity, canManageDirectory]);

  // Load directory users
  const loadUsersData = useCallback(async () => {
    setLoading(true);
    setErrorMessage(null);
    try {
      const [usersRes, depsRes] = await Promise.all([
        listInternalUsersAction(true),
        getUserManagementDependenciesAction(),
      ]);

      if (usersRes.success) {
        setUsers(usersRes.data);
      } else {
        setErrorMessage(usersRes.error);
      }
      setDependencies(depsRes);
    } catch (err) {
      setErrorMessage(
        err instanceof Error ? err.message : "Lỗi khi tải danh bạ người dùng",
      );
    } finally {
      setLoading(false);
    }
  }, []);

  // Filter users
  const filteredUsers = useMemo(() => {
    return users.filter((u) => {
      if (statusFilter === "ACTIVE" && !u.isActive) return false;
      if (statusFilter === "INACTIVE" && u.isActive) return false;

      if (roleFilter === "ROOT" && !u.isRootAdmin) return false;
      if (roleFilter === "HR" && (!u.isHr || u.isRootAdmin)) return false;
      if (roleFilter === "STAFF" && (u.isHr || u.isRootAdmin)) return false;

      if (!searchTerm) return true;
      const lower = searchTerm.toLowerCase();
      return (
        u.fullName.toLowerCase().includes(lower) ||
        u.email.toLowerCase().includes(lower) ||
        u.jobTitle?.toLowerCase().includes(lower)
      );
    });
  }, [users, statusFilter, roleFilter, searchTerm]);

  // Open Create Modal
  const openCreateModal = () => {
    lastActiveTriggerRef.current = createTriggerRef.current;
    setFormEmail("");
    setFormFullName("");
    setFormJobTitle("");
    setFormUnitId("");
    setErrorMessage(null);
    setModalError(null);
    setIsCreateOpen(true);
  };

  // Open Edit Modal
  const openEditModal = (user: InternalUserDirectoryRecord) => {
    lastActiveTriggerRef.current =
      actionTriggerRefs.current[`edit-${user.appUserId}`] ?? null;
    setEditingUser(user);
    setFormEmail(user.email);
    setFormFullName(user.fullName);
    setFormJobTitle(user.jobTitle || "");
    setFormUnitId(user.unitId || "");
    setErrorMessage(null);
    setModalError(null);
  };

  // Open Permissions Modal (Root only)
  const openPermissionsModal = async (user: InternalUserDirectoryRecord) => {
    lastActiveTriggerRef.current =
      actionTriggerRefs.current[`perm-${user.appUserId}`] ?? null;
    setPermissionsUser(user);
    setModalError(null);
    setLoadingPermissions(true);
    try {
      const res = await getUserPermissionsAction(user.appUserId);
      if (res.success) {
        setUserPermissions(res.data);
      } else {
        setModalError(res.error);
      }
    } catch (err) {
      setModalError(
        err instanceof Error ? err.message : "Lỗi khi tải quyền người dùng",
      );
    } finally {
      setLoadingPermissions(false);
    }
  };

  // Open Status Confirmation Modal
  const openStatusModal = (user: InternalUserDirectoryRecord) => {
    lastActiveTriggerRef.current =
      actionTriggerRefs.current[`status-${user.appUserId}`] ?? null;
    setStatusUser(user);
    setModalError(null);
  };

  // Close modals
  const closeModals = useCallback((restoreFocus = true) => {
    setIsCreateOpen(false);
    setEditingUser(null);
    setStatusUser(null);
    setPermissionsUser(null);
    setFormSubmitting(false);
    setModalError(null);
    if (restoreFocus) {
      setTimeout(() => {
        lastActiveTriggerRef.current?.focus();
      }, 0);
    }
  }, []);

  // Post-refresh focus restoration effect
  useEffect(() => {
    if (!focusTargetKey || loading) return;

    if (focusTargetKey === "create-trigger") {
      createTriggerRef.current?.focus();
      setFocusTargetKey(null);
      return;
    }

    const targetEl = actionTriggerRefs.current[focusTargetKey];
    if (targetEl && document.contains(targetEl)) {
      targetEl.focus();
    } else {
      createTriggerRef.current?.focus();
    }
    setFocusTargetKey(null);
  }, [focusTargetKey, loading]);

  // Handle Create Submit
  const handleCreateSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setFormSubmitting(true);
    setModalError(null);

    const res = await createInternalUserAction({
      email: formEmail.trim().toLowerCase(),
      fullName: formFullName.trim(),
      jobTitle: formJobTitle.trim() || null,
      unitId: formUnitId || null,
    });
    setFormSubmitting(false);

    if (res.success) {
      setSuccessMessage(`Đã tạo thành công người dùng "${formFullName}".`);
      closeModals(false);
      setFocusTargetKey("create-trigger");
      await loadUsersData();
    } else {
      setModalError(res.error);
    }
  };

  // Handle Edit Submit
  const handleEditSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingUser) return;
    setFormSubmitting(true);
    setModalError(null);

    const targetKey = `edit-${editingUser.appUserId}`;
    const patch: {
      fullName?: string | null;
      jobTitle?: string | null;
      unitId?: string | null;
      email?: string | null;
    } = {
      fullName: formFullName.trim(),
      jobTitle: formJobTitle.trim() || null,
      unitId: formUnitId || null,
    };

    if (!editingUser.identityBound) {
      patch.email = formEmail.trim().toLowerCase();
    }

    const res = await updateInternalUserDirectoryAction(
      editingUser.appUserId,
      patch,
      editingUser.versionNo,
    );
    setFormSubmitting(false);

    if (res.success) {
      setSuccessMessage(`Đã cập nhật thành công người dùng "${formFullName}".`);
      closeModals(false);
      setFocusTargetKey(targetKey);
      await loadUsersData();
    } else {
      const isStale =
        res.code === "STALE_VERSION" || res.error?.includes("STALE_VERSION");
      setModalError(
        isStale
          ? "Dữ liệu người dùng đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng đóng hộp thoại và tải lại trang."
          : res.error,
      );
    }
  };

  // Handle Status Toggle Confirm (Lock / Unlock)
  const handleStatusConfirm = async () => {
    if (!statusUser) return;
    setFormSubmitting(true);
    setModalError(null);

    const targetKey = `status-${statusUser.appUserId}`;
    const nextActive = !statusUser.isActive;
    const res = await setInternalUserActiveAction(
      statusUser.appUserId,
      nextActive,
      statusUser.versionNo,
    );
    setFormSubmitting(false);

    if (res.success) {
      const msg = nextActive
        ? `Đã kích hoạt người dùng "${statusUser.fullName}".`
        : `Đã khóa người dùng "${statusUser.fullName}".`;
      setSuccessMessage(msg);
      closeModals(false);
      setFocusTargetKey(targetKey);
      await loadUsersData();
    } else {
      const isStale =
        res.code === "STALE_VERSION" || res.error?.includes("STALE_VERSION");
      setModalError(
        isStale
          ? "Dữ liệu người dùng đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng đóng hộp thoại và tải lại trang."
          : res.error,
      );
    }
  };

  // Handle HR Role Toggle (Root only)
  const handleToggleHrRole = async () => {
    if (!permissionsUser) return;
    setFormSubmitting(true);
    setModalError(null);

    const res = permissionsUser.isHr
      ? await revokeHrRoleAction(
          permissionsUser.appUserId,
          permissionsUser.versionNo,
        )
      : await assignHrRoleAction(
          permissionsUser.appUserId,
          permissionsUser.versionNo,
        );
    setFormSubmitting(false);

    if (res.success) {
      setSuccessMessage(
        permissionsUser.isHr
          ? `Đã thu hồi vai trò HR của "${permissionsUser.fullName}".`
          : `Đã gán vai trò HR với quyền mặc định cho "${permissionsUser.fullName}".`,
      );
      closeModals(false);
      setFocusTargetKey(`perm-${permissionsUser.appUserId}`);
      await loadUsersData();
    } else {
      setModalError(res.error);
    }
  };

  // Handle Single Permission Toggle (Root only)
  const handleTogglePermission = async (
    permissionCode: string,
    hasPermission: boolean,
  ) => {
    if (!permissionsUser) return;
    setFormSubmitting(true);
    setModalError(null);

    const res = hasPermission
      ? await revokeHrPermissionAction(
          permissionsUser.appUserId,
          permissionCode,
          permissionsUser.versionNo,
        )
      : await grantHrPermissionAction(
          permissionsUser.appUserId,
          permissionCode,
          permissionsUser.versionNo,
        );
    setFormSubmitting(false);

    if (res.success) {
      // Refresh local permissions and user version
      setUserPermissions((prev) =>
        hasPermission
          ? prev.filter((p) => p !== permissionCode)
          : [...prev, permissionCode],
      );
      setPermissionsUser((prev) =>
        prev ? { ...prev, versionNo: res.data.version_no } : null,
      );
      await loadUsersData();
    } else {
      setModalError(res.error);
    }
  };

  // Focus trap effect
  useEffect(() => {
    const isAnyModalOpen =
      isCreateOpen ||
      Boolean(editingUser) ||
      Boolean(statusUser) ||
      Boolean(permissionsUser);
    if (!isAnyModalOpen) return;

    // Focus first focusable element
    const container = activeModalRef.current;
    if (container) {
      const focusable = container.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );
      if (focusable.length > 0) {
        focusable[0].focus();
      }
    }

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        closeModals(true);
        return;
      }

      if (e.key === "Tab") {
        const modal = activeModalRef.current;
        if (!modal) return;
        const focusableElements = Array.from(
          modal.querySelectorAll<HTMLElement>(
            'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
          ),
        );
        if (focusableElements.length === 0) return;

        const first = focusableElements[0];
        const last = focusableElements[focusableElements.length - 1];

        if (e.shiftKey) {
          if (document.activeElement === first) {
            e.preventDefault();
            last.focus();
          }
        } else {
          if (document.activeElement === last) {
            e.preventDefault();
            first.focus();
          }
        }
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isCreateOpen, editingUser, statusUser, permissionsUser, closeModals]);

  const permissionCategories = useMemo(() => {
    const cats: Record<string, (typeof DELEGABLE_PERMISSIONS)[number][]> = {};
    for (const p of DELEGABLE_PERMISSIONS) {
      if (!cats[p.category]) cats[p.category] = [];
      cats[p.category].push(p);
    }
    return cats;
  }, []);

  return (
    <div className="users-page workflow-list-page">
      <header className="users-header">
        <div className="workflow-page-heading">
          <h1 className="users-header__title">
            {t("Người dùng & phân quyền", "Users & permissions")}
          </h1>
          <PageContext>
            {t(
              "Quản lý nhân sự, tài khoản và quyền truy cập.",
              "Manage staff, accounts and access permissions.",
            )}
          </PageContext>
        </div>
        {canManageDirectory && (
          <div className="users-header__actions">
            <button
              ref={createTriggerRef}
              type="button"
              className="users-btn-primary"
              onClick={openCreateModal}
            >
              {t("+ Thêm người dùng", "+ Add user")}
            </button>
          </div>
        )}
      </header>

      {/* Global Alerts */}
      {errorMessage && (
        <div className="ui-alert ui-alert--error" role="alert">
          {errorMessage}
        </div>
      )}

      {successMessage && (
        <div
          className="ui-alert ui-alert--success"
          role="status"
          aria-live="polite"
        >
          {successMessage}
        </div>
      )}

      {!canViewDirectory && (
        <div className="ui-alert ui-alert--error" role="alert">
          Bạn không có quyền xem danh bạ người dùng (cần quyền{" "}
          <code>users.directory_read</code>, <code>users.directory_manage</code>
          , hoặc <code>ROOT_ADMIN</code>).
        </div>
      )}

      {/* Controls Bar */}
      <section
        className="users-controls"
        aria-label="Bộ lọc và tìm kiếm người dùng"
      >
        <div className="users-controls__group">
          <label htmlFor={statusFilterId} className="users-controls__label">
            Trạng thái:
          </label>
          <select
            id={statusFilterId}
            className="users-controls__select"
            value={statusFilter}
            onChange={(e) =>
              setStatusFilter(e.target.value as "ALL" | "ACTIVE" | "INACTIVE")
            }
          >
            <option value="ALL">{t("Tất cả", "All")}</option>
            <option value="ACTIVE">{t("Hoạt động", "Active")}</option>
            <option value="INACTIVE">{t("Đã khóa", "Inactive")}</option>
          </select>

          <label htmlFor={roleFilterId} className="users-controls__label">
            Vai trò:
          </label>
          <select
            id={roleFilterId}
            className="users-controls__select"
            value={roleFilter}
            onChange={(e) =>
              setRoleFilter(e.target.value as "ALL" | "ROOT" | "HR" | "STAFF")
            }
          >
            <option value="ALL">{t("Tất cả vai trò", "All roles")}</option>
            <option value="ROOT">Root Admin</option>
            <option value="HR">Nhân sự (HR)</option>
            <option value="STAFF">Hội đồng / Khác</option>
          </select>
        </div>

        <div className="users-controls__group">
          <label htmlFor={searchInputId} className="sr-only">
            Tìm theo tên hoặc email
          </label>
          <input
            id={searchInputId}
            type="search"
            className="users-controls__search"
            placeholder="Tìm theo họ tên hoặc email @eiu.edu.vn..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
        </div>
      </section>

      {/* Table */}
      <div className="users-table-container">
        <table className="users-table" aria-label="Danh sách nhân sự nội bộ">
          <colgroup>
            <col style={{ width: "20%" }} />
            <col style={{ width: "24%" }} />
            <col style={{ width: "20%" }} />
            <col style={{ width: 130 }} />
            <col style={{ width: 140 }} />
            {canManageDirectory && <col style={{ width: 144 }} />}
          </colgroup>
          <thead>
            <tr>
              <th scope="col">{t("Họ và tên", "Full name")}</th>
              <th scope="col">{t("Email & danh tính", "Email & identity")}</th>
              <th scope="col">{t("Chức danh / Đơn vị", "Job title / Unit")}</th>
              <th scope="col">{t("Vai trò", "Role")}</th>
              <th scope="col">{t("Trạng thái", "Status")}</th>

              {canManageDirectory && (
                <th scope="col">{t("Thao tác", "Actions")}</th>
              )}
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td
                  colSpan={canManageDirectory ? 6 : 5}
                  style={{ textAlign: "center", padding: "2rem" }}
                >
                  Đang tải dữ liệu...
                </td>
              </tr>
            ) : filteredUsers.length === 0 ? (
              <tr>
                <td
                  colSpan={canManageDirectory ? 6 : 5}
                  style={{ textAlign: "center", padding: "2rem" }}
                >
                  Không tìm thấy nhân sự nào phù hợp.
                </td>
              </tr>
            ) : (
              filteredUsers.map((user) => {
                const unitName =
                  dependencies.units.find((u) => u.unit_id === user.unitId)
                    ?.name_vi || "";
                return (
                  <tr key={user.appUserId}>
                    <td data-label="Họ và tên">
                      <strong>{user.fullName}</strong>
                    </td>
                    <td data-label="Email & Danh tính">
                      <div>
                        <span>{user.email}</span>
                      </div>
                      <div className="text-muted" style={{ fontSize: "1rem" }}>
                        {user.identityBound ? (
                          <span style={{ color: "var(--status-success-text)" }}>
                            ● Đã liên kết Auth
                          </span>
                        ) : (
                          <span style={{ color: "var(--ink-600)" }}>
                            ○ Chưa liên kết Auth
                          </span>
                        )}
                      </div>
                    </td>
                    <td data-label="Chức danh / Đơn vị">
                      <div>{user.jobTitle || "—"}</div>
                      {unitName && (
                        <div
                          className="text-muted"
                          style={{ fontSize: "1rem" }}
                        >
                          {unitName}
                        </div>
                      )}
                    </td>
                    <td data-label="Vai trò">
                      {user.isRootAdmin ? (
                        <span className="users-badge users-badge--root">
                          Root Admin
                        </span>
                      ) : user.isHr ? (
                        <span className="users-badge users-badge--hr">HR</span>
                      ) : (
                        <span className="users-badge users-badge--inactive">
                          Staff
                        </span>
                      )}
                    </td>
                    <td data-label="Trạng thái">
                      {user.isActive ? (
                        <span className="users-badge users-badge--active">
                          Hoạt động
                        </span>
                      ) : (
                        <span className="users-badge users-badge--inactive">
                          Đã khóa
                        </span>
                      )}
                    </td>

                    {canManageDirectory && (
                      <td className="actions-cell">
                        <div className="table-row-actions">
                          <button
                            ref={(el) => {
                              actionTriggerRefs.current[
                                `edit-${user.appUserId}`
                              ] = el;
                            }}
                            type="button"
                            className="users-btn-secondary workflow-edit-action"
                            onClick={() => openEditModal(user)}
                          >
                            Sửa
                          </button>

                          {!user.isRootAdmin && (
                            <RowActions
                              label={t("Thao tác khác", "More actions")}
                            >
                              {isRootAdmin && !user.isRootAdmin && (
                                <button
                                  ref={(el) => {
                                    actionTriggerRefs.current[
                                      `perm-${user.appUserId}`
                                    ] = el;
                                  }}
                                  type="button"
                                  className="users-btn-secondary"
                                  onClick={() => openPermissionsModal(user)}
                                >
                                  Phân quyền
                                </button>
                              )}

                              {!user.isRootAdmin &&
                                (isRootAdmin || !user.isHr) && (
                                  <button
                                    ref={(el) => {
                                      actionTriggerRefs.current[
                                        `status-${user.appUserId}`
                                      ] = el;
                                    }}
                                    type="button"
                                    className="users-btn-secondary"
                                    style={{
                                      color: user.isActive
                                        ? "#dc2626"
                                        : undefined,
                                    }}
                                    onClick={() => openStatusModal(user)}
                                  >
                                    {user.isActive ? "Khóa" : "Mở khóa"}
                                  </button>
                                )}
                            </RowActions>
                          )}
                        </div>
                      </td>
                    )}
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* Modal: Create User */}
      {isCreateOpen && (
        <div className="modal-overlay" role="presentation">
          <div
            ref={activeModalRef}
            className="modal-content"
            role="dialog"
            aria-modal="true"
            aria-labelledby="create-user-title"
          >
            <div className="modal-header">
              <h2 id="create-user-title" className="modal-header__title">
                Thêm người dùng mới
              </h2>
              <button
                type="button"
                className="users-btn-secondary"
                onClick={() => closeModals(true)}
                aria-label="Đóng"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleCreateSubmit}>
              <div className="modal-body">
                {modalError && (
                  <div
                    className="ui-alert ui-alert--error"
                    role="alert"
                    style={{ marginBottom: "1rem" }}
                  >
                    {modalError}
                  </div>
                )}

                <div className="form-group">
                  <label className="form-label" htmlFor="create-email">
                    Email EIU (@eiu.edu.vn){" "}
                    <span style={{ color: "#dc2626" }}>*</span>
                  </label>
                  <input
                    id="create-email"
                    type="email"
                    className="form-input"
                    value={formEmail}
                    onChange={(e) => setFormEmail(e.target.value)}
                    required
                    placeholder="ten.ho@eiu.edu.vn"
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="create-fullname">
                    Họ và tên <span style={{ color: "#dc2626" }}>*</span>
                  </label>
                  <input
                    id="create-fullname"
                    type="text"
                    className="form-input"
                    value={formFullName}
                    onChange={(e) => setFormFullName(e.target.value)}
                    required
                    placeholder="Nguyễn Văn A"
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="create-jobtitle">
                    Chức danh (Job Title)
                  </label>
                  <input
                    id="create-jobtitle"
                    type="text"
                    className="form-input"
                    value={formJobTitle}
                    onChange={(e) => setFormJobTitle(e.target.value)}
                    placeholder="VD: Chuyên viên nhân sự, Giảng viên..."
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="create-unit">
                    Thuộc Khoa / Phòng
                  </label>
                  <select
                    id="create-unit"
                    className="form-select"
                    value={formUnitId}
                    onChange={(e) => setFormUnitId(e.target.value)}
                  >
                    <option value="">-- Chưa phân khoa/phòng --</option>
                    {dependencies.units.map((u) => (
                      <option key={u.unit_id} value={u.unit_id}>
                        {u.name_vi} ({u.code})
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="modal-footer">
                <button
                  type="button"
                  className="users-btn-secondary"
                  onClick={() => closeModals(true)}
                  disabled={formSubmitting}
                >
                  Hủy bỏ
                </button>
                <button
                  type="submit"
                  className="users-btn-primary"
                  disabled={formSubmitting}
                >
                  {formSubmitting ? "Đang lưu..." : "Tạo người dùng"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal: Edit User */}
      {editingUser && (
        <div className="modal-overlay" role="presentation">
          <div
            ref={activeModalRef}
            className="modal-content"
            role="dialog"
            aria-modal="true"
            aria-labelledby="edit-user-title"
          >
            <div className="modal-header">
              <h2 id="edit-user-title" className="modal-header__title">
                Chỉnh sửa thông tin người dùng
              </h2>
              <button
                type="button"
                className="users-btn-secondary"
                onClick={() => closeModals(true)}
                aria-label="Đóng"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleEditSubmit}>
              <div className="modal-body">
                {modalError && (
                  <div
                    className="ui-alert ui-alert--error"
                    role="alert"
                    style={{ marginBottom: "1rem" }}
                  >
                    {modalError}
                  </div>
                )}

                <div className="form-group">
                  <label className="form-label" htmlFor="edit-email">
                    Email EIU{" "}
                    {editingUser.identityBound && (
                      <span className="text-muted" style={{ fontWeight: 400 }}>
                        (Đã liên kết Auth — email cố định; thay đổi danh tính
                        yêu cầu quy trình bảo mật riêng)
                      </span>
                    )}
                  </label>
                  <input
                    id="edit-email"
                    type="email"
                    className="form-input"
                    value={formEmail}
                    onChange={(e) => setFormEmail(e.target.value)}
                    disabled={editingUser.identityBound}
                    required
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="edit-fullname">
                    Họ và tên <span style={{ color: "#dc2626" }}>*</span>
                  </label>
                  <input
                    id="edit-fullname"
                    type="text"
                    className="form-input"
                    value={formFullName}
                    onChange={(e) => setFormFullName(e.target.value)}
                    required
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="edit-jobtitle">
                    Chức danh (Job Title)
                  </label>
                  <input
                    id="edit-jobtitle"
                    type="text"
                    className="form-input"
                    value={formJobTitle}
                    onChange={(e) => setFormJobTitle(e.target.value)}
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="edit-unit">
                    Thuộc Khoa / Phòng
                  </label>
                  <select
                    id="edit-unit"
                    className="form-select"
                    value={formUnitId}
                    onChange={(e) => setFormUnitId(e.target.value)}
                  >
                    <option value="">-- Chưa phân khoa/phòng --</option>
                    {dependencies.units.map((u) => (
                      <option key={u.unit_id} value={u.unit_id}>
                        {u.name_vi} ({u.code})
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="modal-footer">
                <button
                  type="button"
                  className="users-btn-secondary"
                  onClick={() => closeModals(true)}
                  disabled={formSubmitting}
                >
                  Hủy bỏ
                </button>
                <button
                  type="submit"
                  className="users-btn-primary"
                  disabled={formSubmitting}
                >
                  {formSubmitting ? "Đang lưu..." : "Lưu thay đổi"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal: Manage Permissions (Root Admin only) */}
      {permissionsUser && (
        <div className="modal-overlay" role="presentation">
          <div
            ref={activeModalRef}
            className="modal-content modal-content--large"
            role="dialog"
            aria-modal="true"
            aria-labelledby="perm-user-title"
          >
            <div className="modal-header">
              <h2 id="perm-user-title" className="modal-header__title">
                Phân quyền nhân sự: {permissionsUser.fullName} (
                {permissionsUser.email})
              </h2>
              <button
                type="button"
                className="users-btn-secondary"
                onClick={() => closeModals(true)}
                aria-label="Đóng"
              >
                ✕
              </button>
            </div>

            <div className="modal-body">
              {modalError && (
                <div
                  className="ui-alert ui-alert--error"
                  role="alert"
                  style={{ marginBottom: "1rem" }}
                >
                  {modalError}
                </div>
              )}

              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "space-between",
                  padding: "1rem",
                  backgroundColor: "var(--canvas)",
                  borderRadius: "var(--radius-control)",
                  border: "1px solid var(--line)",
                }}
              >
                <div>
                  <div style={{ fontWeight: 700, fontSize: "1.125rem" }}>
                    Vai trò HR:{" "}
                    {permissionsUser.isHr ? (
                      <span style={{ color: "var(--status-info-text)" }}>
                        ĐÃ GÁN
                      </span>
                    ) : (
                      <span style={{ color: "var(--ink-600)" }}>CHƯA GÁN</span>
                    )}
                  </div>
                  <div
                    className="text-muted"
                    style={{ fontSize: "1rem", marginTop: "0.25rem" }}
                  >
                    {permissionsUser.isHr
                      ? "Người dùng có vai trò Nhân sự và các quyền nghiệp vụ được ủy quyền."
                      : "Gán vai trò HR sẽ tự động cấp các quyền nghiệp vụ mặc định ban đầu."}
                  </div>
                </div>
                <button
                  type="button"
                  className={
                    permissionsUser.isHr
                      ? "users-btn-danger"
                      : "users-btn-primary"
                  }
                  onClick={handleToggleHrRole}
                  disabled={formSubmitting}
                >
                  {formSubmitting
                    ? "Đang xử lý..."
                    : permissionsUser.isHr
                      ? "Thu hồi vai trò HR"
                      : "Gán vai trò HR (mặc định)"}
                </button>
              </div>

              {loadingPermissions ? (
                <div style={{ textAlign: "center", padding: "1.5rem" }}>
                  Đang tải quyền chi tiết...
                </div>
              ) : (
                <div>
                  <h3
                    style={{
                      fontSize: "1rem",
                      fontWeight: 700,
                      margin: "1rem 0 0.5rem",
                    }}
                  >
                    Các quyền chi tiết (Granular Permissions):
                  </h3>
                  <div
                    style={{
                      display: "flex",
                      flexDirection: "column",
                      gap: "1rem",
                    }}
                  >
                    {Object.entries(permissionCategories).map(
                      ([cat, perms]) => (
                        <div key={cat} className="permission-category">
                          <h4 className="permission-category__title">{cat}</h4>
                          {perms.map((p) => {
                            const has = userPermissions.includes(p.code);
                            return (
                              <div key={p.code} className="permission-item">
                                <label
                                  className="form-checkbox-label"
                                  style={{ alignItems: "flex-start" }}
                                >
                                  <input
                                    type="checkbox"
                                    className="form-checkbox"
                                    checked={has}
                                    onChange={() =>
                                      handleTogglePermission(p.code, has)
                                    }
                                    disabled={formSubmitting}
                                    style={{ marginTop: "0.25rem" }}
                                  />
                                  <div className="permission-item__text">
                                    <span className="permission-item__label">
                                      {p.labelVi}
                                    </span>
                                    <span className="permission-item__code">
                                      {p.code}
                                    </span>
                                  </div>
                                </label>
                              </div>
                            );
                          })}
                        </div>
                      ),
                    )}
                  </div>
                </div>
              )}
            </div>

            <div className="modal-footer">
              <button
                type="button"
                className="users-btn-secondary"
                onClick={() => closeModals(true)}
                disabled={formSubmitting}
              >
                Đóng
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Modal: Status Confirmation (Lock / Unlock) */}
      {statusUser && (
        <div className="modal-overlay" role="presentation">
          <div
            ref={activeModalRef}
            className="modal-content"
            role="dialog"
            aria-modal="true"
            aria-labelledby="status-user-title"
          >
            <div className="modal-header">
              <h2 id="status-user-title" className="modal-header__title">
                {statusUser.isActive
                  ? "Xác nhận khóa người dùng"
                  : "Xác nhận mở khóa người dùng"}
              </h2>
              <button
                type="button"
                className="users-btn-secondary"
                onClick={() => closeModals(true)}
                aria-label="Đóng"
              >
                ✕
              </button>
            </div>

            <div className="modal-body">
              {modalError && (
                <div
                  className="ui-alert ui-alert--error"
                  role="alert"
                  style={{ marginBottom: "1rem" }}
                >
                  {modalError}
                </div>
              )}

              <p>
                Bạn có chắc chắn muốn{" "}
                <strong>{statusUser.isActive ? "khóa" : "mở khóa"}</strong> tài
                khoản người dùng: <strong>{statusUser.fullName}</strong> (
                <code>{statusUser.email}</code>)?
              </p>

              {statusUser.isActive ? (
                <div className="ui-alert ui-alert--info">
                  <strong>Lưu ý an ninh:</strong> Khi tài khoản bị khóa, người
                  dùng sẽ bị từ chối đăng nhập và không thể được phân công làm
                  người phụ trách hồ sơ (HR Owner) hoặc thành viên hội đồng
                  phỏng vấn mới.
                </div>
              ) : (
                <div className="ui-alert ui-alert--success">
                  <strong>Thông báo:</strong> Khi mở khóa, người dùng có thể
                  đăng nhập bình thường và tiếp tục các quyền nghiệp vụ đã được
                  gán.
                </div>
              )}
            </div>

            <div className="modal-footer">
              <button
                type="button"
                className="users-btn-secondary"
                onClick={() => closeModals(true)}
                disabled={formSubmitting}
              >
                Hủy bỏ
              </button>
              <button
                type="button"
                className={
                  statusUser.isActive ? "users-btn-danger" : "users-btn-primary"
                }
                onClick={handleStatusConfirm}
                disabled={formSubmitting}
              >
                {formSubmitting
                  ? "Đang xử lý..."
                  : statusUser.isActive
                    ? "Xác nhận Khóa"
                    : "Xác nhận Mở khóa"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
