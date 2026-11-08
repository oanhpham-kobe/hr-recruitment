"use client";

import { useCallback, useEffect, useState } from "react";
import {
  cancelFormSessionAction,
  loadCandidateEditDataAction,
  loadCandidateFormPrivacyNoticeAction,
  loadCandidatePortalData,
  refreshCandidatePrivacyNoticeAction,
  resumeFormSessionAction,
  resumeFormSessionByIdAction,
  startFormSessionAction,
  submitCandidateSubmissionAction,
  updateCandidateSubmissionAction,
} from "@/app/candidate/candidate-actions";
import {
  CandidateForm,
  type CandidateFormData,
} from "@/components/candidate/CandidateForm";
import type { QualificationLevelOption } from "@/components/candidate/EducationSection";
import {
  type CandidateSubmissionSummary,
  SubmissionsList,
} from "@/components/candidate/SubmissionsList";
import "@/styles/candidate-portal.css";

type PrivacyNotice = {
  version: string;
  contentVi: string;
  contentEn: string | null;
};

type SessionData = {
  candidate_form_session_id: string;
  mode_code: string;
  target_submission_id?: string | null;
  base_submission_version_no?: number | null;
  presented_privacy_notice_version: string;
  status_code: string;
  expires_at: string;
};

const SESSION_STORAGE_KEY = "eiu_candidate_form_session_id";
const MUTATION_STORAGE_KEY = "eiu_candidate_form_mutation_key";

export default function CandidatePortalPage() {
  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<
    "NEW_APPLICATION" | "MY_APPLICATIONS"
  >("NEW_APPLICATION");
  const [formMode, setFormMode] = useState<
    "NEW_SUBMISSION" | "EDIT_SUBMISSION"
  >("NEW_SUBMISSION");
  const [sessionId, setSessionId] = useState<string>("");
  const [sessionExpiresAt, setSessionExpiresAt] = useState<string>("");
  const [pinnedPrivacyVersion, setPinnedPrivacyVersion] = useState<string>("");
  const [privacyNotice, setPrivacyNotice] = useState<PrivacyNotice>({
    version: "",
    contentVi: "",
    contentEn: null,
  });
  const [privacyAlreadyAcknowledged, setPrivacyAlreadyAcknowledged] =
    useState<boolean>(false);
  const [mutationIdempotencyKey, setMutationIdempotencyKey] =
    useState<string>("");
  const [verifiedEmail, setVerifiedEmail] = useState<string>("");
  const [documentTypes, setDocumentTypes] = useState<
    Array<{ id: string; code: string; name: string }>
  >([]);
  const [qualificationLevels, setQualificationLevels] = useState<
    QualificationLevelOption[]
  >([]);
  const [submissions, setSubmissions] = useState<CandidateSubmissionSummary[]>(
    [],
  );
  const [editInitialData, setEditInitialData] = useState<
    Partial<CandidateFormData> | undefined
  >(undefined);
  const [notification, setNotification] = useState<{
    type: "success" | "error";
    message: string;
  } | null>(null);

  const rememberSession = useCallback((id: string): string => {
    if (typeof window === "undefined") return crypto.randomUUID();
    const previousId = window.sessionStorage.getItem(SESSION_STORAGE_KEY);
    const previousKey = window.sessionStorage.getItem(MUTATION_STORAGE_KEY);
    const key =
      previousId === id && previousKey ? previousKey : crypto.randomUUID();
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, id);
    window.sessionStorage.setItem(MUTATION_STORAGE_KEY, key);
    setMutationIdempotencyKey(key);
    return key;
  }, []);

  const forgetSession = useCallback((id?: string) => {
    if (typeof window !== "undefined") {
      const sessionIdToForget =
        id ?? window.sessionStorage.getItem(SESSION_STORAGE_KEY);
      if (sessionIdToForget) {
        window.sessionStorage.removeItem(
          `eiu_candidate_form_draft_${sessionIdToForget}`,
        );
      }
      window.sessionStorage.removeItem(SESSION_STORAGE_KEY);
      window.sessionStorage.removeItem(MUTATION_STORAGE_KEY);
    }
    setMutationIdempotencyKey("");
  }, []);

  const applySession = useCallback(
    (data: SessionData) => {
      const mode =
        data.mode_code === "EDIT_SUBMISSION"
          ? "EDIT_SUBMISSION"
          : "NEW_SUBMISSION";
      setSessionId(data.candidate_form_session_id);
      setSessionExpiresAt(data.expires_at);
      setPinnedPrivacyVersion(data.presented_privacy_notice_version);
      setFormMode(mode);
      rememberSession(data.candidate_form_session_id);
    },
    [rememberSession],
  );

  const loadPortalData = useCallback(async () => {
    setLoading(true);
    try {
      const res = await loadCandidatePortalData();
      if (!res.success) {
        setNotification({ type: "error", message: res.error });
        return;
      }

      setVerifiedEmail(res.data.verifiedEmail);
      setDocumentTypes(res.data.documentTypes);
      setQualificationLevels(res.data.qualificationLevels);
      setSubmissions(res.data.submissions);
      setPrivacyNotice(res.data.privacyNotice);

      let resumed = false;
      const storedSessionId =
        typeof window === "undefined"
          ? null
          : window.sessionStorage.getItem(SESSION_STORAGE_KEY);

      if (storedSessionId) {
        const resumedRes = await resumeFormSessionByIdAction(storedSessionId);
        if (resumedRes.success && resumedRes.data) {
          applySession(resumedRes.data as SessionData);
          if (resumedRes.data.mode_code === "EDIT_SUBMISSION") {
            const editRes = await loadCandidateEditDataAction(storedSessionId);
            if (editRes.success && editRes.data) {
              setEditInitialData({
                ...editRes.data.initialData,
                attachedDocs: editRes.data.initialData.documents,
              });
              setPrivacyAlreadyAcknowledged(
                editRes.data.privacyAlreadyAcknowledged,
              );
              setPinnedPrivacyVersion(editRes.data.pinnedPrivacyVersion);
              setSessionExpiresAt(editRes.data.expiresAt);
              setPrivacyNotice(editRes.data.privacyNotice);
              resumed = true;
            } else {
              forgetSession(storedSessionId);
            }
          } else {
            const noticeRes =
              await loadCandidateFormPrivacyNoticeAction(storedSessionId);
            if (noticeRes.success && noticeRes.data) {
              setPrivacyNotice(noticeRes.data);
            }
            setPrivacyAlreadyAcknowledged(false);
            setEditInitialData(undefined);
            resumed = true;
          }
          if (resumed) setActiveTab("NEW_APPLICATION");
        } else {
          forgetSession(storedSessionId);
        }
      }

      if (!resumed && res.data.submissions.length === 0) {
        const existing = await resumeFormSessionAction("NEW_SUBMISSION");
        const sessionRes = existing.success
          ? existing
          : await startFormSessionAction("NEW_SUBMISSION");
        if (sessionRes.success && sessionRes.data) {
          applySession(sessionRes.data as SessionData);
          setPrivacyAlreadyAcknowledged(false);
          setEditInitialData(undefined);
          setActiveTab("NEW_APPLICATION");
        } else {
          setNotification({
            type: "error",
            message: sessionRes.error || "Không thể bắt đầu phiên đăng ký",
          });
        }
      } else if (!resumed) {
        setActiveTab("MY_APPLICATIONS");
        setFormMode("NEW_SUBMISSION");
        setEditInitialData(undefined);
      }
    } catch (err) {
      setNotification({
        type: "error",
        message: err instanceof Error ? err.message : "Lỗi kết nối",
      });
    } finally {
      setLoading(false);
    }
  }, [applySession, forgetSession]);

  useEffect(() => {
    void loadPortalData();
  }, [loadPortalData]);

  const handleStartNewApplication = async () => {
    setLoading(true);
    try {
      if (sessionId && formMode === "EDIT_SUBMISSION") {
        await cancelFormSessionAction(sessionId);
        forgetSession(sessionId);
      }

      const existing = await resumeFormSessionAction("NEW_SUBMISSION");
      const sessionRes = existing.success
        ? existing
        : await startFormSessionAction("NEW_SUBMISSION");
      if (sessionRes.success && sessionRes.data) {
        applySession(sessionRes.data as SessionData);
        const noticeRes = await loadCandidateFormPrivacyNoticeAction(
          sessionRes.data.candidate_form_session_id,
        );
        if (noticeRes.success && noticeRes.data) {
          setPrivacyNotice(noticeRes.data);
        }
        setPrivacyAlreadyAcknowledged(false);
        setFormMode("NEW_SUBMISSION");
        setEditInitialData(undefined);
        setActiveTab("NEW_APPLICATION");
      } else {
        setNotification({
          type: "error",
          message: sessionRes.error || "Không thể bắt đầu phiên đăng ký",
        });
      }
    } finally {
      setLoading(false);
    }
  };

  const handleFormSubmit = async (
    data: CandidateFormData,
  ): Promise<{
    success: boolean;
    error?: string;
    privacyNotice?: PrivacyNotice;
  }> => {
    const idempotencyKey =
      mutationIdempotencyKey ||
      (typeof window === "undefined"
        ? crypto.randomUUID()
        : crypto.randomUUID());
    if (!mutationIdempotencyKey) {
      setMutationIdempotencyKey(idempotencyKey);
      if (typeof window !== "undefined") {
        window.sessionStorage.setItem(MUTATION_STORAGE_KEY, idempotencyKey);
      }
    }

    try {
      const input = {
        candidateFormSessionId: sessionId,
        fullName: data.fullName,
        phone: data.phone,
        dateOfBirth: data.dateOfBirth,
        gender: data.gender,
        address: data.address,
        education: data.education,
        privacyNoticeVersion: pinnedPrivacyVersion,
        idempotencyKey,
      };
      const res =
        formMode === "NEW_SUBMISSION"
          ? await submitCandidateSubmissionAction(input)
          : await updateCandidateSubmissionAction(input);

      if (!res.success) {
        if (res.privacyNotice) {
          setPinnedPrivacyVersion(res.privacyNotice.version);
          setPrivacyNotice(res.privacyNotice);
          setPrivacyAlreadyAcknowledged(false);
        } else if (res.code === "PRIVACY_NOTICE_CHANGED") {
          const refreshRes =
            await refreshCandidatePrivacyNoticeAction(sessionId);
          if (refreshRes.success && refreshRes.data) {
            setPinnedPrivacyVersion(refreshRes.data.pinnedPrivacyVersion);
            setSessionExpiresAt(refreshRes.data.expiresAt);
            setPrivacyNotice(refreshRes.data.privacyNotice);
            setPrivacyAlreadyAcknowledged(false);
            return {
              success: false,
              error:
                "Privacy notice updated. Review and acknowledge the current version before retrying.",
              privacyNotice: refreshRes.data.privacyNotice,
            };
          }
        }
        return {
          success: false,
          error: res.error,
          privacyNotice: res.privacyNotice,
        };
      }

      setNotification({
        type: "success",
        message:
          formMode === "NEW_SUBMISSION"
            ? "Nộp hồ sơ thành công! / Application submitted successfully."
            : "Cập nhật hồ sơ thành công! / Application updated successfully.",
      });
      forgetSession(sessionId);
      await loadPortalData();
      setActiveTab("MY_APPLICATIONS");
      setFormMode("NEW_SUBMISSION");
      setEditInitialData(undefined);
      return { success: true };
    } catch (err) {
      return {
        success: false,
        error: err instanceof Error ? err.message : "Submission failed",
      };
    }
  };

  const handleFormCancel = async (): Promise<void> => {
    if (sessionId) await cancelFormSessionAction(sessionId);
    forgetSession(sessionId);
    setSessionId("");
    setSessionExpiresAt("");
    setFormMode("NEW_SUBMISSION");
    setEditInitialData(undefined);
    setPrivacyAlreadyAcknowledged(false);
    if (submissions.length > 0) setActiveTab("MY_APPLICATIONS");
  };

  const handleEditSubmission = async (submissionId: string) => {
    const sub = submissions.find((s) => s.submissionId === submissionId);
    if (sub?.statusCode !== "NEW") return;

    setLoading(true);
    try {
      if (sessionId) {
        await cancelFormSessionAction(sessionId);
        forgetSession(sessionId);
      }
      const sessionRes = await startFormSessionAction(
        "EDIT_SUBMISSION",
        submissionId,
      );
      if (!sessionRes.success || !sessionRes.data) {
        setNotification({
          type: "error",
          message: sessionRes.error || "Không thể mở phiên chỉnh sửa hồ sơ",
        });
        return;
      }

      applySession(sessionRes.data as SessionData);
      const editRes = await loadCandidateEditDataAction(
        sessionRes.data.candidate_form_session_id,
      );
      if (!editRes.success) {
        await cancelFormSessionAction(
          sessionRes.data.candidate_form_session_id,
        );
        forgetSession(sessionRes.data.candidate_form_session_id);
        setNotification({ type: "error", message: editRes.error });
        return;
      }

      setEditInitialData({
        ...editRes.data.initialData,
        attachedDocs: editRes.data.initialData.documents,
      });
      setPrivacyAlreadyAcknowledged(editRes.data.privacyAlreadyAcknowledged);
      setPinnedPrivacyVersion(editRes.data.pinnedPrivacyVersion);
      setSessionExpiresAt(editRes.data.expiresAt);
      setPrivacyNotice(editRes.data.privacyNotice);
      setActiveTab("NEW_APPLICATION");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="portal-wrapper">
      <main className="portal-container" id="main-content">
        <header className="portal-header">
          <div className="portal-brand">
            <h1 className="portal-title">Cổng ứng viên / Candidate Portal</h1>
            <p className="portal-subtitle">
              Trường Đại học Quốc tế Miền Đông — Tuyển dụng / EIU Recruitment
            </p>
          </div>
          <div className="portal-user-meta">
            <span className="user-email-label">Ứng viên / Candidate:</span>
            <span className="user-email-value">{verifiedEmail || "..."}</span>
          </div>
        </header>

        {notification && (
          <div
            role="alert"
            className={`portal-alert portal-alert-${notification.type}`}
            aria-live="polite"
          >
            <span>{notification.message}</span>
            <button
              type="button"
              className="alert-dismiss-btn"
              onClick={() => setNotification(null)}
              aria-label="Đóng thông báo / Dismiss notification"
            >
              ✕
            </button>
          </div>
        )}

        <div
          className="portal-tabs"
          role="tablist"
          aria-label="Cổng ứng viên điều hướng"
        >
          <button
            type="button"
            role="tab"
            id="tab-my-apps"
            aria-selected={activeTab === "MY_APPLICATIONS"}
            aria-controls="panel-my-apps"
            className={`portal-tab ${activeTab === "MY_APPLICATIONS" ? "active" : ""}`}
            onClick={() => setActiveTab("MY_APPLICATIONS")}
          >
            Phiếu của tôi / My Applications ({submissions.length})
          </button>
          <button
            type="button"
            role="tab"
            id="tab-new-app"
            aria-selected={activeTab === "NEW_APPLICATION"}
            aria-controls="panel-new-app"
            className={`portal-tab ${activeTab === "NEW_APPLICATION" ? "active" : ""}`}
            onClick={() => void handleStartNewApplication()}
          >
            {formMode === "EDIT_SUBMISSION"
              ? "Chỉnh sửa phiếu / Edit Application"
              : "Đăng ký mới / New Application"}
          </button>
        </div>

        <div
          role="tabpanel"
          id="panel-my-apps"
          hidden={activeTab !== "MY_APPLICATIONS"}
        >
          {loading ? (
            <div className="portal-loading-indicator">
              Đang tải... / Loading...
            </div>
          ) : (
            <SubmissionsList
              submissions={submissions}
              onEditSubmission={handleEditSubmission}
              onNewApplication={handleStartNewApplication}
            />
          )}
        </div>

        <div
          role="tabpanel"
          id="panel-new-app"
          aria-labelledby="tab-new-app"
          hidden={activeTab !== "NEW_APPLICATION"}
        >
          {loading ? (
            <div className="portal-loading-indicator">
              Đang khởi tạo form... / Loading form...
            </div>
          ) : sessionId ? (
            <CandidateForm
              key={`${sessionId}:${formMode}`}
              sessionId={sessionId}
              mode={formMode}
              verifiedEmail={verifiedEmail}
              pinnedPrivacyVersion={pinnedPrivacyVersion}
              expiresAt={sessionExpiresAt}
              privacyNotice={privacyNotice}
              privacyAlreadyAcknowledged={privacyAlreadyAcknowledged}
              initialData={editInitialData}
              documentTypes={documentTypes}
              qualificationLevels={qualificationLevels}
              onSubmit={handleFormSubmit}
              onCancel={handleFormCancel}
            />
          ) : (
            <div role="alert" className="form-server-error">
              Không có phiên form hợp lệ / No valid form session.
            </div>
          )}
        </div>
      </main>
    </div>
  );
}
