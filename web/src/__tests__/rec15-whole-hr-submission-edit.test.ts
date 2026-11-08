import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { build } from "esbuild";
import { type Browser, chromium, type Page } from "playwright";
import { updateSubmissionAggregateAction } from "@/app/application-inbox-actions";
import { updateSubmissionAggregateByHr } from "@/lib/commands/submission-status";

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
    entryPoints: [
      "src/__tests__/fixtures/submission-detail-drawer-harness.tsx",
    ],
    format: "iife",
    outdir: "rec15-harness-out",
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
              export async function getSubmissionDetailAction() { return { success: false, error: 'stub' }; }
              export async function openSubmissionAction() { return { success: true }; }
              export async function updateSubmissionHrNoteAction() { return { success: false, error: 'stub' }; }
              export async function updateSubmissionAggregateAction() { return { success: true }; }
              export async function getRecruitmentSourcesAction() { return []; }
              export async function getQualificationLevelsAction() { return []; }
              export async function getDocumentSignedUrlAction() { return { success: false, error: 'stub' }; }
              export async function getAssignmentOptionsAction() { return { success: false, error: 'stub' }; }
              export async function createApplicationAction() { return { success: false, error: 'stub' }; }
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
    throw new Error("REC-15 harness did not bundle");
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
// L1: Server Action & Command Validation / Authorization Tests
// =============================================================================

test("L1.1: updateSubmissionAggregateAction validates UUID and positive expectedVersion", async () => {
  const testActorDeps = {
    client: {} as unknown as SupabaseClient,
    resolveActor: async () => ({
      authUserId: "user-1",
      appUserId: "app-1",
      email: "hr@eiu.edu.vn",
      isInternal: true,
      isActive: true,
      isRootAdmin: false,
      roles: ["HR"],
      permissions: ["submissions.view", "submissions.edit"],
    }),
  };

  const resultBadUuid = await updateSubmissionAggregateAction(
    {
      submissionId: "not-a-valid-uuid",
      expectedVersion: 1,
    },
    testActorDeps,
  );
  assert.equal(resultBadUuid.success, false);
  assert.match(resultBadUuid.error ?? "", /uuid/i);

  const resultBadVersion = await updateSubmissionAggregateAction(
    {
      submissionId: "00000000-0000-0000-0000-000000000001",
      expectedVersion: 0,
    },
    testActorDeps,
  );
  assert.equal(resultBadVersion.success, false);
  assert.match(resultBadVersion.error ?? "", /version/i);
});

test("L1.2: updateSubmissionAggregateByHr rejects caller without submissions.edit with FORBIDDEN", async () => {
  const commandResult = await updateSubmissionAggregateByHr(
    {
      submissionId: "00000000-0000-0000-0000-000000000001",
      expectedVersion: 1,
      fullName: "New Name",
    },
    {
      client: {} as unknown as SupabaseClient,
      resolveActor: async () => ({
        authUserId: "user-1",
        appUserId: "app-1",
        email: "viewonly@eiu.edu.vn",
        isInternal: true,
        isActive: true,
        isRootAdmin: false,
        roles: ["HR"],
        permissions: ["submissions.view"], // lacks submissions.edit!
      }),
    },
  );

  assert.equal(commandResult.success, false);
  if (!commandResult.success) {
    assert.equal(commandResult.error.code, "FORBIDDEN");
  }
});

test("L1.3: updateSubmissionAggregateByHr handles STALE_VERSION from RPC cleanly", async () => {
  const mockClient = {
    rpc: async (fn: string) => {
      if (fn === "update_submission_aggregate_by_hr") {
        return {
          data: {
            success: false,
            error_code: "STALE_VERSION",
            message: "Submission version mismatch; reload required",
          },
          error: null,
        };
      }
      return { data: null, error: null };
    },
  };

  const commandResult = await updateSubmissionAggregateByHr(
    {
      submissionId: "00000000-0000-0000-0000-000000000001",
      expectedVersion: 1,
      fullName: "Updated Name",
    },
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
        permissions: ["submissions.view", "submissions.edit"],
      }),
    },
  );

  assert.equal(commandResult.success, false);
  if (!commandResult.success) {
    assert.equal(commandResult.error.code, "STALE_VERSION");
  }
});

test("L1.4: updateSubmissionAggregateByHr executes and returns updated version and changed fields", async () => {
  let passedRpcArgs: unknown = null;
  const mockClient = {
    rpc: async (fn: string, args: unknown) => {
      if (fn === "update_submission_aggregate_by_hr") {
        passedRpcArgs = args;
        return {
          data: {
            success: true,
            submission_id: "00000000-0000-0000-0000-000000000001",
            version_no: 2,
            changed_fields: ["full_name", "hr_note", "education"],
          },
          error: null,
        };
      }
      return { data: null, error: null };
    },
  };

  const commandResult = await updateSubmissionAggregateByHr(
    {
      submissionId: "00000000-0000-0000-0000-000000000001",
      expectedVersion: 1,
      fullName: "Nguyen Van Updated",
      hrNote: "HR verified phone",
      education: [
        {
          periodText: "2015-2019",
          institutionName: "EIU",
          majorName: "Software Engineering",
          degreeName: "Bachelor",
          qualificationId: "qual-1",
        },
      ],
    },
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
        permissions: ["submissions.view", "submissions.edit"],
      }),
    },
  );

  assert.equal(commandResult.success, true);
  if (commandResult.success) {
    assert.equal(commandResult.data.version_no, 2);
    assert.deepEqual(commandResult.data.changed_fields, [
      "full_name",
      "hr_note",
      "education",
    ]);
  }
  const rpcArgs = passedRpcArgs as Record<string, unknown>;
  assert.equal(rpcArgs.p_full_name, "Nguyen Van Updated");
  assert.equal(rpcArgs.p_hr_note, "HR verified phone");
  assert.ok(Array.isArray(rpcArgs.p_education));
});

// =============================================================================
// B1: Rendered Browser Interaction Tests
// =============================================================================

test("B1.1: Entering edit mode renders editable profile, recruitment source, HR note, and education fields", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));

    await setupPage(page, style, script);

    // Open drawer via external button
    const openBtn = page.locator("#external-open-drawer");
    await openBtn.waitFor({ state: "visible", timeout: 5_000 });
    await openBtn.click();

    await page
      .locator(".submission-drawer")
      .waitFor({ state: "visible", timeout: 5_000 });

    // Enter edit mode
    const editBtn = page.locator(".submission-drawer__edit-btn");
    await editBtn.click();

    // Verify all edit inputs are visible and accessible
    await page
      .locator("#drawer-full-name-input")
      .waitFor({ state: "visible", timeout: 5_000 });
    await page
      .locator("#drawer-phone-input")
      .waitFor({ state: "visible", timeout: 5_000 });
    await page
      .locator("#drawer-dob-input")
      .waitFor({ state: "visible", timeout: 5_000 });
    await page
      .locator("#drawer-gender-select")
      .waitFor({ state: "visible", timeout: 5_000 });
    await page
      .locator("#drawer-address-input")
      .waitFor({ state: "visible", timeout: 5_000 });
    await page
      .locator("#drawer-source-select")
      .waitFor({ state: "visible", timeout: 5_000 });
    await page
      .locator("#drawer-hr-note-input")
      .waitFor({ state: "visible", timeout: 5_000 });

    // Verify verified email remains immutable
    const emailCell = page.locator("th:has-text('Email:') + td");
    assert.match((await emailCell.textContent()) ?? "", /Email đã xác minh/i);

    // Verify education add button is rendered
    const addEduBtn = page.locator(".drawer-add-edu-btn");
    assert.equal(await addEduBtn.isVisible(), true);

    // Verify footer has Cancel and Save Changes buttons
    const cancelBtn = page.locator(".submission-drawer__footer .btn-secondary");
    const saveBtn = page.locator(".submission-drawer__footer .btn-primary");
    assert.equal(await cancelBtn.isVisible(), true);
    assert.equal(await saveBtn.isVisible(), true);

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("B1.2: Cancel with unsaved edits prompts discard confirmation; confirming discard restores pre-edit state", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();

    await setupPage(page, style, script);

    const openBtn = page.locator("#external-open-drawer");
    await openBtn.waitFor({ state: "visible", timeout: 5_000 });
    await openBtn.click();

    await page
      .locator(".submission-drawer")
      .waitFor({ state: "visible", timeout: 5_000 });

    const editBtn = page.locator(".submission-drawer__edit-btn");
    await editBtn.click();

    // Modify full name and HR note to make dirty
    const fullNameInput = page.locator("#drawer-full-name-input");
    await fullNameInput.fill("Modified Candidate Name");

    // Click Cancel in footer
    const cancelBtn = page.locator(".submission-drawer__footer .btn-secondary");
    await cancelBtn.click();

    // Discard confirmation dialog appears
    const discardDialog = page.locator(".discard-confirm-dialog");
    await discardDialog.waitFor({ state: "visible", timeout: 5_000 });

    // Confirm discard
    const confirmDiscardBtn = page.locator(
      ".btn-danger:has-text('Hủy thay đổi')",
    );
    await confirmDiscardBtn.click();

    // Dialog closes and drawer returns to view mode with original name
    await discardDialog.waitFor({ state: "hidden", timeout: 5_000 });
    assert.equal(
      await page.locator(".submission-drawer__edit-btn").isVisible(),
      true,
    );

    const nameCell = page.locator("th:has-text('Họ và tên:') + td");
    assert.equal((await nameCell.textContent())?.trim(), "Nguyễn Văn A");
  } finally {
    await browser?.close();
  }
});

test("B1.3: Save commits aggregate updates, exits edit mode, and restores focus to Edit button", {
  timeout: 60_000,
}, async () => {
  const { script, style } = await getHarnessBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();

    await setupPage(page, style, script);

    const openBtn = page.locator("#external-open-drawer");
    await openBtn.waitFor({ state: "visible", timeout: 5_000 });
    await openBtn.click();

    await page
      .locator(".submission-drawer")
      .waitFor({ state: "visible", timeout: 5_000 });

    const editBtn = page.locator(".submission-drawer__edit-btn");
    await editBtn.click();

    // Modify phone number
    const phoneInput = page.locator("#drawer-phone-input");
    await phoneInput.fill("0909888777");

    // Click Save Changes in footer
    const saveBtn = page.locator(".submission-drawer__footer .btn-primary");
    await saveBtn.click();

    // Drawer exits edit mode
    await page
      .locator(".submission-drawer__edit-btn")
      .waitFor({ state: "visible", timeout: 5_000 });

    // Focus restored to edit button
    const activeId = await page.evaluate(
      () => document.activeElement?.className,
    );
    assert.match(activeId ?? "", /submission-drawer__edit-btn/);
  } finally {
    await browser?.close();
  }
});
