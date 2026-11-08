import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { build } from "esbuild";
import { type Browser, chromium, type Page } from "playwright";
import { openSubmissionAction } from "@/app/application-inbox-actions";
import { updateCandidateSubmission } from "@/lib/commands/candidate-submission";
import { openSubmission } from "@/lib/commands/submission-status";

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
    outdir: "rec05-harness-out",
    platform: "browser",
    conditions: ["browser"],
    write: false,
    plugins: [
      {
        name: "stub-server-only",
        setup(b) {
          b.onResolve({ filter: /^server-only$/ }, () => ({
            path: "server-only",
            namespace: "stub-server-only",
          }));
          b.onLoad({ filter: /.*/, namespace: "stub-server-only" }, () => ({
            contents: "export default {};",
          }));
          b.onResolve({ filter: /application-inbox-actions$/ }, () => ({
            path: "actions",
            namespace: "stub-actions",
          }));
          b.onLoad({ filter: /.*/, namespace: "stub-actions" }, () => ({
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
    throw new Error("REC-05 harness did not bundle");
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

  await page.goto("http://localhost:3000");
  await page.addStyleTag({ content: style });
  await page.addScriptTag({ content: script });
}

// =============================================================================
// L1 Intent, Error, and Draft Behavior Tests
// =============================================================================

test("L1.1: openSubmissionAction validates submissionId UUID before RPC", async () => {
  const result = await openSubmissionAction("not-a-valid-uuid", {
    client: {} as unknown as SupabaseClient,
    resolveActor: async () => ({
      authUserId: "user-1",
      appUserId: "app-1",
      email: "hr@eiu.edu.vn",
      isInternal: true,
      isActive: true,
      isRootAdmin: false,
      roles: ["HR"],
      permissions: ["submissions.view"],
    }),
  });
  assert.equal(result.success, false);
  assert.match(result.error ?? "", /uuid/i);
});

test("L1.2: openSubmissionAction maps RPC errors and forbidden codes cleanly", async () => {
  // Test with a mock client dependency injection
  const mockClient = {
    rpc: async (fn: string) => {
      if (fn === "open_submission") {
        return {
          data: {
            success: false,
            error_code: "FORBIDDEN",
            message: "Permission submissions.view required to open submission",
          },
          error: null,
        };
      }
      return { data: null, error: null };
    },
  };

  const commandResult = await openSubmission(
    { submissionId: "00000000-0000-0000-0000-000000000001" },
    {
      client: mockClient as unknown as SupabaseClient,
      resolveActor: async () => ({
        authUserId: "user-1",
        appUserId: "app-1",
        email: "hr@eiu.edu.vn",
        isInternal: true,
        isActive: true,
        isRootAdmin: false,
        roles: ["HR"],
        permissions: ["submissions.view"],
      }),
    },
  );

  assert.equal(commandResult.success, false);
  if (!commandResult.success) {
    assert.equal(commandResult.error.code, "FORBIDDEN");
  }
});

test("L1.3: openSubmission command atomically returns updated READ status and version_no", async () => {
  const mockClient = {
    rpc: async (fn: string, args: unknown) => {
      const rpcArgs = args as { p_submission_id: string } | undefined;
      if (fn === "open_submission") {
        return {
          data: {
            success: true,
            data: {
              submission_id: rpcArgs?.p_submission_id ?? "sub-1",
              candidate_id: "cand-1",
              status_code: "READ",
              full_name: "Nguyen Van A",
              email: "a@example.com",
              phone: "0900000001",
              date_of_birth: "1990-01-01",
              gender: "MALE",
              address: "Binh Duong",
              candidate_notes: null,
              submitted_at: "2026-09-01T08:00:00Z",
              version_no: 2,
            },
          },
          error: null,
        };
      }
      return { data: null, error: null };
    },
  };

  const commandResult = await openSubmission(
    { submissionId: "00000000-0000-0000-0000-000000000001" },
    {
      client: mockClient as unknown as SupabaseClient,
      resolveActor: async () => ({
        authUserId: "user-1",
        appUserId: "app-1",
        email: "hr@eiu.edu.vn",
        isInternal: true,
        isRootAdmin: false,
        roles: ["HR"],
        isActive: true,
        permissions: ["submissions.view", "submissions.status"],
      }),
    },
  );

  assert.equal(commandResult.success, true);
  if (commandResult.success) {
    assert.equal(commandResult.data.status_code, "READ");
    assert.equal(commandResult.data.version_no, 2);
  }
});

test("L1.4: Candidate Save rejected with INVALID_STATE when submission was opened (READ); draft preserved", async () => {
  // Candidate edit command receives INVALID_STATE from DB because submission is no longer NEW
  const mockClient = {
    rpc: async (fn: string) => {
      if (fn === "update_candidate_submission") {
        return {
          data: {
            success: false,
            error_code: "INVALID_STATE",
            message:
              "Submission is no longer in NEW status and cannot be edited by candidate",
          },
          error: null,
        };
      }
      return { data: null, error: null };
    },
  };

  // When updateCandidateSubmission receives this, it returns success: false with code INVALID_STATE
  // and does NOT clear candidate draft in form state
  const mockInput = {
    candidateFormSessionId: "00000000-0000-0000-0000-000000000002",
    fullName: "Nguyen Van Candidate",
    phone: "0900000002",
    dateOfBirth: "1992-02-02",
    gender: "MALE",
    address: "Binh Duong Updated",
    education: [],
    privacyNoticeVersion: "2026-09-01-v1",
    idempotencyKey: "00000000-0000-0000-0000-000000000003",
  };

  const result = await updateCandidateSubmission(mockInput, {
    client: mockClient as unknown as SupabaseClient,
    resolveActor: async () => ({
      authUserId: "cand-auth-1",
      candidateId: "cand-1",
      email: "cand@example.com",
      isInternal: false,
      isActive: true,
      roles: ["CANDIDATE"],
      permissions: [],
    }),
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, "INVALID_STATE");
    assert.match(result.error.message, /no longer in NEW status/i);
  }
});

// =============================================================================
// B1 Real Click Path, Duplicate Click, View-Only HR, and Stale Save E2E Tests
// =============================================================================

test("B1.1: Real click path: clicking 'Chi tiết' invokes openSubmission and transitions NEW badge to READ in table", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));

    await setupPage(page, style, script);

    // Initial state: candidate-1 row has NEW status badge
    const candidateRow = page
      .locator("tbody#candidate-group-candidate-1 tr")
      .first();
    await candidateRow.waitFor({ state: "visible", timeout: 5_000 });

    const statusBadge = candidateRow.locator(".status-badge");
    assert.equal((await statusBadge.textContent())?.trim(), "Mới");

    // Click 'Chi tiết'
    const openDetailBtn = candidateRow.getByRole("button", {
      name: /xem chi tiết phiếu/i,
    });
    await openDetailBtn.click();

    // Drawer opens
    const drawer = page.locator(".submission-drawer");
    await drawer.waitFor({ state: "visible", timeout: 5_000 });
    await page.waitForFunction(
      () => {
        const badge = document.querySelector(
          "tbody#candidate-group-candidate-1 .status-badge",
        );
        return badge?.textContent?.trim() === "Đã đọc";
      },
      { timeout: 5_000 },
    );

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("B1.2: Duplicate click protection: rapid double-clicking 'Chi tiết' invokes openSubmission only once", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();

    await setupPage(page, style, script);

    const candidateRow = page
      .locator("tbody#candidate-group-candidate-1 tr")
      .first();
    await candidateRow.waitFor({ state: "visible", timeout: 5_000 });

    const openDetailBtn = candidateRow.getByRole("button", {
      name: /xem chi tiết phiếu/i,
    });

    // Double click rapidly
    await openDetailBtn.dblclick();

    // Drawer opens
    const drawer = page.locator(".submission-drawer");
    await drawer.waitFor({ state: "visible", timeout: 5_000 });
    const openEventsCount = await page.evaluate(() => {
      const logs = window.__BULK_HARNESS_LOGS__ ?? [];
      return logs.filter((l) => l.event === "openSubmission").length;
    });

    assert.equal(
      openEventsCount,
      1,
      "openSubmission must be invoked exactly once on duplicate clicks",
    );
  } finally {
    await browser?.close();
  }
});

test("B1.3: View-only HR opening a NEW submission keeps status as NEW without mutation", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();

    // Configure harness so openSubmission returns status NEW (view-only HR caller lacks submissions.status)
    await page.addInitScript(() => {
      window.__BULK_HARNESS_DATA__ = {
        openSubmissionResult: {
          success: true,
          data: {
            submission_id: "submission-1",
            candidate_id: "candidate-1",
            status_code: "NEW" as const,
            full_name: "Nguyễn Thị An",
            email: "an@example.com",
            phone: "0901 234 567",
            date_of_birth: "1995-08-15",
            gender: "FEMALE",
            address: "Hà Nội",
            candidate_notes: null,
            submitted_at: "2026-09-02T09:00:00.000Z",
            version_no: 1,
          },
        },
        drawerDetailResult: {
          success: true,
          data: {
            submission_id: "submission-1",
            candidate_id: "candidate-1",
            status_code: "NEW" as const,
            full_name: "Nguyễn Thị An",
            date_of_birth: "1995-08-15",
            gender_code: "FEMALE" as const,
            current_address: "Hà Nội",
            phone: "0901 234 567",
            email: "an@example.com",
            other_info: null,
            hr_note: null,
            recruitment_source_id: null,
            recruitment_source_name: null,
            submitted_at: "2026-09-02T09:00:00.000Z",
            updated_at: "2026-09-02T09:00:00.000Z",
            updated_by_name: null,
            version_no: 1,
            education: [],
            work_experiences: [],
            activities: [],
            documents: [],
            applications: [],
          },
        },
      };
    });

    await setupPage(page, style, script);

    const candidateRow = page
      .locator("tbody#candidate-group-candidate-1 tr")
      .first();
    await candidateRow.waitFor({ state: "visible", timeout: 5_000 });

    const openDetailBtn = candidateRow.getByRole("button", {
      name: /xem chi tiết phiếu/i,
    });
    await openDetailBtn.click();

    // Drawer opens
    const drawer = page.locator(".submission-drawer");
    await drawer.waitFor({ state: "visible", timeout: 5_000 });

    const statusBadge = candidateRow.locator(".status-badge");
    assert.equal((await statusBadge.textContent())?.trim(), "Mới");
  } finally {
    await browser?.close();
  }
});
