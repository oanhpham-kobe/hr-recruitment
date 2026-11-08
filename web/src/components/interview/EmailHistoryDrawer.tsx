"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  deleteEmailHistoryEntryAction,
  loadInterviewEmailHistoryAction,
} from "@/app/interviews/actions";
import { AsyncStatus } from "@/components/ui/AsyncStatus";
import { Button } from "@/components/ui/Button";
import { Drawer } from "@/components/ui/Drawer";
import { StatusBadge } from "@/components/ui/StatusBadge";
import type { EmailHistoryEntry } from "@/lib/commands/email-commands";
import {
  type EmailHistoryDeleteClassification,
  emailHistoryStatusTone,
  emailHistoryTimestamp,
  formatEmailHistoryRecipients,
} from "@/lib/interview/email-ui";
import { DeleteEmailHistoryDialog } from "./DeleteEmailHistoryDialog";
import styles from "./EmailUi.module.css";

function formatTimestamp(value: string): string {
  return new Intl.DateTimeFormat("vi-VN", {
    timeZone: "Asia/Ho_Chi_Minh",
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
}

export function EmailHistoryDrawer({
  open,
  interviewId,
  title,
  canDelete,
  onClose,
}: {
  open: boolean;
  interviewId: string;
  title: string;
  canDelete: boolean;
  onClose: () => void;
}) {
  const [rows, setRows] = useState<EmailHistoryEntry[]>([]);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [message, setMessage] = useState<{
    kind: "info" | "success" | "error" | "warning";
    text: string;
  } | null>(null);

  const loadHistory = useCallback(
    async (clearMessage = true): Promise<boolean> => {
      setLoading(true);
      if (clearMessage) setMessage(null);
      try {
        const result = await loadInterviewEmailHistoryAction(interviewId);
        if (!result.success) {
          setRows([]);
          setSelectedIds(new Set());
          setMessage({ kind: "error", text: result.error.message });
          return false;
        }
        setRows(result.data);
        setSelectedIds(new Set());
        return true;
      } catch {
        setRows([]);
        setSelectedIds(new Set());
        setMessage({
          kind: "error",
          text: "Không thể tải Email History. Vui lòng thử lại.",
        });
        return false;
      } finally {
        setLoading(false);
      }
    },
    [interviewId],
  );

  useEffect(() => {
    if (open) void loadHistory();
  }, [open, loadHistory]);

  const selectedRows = useMemo(
    () => rows.filter((row) => selectedIds.has(row.email_history_id)),
    [rows, selectedIds],
  );
  const testRecordAllowed =
    selectedRows.length > 0 &&
    selectedRows.every((row) => row.environment_code === "TEST");
  const allSelected = rows.length > 0 && selectedIds.size === rows.length;

  const toggleRow = (id: string) => {
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const deleteSelected = async (
    classification: EmailHistoryDeleteClassification,
    reason: string | null,
  ) => {
    if (!selectedRows.length || deleting) return;
    setDeleting(true);
    setMessage(null);
    let deleted = 0;
    let failure: string | null = null;
    try {
      for (const row of selectedRows) {
        const result = await deleteEmailHistoryEntryAction({
          emailHistoryId: row.email_history_id,
          classification,
          reason,
        });
        if (!result.success) {
          failure =
            deleted > 0
              ? `Đã xóa ${deleted} bản ghi trước khi gặp lỗi: ${result.error.message}`
              : result.error.message;
          break;
        }
        deleted += 1;
      }
      setDeleteOpen(false);
      const refreshed = await loadHistory(false);
      if (!refreshed) return;
      setMessage(
        failure
          ? { kind: "error", text: failure }
          : {
              kind: "success",
              text: `Đã xóa ${deleted} bản ghi Email History. Security audit vẫn được giữ nguyên.`,
            },
      );
    } catch {
      await loadHistory(false);
      setMessage({
        kind: "error",
        text:
          deleted > 0
            ? `Đã xóa ${deleted} bản ghi trước khi thao tác bị gián đoạn.`
            : "Không thể hoàn tất xóa Email History. Vui lòng thử lại.",
      });
    } finally {
      setDeleting(false);
    }
  };

  return (
    <>
      <Drawer
        open={open}
        title={`Lịch sử gửi thư — ${title}`}
        onClose={deleting ? () => undefined : onClose}
        footer={
          <div className="interview-drawer-actions">
            <Button
              disabled={loading || deleting}
              onClick={() => void loadHistory()}
            >
              Tải lại
            </Button>
            {canDelete ? (
              <Button
                variant="danger"
                disabled={!selectedIds.size || loading || deleting}
                onClick={() => setDeleteOpen(true)}
              >
                Xóa đã chọn ({selectedIds.size})
              </Button>
            ) : null}
          </div>
        }
      >
        <div className={styles.history}>
          <p className="interview-field-hint">
            Email History chỉ hiển thị kết quả giao nhận đã hoàn tất. Trạng thái
            hàng đợi QUEUED thuộc Email Outbox và không được tổng hợp vào đây.
          </p>
          {message ? (
            <AsyncStatus kind={message.kind}>{message.text}</AsyncStatus>
          ) : null}
          {loading ? <AsyncStatus>Đang tải Email History…</AsyncStatus> : null}
          {!loading && !rows.length ? (
            <p>Chưa có Email History cho Interview này.</p>
          ) : null}
          {rows.length ? (
            <div className={styles.tableScroll}>
              <table className={styles.table}>
                <caption className="sr-only">
                  Email History của Interview hiện tại
                </caption>
                <thead>
                  <tr>
                    {canDelete ? (
                      <th scope="col">
                        <label>
                          <span className="sr-only">
                            Chọn tất cả Email History
                          </span>
                          <input
                            type="checkbox"
                            checked={allSelected}
                            aria-label="Chọn tất cả Email History"
                            onChange={(event) =>
                              setSelectedIds(
                                event.target.checked
                                  ? new Set(
                                      rows.map((row) => row.email_history_id),
                                    )
                                  : new Set(),
                              )
                            }
                          />
                        </label>
                      </th>
                    ) : null}
                    <th scope="col">Người nhận</th>
                    <th scope="col">Subject</th>
                    <th scope="col">Template</th>
                    <th scope="col">Trạng thái</th>
                    <th scope="col">Thời gian</th>
                    <th scope="col">Lỗi</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.email_history_id}>
                      {canDelete ? (
                        <td>
                          <input
                            type="checkbox"
                            checked={selectedIds.has(row.email_history_id)}
                            aria-label={`Chọn Email History ${row.subject ?? row.email_history_id}`}
                            onChange={() => toggleRow(row.email_history_id)}
                          />
                        </td>
                      ) : null}
                      <td>
                        {formatEmailHistoryRecipients(row.recipients) || "—"}
                      </td>
                      <td>{row.subject ?? "—"}</td>
                      <td>
                        <div>{row.email_type}</div>
                        <span className="interview-field-hint">
                          {row.template_version ?? "—"} · {row.environment_code}
                        </span>
                      </td>
                      <td>
                        <StatusBadge
                          tone={emailHistoryStatusTone(row.status_code)}
                        >
                          {row.status_code}
                        </StatusBadge>
                      </td>
                      <td>{formatTimestamp(emailHistoryTimestamp(row))}</td>
                      <td>
                        {row.status_code === "FAILED"
                          ? (row.error_code ?? "—")
                          : "—"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : null}
        </div>
      </Drawer>
      <DeleteEmailHistoryDialog
        open={deleteOpen}
        recordCount={selectedRows.length}
        testRecordAllowed={testRecordAllowed}
        pending={deleting}
        onClose={() => setDeleteOpen(false)}
        onConfirm={deleteSelected}
      />
    </>
  );
}
