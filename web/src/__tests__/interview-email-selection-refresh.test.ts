import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { chromium } from "playwright";

async function bundlePageHarness() {
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
    outdir: "interview-email-selection-refresh-fixture",
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
    throw new Error("Interview selection refresh fixture did not bundle");
  return { script, style };
}

test("InterviewPage restores single-row lifecycle authority after refresh prunes a multi-selection", {
  timeout: 120_000,
}, async () => {
  const assets = await bundlePageHarness();
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
      document.body.dataset.harness = "page";
    });
    await page.addStyleTag({ content: assets.style });
    await page.addScriptTag({ content: assets.script });
    await page
      .locator('[data-harness-ready="page"]')
      .waitFor({ state: "attached", timeout: 5_000 });

    const lifecycleButton = page.getByRole("button", {
      name: "Tạo lịch / Chi tiết",
    });
    await page.getByLabel("Chọn Nguyễn Thị An").check();
    await page.getByLabel("Chọn Trần Minh Bình").check();
    assert.equal(await lifecycleButton.isDisabled(), true);

    await page.evaluate(() => {
      const state = window.__interviewEmailHarness;
      if (!state) throw new Error("Email harness state missing");
      const firstGroup = state.pageData.groups[0];
      if (!firstGroup) throw new Error("First Interview group missing");
      state.pageData = { ...state.pageData, groups: [firstGroup] };
    });

    await page
      .locator(".interview-application-row")
      .first()
      .getByRole("button", { name: "Thao tác khác", exact: true })
      .click();
    await page.getByRole("button", { name: "+ Vòng" }).first().click();
    const confirmation = page.getByRole("dialog", {
      name: "Tạo vòng phỏng vấn tiếp theo",
    });
    await confirmation.waitFor({ state: "visible" });
    await confirmation.getByRole("button", { name: "Xác nhận" }).click();

    await page
      .getByText("Trần Minh Bình", { exact: true })
      .waitFor({ state: "detached" });
    assert.equal(await page.getByLabel("Chọn Nguyễn Thị An").isChecked(), true);
    assert.equal(
      await lifecycleButton.isDisabled(),
      false,
      "one retained email selection must restore single-row lifecycle actions",
    );
    assert.deepEqual(errors, [], "Interview selection refresh browser errors");
    await page.close();
  } finally {
    await browser.close();
  }
});
