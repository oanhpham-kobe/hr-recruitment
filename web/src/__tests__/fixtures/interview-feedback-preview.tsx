import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  errorText,
  useFeedbackText,
} from "@/components/interview-feedback/FeedbackDetail";
import { InterviewFeedbackView } from "@/components/interview-feedback/InterviewFeedbackView";
import { AppShell } from "@/components/shell/AppShell";
import {
  type Detail,
  EMPTY_WORKSPACE,
  type Workspace,
} from "@/lib/interview-feedback/model";
import {
  PREVIEW_PEOPLE,
  type PreviewPersona,
  previewApi,
  resetPreview,
} from "./interview-feedback-preview-state";
import "@/app/globals.css";
import "@/styles/interview-feedback.css";

const PERSONA_KEY = "eiu-synthetic-feedback-persona-v1";
function Preview() {
  const t = useFeedbackText();
  const [persona, setPersona] = useState<PreviewPersona>(() => {
    const saved = localStorage.getItem(PERSONA_KEY);
    return saved === "evaluator-one" || saved === "evaluator-two"
      ? saved
      : "hr";
  });
  const path = location.pathname;
  const [loaded, setLoaded] = useState<{
    data: Workspace;
    detail?: Detail;
  } | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let active = true;
    setLoaded(null);
    setError("");
    const api = previewApi(persona);
    void (async () => {
      const workspace = await api.workspace();
      if (!active) return;
      if (!workspace.success) {
        setError(workspace.error.code);
        return;
      }
      const match = path.match(/^\/interview-feedback\/([a-f0-9-]+)$/i);
      if (match) {
        const result = await api.invitation(match[1]);
        if (!active) return;
        if (!result.success) {
          setError(result.error.code);
          return;
        }
        setLoaded({ data: workspace.data, detail: result.data });
      } else setLoaded({ data: workspace.data });
    })();
    return () => {
      active = false;
    };
  }, [persona]);
  function navigate(next: string) {
    location.assign(next);
  }
  return (
    <div>
      <aside
        className="feedback-preview-banner"
        aria-label={t("Bản dùng thử dữ liệu mẫu", "Synthetic preview")}
      >
        <strong>
          {t(
            "DỮ LIỆU MẪU — Không gửi email. Không kết nối tài khoản thật.",
            "SYNTHETIC DATA — No email sent. No real accounts connected.",
          )}
        </strong>
        <p>
          {t(
            "Thay vai để thử quy trình. Dữ liệu mẫu chỉ được lưu trong trình duyệt này.",
            "Switch personas to try the workflow. Trial data is stored only in this browser.",
          )}
        </p>
        <label>
          {t("Vai dùng thử", "Trial persona")}
          <select
            value={persona}
            onChange={(e) => {
              if (
                window.confirm(
                  t(
                    "Đổi vai sẽ bỏ nội dung chưa lưu. Tiếp tục?",
                    "Switching personas discards unsaved text. Continue?",
                  ),
                )
              ) {
                const next = e.target.value as PreviewPersona;
                localStorage.setItem(PERSONA_KEY, next);
                setPersona(next);
                navigate("/interview-feedback");
              }
            }}
          >
            {PREVIEW_PEOPLE.map((p) => (
              <option value={p.id} key={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </label>
        <button
          type="button"
          onClick={() => {
            if (
              window.confirm(
                t(
                  "Xóa toàn bộ dữ liệu dùng thử trong trình duyệt?",
                  "Reset all synthetic trial data in this browser?",
                ),
              )
            ) {
              resetPreview();
              setPersona("hr");
              localStorage.setItem(PERSONA_KEY, "hr");
              navigate("/interview-feedback");
            }
          }}
        >
          {t("Đặt lại dữ liệu mẫu", "Reset trial data")}
        </button>
      </aside>
      {error ? (
        <div className="feedback-page">
          <p role="alert">{errorText(error, t)}</p>
          <button type="button" onClick={() => navigate("/interview-feedback")}>
            {t("Về danh sách", "Back to workspace")}
          </button>
        </div>
      ) : loaded ? (
        <InterviewFeedbackView
          key={`${persona}-${path}`}
          initialData={loaded.data ?? EMPTY_WORKSPACE}
          initialDetail={loaded.detail}
          api={previewApi(persona)}
        />
      ) : (
        <p role="status">{t("Đang tải…", "Loading…")}</p>
      )}
    </div>
  );
}
const root = document.getElementById("root");
if (root)
  createRoot(root).render(
    <AppShell
      currentPath="/interview-feedback"
      navItems={[
        {
          href: "/interview-feedback",
          labelVi: "Nhận xét phỏng vấn",
          labelEn: "Interview feedback",
        },
      ]}
    >
      <Preview />
    </AppShell>,
  );
