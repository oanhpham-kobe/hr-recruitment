"use client";

import { useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { PageContext } from "@/components/ui/PageContext";
import {
  type Detail,
  type FeedbackApi,
  type Question,
  type Template,
  TRIAL_QUESTIONS,
  type Workspace,
} from "@/lib/interview-feedback/model";
import { errorText, FeedbackDetail, useFeedbackText } from "./FeedbackDetail";
export function InterviewFeedbackView({
  initialData,
  initialDetail = null,
  api,
}: {
  initialData: Workspace;
  initialDetail?: Detail | null;
  api: FeedbackApi;
}) {
  const t = useFeedbackText();
  const [data, setData] = useState(initialData);
  const [templatesById, setTemplatesById] = useState<Record<string, Template>>(
    () =>
      Object.fromEntries(
        (initialData.can_manage ? initialData.templates : []).map(
          (template) => [template.template_id, template],
        ),
      ),
  );
  const templates = Object.values(templatesById);
  const [detail, setDetail] = useState(initialDetail);
  const [offset, setOffset] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [interviewId, setInterviewId] = useState("");
  const [templateId, setTemplateId] = useState(
    initialData.templates[0]?.template_id ?? "",
  );
  const [selected, setSelected] = useState<string[]>([]);
  const [deadline, setDeadline] = useState("");
  const [editor, setEditor] = useState(false);
  const [templateName, setTemplateName] = useState(
    "Phiếu nhận xét phỏng vấn / Interview feedback",
  );
  const [questions, setQuestions] = useState<Question[]>(
    TRIAL_QUESTIONS.map((q) => ({ ...q })),
  );
  const [previous, setPrevious] = useState<string | null>(null);
  const createKey = useRef<string | null>(null);
  const publishKey = useRef<string | null>(null);
  const selectedInterview = data.interviews.find(
    (i) => i.interview_id === interviewId,
  );
  const selectedTemplate = templatesById[templateId];
  const validSelection = Boolean(
    selectedInterview &&
      !selectedInterview.collection_id &&
      selectedTemplate &&
      selected.length > 0 &&
      selected.every((id) =>
        selectedInterview.participants.some((p) => p.participant_id === id),
      ),
  );
  function reportError(code: string) {
    setError(code);
    if (["FORBIDDEN", "UNAUTHENTICATED"].includes(code)) {
      setTemplatesById({});
      setTemplateId("");
      setInterviewId("");
      setSelected([]);
      setEditor(false);
      setData((current) => ({
        ...current,
        can_manage: false,
        templates: [],
        interviews: [],
        collections: [],
      }));
      createKey.current = null;
    }
  }
  async function refreshWorkspace(nextOffset = offset) {
    const result = await api.workspace(nextOffset);
    if (result.success) {
      setData(result.data);
      if (result.data.can_manage) {
        setTemplatesById((current) => ({
          ...current,
          ...Object.fromEntries(
            result.data.templates.map((template) => [
              template.template_id,
              template,
            ]),
          ),
        }));
        setTemplateId(
          (current) => current || result.data.templates[0]?.template_id || "",
        );
      } else {
        setTemplatesById({});
        setTemplateId("");
        setEditor(false);
      }
      if (nextOffset !== offset) {
        setInterviewId("");
        setSelected([]);
        createKey.current = null;
      } else {
        const nextInterview = result.data.interviews.find(
          (i) => i.interview_id === interviewId,
        );
        if (!nextInterview || nextInterview.collection_id) {
          setInterviewId("");
          setSelected([]);
          createKey.current = null;
        } else
          setSelected((values) =>
            values.filter((id) =>
              nextInterview.participants.some((p) => p.participant_id === id),
            ),
          );
      }
      setOffset(nextOffset);
      return true;
    }
    reportError(result.error.code);
    return false;
  }
  async function refreshDetail() {
    if (!detail) return;
    const result =
      detail.mode === "OWN"
        ? await api.invitation(detail.invitation.invitation_id)
        : await api.collection(detail.collection.collection_id);
    if (result.success) setDetail(result.data);
    else {
      reportError(result.error.code);
      if (
        ["FORBIDDEN", "NOT_FOUND", "UNAUTHENTICATED"].includes(
          result.error.code,
        )
      )
        setDetail(null);
    }
    await refreshWorkspace();
  }
  async function openCollection(id: string) {
    setBusy(true);
    setError("");
    try {
      const result = await api.collection(id);
      if (result.success) setDetail(result.data);
      else reportError(result.error.code);
    } catch {
      setError("COMMAND_FAILED");
    } finally {
      setBusy(false);
    }
  }
  async function create() {
    if (!selectedInterview || !validSelection) {
      setError("VALIDATION_ERROR");
      return;
    }
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const parsed = deadline ? new Date(deadline) : null;
      if (parsed && !Number.isFinite(parsed.getTime())) {
        setError("VALIDATION_ERROR");
        return;
      }
      createKey.current ??= crypto.randomUUID();
      const result = await api.create({
        interviewId,
        templateId,
        participantIds: selected,
        deadlineAt: parsed?.toISOString() ?? null,
        idempotencyKey: createKey.current,
      });
      if (result.success) {
        createKey.current = null;
        setNotice(
          t(
            "Bộ thu thập đã sẵn sàng. Kiểm tra phiên bản và hạn phản hồi bên dưới.",
            "Collection ready. Check its pinned template and deadline below.",
          ),
        );
        await refreshWorkspace();
        await openCollection(result.data.collection_id);
      } else reportError(result.error.code);
    } catch {
      setError("COMMAND_FAILED");
    } finally {
      setBusy(false);
    }
  }
  async function publish() {
    setBusy(true);
    setError("");
    try {
      publishKey.current ??= crypto.randomUUID();
      const result = await api.publish({
        name: templateName,
        questions,
        previousTemplateId: previous,
        idempotencyKey: publishKey.current,
      });
      if (result.success) {
        publishKey.current = null;
        setTemplatesById((current) => ({
          ...current,
          [result.data.template_id]: result.data,
        }));
        setTemplateId(result.data.template_id);
        setEditor(false);
        setNotice(
          t(
            "Đã xuất bản phiên bản mới. Các bộ thu thập cũ không thay đổi.",
            "New version published. Existing collections are unchanged.",
          ),
        );
        await refreshWorkspace();
      } else reportError(result.error.code);
    } catch {
      setError("COMMAND_FAILED");
    } finally {
      setBusy(false);
    }
  }
  function changeQuestion(index: number, patch: Partial<Question>) {
    publishKey.current = null;
    setQuestions(
      questions.map((q, i) => (i === index ? { ...q, ...patch } : q)),
    );
  }
  function moveQuestion(index: number, delta: number) {
    publishKey.current = null;
    const next = [...questions];
    [next[index], next[index + delta]] = [next[index + delta], next[index]];
    setQuestions(next);
  }
  return (
    <div className="feedback-page">
      <header className="feedback-no-print workflow-page-heading">
        <h1>{t("Nhận xét phỏng vấn", "Interview feedback")}</h1>
        <PageContext>
          {t(
            "Thu thập nhận xét và tổng hợp theo đúng vòng phỏng vấn.",
            "Collect and consolidate feedback for the exact interview round.",
          )}
        </PageContext>
      </header>
      {error && (
        <p role="alert" className="feedback-error feedback-no-print">
          {errorText(error, t)}
        </p>
      )}
      {notice && (
        <p role="status" className="feedback-no-print">
          {notice}
        </p>
      )}
      {detail ? (
        <>
          <div className="feedback-actions feedback-no-print">
            <Button
              disabled={busy}
              onClick={() => {
                if (
                  window.confirm(
                    t(
                      "Rời màn hình sẽ bỏ nội dung chưa lưu. Tiếp tục?",
                      "Leaving discards unsaved text. Continue?",
                    ),
                  )
                ) {
                  setDetail(null);
                  setError("");
                }
              }}
            >
              {t("Về danh sách", "Back to workspace")}
            </Button>
            <Button
              disabled={busy}
              onClick={() => {
                void refreshDetail().catch(() => setError("COMMAND_FAILED"));
              }}
            >
              {t("Kiểm tra cập nhật", "Check for updates")}
            </Button>
          </div>
          <FeedbackDetail detail={detail} api={api} onRefresh={refreshDetail} />
        </>
      ) : (
        <>
          {data.can_manage && (
            <section>
              <details className="workflow-filters feedback-setup">
                <summary>
                  {t("Giao phiếu nhận xét", "Assign feedback forms")}
                </summary>
                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    void create();
                  }}
                >
                  <fieldset disabled={busy} className="feedback-assignment">
                    <legend>
                      {t(
                        "Vòng phỏng vấn và người đánh giá",
                        "Interview round and evaluators",
                      )}
                    </legend>
                    <label className="feedback-field">
                      {t(
                        "Ứng viên và vòng phỏng vấn",
                        "Candidate and interview round",
                      )}
                      <select
                        required
                        value={interviewId}
                        onChange={(e) => {
                          setInterviewId(e.target.value);
                          setSelected([]);
                          createKey.current = null;
                        }}
                      >
                        <option value="">
                          {t("Chọn phỏng vấn", "Select an interview")}
                        </option>
                        {data.interviews.map((i) => (
                          <option
                            key={i.interview_id}
                            value={i.interview_id}
                            disabled={Boolean(i.collection_id)}
                          >
                            {i.candidate_name} · {i.position_name} ·{" "}
                            {t("Vòng", "Round")} {i.round_no}
                            {i.collection_id
                              ? t(
                                  " — Đã có bộ thu thập",
                                  " — Collection exists",
                                )
                              : ""}
                          </option>
                        ))}
                      </select>
                    </label>
                    {selectedInterview && (
                      <div className="feedback-context">
                        <strong>{selectedInterview.candidate_name}</strong>
                        <p>
                          {selectedInterview.position_name} ·{" "}
                          {selectedInterview.unit_name} · {t("Vòng", "Round")}{" "}
                          {selectedInterview.round_no}
                        </p>
                        <p>
                          {selectedInterview.start_at
                            ? new Date(
                                selectedInterview.start_at,
                              ).toLocaleString(t("vi-VN", "en-GB"))
                            : t("Chưa xếp lịch", "Not scheduled")}
                        </p>
                        <fieldset>
                          <legend>
                            {t(
                              "Chọn ít nhất một người đang được phân công",
                              "Select at least one currently assigned evaluator",
                            )}
                          </legend>
                          {selectedInterview.participants.map((p) => (
                            <label
                              className="feedback-check"
                              key={p.participant_id}
                            >
                              <input
                                type="checkbox"
                                checked={selected.includes(p.participant_id)}
                                onChange={(e) => {
                                  createKey.current = null;
                                  setSelected(
                                    e.target.checked
                                      ? [...selected, p.participant_id]
                                      : selected.filter(
                                          (id) => id !== p.participant_id,
                                        ),
                                  );
                                }}
                              />
                              {p.evaluator_name}
                            </label>
                          ))}
                        </fieldset>
                      </div>
                    )}
                    <label className="feedback-field">
                      {t("Mẫu câu hỏi đã xuất bản", "Published questionnaire")}
                      <select
                        required
                        value={templateId}
                        onChange={(e) => {
                          setTemplateId(e.target.value);
                          createKey.current = null;
                        }}
                      >
                        <option value="">
                          {t("Chọn mẫu", "Select a template")}
                        </option>
                        {templates.map((v) => (
                          <option key={v.template_id} value={v.template_id}>
                            {v.name} · v{v.version_no}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label className="feedback-field">
                      {t(
                        "Hạn phản hồi (không bắt buộc, giờ địa phương)",
                        "Deadline (optional, local time)",
                      )}
                      <input
                        type="datetime-local"
                        value={deadline}
                        onChange={(e) => {
                          setDeadline(e.target.value);
                          createKey.current = null;
                        }}
                      />
                    </label>
                    <p>
                      {t(
                        "Kiểm tra đúng ứng viên và vòng trước khi tạo. Thông báo chỉ được lưu chờ; chưa gửi email.",
                        "Confirm the candidate and round before creating. Notifications are queued only; no email is sent.",
                      )}
                    </p>
                    <Button
                      type="submit"
                      variant="primary"
                      disabled={!validSelection}
                      pending={busy}
                    >
                      {t(
                        "Giao phiếu cho người chấm",
                        "Assign forms to evaluators",
                      )}
                    </Button>
                  </fieldset>
                </form>
              </details>
              <details className="workflow-filters feedback-setup">
                <summary>
                  {t("Phiên bản câu hỏi", "Questionnaire versions")}
                </summary>
                <div className="feedback-actions">
                  <Button
                    disabled={busy}
                    onClick={() => {
                      setPrevious(null);
                      setQuestions(TRIAL_QUESTIONS.map((q) => ({ ...q })));
                      setTemplateName(
                        "Phiếu nhận xét phỏng vấn / Interview feedback",
                      );
                      publishKey.current = null;
                      setEditor(true);
                    }}
                  >
                    {t("Tạo mẫu mới", "New template")}
                  </Button>
                  {templates.map((v) => (
                    <Button
                      key={v.template_id}
                      disabled={busy}
                      onClick={() => {
                        setPrevious(v.template_id);
                        setTemplateName(v.name);
                        setQuestions(v.questions.map((q) => ({ ...q })));
                        publishKey.current = null;
                        setEditor(true);
                      }}
                    >
                      {t("Phiên bản mới từ", "New version from")} {v.name} · v
                      {v.version_no}
                    </Button>
                  ))}
                </div>
                {editor && (
                  <form
                    onSubmit={(e) => {
                      e.preventDefault();
                      void publish();
                    }}
                    className="feedback-panel"
                  >
                    <fieldset disabled={busy}>
                      <legend>
                        {t(
                          "Xuất bản phiên bản bất biến",
                          "Publish immutable version",
                        )}
                      </legend>
                      <label className="feedback-field">
                        {t("Tên mẫu", "Template name")}
                        <input
                          required
                          maxLength={200}
                          value={templateName}
                          onChange={(e) => {
                            setTemplateName(e.target.value);
                            publishKey.current = null;
                          }}
                        />
                      </label>
                      {questions.map((q, index) => (
                        <div key={q.key} className="feedback-question">
                          <label
                            className="feedback-field"
                            htmlFor={`question-${q.key}`}
                          >
                            {t("Câu hỏi", "Question")} {index + 1}
                            <textarea
                              id={`question-${q.key}`}
                              required
                              maxLength={1000}
                              value={q.label}
                              onChange={(e) =>
                                changeQuestion(index, { label: e.target.value })
                              }
                            />
                          </label>
                          <label className="feedback-check">
                            <input
                              type="checkbox"
                              checked={q.required}
                              onChange={(e) =>
                                changeQuestion(index, {
                                  required: e.target.checked,
                                })
                              }
                            />
                            {t("Bắt buộc", "Required")}
                          </label>
                          <div className="feedback-actions">
                            <Button
                              type="button"
                              disabled={index === 0}
                              onClick={() => moveQuestion(index, -1)}
                              aria-label={`${t("Lên", "Move up")} ${index + 1}`}
                            >
                              ↑
                            </Button>
                            <Button
                              type="button"
                              disabled={index === questions.length - 1}
                              onClick={() => moveQuestion(index, 1)}
                              aria-label={`${t("Xuống", "Move down")} ${index + 1}`}
                            >
                              ↓
                            </Button>
                            <Button
                              type="button"
                              disabled={questions.length === 1}
                              onClick={() => {
                                setQuestions(
                                  questions.filter((_, i) => i !== index),
                                );
                                publishKey.current = null;
                              }}
                            >
                              {t("Xóa câu hỏi", "Remove question")} {index + 1}
                            </Button>
                          </div>
                        </div>
                      ))}
                      <div className="feedback-actions">
                        <Button
                          type="button"
                          disabled={questions.length >= 30}
                          onClick={() => {
                            setQuestions([
                              ...questions,
                              {
                                key: `question_${crypto.randomUUID().replaceAll("-", "")}`,
                                label: "",
                                required: false,
                              },
                            ]);
                            publishKey.current = null;
                          }}
                        >
                          {t("Thêm câu hỏi", "Add question")}
                        </Button>
                        <Button type="submit" variant="primary" pending={busy}>
                          {t("Xuất bản phiên bản", "Publish version")}
                        </Button>
                        <Button type="button" onClick={() => setEditor(false)}>
                          {t("Hủy", "Cancel")}
                        </Button>
                      </div>
                    </fieldset>
                  </form>
                )}
              </details>
              <h2>{t("Theo dõi phiếu nhận xét", "Feedback tracking")}</h2>
              <div className="feedback-table-scroll">
                <table>
                  <caption>{t("Các đợt nhận xét", "Feedback rounds")}</caption>
                  <thead>
                    <tr>
                      <th>{t("Ứng viên / Vòng", "Candidate / Round")}</th>
                      <th>{t("Đã nộp", "Submitted")}</th>
                      <th>{t("Báo cáo", "Report")}</th>
                      <th>{t("Thao tác", "Actions")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.collections.map((c) => (
                      <tr key={c.collection_id}>
                        <td
                          data-label={t("Ứng viên / Vòng", "Candidate / Round")}
                        >
                          {c.context.candidate_name} · {t("Vòng", "Round")}{" "}
                          {c.context.round_no}
                          <br />
                          {c.context.position_name}
                        </td>
                        <td data-label={t("Đã nộp", "Submitted")}>
                          {c.submitted_count}/{c.selected_count}
                        </td>
                        <td data-label={t("Báo cáo", "Report")}>
                          {c.consolidation_state === "APPROVED"
                            ? t("Đã duyệt", "Approved")
                            : c.consolidation_state === "DRAFT"
                              ? t("Bản nháp", "Draft")
                              : t("Chưa tạo", "Not created")}
                        </td>
                        <td data-label={t("Thao tác", "Actions")}>
                          <Button
                            disabled={busy}
                            onClick={() => void openCollection(c.collection_id)}
                          >
                            {t("Xem đợt nhận xét", "Open feedback round")}
                          </Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {data.collections.length === 0 && (
                <p>
                  {t(
                    "Chưa giao phiếu nhận xét.",
                    "No feedback forms assigned yet.",
                  )}
                </p>
              )}
            </section>
          )}
          <section>
            <h2>{t("Phiếu nhận xét của tôi", "My feedback forms")}</h2>
            {data.invitations.length === 0 ? (
              <p>
                {t("Chưa có lời mời khả dụng.", "No available invitations.")}
              </p>
            ) : (
              <ul className="feedback-invitations">
                {data.invitations.map((i) => (
                  <li key={i.invitation_id}>
                    <a href={`/interview-feedback/${i.invitation_id}`}>
                      {i.context.candidate_name} · {t("Vòng", "Round")}{" "}
                      {i.context.round_no} ·{" "}
                      {i.state === "SUBMITTED"
                        ? t("Đã nộp", "Submitted")
                        : t("Mở phiếu nhận xét", "Open feedback form")}
                    </a>
                  </li>
                ))}
              </ul>
            )}
          </section>
          <nav
            className="feedback-actions"
            aria-label={t("Phân trang dữ liệu", "Workspace pagination")}
          >
            <Button
              disabled={busy || offset === 0}
              onClick={() => {
                void refreshWorkspace(Math.max(0, offset - 50)).catch(() =>
                  setError("COMMAND_FAILED"),
                );
              }}
            >
              {t("Trang trước", "Previous page")}
            </Button>
            <span>
              {t("Trang", "Page")} {offset / 50 + 1}
            </span>
            <Button
              disabled={
                busy ||
                Math.max(
                  data.templates.length,
                  data.interviews.length,
                  data.collections.length,
                  data.invitations.length,
                ) < 50
              }
              onClick={() => {
                void refreshWorkspace(offset + 50).catch(() =>
                  setError("COMMAND_FAILED"),
                );
              }}
            >
              {t("Trang tiếp", "Next page")}
            </Button>
            <Button
              disabled={busy}
              onClick={() => {
                void refreshWorkspace().catch(() => setError("COMMAND_FAILED"));
              }}
            >
              {t("Tải lại danh sách", "Refresh workspace")}
            </Button>
          </nav>
        </>
      )}
    </div>
  );
}
