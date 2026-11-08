"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  enqueueInterviewEmailAction,
  previewInterviewEmailAction,
} from "@/app/interviews/actions";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import type {
  EmailPreviewData,
  InterviewEmailType,
} from "@/lib/commands/email-commands";
import styles from "./EmailUi.module.css";

export interface EmailPreviewDialogProps {
  open: boolean;
  emailType: InterviewEmailType;
  interviewId: string;
  applicationId: string;
  submissionId: string;
  contextSummary: string;
  onClose: () => void;
  onQueued: () => void;
}

export function EmailPreviewDialog({
  open,
  emailType,
  interviewId,
  applicationId,
  submissionId,
  contextSummary,
  onClose,
  onQueued,
}: EmailPreviewDialogProps) {
  const [preview, setPreview] = useState<EmailPreviewData | null>(null);
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const idempotencyKey = useRef<string | null>(null);

  const loadPreview = useCallback(
    async (notice?: string) => {
      setLoading(true);
      setPreview(null);
      setMessage(notice ?? null);
      idempotencyKey.current = null;
      try {
        const result = await previewInterviewEmailAction({
          emailType,
          interviewId,
          applicationId,
          submissionId,
        });
        if (!result.success) {
          setMessage(result.error.message);
          return;
        }
        setPreview(result.data);
      } catch {
        setMessage("Không thể tải bản xem trước email. Vui lòng thử lại.");
      } finally {
        setLoading(false);
      }
    },
    [applicationId, emailType, interviewId, submissionId],
  );

  useEffect(() => {
    if (open) void loadPreview();
  }, [open, loadPreview]);

  const confirmSend = async () => {
    if (!preview || sending) return;
    setSending(true);
    setMessage(null);
    const key = idempotencyKey.current ?? crypto.randomUUID();
    idempotencyKey.current = key;
    try {
      const result = await enqueueInterviewEmailAction({
        request: {
          email_type: preview.email_type,
          interview_id: preview.interview_id,
          application_id: preview.application_id,
          submission_id: preview.submission_id,
          preview_fingerprint: preview.preview_fingerprint,
        },
        idempotencyKey: key,
      });
      if (!result.success) {
        if (result.error.code === "STALE_PREVIEW") {
          await loadPreview(
            "Thông tin phỏng vấn đã thay đổi, vui lòng xem lại bản xem trước.",
          );
          return;
        }
        setMessage(result.error.message);
        return;
      }
      idempotencyKey.current = null;
      onQueued();
      onClose();
    } catch {
      setMessage("Không thể đưa email vào hàng đợi. Vui lòng thử lại.");
    } finally {
      setSending(false);
    }
  };

  const title =
    emailType === "INTERVIEW_INVITATION"
      ? "Bản xem trước email — Ứng viên"
      : "Bản xem trước email — Người tham dự";

  return (
    <Dialog
      open={open}
      title={title}
      onClose={sending ? () => undefined : onClose}
      footer={
        <div className="interview-drawer-actions">
          <Button variant="ghost" disabled={sending} onClick={onClose}>
            Đóng
          </Button>
          <Button
            variant="primary"
            pending={sending}
            disabled={!preview || loading}
            onClick={() => void confirmSend()}
          >
            Xác nhận gửi
          </Button>
        </div>
      }
    >
      <div className="interview-form-grid">
        <p className="interview-form-span">
          <strong>Ngữ cảnh:</strong> {contextSummary}
        </p>
        {message ? (
          <p
            className="interview-field-hint interview-form-span"
            role="status"
            aria-live="polite"
          >
            {message}
          </p>
        ) : null}
        {loading ? (
          <p className="interview-form-span" role="status">
            Đang tạo bản xem trước…
          </p>
        ) : null}
        {preview ? (
          <>
            <div className="interview-form-span">
              <strong>To</strong>
              <ul className={styles.recipientList}>
                {preview.recipients.to.map((recipient) => (
                  <li key={recipient}>{recipient}</li>
                ))}
              </ul>
            </div>
            {preview.recipients.cc.length ? (
              <div className="interview-form-span">
                <strong>CC</strong>
                <ul className={styles.recipientList}>
                  {preview.recipients.cc.map((recipient) => (
                    <li key={recipient}>{recipient}</li>
                  ))}
                </ul>
              </div>
            ) : null}
            <p className="interview-form-span">
              <strong>Subject:</strong> {preview.subject}
            </p>
            <div className="interview-form-span">
              <strong>Nội dung</strong>
              <pre className={styles.previewBody}>{preview.body_text}</pre>
            </div>
            <p className="interview-field-hint interview-form-span">
              Template {preview.template_version} · {preview.environment_code}
            </p>
          </>
        ) : null}
      </div>
    </Dialog>
  );
}
