import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import test from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { type Browser, chromium } from "playwright";

const port = 3004;
const baseUrl = `http://127.0.0.1:${port}`;

async function waitForServer(): Promise<void> {
  let lastError: unknown;

  // External Next.js process exposes no readiness event; integration test polls HTTP endpoint.
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch(baseUrl);

      if (response.ok) {
        return;
      }
    } catch (error) {
      lastError = error;
    }

    await sleep(250);
  }

  throw lastError ?? new Error("Next.js server did not start on port 3004");
}

test("production shell renders cleanly with semantic landmarks and zero CSP violations", {
  timeout: 60_000,
}, async () => {
  const server = spawn(
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

    const response = await page.goto(baseUrl, { waitUntil: "networkidle" });
    const status = response?.status();
    const nonce = response?.headers()["x-nonce"];
    const contentSecurityPolicy =
      response?.headers()["content-security-policy"];
    const violations = await page.evaluate(
      () =>
        (window as typeof window & { cspViolations: string[] }).cspViolations,
    );

    // 1. HTTP 200 OK
    assert.equal(status, 200);

    // 2. Dynamic nonce CSP and zero violations
    assert.ok(nonce);
    assert.match(contentSecurityPolicy ?? "", new RegExp(`'nonce-${nonce}'`));
    assert.deepEqual(violations, []);

    // 3. Semantic landmarks and skip link presence in rendered DOM
    const html = await page.content();

    // Skip link targeting #main-content
    assert.match(html, /class="[^"]*skip-link[^"]*"/);
    assert.match(html, /href="#main-content"/);

    // Semantic <aside> sidebar
    assert.match(html, /<aside\b[^>]*class="[^"]*sidebar[^"]*"/);
    assert.match(html, /aria-label="Thanh điều hướng chính"/);

    // Semantic <nav> navigation
    assert.match(html, /<nav\b[^>]*class="[^"]*sidebar-nav[^"]*"/);
    assert.match(html, /aria-label="Menu chức năng"/);

    // Semantic <header> topbar
    assert.match(html, /<header\b[^>]*class="[^"]*topbar[^"]*"/);

    // Semantic <main id="main-content">
    assert.match(html, /<main\b[^>]*id="main-content"/);
    assert.match(html, /tabindex="-1"/i);

    // Exercise actual layout + management page composition, even without a session.
    for (const route of ["/users", "/master-data"]) {
      const routeResponse = await page.goto(`${baseUrl}${route}`, {
        waitUntil: "networkidle",
      });
      assert.equal(routeResponse?.status(), 200, route);
      assert.equal(await page.locator(".shell").count(), 1, route);
      assert.equal(await page.locator("main#main-content").count(), 1, route);
      assert.equal(await page.locator("main main").count(), 0, route);
    }

    // Language switcher in header
    assert.match(html, /class="[^"]*language-switcher[^"]*"/);
  } finally {
    await browser?.close();

    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});
