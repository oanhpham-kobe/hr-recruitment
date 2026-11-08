import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import test from "node:test";

import { type Browser, chromium } from "playwright";

const port = 3104;
const baseUrl = `http://127.0.0.1:${port}`;

async function waitForServer(): Promise<void> {
  let lastError: unknown;

  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch(baseUrl);

      if (response.ok) {
        return;
      }
    } catch (error) {
      lastError = error;
    }

    // The external Next.js process exposes no readiness event, so this integration test polls HTTP.
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw lastError ?? new Error("Next.js did not start");
}

test("production page has a dynamic nonce CSP with no browser CSP violations", {
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
    const nonce = response?.headers()["x-nonce"];
    const contentSecurityPolicy =
      response?.headers()["content-security-policy"];
    const violations = await page.evaluate(
      () =>
        (window as typeof window & { cspViolations: string[] }).cspViolations,
    );

    assert.equal(response?.status(), 200);
    assert.ok(nonce);
    assert.match(contentSecurityPolicy ?? "", new RegExp(`'nonce-${nonce}'`));
    assert.deepEqual(violations, []);
  } finally {
    await browser?.close();

    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});
