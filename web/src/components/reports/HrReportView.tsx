"use client";

import { useMemo, useState } from "react";
import { useAppLocale } from "@/components/shell/LocaleProvider";
import { AsyncStatus } from "@/components/ui/AsyncStatus";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Drawer } from "@/components/ui/Drawer";
import { PageContext } from "@/components/ui/PageContext";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { StatusMenu } from "@/components/ui/StatusMenu";
import { TableScrollContainer } from "@/components/ui/TableScrollContainer";
import {
  HR_REPORT_STATUS_LABELS,
  HR_REPORT_STATUSES,
  type HrReportFilters,
  type HrReportPageData,
  type HrReportParticipant,
  type HrReportRow,
  hrReportStatusTone,
  INITIAL_HR_REPORT_FILTERS,
} from "@/lib/reports/hr-model";
import type {
  BulkHrReportStatusInput,
  DeleteHrParticipantReportInput,
  HrReportCommandResult,
  HrReportNoteInput,
  HrReportStatusInput,
  HrReportVisibilityInput,
  SaveHrParticipantReportInput,
} from "@/lib/reports/hr-server";
import {
  changedReportFields,
  REPORT_FIELD_KEYS,
  type ReportFieldKey,
  type ReportFields,
} from "@/lib/reports/model";
import styles from "./HrReportView.module.css";
import { REPORT_FIELD_LABELS } from "./reportUi";

type Feedback = {
  kind: "success" | "warning" | "error";
  vi: string;
  en: string;
} | null;

type SavedDraft = "note" | "participant";

interface HrReportViewProps {
  initialData: HrReportPageData;
  onRefresh: (filters?: Partial<HrReportFilters>) => Promise<HrReportPageData>;
  onStatus: (input: HrReportStatusInput) => Promise<HrReportCommandResult>;
  onBulkStatus: (
    input: BulkHrReportStatusInput,
  ) => Promise<HrReportCommandResult>;
  onVisibility: (
    input: HrReportVisibilityInput,
  ) => Promise<HrReportCommandResult>;
  onNote: (input: HrReportNoteInput) => Promise<HrReportCommandResult>;
  onSaveParticipantReport: (
    input: SaveHrParticipantReportInput,
  ) => Promise<HrReportCommandResult>;
  onDeleteParticipantReport: (
    input: DeleteHrParticipantReportInput,
  ) => Promise<HrReportCommandResult>;
}

function cloneFields(fields: ReportFields): ReportFields {
  return Object.fromEntries(
    REPORT_FIELD_KEYS.map((key) => [key, fields[key]]),
  ) as ReportFields;
}

function mergeReportDraftWithFresh(
  base: ReportFields,
  draft: ReportFields,
  fresh: ReportFields,
): { base: ReportFields; draft: ReportFields } {
  const dirtyFields = Object.keys(
    changedReportFields(base, draft).patches,
  ) as ReportFieldKey[];
  const nextBase = cloneFields(fresh);
  const nextDraft = cloneFields(fresh);
  for (const key of dirtyFields) {
    nextBase[key] = base[key];
    nextDraft[key] = draft[key];
  }
  return { base: nextBase, draft: nextDraft };
}

function displayText(value: string | null): string {
  return value?.trim() ? value : "—";
}

function formatDateTime(value: string | null, locale: "vi" | "en"): string {
  if (!value || Number.isNaN(new Date(value).getTime())) return "—";
  return new Intl.DateTimeFormat(locale === "vi" ? "vi-VN" : "en-GB", {
    timeZone: "Asia/Ho_Chi_Minh",
    hour: "2-digit",
    minute: "2-digit",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour12: false,
  }).format(new Date(value));
}

function formatInterviewTime(row: HrReportRow, locale: "vi" | "en"): string {
  if (!row.startAt) return locale === "vi" ? "Chưa xếp lịch" : "Not scheduled";
  if (!row.endAt) return formatDateTime(row.startAt, locale);
  const start = new Date(row.startAt);
  const end = new Date(row.endAt);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return "—";
  const language = locale === "vi" ? "vi-VN" : "en-GB";
  const time = new Intl.DateTimeFormat(language, {
    timeZone: "Asia/Ho_Chi_Minh",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const date = new Intl.DateTimeFormat(language, {
    timeZone: "Asia/Ho_Chi_Minh",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  });
  return `${time.format(start)} – ${time.format(end)} · ${date.format(start)}`;
}

function locationLabel(row: HrReportRow, locale: "vi" | "en"): string {
  if (row.roomName) return row.roomName;
  const format =
    locale === "en"
      ? row.formatNameEn || row.formatNameVi
      : row.formatNameVi || row.formatNameEn;
  return format || "—";
}

function positionLabel(row: HrReportRow, locale: "vi" | "en"): string {
  return locale === "en"
    ? row.positionNameEn || row.positionNameVi
    : row.positionNameVi;
}

function commandFeedback(
  result: HrReportCommandResult,
  successVi: string,
  successEn: string,
): Feedback {
  if (result.success) {
    return { kind: "success", vi: successVi, en: successEn };
  }
  if (result.error.code === "STALE_VERSION") {
    return {
      kind: "warning",
      vi: "Dữ liệu đã thay đổi ở nơi khác. Trang đã được tải lại.",
      en: "This data changed elsewhere. Fresh data has been loaded.",
    };
  }
  return {
    kind: "error",
    vi: `Không thể hoàn tất thao tác (${result.error.code}).`,
    en: `The action could not be completed (${result.error.code}).`,
  };
}

export function HrReportView({
  initialData,
  onRefresh,
  onStatus,
  onBulkStatus,
  onVisibility,
  onNote,
  onSaveParticipantReport,
  onDeleteParticipantReport,
}: HrReportViewProps) {
  const { locale } = useAppLocale();
  const t = (vi: string, en: string) => (locale === "vi" ? vi : en);
  const [data, setData] = useState(initialData);
  const [filters, setFilters] = useState<HrReportFilters>({
    ...INITIAL_HR_REPORT_FILTERS,
    page: initialData.page,
    pageSize: initialData.pageSize,
  });
  const [searchDraft, setSearchDraft] = useState("");
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [drawerRow, setDrawerRow] = useState<HrReportRow | null>(null);
  const [noteDraft, setNoteDraft] = useState("");
  const [noteBase, setNoteBase] = useState("");
  const [noteExpectedVersionNo, setNoteExpectedVersionNo] = useState<
    number | null
  >(null);
  const [editingParticipantId, setEditingParticipantId] = useState<
    string | null
  >(null);
  const [reportDraft, setReportDraft] = useState<ReportFields | null>(null);
  const [reportBase, setReportBase] = useState<ReportFields | null>(null);
  const [deleteParticipant, setDeleteParticipant] =
    useState<HrReportParticipant | null>(null);
  const [discardOpen, setDiscardOpen] = useState(false);
  const [pending, setPending] = useState(false);
  const [feedback, setFeedback] = useState<Feedback>(null);

  const selectedRow = drawerRow;
  const drawerInterviewId = drawerRow?.interviewId ?? null;

  const currentEditingParticipant = useMemo(
    () =>
      selectedRow?.drawer.participants.find(
        (participant) =>
          participant.interviewParticipantId === editingParticipantId,
      ) ?? null,
    [editingParticipantId, selectedRow],
  );

  const noteDirty = Boolean(selectedRow) && noteDraft !== noteBase;
  const participantDirty =
    Boolean(reportDraft && reportBase) &&
    REPORT_FIELD_KEYS.some((key) => reportDraft?.[key] !== reportBase?.[key]);
  const hasUnsaved = noteDirty || participantDirty;

  const statusOptions = HR_REPORT_STATUSES.map((status) => ({
    value: status,
    label: HR_REPORT_STATUS_LABELS[status][locale],
  }));

  const allVisibleSelected =
    data.rows.length > 0 &&
    data.rows.every((row) => selectedIds.has(row.interviewId));

  function resetEditing() {
    setEditingParticipantId(null);
    setReportDraft(null);
    setReportBase(null);
  }

  function warnUnsaved() {
    setFeedback({
      kind: "warning",
      vi: "Hãy lưu hoặc bỏ thay đổi đang chỉnh sửa trước khi chuyển nội dung.",
      en: "Save or discard the current edits before switching content.",
    });
  }

  function hydrateDrawer(row: HrReportRow) {
    if (
      drawerInterviewId &&
      drawerInterviewId !== row.interviewId &&
      hasUnsaved
    ) {
      warnUnsaved();
      return;
    }
    const note = row.hrReportNote ?? "";
    setDrawerRow(row);
    setNoteDraft(note);
    setNoteBase(note);
    setNoteExpectedVersionNo(row.interviewVersionNo);
    resetEditing();
    setFeedback(null);
  }

  function closeDrawerNow() {
    setDrawerRow(null);
    setNoteDraft("");
    setNoteBase("");
    setNoteExpectedVersionNo(null);
    resetEditing();
    setFeedback(null);
    setDiscardOpen(false);
  }

  function requestCloseDrawer() {
    if (pending) return;
    if (hasUnsaved) {
      setDiscardOpen(true);
      return;
    }
    closeDrawerNow();
  }

  async function refresh(
    nextFilters: HrReportFilters,
    options?: { preserveDrawer?: string | null; savedDraft?: SavedDraft },
  ) {
    const previousRow = selectedRow;
    const previousBase = reportBase;
    const previousDraft = reportDraft;
    const noteWasDirty = noteDirty && options?.savedDraft !== "note";
    const participantWasDirty =
      participantDirty && options?.savedDraft !== "participant";
    const editingId = editingParticipantId;
    const next = await onRefresh(nextFilters);
    setData(next);
    setFilters({
      ...nextFilters,
      page: next.page,
      pageSize: next.pageSize,
    });
    setSelectedIds(new Set());

    const preserveId = options?.preserveDrawer ?? drawerInterviewId;
    if (!preserveId) return next;

    const fresh = next.rows.find((row) => row.interviewId === preserveId);
    if (!fresh) {
      if (previousRow && (noteWasDirty || participantWasDirty)) {
        setDrawerRow(
          options?.savedDraft === "note"
            ? { ...previousRow, hrReportNote: noteDraft }
            : previousRow,
        );
        if (options?.savedDraft === "note") {
          setNoteBase(noteDraft);
        }
        if (options?.savedDraft === "participant") {
          resetEditing();
        }
      } else {
        closeDrawerNow();
      }
      return next;
    }

    setDrawerRow(fresh);
    const freshNote = fresh.hrReportNote ?? "";
    if (options?.savedDraft === "note" || !noteWasDirty) {
      setNoteBase(freshNote);
      setNoteDraft(freshNote);
      setNoteExpectedVersionNo(fresh.interviewVersionNo);
    }

    if (options?.savedDraft === "participant") {
      resetEditing();
      return next;
    }

    if (editingId && previousBase && previousDraft) {
      const freshParticipant = fresh.drawer.participants.find(
        (participant) => participant.interviewParticipantId === editingId,
      );
      if (freshParticipant) {
        const merged = mergeReportDraftWithFresh(
          previousBase,
          previousDraft,
          freshParticipant.report,
        );
        setReportBase(merged.base);
        setReportDraft(merged.draft);
      } else if (participantWasDirty && previousRow) {
        setDrawerRow(previousRow);
      } else {
        resetEditing();
      }
    }

    return next;
  }

  async function applyFilters(next: HrReportFilters) {
    if (pending) return;
    setPending(true);
    setFeedback(null);
    try {
      await refresh(next);
    } catch {
      setFeedback({
        kind: "error",
        vi: "Không thể tải dữ liệu báo cáo.",
        en: "Report data could not be loaded.",
      });
    } finally {
      setPending(false);
    }
  }

  async function runRowStatus(row: HrReportRow, status: string) {
    if (pending || !data.permissions.manageStatus) return;
    setPending(true);
    setFeedback(null);
    try {
      const result = await onStatus({
        interviewId: row.interviewId,
        status: status as HrReportStatusInput["status"],
        expectedVersionNo: row.interviewVersionNo,
      });
      setFeedback(
        commandFeedback(
          result,
          "Đã cập nhật trạng thái báo cáo.",
          "Report status updated.",
        ),
      );
      await refresh(filters, { preserveDrawer: drawerInterviewId });
    } catch {
      setFeedback({
        kind: "error",
        vi: "Không thể cập nhật trạng thái.",
        en: "Status could not be updated.",
      });
    } finally {
      setPending(false);
    }
  }

  async function runBulkStatus(status: string) {
    if (pending || !data.permissions.manageStatus || selectedIds.size === 0)
      return;
    const targets = data.rows
      .filter((row) => selectedIds.has(row.interviewId))
      .map((row) => ({
        interviewId: row.interviewId,
        expectedVersionNo: row.interviewVersionNo,
      }));
    if (targets.length === 0) return;
    setPending(true);
    setFeedback(null);
    try {
      const result = await onBulkStatus({
        targets,
        status: status as BulkHrReportStatusInput["status"],
      });
      setFeedback(
        commandFeedback(
          result,
          "Đã cập nhật trạng thái cho các báo cáo đã chọn.",
          "Selected report statuses updated.",
        ),
      );
      await refresh(filters, { preserveDrawer: drawerInterviewId });
    } catch {
      setFeedback({
        kind: "error",
        vi: "Không thể cập nhật trạng thái hàng loạt.",
        en: "Bulk status update failed.",
      });
    } finally {
      setPending(false);
    }
  }

  async function runVisibility(row: HrReportRow) {
    if (pending || !data.permissions.visibility) return;
    setPending(true);
    setFeedback(null);
    try {
      const result = await onVisibility({
        interviewId: row.interviewId,
        visible: !row.visibleToInterviewers,
        expectedVersionNo: row.interviewVersionNo,
      });
      setFeedback(
        commandFeedback(
          result,
          row.visibleToInterviewers
            ? "Đã ẩn báo cáo với Interviewer."
            : "Đã hiển thị báo cáo với Interviewer.",
          row.visibleToInterviewers
            ? "Report hidden from Interviewers."
            : "Report shown to Interviewers.",
        ),
      );
      await refresh(filters, { preserveDrawer: row.interviewId });
    } catch {
      setFeedback({
        kind: "error",
        vi: "Không thể cập nhật quyền hiển thị.",
        en: "Visibility could not be updated.",
      });
    } finally {
      setPending(false);
    }
  }

  async function saveNote(row: HrReportRow) {
    if (pending || !data.permissions.manageStatus || !noteDirty) return;
    setPending(true);
    setFeedback(null);
    try {
      const result = await onNote({
        interviewId: row.interviewId,
        note: noteDraft.trim() ? noteDraft : null,
        expectedVersionNo: noteExpectedVersionNo ?? row.interviewVersionNo,
      });
      setFeedback(
        commandFeedback(result, "Đã lưu ghi chú HR.", "HR note saved."),
      );
      await refresh(filters, {
        preserveDrawer: row.interviewId,
        savedDraft: result.success ? "note" : undefined,
      });
    } catch {
      setFeedback({
        kind: "error",
        vi: "Không thể lưu ghi chú HR.",
        en: "HR note could not be saved.",
      });
    } finally {
      setPending(false);
    }
  }

  function requestParticipantEdit(participant: HrReportParticipant) {
    if (!data.permissions.editInterviewer || pending) return;
    const editingSame =
      participant.interviewParticipantId === editingParticipantId;
    if (participantDirty) {
      warnUnsaved();
      return;
    }
    if (editingSame) {
      resetEditing();
      return;
    }
    setEditingParticipantId(participant.interviewParticipantId);
    setReportBase(cloneFields(participant.report));
    setReportDraft(cloneFields(participant.report));
    setFeedback(null);
  }

  async function saveParticipantReport(row: HrReportRow) {
    if (
      pending ||
      !data.permissions.editInterviewer ||
      !currentEditingParticipant ||
      !reportDraft ||
      !reportBase
    ) {
      return;
    }
    const changed = changedReportFields(reportBase, reportDraft);
    if (Object.keys(changed.patches).length === 0) {
      if (currentEditingParticipant.interviewReportId) {
        setFeedback({
          kind: "warning",
          vi: "Không có thay đổi để lưu.",
          en: "There are no changes to save.",
        });
        return;
      }
      changed.patches.professional_knowledge = "";
      changed.baseValues.professional_knowledge = null;
    }
    setPending(true);
    setFeedback(null);
    try {
      const result = await onSaveParticipantReport({
        interviewParticipantId:
          currentEditingParticipant.interviewParticipantId,
        expectedVersionNo: currentEditingParticipant.reportVersionNo,
        patches: changed.patches,
        baseValues: changed.baseValues,
      });
      setFeedback(
        commandFeedback(
          result,
          "Đã lưu báo cáo Interviewer.",
          "Interviewer report saved.",
        ),
      );
      await refresh(filters, {
        preserveDrawer: row.interviewId,
        savedDraft: result.success ? "participant" : undefined,
      });
    } catch {
      setFeedback({
        kind: "error",
        vi: "Không thể lưu báo cáo Interviewer.",
        en: "Interviewer report could not be saved.",
      });
    } finally {
      setPending(false);
    }
  }

  async function confirmDeleteParticipant(row: HrReportRow) {
    if (
      pending ||
      !data.permissions.delete ||
      !deleteParticipant?.interviewReportId
    ) {
      return;
    }
    if (
      participantDirty &&
      deleteParticipant.interviewParticipantId === editingParticipantId
    ) {
      setDeleteParticipant(null);
      warnUnsaved();
      return;
    }
    const deletedParticipantId = deleteParticipant.interviewParticipantId;
    setPending(true);
    setFeedback(null);
    try {
      const result = await onDeleteParticipantReport({
        interviewReportId: deleteParticipant.interviewReportId,
        expectedVersionNo: deleteParticipant.reportVersionNo,
      });
      setDeleteParticipant(null);
      setFeedback(
        commandFeedback(
          result,
          "Đã xóa hoặc chuyển báo cáo về không hoạt động theo lịch sử sử dụng.",
          "The participant report was deleted or inactivated according to its history.",
        ),
      );
      if (result.success && deletedParticipantId === editingParticipantId) {
        resetEditing();
      }
      await refresh(filters, { preserveDrawer: row.interviewId });
    } catch {
      setFeedback({
        kind: "error",
        vi: "Không thể xóa/chuyển không hoạt động báo cáo.",
        en: "The participant report could not be deleted/inactivated.",
      });
    } finally {
      setPending(false);
    }
  }

  const drawerFooter = selectedRow ? (
    <div className={styles.drawerActions}>
      <a
        className="ui-button ui-button--secondary"
        href="/interviews"
        aria-disabled={hasUnsaved || pending || undefined}
        onClick={(event) => {
          if (hasUnsaved || pending) {
            event.preventDefault();
            warnUnsaved();
          }
        }}
      >
        {t("Mở trang Phỏng vấn", "Open Interviews")}
      </a>
      <Button
        disabled
        title={t(
          "Đang chờ mẫu PDF chính thức",
          "Official PDF template pending",
        )}
      >
        {t("Tải PDF — đang chờ mẫu", "Download PDF — template pending")}
      </Button>
      <Button onClick={requestCloseDrawer} disabled={pending}>
        {t("Đóng", "Close")}
      </Button>
    </div>
  ) : undefined;

  return (
    <section
      className={`${styles.root} workflow-list-page`}
      aria-labelledby="hr-report-title"
      aria-busy={pending || undefined}
    >
      <div className={styles.heading}>
        <div className="workflow-page-heading">
          <h1 id="hr-report-title">
            {t("Báo cáo phỏng vấn", "Interview Reports")}
          </h1>
          <PageContext>
            {t(
              "Mỗi dòng là một Application tại vòng phỏng vấn hiện hành.",
              "Each row is one Application at its current interview round.",
            )}
          </PageContext>
        </div>
      </div>

      <div
        className={styles.toolbar}
        role="toolbar"
        aria-label={t("Công cụ báo cáo", "Report tools")}
      >
        <div className={styles.searchGroup}>
          <label htmlFor="hr-report-search">{t("Tìm kiếm", "Search")}</label>
          <input
            id="hr-report-search"
            type="search"
            value={searchDraft}
            disabled={pending}
            onChange={(event) => setSearchDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                void applyFilters({
                  ...filters,
                  page: 1,
                  search: searchDraft.trim().slice(0, 256),
                });
              }
            }}
          />
          <Button
            disabled={pending}
            onClick={() =>
              void applyFilters({
                ...filters,
                page: 1,
                search: searchDraft.trim().slice(0, 256),
              })
            }
          >
            {t("Tìm", "Search")}
          </Button>
        </div>

        <details className="workflow-filters">
          <summary>
            {t("Bộ lọc báo cáo", "Report filters")}
            {filters.status || filters.visibility !== "ALL"
              ? t(" · Đang áp dụng", " · Active")
              : ""}
          </summary>
          <div className="workflow-filters__body">
            <div className={styles.filterGroup}>
              <label htmlFor="hr-report-status-filter">
                {t("Trạng thái", "Status")}
              </label>
              <select
                id="hr-report-status-filter"
                value={filters.status ?? ""}
                disabled={pending}
                onChange={(event) =>
                  void applyFilters({
                    ...filters,
                    page: 1,
                    status: event.target.value
                      ? (event.target.value as HrReportFilters["status"])
                      : null,
                  })
                }
              >
                <option value="">{t("Tất cả", "All")}</option>
                {HR_REPORT_STATUSES.map((status) => (
                  <option key={status} value={status}>
                    {HR_REPORT_STATUS_LABELS[status][locale]}
                  </option>
                ))}
              </select>
            </div>

            <div className={styles.filterGroup}>
              <label htmlFor="hr-report-visibility-filter">
                {t("Hiển thị", "Visibility")}
              </label>
              <select
                id="hr-report-visibility-filter"
                value={filters.visibility}
                disabled={pending}
                onChange={(event) =>
                  void applyFilters({
                    ...filters,
                    page: 1,
                    visibility: event.target
                      .value as HrReportFilters["visibility"],
                  })
                }
              >
                <option value="ALL">{t("Tất cả", "All")}</option>
                <option value="VISIBLE">{t("Đang hiển thị", "Visible")}</option>
                <option value="HIDDEN">{t("Đang ẩn", "Hidden")}</option>
              </select>
            </div>

            <div className={styles.filterGroup}>
              <label htmlFor="hr-report-sort">{t("Sắp xếp", "Sort")}</label>
              <select
                id="hr-report-sort"
                value={filters.sort}
                disabled={pending}
                onChange={(event) =>
                  void applyFilters({
                    ...filters,
                    page: 1,
                    sort: event.target.value as HrReportFilters["sort"],
                  })
                }
              >
                <option value="CANDIDATE_ASC">
                  {t("Tên A–Z", "Name A–Z")}
                </option>
                <option value="CANDIDATE_DESC">
                  {t("Tên Z–A", "Name Z–A")}
                </option>
                <option value="UPDATED_DESC">
                  {t("Mới cập nhật", "Recently updated")}
                </option>
              </select>
            </div>
          </div>
        </details>
        <div
          className={styles.selectionSummary}
          role="status"
          aria-live="polite"
        >
          <span>
            {t("Đã chọn", "Selected")}: {selectedIds.size}
          </span>
          <StatusMenu
            label={t("Đổi trạng thái đã chọn", "Change selected status")}
            options={statusOptions}
            disabled={
              pending ||
              !data.permissions.manageStatus ||
              selectedIds.size === 0
            }
            onSelect={(value) => void runBulkStatus(value)}
          />
        </div>
      </div>

      {feedback ? (
        <AsyncStatus kind={feedback.kind}>
          {locale === "vi" ? feedback.vi : feedback.en}
        </AsyncStatus>
      ) : null}

      {data.rows.length === 0 ? (
        <div className={styles.empty} role="status">
          <strong>
            {t("Không có báo cáo phù hợp.", "No matching reports.")}
          </strong>
        </div>
      ) : (
        <TableScrollContainer
          className={`${styles.tableScroll} workflow-list-scroll`}
        >
          <table className={styles.table}>
            <colgroup>
              <col style={{ width: 48 }} />
              <col style={{ width: "16%" }} />
              <col style={{ width: "16%" }} />
              <col style={{ width: "15%" }} />
              <col style={{ width: "10%" }} />
              <col style={{ width: 168 }} />
              <col />
              <col style={{ width: 100 }} />
            </colgroup>
            <thead>
              <tr>
                <th scope="col">
                  <label className={styles.checkboxTarget}>
                    <span className="sr-only">
                      {t("Chọn tất cả", "Select all")}
                    </span>
                    <input
                      type="checkbox"
                      checked={allVisibleSelected}
                      aria-label={t("Chọn tất cả dòng", "Select all rows")}
                      onChange={(event) => {
                        setSelectedIds(
                          event.target.checked
                            ? new Set(data.rows.map((row) => row.interviewId))
                            : new Set(),
                        );
                      }}
                    />
                  </label>
                </th>
                <th scope="col">{t("Họ và tên", "Full name")}</th>
                <th scope="col">{t("Vị trí", "Position")}</th>
                <th scope="col">
                  {t("Thời gian phỏng vấn", "Interview time")}
                </th>
                <th scope="col">{t("Địa điểm", "Location")}</th>
                <th scope="col">{t("Trạng thái", "Status")}</th>
                <th scope="col">{t("Ghi chú", "Note")}</th>
                <th scope="col">{t("Thao tác", "Actions")}</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((row) => {
                const statusLabel =
                  HR_REPORT_STATUS_LABELS[row.reportStatus][locale];
                return (
                  <tr key={row.applicationId}>
                    <td>
                      <label className={styles.checkboxTarget}>
                        <span className="sr-only">
                          {t(
                            `Chọn ${row.candidateName}`,
                            `Select ${row.candidateName}`,
                          )}
                        </span>
                        <input
                          type="checkbox"
                          checked={selectedIds.has(row.interviewId)}
                          aria-label={t(
                            `Chọn ${row.candidateName}`,
                            `Select ${row.candidateName}`,
                          )}
                          onChange={(event) => {
                            setSelectedIds((current) => {
                              const next = new Set(current);
                              if (event.target.checked) {
                                next.add(row.interviewId);
                              } else {
                                next.delete(row.interviewId);
                              }
                              return next;
                            });
                          }}
                        />
                      </label>
                    </td>
                    <td>
                      <strong>{row.candidateName}</strong>
                    </td>
                    <td>{positionLabel(row, locale)}</td>
                    <td>{formatInterviewTime(row, locale)}</td>
                    <td>{locationLabel(row, locale)}</td>
                    <td>
                      {data.permissions.manageStatus ? (
                        <StatusMenu
                          label={t(
                            `Đổi trạng thái của ${row.candidateName}`,
                            `Change status for ${row.candidateName}`,
                          )}
                          currentValue={row.reportStatus}
                          options={statusOptions}
                          disabled={pending}
                          triggerClassName={styles.statusTrigger}
                          triggerContent={
                            <StatusBadge
                              tone={hrReportStatusTone(row.reportStatus)}
                              operationalInterview
                              className={styles.statusBadge}
                            >
                              {statusLabel}
                            </StatusBadge>
                          }
                          onSelect={(value) => void runRowStatus(row, value)}
                        />
                      ) : (
                        <StatusBadge
                          tone={hrReportStatusTone(row.reportStatus)}
                          operationalInterview
                          className={styles.statusBadge}
                        >
                          {statusLabel}
                        </StatusBadge>
                      )}
                    </td>
                    <td>
                      <span
                        className={`${styles.noteCell} workflow-note-excerpt`}
                      >
                        {displayText(row.hrReportNote)}
                      </span>
                    </td>
                    <td>
                      <div className={styles.actionCell}>
                        <Button onClick={() => hydrateDrawer(row)}>
                          {t("Xem", "View")}
                        </Button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </TableScrollContainer>
      )}

      <nav
        className={`${styles.pagination} workflow-pagination`}
        aria-label={t("Phân trang", "Pagination")}
      >
        <Button
          disabled={pending || data.page <= 1}
          onClick={() =>
            void applyFilters({ ...filters, page: Math.max(1, data.page - 1) })
          }
        >
          {t("Trước", "Previous")}
        </Button>
        <span>
          {t("Trang", "Page")} {data.page} / {Math.max(data.pageCount, 1)} ·{" "}
          {data.total}
        </span>
        <Button
          disabled={
            pending || data.pageCount === 0 || data.page >= data.pageCount
          }
          onClick={() => void applyFilters({ ...filters, page: data.page + 1 })}
        >
          {t("Sau", "Next")}
        </Button>
      </nav>

      <Drawer
        open={Boolean(selectedRow)}
        title={t("Chi tiết báo cáo", "Report Detail")}
        onClose={requestCloseDrawer}
        footer={drawerFooter}
      >
        {selectedRow ? (
          <div className={styles.drawerStack}>
            {feedback ? (
              <AsyncStatus kind={feedback.kind}>
                {locale === "vi" ? feedback.vi : feedback.en}
              </AsyncStatus>
            ) : null}

            <section className={styles.drawerSection}>
              <h3>{t("Tổng quan báo cáo", "Report Overview")}</h3>
              <dl className={styles.metaGrid}>
                <dt>{t("Trạng thái", "Report Status")}</dt>
                <dd>
                  {HR_REPORT_STATUS_LABELS[selectedRow.reportStatus][locale]}
                </dd>
                <dt>{t("HR phụ trách", "HR Owner")}</dt>
                <dd>{displayText(selectedRow.drawer.hrOwnerName)}</dd>
                <dt>{t("Cập nhật cuối", "Last updated")}</dt>
                <dd>
                  {formatDateTime(selectedRow.lastUpdatedAt, locale)}
                  {selectedRow.lastUpdatedByName
                    ? ` · ${selectedRow.lastUpdatedByName}`
                    : ""}
                </dd>
              </dl>
              <div className={styles.visibilityRow}>
                <span>
                  <strong>
                    {t("Hiển thị Interviewer", "Interviewer visibility")}:
                  </strong>{" "}
                  {selectedRow.visibleToInterviewers
                    ? t("Đang hiển thị", "Visible")
                    : t("Đang ẩn", "Hidden")}
                </span>
                {data.permissions.visibility ? (
                  <Button
                    disabled={pending}
                    onClick={() => void runVisibility(selectedRow)}
                  >
                    {selectedRow.visibleToInterviewers
                      ? t("Ẩn với Interviewer", "Hide from Interviewers")
                      : t("Hiển thị với Interviewer", "Show to Interviewers")}
                  </Button>
                ) : null}
              </div>
            </section>

            <section className={styles.drawerSection}>
              <h3>{t("Ghi chú HR", "HR Report Note")}</h3>
              {data.permissions.manageStatus ? (
                <div className={styles.noteEditor}>
                  <label htmlFor="hr-report-note">
                    {t("Nội dung ghi chú", "Note content")}
                  </label>
                  <textarea
                    id="hr-report-note"
                    value={noteDraft}
                    disabled={pending}
                    onChange={(event) => setNoteDraft(event.target.value)}
                  />
                  <div className={styles.drawerActions}>
                    <Button
                      disabled={pending || !noteDirty}
                      onClick={() => {
                        setNoteDraft(noteBase);
                      }}
                    >
                      {t("Hoàn tác", "Reset")}
                    </Button>
                    <Button
                      variant="primary"
                      disabled={pending || !noteDirty}
                      onClick={() => void saveNote(selectedRow)}
                    >
                      {t("Lưu ghi chú", "Save note")}
                    </Button>
                  </div>
                </div>
              ) : (
                <p>{displayText(selectedRow.hrReportNote)}</p>
              )}
            </section>

            <section className={styles.drawerSection}>
              <h3>{t("Báo cáo của người phỏng vấn", "Participant Reports")}</h3>
              <div className={styles.participantList}>
                {selectedRow.drawer.participants.length === 0 ? (
                  <p>
                    {t(
                      "Chưa có người phỏng vấn hiện hành.",
                      "No current participants.",
                    )}
                  </p>
                ) : (
                  selectedRow.drawer.participants.map((participant) => {
                    const editing =
                      participant.interviewParticipantId ===
                      editingParticipantId;
                    return (
                      <article
                        className={styles.participantCard}
                        key={participant.interviewParticipantId}
                      >
                        <div className={styles.participantHeading}>
                          <div>
                            <h4>{participant.name}</h4>
                            <span>{displayText(participant.jobTitle)}</span>
                          </div>
                          <div className={styles.participantActions}>
                            {data.permissions.editInterviewer ? (
                              <Button
                                className={
                                  editing ? undefined : "workflow-edit-action"
                                }
                                disabled={pending}
                                onClick={() =>
                                  requestParticipantEdit(participant)
                                }
                              >
                                {editing
                                  ? t("Hủy sửa", "Cancel edit")
                                  : t("Sửa", "Edit")}
                              </Button>
                            ) : null}
                            {data.permissions.delete &&
                            participant.interviewReportId ? (
                              <Button
                                variant="danger"
                                disabled={pending}
                                onClick={() =>
                                  setDeleteParticipant(participant)
                                }
                              >
                                {t("Xóa / Inactive", "Delete / Inactivate")}
                              </Button>
                            ) : null}
                          </div>
                        </div>

                        {editing && reportDraft ? (
                          <div className={styles.reportEditor}>
                            {REPORT_FIELD_KEYS.map((key) => (
                              <label key={key}>
                                {
                                  REPORT_FIELD_LABELS[key][
                                    locale === "vi" ? 0 : 1
                                  ]
                                }
                                <textarea
                                  value={reportDraft[key] ?? ""}
                                  disabled={pending}
                                  onChange={(event) =>
                                    setReportDraft((current) =>
                                      current
                                        ? {
                                            ...current,
                                            [key]: event.target.value,
                                          }
                                        : current,
                                    )
                                  }
                                />
                              </label>
                            ))}
                            <div className={styles.participantActions}>
                              <Button
                                disabled={pending}
                                onClick={() =>
                                  currentEditingParticipant
                                    ? requestParticipantEdit(
                                        currentEditingParticipant,
                                      )
                                    : resetEditing()
                                }
                              >
                                {t("Hủy", "Cancel")}
                              </Button>
                              <Button
                                variant="primary"
                                pending={pending}
                                onClick={() =>
                                  void saveParticipantReport(selectedRow)
                                }
                              >
                                {t("Lưu báo cáo", "Save report")}
                              </Button>
                            </div>
                          </div>
                        ) : (
                          <dl className={styles.reportFields}>
                            {REPORT_FIELD_KEYS.map((key) => (
                              <div key={key}>
                                <dt>
                                  {
                                    REPORT_FIELD_LABELS[key][
                                      locale === "vi" ? 0 : 1
                                    ]
                                  }
                                </dt>
                                <dd>{displayText(participant.report[key])}</dd>
                              </div>
                            ))}
                          </dl>
                        )}
                      </article>
                    );
                  })
                )}
              </div>
            </section>

            <section className={styles.drawerSection}>
              <h3>{t("Quyết định cuối", "Final Decision")}</h3>
              <div className={styles.finalDecision}>
                <dl className={styles.metaGrid}>
                  <dt>{t("Nguồn", "Source")}</dt>
                  <dd>
                    {displayText(
                      selectedRow.drawer.finalDecision.sourceParticipantName,
                    )}
                  </dd>
                  <dt>{t("Kết luận", "Conclusion")}</dt>
                  <dd>
                    {displayText(selectedRow.drawer.finalDecision.conclusion)}
                  </dd>
                  <dt>{t("Công việc dự kiến", "Expected assignment")}</dt>
                  <dd>
                    {displayText(
                      selectedRow.drawer.finalDecision
                        .expectedSpecificJobAssigned,
                    )}
                  </dd>
                  <dt>
                    {t("Thời gian tuyển dụng", "Expected recruitment time")}
                  </dt>
                  <dd>
                    {displayText(
                      selectedRow.drawer.finalDecision.expectedRecruitmentTime,
                    )}
                  </dd>
                  <dt>{t("Cập nhật quyết định", "Decision updated")}</dt>
                  <dd>
                    {formatDateTime(
                      selectedRow.drawer.finalDecision.updatedAt,
                      locale,
                    )}
                    {selectedRow.drawer.finalDecision.updatedByName
                      ? ` · ${selectedRow.drawer.finalDecision.updatedByName}`
                      : ""}
                  </dd>
                </dl>
              </div>
            </section>
          </div>
        ) : null}
      </Drawer>

      <Dialog
        open={discardOpen}
        title={t("Bỏ thay đổi chưa lưu?", "Discard unsaved changes?")}
        onClose={() => setDiscardOpen(false)}
        footer={
          <div className={styles.dialogActions}>
            <Button onClick={() => setDiscardOpen(false)}>
              {t("Tiếp tục sửa", "Keep editing")}
            </Button>
            <Button variant="danger" onClick={closeDrawerNow}>
              {t("Bỏ thay đổi", "Discard changes")}
            </Button>
          </div>
        }
      >
        <p>
          {t(
            "Các thay đổi chưa lưu trong ghi chú hoặc báo cáo sẽ bị mất.",
            "Unsaved note or report changes will be lost.",
          )}
        </p>
      </Dialog>

      <Dialog
        open={Boolean(deleteParticipant && selectedRow)}
        title={t("Xóa / Inactive báo cáo?", "Delete / inactivate report?")}
        onClose={() => {
          if (!pending) setDeleteParticipant(null);
        }}
        footer={
          selectedRow ? (
            <div className={styles.dialogActions}>
              <Button
                disabled={pending}
                onClick={() => setDeleteParticipant(null)}
              >
                {t("Hủy", "Cancel")}
              </Button>
              <Button
                variant="danger"
                pending={pending}
                onClick={() => void confirmDeleteParticipant(selectedRow)}
              >
                {t("Xác nhận", "Confirm")}
              </Button>
            </div>
          ) : undefined
        }
      >
        <p>
          {t(
            "Chỉ báo cáo cụ thể của người phỏng vấn này bị tác động. Báo cáo đã sử dụng sẽ được chuyển Inactive/Archive; báo cáo trống chưa sử dụng có thể bị xóa.",
            "Only this participant report is affected. Used reports are inactivated/archived; unused empty reports may be deleted.",
          )}
        </p>
      </Dialog>
    </section>
  );
}
