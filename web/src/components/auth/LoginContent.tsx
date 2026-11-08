"use client";

import type { SupabaseClient } from "@supabase/supabase-js";
import React, { useId } from "react";
import { safeInternalPath } from "@/lib/auth/safe-internal-path";
import { createBrowserClient } from "@/lib/supabase/client";

/**
 * Canonical error definitions per AUTH_AND_LOGIN.md v1.8 and TASK-S01-005 spec
 */
export interface AuthErrorContent {
  titleVi: string;
  titleEn: string;
  descVi: string;
  descEn: string;
}

export const CANONICAL_AUTH_ERRORS: Record<string, AuthErrorContent> = {
  USER_INACTIVE: {
    titleVi: "Tài khoản tạm khóa / Account inactive",
    titleEn: "Account Inactive or Locked",
    descVi:
      "Tài khoản của bạn đã bị khóa hoặc chưa được kích hoạt. Vui lòng liên hệ Phòng Nhân sự EIU (hr@eiu.edu.vn) để được hỗ trợ.",
    descEn:
      "Your account is inactive or locked. Please contact EIU HR Department (hr@eiu.edu.vn) for assistance.",
  },
  FORBIDDEN: {
    titleVi: "Truy cập bị từ chối / Access denied",
    titleEn: "Access Denied",
    descVi:
      "Chỉ tài khoản Google Workspace thuộc tên miền trường (@eiu.edu.vn) mới được phép đăng nhập vào cổng nhân sự nội bộ.",
    descEn:
      "Access denied. Only university Google Workspace accounts (@eiu.edu.vn) are permitted for internal login.",
  },
  NOT_FOUND: {
    titleVi: "Chưa phân quyền / Account not provisioned",
    titleEn: "Account Not Provisioned",
    descVi:
      "Tài khoản chưa được phân quyền trong danh bạ nhân sự tuyển dụng. Vui lòng liên hệ Quản trị viên hệ thống.",
    descEn:
      "Account not provisioned in the recruitment directory. Please contact the administrator.",
  },
  IDENTITY_REBIND_FORBIDDEN: {
    titleVi: "Không thể liên kết / Identity rebind forbidden",
    titleEn: "Identity Rebind Forbidden",
    descVi:
      "Tài khoản Google này đã được liên kết với một định danh nhân sự khác và không thể tái liên kết.",
    descEn:
      "This Google account is already bound to a different identity and cannot be rebound.",
  },
  INVALID_OTP: {
    titleVi: "Mã OTP không hợp lệ / Invalid OTP",
    titleEn: "Invalid or Expired OTP",
    descVi:
      "Mã xác thực OTP không chính xác hoặc đã hết hạn. Vui lòng kiểm tra lại hộp thư hoặc yêu cầu mã mới.",
    descEn:
      "The OTP verification code is invalid or has expired. Please check your email or request a new code.",
  },
  UNAUTHENTICATED: {
    titleVi: "Xác thực không thành công / Unauthenticated",
    titleEn: "Authentication Failed",
    descVi:
      "Mã xác thực OTP không chính xác hoặc phiên đăng nhập đã hết hạn. Vui lòng thử lại.",
    descEn:
      "The OTP verification code is incorrect or your session has expired. Please try again.",
  },
  MISSING_CODE: {
    titleVi: "Thiếu mã xác thực / Missing code",
    titleEn: "Missing Authorization Code",
    descVi:
      "Không nhận được mã ủy quyền từ Google OAuth. Vui lòng thử đăng nhập lại.",
    descEn:
      "Missing authorization code from Google OAuth. Please try logging in again.",
  },
  AUTH_EXCHANGE_FAILED: {
    titleVi: "Lỗi trao đổi phiên / Auth exchange failed",
    titleEn: "Auth Exchange Failed",
    descVi:
      "Không thể hoàn tất trao đổi phiên xác thực với Google. Vui lòng thử lại sau.",
    descEn:
      "Failed to exchange authorization code for session with Google. Please try again later.",
  },
};

export function resolveAuthError(
  code: string | null | undefined,
  fallbackMessage?: string | null,
): AuthErrorContent | null {
  if (!code) return null;
  const canonical = CANONICAL_AUTH_ERRORS[code.toUpperCase()];
  if (canonical) {
    return canonical;
  }
  return {
    titleVi: "Lỗi xác thực / Authentication error",
    titleEn: "Authentication Error",
    descVi:
      fallbackMessage ||
      "Đã xảy ra lỗi trong quá trình xác thực. Vui lòng thử lại.",
    descEn:
      fallbackMessage || "An authentication error occurred. Please try again.",
  };
}

export interface LoginContentProps {
  initialErrorCode?: string | null;
  initialPersona?: "candidate" | "internal";
  initialEmail?: string;
  initialOtpStep?: boolean;
  supabaseClient?: SupabaseClient;
}

let fallbackIdCounter = 0;
function useSafeId(): string {
  const internals = React as unknown as Record<string, { H?: unknown }>;
  const hasDispatcher = Boolean(
    internals.__SERVER_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE
      ?.H ||
      internals.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE
        ?.H,
  );

  if (hasDispatcher) {
    // biome-ignore lint/correctness/useHookAtTopLevel: safe wrapper
    return useId();
  }

  fallbackIdCounter += 1;
  return `:r${fallbackIdCounter}:`;
}

function useSafeState<T>(
  initialValue: T | (() => T),
): [T, (val: T | ((prev: T) => T)) => void] {
  const internals = React as unknown as Record<string, { H?: unknown }>;
  const hasDispatcher = Boolean(
    internals.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE
      ?.H,
  );

  if (hasDispatcher && typeof React.useState === "function") {
    // biome-ignore lint/correctness/useHookAtTopLevel: safe client wrapper
    return React.useState<T>(initialValue);
  }

  const resolved =
    typeof initialValue === "function"
      ? (initialValue as () => T)()
      : initialValue;
  return [resolved, () => {}];
}
export function LoginContent({
  initialErrorCode = null,
  initialPersona = "candidate",
  initialEmail = "",
  initialOtpStep = false,
  supabaseClient,
}: LoginContentProps) {
  const [persona, setPersona] = useSafeState<"candidate" | "internal">(
    initialPersona,
  );
  const [email, setEmail] = useSafeState(initialEmail);
  const [otp, setOtp] = useSafeState("");
  const [isOtpSent, setIsOtpSent] = useSafeState(initialOtpStep);
  const [isLoading, setIsLoading] = useSafeState(false);
  const [errorCode, setErrorCode] = useSafeState<string | null>(
    initialErrorCode,
  );
  const [errorMessage, setErrorMessage] = useSafeState<string | null>(null);
  const [infoMessage, setInfoMessage] = useSafeState<string | null>(null);

  const emailInputId = useSafeId();
  const otpInputId = useSafeId();
  const activeError = resolveAuthError(errorCode, errorMessage);

  // Switch persona tabs
  const handleTabChange = (nextPersona: "candidate" | "internal") => {
    setPersona(nextPersona);
    setErrorCode(null);
    setErrorMessage(null);
    setInfoMessage(null);
  };

  // Step 1: Candidate Email OTP Request
  const handleSendOtp = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    const cleanEmail = email.trim();
    if (!cleanEmail) return;

    setIsLoading(true);
    setErrorCode(null);
    setErrorMessage(null);
    setInfoMessage(null);

    try {
      const client = supabaseClient ?? createBrowserClient();
      const { error } = await client.auth.signInWithOtp({
        email: cleanEmail,
        options: {
          shouldCreateUser: true,
        },
      });

      if (error) {
        setErrorCode("UNAUTHENTICATED");
        setErrorMessage(error.message);
      } else {
        setIsOtpSent(true);
        setInfoMessage(
          `Mã xác thực 6 chữ số đã được gửi đến ${cleanEmail}. Vui lòng kiểm tra hộp thư. / A 6-digit OTP has been sent to ${cleanEmail}. Please check your inbox.`,
        );
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Failed to send OTP";
      setErrorCode("UNAUTHENTICATED");
      setErrorMessage(message);
    } finally {
      setIsLoading(false);
    }
  };

  // Step 2: Candidate OTP Verification via /auth/candidate/verify
  const handleVerifyOtp = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    const cleanEmail = email.trim();
    const cleanOtp = otp.trim();
    if (!cleanEmail || !cleanOtp) return;

    setIsLoading(true);
    setErrorCode(null);
    setErrorMessage(null);

    try {
      const response = await fetch("/auth/candidate/verify", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: cleanEmail,
          token: cleanOtp,
        }),
      });

      let result: {
        success?: boolean;
        error?: { code?: string; message?: string };
      } = {};
      try {
        result = await response.json();
      } catch {
        result = { success: false };
      }

      if (!response.ok || !result.success) {
        const errCode =
          result.error?.code ||
          (response.status === 401 ? "INVALID_OTP" : "UNAUTHENTICATED");
        setErrorCode(errCode);
        setErrorMessage(result.error?.message || null);
      } else {
        // Authenticated and provisioned successfully
        if (typeof window !== "undefined") {
          const urlParams = new URLSearchParams(window.location.search);
          const next = safeInternalPath(urlParams.get("next"));
          window.location.href = next;
        }
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Verification error";
      setErrorCode("UNAUTHENTICATED");
      setErrorMessage(message);
    } finally {
      setIsLoading(false);
    }
  };

  // Internal Personnel Google OAuth Login
  const handleGoogleLogin = async () => {
    setIsLoading(true);
    setErrorCode(null);
    setErrorMessage(null);

    try {
      const client = supabaseClient ?? createBrowserClient();
      let redirectTo = "/auth/callback";
      if (typeof window !== "undefined") {
        const redirectUrl = new URL("/auth/callback", window.location.origin);
        const urlParams = new URLSearchParams(window.location.search);
        const next = urlParams.get("next");
        if (next) {
          redirectUrl.searchParams.set("next", safeInternalPath(next));
        }
        redirectTo = redirectUrl.toString();
      }

      const { error } = await client.auth.signInWithOAuth({
        provider: "google",
        options: {
          redirectTo,
          queryParams: {
            hd: "eiu.edu.vn",
            prompt: "select_account",
          },
        },
      });

      if (error) {
        setErrorCode("AUTH_EXCHANGE_FAILED");
        setErrorMessage(error.message);
        setIsLoading(false);
      }
    } catch (err: unknown) {
      const message =
        err instanceof Error ? err.message : "Failed to initiate Google OAuth";
      setErrorCode("AUTH_EXCHANGE_FAILED");
      setErrorMessage(message);
      setIsLoading(false);
    }
  };

  return (
    <main id="main-content" tabIndex={-1} className="login-page">
      {/* -----------------------------------------------------------------
       * Visual Brand Panel (Left on Desktop, Top on Mobile)
       * ----------------------------------------------------------------- */}
      <section
        className="login-brand-panel"
        aria-label="Thông tin nhận diện EIU / EIU Brand identity"
      >
        <div className="brand-panel-header">
          <div className="brand-panel-logo">
            <span className="brand-logo-text">EIU</span>
            <span className="brand-logo-accent" aria-hidden="true">
              <i />
              <i />
              <i />
            </span>
          </div>
          <div className="brand-panel-institution">
            Trường Đại học Quốc tế Miền Đông
          </div>
        </div>

        <div className="brand-panel-body">
          <span className="brand-panel-badge">
            Eastern International University
          </span>
          <h1 className="brand-panel-title">
            Cổng Tuyển dụng Trực tuyến / Recruitment Portal
          </h1>
          <div className="brand-panel-gold-divider" aria-hidden="true" />
          <p className="brand-panel-desc">
            Hệ thống tiếp nhận và xử lý hồ sơ tuyển dụng giảng viên, nghiên cứu
            viên và chuyên viên. Môi trường học thuật và làm việc hiện đại theo
            chuẩn mực quốc tế.
          </p>
        </div>

        <div className="brand-panel-footer">
          © Trường Đại học Quốc tế Miền Đông. Bản quyền thuộc về EIU.
        </div>
      </section>

      {/* -----------------------------------------------------------------
       * Main Login Form Panel (Right on Desktop, Bottom on Mobile)
       * ----------------------------------------------------------------- */}
      <section
        className="login-main-panel"
        aria-label="Khu vực đăng nhập / Sign-in section"
      >
        {/* Top-Right Language Toggle Placeholder */}
        <div className="login-utility-bar">
          {/* biome-ignore lint/a11y/useSemanticElements: toolbar button group per WAI-ARIA pattern */}
          <div
            className="language-switcher"
            role="group"
            aria-label="Chọn ngôn ngữ / Choose language"
          >
            <button
              type="button"
              className="lang-btn active"
              aria-pressed="true"
              aria-label="Tiếng Việt (Đang chọn / Selected)"
            >
              VI
            </button>
            <span className="lang-divider" aria-hidden="true">
              |
            </span>
            <button
              type="button"
              className="lang-btn"
              aria-pressed="false"
              aria-label="English"
            >
              EN
            </button>
          </div>
        </div>

        {/* Centered Institutional Login Card */}
        <div className="login-card">
          <header className="login-card-header">
            <h2 className="login-card-title">Đăng nhập / Sign In</h2>
            <p className="login-card-subtitle">
              Chọn đúng đối tượng để tiếp tục truy cập hệ thống tuyển dụng
            </p>
          </header>

          {/* Persona Selector Tabs (WAI-ARIA Pattern) */}
          <div
            className="persona-tablist"
            role="tablist"
            aria-label="Chọn đối tượng đăng nhập / Select sign-in persona"
          >
            <button
              type="button"
              id="tab-candidate"
              role="tab"
              aria-selected={persona === "candidate"}
              aria-controls="panel-candidate"
              tabIndex={persona === "candidate" ? 0 : -1}
              className="persona-tab"
              onClick={() => handleTabChange("candidate")}
            >
              Ứng viên / Candidate
            </button>
            <button
              type="button"
              id="tab-internal"
              role="tab"
              aria-selected={persona === "internal"}
              aria-controls="panel-internal"
              tabIndex={persona === "internal" ? 0 : -1}
              className="persona-tab"
              onClick={() => handleTabChange("internal")}
            >
              Cán bộ - Giảng viên / Internal Staff
            </button>
          </div>

          {/* Accessible Error Alert Banner */}
          {activeError && (
            <div
              role="alert"
              aria-live="assertive"
              className="login-alert login-alert-danger"
              id="auth-error-alert"
            >
              <svg
                className="login-alert-icon"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
              >
                <circle cx="12" cy="12" r="10" />
                <line x1="12" y1="8" x2="12" y2="12" />
                <line x1="12" y1="16" x2="12.01" y2="16" />
              </svg>
              <div className="login-alert-content">
                <div className="login-alert-title">{activeError.titleVi}</div>
                <p className="login-alert-desc">{activeError.descVi}</p>
                <p
                  className="login-alert-desc"
                  style={{ marginTop: "4px", opacity: 0.9 }}
                >
                  <em>{activeError.descEn}</em>
                </p>
              </div>
            </div>
          )}

          {/* Accessible Info/Status Banner */}
          {infoMessage && !activeError && (
            <div
              role="status"
              aria-live="polite"
              className="login-alert login-alert-info"
            >
              <svg
                className="login-alert-icon"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
              >
                <circle cx="12" cy="12" r="10" />
                <line x1="12" y1="16" x2="12" y2="12" />
                <line x1="12" y1="8" x2="12.01" y2="8" />
              </svg>
              <div className="login-alert-content">
                <p className="login-alert-desc">{infoMessage}</p>
              </div>
            </div>
          )}

          {/* -------------------------------------------------------------
           * Persona 1: Candidate Email OTP Flow
           * ------------------------------------------------------------- */}
          {persona === "candidate" && (
            <div
              id="panel-candidate"
              role="tabpanel"
              aria-labelledby="tab-candidate"
            >
              {!isOtpSent ? (
                // Step 1: Enter Email and Request OTP
                <form onSubmit={handleSendOtp} noValidate={false}>
                  <div className="login-form-group">
                    <label htmlFor={emailInputId} className="login-label">
                      <span>
                        Địa chỉ email ứng viên / Candidate email
                        <span className="required-indicator" aria-hidden="true">
                          *
                        </span>
                      </span>
                    </label>
                    <input
                      id={emailInputId}
                      name="email"
                      type="email"
                      autoComplete="email"
                      required
                      aria-required="true"
                      placeholder="ungvien@example.com"
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                      disabled={isLoading}
                      className="login-input"
                    />
                    <p className="login-helper-text">
                      Hệ thống sẽ gửi mã số xác thực (OTP) một lần đến email này
                    </p>
                  </div>

                  <button
                    type="submit"
                    disabled={isLoading || !email.trim()}
                    className="btn-login-primary"
                  >
                    {isLoading ? (
                      <span>Đang gửi mã... / Sending code...</span>
                    ) : (
                      <span>Gửi mã xác thực / Send OTP</span>
                    )}
                  </button>
                </form>
              ) : (
                // Step 2: Enter 6-digit OTP Code
                <form onSubmit={handleVerifyOtp} noValidate={false}>
                  <div className="login-form-group">
                    <label htmlFor={otpInputId} className="login-label">
                      <span>
                        Mã xác thực OTP (6 chữ số) / Verification Code
                        <span className="required-indicator" aria-hidden="true">
                          *
                        </span>
                      </span>
                    </label>
                    <input
                      id={otpInputId}
                      name="otp"
                      type="text"
                      inputMode="numeric"
                      pattern="[0-9]*"
                      maxLength={6}
                      autoComplete="one-time-code"
                      required
                      aria-required="true"
                      placeholder="000000"
                      value={otp}
                      onChange={(e) =>
                        setOtp(
                          e.target.value.replace(/[^0-9]/g, "").slice(0, 6),
                        )
                      }
                      disabled={isLoading}
                      className="login-input login-input-otp"
                    />
                    <p className="login-helper-text">
                      Nhập mã số gồm 6 chữ số được gửi trong email của bạn
                    </p>
                  </div>

                  <button
                    type="submit"
                    disabled={isLoading || otp.trim().length !== 6}
                    className="btn-login-primary"
                  >
                    {isLoading ? (
                      <span>Đang xác nhận... / Verifying...</span>
                    ) : (
                      <span>Xác nhận & Đăng nhập / Verify & Sign in</span>
                    )}
                  </button>

                  <div className="form-actions-row">
                    <button
                      type="button"
                      className="btn-login-link"
                      onClick={() => handleSendOtp()}
                      disabled={isLoading}
                    >
                      Gửi lại mã / Resend OTP
                    </button>
                    <button
                      type="button"
                      className="btn-login-link"
                      onClick={() => {
                        setIsOtpSent(false);
                        setOtp("");
                        setErrorCode(null);
                        setInfoMessage(null);
                      }}
                      disabled={isLoading}
                    >
                      Đổi email / Change email
                    </button>
                  </div>
                </form>
              )}
            </div>
          )}

          {/* -------------------------------------------------------------
           * Persona 2: Internal Personnel Google OAuth Flow
           * ------------------------------------------------------------- */}
          {persona === "internal" && (
            <div
              id="panel-internal"
              role="tabpanel"
              aria-labelledby="tab-internal"
            >
              <div className="internal-instruction-box">
                <p style={{ margin: "0 0 6px 0" }}>
                  <strong>Quy định đăng nhập nội bộ:</strong>
                </p>
                <p style={{ margin: 0 }}>
                  Đăng nhập bằng tài khoản Google Workspace trường (
                  <strong>@eiu.edu.vn</strong>). Tài khoản cần được kích hoạt và
                  phân quyền trong danh bạ quản trị nhân sự EIU.
                </p>
              </div>

              <button
                type="button"
                className="btn-google-login"
                onClick={handleGoogleLogin}
                disabled={isLoading}
              >
                <svg
                  className="btn-google-icon"
                  viewBox="0 0 24 24"
                  width="20"
                  height="20"
                  aria-hidden="true"
                >
                  <path
                    fill="#4285F4"
                    d="M23.745 12.27c0-.7-.06-1.4-.19-2.07H12v4.51h6.6c-.29 1.52-1.14 2.82-2.4 3.68v3.05h3.88c2.27-2.09 3.665-5.17 3.665-9.17z"
                  />
                  <path
                    fill="#34A853"
                    d="M12 24c3.24 0 5.95-1.08 7.93-2.91l-3.88-3.05c-1.08.72-2.45 1.16-4.05 1.16-3.12 0-5.77-2.1-6.72-4.93H1.25v3.15C3.26 21.36 7.33 24 12 24z"
                  />
                  <path
                    fill="#FBBC05"
                    d="M5.28 14.27c-.25-.72-.38-1.49-.38-2.27s.13-1.55.38-2.27V6.58H1.25C.45 8.18 0 9.98 0 12s.45 3.82 1.25 5.42l4.03-3.15z"
                  />
                  <path
                    fill="#EA4335"
                    d="M12 4.75c1.77 0 3.35.61 4.6 1.8l3.42-3.42C17.95 1.19 15.24 0 12 0 7.33 0 3.26 2.64 1.25 6.58l4.03 3.15c.95-2.83 3.6-4.98 6.72-4.98z"
                  />
                </svg>
                {isLoading ? (
                  <span>Đang kết nối... / Connecting...</span>
                ) : (
                  <span>
                    Đăng nhập với Google / Sign in with Google Workspace
                  </span>
                )}
              </button>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
