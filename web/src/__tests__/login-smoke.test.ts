import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import test from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { type Browser, chromium } from "playwright";

const port = 3003;
const baseUrl = `http://127.0.0.1:${port}`;
const loginUrl = `${baseUrl}/login`;

async function isServerResponding(): Promise<boolean> {
  try {
    const res = await fetch(baseUrl);
    return res.status === 200;
  } catch {
    return false;
  }
}

async function waitForServer(): Promise<void> {
  let lastError: unknown;

  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch(baseUrl);
      if (response.status === 200) {
        return;
      }
    } catch (error) {
      lastError = error;
    }

    await sleep(250);
  }

  throw lastError ?? new Error("Next.js server did not start on port 3003");
}

test("production login page renders with dynamic nonce CSP, zero violations, and accessible controls", {
  timeout: 60_000,
}, async () => {
  let server: ChildProcess | undefined;
  const alreadyRunning = await isServerResponding();

  if (!alreadyRunning) {
    server = spawn(
      process.execPath,
      [
        path.resolve("node_modules/next/dist/bin/next"),
        "start",
        "-p",
        String(port),
      ],
      {
        env: {
          ...process.env,
          NEXT_PUBLIC_SUPABASE_URL: "https://project.supabase.co",
          NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "test-publishable-key",
        },
        stdio: "ignore",
      },
    );
  }

  let browser: Browser | undefined;

  try {
    await waitForServer();
    browser = await chromium.launch();
    const page = await browser.newPage();

    await page.addInitScript(() => {
      (window as typeof window & { cspViolations: string[] }).cspViolations =
        [];
      window.addEventListener("securitypolicyviolation", (event) => {
        (
          window as typeof window & { cspViolations: string[] }
        ).cspViolations.push(event.violatedDirective);
      });
    });

    const response = await page.goto(loginUrl, { waitUntil: "networkidle" });
    const status = response?.status();
    const nonce = response?.headers()["x-nonce"];
    const contentSecurityPolicy =
      response?.headers()["content-security-policy"];
    const violations = await page.evaluate(
      () =>
        (window as typeof window & { cspViolations: string[] }).cspViolations,
    );

    // 1. HTTP 200 OK on /login
    assert.equal(status, 200);

    // 2. Dynamic nonce CSP and zero violations
    assert.ok(nonce, "x-nonce header must be present on /login response");
    assert.match(
      contentSecurityPolicy ?? "",
      new RegExp(`'nonce-${nonce}'`),
      "Content-Security-Policy header must include dynamic nonce",
    );
    assert.deepEqual(
      violations,
      [],
      "Zero CSP violations must occur during login rendering",
    );

    // 3. Semantic landmarks and UI components in rendered DOM
    const html = await page.content();

    // Semantic <main id="main-content"> landmark
    assert.match(html, /<main\b[^>]*id="main-content"/);
    assert.match(html, /tabindex="-1"/i);

    // Visual Brand Identity Panel
    assert.match(html, /class="[^"]*login-brand-panel[^"]*"/);
    assert.match(html, /Trường Đại học Quốc tế Miền Đông/);
    assert.match(html, /Cổng Tuyển dụng Trực tuyến \/ Recruitment Portal/);

    // Centered Login Card
    assert.match(html, /class="[^"]*login-card[^"]*"/);
    assert.match(html, /class="[^"]*login-card-title[^"]*"/);

    // Persona Selector Tablist (WAI-ARIA pattern)
    assert.match(html, /role="tablist"/);
    assert.match(html, /id="tab-candidate"/);
    assert.match(html, /id="tab-internal"/);

    // Form inputs and action buttons
    assert.match(html, /input\b[^>]*name="email"/);
    assert.match(html, /class="[^"]*btn-login-primary[^"]*"/);

    // Language toggle in utility region
    assert.match(html, /class="[^"]*language-switcher[^"]*"/);
    assert.match(html, /aria-label="Chọn ngôn ngữ \/ Choose language"/);
  } finally {
    await browser?.close();

    if (server && server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});
