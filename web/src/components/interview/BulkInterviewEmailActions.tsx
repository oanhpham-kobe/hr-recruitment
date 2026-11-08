"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  bulkEnqueueInterviewEmailsAction,
  getInterviewEmailCapabilitiesAction,
  previewInterviewEmailAction,
} from "@/app/interviews/actions";
import { AsyncStatus } from "@/components/ui/AsyncStatus";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import type {
  BulkEmailResult,
  EmailCommandError,
  EmailPreviewData,
  InterviewEmailType,
} from "@/lib/commands/email-commands";
import {
  formatInterviewTime,
  type InterviewApplicationGroup,
  type InterviewRound,
} from "@/lib/interview/model";
import styles from "./EmailUi.module.css";

export interface BulkInterviewEmailTarget {
  application: InterviewApplicationGroup;
  round: InterviewRound;
}

type PreviewItem = {
  target: BulkInterviewEmailTarget;
  preview: EmailPreviewData | null;
  error: EmailCommandError | null;
};

function targetLabel(target: BulkInterviewEmailTarget): string {
  return `${target.application.candidateName} — Vòng ${target.round.roundNo}`;
}

function hasCurrentParticipants(target: BulkInterviewEmailTarget): boolean {
  return target.round.participants.some((participant) => participant.isCurrent);
}

function BulkEmailPreviewDialog({
  open,
  emailType,
  targets,
  onClose,
}: {
  open: boolean;
  emailType: InterviewEmailType;
  targets: BulkInterviewEmailTarget[];
  onClose: () => void;
}) {
  const [items, setItems] = useState<PreviewItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [result, setResult] = useState<BulkEmailResult | null>(null);
  const idempotencyKey = useRef<string | null>(null);

  const labelsByInterview = useMemo(
    () =>
      new Map(
        targets.map((target) => [
          target.round.interviewId,
          targetLabel(target),
        ]),
      ),
    [targets],
  );

  const loadPreviews = useCallback(async () => {
    setLoading(true);
    setItems([]);
    setMessage(null);
    setResult(null);
    idempotencyKey.current = null;
    try {
      const nextItems = await Promise.all(
        targets.map(async (target): Promise<PreviewItem> => {
          const previewResult = await previewInterviewEmailAction({
            emailType,
            interviewId: target.round.interviewId,
            applicationId: target.application.applicationId,
            submissionId: target.application.submissionId,
          });
          if (!previewResult.success) {
            return {
              target,
              preview: null,
              error: previewResult.error,
            };
          }
          return {
            target,
            preview: previewResult.data,
            error: null,
          };
        }),
      );
      setItems(nextItems);
      const failed = nextItems.filter((item) => item.error);
      if (failed.length) {
        setMessage(
          `Không thể tạo ${failed.length}/${nextItems.length} bản xem trước. Hãy xử lý lỗi trước khi gửi hàng loạt.`,
        );
      }
    } catch {
      setMessage(
        "Không thể tải bản xem trước email hàng loạt. Vui lòng thử lại.",
      );
    } finally {
      setLoading(false);
    }
  }, [emailType, targets]);

  useEffect(() => {
    if (open) void loadPreviews();
  }, [open, loadPreviews]);

  const readyItems = items.filter((item) => item.preview);
  const canConfirm =
    !loading &&
    !sending &&
    items.length === targets.length &&
    readyItems.length === targets.length &&
    targets.length >= 1 &&
    targets.length <= 100 &&
    result === null;

  const confirmBulkSend = async () => {
    if (!canConfirm) return;
    const previews = items.flatMap((item) =>
      item.preview ? [item.preview] : [],
    );
    if (previews.length !== targets.length) return;
    const key = idempotencyKey.current ?? crypto.randomUUID();
    idempotencyKey.current = key;
    setSending(true);
    setMessage(null);
    try {
      const bulkResult = await bulkEnqueueInterviewEmailsAction({
        requests: previews.map((preview) => ({
          email_type: preview.email_type,
          interview_id: preview.interview_id,
          application_id: preview.application_id,
          submission_id: preview.submission_id,
          preview_fingerprint: preview.preview_fingerprint,
        })),
        idempotencyKey: key,
      });
      if (!bulkResult.success) {
        setMessage(bulkResult.error.message);
        return;
      }
      setResult(bulkResult.data);
      setMessage(
        bulkResult.data.failed.length
          ? `Đã đưa ${bulkResult.data.success.length} email vào hàng đợi; ${bulkResult.data.failed.length} email thất bại. Kết quả từng Interview hiển thị bên dưới.`
          : `Đã đưa ${bulkResult.data.success.length} email vào hàng đợi gửi thư.`,
      );
    } catch {
      setMessage("Không thể hoàn tất gửi email hàng loạt. Vui lòng thử lại.");
    } finally {
      setSending(false);
    }
  };

  const title =
    emailType === "INTERVIEW_INVITATION"
      ? `Bản xem trước email ứng viên — ${targets.length} Interview`
      : `Bản xem trước email người tham dự — ${targets.length} Interview`;

  return (
    <Dialog
      open={open}
      title={title}
      onClose={loading || sending ? () => undefined : onClose}
      footer={
        <div className="interview-drawer-actions">
          <Button
            variant="ghost"
            disabled={loading || sending}
            onClick={onClose}
          >
            Đóng
          </Button>
          {!result ? (
            <>
              <Button
                variant="ghost"
                disabled={loading || sending}
                onClick={() => void loadPreviews()}
              >
                Tải lại bản xem trước
              </Button>
              <Button
                variant="primary"
                pending={sending}
                disabled={!canConfirm}
                onClick={() => void confirmBulkSend()}
              >
                Xác nhận gửi {targets.length} email
              </Button>
            </>
          ) : null}
        </div>
      }
    >
      <div className={styles.bulkDialog}>
        <p className="interview-field-hint">
          Mỗi Interview được preview riêng từ server. Mỗi fingerprint dưới đây
          được giữ nguyên khi gọi bulk enqueue; người nhận người tham dự luôn do
          server xác định từ toàn bộ current Participants của từng Interview.
        </p>
        {message ? (
          <AsyncStatus kind={result?.failed.length ? "warning" : "info"}>
            {message}
          </AsyncStatus>
        ) : null}
        {loading ? <AsyncStatus>Đang tạo bản xem trước…</AsyncStatus> : null}

        {!result ? (
          <div className={styles.bulkPreviewList}>
            {items.map((item) => (
              <article
                key={item.target.round.interviewId}
                className={styles.bulkPreviewCard}
                data-interview-id={item.target.round.interviewId}
              >
                <h3>{targetLabel(item.target)}</h3>
                <p className="interview-field-hint">
                  {formatInterviewTime(
                    item.target.round.startAt,
                    item.target.round.endAt,
                  )}
                </p>
                {item.error ? (
                  <AsyncStatus kind="error">
                    {item.error.message} ({item.error.code})
                  </AsyncStatus>
                ) : null}
                {item.preview ? (
                  <>
                    <div>
                      <strong>To</strong>
                      <ul className={styles.recipientList}>
                        {item.preview.recipients.to.map((recipient) => (
                          <li key={recipient}>{recipient}</li>
                        ))}
                      </ul>
                    </div>
                    {item.preview.recipients.cc.length ? (
                      <div>
                        <strong>CC</strong>
                        <ul className={styles.recipientList}>
                          {item.preview.recipients.cc.map((recipient) => (
                            <li key={recipient}>{recipient}</li>
                          ))}
                        </ul>
                      </div>
                    ) : null}
                    <p>
                      <strong>Subject:</strong> {item.preview.subject}
                    </p>
                    <pre className={styles.previewBody}>
                      {item.preview.body_text}
                    </pre>
                    <p className="interview-field-hint">
                      Template {item.preview.template_version} ·{" "}
                      {item.preview.environment_code}
                    </p>
                  </>
                ) : null}
              </article>
            ))}
          </div>
        ) : (
          <div className={styles.bulkResult} aria-live="polite">
            <h3>Kết quả enqueue theo Interview</h3>
            <ul className={styles.bulkResultList}>
              {result.success.map((item) => (
                <li key={`success-${item.id}-${item.email_type ?? "email"}`}>
                  <strong>{labelsByInterview.get(item.id) ?? item.id}</strong>:
                  Đã vào hàng đợi
                  {item.email_outbox_id ? ` · ${item.email_outbox_id}` : ""}
                </li>
              ))}
              {result.failed.map((item) => (
                <li key={`failed-${item.id}-${item.error_code ?? "error"}`}>
                  <strong>{labelsByInterview.get(item.id) ?? item.id}</strong>:
                  Thất bại · {item.error_code ?? "INTERNAL_ERROR"}
                </li>
              ))}
            </ul>
            {result.failed.length ? (
              <p className="interview-field-hint">
                Không tự retry toàn bộ batch để tránh tạo email trùng cho các
                Interview đã enqueue thành công. Đóng dialog, chỉ chọn lại các
                Interview thất bại, xem preview mới rồi gửi lại.
              </p>
            ) : null}
          </div>
        )}
      </div>
    </Dialog>
  );
}

export function BulkInterviewEmailActions({
  targets,
  disabled = false,
}: {
  targets: BulkInterviewEmailTarget[];
  disabled?: boolean;
}) {
  const [canSend, setCanSend] = useState(false);
  const [resolved, setResolved] = useState(false);
  const [emailType, setEmailType] = useState<InterviewEmailType | null>(null);

  useEffect(() => {
    let active = true;
    void getInterviewEmailCapabilitiesAction()
      .then((capabilities) => {
        if (!active) return;
        setCanSend(capabilities.canSend);
        setResolved(true);
      })
      .catch(() => {
        if (!active) return;
        setCanSend(false);
        setResolved(true);
      });
    return () => {
      active = false;
    };
  }, []);

  const uniqueTargets = useMemo(
    () =>
      Array.from(
        new Map(
          targets.map((target) => [target.round.interviewId, target] as const),
        ).values(),
      ),
    [targets],
  );
  const tooMany = uniqueTargets.length > 100;
  const allOperational = uniqueTargets.every(
    (target) => target.application.isActive && target.round.isActive,
  );
  const candidateReady =
    allOperational &&
    uniqueTargets.every((target) => Boolean(target.application.candidateEmail));
  const participantReady =
    allOperational && uniqueTargets.every(hasCurrentParticipants);

  if (!uniqueTargets.length || !resolved || !canSend) return null;

  return (
    <section
      className={styles.bulkBar}
      aria-label="Gửi email cho Interview đã chọn"
    >
      <div>
        <strong>{uniqueTargets.length} Interview đã chọn cho email</strong>
        <p className="interview-field-hint">
          Gửi hàng loạt luôn preview từng Interview trước; tối đa 100 request
          mỗi batch.
        </p>
      </div>
      <div className={styles.bulkActions}>
        <Button
          disabled={disabled || tooMany || !candidateReady}
          onClick={() => setEmailType("INTERVIEW_INVITATION")}
        >
          Gửi thư ứng viên đã chọn
        </Button>
        <Button
          disabled={disabled || tooMany || !participantReady}
          onClick={() => setEmailType("INTERVIEW_PARTICIPANT_INVITATION")}
        >
          Gửi thư người tham dự đã chọn
        </Button>
      </div>
      {tooMany ? (
        <AsyncStatus kind="warning">
          Chỉ được gửi tối đa 100 Interview trong một batch.
        </AsyncStatus>
      ) : null}
      {!allOperational ? (
        <AsyncStatus kind="warning">
          Chỉ Interview và Application đang hoạt động mới có thể gửi email.
        </AsyncStatus>
      ) : null}
      {emailType ? (
        <BulkEmailPreviewDialog
          open
          emailType={emailType}
          targets={uniqueTargets}
          onClose={() => setEmailType(null)}
        />
      ) : null}
    </section>
  );
}
