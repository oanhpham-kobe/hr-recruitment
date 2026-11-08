import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import React from "react";

import {
  CANONICAL_AUTH_ERRORS,
  LoginContent,
  resolveAuthError,
} from "@/components/auth/LoginContent";

/**
 * Universal HTML serializer for React element trees under react-server conditions
 */
function renderToString(node: unknown): string {
  if (node === null || node === undefined || typeof node === "boolean") {
    return "";
  }
  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }
  if (Array.isArray(node)) {
    return node.map(renderToString).join("");
  }
  if (React.isValidElement(node)) {
    if (typeof node.type === "function") {
      const Component = node.type as (props: unknown) => React.ReactNode;
      return renderToString(Component(node.props));
    }
    const tag = node.type as string;
    const props = (node.props || {}) as Record<string, unknown>;
    let attrs = "";
    for (const [key, val] of Object.entries(props)) {
      if (
        key === "children" ||
        key.startsWith("on") ||
        val === null ||
        val === undefined
      ) {
        continue;
      }
      const attrName =
        key === "className" ? "class" : key === "htmlFor" ? "for" : key;
      if (typeof val === "boolean") {
        if (key.startsWith("aria-")) {
          attrs += ` ${attrName}="${val ? "true" : "false"}"`;
        } else if (val === true) {
          attrs += ` ${attrName}`;
        }
      } else {
        attrs += ` ${attrName}="${String(val).replace(/"/g, "&quot;")}"`;
      }
    }
    const children = renderToString(props.children);
    return `<${tag}${attrs}>${children}</${tag}>`;
  }
  return "";
}

// ---------------------------------------------------------------------------
// 1. Semantic Landmarks & Brand Identity
// ---------------------------------------------------------------------------

test("login page renders main landmark, brand panel, and language switcher", () => {
  const html = renderToString(React.createElement(LoginContent));

  // Semantic <main id="main-content">
  assert.match(html, /<main\b[^>]*id="main-content"/);
  assert.match(html, /tabindex="-1"/i);

  // EIU Brand Identity in visual panel
  assert.match(html, /class="[^"]*login-brand-panel[^"]*"/);
  assert.match(html, /class="[^"]*brand-logo-text[^"]*"[^>]*>EIU</);
  assert.match(html, /class="[^"]*brand-logo-accent[^"]*"/);
  assert.match(html, /Trường Đại học Quốc tế Miền Đông/);
  assert.match(html, /Cổng Tuyển dụng Trực tuyến \/ Recruitment Portal/);

  // Language switcher utility
  assert.match(html, /class="[^"]*language-switcher[^"]*"/);
  assert.match(html, /role="group"/);
  assert.match(html, /aria-label="Chọn ngôn ngữ \/ Choose language"/);
  assert.match(html, /aria-pressed="true"[^>]*>VI</);
  assert.match(html, /aria-pressed="false"[^>]*>EN</);
});

// ---------------------------------------------------------------------------
// 2. Persona Selector Tabs & Accessibility
// ---------------------------------------------------------------------------

test("persona selector implements WAI-ARIA tablist pattern with proper active states", () => {
  // Default: Candidate persona active
  const candidateHtml = renderToString(React.createElement(LoginContent));

  assert.match(candidateHtml, /role="tablist"/);
  assert.match(
    candidateHtml,
    /aria-label="Chọn đối tượng đăng nhập \/ Select sign-in persona"/,
  );

  // Candidate tab is selected
  assert.match(
    candidateHtml,
    /<button[^>]*id="tab-candidate"[^>]*role="tab"[^>]*aria-selected="true"/,
  );
  assert.match(
    candidateHtml,
    /<button[^>]*id="tab-internal"[^>]*role="tab"[^>]*aria-selected="false"/,
  );
  assert.match(candidateHtml, /aria-controls="panel-candidate"/);
  assert.match(candidateHtml, /aria-controls="panel-internal"/);

  // Internal persona active
  const internalHtml = renderToString(
    React.createElement(LoginContent, { initialPersona: "internal" }),
  );

  assert.match(
    internalHtml,
    /<button[^>]*id="tab-candidate"[^>]*role="tab"[^>]*aria-selected="false"/,
  );
  assert.match(
    internalHtml,
    /<button[^>]*id="tab-internal"[^>]*role="tab"[^>]*aria-selected="true"/,
  );
});

// ---------------------------------------------------------------------------
// 3. Candidate Persona Form Flow
// ---------------------------------------------------------------------------

test("candidate flow step 1: renders accessible email input and send OTP button", () => {
  const html = renderToString(
    React.createElement(LoginContent, {
      initialPersona: "candidate",
      initialOtpStep: false,
    }),
  );

  // Associated label
  assert.match(
    html,
    /<label\b[^>]*for="([^"]+)"[^>]*>[\s\S]*?Địa chỉ email ứng viên \/ Candidate email/,
  );

  // Email input field
  assert.match(html, /<input\b[^>]*name="email"/);
  assert.match(html, /type="email"/);
  assert.match(html, /required/);
  assert.match(html, /aria-required="true"/);
  assert.match(html, /class="[^"]*login-input[^"]*"/);

  // Send OTP primary button
  assert.match(
    html,
    /<button\b[^>]*type="submit"[^>]*class="[^"]*btn-login-primary[^"]*"[^>]*>[\s\S]*?Gửi mã xác thực \/ Send OTP/,
  );
});

test("candidate flow step 2: renders 6-digit OTP numeric input and verify button", () => {
  const html = renderToString(
    React.createElement(LoginContent, {
      initialPersona: "candidate",
      initialOtpStep: true,
      initialEmail: "candidate@test.edu",
    }),
  );

  // Associated label for OTP
  assert.match(
    html,
    /<label\b[^>]*for="([^"]+)"[^>]*>[\s\S]*?Mã xác thực OTP \(6 chữ số\)/,
  );

  // 6-digit OTP input field
  assert.match(html, /<input\b[^>]*name="otp"/);
  assert.match(html, /inputmode="numeric"/i);
  assert.match(html, /maxlength="6"/i);
  assert.match(html, /pattern="\[0-9\]\*"/);
  assert.match(html, /required/);
  assert.match(html, /aria-required="true"/);
  assert.match(html, /class="[^"]*login-input-otp[^"]*"/);

  // Verify and sign-in button
  assert.match(
    html,
    /<button\b[^>]*type="submit"[^>]*class="[^"]*btn-login-primary[^"]*"[^>]*>[\s\S]*?Xác nhận & Đăng nhập \/ Verify & Sign in/,
  );

  // Resend and change email secondary action buttons
  assert.match(html, /Gửi lại mã \/ Resend OTP/);
  assert.match(html, /Đổi email \/ Change email/);
});

// ---------------------------------------------------------------------------
// 4. Internal Personnel Persona Flow
// ---------------------------------------------------------------------------

test("internal personnel flow renders @eiu.edu.vn instruction and Google OAuth button", () => {
  const html = renderToString(
    React.createElement(LoginContent, { initialPersona: "internal" }),
  );

  // Institutional Google Workspace instruction
  assert.match(html, /@eiu\.edu\.vn/);
  assert.match(html, /Quy định đăng nhập nội bộ/);

  // Google OAuth button with SVG icon and accessible text
  assert.match(
    html,
    /<button\b[^>]*type="button"[^>]*class="[^"]*btn-google-login[^"]*"/,
  );
  assert.match(html, /class="[^"]*btn-google-icon[^"]*"/);
  assert.match(html, /Đăng nhập với Google \/ Sign in with Google Workspace/);
});

// ---------------------------------------------------------------------------
// 5. Accessible Error Alert Banners for All Canonical Error Codes
// ---------------------------------------------------------------------------

const canonicalErrorTestCases = [
  {
    code: "USER_INACTIVE",
    expectedVi: "Tài khoản của bạn đã bị khóa hoặc chưa được kích hoạt",
    expectedEn: "Your account is inactive or locked",
  },
  {
    code: "FORBIDDEN",
    expectedVi:
      "Chỉ tài khoản Google Workspace thuộc tên miền trường (@eiu.edu.vn)",
    expectedEn: "Access denied. Only university Google Workspace accounts",
  },
  {
    code: "NOT_FOUND",
    expectedVi:
      "Tài khoản chưa được phân quyền trong danh bạ nhân sự tuyển dụng",
    expectedEn: "Account not provisioned in the recruitment directory",
  },
  {
    code: "IDENTITY_REBIND_FORBIDDEN",
    expectedVi: "đã được liên kết với một định danh nhân sự khác",
    expectedEn: "already bound to a different identity",
  },
  {
    code: "INVALID_OTP",
    expectedVi: "Mã xác thực OTP không chính xác hoặc đã hết hạn",
    expectedEn: "The OTP verification code is invalid or has expired",
  },
  {
    code: "UNAUTHENTICATED",
    expectedVi:
      "Mã xác thực OTP không chính xác hoặc phiên đăng nhập đã hết hạn",
    expectedEn:
      "The OTP verification code is incorrect or your session has expired",
  },
  {
    code: "MISSING_CODE",
    expectedVi: "Không nhận được mã ủy quyền từ Google OAuth",
    expectedEn: "Missing authorization code from Google OAuth",
  },
  {
    code: "AUTH_EXCHANGE_FAILED",
    expectedVi: "Không thể hoàn tất trao đổi phiên xác thực với Google",
    expectedEn: "Failed to exchange authorization code for session with Google",
  },
];

test("CANONICAL_AUTH_ERRORS maps all expected error keys to bilingual messages", () => {
  const requiredCodes = [
    "USER_INACTIVE",
    "FORBIDDEN",
    "NOT_FOUND",
    "IDENTITY_REBIND_FORBIDDEN",
    "INVALID_OTP",
    "UNAUTHENTICATED",
    "MISSING_CODE",
    "AUTH_EXCHANGE_FAILED",
  ];

  for (const code of requiredCodes) {
    assert.ok(
      CANONICAL_AUTH_ERRORS[code],
      `Missing error configuration for ${code}`,
    );
    assert.ok(
      CANONICAL_AUTH_ERRORS[code].titleVi,
      `Missing titleVi for ${code}`,
    );
    assert.ok(
      CANONICAL_AUTH_ERRORS[code].titleEn,
      `Missing titleEn for ${code}`,
    );
    assert.ok(CANONICAL_AUTH_ERRORS[code].descVi, `Missing descVi for ${code}`);
    assert.ok(CANONICAL_AUTH_ERRORS[code].descEn, `Missing descEn for ${code}`);
  }
});

for (const { code, expectedVi, expectedEn } of canonicalErrorTestCases) {
  test(`error banner renders accessible alert with role="alert" for code: ${code}`, () => {
    const html = renderToString(
      React.createElement(LoginContent, { initialErrorCode: code }),
    );

    // WAI-ARIA accessible alert container
    assert.match(html, /role="alert"/);
    assert.match(html, /aria-live="assertive"/);
    assert.match(html, /class="[^"]*login-alert login-alert-danger[^"]*"/);

    // Bilingual alert content
    assert.ok(
      html.includes(expectedVi),
      `Expected Vietnamese message for ${code} not found in HTML`,
    );
    assert.ok(
      html.includes(expectedEn),
      `Expected English message for ${code} not found in HTML`,
    );
  });
}

test("resolveAuthError maps canonical and unknown error codes gracefully", () => {
  // Known code
  const known = resolveAuthError("FORBIDDEN");
  assert.equal(known?.titleEn, "Access Denied");
  assert.ok(known?.descVi.includes("@eiu.edu.vn"));

  // Lowercase code is normalized
  const lower = resolveAuthError("user_inactive");
  assert.equal(lower?.titleEn, "Account Inactive or Locked");

  // Unknown fallback code
  const unknown = resolveAuthError("SOME_CUSTOM_ERROR", "Custom details");
  assert.equal(unknown?.titleEn, "Authentication Error");
  assert.equal(unknown?.descEn, "Custom details");

  // Null code returns null
  assert.equal(resolveAuthError(null), null);
  assert.equal(resolveAuthError(undefined), null);
});

// ---------------------------------------------------------------------------
// 6. Design System v1.8 CSS Tokens & Responsive Breakpoint Validation
// ---------------------------------------------------------------------------

test("login.css complies with typography >= 16px, 820px breakpoint, and focus ring tokens", () => {
  const cssPath = path.resolve(import.meta.dirname, "../styles/login.css");
  assert.ok(fs.existsSync(cssPath), "web/src/styles/login.css must exist");

  const css = fs.readFileSync(cssPath, "utf-8");

  // Typography Hard Rule: font-size >= 16px on controls, labels, and inputs
  assert.match(css, /\.login-label\s*\{[^}]*font-size:\s*16px/);
  assert.match(css, /\.login-input\s*\{[^}]*font-size:\s*16px/);
  assert.match(css, /\.btn-login-primary\s*\{[^}]*font-size:\s*16px/);
  assert.match(css, /\.btn-google-login\s*\{[^}]*font-size:\s*16px/);
  assert.match(css, /\.persona-tab\s*\{[^}]*font-size:\s*16px/);

  // Form controls minimum height >= 48px
  assert.match(css, /\.login-input\s*\{[^}]*min-height:\s*48px/);
  assert.match(css, /\.persona-tab\s*\{[^}]*min-height:\s*48px/);
  assert.match(css, /\.btn-login-primary\s*\{[^}]*min-height:\s*50px/);
  assert.match(css, /\.btn-google-login\s*\{[^}]*min-height:\s*50px/);

  // Focus visible rings for accessibility
  assert.match(css, /\.login-input:focus-visible/);
  assert.match(css, /\.persona-tab:focus-visible/);
  assert.match(css, /\.btn-login-primary:focus-visible/);
  assert.match(css, /\.btn-google-login:focus-visible/);

  // Responsive Breakpoint at 820px (split -> stacked layout)
  assert.match(css, /@media\s*\(\s*max-width:\s*820px\s*\)/);
  assert.match(css, /\.login-page\s*\{[^}]*flex-direction:\s*column/);

  // Institutional colors: --eiu-blue, --eiu-gold, danger colors
  assert.match(css, /var\(--eiu-blue/);
  assert.match(css, /var\(--eiu-gold/);
  assert.match(css, /#B44425/i); // Semantic danger foreground (TOKENS v1.8)
  assert.match(css, /#F8E5E0/i); // Semantic danger soft background (TOKENS v1.8)
});
