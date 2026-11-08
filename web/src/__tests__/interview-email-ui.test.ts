import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { type Browser, chromium, type Page } from "playwright";
import type { EmailHistoryEntry } from "@/lib/commands/email-commands";
import {
  emailHistoryStatusTone,
  emailHistoryTimestamp,
  formatEmailHistoryRecipients,
  validateEmailHistoryDeletion,
} from "@/lib/interview/email-ui";

const baseHistory: EmailHistoryEntry = {
  email_history_id: "10000000-0000-0000-0000-000000000001",
  interview_id: "20000000-0000-0000-0000-000000000001",
  email_type: "INTERVIEW_INVITATION",
  environment_code: "TEST",
  recipients: { to: ["candidate@example.com"], cc: ["audit@example.com"] },
  subject: "Interview invitation",
  template_version: "test-1",
  sent_at: "2026-09-16T10:00:00.000Z",
  created_at: "2026-09-16T09:59:00.000Z",
  status_code: "SENT",
  error_code: null,
};

async function bundleHarness() {
  const actionsMock = resolve(
    process.cwd(),
    "src/__tests__/fixtures/interview-actions-browser-mock.ts",
  );
  const bundle = await build({
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
    absWorkingDir: process.cwd(),
    bundle: true,
    entryPoints: ["src/__tests__/fixtures/interview-email-ui-harness.tsx"],
    format: "iife",
    outdir: "interview-email-ui-fixture",
    platform: "browser",
    conditions: ["browser"],
    write: false,
    plugins: [
      {
        name: "interview-actions-browser-mock",
        setup(esbuild) {
          esbuild.onResolve(
            { filter: /^@\/app\/interviews\/actions$/ },
            () => ({ path: actionsMock }),
          );
        },
      },
    ],
  });
  const script = bundle.outputFiles.find((file) =>
    file.path.endsWith(".js"),
  )?.text;
  const style = bundle.outputFiles.find((file) =>
    file.path.endsWith(".css"),
  )?.text;
  if (!script || !style)
    throw new Error(
      "Interview email browser acceptance fixture did not bundle",
    );
  return { script, style };
}

async function openHarness(
  browser: Browser,
  assets: { script: string; style: string },
  mode: "page" | "preview-stale" | "history",
): Promise<{ page: Page; errors: string[] }> {
  const page = await browser.newPage({
    viewport: { width: 1280, height: 900 },
  });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  await page.route("http://localhost/harness", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "text/html",
      body: '<div id="root"></div>',
    });
  });
  await page.goto("http://localhost/harness");
  await page.evaluate((value) => {
    document.body.dataset.harness = value;
  }, mode);
  await page.addStyleTag({ content: assets.style });
  await page.addScriptTag({ content: assets.script });
  await page
    .locator(`[data-harness-ready="${mode}"]`)
    .waitFor({ state: "attached", timeout: 5_000 });
  return { page, errors };
}

test("email history UI maps only accepted completed statuses", () => {
  assert.equal(emailHistoryStatusTone("SENT"), "success");
  assert.equal(emailHistoryStatusTone("FAILED"), "danger");
  assert.equal(emailHistoryStatusTone("CANCELLED"), "warning");
  assert.equal(emailHistoryStatusTone("ABANDONED"), "neutral");
});

test("email history UI formats authoritative recipients and timestamps", () => {
  assert.equal(
    formatEmailHistoryRecipients(baseHistory.recipients),
    "candidate@example.com, audit@example.com",
  );
  assert.equal(emailHistoryTimestamp(baseHistory), baseHistory.sent_at);
  assert.equal(
    emailHistoryTimestamp({ ...baseHistory, sent_at: null }),
    baseHistory.created_at,
  );
});

test("delete validation enforces TEST environment and WRONG_RECORD reason", () => {
  assert.equal(validateEmailHistoryDeletion("TEST_RECORD", "", true), null);
  assert.match(
    validateEmailHistoryDeletion("TEST_RECORD", "", false) ?? "",
    /môi trường TEST/i,
  );
  assert.match(
    validateEmailHistoryDeletion("WRONG_RECORD", "   ", false) ?? "",
    /yêu cầu lý do/i,
  );
  assert.equal(
    validateEmailHistoryDeletion(
      "WRONG_RECORD",
      "Wrong operational record",
      false,
    ),
    null,
  );
  assert.match(
    validateEmailHistoryDeletion("WRONG_RECORD", "x".repeat(1001), false) ?? "",
    /1000/,
  );
});

test("InterviewPage supports multi-row preview-fenced bulk email without participant subsetting", {
  timeout: 120_000,
}, async () => {
  const assets = await bundleHarness();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const { page, errors } = await openHarness(browser, assets, "page");

    await page.getByLabel("Chọn Nguyễn Thị An").check();
    assert.equal(
      await page
        .getByRole("button", { name: "Tạo lịch / Chi tiết" })
        .isDisabled(),
      false,
    );
    await page.getByLabel("Chọn Trần Minh Bình").check();
    assert.equal(
      await page
        .getByRole("button", { name: "Tạo lịch / Chi tiết" })
        .isDisabled(),
      true,
      "single-Interview lifecycle actions must disable while multiple rows are selected",
    );

    await page
      .getByText("2 Interview đã chọn cho email", { exact: true })
      .waitFor({ state: "visible" });
    await page
      .getByRole("button", { name: "Gửi thư ứng viên đã chọn" })
      .click();

    const candidateDialog = page.getByRole("dialog", {
      name: "Bản xem trước email ứng viên — 2 Interview",
    });
    await candidateDialog.waitFor({ state: "visible" });
    assert.equal(
      await candidateDialog.locator("[data-interview-id]").count(),
      2,
    );
    await candidateDialog
      .getByText("an@example.com", { exact: true })
      .waitFor();
    await candidateDialog
      .getByText("binh@example.com", { exact: true })
      .waitFor();
    assert.match(
      await candidateDialog.innerText(),
      /Server body — Nguyễn Thị An/,
    );
    assert.match(
      await candidateDialog.innerText(),
      /Server body — Trần Minh Bình/,
    );

    const candidatePreviewCalls = await page.evaluate(
      () => window.__interviewEmailHarness?.previewCalls ?? [],
    );
    assert.equal(candidatePreviewCalls.length, 2);
    assert.deepEqual(
      candidatePreviewCalls.map((call) => call.emailType),
      ["INTERVIEW_INVITATION", "INTERVIEW_INVITATION"],
    );

    await candidateDialog
      .getByRole("button", { name: "Xác nhận gửi 2 email" })
      .click();
    await candidateDialog
      .getByText("Đã đưa 2 email vào hàng đợi gửi thư.", { exact: true })
      .waitFor({ state: "visible" });

    const bulkCalls = await page.evaluate(
      () => window.__interviewEmailHarness?.bulkCalls ?? [],
    );
    assert.equal(bulkCalls.length, 1);
    const bulkCall = bulkCalls[0];
    assert.ok(bulkCall);
    assert.equal(bulkCall.requests.length, 2);
    for (const request of bulkCall.requests) {
      assert.deepEqual(Object.keys(request).sort(), [
        "application_id",
        "email_type",
        "interview_id",
        "preview_fingerprint",
        "submission_id",
      ]);
      assert.equal(request.preview_fingerprint.length, 64);
      assert.equal("participantIds" in request, false);
      assert.equal("recipientIds" in request, false);
    }
    assert.match(
      bulkCall.idempotencyKey,
      /^[0-9a-f-]{36}$/i,
      "bulk action must receive a client-generated UUID idempotency key",
    );
    assert.equal(
      await page.evaluate(
        () => window.__interviewEmailHarness?.interviewStatusMutations ?? -1,
      ),
      0,
      "email send must not mutate Interview schedule status",
    );

    await candidateDialog
      .getByRole("button", { name: "Đóng", exact: true })
      .click();
    await candidateDialog.waitFor({ state: "detached" });
    await page
      .getByRole("button", { name: "Gửi thư người tham dự đã chọn" })
      .click();
    const participantDialog = page.getByRole("dialog", {
      name: "Bản xem trước email người tham dự — 2 Interview",
    });
    await participantDialog.waitFor({ state: "visible" });
    await participantDialog
      .getByText("interviewer.one@example.com", { exact: true })
      .waitFor();
    await participantDialog
      .getByText("interviewer.two@example.com", { exact: true })
      .waitFor();
    const allPreviewCalls = await page.evaluate(
      () => window.__interviewEmailHarness?.previewCalls ?? [],
    );
    assert.deepEqual(
      allPreviewCalls.slice(-2).map((call) => call.emailType),
      ["INTERVIEW_PARTICIPANT_INVITATION", "INTERVIEW_PARTICIPANT_INVITATION"],
    );

    await participantDialog
      .getByRole("button", { name: "Đóng", exact: true })
      .click();
    await page
      .locator(".interview-row-actions button[popovertarget]")
      .first()
      .click();
    await page
      .getByRole("button", { name: "Gửi thư ứng viên Nguyễn Thị An" })
      .waitFor({ state: "visible" });
    await page
      .getByRole("button", { name: "Gửi thư người tham dự Vòng 1" })
      .waitFor({ state: "visible" });
    assert.deepEqual(errors, [], "page bulk-email browser console/page errors");
    await page.close();
  } finally {
    await browser?.close();
  }
});

test("preview dialog retains fingerprint, refreshes STALE_PREVIEW, and queues without status mutation", {
  timeout: 120_000,
}, async () => {
  const assets = await bundleHarness();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const { page, errors } = await openHarness(
      browser,
      assets,
      "preview-stale",
    );
    const dialog = page.getByRole("dialog", {
      name: "Bản xem trước email — Ứng viên",
    });
    await dialog.waitFor({ state: "visible" });
    await dialog.getByText("an@example.com", { exact: true }).waitFor();
    assert.match(await dialog.innerText(), /Server subject — Nguyễn Thị An/);
    assert.match(await dialog.innerText(), /Server body — Nguyễn Thị An/);

    await dialog.getByRole("button", { name: "Xác nhận gửi" }).click();
    await dialog
      .getByText(
        "Thông tin phỏng vấn đã thay đổi, vui lòng xem lại bản xem trước.",
        { exact: true },
      )
      .waitFor({ state: "visible" });

    const staleState = await page.evaluate(() => ({
      previewCalls: window.__interviewEmailHarness?.previewCalls ?? [],
      previewFingerprints:
        window.__interviewEmailHarness?.previewFingerprints ?? [],
      enqueueCalls: window.__interviewEmailHarness?.enqueueCalls ?? [],
    }));
    assert.equal(staleState.previewCalls.length, 2);
    assert.equal(staleState.previewFingerprints.length, 2);
    assert.equal(staleState.enqueueCalls.length, 1);
    assert.equal(
      staleState.enqueueCalls[0]?.request.preview_fingerprint,
      staleState.previewFingerprints[0],
      "first enqueue must carry the fingerprint the user reviewed",
    );
    assert.notEqual(
      staleState.previewFingerprints[0],
      staleState.previewFingerprints[1],
      "STALE_PREVIEW refresh must produce a new preview fingerprint in the harness",
    );

    await dialog.getByRole("button", { name: "Xác nhận gửi" }).click();
    await page.waitForFunction(
      () => (window.__interviewEmailHarness?.queuedNotices ?? 0) === 1,
    );
    const finalState = await page.evaluate(() => ({
      queuedNotices: window.__interviewEmailHarness?.queuedNotices ?? 0,
      previewFingerprints:
        window.__interviewEmailHarness?.previewFingerprints ?? [],
      enqueueCalls: window.__interviewEmailHarness?.enqueueCalls ?? [],
      statusMutations:
        window.__interviewEmailHarness?.interviewStatusMutations ?? -1,
    }));
    assert.equal(finalState.queuedNotices, 1);
    assert.equal(finalState.enqueueCalls.length, 2);
    assert.equal(
      finalState.enqueueCalls[1]?.request.preview_fingerprint,
      finalState.previewFingerprints[1],
      "second confirmation must use the refreshed fingerprint, not the stale one",
    );
    assert.equal(finalState.statusMutations, 0);
    assert.deepEqual(errors, [], "preview browser console/page errors");
    await page.close();
  } finally {
    await browser?.close();
  }
});

test("history drawer renders completed statuses and executes validated deletion behavior", {
  timeout: 120_000,
}, async () => {
  const assets = await bundleHarness();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const { page, errors } = await openHarness(browser, assets, "history");
    const drawer = page.getByRole("dialog", {
      name: "Lịch sử gửi thư — Nguyễn Thị An — Vòng 1",
    });
    await drawer.waitFor({ state: "visible" });

    assert.deepEqual(
      await drawer.locator(".ui-status-badge").allTextContents(),
      ["SENT", "FAILED", "CANCELLED", "ABANDONED"],
    );
    assert.equal(
      (await drawer.locator(".ui-status-badge").allTextContents()).includes(
        "QUEUED",
      ),
      false,
    );
    await drawer.getByLabel("Chọn tất cả Email History").check();
    await drawer.getByRole("button", { name: "Xóa đã chọn (4)" }).click();

    const deleteDialog = page.getByRole("dialog", {
      name: "Xóa Email History",
    });
    await deleteDialog.waitFor({ state: "visible" });
    assert.match(
      await deleteDialog.innerText(),
      /security audit đã ghi nhận thao tác vẫn bất biến/i,
    );
    const classification = deleteDialog.getByLabel("Phân loại xóa");
    const testRecordOption = classification.locator(
      'option[value="TEST_RECORD"]',
    );
    assert.equal(
      await testRecordOption.evaluate((option) =>
        option.hasAttribute("disabled"),
      ),
      true,
      "TEST_RECORD must be unavailable for a mixed TEST/PRODUCTION selection",
    );
    assert.equal(
      await classification.inputValue(),
      "WRONG_RECORD",
      "mixed TEST/PRODUCTION selection must default to WRONG_RECORD",
    );
    const deleteButton = deleteDialog.getByRole("button", {
      name: "Xóa 4 bản ghi",
    });
    assert.equal(await deleteButton.isDisabled(), true);
    await deleteDialog
      .getByLabel("Lý do xóa")
      .fill("  Wrong imported records  ");
    assert.equal(await deleteButton.isDisabled(), false);
    await deleteButton.click();

    await drawer
      .getByText(
        "Đã xóa 4 bản ghi Email History. Security audit vẫn được giữ nguyên.",
        { exact: true },
      )
      .waitFor({ state: "visible" });
    const deleteCalls = await page.evaluate(
      () => window.__interviewEmailHarness?.deleteCalls ?? [],
    );
    assert.equal(deleteCalls.length, 4);
    assert.ok(
      deleteCalls.every(
        (call) =>
          call.classification === "WRONG_RECORD" &&
          call.reason === "Wrong imported records",
      ),
    );
    assert.deepEqual(errors, [], "history browser console/page errors");
    await page.close();
  } finally {
    await browser?.close();
  }
});
