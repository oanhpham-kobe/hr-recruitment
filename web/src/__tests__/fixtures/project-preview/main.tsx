import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  CandidateForm,
  type CandidateFormData,
} from "@/components/candidate/CandidateForm";
import { ApplicationInboxTable } from "@/components/inbox/ApplicationInboxTable";
import { InterviewPage } from "@/components/interview/InterviewPage";
import { InterviewFeedbackView } from "@/components/interview-feedback/InterviewFeedbackView";
import { MasterDataManagementPage } from "@/components/master-data/MasterDataManagementPage";
import { HrReportView } from "@/components/reports/HrReportView";
import { InterviewerReportView } from "@/components/reports/InterviewerReportView";
import { AppShell } from "@/components/shell/AppShell";
import { useAppLocale } from "@/components/shell/LocaleProvider";
import { NavigationIcon } from "@/components/shell/NavigationIcon";
import { Dialog } from "@/components/ui/Dialog";
import { UsersManagementPage } from "@/components/users/UsersManagementPage";
import type { Detail, Workspace } from "@/lib/interview-feedback/model";
import { previewApi } from "./feedback";
import { assignmentOptions, inboxGroups } from "./inbox-actions";
import { interviewData } from "./interview-actions";
import {
  bulkReportStatus,
  deleteReport,
  hrData,
  ownReportData,
  reportMutation,
  saveReport,
} from "./reports";
import {
  hasPermission,
  mutate,
  newSubmission,
  now,
  PEOPLE,
  type Persona,
  persistenceAvailable,
  read,
  reset,
  STORE_KEY,
  save,
} from "./store";
import "@/app/globals.css";
import "@/styles/interview.css";
import "@/styles/reports.css";
import "@/styles/users.css";
import "@/styles/master-data.css";
import "@/styles/interview-feedback.css";
import "@/styles/candidate-portal.css";
import "./preview.css";

const routes = [
  ["/guide", "Hướng dẫn thử nghiệm", "Test guide"],
  ["/candidate", "Cổng ứng viên", "Candidate portal"],
  ["/", "Phiếu ứng tuyển", "Applications"],
  ["/interviews", "Lịch phỏng vấn", "Interviews"],
  ["/reports", "Báo cáo phỏng vấn", "Interview reports"],
  ["/interview-feedback", "Nhận xét phỏng vấn", "Interview feedback"],
  ["/users", "Người dùng & phân quyền", "Users & permissions"],
  ["/master-data", "Danh mục", "Master data"],
  ["/services", "Email & tài liệu mẫu", "Simulated email & documents"],
];
const go = (path: string) => {
  location.hash = path;
};
function Feedback({ persona, path }: { persona: Persona; path: string }) {
  const [loaded, setLoaded] = useState<{
    workspace: Workspace;
    detail: Detail | null;
  } | null>(null);
  const [error, setError] = useState("");
  const api = React.useMemo(() => previewApi(persona), [persona]);
  useEffect(() => {
    let active = true;
    (async () => {
      const w = await api.workspace(0);
      const invitation = path.split("/")[2];
      const d = invitation ? await api.invitation(invitation) : null;
      if (!active) return;
      if (!w.success) {
        setError(w.error.code);
        return;
      }
      if (d && !d.success) {
        setError(d.error.code);
        return;
      }
      setLoaded({ workspace: w.data, detail: d?.success ? d.data : null });
    })();
    return () => {
      active = false;
    };
  }, [api, path]);
  return error ? (
    <p role="alert">{error}</p>
  ) : loaded ? (
    <InterviewFeedbackView
      initialData={loaded.workspace}
      initialDetail={loaded.detail}
      api={api}
    />
  ) : (
    <p role="status">Đang tải / Loading…</p>
  );
}
function CandidatePortal({ path }: { path: string }) {
  const s = read();
  const editing = path.split("/")[2];
  const sub = s.submissions.find((v) => v.submission_id === editing);
  const form = editing === "new" || Boolean(sub);
  if (form) {
    if (!s.candidateActive || (sub && sub.status_code !== "NEW"))
      return (
        <p role="alert">
          Phiếu chỉ được sửa khi NEW / Editing is available only while NEW.
        </p>
      );
    const sessionId = `project-preview-${editing}`;
    const submit = async (data: CandidateFormData) => {
      const result = mutate(
        "Ứng viên gửi phiếu / Candidate submission",
        (state) => {
          const existing =
            sub &&
            state.submissions.find(
              (v) => v.submission_id === sub.submission_id,
            );
          if (
            !state.candidateActive ||
            (existing && existing.status_code !== "NEW")
          )
            return {
              success: false,
              error: "Phiếu đã được HR mở / Submission is no longer editable.",
            };
          const target = existing ?? newSubmission(data.fullName);
          Object.assign(target, {
            full_name: data.fullName,
            phone: data.phone,
            date_of_birth: data.dateOfBirth,
            gender_code: data.gender,
            current_address: data.address,
            updated_at: now(),
          });
          target.education = data.education.map((e, i) => ({
            education_id: crypto.randomUUID(),
            sort_order: i + 1,
            period_text: e.periodText ?? null,
            qualification_id: e.qualificationId ?? null,
            qualification_name: null,
            major: e.major ?? null,
            institution: e.institution ?? null,
          }));
          target.documents = data.attachedDocs.map((d) => ({
            document_id: crypto.randomUUID(),
            logical_document_id: d.logicalDocumentId ?? crypto.randomUUID(),
            document_type_id:
              d.documentTypeId ?? s.catalogs.document_types[0].id,
            document_type_code: d.documentTypeCode,
            document_type_name: d.documentTypeName,
            original_filename: d.filename,
            mime_type: "application/pdf",
            file_size_bytes: d.fileSizeBytes,
            uploaded_at: now(),
          }));
          if (!existing) state.submissions.push(target);
          else target.version_no++;
          return { success: true };
        },
      );
      if (result.success) {
        sessionStorage.removeItem(`eiu_candidate_form_draft_${sessionId}`);
        go("/candidate");
      }
      return result;
    };
    return (
      <section className="preview-form-page">
        <h1>
          {sub
            ? "Cập nhật phiếu / Edit submission"
            : "Phiếu ứng tuyển mới / New submission"}
        </h1>
        <CandidateForm
          sessionId={sessionId}
          mode={sub ? "EDIT_SUBMISSION" : "NEW_SUBMISSION"}
          verifiedEmail="candidate@example.test"
          pinnedPrivacyVersion="synthetic-v1"
          expiresAt="2099-01-01T00:00:00Z"
          privacyNotice={{
            version: "synthetic-v1",
            contentVi:
              "Môi trường thử nghiệm cục bộ. Chỉ nhập dữ liệu giả. Thông tin lưu trên trình duyệt này; không gửi đến EIU.",
            contentEn:
              "Local trial. Use synthetic information only. Data stays in this browser and is not sent to EIU.",
          }}
          privacyAlreadyAcknowledged={Boolean(sub)}
          initialData={
            sub
              ? {
                  fullName: sub.full_name,
                  phone: sub.phone ?? "",
                  dateOfBirth: sub.date_of_birth ?? "",
                  gender: sub.gender_code === "MALE" ? "MALE" : "FEMALE",
                  address: sub.current_address ?? "",
                  education: sub.education.map((e) => ({
                    periodText: e.period_text,
                    qualificationId: e.qualification_id,
                    major: e.major,
                    institution: e.institution,
                    sortOrder: e.sort_order,
                  })),
                  attachedDocs: sub.documents.map((d) => ({
                    reservationId: d.document_id,
                    documentTypeCode: d.document_type_code ?? "OTHER",
                    documentTypeName: d.document_type_name ?? "Document",
                    filename: d.original_filename,
                    fileSizeBytes: d.file_size_bytes,
                    logicalDocumentId: d.logical_document_id,
                    documentTypeId: d.document_type_id,
                    persisted: true,
                    isCv: d.document_type_code === "CV_RESUME",
                  })),
                }
              : undefined
          }
          documentTypes={s.catalogs.document_types
            .filter((v) => v.isActive)
            .map((v) => ({ id: v.id, code: v.code, name: v.nameVi }))}
          qualificationLevels={s.catalogs.qualification_levels.map((v) => ({
            id: v.id,
            name: v.nameVi,
          }))}
          onSubmit={submit}
          onCancel={async () => go("/candidate")}
        />
      </section>
    );
  }
  return (
    <section className="preview-stack">
      <h1>Cổng ứng viên / Candidate portal</h1>
      <p>
        Đăng nhập OTP được mô phỏng bằng vai thử nghiệm. Không gửi mã hay email
        thật. / OTP sign-in is simulated by the trial persona.
      </p>
      <button
        type="button"
        disabled={!s.candidateActive}
        onClick={() => go("/candidate/new")}
      >
        Tạo phiếu mới / New submission
      </button>
      {[...s.submissions].reverse().map((v) => (
        <article className="preview-card" key={v.submission_id}>
          <h2>{v.full_name}</h2>
          <p>
            {v.status_code} · {new Date(v.submitted_at).toLocaleString()}
          </p>
          <p>
            {v.email} · {v.phone}
          </p>
          <button
            type="button"
            disabled={v.status_code !== "NEW" || !s.candidateActive}
            onClick={() => go(`/candidate/${v.submission_id}`)}
          >
            Sửa phiếu / Edit submission
          </button>
          <details>
            <summary>Tài liệu của tôi / My documents</summary>
            {v.documents.map((d) => (
              <p key={d.document_id}>
                {d.original_filename} · {d.file_size_bytes} bytes · metadata mô
                phỏng / simulated metadata
              </p>
            ))}
          </details>
        </article>
      ))}
    </section>
  );
}
function Guide() {
  const s = read();
  const { locale } = useAppLocale();
  const t = (vi: string, en: string) => (locale === "vi" ? vi : en);
  const checkpoints = [
    [
      "candidate",
      "Gửi một phiếu ứng tuyển / Submit an application",
      s.events.some((e) => e.action.startsWith("Ứng viên")),
    ],
    [
      "read",
      "HR mở NEW → READ / HR opens NEW → READ",
      s.events.some((e) => e.action.startsWith("Mở phiếu")),
    ],
    [
      "assign",
      "Gán vị trí và tạo vòng 1 / Assign a position and round 1",
      s.applications.length > 0,
    ],
    [
      "schedule",
      "Xếp lịch và thêm người phỏng vấn / Schedule and add interviewers",
      s.applications.some((a) =>
        a.rounds.some(
          (r) => r.startAt && r.participants.some((p) => p.isCurrent),
        ),
      ),
    ],
    [
      "legacy",
      "Người phỏng vấn lưu báo cáo / Interviewer saves interview report",
      s.reports.some((r) => r.active),
    ],
    [
      "collection",
      "HR giao phiếu nhận xét / HR assigns questionnaires",
      s.feedback.collections.length > 0,
    ],
    [
      "respond",
      "Người chấm gửi nhận xét / Evaluator submits feedback",
      s.feedback.invitations.some((i) => i.state === "SUBMITTED"),
    ],
    [
      "approve",
      "HR duyệt bản tổng hợp / HR approves consolidation",
      s.feedback.reports.some((r) => r.state === "APPROVED"),
    ],
  ] as const;
  return (
    <section className="preview-stack preview-guide">
      <h1>{t("Phòng thử nghiệm toàn bộ dự án", "Project test workspace")}</h1>
      <p>
        {t(
          "Thực hiện các bước theo thứ tự với dữ liệu mẫu. Nút Mở bước sẽ chọn vai và màn hình phù hợp. Thay đổi được giữ trong trình duyệt; bấm Bắt đầu lại khi muốn làm lại.",
          "Follow the steps in order with sample data. Open step selects the appropriate role and screen. Changes stay in this browser; use Reset all to start again.",
        )}
      </p>
      <ol className="preview-steps">
        {checkpoints.map(([key, label, done], index) => (
          <li key={key}>
            <span
              role="img"
              aria-label={
                done
                  ? t("Đã thực hiện trong bản thử", "Observed in trial data")
                  : t("Chưa thực hiện", "Not yet observed")
              }
            >
              {done ? "✓" : index + 1}
            </span>{" "}
            {label.split(" / ")[locale === "vi" ? 0 : 1] ?? label}{" "}
            <button
              type="button"
              aria-label={`${t("Mở bước", "Open step")}: ${label.split(" / ")[locale === "vi" ? 0 : 1] ?? label}`}
              onClick={() => {
                const target =
                  key === "candidate"
                    ? "/candidate"
                    : key === "read" || key === "assign"
                      ? "/"
                      : key === "schedule"
                        ? "/interviews"
                        : key === "legacy"
                          ? "/reports"
                          : "/interview-feedback";
                const nextRole: Persona =
                  key === "candidate"
                    ? "candidate"
                    : key === "legacy" || key === "respond"
                      ? "interviewerA"
                      : "hr";
                const next = read();
                if (next.persona !== nextRole) {
                  next.persona = nextRole;
                  save(next);
                  location.hash = target;
                  location.reload();
                } else go(target);
              }}
            >
              {t("Mở bước", "Open step")}
            </button>
          </li>
        ))}
      </ol>
      <p>
        {t(
          "Nếu màn hình chưa có dữ liệu, hãy hoàn tất bước trước rồi quay lại. Khi đến phần nhận xét, chuyển lần lượt giữa Tâm và Hà để điền phiếu của từng người.",
          "If a screen is empty, complete the previous step first. For feedback, switch between Tâm and Hà to fill each person's form.",
        )}
      </p>
      <p>
        {t(
          "Chuyển giữa sáu vai thử nghiệm để thao tác cùng một bộ dữ liệu. Tài khoản tạo trong danh bạ chưa liên kết Google. Root có thể cấp/thu hồi quyền HR; chuyển lại HR để kiểm tra tác động. Tạo vòng tiếp theo để xem quyền ở vòng hiện tại và lịch sử.",
          "Switch between the six supplied personas to exercise the same saved workflow. New directory accounts are not bound to Google. Root can grant or revoke HR permissions; switch to HR to inspect their effect. Create another round to inspect current and historical access.",
        )}
      </p>
      <h2>{t("Ghi chú thử nghiệm", "Test notes")}</h2>
      <textarea
        aria-label="Ghi chú thử nghiệm / Test notes"
        rows={5}
        defaultValue={s.notes}
        onBlur={(e) => {
          const next = read();
          next.notes = e.target.value;
          save(next);
        }}
      />
      <button
        type="button"
        onClick={() => {
          const state = read();
          const blob = new Blob(
            [
              "EIU — Ghi chú thử nghiệm / Trial notes\n\n" +
                checkpoints
                  .map(([, label, done]) => (done ? "[x] " : "[ ] ") + label)
                  .join("\n") +
                "\n\n" +
                state.notes +
                "\n\n" +
                state.events
                  .map((e) => `${e.at} · ${e.actor} · ${e.action}`)
                  .join("\n"),
            ],
            { type: "text/plain;charset=utf-8" },
          );
          const a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = "eiu-synthetic-test-notes.txt";
          a.click();
          setTimeout(() => URL.revokeObjectURL(a.href), 1000);
        }}
      >
        Xuất ghi chú / Export readable notes
      </button>
      <details>
        <summary>Nhật ký thao tác mô phỏng / Synthetic activity</summary>
        {s.events.map((e) => (
          <p key={e.id}>
            {e.at} · {e.actor} · {e.action}
          </p>
        ))}
      </details>
    </section>
  );
}
function Services() {
  const s = read();
  return (
    <section className="preview-stack">
      <h1>Email & tài liệu mô phỏng / Simulated services</h1>
      <p>
        OAuth, OTP, gửi email, quét virus, URL tài liệu riêng tư và xuất PDF
        chính thức chưa kết nối. Không gửi email thật. In trình duyệt chỉ là bản
        in thử nghiệm.
      </p>
      <h2>Hàng đợi cục bộ / Local email queue</h2>
      {!hasPermission(s, "emails.history_view") ? (
        <p>
          Bạn không có quyền xem lịch sử email / Email history access required.
        </p>
      ) : s.emails.length === 0 ? (
        <p>Chưa có email / No queued emails</p>
      ) : (
        s.emails
          .filter((e) => !e.deleted)
          .map((e) => (
            <article className="preview-card" key={e.id}>
              <h3>{e.subject}</h3>
              <p>SIMULATED — provider paused · {e.recipients.join(", ")}</p>
              <pre>{e.body}</pre>
              <button
                type="button"
                disabled={!hasPermission(s, "emails.history_delete")}
                onClick={() =>
                  mutate("Xóa email mô phỏng / Remove simulated email", (n) => {
                    const item = n.emails.find((v) => v.id === e.id);
                    if (item) item.deleted = true;
                  })
                }
              >
                Xóa khỏi bản thử / Remove locally
              </button>
            </article>
          ))
      )}
      <h2>Tài liệu / Documents</h2>
      {(hasPermission(s, "submissions.view") ? s.submissions : []).map((v) => (
        <details key={v.submission_id}>
          <summary>
            {v.full_name} · {v.documents.length} tài liệu
          </summary>
          {v.documents.map((d) => (
            <article key={d.document_id}>
              <h3>{d.original_filename}</h3>
              <p>
                {d.document_type_name} · {d.file_size_bytes} bytes
              </p>
              <p>
                Chỉ metadata tổng hợp; không lưu hoặc tải nội dung thật. /
                Synthetic metadata only; no real content is stored or retrieved.
              </p>
            </article>
          ))}
        </details>
      ))}
    </section>
  );
}
function Surface({ path }: { path: string }) {
  const s = read();
  const u = s.users.find((v) => v.appUserId === PEOPLE[s.persona].id);
  const identity = {
    roles:
      s.persona === "root"
        ? ["ROOT_ADMIN"]
        : u?.isHr
          ? ["HR"]
          : ["INTERVIEWER"],
    permissions: u?.permissions ?? [],
  };
  if (path === "/guide") return <Guide />;
  if (path.startsWith("/candidate"))
    return s.persona === "candidate" && s.candidateActive ? (
      <CandidatePortal path={path} />
    ) : (
      <p>
        Chọn vai Ứng viên đang hoạt động để thử cổng ứng viên / An active
        Candidate account is required.
      </p>
    );
  if (s.persona === "candidate")
    return (
      <p>Chức năng dành cho nhân sự nội bộ / Internal account required.</p>
    );
  if (!u?.isActive || !u.identityBound)
    return (
      <p role="alert">
        Tài khoản thử nghiệm chưa hoạt động hoặc chưa liên kết / Trial account
        is inactive or unbound.
      </p>
    );
  if (path === "/services") return <Services />;
  if (path.startsWith("/interview-feedback"))
    return <Feedback persona={s.persona} path={path} />;
  if (path === "/reports")
    return !hasPermission(s, "reports.view") ? (
      <InterviewerReportView
        initialData={ownReportData()}
        onSave={saveReport}
        onRefresh={async () => ownReportData()}
      />
    ) : (
      <HrReportView
        initialData={hrData()}
        onRefresh={async (filters) => hrData(filters)}
        onStatus={reportMutation}
        onVisibility={reportMutation}
        onNote={reportMutation}
        onSaveParticipantReport={(input) => saveReport(input, true)}
        onDeleteParticipantReport={deleteReport}
        onBulkStatus={bulkReportStatus}
      />
    );
  if (s.persona.startsWith("interviewer"))
    return <p>Chức năng dành cho HR / HR access required.</p>;
  if (path === "/interviews")
    return hasPermission(s, "interviews.view") ? (
      <InterviewPage initialData={interviewData()} />
    ) : (
      <p role="alert">
        Bạn không có quyền xem lịch phỏng vấn / Interview view access required.
      </p>
    );
  if (path === "/users")
    return [
      "users.directory_read",
      "users.directory_manage",
      "users.permissions_manage",
    ].some((permission) => hasPermission(s, permission)) ? (
      <UsersManagementPage
        identity={identity}
        initialUsers={s.users}
        initialDependencies={{ units: assignmentOptions().units }}
      />
    ) : (
      <p role="alert">
        Bạn không có quyền xem danh bạ / Directory access required.
      </p>
    );
  if (path === "/master-data")
    return hasPermission(s, "master_data.manage") ? (
      <MasterDataManagementPage
        identity={identity}
        initialItems={s.catalogs.organizational_units}
      />
    ) : (
      <p role="alert">
        Bạn không có quyền quản lý danh mục / Master data access required.
      </p>
    );
  return hasPermission(s, "submissions.view") ? (
    <ApplicationInboxTable groups={inboxGroups()} />
  ) : (
    <p role="alert">
      Bạn không có quyền xem phiếu ứng tuyển / Submission view access required.
    </p>
  );
}
function Controls() {
  const [open, setOpen] = useState(false);
  const s = read();
  const { locale } = useAppLocale();
  const t = (vi: string, en: string) => (locale === "vi" ? vi : en);
  return (
    <>
      <button
        type="button"
        className="preview-workspace-trigger"
        aria-label="Mở vai thử nghiệm / Open trial workspace"
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen(true)}
      >
        <NavigationIcon path="workspace" />
        <span>{t("Vai thử nghiệm", "Trial role")}</span>
      </button>
      <Dialog
        open={open}
        title={t("Không gian thử nghiệm", "Trial workspace")}
        onClose={() => setOpen(false)}
      >
        <aside
          className="preview-controls"
          aria-label="Synthetic preview controls"
        >
          <span className="preview-trial-label">
            {t("Dữ liệu mẫu", "Synthetic data")}
          </span>
          {!persistenceAvailable() && (
            <p role="alert">
              Trình duyệt không cho lưu dữ liệu. Thay đổi chỉ còn trong phiên
              này. / Storage unavailable; changes last only for this page
              session.
            </p>
          )}
          <label>
            {t("Vai thử nghiệm", "Trial role")}{" "}
            <select
              aria-label="Vai thử nghiệm / Trial role"
              value={s.persona}
              onChange={(e) => {
                const n = read();
                n.persona = e.target.value as Persona;
                save(n);
                location.reload();
              }}
            >
              {Object.entries(PEOPLE).map(([key, p]) => (
                <option key={key} value={key}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <button
            type="button"
            aria-label="Bắt đầu lại / Reset all"
            onClick={() => {
              if (
                !confirm(
                  "Xóa dữ liệu thử nghiệm và bắt đầu lại? / Reset synthetic workspace?",
                )
              )
                return;
              for (const key of Object.keys(sessionStorage))
                if (key.startsWith("eiu_candidate_form_draft_project-preview-"))
                  sessionStorage.removeItem(key);
              reset();
              location.hash = "/guide";
              location.reload();
            }}
          >
            {t("Bắt đầu lại", "Reset all")}
          </button>
          <button
            type="button"
            onClick={() => {
              setOpen(false);
              go("/guide");
            }}
          >
            {t("Hướng dẫn", "Guide")}
          </button>
          <small className="preview-simulation-note">
            {t(
              "Chỉ nhập dữ liệu mẫu. Không gửi email thật.",
              "Synthetic input only. No real emails are sent.",
            )}
          </small>
        </aside>
      </Dialog>
    </>
  );
}
function PreviewTitle({ path }: { path: string }) {
  const { locale } = useAppLocale();
  const route =
    routes.find(([href]) => href === path) ??
    routes.find(([href]) => path.startsWith(href) && href !== "/");
  return (
    <div className="workspace-context">
      <span>{locale === "vi" ? "Tuyển dụng" : "Recruitment"}</span>
      <span aria-hidden="true">/</span>
      <span>
        {route?.[locale === "vi" ? 1 : 2] ??
          (locale === "vi" ? "Phiếu ứng tuyển" : "Applications")}
      </span>
    </div>
  );
}
function App() {
  const [path, setPath] = useState(location.hash.slice(1) || "/guide");
  const [, update] = useState(0);
  useEffect(() => {
    const changed = () => update((n) => n + 1);
    const hash = () => setPath(location.hash.slice(1) || "/guide");
    const links = (e: MouseEvent) => {
      const a = (e.target as HTMLElement).closest("a");
      const href = a?.getAttribute("href");
      if (!href || href.startsWith("blob:") || href.startsWith("#")) return;
      if (href.startsWith("/")) {
        e.preventDefault();
        go(href);
      } else if (/^https?:/i.test(href)) {
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("project-preview-external"));
      }
    };
    window.addEventListener("hashchange", hash);
    window.addEventListener("project-preview-change", changed);
    document.addEventListener("click", links);
    return () => {
      window.removeEventListener("hashchange", hash);
      window.removeEventListener("project-preview-change", changed);
      document.removeEventListener("click", links);
    };
  }, []);
  const role = read().persona;
  const items = routes
    .filter(([p]) =>
      role === "candidate"
        ? ["/guide", "/candidate"].includes(p)
        : role.startsWith("interviewer")
          ? ["/guide", "/reports", "/interview-feedback"].includes(p)
          : p !== "/candidate",
    )
    .map(([href, labelVi, labelEn]) => ({ href, labelVi, labelEn }));
  return (
    <div id="app-root">
      <AppShell
        title={<PreviewTitle path={path} />}
        currentPath={path}
        navItems={items}
        workspaceControl={<Controls />}
        accountLabel={PEOPLE[role].name}
      >
        <Surface key={`${role}:${path}`} path={path} />
      </AppShell>
    </div>
  );
}
try {
  if (!localStorage.getItem(STORE_KEY)) save(read());
} catch {
  save(read());
}
const container = document.getElementById("root");
if (!container) throw new Error("The preview root element is missing.");
createRoot(container).render(<App />);
