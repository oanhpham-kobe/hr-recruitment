import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { chromium } from "playwright";

async function bundleHistoryHarness() {
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
    outdir: "interview-email-history-reload-fixture",
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
    throw new Error("Email History reload fixture did not bundle");
  return { script, style };
}

test("Email History clears stale selection when reload fails", {
  timeout: 120_000,
}, async () => {
  const assets = await bundleHistoryHarness();
  const browser = await chromium.launch();
  try {
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
    await page.evaluate(() => {
      document.body.dataset.harness = "history";
    });
    await page.addStyleTag({ content: assets.style });
    await page.addScriptTag({ content: assets.script });
    await page
      .locator('[data-harness-ready="history"]')
      .waitFor({ state: "attached", timeout: 5_000 });

    const drawer = page.getByRole("dialog", {
      name: "Lịch sử gửi thư — Nguyễn Thị An — Vòng 1",
    });
    await drawer.getByText("Sent interview", { exact: true }).waitFor();

    const firstHistoryCheckbox = drawer.getByLabel(
      "Chọn Email History Sent interview",
    );
    await firstHistoryCheckbox.check();
    const deleteOne = drawer.getByRole("button", {
      name: "Xóa đã chọn (1)",
    });
    assert.equal(await deleteOne.isDisabled(), false);

    await page.evaluate(() => {
      if (!window.__interviewEmailHarness)
        throw new Error("Email harness state missing");
      window.__interviewEmailHarness.failNextHistoryLoad = true;
    });
    await drawer.getByRole("button", { name: "Tải lại" }).click();
    await drawer
      .getByText("Không thể tải Email History. Vui lòng thử lại.", {
        exact: true,
      })
      .waitFor({ state: "visible" });

    const deleteZeroAfterFailure = drawer.getByRole("button", {
      name: "Xóa đã chọn (0)",
    });
    assert.equal(await deleteZeroAfterFailure.isDisabled(), true);
    assert.equal(await drawer.locator("tbody tr").count(), 0);

    await drawer.getByRole("button", { name: "Tải lại" }).click();
    await drawer.getByText("Sent interview", { exact: true }).waitFor();
    const deleteZeroAfterRecovery = drawer.getByRole("button", {
      name: "Xóa đã chọn (0)",
    });
    assert.equal(await deleteZeroAfterRecovery.isDisabled(), true);
    assert.equal(await firstHistoryCheckbox.isChecked(), false);
    assert.deepEqual(errors, [], "Email History reload browser errors");
    await page.close();
  } finally {
    await browser.close();
  }
});
