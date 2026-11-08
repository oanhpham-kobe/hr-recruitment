"use client";
import { useEffect, useState } from "react";
import { useAppLocale } from "@/components/shell/LocaleProvider";
import { Button } from "@/components/ui/Button";
import type {
  Consolidation,
  Detail,
  FeedbackApi,
  HrDetail,
  OwnDetail,
  Result,
} from "@/lib/interview-feedback/model";
export function useFeedbackText() {
  const { locale } = useAppLocale();
  return (vi: string, en: string) => (locale === "vi" ? vi : en);
}
export function errorText(code: string, t: (vi: string, en: string) => string) {
  const messages: Record<string, [string, string]> = {
    STALE_VERSION: [
      "Dữ liệu đã thay đổi. Nội dung chưa lưu vẫn được giữ. Tải bản mới trước khi thử lại.",
      "The record changed. Unsaved text is preserved. Load the latest version before retrying.",
    ],
    CONTEXT_NOT_WRITABLE: [
      "Vòng phỏng vấn không còn cho phép ghi.",
      "This interview round no longer permits changes.",
    ],
    DEADLINE_PASSED: [
      "Đã hết hạn phản hồi.",
      "The response deadline has passed.",
    ],
    REQUIRED_ANSWER_MISSING: [
      "Vui lòng trả lời các câu hỏi bắt buộc.",
      "Please answer all required questions.",
    ],
    ALREADY_SUBMITTED: [
      "Phản hồi đã nộp và không thể sửa.",
      "This response has been submitted and cannot be edited.",
    ],
    INVITATION_REVOKED: [
      "Lời mời đã bị thu hồi.",
      "This invitation has been revoked.",
    ],
    COMPLETENESS_REQUIRED: [
      "Cần đủ phản hồi hợp lệ từ tất cả người được chọn ban đầu.",
      "Valid responses from every originally selected evaluator are required.",
    ],
    ALREADY_APPROVED: [
      "Báo cáo đã duyệt và không thể sửa.",
      "This report is approved and cannot be edited.",
    ],
    FORBIDDEN: [
      "Bạn không có quyền truy cập dữ liệu này.",
      "You do not have access to this record.",
    ],
    UNAUTHENTICATED: [
      "Vui lòng đăng nhập bằng tài khoản nội bộ.",
      "Please sign in with an internal account.",
    ],
    NOT_FOUND: [
      "Không tìm thấy dữ liệu hoặc quyền truy cập đã thay đổi.",
      "Record not found or access has changed.",
    ],
    VALIDATION_ERROR: [
      "Kiểm tra thông tin đã nhập.",
      "Check the values you entered.",
    ],
  };
  const pair = messages[code] ?? [
    "Không thể hoàn tất. Nội dung nhập được giữ; vui lòng thử lại.",
    "Unable to complete. Your text is preserved; please retry.",
  ];
  return t(pair[0], pair[1]);
}
function useUnsavedWarning(dirty: boolean) {
  useEffect(() => {
    if (!dirty) return;
    const handler = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, [dirty]);
}
export function FeedbackContext({
  detail,
}: {
  detail: Pick<Detail, "context" | "template" | "collection">;
}) {
  const t = useFeedbackText();
  const c = detail.context;
  return (
    <div className="feedback-context">
      <strong>{c.candidate_name}</strong>
      <p>
        {c.position_name} · {c.unit_name}
      </p>
      <p>
        {t("Vòng", "Round")} {c.round_no} ·{" "}
        {c.start_at
          ? new Date(c.start_at).toLocaleString(t("vi-VN", "en-GB"))
          : t("Chưa xếp lịch", "Not scheduled")}
      </p>
      <p>
        {detail.template.name} · {t("Phiên bản", "Version")}{" "}
        {detail.template.version_no}
      </p>
      <p>
        {t("Hạn phản hồi", "Response deadline")}:{" "}
        {detail.collection.deadline_at
          ? new Date(detail.collection.deadline_at).toLocaleString(
              t("vi-VN", "en-GB"),
            )
          : t("Không đặt hạn", "No deadline")}
      </p>
    </div>
  );
}
export function FeedbackDetail({
  detail,
  api,
  onRefresh,
}: {
  detail: Detail;
  api: FeedbackApi;
  onRefresh: () => Promise<void>;
}) {
  return detail.mode === "OWN" ? (
    <OwnResponse
      key={detail.invitation.invitation_id}
      detail={detail}
      api={api}
      onRefresh={onRefresh}
    />
  ) : (
    <HrCollection
      key={detail.collection.collection_id}
      detail={detail}
      api={api}
      onRefresh={onRefresh}
    />
  );
}
function OwnResponse({
  detail,
  api,
  onRefresh,
}: {
  detail: OwnDetail;
  api: FeedbackApi;
  onRefresh: () => Promise<void>;
}) {
  const t = useFeedbackText();
  const [answers, setAnswers] = useState({ ...detail.invitation.answers });
  const [base, setBase] = useState(detail.invitation.version_no);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const dirty =
    JSON.stringify(answers) !== JSON.stringify(detail.invitation.answers);
  useUnsavedWarning(dirty);
  const expired = Boolean(
    detail.collection.deadline_at &&
      Date.parse(detail.collection.deadline_at) <= Date.now(),
  );
  const readonly =
    detail.invitation.state !== "DRAFT" ||
    !detail.invitation.available ||
    !detail.context.writable ||
    expired;
  async function save(submit: boolean) {
    if (
      submit &&
      !window.confirm(
        t(
          "Nộp phản hồi sẽ khóa nội dung, không thể chỉnh sửa. Tiếp tục?",
          "Submitting makes this response immutable. Continue?",
        ),
      )
    )
      return;
    setBusy(true);
    setError("");
    setSaved(false);
    try {
      const result = await api.respond({
        invitationId: detail.invitation.invitation_id,
        answers,
        expectedVersionNo: base,
        submit,
      });
      if (result.success) {
        setBase(result.data.version_no);
        setAnswers({ ...result.data.answers });
        setSaved(true);
      } else {
        setError(result.error.code);
      }
      await onRefresh();
    } catch {
      setError("COMMAND_FAILED");
    } finally {
      setBusy(false);
    }
  }
  return (
    <section aria-label={t("Phản hồi của tôi", "My response")}>
      <h2>{t("Phiếu nhận xét cá nhân", "Individual feedback")}</h2>
      <FeedbackContext detail={detail} />
      <p>
        {detail.invitation.evaluator_name} ·{" "}
        {detail.invitation.state === "SUBMITTED"
          ? t("Đã nộp — không thể sửa", "Submitted — immutable")
          : t("Bản nháp", "Draft")}
      </p>
      {readonly && (
        <p role="status">
          {t(
            "Phản hồi hiện chỉ cho phép đọc.",
            "This response is currently read-only.",
          )}
        </p>
      )}
      {error && (
        <p className="feedback-error" role="alert">
          {errorText(error, t)}
        </p>
      )}
      {saved && (
        <p role="status">{t("Đã lưu thành công.", "Saved successfully.")}</p>
      )}
      {dirty && (
        <p role="status">
          {t("Có nội dung chưa lưu.", "You have unsaved changes.")}
        </p>
      )}
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void save(true);
        }}
      >
        <fieldset disabled={busy}>
          <legend>{t("Nhận xét", "Comments")}</legend>
          {detail.template.questions.map((q) => (
            <label
              className="feedback-field"
              key={q.key}
              htmlFor={`answer-${q.key}`}
            >
              <span>
                {q.label}{" "}
                {q.required
                  ? t("(Bắt buộc)", "(Required)")
                  : t("(Không bắt buộc)", "(Optional)")}
              </span>
              <textarea
                id={`answer-${q.key}`}
                value={answers[q.key] ?? ""}
                maxLength={10000}
                readOnly={readonly}
                required={q.required}
                rows={4}
                onChange={(e) => {
                  setSaved(false);
                  setAnswers({ ...answers, [q.key]: e.target.value });
                }}
              />
            </label>
          ))}
          <div className="feedback-actions">
            <Button
              type="button"
              pending={busy}
              disabled={readonly}
              onClick={() => void save(false)}
            >
              {t("Lưu nháp", "Save draft")}
            </Button>
            <Button
              type="submit"
              variant="primary"
              pending={busy}
              disabled={readonly}
            >
              {t("Nộp phản hồi", "Submit response")}
            </Button>
          </div>
        </fieldset>
      </form>
      <Button
        type="button"
        disabled={busy}
        onClick={() => {
          if (
            window.confirm(
              t(
                "Tải bản mới sẽ thay nội dung chưa lưu. Tiếp tục?",
                "Loading the latest version replaces unsaved text. Continue?",
              ),
            )
          ) {
            void (async () => {
              setBusy(true);
              try {
                const result = await api.invitation(
                  detail.invitation.invitation_id,
                );
                if (result.success) {
                  setAnswers({ ...result.data.invitation.answers });
                  setBase(result.data.invitation.version_no);
                  setError("");
                  setSaved(false);
                  await onRefresh();
                } else setError(result.error.code);
              } catch {
                setError("COMMAND_FAILED");
              } finally {
                setBusy(false);
              }
            })();
          }
        }}
      >
        {t("Dùng bản mới nhất", "Use latest version")}
      </Button>
    </section>
  );
}
function HrCollection({
  detail,
  api,
  onRefresh,
}: {
  detail: HrDetail;
  api: FeedbackApi;
  onRefresh: () => Promise<void>;
}) {
  const t = useFeedbackText();
  const [title, setTitle] = useState(
    detail.consolidation?.title ??
      t("Báo cáo nhận xét phỏng vấn", "Consolidated interview feedback"),
  );
  const [summary, setSummary] = useState(
    detail.consolidation?.overall_summary ?? "",
  );
  const [base, setBase] = useState(detail.consolidation?.version_no ?? 0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const report = detail.consolidation;
  const approved = report?.state === "APPROVED";
  const complete =
    detail.blockers.length === 0 &&
    detail.context.writable &&
    detail.invitations.length > 0 &&
    detail.invitations.every((i) => i.available && i.state === "SUBMITTED");
  async function command<T>(
    action: () => Promise<Result<T>>,
    after?: (data: T) => void,
  ) {
    setBusy(true);
    setError("");
    setSaved(false);
    try {
      const result = await action();
      if (result.success) {
        after?.(result.data);
        setSaved(true);
      } else setError(result.error.code);
      await onRefresh();
    } catch {
      setError("COMMAND_FAILED");
    } finally {
      setBusy(false);
    }
  }
  function save(approve: boolean) {
    void command(
      () =>
        api.consolidate({
          collectionId: detail.collection.collection_id,
          title,
          overallSummary: summary,
          expectedVersionNo: base,
          approve,
        }),
      (data) => setBase(data.version_no),
    );
  }
  const dirty = report
    ? title !== report.title || summary !== report.overall_summary
    : summary !== "";
  useUnsavedWarning(dirty);
  return (
    <section>
      <h2>{t("Theo dõi và tổng hợp", "Tracking and consolidation")}</h2>
      <FeedbackContext detail={detail} />
      <p>
        {t("Đã nộp", "Submitted")}:{" "}
        {
          detail.invitations.filter(
            (i) => i.state === "SUBMITTED" && i.available,
          ).length
        }
        /{detail.invitations.length}
      </p>
      <p className="feedback-notice">
        {t(
          "Đang chờ — chưa cấu hình gửi thư. Không có email nào được gửi.",
          "Queued — delivery not configured. No email has been sent.",
        )}
      </p>
      <div className="feedback-table-scroll">
        <table>
          <caption>
            {t(
              "Tất cả người đánh giá đã chọn",
              "All originally selected evaluators",
            )}
          </caption>
          <thead>
            <tr>
              <th>{t("Người đánh giá", "Evaluator")}</th>
              <th>{t("Trạng thái", "Status")}</th>
              <th>{t("Thao tác", "Actions")}</th>
            </tr>
          </thead>
          <tbody>
            {detail.invitations.map((i) => (
              <tr key={i.invitation_id}>
                <td data-label={t("Người đánh giá", "Evaluator")}>
                  {i.evaluator_name}
                </td>
                <td data-label={t("Trạng thái", "Status")}>
                  {!i.available
                    ? t("Không còn đủ điều kiện", "Unavailable")
                    : i.state === "SUBMITTED"
                      ? t("Đã nộp", "Submitted")
                      : i.state === "REVOKED"
                        ? t("Đã thu hồi", "Revoked")
                        : t("Chưa nộp", "Not submitted")}
                </td>
                <td data-label={t("Thao tác", "Actions")}>
                  <a href={`/interview-feedback/${i.invitation_id}`}>
                    {t(
                      "Liên kết cho người nhận (cần đăng nhập)",
                      "Recipient link (sign-in required)",
                    )}
                  </a>
                  {i.state === "SUBMITTED" && (
                    <details>
                      <summary>{t("Xem nhận xét", "View response")}</summary>
                      {detail.template.questions.map((q) => (
                        <div key={q.key}>
                          <h4>{q.label}</h4>
                          <p className="feedback-plain-text">
                            {i.answers[q.key] === undefined
                              ? t(
                                  "Không cung cấp câu trả lời",
                                  "No answer supplied",
                                )
                              : i.answers[q.key] === ""
                                ? t("Câu trả lời để trống", "Answer left empty")
                                : i.answers[q.key]}
                          </p>
                        </div>
                      ))}
                    </details>
                  )}
                  {i.state === "DRAFT" && (
                    <Button
                      disabled={busy}
                      variant="danger"
                      onClick={() => {
                        if (
                          window.confirm(
                            t(
                              "Thu hồi sẽ chặn hoàn tất báo cáo; không thể bỏ qua người này. Tiếp tục?",
                              "Revoking blocks consolidation; this evaluator cannot be waived. Continue?",
                            ),
                          )
                        )
                          void command(() =>
                            api.revoke({
                              invitationId: i.invitation_id,
                              expectedVersionNo: i.version_no,
                            }),
                          );
                      }}
                    >
                      {t("Thu hồi", "Revoke")}
                    </Button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {!complete && !approved && (
        <div role="status" className="feedback-notice">
          <p>
            {t(
              "Chưa thể tổng hợp hoặc duyệt.",
              "Consolidation or approval is blocked.",
            )}
          </p>
          {!detail.context.writable && (
            <p>
              {t(
                "Vòng phỏng vấn không còn cho phép ghi.",
                "Interview context no longer allows changes.",
              )}
            </p>
          )}
          <ul>
            {detail.blockers.map((b) => (
              <li key={b.invitation_id}>
                {b.evaluator_name}:{" "}
                {b.reason === "INVITATION_REVOKED"
                  ? t("Đã thu hồi lời mời", "Invitation revoked")
                  : b.reason === "EVALUATOR_UNAVAILABLE"
                    ? t(
                        "Người đánh giá không còn đủ điều kiện",
                        "Evaluator unavailable",
                      )
                    : t("Chưa nộp phản hồi", "Response not submitted")}
              </li>
            ))}
          </ul>
        </div>
      )}
      {error && (
        <p role="alert" className="feedback-error">
          {errorText(error, t)}
        </p>
      )}
      {saved && (
        <p role="status">{t("Đã lưu thành công.", "Saved successfully.")}</p>
      )}
      <div className="feedback-no-print">
        {dirty && (
          <p role="status">
            {t("Có nội dung chưa lưu.", "You have unsaved changes.")}
          </p>
        )}
        <h3>{t("Báo cáo tổng hợp", "Consolidated report")}</h3>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            save(false);
          }}
        >
          <fieldset disabled={busy || approved}>
            <legend>
              {t("Tiêu đề và nhận xét chung", "Title and overall summary")}
            </legend>
            <label className="feedback-field">
              {t("Tiêu đề báo cáo", "Report title")}
              <input
                value={title}
                maxLength={200}
                required
                onChange={(e) => {
                  setTitle(e.target.value);
                  setSaved(false);
                }}
              />
            </label>
            <label className="feedback-field">
              {t("Nhận xét chung", "Overall summary")}
              <textarea
                rows={5}
                value={summary}
                maxLength={20000}
                onChange={(e) => {
                  setSummary(e.target.value);
                  setSaved(false);
                }}
              />
            </label>
            <div className="feedback-actions">
              <Button type="submit" disabled={!complete} pending={busy}>
                {report
                  ? t("Lưu bản nháp", "Save report draft")
                  : t("Tạo bản nháp tổng hợp", "Create consolidated draft")}
              </Button>
              <Button
                type="button"
                variant="primary"
                disabled={!complete || !report || dirty}
                onClick={() => {
                  if (
                    window.confirm(
                      t(
                        "Duyệt báo cáo sẽ khóa vĩnh viễn nội dung. Tiếp tục?",
                        "Approval makes this report immutable. Continue?",
                      ),
                    )
                  )
                    save(true);
                }}
              >
                {t("Duyệt báo cáo", "Approve report")}
              </Button>
            </div>
          </fieldset>
        </form>
        <Button
          disabled={busy}
          onClick={() => {
            if (
              window.confirm(
                t(
                  "Tải bản mới sẽ thay tiêu đề và nhận xét chưa lưu. Tiếp tục?",
                  "Loading the latest version replaces unsaved title and summary. Continue?",
                ),
              )
            ) {
              void (async () => {
                setBusy(true);
                try {
                  const result = await api.collection(
                    detail.collection.collection_id,
                  );
                  if (result.success && result.data.mode === "HR") {
                    const latest = result.data.consolidation;
                    setTitle(
                      latest?.title ??
                        t(
                          "Báo cáo nhận xét phỏng vấn",
                          "Consolidated interview feedback",
                        ),
                    );
                    setSummary(latest?.overall_summary ?? "");
                    setBase(latest?.version_no ?? 0);
                    setError("");
                    await onRefresh();
                  } else
                    setError(result.success ? "FORBIDDEN" : result.error.code);
                } catch {
                  setError("COMMAND_FAILED");
                } finally {
                  setBusy(false);
                }
              })();
            }
          }}
        >
          {t("Dùng báo cáo mới nhất", "Use latest report")}
        </Button>
        {report && (
          <Button disabled={dirty || busy} onClick={() => window.print()}>
            {t("In / lưu PDF bằng trình duyệt", "Print / save PDF in browser")}
          </Button>
        )}
        <p>
          {t(
            "Bản in tiện dụng tại máy; chưa phải mẫu Word/PDF chính thức.",
            "Local browser printing; not the official Word/PDF template.",
          )}
        </p>
      </div>
      {report && <ConsolidatedPrint report={report} />}
    </section>
  );
}
export function ConsolidatedPrint({ report }: { report: Consolidation }) {
  const t = useFeedbackText();
  const s = report.snapshot;
  return (
    <article className="feedback-print-report">
      <h2>{report.title}</h2>
      <p>
        {report.state === "APPROVED"
          ? t("Đã duyệt", "Approved")
          : t("Bản nháp", "Draft")}{" "}
        · {t("Phiên bản", "Version")} {report.version_no}
      </p>
      <p>
        <strong>{s.context.candidate_name}</strong> · {s.context.position_name}{" "}
        · {s.context.unit_name} · {t("Vòng", "Round")} {s.context.round_no}
      </p>
      <p>
        {s.context.start_at
          ? new Date(s.context.start_at).toLocaleString(t("vi-VN", "en-GB"))
          : t("Chưa xếp lịch", "Not scheduled")}
      </p>
      <p>
        {s.template.name} · {t("Phiên bản câu hỏi", "Questionnaire version")}{" "}
        {s.template.version_no}
      </p>
      <h3>{t("Nhận xét chung", "Overall summary")}</h3>
      <p className="feedback-plain-text">
        {report.overall_summary ||
          t("Không có nhận xét chung.", "No overall summary.")}
      </p>
      {s.questions.map((q) => (
        <section key={q.key}>
          <h3>{q.label}</h3>
          {q.answers.map((a) => (
            <div key={a.invitation_id}>
              <h4>{a.evaluator_name}</h4>
              <p className="feedback-plain-text">
                {a.answer === null
                  ? t("Không cung cấp câu trả lời", "No answer supplied")
                  : a.answer === ""
                    ? t("Câu trả lời để trống", "Answer left empty")
                    : a.answer}
              </p>
            </div>
          ))}
        </section>
      ))}
      <h3>{t("Thông tin phản hồi đã chốt", "Pinned response attribution")}</h3>
      <ul>
        {s.evaluators.map((e) => (
          <li key={e.invitation_id}>
            {e.evaluator_name} · {t("Phiên bản", "Version")}{" "}
            {e.answer_version_no} ·{" "}
            {new Date(e.submitted_at).toLocaleString(t("vi-VN", "en-GB"))}
          </li>
        ))}
      </ul>
    </article>
  );
}
