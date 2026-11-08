import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { once } from "node:events";
import { createServer } from "node:net";
import path from "node:path";
import test from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { type Browser, chromium } from "playwright";

async function allocatePort(): Promise<number> {
  const listener = createServer();

  await new Promise<void>((resolve, reject) => {
    listener.once("error", reject);
    listener.listen(0, "127.0.0.1", resolve);
  });

  const address = listener.address();
  await new Promise<void>((resolve, reject) => {
    listener.close((error) => (error ? reject(error) : resolve()));
  });

  if (!address || typeof address === "string") {
    throw new Error("Could not allocate a local test port");
  }

  return address.port;
}

async function waitForServer(baseUrl: string): Promise<void> {
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

  throw lastError ?? new Error(`Next.js server did not start at ${baseUrl}`);
}

test("production browser bundle initializes Supabase with build-time public environment", {
  timeout: 60_000,
}, async () => {
  const port = await allocatePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const server: ChildProcess = spawn(
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
    await waitForServer(baseUrl);
    browser = await chromium.launch();
    const page = await browser.newPage();
    const browserErrors: string[] = [];
    page.on("pageerror", (error) => browserErrors.push(error.message));
    page.on("console", (message) => {
      if (
        message.type() === "error" &&
        /hydration|Minified React error #418/i.test(message.text())
      )
        browserErrors.push(message.text());
    });
    const invitationPath =
      "/interview-feedback/10100000-0000-4000-8000-000000000001";
    for (const query of ["persona=internal", "error=FORBIDDEN"]) {
      await page.goto(
        `${baseUrl}/login?${query}&next=${encodeURIComponent(invitationPath)}`,
        { waitUntil: "networkidle" },
      );
      assert.ok(
        await page
          .getByRole("button", { name: /Sign in with Google Workspace/ })
          .isVisible(),
      );
      assert.equal(await page.locator('input[name="email"]').count(), 0);
      if (query === "error=FORBIDDEN")
        assert.ok(
          await page
            .getByRole("alert")
            .filter({ hasText: "Truy cập bị từ chối" })
            .isVisible(),
        );
      assert.deepEqual(
        browserErrors,
        [],
        `${query} must hydrate without React recovery`,
      );
    }
    let resolveOtpRoute: (() => void) | undefined;
    const routedOtp = new Promise<void>((resolve) => {
      resolveOtpRoute = resolve;
    });

    await page.route(
      "https://project.supabase.co/auth/v1/otp**",
      async (route) => {
        resolveOtpRoute?.();
        await route.fulfill({
          body: JSON.stringify({
            message: "controlled browser test rejection",
          }),
          contentType: "application/json",
          status: 400,
        });
      },
    );
    await page.goto(`${baseUrl}/login?persona=candidate`, {
      waitUntil: "networkidle",
    });
    await page.locator('input[name="email"]').fill("candidate@example.test");
    await page.locator('button[type="submit"]').click();
    await Promise.race([
      routedOtp,
      sleep(10_000).then(() => {
        throw new Error(
          "Browser bundle did not issue the intercepted OTP request",
        );
      }),
    ]);
    assert.deepEqual(
      browserErrors,
      [],
      "Candidate OTP login must hydrate cleanly",
    );
    const serverRendered = await browser.newPage({ javaScriptEnabled: false });
    await serverRendered.goto(`${baseUrl}/login?error=FORBIDDEN`);
    assert.ok(
      await serverRendered
        .getByRole("button", { name: /Sign in with Google Workspace/ })
        .isVisible(),
      "Server markup must already use the internal persona",
    );
    assert.ok(
      await serverRendered
        .getByRole("alert")
        .filter({ hasText: "Truy cập bị từ chối" })
        .isVisible(),
      "Server markup must already show the query error",
    );
    await serverRendered.close();
    await page.goto(
      `${baseUrl}/login?persona=internal&next=${encodeURIComponent(invitationPath)}`,
      { waitUntil: "networkidle" },
    );
    let authorizeUrl: URL | undefined;
    await page.route(
      "https://project.supabase.co/auth/v1/authorize**",
      async (route) => {
        authorizeUrl = new URL(route.request().url());
        await route.fulfill({
          status: 200,
          contentType: "text/html",
          body: "<p>Intercepted OAuth request; no provider contacted.</p>",
        });
      },
    );
    await page
      .getByRole("button", { name: /Sign in with Google Workspace/ })
      .click();
    await page.waitForURL("https://project.supabase.co/auth/v1/authorize**");
    assert.ok(authorizeUrl);
    const callback = new URL(
      authorizeUrl.searchParams.get("redirect_to") ?? "",
    );
    assert.equal(callback.pathname, "/auth/callback");
    assert.equal(callback.searchParams.get("next"), invitationPath);
    assert.equal(authorizeUrl.searchParams.get("provider"), "google");
    assert.deepEqual(browserErrors, []);
  } finally {
    await browser?.close();

    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});
