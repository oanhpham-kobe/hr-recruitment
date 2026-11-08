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
  createMasterItemAction,
  deleteOrInactivateMasterItemAction,
  getMasterDataDependenciesAction,
  getMasterDataItemsAction,
  type MasterDataItemRecord,
  updateMasterItemAction,
} from "@/app/master-data/actions";
import { useAppLocale } from "@/components/shell/LocaleProvider";
import type { InternalNavigationIdentity } from "@/components/shell/navigation";
import { PageContext } from "@/components/ui/PageContext";
import type { MasterDataType } from "@/lib/commands/master-data";

export interface MasterCatalogOption {
  type: MasterDataType;
  labelVi: string;
  labelEn: string;
}

export const MASTER_CATALOG_OPTIONS: readonly MasterCatalogOption[] = [
  {
    type: "organizational_units",
    labelVi: "Khoa / Phòng",
    labelEn: "Organizational Units",
  },
  {
    type: "department_teams",
    labelVi: "Ngành / Tổ",
    labelEn: "Department Teams",
  },
  {
    type: "positions",
    labelVi: "Vị trí tuyển dụng",
    labelEn: "Positions",
  },
  {
    type: "position_groups",
    labelVi: "Nhóm vị trí",
    labelEn: "Position Groups",
  },
  { type: "rooms", labelVi: "Phòng / Địa điểm", labelEn: "Rooms" },
  {
    type: "interview_formats",
    labelVi: "Hình thức phỏng vấn",
    labelEn: "Interview Formats",
  },
  {
    type: "qualification_levels",
    labelVi: "Trình độ học vấn",
    labelEn: "Qualification Levels",
  },
  {
    type: "recruitment_sources",
    labelVi: "Nguồn tuyển dụng",
    labelEn: "Recruitment Sources",
  },
  {
    type: "document_types",
    labelVi: "Loại tài liệu",
    labelEn: "Document Types",
  },
  {
    type: "cancellation_reasons",
    labelVi: "Lý do hủy",
    labelEn: "Cancellation Reasons",
  },
  {
    type: "rejection_reasons",
    labelVi: "Lý do từ chối",
    labelEn: "Rejection Reasons",
  },
];

export interface MasterDataManagementPageProps {
  identity?: InternalNavigationIdentity | null;
  initialCatalog?: MasterDataType;
  initialItems?: MasterDataItemRecord[];
  initialDependencies?: {
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
  };
}

export function MasterDataManagementPage({
  identity,
  initialCatalog = "organizational_units",
  initialItems = [],
  initialDependencies = { units: [], teams: [], positionGroups: [] },
}: MasterDataManagementPageProps) {
  const { locale } = useAppLocale();
  const t = (vi: string, en: string) => (locale === "vi" ? vi : en);
  const [selectedCatalog, setSelectedCatalog] =
    useState<MasterDataType>(initialCatalog);
  const [items, setItems] = useState<MasterDataItemRecord[]>(initialItems);
  const [loading, setLoading] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const [statusFilter, setStatusFilter] = useState<
    "ALL" | "ACTIVE" | "INACTIVE"
  >("ALL");
  const [dependencies, setDependencies] = useState(initialDependencies);

  // Alerts & announcements
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [modalError, setModalError] = useState<string | null>(null);

  // Modal states
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [editingItem, setEditingItem] = useState<MasterDataItemRecord | null>(
    null,
  );
  const [deletingItem, setDeletingItem] = useState<MasterDataItemRecord | null>(
    null,
  );

  // Form states
  const [formCode, setFormCode] = useState("");
  const [formNameVi, setFormNameVi] = useState("");
  const [formNameEn, setFormNameEn] = useState("");
  const [formBuilding, setFormBuilding] = useState("");
  const [formScopeCode, setFormScopeCode] = useState<
    "SUBMISSION" | "INTERVIEW" | "BOTH"
  >("SUBMISSION");
  const [formRequiresRoom, setFormRequiresRoom] = useState(false);
  const [formRequiresMeetingLink, setFormRequiresMeetingLink] = useState(false);
  const [formRequiresDemoTopic, setFormRequiresDemoTopic] = useState(false);
  const [formUnitId, setFormUnitId] = useState("");
  const [formTeamId, setFormTeamId] = useState("");
  const [formGroupId, setFormGroupId] = useState("");
  const [formSubmitting, setFormSubmitting] = useState(false);

  // Post-refresh focus target key (e.g. "edit-u-001" or "create-trigger")
  const [focusTargetKey, setFocusTargetKey] = useState<string | null>(null);

  // References for focus restoration and containment
  const createTriggerRef = useRef<HTMLButtonElement>(null);
  const actionTriggerRefs = useRef<Record<string, HTMLButtonElement | null>>(
    {},
  );
  const lastActiveTriggerRef = useRef<HTMLElement | null>(null);
  const activeModalRef = useRef<HTMLDivElement>(null);

  const searchInputId = useId();
  const catalogSelectId = useId();
  const statusFilterId = useId();

  const canManage = useMemo(() => {
    if (!identity) return false;
    return (
      identity.roles.includes("ROOT_ADMIN") ||
      identity.permissions.includes("master_data.manage")
    );
  }, [identity]);

  // Load catalog items when catalog type changes
  const loadCatalogData = useCallback(async (type: MasterDataType) => {
    setLoading(true);
    setErrorMessage(null);
    try {
      const [itemsRes, depsRes] = await Promise.all([
        getMasterDataItemsAction(type, true),
        getMasterDataDependenciesAction(),
      ]);

      if (itemsRes.success) {
        setItems(itemsRes.data);
      } else {
        setErrorMessage(itemsRes.error);
      }

      setDependencies(depsRes);
    } catch (err) {
      setErrorMessage(
        err instanceof Error ? err.message : "Lỗi khi tải danh mục",
      );
    } finally {
      setLoading(false);
    }
  }, []);

  const handleCatalogChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const nextType = e.target.value as MasterDataType;
    setSelectedCatalog(nextType);
    setSearchTerm("");
    setSuccessMessage(null);
    void loadCatalogData(nextType);
  };

  // Filter items
  const filteredItems = useMemo(() => {
    return items.filter((item) => {
      if (statusFilter === "ACTIVE" && !item.isActive) return false;
      if (statusFilter === "INACTIVE" && item.isActive) return false;
      if (!searchTerm) return true;
      const lower = searchTerm.toLowerCase();
      return (
        item.code.toLowerCase().includes(lower) ||
        item.nameVi.toLowerCase().includes(lower) ||
        item.nameEn?.toLowerCase().includes(lower)
      );
    });
  }, [items, statusFilter, searchTerm]);

  // Open Create Modal
  const openCreateModal = () => {
    lastActiveTriggerRef.current = createTriggerRef.current;
    setFormCode("");
    setFormNameVi("");
    setFormNameEn("");
    setFormBuilding("");
    setFormScopeCode("SUBMISSION");
    setFormRequiresRoom(false);
    setFormRequiresMeetingLink(false);
    setFormRequiresDemoTopic(false);
    setFormUnitId(dependencies.units[0]?.unit_id || "");
    setFormTeamId("");
    setFormGroupId(dependencies.positionGroups[0]?.position_group_id || "");
    setErrorMessage(null);
    setModalError(null);
    setIsCreateOpen(true);
  };

  // Open Edit Modal
  const openEditModal = (item: MasterDataItemRecord) => {
    lastActiveTriggerRef.current =
      actionTriggerRefs.current[`edit-${item.id}`] ?? null;
    setEditingItem(item);
    setFormCode(item.code);
    setFormNameVi(item.nameVi);
    setFormNameEn(item.nameEn || "");
    setFormBuilding(String(item.metadata?.building || ""));
    setFormScopeCode(
      (item.metadata?.scope_code as "SUBMISSION" | "INTERVIEW" | "BOTH") ||
        "SUBMISSION",
    );
    setFormRequiresRoom(Boolean(item.metadata?.requires_room));
    setFormRequiresMeetingLink(Boolean(item.metadata?.requires_meeting_link));
    setFormRequiresDemoTopic(Boolean(item.metadata?.requires_demo_topic));
    setFormUnitId(String(item.metadata?.unit_id || ""));
    setFormTeamId(String(item.metadata?.department_team_id || ""));
    setFormGroupId(String(item.metadata?.position_group_id || ""));
    setErrorMessage(null);
    setModalError(null);
  };

  // Close modals & optionally restore focus to initiating trigger
  const closeModals = useCallback((restoreFocus = true) => {
    setIsCreateOpen(false);
    setEditingItem(null);
    setDeletingItem(null);
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

    const payload: Record<string, unknown> = {};

    if (selectedCatalog === "rooms") {
      payload.code = formCode.trim();
      payload.display_name = formNameVi.trim();
      if (formBuilding.trim()) payload.building = formBuilding.trim();
    } else {
      payload.code = formCode.trim();
      payload.name_vi = formNameVi.trim();
      if (formNameEn.trim()) payload.name_en = formNameEn.trim();
    }

    if (selectedCatalog === "department_teams") {
      payload.unit_id = formUnitId;
    } else if (selectedCatalog === "positions") {
      payload.unit_id = formUnitId;
      if (formTeamId) payload.department_team_id = formTeamId;
      payload.position_group_id = formGroupId;
    } else if (selectedCatalog === "position_groups") {
      payload.requires_demo_topic = formRequiresDemoTopic;
    } else if (selectedCatalog === "interview_formats") {
      payload.requires_room = formRequiresRoom;
      payload.requires_meeting_link = formRequiresMeetingLink;
    } else if (selectedCatalog === "document_types") {
      payload.scope_code = formScopeCode;
    }

    const res = await createMasterItemAction(selectedCatalog, payload);
    setFormSubmitting(false);

    if (res.success) {
      setSuccessMessage(`Đã tạo thành công mục danh mục "${formNameVi}".`);
      closeModals(false);
      setFocusTargetKey("create-trigger");
      await loadCatalogData(selectedCatalog);
    } else {
      setModalError(res.error);
    }
  };

  // Handle Edit Submit
  const handleEditSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingItem) return;
    setFormSubmitting(true);
    setModalError(null);

    const targetKey = `edit-${editingItem.id}`;
    const payload: Record<string, unknown> = {};

    if (selectedCatalog === "rooms") {
      payload.display_name = formNameVi.trim();
      payload.building = formBuilding.trim() || null;
    } else {
      payload.name_vi = formNameVi.trim();
      payload.name_en = formNameEn.trim() || null;
    }

    if (selectedCatalog === "position_groups") {
      payload.requires_demo_topic = formRequiresDemoTopic;
    } else if (selectedCatalog === "interview_formats") {
      payload.requires_room = formRequiresRoom;
      payload.requires_meeting_link = formRequiresMeetingLink;
    } else if (selectedCatalog === "document_types") {
      payload.scope_code = formScopeCode;
    }

    const res = await updateMasterItemAction(
      selectedCatalog,
      editingItem.id,
      payload,
      editingItem.versionNo,
    );
    setFormSubmitting(false);

    if (res.success) {
      setSuccessMessage(`Đã cập nhật thành công mục danh mục "${formNameVi}".`);
      closeModals(false);
      setFocusTargetKey(targetKey);
      await loadCatalogData(selectedCatalog);
    } else {
      const isStale =
        res.code === "STALE_VERSION" || res.error?.includes("STALE_VERSION");
      setModalError(
        isStale
          ? "Dữ liệu đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng đóng hộp thoại và tải lại trang."
          : res.error,
      );
    }
  };

  // Handle Inactivate / Delete Confirm
  const handleDeleteConfirm = async () => {
    if (!deletingItem) return;
    setFormSubmitting(true);
    setModalError(null);

    const res = await deleteOrInactivateMasterItemAction(
      selectedCatalog,
      deletingItem.id,
      deletingItem.versionNo,
    );
    setFormSubmitting(false);

    if (res.success) {
      const outcome = res.data.outcome;
      const msg =
        outcome === "INACTIVATED"
          ? `Mục danh mục "${deletingItem.nameVi}" đã chuyển sang trạng thái Ngừng hoạt động (do đã có dữ liệu tham chiếu trong hệ thống).`
          : `Đã xóa vĩnh viễn mục danh mục "${deletingItem.nameVi}" (chưa có dữ liệu tham chiếu).`;
      setSuccessMessage(msg);
      closeModals(false);
      setFocusTargetKey("create-trigger");
      await loadCatalogData(selectedCatalog);
    } else {
      const isStale =
        res.code === "STALE_VERSION" || res.error?.includes("STALE_VERSION");
      setModalError(
        isStale
          ? "Dữ liệu đã bị thay đổi bởi người khác (phiên bản cũ). Vui lòng đóng hộp thoại và tải lại trang."
          : res.error,
      );
    }
  };

  // Dialog focus trapping and keydown handling
  useEffect(() => {
    const isAnyModalOpen =
      isCreateOpen || Boolean(editingItem) || Boolean(deletingItem);
    if (!isAnyModalOpen) return;

    // Focus first interactive control inside modal
    const modal = activeModalRef.current;
    if (modal) {
      const focusable = modal.querySelectorAll<HTMLElement>(
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
        const container = activeModalRef.current;
        if (!container) return;
        const focusableElements = Array.from(
          container.querySelectorAll<HTMLElement>(
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
  }, [isCreateOpen, editingItem, deletingItem, closeModals]);

  return (
    <div className="master-data-page workflow-list-page">
      <header className="master-data-header">
        <div className="workflow-page-heading">
          <h1 className="master-data-header__title">
            {t("Danh mục", "Master data")}
          </h1>
          <PageContext>
            {t(
              "Dữ liệu dùng chung trong quy trình tuyển dụng.",
              "Shared information for the recruitment workflow.",
            )}
          </PageContext>
        </div>
        {canManage && (
          <div className="master-data-header__actions">
            <button
              ref={createTriggerRef}
              type="button"
              className="master-data-btn-primary"
              onClick={openCreateModal}
            >
              {t("+ Thêm mới", "+ Create new")}
            </button>
          </div>
        )}
      </header>

      {/* Global Alert Messages */}
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

      {!canManage && (
        <div className="ui-alert ui-alert--error" role="alert">
          Bạn không có quyền quản lý Danh mục (cần quyền{" "}
          <code>master_data.manage</code> hoặc <code>ROOT_ADMIN</code>).
        </div>
      )}

      {/* Controls Bar */}
      <section
        className="master-data-controls"
        aria-label="Bộ lọc và chọn danh mục"
      >
        <div className="master-data-controls__select-group">
          <label
            htmlFor={catalogSelectId}
            className="master-data-controls__label"
          >
            Danh mục:
          </label>
          <select
            id={catalogSelectId}
            className="master-data-controls__select"
            value={selectedCatalog}
            onChange={handleCatalogChange}
            disabled={loading}
          >
            {MASTER_CATALOG_OPTIONS.map((cat) => (
              <option key={cat.type} value={cat.type}>
                {locale === "vi" ? cat.labelVi : cat.labelEn}
              </option>
            ))}
          </select>
        </div>

        <div className="master-data-controls__filters">
          <label
            htmlFor={statusFilterId}
            className="master-data-controls__label"
          >
            Trạng thái:
          </label>
          <select
            id={statusFilterId}
            className="master-data-controls__select"
            style={{ minWidth: "160px" }}
            value={statusFilter}
            onChange={(e) =>
              setStatusFilter(e.target.value as "ALL" | "ACTIVE" | "INACTIVE")
            }
          >
            <option value="ALL">{t("Tất cả", "All")}</option>
            <option value="ACTIVE">{t("Hoạt động", "Active")}</option>
            <option value="INACTIVE">Ngừng hoạt động / Inactive</option>
          </select>

          <label htmlFor={searchInputId} className="sr-only">
            Tìm kiếm mã hoặc tên
          </label>
          <input
            id={searchInputId}
            type="search"
            className="master-data-controls__search"
            placeholder="Tìm theo mã hoặc tên..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
        </div>
      </section>

      {/* Table */}
      <div className="master-data-table-container">
        <table className="master-data-table" aria-label="Bảng dữ liệu danh mục">
          <colgroup>
            <col style={{ width: "14%" }} />
            <col style={{ width: "26%" }} />
            <col style={{ width: "26%" }} />
            <col style={{ width: "14%" }} />

            {canManage && <col style={{ width: 180 }} />}
          </colgroup>
          <thead>
            <tr>
              <th scope="col">{t("Mã", "Code")}</th>
              <th scope="col">{t("Tên tiếng Việt", "Vietnamese name")}</th>
              <th scope="col">
                {t("Tên tiếng Anh / Thuộc tính", "English name / Properties")}
              </th>
              <th scope="col">{t("Trạng thái", "Status")}</th>

              {canManage && <th scope="col">{t("Thao tác", "Actions")}</th>}
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td
                  colSpan={canManage ? 5 : 4}
                  style={{ textAlign: "center", padding: "2rem" }}
                >
                  Đang tải dữ liệu...
                </td>
              </tr>
            ) : filteredItems.length === 0 ? (
              <tr>
                <td
                  colSpan={canManage ? 5 : 4}
                  style={{ textAlign: "center", padding: "2rem" }}
                >
                  Không có mục danh mục nào phù hợp.
                </td>
              </tr>
            ) : (
              filteredItems.map((item) => (
                <tr key={item.id}>
                  <td data-label="Mã">
                    <code>{item.code}</code>
                  </td>
                  <td data-label="Tên tiếng Việt">
                    <strong>{item.nameVi}</strong>
                  </td>
                  <td data-label="Tên tiếng Anh / Thuộc tính">
                    {item.nameEn && <div>{item.nameEn}</div>}
                    {selectedCatalog === "rooms" &&
                      Boolean(item.metadata?.building) && (
                        <div
                          className="text-muted"
                          style={{ fontSize: "1rem" }}
                        >
                          Tòa nhà: {String(item.metadata?.building)}
                        </div>
                      )}
                    {selectedCatalog === "document_types" &&
                      Boolean(item.metadata?.scope_code) && (
                        <div
                          className="text-muted"
                          style={{ fontSize: "1rem" }}
                        >
                          Phạm vi: {String(item.metadata?.scope_code)}
                        </div>
                      )}
                    {selectedCatalog === "position_groups" &&
                      Boolean(item.metadata?.requires_demo_topic) && (
                        <div
                          className="text-muted"
                          style={{ fontSize: "1rem" }}
                        >
                          (Yêu cầu đề tài demo)
                        </div>
                      )}
                    {selectedCatalog === "interview_formats" && (
                      <div className="text-muted" style={{ fontSize: "1rem" }}>
                        {item.metadata?.requires_room ? "Cần phòng | " : ""}
                        {item.metadata?.requires_meeting_link
                          ? "Cần link họp"
                          : ""}
                      </div>
                    )}
                  </td>
                  <td data-label="Trạng thái">
                    {item.isActive ? (
                      <span className="master-data-badge master-data-badge--active">
                        Đang hoạt động
                      </span>
                    ) : (
                      <span className="master-data-badge master-data-badge--inactive">
                        Ngừng hoạt động
                      </span>
                    )}
                  </td>

                  {canManage && (
                    <td className="actions-cell">
                      <div className="table-row-actions">
                        <button
                          ref={(el) => {
                            actionTriggerRefs.current[`edit-${item.id}`] = el;
                          }}
                          type="button"
                          className="master-data-btn-secondary workflow-edit-action"
                          onClick={() => openEditModal(item)}
                        >
                          Sửa
                        </button>
                        {item.isActive && (
                          <button
                            ref={(el) => {
                              actionTriggerRefs.current[`delete-${item.id}`] =
                                el;
                            }}
                            type="button"
                            className="master-data-btn-secondary"
                            style={{ color: "#dc2626" }}
                            onClick={() => {
                              lastActiveTriggerRef.current =
                                actionTriggerRefs.current[
                                  `delete-${item.id}`
                                ] ?? null;
                              setDeletingItem(item);
                              setModalError(null);
                            }}
                          >
                            Xóa / Ngừng HĐ
                          </button>
                        )}
                      </div>
                    </td>
                  )}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Modal: Create Item */}
      {isCreateOpen && (
        <div className="modal-overlay" role="presentation">
          <div
            ref={activeModalRef}
            className="modal-content"
            role="dialog"
            aria-modal="true"
            aria-labelledby="create-dialog-title"
          >
            <div className="modal-header">
              <h2 id="create-dialog-title" className="modal-header__title">
                Thêm mới mục danh mục
              </h2>
              <button
                type="button"
                className="master-data-btn-secondary"
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
                  <label className="form-label" htmlFor="create-code">
                    Mã định danh (Code){" "}
                    <span style={{ color: "#dc2626" }}>*</span>
                  </label>
                  <input
                    id="create-code"
                    type="text"
                    className="form-input"
                    value={formCode}
                    onChange={(e) => setFormCode(e.target.value)}
                    required
                    placeholder="VD: CNTT, PH-301..."
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="create-name-vi">
                    {selectedCatalog === "rooms"
                      ? "Tên phòng hiển thị"
                      : "Tên tiếng Việt"}{" "}
                    <span style={{ color: "#dc2626" }}>*</span>
                  </label>
                  <input
                    id="create-name-vi"
                    type="text"
                    className="form-input"
                    value={formNameVi}
                    onChange={(e) => setFormNameVi(e.target.value)}
                    required
                  />
                </div>

                {selectedCatalog !== "rooms" && (
                  <div className="form-group">
                    <label className="form-label" htmlFor="create-name-en">
                      Tên tiếng Anh (English Name)
                    </label>
                    <input
                      id="create-name-en"
                      type="text"
                      className="form-input"
                      value={formNameEn}
                      onChange={(e) => setFormNameEn(e.target.value)}
                    />
                  </div>
                )}

                {/* Catalog-specific fields */}
                {selectedCatalog === "rooms" && (
                  <div className="form-group">
                    <label className="form-label" htmlFor="create-building">
                      Tòa nhà (Building)
                    </label>
                    <input
                      id="create-building"
                      type="text"
                      className="form-input"
                      value={formBuilding}
                      onChange={(e) => setFormBuilding(e.target.value)}
                      placeholder="VD: Nhà B, Tòa A..."
                    />
                  </div>
                )}

                {selectedCatalog === "department_teams" && (
                  <div className="form-group">
                    <label className="form-label" htmlFor="create-unit">
                      Thuộc Khoa / Phòng{" "}
                      <span style={{ color: "#dc2626" }}>*</span>
                    </label>
                    <select
                      id="create-unit"
                      className="form-select"
                      value={formUnitId}
                      onChange={(e) => setFormUnitId(e.target.value)}
                      required
                    >
                      {dependencies.units.map((u) => (
                        <option key={u.unit_id} value={u.unit_id}>
                          {u.name_vi} ({u.code})
                        </option>
                      ))}
                    </select>
                  </div>
                )}

                {selectedCatalog === "positions" && (
                  <>
                    <div className="form-group">
                      <label className="form-label" htmlFor="create-pos-unit">
                        Thuộc Khoa / Phòng{" "}
                        <span style={{ color: "#dc2626" }}>*</span>
                      </label>
                      <select
                        id="create-pos-unit"
                        className="form-select"
                        value={formUnitId}
                        onChange={(e) => {
                          setFormUnitId(e.target.value);
                          setFormTeamId("");
                        }}
                        required
                      >
                        {dependencies.units.map((u) => (
                          <option key={u.unit_id} value={u.unit_id}>
                            {u.name_vi} ({u.code})
                          </option>
                        ))}
                      </select>
                    </div>

                    <div className="form-group">
                      <label className="form-label" htmlFor="create-pos-team">
                        Thuộc Ngành / Tổ (Tùy chọn)
                      </label>
                      <select
                        id="create-pos-team"
                        className="form-select"
                        value={formTeamId}
                        onChange={(e) => setFormTeamId(e.target.value)}
                      >
                        <option value="">-- Không phân ngành/tổ --</option>
                        {dependencies.teams
                          .filter(
                            (t) => !formUnitId || t.unit_id === formUnitId,
                          )
                          .map((t) => (
                            <option
                              key={t.department_team_id}
                              value={t.department_team_id}
                            >
                              {t.name_vi} ({t.code})
                            </option>
                          ))}
                      </select>
                    </div>

                    <div className="form-group">
                      <label className="form-label" htmlFor="create-pos-group">
                        Nhóm vị trí <span style={{ color: "#dc2626" }}>*</span>
                      </label>
                      <select
                        id="create-pos-group"
                        className="form-select"
                        value={formGroupId}
                        onChange={(e) => setFormGroupId(e.target.value)}
                        required
                      >
                        {dependencies.positionGroups.map((g) => (
                          <option
                            key={g.position_group_id}
                            value={g.position_group_id}
                          >
                            {g.name_vi} ({g.code})
                          </option>
                        ))}
                      </select>
                    </div>
                  </>
                )}

                {selectedCatalog === "position_groups" && (
                  <label className="form-checkbox-label">
                    <input
                      type="checkbox"
                      className="form-checkbox"
                      checked={formRequiresDemoTopic}
                      onChange={(e) =>
                        setFormRequiresDemoTopic(e.target.checked)
                      }
                    />
                    Yêu cầu đề tài demo (requires_demo_topic)
                  </label>
                )}

                {selectedCatalog === "interview_formats" && (
                  <div
                    style={{
                      display: "flex",
                      flexDirection: "column",
                      gap: "0.5rem",
                    }}
                  >
                    <label className="form-checkbox-label">
                      <input
                        type="checkbox"
                        className="form-checkbox"
                        checked={formRequiresRoom}
                        onChange={(e) => setFormRequiresRoom(e.target.checked)}
                      />
                      Cần phòng phỏng vấn trực tiếp (requires_room)
                    </label>
                    <label className="form-checkbox-label">
                      <input
                        type="checkbox"
                        className="form-checkbox"
                        checked={formRequiresMeetingLink}
                        onChange={(e) =>
                          setFormRequiresMeetingLink(e.target.checked)
                        }
                      />
                      Cần đường dẫn họp trực tuyến (requires_meeting_link)
                    </label>
                  </div>
                )}

                {selectedCatalog === "document_types" && (
                  <div className="form-group">
                    <label className="form-label" htmlFor="create-scope">
                      Phạm vi áp dụng (Scope Code){" "}
                      <span style={{ color: "#dc2626" }}>*</span>
                    </label>
                    <select
                      id="create-scope"
                      className="form-select"
                      value={formScopeCode}
                      onChange={(e) =>
                        setFormScopeCode(
                          e.target.value as "SUBMISSION" | "INTERVIEW" | "BOTH",
                        )
                      }
                      required
                    >
                      <option value="SUBMISSION">
                        SUBMISSION (Hồ sơ ứng tuyển)
                      </option>
                      <option value="INTERVIEW">INTERVIEW (Phỏng vấn)</option>
                      <option value="BOTH">BOTH (Cả hai)</option>
                    </select>
                  </div>
                )}
              </div>

              <div className="modal-footer">
                <button
                  type="button"
                  className="master-data-btn-secondary"
                  onClick={() => closeModals(true)}
                  disabled={formSubmitting}
                >
                  Hủy bỏ
                </button>
                <button
                  type="submit"
                  className="master-data-btn-primary"
                  disabled={formSubmitting}
                >
                  {formSubmitting ? "Đang lưu..." : "Tạo mới"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal: Edit Item */}
      {editingItem && (
        <div className="modal-overlay" role="presentation">
          <div
            ref={activeModalRef}
            className="modal-content"
            role="dialog"
            aria-modal="true"
            aria-labelledby="edit-dialog-title"
          >
            <div className="modal-header">
              <h2 id="edit-dialog-title" className="modal-header__title">
                Chỉnh sửa mục danh mục
              </h2>
              <button
                type="button"
                className="master-data-btn-secondary"
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
                  <label className="form-label" htmlFor="edit-code">
                    Mã định danh (Bất biến theo hợp đồng)
                  </label>
                  <input
                    id="edit-code"
                    type="text"
                    className="form-input"
                    value={formCode}
                    disabled
                  />
                </div>

                <div className="form-group">
                  <label className="form-label" htmlFor="edit-name-vi">
                    {selectedCatalog === "rooms"
                      ? "Tên phòng hiển thị"
                      : "Tên tiếng Việt"}{" "}
                    <span style={{ color: "#dc2626" }}>*</span>
                  </label>
                  <input
                    id="edit-name-vi"
                    type="text"
                    className="form-input"
                    value={formNameVi}
                    onChange={(e) => setFormNameVi(e.target.value)}
                    required
                  />
                </div>

                {selectedCatalog !== "rooms" && (
                  <div className="form-group">
                    <label className="form-label" htmlFor="edit-name-en">
                      Tên tiếng Anh (English Name)
                    </label>
                    <input
                      id="edit-name-en"
                      type="text"
                      className="form-input"
                      value={formNameEn}
                      onChange={(e) => setFormNameEn(e.target.value)}
                    />
                  </div>
                )}

                {selectedCatalog === "rooms" && (
                  <div className="form-group">
                    <label className="form-label" htmlFor="edit-building">
                      Tòa nhà (Building)
                    </label>
                    <input
                      id="edit-building"
                      type="text"
                      className="form-input"
                      value={formBuilding}
                      onChange={(e) => setFormBuilding(e.target.value)}
                    />
                  </div>
                )}

                {selectedCatalog === "position_groups" && (
                  <label className="form-checkbox-label">
                    <input
                      type="checkbox"
                      className="form-checkbox"
                      checked={formRequiresDemoTopic}
                      onChange={(e) =>
                        setFormRequiresDemoTopic(e.target.checked)
                      }
                    />
                    Yêu cầu đề tài demo (requires_demo_topic)
                  </label>
                )}

                {selectedCatalog === "interview_formats" && (
                  <div
                    style={{
                      display: "flex",
                      flexDirection: "column",
                      gap: "0.5rem",
                    }}
                  >
                    <label className="form-checkbox-label">
                      <input
                        type="checkbox"
                        className="form-checkbox"
                        checked={formRequiresRoom}
                        onChange={(e) => setFormRequiresRoom(e.target.checked)}
                      />
                      Cần phòng phỏng vấn trực tiếp (requires_room)
                    </label>
                    <label className="form-checkbox-label">
                      <input
                        type="checkbox"
                        className="form-checkbox"
                        checked={formRequiresMeetingLink}
                        onChange={(e) =>
                          setFormRequiresMeetingLink(e.target.checked)
                        }
                      />
                      Cần đường dẫn họp trực tuyến (requires_meeting_link)
                    </label>
                  </div>
                )}

                {selectedCatalog === "document_types" && (
                  <div className="form-group">
                    <label className="form-label" htmlFor="edit-scope">
                      Phạm vi áp dụng (Scope Code){" "}
                      <span style={{ color: "#dc2626" }}>*</span>
                    </label>
                    <select
                      id="edit-scope"
                      className="form-select"
                      value={formScopeCode}
                      onChange={(e) =>
                        setFormScopeCode(
                          e.target.value as "SUBMISSION" | "INTERVIEW" | "BOTH",
                        )
                      }
                      required
                    >
                      <option value="SUBMISSION">
                        SUBMISSION (Hồ sơ ứng tuyển)
                      </option>
                      <option value="INTERVIEW">INTERVIEW (Phỏng vấn)</option>
                      <option value="BOTH">BOTH (Cả hai)</option>
                    </select>
                  </div>
                )}
              </div>

              <div className="modal-footer">
                <button
                  type="button"
                  className="master-data-btn-secondary"
                  onClick={() => closeModals(true)}
                  disabled={formSubmitting}
                >
                  Hủy bỏ
                </button>
                <button
                  type="submit"
                  className="master-data-btn-primary"
                  disabled={formSubmitting}
                >
                  {formSubmitting ? "Đang lưu..." : "Lưu thay đổi"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal: Delete or Inactivate Confirmation */}
      {deletingItem && (
        <div className="modal-overlay" role="presentation">
          <div
            ref={activeModalRef}
            className="modal-content"
            role="dialog"
            aria-modal="true"
            aria-labelledby="delete-dialog-title"
          >
            <div className="modal-header">
              <h2 id="delete-dialog-title" className="modal-header__title">
                Xác nhận Xóa / Ngừng hoạt động
              </h2>
              <button
                type="button"
                className="master-data-btn-secondary"
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
                Bạn có chắc chắn muốn xóa hoặc ngừng hoạt động mục danh mục:{" "}
                <strong>{deletingItem.nameVi}</strong> (Mã:{" "}
                <code>{deletingItem.code}</code>)?
              </p>
              <div className="ui-alert ui-alert--info">
                <strong>Cơ chế an toàn tham chiếu:</strong>
                <ul style={{ margin: "0.5rem 0 0", paddingLeft: "1.25rem" }}>
                  <li>
                    Nếu mục danh mục này <strong>đã được sử dụng</strong> trong
                    hồ sơ ứng tuyển hoặc lịch phỏng vấn, hệ thống sẽ tự động{" "}
                    <strong>chuyển sang trạng thái Ngừng hoạt động</strong> để
                    bảo tồn lịch sử dữ liệu.
                  </li>
                  <li>
                    Nếu mục danh mục này <strong>chưa từng được sử dụng</strong>
                    , hệ thống sẽ thực hiện <strong>xóa vĩnh viễn</strong>.
                  </li>
                </ul>
              </div>
            </div>

            <div className="modal-footer">
              <button
                type="button"
                className="master-data-btn-secondary"
                onClick={() => closeModals(true)}
                disabled={formSubmitting}
              >
                Hủy bỏ
              </button>
              <button
                type="button"
                className="master-data-btn-danger"
                onClick={handleDeleteConfirm}
                disabled={formSubmitting}
              >
                {formSubmitting ? "Đang xử lý..." : "Xác nhận thực hiện"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
