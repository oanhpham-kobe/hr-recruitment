"use client";

import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import {
  type EmailHistoryDeleteClassification,
  validateEmailHistoryDeletion,
} from "@/lib/interview/email-ui";

export function DeleteEmailHistoryDialog({
  open,
  recordCount,
  testRecordAllowed,
  pending,
  onClose,
  onConfirm,
}: {
  open: boolean;
  recordCount: number;
  testRecordAllowed: boolean;
  pending: boolean;
  onClose: () => void;
  onConfirm: (
    classification: EmailHistoryDeleteClassification,
    reason: string | null,
  ) => Promise<void>;
}) {
  const [classification, setClassification] =
    useState<EmailHistoryDeleteClassification>("WRONG_RECORD");
  const [reason, setReason] = useState("");
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setClassification(testRecordAllowed ? "TEST_RECORD" : "WRONG_RECORD");
    setReason("");
    setMessage(null);
  }, [open, testRecordAllowed]);

  const validation = useMemo(
    () =>
      validateEmailHistoryDeletion(classification, reason, testRecordAllowed),
    [classification, reason, testRecordAllowed],
  );

  const confirm = async () => {
    if (validation || pending) {
      setMessage(validation);
      return;
    }
    setMessage(null);
    await onConfirm(
      classification,
      classification === "WRONG_RECORD" ? reason.trim() : null,
    );
  };

  return (
    <Dialog
      open={open}
      title="Xóa Email History"
      onClose={pending ? () => undefined : onClose}
      footer={
        <div className="interview-drawer-actions">
          <Button variant="ghost" disabled={pending} onClick={onClose}>
            Hủy
          </Button>
          <Button
            variant="danger"
            pending={pending}
            disabled={Boolean(validation)}
            onClick={() => void confirm()}
          >
            Xóa {recordCount} bản ghi
          </Button>
        </div>
      }
    >
      <div className="interview-form-grid">
        <p className="interview-form-span">
          Email History là lịch sử vận hành. Khi xóa, security audit đã ghi nhận
          thao tác vẫn bất biến và không bị xóa theo.
        </p>
        <label className="interview-form-span">
          Phân loại xóa
          <select
            value={classification}
            disabled={pending}
            onChange={(event) => {
              setClassification(
                event.target.value as EmailHistoryDeleteClassification,
              );
              setMessage(null);
            }}
          >
            <option value="TEST_RECORD" disabled={!testRecordAllowed}>
              TEST_RECORD — Bản ghi thử nghiệm
            </option>
            <option value="WRONG_RECORD">
              WRONG_RECORD — Bản ghi vận hành sai
            </option>
          </select>
        </label>
        {classification === "WRONG_RECORD" ? (
          <label className="interview-form-span">
            Lý do xóa
            <textarea
              rows={4}
              maxLength={1000}
              required
              disabled={pending}
              value={reason}
              onChange={(event) => {
                setReason(event.target.value);
                setMessage(null);
              }}
              aria-describedby="email-history-delete-reason-hint"
            />
            <span
              id="email-history-delete-reason-hint"
              className="interview-field-hint"
            >
              Bắt buộc, tối đa 1000 ký tự. {reason.length}/1000
            </span>
          </label>
        ) : (
          <p className="interview-field-hint interview-form-span">
            TEST_RECORD chỉ được phép khi tất cả bản ghi đã chọn thuộc môi
            trường TEST.
          </p>
        )}
        {message ? (
          <p className="interview-field-hint interview-form-span" role="alert">
            {message}
          </p>
        ) : null}
      </div>
    </Dialog>
  );
}
