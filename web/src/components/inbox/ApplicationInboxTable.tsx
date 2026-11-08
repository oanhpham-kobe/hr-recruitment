"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  useTransition,
} from "react";
import {
  bulkSetCandidateActiveAction,
  bulkSetLatestSubmissionManualStatusAction,
  openSubmissionAction,
  queryApplicationInbox,
} from "@/app/application-inbox-actions";
import {
  ApplicationInboxTableRows,
  SUBMISSION_STATUS_LABEL,
} from "@/components/inbox/ApplicationInboxTableRows";
import {
  SubmissionDetailDrawer,
  type SubmissionDetailDrawerProps,
} from "@/components/inbox/SubmissionDetailDrawer";
import { PageContext } from "@/components/ui/PageContext";
import { StatusMenu } from "@/components/ui/StatusMenu";
import {
  APPLICATION_INBOX_COLUMNS,
  APPLICATION_INBOX_PAGE_SIZES,
  type ApplicationInboxFilters,
  type ApplicationInboxGroup,
  type ApplicationInboxPageSize,
  DEFAULT_APPLICATION_INBOX_PAGE_SIZE,
  INITIAL_APPLICATION_INBOX_FILTERS,
  latestSubmission,
  nextExpandedCandidateId,
  normalizeApplicationInboxPageSize,
  type SubmissionStatus,
} from "@/lib/application-inbox/model";

export function groupHasActiveApplication(
  group: ApplicationInboxGroup,
): boolean {
  const anyGroup = group as unknown as {
    hasActiveApplication?: boolean;
    applications?: Array<{ is_active?: boolean; isActive?: boolean }>;
  };
  if (typeof anyGroup.hasActiveApplication === "boolean") {
    return anyGroup.hasActiveApplication;
  }
  if (Array.isArray(anyGroup.applications)) {
    return anyGroup.applications.some(
      (a) => a.is_active === true || a.isActive === true,
    );
  }
  const sub = latestSubmission(group);
  const anySub = sub as unknown as
    | {
        hasActiveApplication?: boolean;
        applications?: Array<{ is_active?: boolean; isActive?: boolean }>;
      }
    | undefined;
  if (typeof anySub?.hasActiveApplication === "boolean") {
    return anySub.hasActiveApplication;
  }
  if (Array.isArray(anySub?.applications)) {
    return anySub.applications.some(
      (a) => a.is_active === true || a.isActive === true,
    );
  }
  return sub?.hasApplication ?? false;
}

export interface SelectedCandidateToken {
  candidateId: string;
  candidateVersionNo: number;
  latestSubmissionId: string;
  latestSubmissionVersionNo: number;
  hasActiveApplication: boolean;
}

export interface ApplicationInboxTableActions {
  queryApplicationInbox?: typeof queryApplicationInbox;
  bulkSetLatestSubmissionManualStatusAction?: typeof bulkSetLatestSubmissionManualStatusAction;
  bulkSetCandidateActiveAction?: typeof bulkSetCandidateActiveAction;
  openSubmissionAction?: typeof openSubmissionAction;
  drawerActions?: SubmissionDetailDrawerProps["actions"];
}

export interface ApplicationInboxTableProps {
  groups: ApplicationInboxGroup[];
  errorMessage?: string;
  loading?: boolean;
  page?: number;
  pageCount?: number;
  pageSize?: ApplicationInboxPageSize;
  actions?: ApplicationInboxTableActions;
}

interface ApplicationInboxPage {
  groups: ApplicationInboxGroup[];
  page: number;
  pageCount: number;
}

export interface ApplicationInboxReadState {
  errorMessage?: string;
  inbox: ApplicationInboxPage;
}

export type ApplicationInboxReadAction =
  | { inbox: ApplicationInboxPage; type: "loaded" }
  | { message: string; type: "failed" }
  | {
      type: "submission_updated";
      submissionId: string;
      hrNote: string | null;
      versionNo: number;
      status?: SubmissionStatus;
      hasApplication: boolean;
      hasActiveApplication?: boolean;
    };

export function reduceApplicationInboxReadState(
  state: ApplicationInboxReadState,
  action: ApplicationInboxReadAction,
): ApplicationInboxReadState {
  if (action.type === "loaded") {
    return { inbox: action.inbox };
  }
  if (action.type === "failed") {
    return { ...state, errorMessage: action.message };
  }
  if (action.type === "submission_updated") {
    const updatedGroups = state.inbox.groups.map((group) => {
      const hasSub = group.submissions.some(
        (s) => s.submissionId === action.submissionId,
      );
      if (!hasSub) return group;

      const updatedSubmissions = group.submissions.map((s) => {
        if (s.submissionId !== action.submissionId) return s;
        return {
          ...s,
          hrNote: action.hrNote,
          hasApplication: action.hasApplication,
          hasActiveApplication:
            action.hasActiveApplication ?? action.hasApplication,
          versionNo: action.versionNo,
          status: action.status ?? s.status,
        };
      });

      const isLatest = group.latestSubmissionId === action.submissionId;

      return {
        ...group,
        latestSubmissionVersionNo: isLatest
          ? action.versionNo
          : group.latestSubmissionVersionNo,
        submissions: updatedSubmissions,
      };
    });

    return {
      ...state,
      inbox: {
        ...state.inbox,
        groups: updatedGroups,
      },
    };
  }
  return state;
}

function hasActiveFilters(filters: ApplicationInboxFilters): boolean {
  return Object.values(filters).some(
    (value) => value !== "" && value !== "ALL",
  );
}

export function ApplicationInboxTable({
  groups,
  errorMessage,
  loading = false,
  page = 1,
  pageCount = 1,
  pageSize: initialPageSize = DEFAULT_APPLICATION_INBOX_PAGE_SIZE,
  actions,
}: ApplicationInboxTableProps) {
  const queryInbox = actions?.queryApplicationInbox ?? queryApplicationInbox;
  const bulkSetStatus =
    actions?.bulkSetLatestSubmissionManualStatusAction ??
    bulkSetLatestSubmissionManualStatusAction;
  const bulkSetCandidateActive =
    actions?.bulkSetCandidateActiveAction ?? bulkSetCandidateActiveAction;
  const [filters, setFilters] = useState<ApplicationInboxFilters>(
    INITIAL_APPLICATION_INBOX_FILTERS,
  );
  const [debouncedFilters, setDebouncedFilters] =
    useState<ApplicationInboxFilters>(INITIAL_APPLICATION_INBOX_FILTERS);
  const [pageSize, setPageSize] = useState<ApplicationInboxPageSize>(
    normalizeApplicationInboxPageSize(initialPageSize),
  );
  const [inboxState, dispatchInboxState] = useReducer(
    reduceApplicationInboxReadState,
    {
      inbox: { groups, page, pageCount },
      errorMessage,
    },
  );
  const [isPending, startTransition] = useTransition();
  const debounceInitialized = useRef(false);
  const reloadInitialized = useRef(false);
  const requestSequence = useRef(0);
  const [expandedCandidateId, setExpandedCandidateId] = useState<string | null>(
    null,
  );
  const [selectedTokens, setSelectedTokens] = useState<
    Map<string, SelectedCandidateToken>
  >(new Map());
  const [selectionNotice, setSelectionNotice] = useState<string | null>(null);

  const selectedCandidateIds = useMemo(
    () => new Set(selectedTokens.keys()),
    [selectedTokens],
  );
  const [activeSubmissionId, setActiveSubmissionId] = useState<string | null>(
    null,
  );
  const [openingSubmissionId, setOpeningSubmissionId] = useState<string | null>(
    null,
  );
  const [isBulkActionPending, setIsBulkActionPending] = useState(false);
  const [isInactiveModalOpen, setIsInactiveModalOpen] = useState(false);
  const [feedbackMessage, setFeedbackMessage] = useState<string | null>(null);
  const [feedbackType, setFeedbackType] = useState<"success" | "error">(
    "success",
  );

  const inactiveTriggerRef = useRef<HTMLButtonElement | null>(null);
  const inactiveModalRef = useRef<HTMLDivElement | null>(null);
  const cancelInactiveBtnRef = useRef<HTMLButtonElement | null>(null);
  const triggerElementRef = useRef<HTMLElement | null>(null);
  const tableContainerRef = useRef<HTMLElement | null>(null);
  const selectionStatusRef = useRef<HTMLSpanElement | null>(null);

  const restoreFocus = useCallback(() => {
    const trigger = inactiveTriggerRef.current ?? triggerElementRef.current;
    if (
      trigger &&
      !trigger.hasAttribute("disabled") &&
      !(trigger as HTMLButtonElement).disabled &&
      typeof trigger.focus === "function"
    ) {
      trigger.focus();
      return;
    }
    if (selectionStatusRef.current) {
      selectionStatusRef.current.focus();
      return;
    }
    if (tableContainerRef.current) {
      tableContainerRef.current.focus();
      return;
    }
  }, []);

  const handleSubmissionUpdated = useCallback(
    (updated: {
      submissionId: string;
      hrNote: string | null;
      versionNo: number;
      status?: SubmissionStatus;
      hasApplication: boolean;
      hasActiveApplication?: boolean;
    }) => {
      dispatchInboxState({
        type: "submission_updated",
        submissionId: updated.submissionId,
        hrNote: updated.hrNote,
        versionNo: updated.versionNo,
        status: updated.status,
        hasApplication: updated.hasApplication,
        hasActiveApplication: updated.hasActiveApplication,
      });

      setSelectedTokens((current) => {
        let changed = false;
        const next = new Map(current);
        for (const [id, token] of next) {
          if (token.latestSubmissionId === updated.submissionId) {
            next.set(id, {
              ...token,
              latestSubmissionVersionNo: updated.versionNo,
              hasActiveApplication:
                updated.hasActiveApplication ?? updated.hasApplication,
            });
            changed = true;
          }
        }
        return changed ? next : current;
      });
    },
    [],
  );

  const handleOpenSubmission = useCallback(
    (submissionId: string) => {
      if (openingSubmissionId === submissionId) {
        return;
      }
      setOpeningSubmissionId(submissionId);
      setActiveSubmissionId(submissionId);
    },
    [openingSubmissionId],
  );

  const handleCloseDrawer = useCallback(() => {
    setActiveSubmissionId(null);
    setOpeningSubmissionId(null);
  }, []);

  const loadPage = useCallback(
    (
      nextPage: number,
      nextFilters: ApplicationInboxFilters,
      nextPageSize: ApplicationInboxPageSize,
    ) => {
      const sequence = ++requestSequence.current;
      startTransition(async () => {
        try {
          const nextInbox = await queryInbox({
            filters: nextFilters,
            page: nextPage,
            pageSize: nextPageSize,
          });
          if (sequence === requestSequence.current) {
            dispatchInboxState({ type: "loaded", inbox: nextInbox });
            setExpandedCandidateId(null);
            setSelectedTokens((current) => {
              if (current.size > 0) {
                setSelectionNotice(
                  "Đã đặt lại danh sách chọn do thay đổi trang hoặc bộ lọc.",
                );
                return new Map();
              }
              return current;
            });
          }
        } catch {
          if (sequence === requestSequence.current) {
            dispatchInboxState({
              type: "failed",
              message: "Không thể tải Phiếu Ứng tuyển. Vui lòng thử lại.",
            });
          }
        }
      });
    },
    [queryInbox],
  );

  useEffect(() => {
    if (!debounceInitialized.current) {
      debounceInitialized.current = true;
      return;
    }
    const timer = window.setTimeout(() => setDebouncedFilters(filters), 300);
    return () => window.clearTimeout(timer);
  }, [filters]);

  useEffect(() => {
    if (!reloadInitialized.current) {
      reloadInitialized.current = true;
      return;
    }
    loadPage(1, debouncedFilters, pageSize);
  }, [debouncedFilters, pageSize, loadPage]);

  const handleBulkSetStatus = useCallback(
    async (statusCode: "NEW" | "READ") => {
      const selectedItems = Array.from(selectedTokens.values());
      if (selectedItems.length === 0) return;

      const ineligible = selectedItems.filter(
        (item) => item.hasActiveApplication,
      );
      if (ineligible.length > 0) {
        setFeedbackMessage(
          "Không thể chuyển trạng thái Mới/Đã đọc cho Ứng viên đã có Application.",
        );
        setFeedbackType("error");
        return;
      }

      setIsBulkActionPending(true);
      setFeedbackMessage(null);
      try {
        const items = selectedItems.map((item) => ({
          candidateId: item.candidateId,
          expectedLatestSubmissionId: item.latestSubmissionId,
          expectedVersion: item.latestSubmissionVersionNo,
        }));

        const result = await bulkSetStatus({
          items,
          statusCode,
        });

        if (!result.success) {
          setFeedbackMessage(result.error);
          setFeedbackType("error");
          return;
        }

        setFeedbackMessage(
          `Đã chuyển trạng thái ${result.data.count} Phiếu sang ${SUBMISSION_STATUS_LABEL[statusCode]} thành công.`,
        );
        setFeedbackType("success");
        setSelectedTokens(new Map());
        tableContainerRef.current?.focus();
        loadPage(inboxState.inbox.page, debouncedFilters, pageSize);
      } catch {
        setFeedbackMessage("Không thể cập nhật trạng thái phiếu hàng loạt.");
        setFeedbackType("error");
      } finally {
        setIsBulkActionPending(false);
      }
    },
    [
      selectedTokens,
      bulkSetStatus,
      loadPage,
      inboxState.inbox.page,
      debouncedFilters,
      pageSize,
    ],
  );

  const handleBulkReactivate = useCallback(async () => {
    const selectedItems = Array.from(selectedTokens.values());
    if (selectedItems.length === 0) return;

    setIsBulkActionPending(true);
    setFeedbackMessage(null);
    try {
      const items = selectedItems.map((item) => ({
        candidateId: item.candidateId,
        expectedVersion: item.candidateVersionNo,
      }));

      const result = await bulkSetCandidateActive({
        items,
        active: true,
      });

      if (!result.success) {
        setFeedbackMessage(result.error);
        setFeedbackType("error");
        return;
      }

      setFeedbackMessage(
        `Đã kích hoạt lại ${result.data.count} tài khoản Candidate thành công.`,
      );
      setFeedbackType("success");
      setSelectedTokens(new Map());
      tableContainerRef.current?.focus();
      loadPage(inboxState.inbox.page, debouncedFilters, pageSize);
    } catch {
      setFeedbackMessage("Không thể kích hoạt lại tài khoản Candidate.");
      setFeedbackType("error");
    } finally {
      setIsBulkActionPending(false);
    }
  }, [
    selectedTokens,
    bulkSetCandidateActive,
    loadPage,
    inboxState.inbox.page,
    debouncedFilters,
    pageSize,
  ]);
  const handleOpenInactiveDialog = useCallback(() => {
    if (selectedTokens.size === 0) return;
    triggerElementRef.current = document.activeElement as HTMLElement | null;
    setIsInactiveModalOpen(true);
  }, [selectedTokens.size]);

  const handleCloseInactiveDialog = useCallback(() => {
    setIsInactiveModalOpen(false);
    restoreFocus();
  }, [restoreFocus]);

  const handleConfirmInactive = useCallback(async () => {
    const selectedItems = Array.from(selectedTokens.values());
    if (selectedItems.length === 0) return;

    setIsBulkActionPending(true);
    setFeedbackMessage(null);
    try {
      const items = selectedItems.map((item) => ({
        candidateId: item.candidateId,
        expectedVersion: item.candidateVersionNo,
      }));

      const result = await bulkSetCandidateActive({
        items,
        active: false,
      });

      if (!result.success) {
        setFeedbackMessage(result.error);
        setFeedbackType("error");
        setIsInactiveModalOpen(false);
        restoreFocus();
        return;
      }

      setFeedbackMessage(
        `Đã ngừng hoạt động ${result.data.count} tài khoản Candidate thành công.`,
      );
      setFeedbackType("success");
      setIsInactiveModalOpen(false);
      setSelectedTokens(new Map());
      tableContainerRef.current?.focus();
      loadPage(inboxState.inbox.page, debouncedFilters, pageSize);
    } catch {
      setFeedbackMessage("Không thể ngừng hoạt động tài khoản Candidate.");
      setFeedbackType("error");
      setIsInactiveModalOpen(false);
      restoreFocus();
    } finally {
      setIsBulkActionPending(false);
    }
  }, [
    selectedTokens,
    bulkSetCandidateActive,
    restoreFocus,
    loadPage,
    inboxState.inbox.page,
    debouncedFilters,
    pageSize,
  ]);
  useEffect(() => {
    if (!isInactiveModalOpen) return;

    cancelInactiveBtnRef.current?.focus();

    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Tab") {
        const dialogNode = inactiveModalRef.current;
        if (!dialogNode) return;

        const focusable = dialogNode.querySelectorAll<HTMLElement>(
          'button:not([disabled]):not([tabindex="-1"]), [tabindex]:not([tabindex="-1"])',
        );
        if (focusable.length === 0) {
          event.preventDefault();
          if (document.activeElement !== dialogNode) {
            dialogNode.focus();
          }
          return;
        }

        const first = focusable[0];
        const last = focusable[focusable.length - 1];

        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      } else if (event.key === "Escape") {
        if (isBulkActionPending) return;
        event.preventDefault();
        event.stopPropagation();
        handleCloseInactiveDialog();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isInactiveModalOpen, isBulkActionPending, handleCloseInactiveDialog]);

  function updateFilters(patch: Partial<ApplicationInboxFilters>) {
    setFilters((current) => ({ ...current, ...patch }));
    setSelectedTokens((current) => {
      if (current.size > 0) {
        setSelectionNotice("Đã đặt lại danh sách chọn do thay đổi bộ lọc.");
        return new Map();
      }
      return current;
    });
  }

  function handlePageSizeChange(value: string) {
    const nextPageSize = normalizeApplicationInboxPageSize(Number(value));
    if (nextPageSize === pageSize) return;
    setPageSize(nextPageSize);
    setSelectedTokens((current) => {
      if (current.size > 0) {
        setSelectionNotice(
          "Đã đặt lại danh sách chọn do thay đổi số Candidate mỗi trang.",
        );
        return new Map();
      }
      return current;
    });
  }

  function toggleCandidate(candidateId: string) {
    setExpandedCandidateId((current) =>
      nextExpandedCandidateId(current, candidateId),
    );
  }

  function toggleSelectedCandidate(candidateId: string, selected: boolean) {
    setSelectedTokens((current) => {
      const next = new Map(current);
      if (selected) {
        const group = inboxState.inbox.groups.find(
          (g) => g.candidateId === candidateId,
        );
        if (group) {
          next.set(candidateId, {
            candidateId: group.candidateId,
            candidateVersionNo: group.candidateVersionNo,
            latestSubmissionId: group.latestSubmissionId,
            latestSubmissionVersionNo: group.latestSubmissionVersionNo,
            hasActiveApplication: groupHasActiveApplication(group),
          });
        }
      } else {
        next.delete(candidateId);
      }
      return next;
    });
  }

  function resetFilters() {
    setFilters(INITIAL_APPLICATION_INBOX_FILTERS);
    setSelectedTokens((current) => {
      if (current.size > 0) {
        setSelectionNotice("Đã đặt lại danh sách chọn do đặt lại bộ lọc.");
        return new Map();
      }
      return current;
    });
  }
  const displayedError = inboxState.errorMessage;
  const inbox = inboxState.inbox;

  return (
    <section
      ref={tableContainerRef}
      tabIndex={-1}
      className="application-inbox workflow-list-page"
      aria-labelledby="inbox-heading"
    >
      <div className="application-inbox__header">
        <div className="workflow-page-heading">
          <h1 id="inbox-heading">Quản lý Phiếu Ứng tuyển</h1>
          <PageContext>
            Mỗi dòng là một Ứng viên; thông tin tóm tắt lấy từ phiếu mới nhất.
          </PageContext>
        </div>
      </div>

      <form
        className="application-inbox__toolbar"
        aria-label="Tìm kiếm và lọc Phiếu Ứng tuyển"
        onSubmit={(event) => event.preventDefault()}
      >
        <div className="application-inbox__search">
          <label htmlFor="application-inbox-search">
            Tìm kiếm tên, email hoặc SĐT
          </label>
          <input
            id="application-inbox-search"
            type="search"
            value={filters.query}
            onChange={(event) => updateFilters({ query: event.target.value })}
            placeholder="Tìm tên, email, SĐT..."
          />
        </div>
        <label>
          Trạng thái phiếu
          <select
            value={filters.status}
            onChange={(event) =>
              updateFilters({
                status: event.target.value as ApplicationInboxFilters["status"],
              })
            }
          >
            <option value="ALL">Tất cả</option>
            {Object.entries(SUBMISSION_STATUS_LABEL).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <details className="workflow-filters">
          <summary>
            Bộ lọc khác{hasActiveFilters(filters) ? " · Đang áp dụng" : ""}
          </summary>
          <div className="workflow-filters__body">
            <label>
              Từ ngày ứng tuyển
              <input
                type="date"
                value={filters.dateFrom}
                onChange={(event) =>
                  updateFilters({ dateFrom: event.target.value })
                }
              />
            </label>
            <label>
              Đến ngày ứng tuyển
              <input
                type="date"
                value={filters.dateTo}
                onChange={(event) =>
                  updateFilters({ dateTo: event.target.value })
                }
              />
            </label>
            <label>
              Tài khoản Candidate
              <select
                value={filters.candidateActivity}
                onChange={(event) =>
                  updateFilters({
                    candidateActivity: event.target
                      .value as ApplicationInboxFilters["candidateActivity"],
                  })
                }
              >
                <option value="ALL">Tất cả tài khoản</option>
                <option value="ACTIVE">Đang hoạt động</option>
                <option value="INACTIVE">Đã ngừng hoạt động</option>
              </select>
            </label>
            <label>
              Mới / đã đọc
              <select
                value={filters.newRead}
                onChange={(event) =>
                  updateFilters({
                    newRead: event.target
                      .value as ApplicationInboxFilters["newRead"],
                  })
                }
              >
                <option value="ALL">Tất cả</option>
                <option value="NEW">Mới</option>
                <option value="READ">Đã đọc</option>
              </select>
            </label>
            <label>
              Application
              <select
                value={filters.application}
                onChange={(event) =>
                  updateFilters({
                    application: event.target
                      .value as ApplicationInboxFilters["application"],
                  })
                }
              >
                <option value="ALL">Tất cả</option>
                <option value="HAS_APPLICATION">Đã có Application</option>
                <option value="NO_APPLICATION">Chưa có Application</option>
              </select>
            </label>
          </div>
        </details>
        {hasActiveFilters(filters) && (
          <button
            type="button"
            className="btn-secondary"
            onClick={resetFilters}
          >
            Xóa tìm kiếm và bộ lọc
          </button>
        )}
      </form>

      {feedbackMessage && (
        <div
          role={feedbackType === "error" ? "alert" : "status"}
          aria-live={feedbackType === "error" ? "assertive" : "polite"}
          className={`application-inbox__feedback-banner application-inbox__feedback-banner--${feedbackType}`}
        >
          <span>{feedbackMessage}</span>
          <button
            type="button"
            onClick={() => setFeedbackMessage(null)}
            aria-label="Đóng thông báo"
            className="application-inbox__feedback-close"
          >
            ×
          </button>
        </div>
      )}

      <details
        hidden={selectedTokens.size === 0}
        open={selectedTokens.size > 0}
        className="application-inbox__bulk-toolbar"
        aria-label="Thao tác hàng loạt"
      >
        <summary>
          Thao tác ·
          <span
            ref={selectionStatusRef}
            tabIndex={-1}
            className="application-inbox__selection-count"
          >
            {selectedTokens.size} ứng viên được chọn
          </span>
        </summary>
        <div className="application-inbox__bulk-actions">
          <StatusMenu
            label="Trạng thái đã chọn"
            options={[
              { value: "NEW", label: "Đánh dấu Mới" },
              { value: "READ", label: "Đánh dấu Đã đọc" },
            ]}
            disabled={
              selectedTokens.size === 0 || isPending || isBulkActionPending
            }
            onSelect={(value) =>
              void handleBulkSetStatus(value as "NEW" | "READ")
            }
          />
          <button
            ref={inactiveTriggerRef}
            type="button"
            className="btn-secondary application-inbox__bulk-btn"
            disabled={
              selectedTokens.size === 0 || isPending || isBulkActionPending
            }
            onClick={handleOpenInactiveDialog}
          >
            Ngừng hoạt động
          </button>
          <button
            type="button"
            className="btn-secondary application-inbox__bulk-btn"
            disabled={
              selectedTokens.size === 0 || isPending || isBulkActionPending
            }
            onClick={handleBulkReactivate}
          >
            Kích hoạt lại
          </button>
        </div>
      </details>
      <div
        role="status"
        aria-live="polite"
        className="sr-only application-inbox__selection-notice"
      >
        {selectedTokens.size} ứng viên được chọn. {selectionNotice}
      </div>

      <div className="application-inbox__table-scroll">
        <table className="application-inbox__table">
          <colgroup>
            {APPLICATION_INBOX_COLUMNS.map((column) => (
              <col
                key={column.key}
                className={`application-inbox__col--${column.key}`}
              />
            ))}
          </colgroup>
          <thead>
            <tr>
              {APPLICATION_INBOX_COLUMNS.map((column) => (
                <th key={column.key} scope="col">
                  {column.key === "select" ? (
                    <label className="application-inbox__selection-control">
                      <input
                        type="checkbox"
                        checked={
                          inbox.groups.length > 0 &&
                          inbox.groups.every((g) =>
                            selectedCandidateIds.has(g.candidateId),
                          )
                        }
                        ref={(input) => {
                          if (input) {
                            const someSelected =
                              inbox.groups.some((g) =>
                                selectedCandidateIds.has(g.candidateId),
                              ) &&
                              !inbox.groups.every((g) =>
                                selectedCandidateIds.has(g.candidateId),
                              );
                            input.indeterminate = someSelected;
                          }
                        }}
                        aria-label="Chọn tất cả Candidate trên trang này"
                        onChange={(event) => {
                          if (event.target.checked) {
                            const next = new Map<
                              string,
                              SelectedCandidateToken
                            >();
                            for (const g of inbox.groups) {
                              next.set(g.candidateId, {
                                candidateId: g.candidateId,
                                candidateVersionNo: g.candidateVersionNo,
                                latestSubmissionId: g.latestSubmissionId,
                                latestSubmissionVersionNo:
                                  g.latestSubmissionVersionNo,
                                hasActiveApplication:
                                  groupHasActiveApplication(g),
                              });
                            }
                            setSelectedTokens(next);
                          } else {
                            setSelectedTokens(new Map());
                          }
                        }}
                      />
                    </label>
                  ) : (
                    column.label
                  )}
                </th>
              ))}
            </tr>
          </thead>
          {loading || isPending ? (
            <tbody>
              <tr>
                <td colSpan={APPLICATION_INBOX_COLUMNS.length}>
                  <p
                    className="application-inbox__feedback"
                    role="status"
                    aria-live="polite"
                  >
                    Đang tải danh sách Candidate...
                  </p>
                </td>
              </tr>
            </tbody>
          ) : displayedError ? (
            <tbody>
              <tr>
                <td colSpan={APPLICATION_INBOX_COLUMNS.length}>
                  <p className="application-inbox__feedback" role="alert">
                    {displayedError}
                  </p>
                </td>
              </tr>
            </tbody>
          ) : inboxState.inbox.groups.length === 0 ? (
            <tbody>
              <tr>
                <td colSpan={APPLICATION_INBOX_COLUMNS.length}>
                  <p
                    className="application-inbox__feedback"
                    role="status"
                    aria-live="polite"
                  >
                    Không tìm thấy Candidate phù hợp với điều kiện hiện tại.
                  </p>
                </td>
              </tr>
            </tbody>
          ) : (
            <ApplicationInboxTableRows
              groups={inboxState.inbox.groups}
              expandedCandidateId={expandedCandidateId}
              selectedCandidateIds={selectedCandidateIds}
              onOpenSubmission={handleOpenSubmission}
              onToggleCandidate={toggleCandidate}
              onToggleSelectedCandidate={toggleSelectedCandidate}
            />
          )}
        </table>
      </div>
      {!loading && !displayedError && (
        <nav
          className="application-inbox__pagination"
          aria-label="Phân trang Candidate"
        >
          <label>
            Ứng viên mỗi trang
            <select
              aria-label="Số Candidate mỗi trang"
              value={pageSize}
              disabled={isPending}
              onChange={(event) => handlePageSizeChange(event.target.value)}
            >
              {APPLICATION_INBOX_PAGE_SIZES.map((size) => (
                <option key={size} value={size}>
                  {size}
                </option>
              ))}
            </select>
          </label>
          <button
            type="button"
            className="btn-secondary"
            disabled={inbox.page === 1 || isPending}
            aria-label="Trang trước"
            onClick={() => loadPage(inbox.page - 1, debouncedFilters, pageSize)}
          >
            Trước
          </button>
          <span aria-live="polite">
            Trang {inbox.page} / {inbox.pageCount}
          </span>
          <button
            type="button"
            className="btn-secondary"
            disabled={inbox.page === inbox.pageCount || isPending}
            aria-label="Trang sau"
            onClick={() => loadPage(inbox.page + 1, debouncedFilters, pageSize)}
          >
            Sau
          </button>
        </nav>
      )}
      <SubmissionDetailDrawer
        submissionId={activeSubmissionId ?? ""}
        isOpen={activeSubmissionId !== null}
        onClose={handleCloseDrawer}
        onSubmissionUpdated={handleSubmissionUpdated}
        actions={{
          ...actions?.drawerActions,
          openSubmission:
            actions?.openSubmissionAction ??
            actions?.drawerActions?.openSubmission ??
            openSubmissionAction,
        }}
      />
      {isInactiveModalOpen && (
        <div
          className="bulk-confirm-overlay"
          role="dialog"
          aria-modal="true"
          aria-labelledby="bulk-inactive-dialog-title"
          aria-describedby="bulk-inactive-dialog-desc"
        >
          <div
            ref={inactiveModalRef}
            className="bulk-confirm-dialog"
            tabIndex={-1}
          >
            <h3 id="bulk-inactive-dialog-title">
              Xác nhận ngừng hoạt động tài khoản Candidate
            </h3>
            <p id="bulk-inactive-dialog-desc">
              Bạn có chắc chắn muốn ngừng hoạt động{" "}
              <strong>{selectedTokens.size}</strong> tài khoản Candidate đã
              chọn? Ứng viên sẽ không thể đăng nhập vào Candidate Portal bằng
              email tương ứng cho tới khi được kích hoạt lại.
            </p>
            <div className="bulk-confirm-dialog__actions">
              <button
                ref={cancelInactiveBtnRef}
                type="button"
                className="btn-secondary"
                disabled={isBulkActionPending}
                onClick={handleCloseInactiveDialog}
              >
                Hủy bỏ
              </button>
              <button
                type="button"
                className="btn-danger"
                disabled={isBulkActionPending}
                onClick={handleConfirmInactive}
              >
                {isBulkActionPending
                  ? "Đang xử lý..."
                  : "Xác nhận ngừng hoạt động"}
              </button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
