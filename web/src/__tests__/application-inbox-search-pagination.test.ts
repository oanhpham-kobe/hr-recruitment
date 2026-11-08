import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { build } from "esbuild";
import { type Browser, chromium, type Page } from "playwright";
import {
  APPLICATION_INBOX_PAGE_SIZES,
  DEFAULT_APPLICATION_INBOX_PAGE_SIZE,
  normalizeApplicationInboxPageSize,
} from "@/lib/application-inbox/model";
import { loadApplicationInbox } from "@/lib/application-inbox/server";
import type { AppSession } from "@/lib/auth/session";

function internalSession(): AppSession {
  return {
    isAuthenticated: true,
    user: {
      authUserId: "search-pagination-user",
      email: "search-pagination@eiu.edu.vn",
      isInternal: true,
      isCandidate: false,
      appUserId: "search-pagination-app-user",
      candidateId: undefined,
      roles: ["HR"],
      permissions: ["submissions.view"],
    },
  };
}

function createInboxClient() {
  const rpcCalls: Array<{ args: Record<string, unknown>; name: string }> = [];
  const client = {
    rpc(name: string, args: Record<string, unknown>) {
      rpcCalls.push({ name, args });
      return Promise.resolve({ data: [], error: null });
    },
  } as unknown as SupabaseClient;

  return { client, rpcCalls };
}

test("Application Inbox canonical user-facing page sizes are exactly 25/50/100 with default 25", () => {
  assert.deepEqual(APPLICATION_INBOX_PAGE_SIZES, [25, 50, 100]);
  assert.equal(DEFAULT_APPLICATION_INBOX_PAGE_SIZE, 25);
  assert.equal(normalizeApplicationInboxPageSize(25), 25);
  assert.equal(normalizeApplicationInboxPageSize(50), 50);
  assert.equal(normalizeApplicationInboxPageSize(100), 100);
  assert.equal(normalizeApplicationInboxPageSize(10), 25);
  assert.equal(normalizeApplicationInboxPageSize(101), 25);
  assert.equal(normalizeApplicationInboxPageSize("50"), 25);
});

test("Application Inbox low-level server adapter enforces canonical page sizes with fallback 25", async () => {
  const defaultClient = createInboxClient();
  await loadApplicationInbox({
    client: defaultClient.client,
    resolveSession: async () => internalSession(),
  });
  assert.equal(defaultClient.rpcCalls.length, 1);
  assert.equal(defaultClient.rpcCalls[0].args.p_page_size, 25);

  const invalidSmallClient = createInboxClient();
  await loadApplicationInbox({
    client: invalidSmallClient.client,
    pageSize: 1,
    resolveSession: async () => internalSession(),
  });
  assert.equal(invalidSmallClient.rpcCalls[0].args.p_page_size, 25);

  const invalidLargeClient = createInboxClient();
  await loadApplicationInbox({
    client: invalidLargeClient.client,
    pageSize: 999,
    resolveSession: async () => internalSession(),
  });
  assert.equal(invalidLargeClient.rpcCalls[0].args.p_page_size, 25);

  const canonicalClient = createInboxClient();
  await loadApplicationInbox({
    client: canonicalClient.client,
    pageSize: 100,
    resolveSession: async () => internalSession(),
  });
  assert.equal(canonicalClient.rpcCalls[0].args.p_page_size, 100);
});

let cachedScript: string | undefined;
let cachedStyle: string | undefined;

async function getHarnessBundle(): Promise<{ script: string; style: string }> {
  if (cachedScript && cachedStyle) {
    return { script: cachedScript, style: cachedStyle };
  }

  const browserBundle = await build({
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
    absWorkingDir: process.cwd(),
    bundle: true,
    entryPoints: ["src/__tests__/fixtures/application-inbox-bulk-harness.tsx"],
    format: "iife",
    outdir: "application-inbox-search-pagination-fixture",
    platform: "browser",
    conditions: ["browser"],
    write: false,
    plugins: [
      {
        name: "stub-server-only",
        setup(builder) {
          builder.onResolve({ filter: /^server-only$/ }, () => ({
            path: "server-only",
            namespace: "stub-server-only",
          }));
          builder.onLoad(
            { filter: /.*/, namespace: "stub-server-only" },
            () => ({ contents: "module.exports = {};" }),
          );
          builder.onResolve({ filter: /application-inbox-actions$/ }, () => ({
            path: "actions",
            namespace: "stub-actions",
          }));
          builder.onLoad({ filter: /.*/, namespace: "stub-actions" }, () => ({
            contents: `
              export async function queryApplicationInbox() { return { groups: [], page: 1, pageCount: 1 }; }
              export async function bulkSetLatestSubmissionManualStatusAction() { return { success: false, error: 'stub' }; }
              export async function bulkSetCandidateActiveAction() { return { success: false, error: 'stub' }; }
              export async function setCandidateActiveAction() { return { success: false, error: 'stub' }; }
              export async function createApplicationAction() { return { success: false, error: 'stub' }; }
              export async function getAssignmentOptionsAction() { return { success: false, error: 'stub' }; }
              export async function getDocumentSignedUrlAction() { return { success: false, error: 'stub' }; }
              export async function getSubmissionDetailAction() { return { success: false, error: 'stub' }; }
              export async function updateSubmissionHrNoteAction() { return { success: false, error: 'stub' }; }
              export async function openSubmissionAction() { return { success: true }; }
              export async function updateSubmissionAggregateAction() { return { success: true }; }
              export async function getRecruitmentSourcesAction() { return []; }
              export async function getQualificationLevelsAction() { return []; }
            `,
          }));
        },
      },
    ],
  });

  const script = browserBundle.outputFiles.find((file) =>
    file.path.endsWith(".js"),
  )?.text;
  const style = browserBundle.outputFiles.find((file) =>
    file.path.endsWith(".css"),
  )?.text;
  if (!script || !style) {
    throw new Error(
      "Application Inbox search/page-size fixture did not bundle",
    );
  }

  cachedScript = script;
  cachedStyle = style;
  return { script, style };
}

async function setupPage(page: Page, style: string, script: string) {
  await page.route("http://localhost:3000/**", (route) => {
    route.fulfill({
      status: 200,
      contentType: "text/html",
      body: '<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>',
    });
  });

  await page.goto("http://localhost:3000/");
  await page.addStyleTag({ content: style });
  await page.addScriptTag({ content: script });
  await page
    .getByLabel("Số Candidate mỗi trang")
    .waitFor({ state: "visible", timeout: 5_000 });
}

test("Application Inbox page-size selector exposes exactly 25/50/100 and reloads page 1 while clearing page-scoped selection", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") pageErrors.push(message.text());
    });
    await setupPage(page, style, script);

    const pageSize = page.getByLabel("Số Candidate mỗi trang");
    assert.equal(await pageSize.inputValue(), "25");
    assert.deepEqual(await pageSize.locator("option").allTextContents(), [
      "25",
      "50",
      "100",
    ]);

    await page
      .getByRole("checkbox", { name: "Chọn Candidate Nguyễn Thị An" })
      .click();
    assert.equal(
      (
        await page.locator(".application-inbox__selection-count").textContent()
      )?.trim(),
      "1 ứng viên được chọn",
    );

    await page.evaluate(() => {
      window.__BULK_HARNESS_LOGS__ = [];
    });
    await pageSize.selectOption("50");
    await page.waitForFunction(
      () =>
        window.__BULK_HARNESS_LOGS__?.some(
          (entry) =>
            entry.event === "queryInbox" &&
            (entry.payload as { pageSize?: number } | undefined)?.pageSize ===
              50,
        ) === true,
      undefined,
      { timeout: 2_000 },
    );

    const queryLog = await page.evaluate(() =>
      window.__BULK_HARNESS_LOGS__?.find(
        (entry) => entry.event === "queryInbox",
      ),
    );
    const payload = queryLog?.payload as
      | { page?: number; pageSize?: number }
      | undefined;
    assert.equal(payload?.page, 1);
    assert.equal(payload?.pageSize, 50);
    assert.equal(
      (
        await page.locator(".application-inbox__selection-count").textContent()
      )?.trim(),
      "0 ứng viên được chọn",
    );
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Application Inbox search waits 300 ms, sends PII only in request state, and leaves URL/history unchanged", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") pageErrors.push(message.text());
    });
    await setupPage(page, style, script);

    await page.evaluate(() => {
      window.__BULK_HARNESS_LOGS__ = [];
    });
    const initialUrl = page.url();
    const initialHistoryLength = await page.evaluate(() => history.length);
    const query = "Nguyễn An nhaycam@example.test";

    await page.clock.install({ time: new Date("2026-11-05T00:00:00Z") });
    await page.clock.pauseAt(new Date("2026-11-05T02:00:00Z"));
    await page.getByLabel("Tìm kiếm tên, email hoặc SĐT").fill(query);
    await page.clock.runFor(299);
    const earlyQueryCount = await page.evaluate(
      () =>
        window.__BULK_HARNESS_LOGS__?.filter(
          (entry) => entry.event === "queryInbox",
        ).length ?? 0,
    );
    assert.equal(earlyQueryCount, 0, "search must not dispatch before 300 ms");

    await page.clock.runFor(1);
    await page.waitForFunction(
      () =>
        window.__BULK_HARNESS_LOGS__?.some(
          (entry) => entry.event === "queryInbox",
        ) === true,
      undefined,
      { timeout: 2_000 },
    );
    const queryLog = await page.evaluate(() =>
      window.__BULK_HARNESS_LOGS__?.find(
        (entry) => entry.event === "queryInbox",
      ),
    );
    const payload = queryLog?.payload as
      | {
          filters?: { query?: string };
          page?: number;
          pageSize?: number;
        }
      | undefined;
    assert.equal(payload?.filters?.query, query);
    assert.equal(payload?.page, 1);
    assert.equal(payload?.pageSize, 25);
    assert.equal(page.url(), initialUrl);
    assert.equal(
      await page.evaluate(() => history.length),
      initialHistoryLength,
    );
    assert.equal(new URL(page.url()).search, "");
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});
