import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { type Browser, chromium } from "playwright";

test("StatusMenu keyboard semantics and stacked overlay locking remain operational", {
  timeout: 60_000,
}, async () => {
  const bundle = await build({
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
    absWorkingDir: process.cwd(),
    bundle: true,
    entryPoints: [
      "src/__tests__/fixtures/design-primitives-interaction-harness.tsx",
    ],
    format: "iife",
    outdir: "design-primitives-interaction-fixture",
    platform: "browser",
    conditions: ["browser"],
    write: false,
  });
  const script = bundle.outputFiles.find((file) =>
    file.path.endsWith(".js"),
  )?.text;
  const style = bundle.outputFiles.find((file) =>
    file.path.endsWith(".css"),
  )?.text;
  if (!script || !style) {
    throw new Error("Primitive interaction fixture did not bundle");
  }

  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage({
      viewport: { width: 1024, height: 800 },
    });
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") pageErrors.push(message.text());
    });

    await page.setContent('<div id="app-root"><div id="root"></div></div>');
    await page.addStyleTag({ content: style });
    await page.addScriptTag({ content: script });
    await page
      .locator('[data-testid="primitive-harness-ready"]')
      .waitFor({ state: "visible", timeout: 5_000 });
    assert.deepEqual(pageErrors, []);

    const statusTrigger = page.locator(".ui-status-menu__trigger");
    await statusTrigger.focus();
    await statusTrigger.press("ArrowDown");
    const menu = page.locator('[role="menu"]');
    await menu.waitFor({ state: "visible" });
    await page.waitForFunction(
      () => document.activeElement?.getAttribute("role") === "menuitemradio",
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Mới",
    );

    await page.keyboard.press("ArrowDown");
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Đã đọc",
    );
    await page.keyboard.press("End");
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Đã đóng",
      "End must skip the disabled menu item and focus the last enabled option",
    );
    await page.keyboard.press("Enter");
    await menu.waitFor({ state: "detached" });
    assert.match((await statusTrigger.textContent()) ?? "", /CLOSED/);
    assert.equal(
      await page.evaluate(() => document.activeElement?.className),
      "ui-status-menu__trigger",
    );

    await statusTrigger.click();
    await menu.waitFor({ state: "visible" });
    await page.waitForFunction(
      () =>
        document.activeElement?.getAttribute("role") === "menuitemradio" &&
        document.activeElement?.getAttribute("aria-checked") === "true",
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Đã đóng",
      "click-open must focus the current enabled status",
    );
    await page.keyboard.press("Escape");
    await menu.waitFor({ state: "detached" });
    assert.equal(
      await page.evaluate(() => document.activeElement?.className),
      "ui-status-menu__trigger",
    );

    const drawerTrigger = page.locator('[data-testid="open-drawer"]');
    await drawerTrigger.click();
    const drawer = page.locator(".ui-drawer");
    await drawer.waitFor({ state: "visible" });
    assert.equal(await page.locator("#app-root").getAttribute("inert"), "");
    assert.equal(
      await page.evaluate(() => document.body.style.overflow),
      "hidden",
    );

    const dialogTrigger = page.locator('[data-testid="open-dialog"]');
    await dialogTrigger.click();
    const dialog = page.locator(".ui-dialog");
    await dialog.waitFor({ state: "visible" });
    assert.equal(await page.locator("#app-root").getAttribute("inert"), "");

    for (const viewport of [
      { width: 1440, height: 900 },
      { width: 768, height: 600 },
      { width: 390, height: 360 },
      { width: 360, height: 360 },
    ]) {
      await page.setViewportSize(viewport);
      const footer = dialog.locator("footer");
      const bounds = await footer.boundingBox();
      assert.ok(
        bounds && bounds.y >= 0 && bounds.y + bounds.height <= viewport.height,
        `Dialog actions must remain in viewport at ${viewport.width}x${viewport.height}`,
      );
      const body = dialog.locator(".ui-dialog__body");
      assert.ok(
        await body.evaluate((el) => el.scrollHeight > el.clientHeight),
        "Long dialog must scroll within its body",
      );
      await dialog.getByLabel(/Trường 12/).focus();
      const last = await dialog.getByLabel(/Trường 12/).boundingBox();
      const bodyBounds = await body.boundingBox();
      assert.ok(
        last &&
          bodyBounds &&
          last.y >= bodyBounds.y &&
          last.y + last.height <= bodyBounds.y + bodyBounds.height,
        "Keyboard focus must scroll the final field above the fixed actions",
      );
      assert.equal(
        await dialog
          .getByRole("button", { name: "Đồng ý", exact: true })
          .isVisible(),
        true,
      );
      await dialog.getByRole("button", { name: "Đồng ý", exact: true }).focus();
      await page.keyboard.press("Tab");
      assert.equal(
        await page.evaluate(() =>
          document.activeElement?.getAttribute("aria-label"),
        ),
        "Đóng / Close",
      );
    }
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "detached" });
    assert.equal(
      await drawer.count(),
      1,
      "closing top Dialog must keep Drawer open",
    );
    assert.equal(await page.locator("#app-root").getAttribute("inert"), "");
    assert.equal(
      await page.evaluate(() => document.body.style.overflow),
      "hidden",
    );
    await page.waitForFunction(
      () =>
        document.activeElement?.getAttribute("data-testid") === "open-dialog",
    );

    const drawerFooter = await drawer.locator("footer").boundingBox();
    assert.ok(
      drawerFooter && drawerFooter.y + drawerFooter.height <= 360,
      "Drawer footer must remain reachable at constrained height",
    );
    await drawer.getByLabel(/Mục 12/).focus();
    assert.ok(
      await drawer
        .locator(".ui-drawer__body")
        .evaluate((el) => el.scrollTop > 0),
      "Keyboard focus scrolls only drawer body",
    );
    await page.keyboard.press("Escape");
    await drawer.waitFor({ state: "detached" });
    assert.equal(await page.locator("#app-root").getAttribute("inert"), null);
    assert.equal(await page.evaluate(() => document.body.style.overflow), "");
    await page.waitForFunction(
      () =>
        document.activeElement?.getAttribute("data-testid") === "open-drawer",
    );
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});
