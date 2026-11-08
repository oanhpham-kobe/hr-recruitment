import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { type Browser, chromium, type Page } from "playwright";

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
    outdir: "application-inbox-bulk-fixture",
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
            contents: "module.exports = {};",
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
    throw new Error("Application Inbox bulk fixture did not bundle");
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

test("Application Inbox bulk toolbar appears for selection, disables on 0, and handles Select All", {
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

    await page
      .locator(".application-inbox__bulk-toolbar")
      .waitFor({ state: "attached", timeout: 5_000 });
    assert.deepEqual(pageErrors, []);
    assert.equal(
      await page.locator(".application-inbox__bulk-toolbar").isVisible(),
      false,
    );

    const selectionCount = page.locator(".application-inbox__selection-count");
    await assert.equal(
      (await selectionCount.textContent())?.trim(),
      "0 ứng viên được chọn",
    );

    const markNewBtn = statusAction(page, "NEW");
    const markReadBtn = statusAction(page, "READ");
    const inactiveBtn = page.getByRole("button", {
      name: "Ngừng hoạt động",
      includeHidden: true,
    });
    const reactivateBtn = page.getByRole("button", {
      name: "Kích hoạt lại",
      includeHidden: true,
    });

    // All 4 bulk buttons must be disabled when 0 candidates are selected
    assert.equal(await markNewBtn.isDisabled(), true);
    assert.equal(await markReadBtn.isDisabled(), true);
    assert.equal(await inactiveBtn.isDisabled(), true);
    assert.equal(await reactivateBtn.isDisabled(), true);

    // Select candidate 1
    const cand1Checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Nguyễn Thị An",
    });
    await cand1Checkbox.click();
    assert.equal(
      await page.locator(".application-inbox__bulk-toolbar").isVisible(),
      true,
    );
    assert.equal(await cand1Checkbox.isChecked(), true);
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "1 ứng viên được chọn",
    );

    // Buttons are now enabled
    assert.equal(await markNewBtn.isDisabled(), false);
    assert.equal(await markReadBtn.isDisabled(), false);
    assert.equal(await inactiveBtn.isDisabled(), false);
    assert.equal(await reactivateBtn.isDisabled(), false);

    // Select candidate 2
    const cand2Checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Trần Minh Bình",
    });
    await cand2Checkbox.click();
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "2 ứng viên được chọn",
    );

    // Click Select All in the table header to select all 3
    const selectAllCheckbox = page.getByRole("checkbox", {
      name: "Chọn tất cả Candidate trên trang này",
    });
    await selectAllCheckbox.click();
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "3 ứng viên được chọn",
    );

    // Click Select All again to deselect all
    await selectAllCheckbox.click();
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "0 ứng viên được chọn",
    );
    assert.equal(await markNewBtn.isDisabled(), true);

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Application Inbox bulk Mark NEW/READ forwards row-bound tokens and blocks candidates with active applications", {
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

    await page
      .locator(".application-inbox__bulk-toolbar")
      .waitFor({ state: "attached", timeout: 5_000 });

    // Candidate 3 has hasApplication: true
    const cand3Checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Lê Văn Cường",
    });
    await cand3Checkbox.click();

    const markNewBtn = statusAction(page, "NEW");
    await markNewBtn.click();

    // Client guard blocks submission and shows accessible alert
    const alertBanner = page.locator(
      ".application-inbox__feedback-banner--error",
    );
    await alertBanner.waitFor({ state: "visible", timeout: 5_000 });
    assert.equal(await alertBanner.getAttribute("role"), "alert");
    assert.match(
      (await alertBanner.textContent()) ?? "",
      /Không thể chuyển trạng thái Mới\/Đã đọc cho Ứng viên đã có Application/i,
    );

    // Deselect candidate 3, select candidates 1 & 2 (both hasApplication: false)
    await cand3Checkbox.click();
    await page
      .getByRole("checkbox", { name: "Chọn Candidate Nguyễn Thị An" })
      .click();
    await page
      .getByRole("checkbox", { name: "Chọn Candidate Trần Minh Bình" })
      .click();

    const markReadBtn = statusAction(page, "READ");
    await markReadBtn.click();

    // Verify success banner and action payload with exact row-bound tokens
    const statusBanner = page.locator(
      ".application-inbox__feedback-banner--success",
    );
    await statusBanner.waitFor({ state: "visible", timeout: 5_000 });
    assert.equal(await statusBanner.getAttribute("role"), "status");
    assert.match(
      (await statusBanner.textContent()) ?? "",
      /Đã chuyển trạng thái 2 Phiếu sang Đã đọc thành công/i,
    );

    // Check log in harness window
    const logs = await page.evaluate(
      () =>
        (window as unknown as { __BULK_HARNESS_LOGS__: unknown[] })
          .__BULK_HARNESS_LOGS__,
    );
    assert.ok(Array.isArray(logs));
    const statusCall = logs.find(
      (l) => (l as { event: string }).event === "bulkSetStatus",
    ) as {
      payload: {
        items: Array<{
          candidateId: string;
          expectedLatestSubmissionId: string;
          expectedVersion: number;
        }>;
        statusCode: string;
      };
    };
    assert.ok(statusCall);
    assert.equal(statusCall.payload.statusCode, "READ");
    assert.deepEqual(statusCall.payload.items, [
      {
        candidateId: "candidate-1",
        expectedLatestSubmissionId: "submission-1",
        expectedVersion: 1,
      },
      {
        candidateId: "candidate-2",
        expectedLatestSubmissionId: "submission-2",
        expectedVersion: 3,
      },
    ]);

    // Selection was cleared after successful bulk action
    const selectionCount = page.locator(".application-inbox__selection-count");
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "0 ứng viên được chọn",
    );

    // Finding 2: candidate with inactive historical application is NOT blocked from Mark NEW/READ
    const page2 = await browser.newPage();
    const page2Errors: string[] = [];
    page2.on("pageerror", (error) => page2Errors.push(error.message));
    await page2.addInitScript(() => {
      const win = window as unknown as Record<string, unknown>;
      win.__BULK_HARNESS_DATA__ = {
        groups: [
          {
            candidateId: "candidate-inactive-app",
            email: "inactive-app@example.com",
            isCandidateActive: true,
            candidateVersionNo: 1,
            latestSubmissionId: "submission-inactive-app",
            latestSubmissionVersionNo: 2,
            hasActiveApplication: false,
            applications: [
              {
                applicationId: "app-old-1",
                is_active: false,
              },
            ],
            submissions: [
              {
                submissionId: "submission-inactive-app",
                candidateId: "candidate-inactive-app",
                status: "NEW",
                fullName: "Hoàng Văn Dũng",
                dateOfBirth: "1991-05-20",
                gender: "MALE",
                phone: "0933 456 789",
                hrNote: "Application cũ đã đóng",
                submittedAt: "2026-08-10T09:00:00.000Z",
                hasApplication: true,
                hasActiveApplication: false,
                applications: [
                  {
                    applicationId: "app-old-1",
                    is_active: false,
                  },
                ],
                versionNo: 2,
              },
            ],
          },
        ],
      };
    });

    await setupPage(page2, style, script);
    await page2
      .locator(".application-inbox__bulk-toolbar")
      .waitFor({ state: "attached", timeout: 5_000 });

    const dungCheckbox = page2.getByRole("checkbox", {
      name: "Chọn Candidate Hoàng Văn Dũng",
    });
    await dungCheckbox.click();

    // Mark READ on candidate with historical inactive application succeeds (not blocked)
    const markReadBtn2 = statusAction(page2, "READ");
    await markReadBtn2.click();

    const successBanner = page2.locator(
      ".application-inbox__feedback-banner--success",
    );
    await successBanner.waitFor({ state: "visible", timeout: 5_000 });
    assert.match(
      (await successBanner.textContent()) ?? "",
      /Đã chuyển trạng thái 1 Phiếu sang Đã đọc thành công/i,
    );

    assert.deepEqual(page2Errors, []);
    await page2.close();
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Application Inbox bulk Inactive opens accessible confirmation dialog, traps Tab focus, dismisses on Escape, and restores focus", {
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

    await page
      .locator(".application-inbox__bulk-toolbar")
      .waitFor({ state: "attached", timeout: 5_000 });

    // Select candidate 1
    await page
      .getByRole("checkbox", { name: "Chọn Candidate Nguyễn Thị An" })
      .click();

    const inactiveBtn = page.getByRole("button", {
      name: "Ngừng hoạt động",
      includeHidden: true,
    });
    await inactiveBtn.focus();
    await inactiveBtn.click();

    // Accessible confirmation dialog opens
    const dialog = page.locator('.bulk-confirm-overlay[role="dialog"]');
    await dialog.waitFor({ state: "visible", timeout: 5_000 });
    assert.equal(await dialog.getAttribute("aria-modal"), "true");
    assert.equal(
      await dialog.getAttribute("aria-labelledby"),
      "bulk-inactive-dialog-title",
    );
    assert.equal(
      await dialog.getAttribute("aria-describedby"),
      "bulk-inactive-dialog-desc",
    );

    // Focus landed on Cancel ("Hủy bỏ") button initially
    const cancelBtn = dialog.getByRole("button", { name: "Hủy bỏ" });
    const confirmBtn = dialog.getByRole("button", {
      name: "Xác nhận ngừng hoạt động",
    });
    assert.equal(
      await page.evaluate(
        () => document.activeElement?.textContent?.trim() === "Hủy bỏ",
      ),
      true,
    );

    // Keyboard focus trap: Tab moves to Confirm button
    await page.keyboard.press("Tab");
    assert.equal(
      await page.evaluate(
        () =>
          document.activeElement?.textContent?.trim() ===
          "Xác nhận ngừng hoạt động",
      ),
      true,
    );

    // Tab wraps back to Cancel button
    await page.keyboard.press("Tab");
    assert.equal(
      await page.evaluate(
        () => document.activeElement?.textContent?.trim() === "Hủy bỏ",
      ),
      true,
    );

    // Shift+Tab wraps back to Confirm button
    await page.keyboard.down("Shift");
    await page.keyboard.press("Tab");
    await page.keyboard.up("Shift");
    assert.equal(
      await page.evaluate(
        () =>
          document.activeElement?.textContent?.trim() ===
          "Xác nhận ngừng hoạt động",
      ),
      true,
    );

    // Escape key dismisses dialog and restores focus to "Ngừng hoạt động" trigger
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "detached", timeout: 5_000 });
    assert.equal(
      await page.evaluate(
        () => document.activeElement?.textContent?.trim() === "Ngừng hoạt động",
      ),
      true,
    );
    // Re-open dialog and test Cancel ("Hủy bỏ") button dismissal restores focus
    await inactiveBtn.click();
    await dialog.waitFor({ state: "visible", timeout: 5_000 });
    await cancelBtn.click();
    await dialog.waitFor({ state: "detached", timeout: 5_000 });
    assert.equal(
      await page.evaluate(
        () => document.activeElement?.textContent?.trim() === "Ngừng hoạt động",
      ),
      true,
    );

    // Re-open dialog with delay to verify pending focus trap and focus restoration
    await page.evaluate(() => {
      const win = window as unknown as Record<string, unknown>;
      win.__BULK_HARNESS_DATA__ = {
        delayActiveMs: 400,
      };
    });

    await inactiveBtn.click();
    await dialog.waitFor({ state: "visible", timeout: 5_000 });
    await confirmBtn.click();

    // Finding 3: While pending action is executing, buttons are disabled
    const pendingConfirmBtn = dialog.locator(".btn-danger");
    assert.equal(await pendingConfirmBtn.isDisabled(), true);
    assert.equal(await cancelBtn.isDisabled(), true);

    // Tab key must remain contained inside dialog container and NOT escape
    await page.keyboard.press("Tab");
    const isFocusInsideModal = await page.evaluate(() => {
      const active = document.activeElement;
      const dialog = document.querySelector(".bulk-confirm-dialog");
      return active === dialog || (dialog ? dialog.contains(active) : false);
    });
    assert.equal(isFocusInsideModal, true);

    // Dialog detached and success banner rendered
    await dialog.waitFor({ state: "detached", timeout: 5_000 });
    const statusBanner = page.locator(
      ".application-inbox__feedback-banner--success",
    );
    await statusBanner.waitFor({ state: "visible", timeout: 5_000 });
    assert.match(
      (await statusBanner.textContent()) ?? "",
      /Đã ngừng hoạt động 1 tài khoản Candidate thành công/i,
    );

    // Finding 4: When action completes and selection is cleared, focus is cleanly restored to stable element (not lost to body)
    const focusedTag = await page.evaluate(() =>
      document.activeElement?.tagName?.toLowerCase(),
    );
    assert.notEqual(focusedTag, "body");
    const isFocusOnStableElement = await page.evaluate(() => {
      const active = document.activeElement;
      return (
        active?.classList.contains("application-inbox__selection-count") ||
        active?.classList.contains("application-inbox")
      );
    });
    assert.equal(isFocusOnStableElement, true);
    // Log confirms payload
    const logs = await page.evaluate(
      () =>
        (window as unknown as { __BULK_HARNESS_LOGS__: unknown[] })
          .__BULK_HARNESS_LOGS__,
    );
    const activeCall = logs.find(
      (l) => (l as { event: string }).event === "bulkSetActive",
    ) as {
      payload: {
        items: Array<{ candidateId: string; expectedVersion: number }>;
        active: boolean;
      };
    };
    assert.ok(activeCall);
    assert.equal(activeCall.payload.active, false);
    assert.deepEqual(activeCall.payload.items, [
      { candidateId: "candidate-1", expectedVersion: 1 },
    ]);

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Application Inbox bulk Reactivate executes action and error banner renders accessible alert on failure", {
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

    await page
      .locator(".application-inbox__bulk-toolbar")
      .waitFor({ state: "attached", timeout: 5_000 });

    // Select candidate 3 (currently inactive)
    await page
      .getByRole("checkbox", { name: "Chọn Candidate Lê Văn Cường" })
      .click();

    const reactivateBtn = page.getByRole("button", {
      name: "Kích hoạt lại",
      includeHidden: true,
    });
    await reactivateBtn.click();

    // Success status
    const statusBanner = page.locator(
      ".application-inbox__feedback-banner--success",
    );
    await statusBanner.waitFor({ state: "visible", timeout: 5_000 });
    assert.match(
      (await statusBanner.textContent()) ?? "",
      /Đã kích hoạt lại 1 tài khoản Candidate thành công/i,
    );

    // Inject server error
    await page.evaluate(() => {
      (
        window as unknown as {
          __BULK_HARNESS_DATA__: Record<string, unknown>;
        }
      ).__BULK_HARNESS_DATA__ = {
        bulkActiveResult: {
          success: false,
          error: "Không thể kích hoạt lại tài khoản Candidate do phiên bản cũ.",
          code: "STALE_VERSION",
        },
      };
    });

    // Select candidate 2 and attempt reactivation
    await page
      .getByRole("checkbox", { name: "Chọn Candidate Trần Minh Bình" })
      .click();
    await reactivateBtn.click();

    // Accessible error banner displayed with role="alert"
    const alertBanner = page.locator(
      ".application-inbox__feedback-banner--error",
    );
    await alertBanner.waitFor({ state: "visible", timeout: 5_000 });
    assert.equal(await alertBanner.getAttribute("role"), "alert");
    assert.equal(await alertBanner.getAttribute("aria-live"), "assertive");
    assert.match(
      (await alertBanner.textContent()) ?? "",
      /Không thể kích hoạt lại tài khoản Candidate do phiên bản cũ/i,
    );

    // Check touch targets and typography
    const buttonBounds = await reactivateBtn.boundingBox();
    assert.ok(buttonBounds);
    assert.ok(buttonBounds.height >= 44);
    assert.ok(buttonBounds.width >= 44);

    const fontSize = await reactivateBtn.evaluate(
      (element) => window.getComputedStyle(element).fontSize,
    );
    assert.ok(Number.parseFloat(fontSize) >= 14);

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Application Inbox selection scope resets on filter change with accessible announcement and submits exact selection", {
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

    await page
      .locator(".application-inbox__bulk-toolbar")
      .waitFor({ state: "attached", timeout: 5_000 });

    const selectionCount = page.locator(".application-inbox__selection-count");

    // 1. Select candidate 1
    const cand1Checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Nguyễn Thị An",
    });
    await cand1Checkbox.click();
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "1 ứng viên được chọn",
    );

    // 2. Change search filter
    const searchInput = page.getByLabel("Tìm kiếm tên, email hoặc SĐT");
    await searchInput.fill("Bình");

    // 3. Selection must be reset to 0 with accessible announcement
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "0 ứng viên được chọn",
    );
    const notice = page.locator(".application-inbox__selection-notice");
    assert.match(
      (await notice.textContent()) ?? "",
      /Đã đặt lại danh sách chọn do thay đổi bộ lọc/i,
    );

    // Bulk buttons are disabled
    const markNewBtn = statusAction(page, "NEW");
    assert.equal(await markNewBtn.isDisabled(), true);

    // 4. Reset filter
    const clearFilterBtn = page.getByRole("button", {
      name: "Xóa tìm kiếm và bộ lọc",
    });
    if (await clearFilterBtn.isVisible()) {
      await clearFilterBtn.click();
    } else {
      await searchInput.fill("");
    }

    // 5. Select all candidates on the page
    const selectAllCheckbox = page.getByRole("checkbox", {
      name: "Chọn tất cả Candidate trên trang này",
    });
    await selectAllCheckbox.click();
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "3 ứng viên được chọn",
    );

    // Deselect candidate 3 (has active application) so bulk mark READ succeeds
    const cand3Checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Lê Văn Cường",
    });
    await cand3Checkbox.click();
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "2 ứng viên được chọn",
    );

    // 6. Bulk Mark READ submits exact announced selection (2 items)
    const markReadBtn = statusAction(page, "READ");
    await markReadBtn.click();

    const statusBanner = page.locator(
      ".application-inbox__feedback-banner--success",
    );
    await statusBanner.waitFor({ state: "visible", timeout: 5_000 });

    const logs = await page.evaluate(
      () =>
        (window as unknown as { __BULK_HARNESS_LOGS__: unknown[] })
          .__BULK_HARNESS_LOGS__,
    );
    const statusCalls = logs?.filter(
      (l) =>
        typeof l === "object" &&
        l !== null &&
        "event" in l &&
        l.event === "bulkSetStatus",
    );
    const lastCall = statusCalls?.[statusCalls.length - 1] as
      | { payload?: { items?: Array<{ candidateId?: string }> } }
      | undefined;
    assert.ok(lastCall);
    assert.equal(lastCall.payload?.items?.length, 2);
    assert.deepEqual(
      lastCall.payload?.items?.map((i) => i.candidateId),
      ["candidate-1", "candidate-2"],
    );

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Application Inbox drawer observed server updates (NEW->READ on open and HR note save) synchronize properly via onSubmissionUpdated and forward exact version", {
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

    // 1. Initial state: candidate-1 row has submission-1 with version 1 (unselected)
    const row = page.locator("#candidate-group-candidate-1");
    await row.waitFor({ state: "visible", timeout: 5_000 });
    assert.match((await row.textContent()) ?? "", /Mới/);

    // 2. Open submission in drawer via "Chi tiết" button
    const detailBtn = row.getByRole("button", { name: "Chi tiết" }).first();
    await detailBtn.click();

    const drawer = page.locator(".submission-drawer");
    await drawer.waitFor({ state: "visible", timeout: 5_000 });

    // Wait for drawer content to load (mock getSubmissionDetail returns version_no: 2, status: READ)
    await page
      .locator(".submission-drawer__header")
      .waitFor({ state: "visible", timeout: 5_000 });

    const detailSizes = await drawer
      .locator(
        "th, td, label, input, select, textarea, button, .wrap-anywhere, .meta, small, .drawer-doc-item__meta",
      )
      .evaluateAll((elements) =>
        elements.map((el) => Number.parseFloat(getComputedStyle(el).fontSize)),
      );
    assert.ok(
      detailSizes.length > 0 && detailSizes.every((size) => size >= 16),
      "Inline submission detail retains16px values, metadata and commands",
    );

    // Verify drawer subtitle shows status READ
    const subtitle = page.locator(".submission-drawer__subtitle");
    await subtitle.waitFor({ state: "visible", timeout: 5_000 });
    assert.match((await subtitle.textContent()) ?? "", /READ/);

    // 3. Edit HR note inside drawer and save
    const editBtn = page.getByRole("button", { name: "Chỉnh sửa" });
    await editBtn.click();

    const hrNoteTextarea = page.locator("#drawer-hr-note-input");
    await hrNoteTextarea.waitFor({ state: "visible", timeout: 5_000 });
    await hrNoteTextarea.fill("Ghi chú mới từ HR qua drawer");

    const saveBtn = page.getByRole("button", { name: "Lưu thay đổi" });
    await saveBtn.click();

    // Wait for edit mode to finish (edit button visible again)
    await editBtn.waitFor({ state: "visible", timeout: 5_000 });

    // 4. Close the drawer
    const closeBtn = page.getByRole("button", { name: "Đóng chi tiết phiếu" });
    await closeBtn.click();
    await drawer.waitFor({ state: "hidden", timeout: 5_000 });

    // 5. Verify table row reflects confirmed server observations (status READ and updated HR note)
    assert.match((await row.textContent()) ?? "", /Đã đọc/);
    assert.match(
      (await row.textContent()) ?? "",
      /Ghi chú mới từ HR qua drawer/,
    );

    // 6. Select candidate-1 row after drawer closed
    const checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Nguyễn Thị An",
    });
    await checkbox.click();
    assert.equal(await checkbox.isChecked(), true);

    // 7. Execute bulk Mark READ
    const markReadBtn = statusAction(page, "READ");
    await markReadBtn.click();

    const statusBanner = page.locator(
      ".application-inbox__feedback-banner--success",
    );
    await statusBanner.waitFor({ state: "visible", timeout: 5_000 });

    // 8. Verify bulk action forwarded exact observed version: 3 (not stale 1 or 2)
    const logs = await page.evaluate(
      () =>
        (
          window as unknown as {
            __BULK_HARNESS_LOGS__?: Array<{ event: string; payload?: unknown }>;
          }
        ).__BULK_HARNESS_LOGS__ ?? [],
    );
    const statusCalls = logs.filter((l) => l.event === "bulkSetStatus");
    const lastCall = statusCalls[statusCalls.length - 1];

    assert.ok(lastCall, "bulkSetStatus action must be called");
    const payload = lastCall.payload;
    assert.ok(payload && typeof payload === "object" && "items" in payload);
    const items = payload.items;
    assert.ok(Array.isArray(items) && items.length === 1);
    assert.deepEqual(items[0], {
      candidateId: "candidate-1",
      expectedLatestSubmissionId: "submission-1",
      expectedVersion: 3,
    });
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Opening a submission that fails detail load does NOT increment version in table or selection state", {
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

    // Configure harness to fail detail loading
    await page.evaluate(() => {
      window.__BULK_HARNESS_DATA__ = window.__BULK_HARNESS_DATA__ ?? {};
      window.__BULK_HARNESS_DATA__.drawerDetailResult = {
        success: false,
        error: "Lỗi kết nối khi tải chi tiết phiếu",
      };
    });

    const row = page.locator("#candidate-group-candidate-1");
    await row.waitFor({ state: "visible", timeout: 5_000 });
    assert.match((await row.textContent()) ?? "", /Mới/);

    // Open submission drawer via "Chi tiết"
    const detailBtn = row.getByRole("button", { name: "Chi tiết" }).first();
    await detailBtn.click();

    const drawer = page.locator(".submission-drawer");
    await drawer.waitFor({ state: "visible", timeout: 5_000 });

    // Verify error alert is displayed in drawer
    const errorAlert = drawer.locator(".submission-drawer__error");
    await errorAlert.waitFor({ state: "visible", timeout: 5_000 });
    assert.match(
      (await errorAlert.textContent()) ?? "",
      /Lỗi kết nối khi tải chi tiết phiếu/,
    );

    // Close the drawer
    const closeBtn = page.getByRole("button", { name: "Đóng chi tiết phiếu" });
    await closeBtn.click();
    await drawer.waitFor({ state: "hidden", timeout: 5_000 });

    // Verify table row still has original status NEW ("Mới")
    assert.match((await row.textContent()) ?? "", /Mới/);

    // Select candidate-1 row
    const checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Nguyễn Thị An",
    });
    await checkbox.click();
    assert.equal(await checkbox.isChecked(), true);

    // Execute bulk Mark READ
    const markReadBtn = statusAction(page, "READ");
    await markReadBtn.click();

    const statusBanner = page.locator(
      ".application-inbox__feedback-banner--success",
    );
    await statusBanner.waitFor({ state: "visible", timeout: 5_000 });
    // Verify bulk action forwarded original unincremented version: 1 (NO speculative increment!)
    const logs = await page.evaluate(
      () =>
        (
          window as unknown as {
            __BULK_HARNESS_LOGS__?: Array<{ event: string; payload?: unknown }>;
          }
        ).__BULK_HARNESS_LOGS__ ?? [],
    );
    const statusCalls = logs.filter((l) => l.event === "bulkSetStatus");
    const lastCall = statusCalls[statusCalls.length - 1];

    assert.ok(lastCall, "bulkSetStatus action must be called");
    const payload = lastCall.payload;
    assert.ok(payload && typeof payload === "object" && "items" in payload);
    const items = payload.items;
    assert.ok(Array.isArray(items) && items.length === 1);
    assert.deepEqual(items[0], {
      candidateId: "candidate-1",
      expectedLatestSubmissionId: "submission-1",
      expectedVersion: 1,
    });

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("Application Inbox bulk toolbar and table render and operate correctly at responsive viewport (768px tablet breakpoint)", {
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

    // Explicit responsive tablet viewport at 768px
    await page.setViewportSize({ width: 768, height: 1024 });
    await setupPage(page, style, script);

    const toolbar = page.locator(".application-inbox__bulk-toolbar");
    await toolbar.waitFor({ state: "attached", timeout: 5_000 });

    // Verify explicit observable flex-wrap behavior on toolbar and action group
    const toolbarFlexWrap = await toolbar.evaluate(
      (el) => window.getComputedStyle(el).flexWrap,
    );
    assert.equal(
      toolbarFlexWrap,
      "wrap",
      "Toolbar must have flex-wrap: wrap for responsive wrapping",
    );

    const actionsContainer = page.locator(".application-inbox__bulk-actions");
    const actionsFlexWrap = await actionsContainer.evaluate(
      (el) => window.getComputedStyle(el).flexWrap,
    );
    assert.equal(
      actionsFlexWrap,
      "wrap",
      "Bulk actions container must have flex-wrap: wrap for responsive wrapping",
    );

    // Verify selection count at 768px
    const selectionCount = page.locator(".application-inbox__selection-count");
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "0 ứng viên được chọn",
    );

    // Verify table scroll container is present and has horizontal overflow capability
    const tableScroll = page.locator(".application-inbox__table-scroll");
    await tableScroll.waitFor({ state: "visible", timeout: 5_000 });
    const scrollBox = await tableScroll.boundingBox();
    assert.ok(
      scrollBox,
      "Table scroll container bounding box must be available",
    );
    assert.ok(
      scrollBox.width <= 768,
      "Table scroll container width must fit within 768px viewport",
    );

    // Select candidate-1 via checkbox
    const checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Nguyễn Thị An",
    });
    await checkbox.click();
    assert.equal(await checkbox.isChecked(), true);
    assert.equal(
      (await selectionCount.textContent())?.trim(),
      "1 ứng viên được chọn",
    );

    // Verify touch targets >= 44x44px for bulk buttons at 768px
    const markReadBtn = statusAction(page, "READ");
    const markNewBtn = statusAction(page, "NEW");
    const inactiveBtn = page.getByRole("button", {
      name: "Ngừng hoạt động",
      includeHidden: true,
    });
    const reactivateBtn = page.getByRole("button", {
      name: "Kích hoạt lại",
      includeHidden: true,
    });

    for (const btn of [markReadBtn, markNewBtn, inactiveBtn, reactivateBtn]) {
      const box = await btn.boundingBox();
      assert.ok(box, "Button bounding box must be available");
      assert.ok(box.width >= 44, `Button width ${box.width} must be >= 44px`);
      assert.ok(
        box.height >= 44,
        `Button height ${box.height} must be >= 44px`,
      );
    }
    // Verify observable flex-wrap geometry: toolbar action controls wrap below selection count
    const countBox = await selectionCount.boundingBox();
    const actionsBox = await actionsContainer.boundingBox();
    assert.ok(countBox, "Selection count bounding box must be available");
    assert.ok(actionsBox, "Bulk actions bounding box must be available");
    assert.ok(
      actionsBox.y > countBox.y,
      `Bulk actions group (top ${actionsBox.y}) must wrap onto a subsequent line below selection count (top ${countBox.y})`,
    );

    // Execute bulk action at responsive viewport
    await markReadBtn.click();
    const successBanner = page.locator(
      ".application-inbox__feedback-banner--success",
    );
    await successBanner.waitFor({ state: "visible", timeout: 5_000 });
    assert.match(
      (await successBanner.textContent()) ?? "",
      /Đã chuyển trạng thái 1 Phiếu sang Đã đọc thành công/,
    );

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

function statusAction(page: Page, value: "NEW" | "READ") {
  const trigger = page.getByRole("button", {
    name: "Trạng thái đã chọn",
    exact: true,
    includeHidden: true,
  });
  return {
    boundingBox: () => trigger.boundingBox(),
    isDisabled: () => trigger.isDisabled(),
    isEnabled: () => trigger.isEnabled(),
    click: async () => {
      await trigger.click();
      await page
        .getByRole("menuitemradio", {
          name: value === "NEW" ? "Đánh dấu Mới" : "Đánh dấu Đã đọc",
          exact: true,
        })
        .click();
    },
  };
}
