import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { type Browser, chromium, type Page } from "playwright";

const WIDTHS = [360, 390, 430, 768, 1024, 1280, 1393, 1440, 1920] as const;
type HarnessMode = "internal" | "candidate" | "login";

async function bundleHarness() {
  const bundle = await build({
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
    absWorkingDir: process.cwd(),
    bundle: true,
    entryPoints: [
      "src/__tests__/fixtures/design-browser-acceptance-harness.tsx",
    ],
    format: "iife",
    outdir: "design-browser-acceptance-fixture",
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
  if (!script || !style)
    throw new Error("Design browser acceptance fixture did not bundle");
  return { script, style };
}

async function openHarness(
  browser: Browser,
  assets: { script: string; style: string },
  mode: HarnessMode,
  width: number,
): Promise<{ page: Page; errors: string[] }> {
  const page = await browser.newPage({ viewport: { width, height: 900 } });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  await page.setContent('<div id="root"></div>');
  await page.evaluate((value) => {
    document.body.dataset.harness = value;
  }, mode);
  await page.addStyleTag({ content: assets.style });
  await page.addScriptTag({ content: assets.script });
  await page
    .locator(`[data-harness-ready="${mode}"]`)
    .waitFor({ state: "visible", timeout: 5_000 });
  return { page, errors };
}

async function assertNoPageOverflow(page: Page, label: string) {
  const dimensions = await page.evaluate(() => ({
    clientWidth: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
  }));
  assert.ok(
    dimensions.scrollWidth <= dimensions.clientWidth + 1,
    `${label}: unexpected page overflow ${dimensions.scrollWidth} > ${dimensions.clientWidth}`,
  );
}

test("production Design System passes desktop, tablet, and phone browser acceptance matrix", {
  timeout: 180_000,
}, async () => {
  const assets = await bundleHarness();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();

    for (const width of WIDTHS) {
      const internal = await openHarness(browser, assets, "internal", width);
      await assertNoPageOverflow(internal.page, `internal@${width}`);
      assert.deepEqual(
        internal.errors,
        [],
        `internal@${width} console/page errors`,
      );

      const sidebar = internal.page.locator(".sidebar");
      const trigger = internal.page.locator("#internal-nav-trigger");
      const table = internal.page.locator(".application-inbox__table");
      const tableScroll = internal.page.locator(
        '[data-testid="internal-table-scroll"]',
      );
      const badge = internal.page.locator(".ui-status-badge--interview");

      const badgeWidth = await badge.evaluate(
        (element) => element.getBoundingClientRect().width,
      );
      assert.ok(
        Math.abs(badgeWidth - 144) <= 1,
        `internal@${width}: Interview badge must be 144px`,
      );

      if (width > 1024) {
        assert.notEqual(
          await sidebar.evaluate(
            (element) => getComputedStyle(element).display,
          ),
          "none",
        );
        const sidebarWidth = await sidebar.evaluate(
          (element) => element.getBoundingClientRect().width,
        );
        assert.ok(
          Math.abs(sidebarWidth - 244) <= 1,
          `internal@${width}: desktop sidebar must be 244px`,
        );
        assert.equal(
          await trigger.evaluate(
            (element) => getComputedStyle(element).display,
          ),
          "none",
        );
      } else {
        assert.equal(
          await sidebar.evaluate(
            (element) => getComputedStyle(element).display,
          ),
          "none",
        );
        assert.notEqual(
          await trigger.evaluate(
            (element) => getComputedStyle(element).display,
          ),
          "none",
        );
      }

      if (
        width -
          (width > 1024 ? 244 : 0) -
          (width >= 1024 ? 48 : width >= 768 ? 40 : width <= 360 ? 24 : 32) >
        1100
      ) {
        assert.equal(
          await table.evaluate((element) => getComputedStyle(element).display),
          "table",
        );
        const overflow = await tableScroll.evaluate((element) => ({
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
        }));
        assert.ok(
          overflow.scrollWidth <= overflow.clientWidth + 1,
          `internal@${width}: fluid operational table must expose every column without horizontal scrolling`,
        );
        const columns = await table
          .locator("tbody tr")
          .first()
          .evaluate((row) =>
            Array.from(row.children).map(
              (cell) => cell.getBoundingClientRect().width,
            ),
          );
        assert.ok(
          columns[2] > columns[1] + 5,
          `internal@${width}: email receives more space than identity instead of equal auto columns`,
        );
        assert.ok(
          columns[7] >= 120,
          `internal@${width}: Inbox notes retain a readable column near structured reflow`,
        );
        for (const [index, reserved] of [
          [0, 48],
          [3, 112],
          [4, 80],
          [5, 130],
          [6, 160],
          [8, 100],
        ]) {
          assert.ok(
            Math.abs(columns[index] - reserved) <= 1,
            `internal@${width}: compact data/status/action columns retain usable width`,
          );
        }
        const firstCellPosition = await internal.page
          .locator(".application-inbox__table tbody td")
          .first()
          .evaluate((element) => getComputedStyle(element).position);
        assert.equal(
          firstCellPosition,
          "sticky",
          `internal@${width}: Select context must remain sticky`,
        );
      } else {
        assert.equal(
          await table.evaluate((element) => getComputedStyle(element).display),
          "block",
        );
        assert.equal(
          await internal.page
            .locator(".application-inbox__table tbody tr")
            .first()
            .evaluate((element) => getComputedStyle(element).display),
          "grid",
          `internal@${width}: phone table presentation must become structured labelled rows`,
        );
      }

      if (width === 390) {
        await trigger.click();
        const panel = internal.page.locator(".mobile-nav-panel");
        await panel.waitFor({ state: "visible" });
        assert.equal(
          await internal.page.locator("#app-root").getAttribute("inert"),
          "",
        );
        assert.equal(
          await internal.page.evaluate(() => document.body.style.overflow),
          "hidden",
        );
        const panelWidth = await panel.evaluate(
          (element) => element.getBoundingClientRect().width,
        );
        assert.ok(
          panelWidth <= 360,
          "phone navigation panel must stay bounded",
        );
        await internal.page.keyboard.press("Escape");
        await panel.waitFor({ state: "detached" });
        assert.equal(
          await internal.page.evaluate(() => document.activeElement?.id),
          "internal-nav-trigger",
        );
      }

      if (width === 390 || width === 1280) {
        const drawerTrigger = internal.page.locator(
          '[data-testid="open-drawer"]',
        );
        await drawerTrigger.click();
        const drawer = internal.page.locator(".ui-drawer");
        await drawer.waitFor({ state: "visible" });
        const drawerBounds = await drawer.boundingBox();
        assert.ok(drawerBounds);
        if (width <= 640) {
          assert.ok(
            drawerBounds.width >= width - 1,
            `internal@${width}: phone drawer must be full width`,
          );
          assert.ok(
            drawerBounds.height >= 899,
            `internal@${width}: phone drawer must use 100dvh`,
          );
        } else {
          assert.ok(
            Math.abs(drawerBounds.width - 820) <= 1,
            "desktop drawer must use preferred 820px width",
          );
        }
        await internal.page.keyboard.press("Escape");
        await drawer.waitFor({ state: "detached" });
        assert.equal(
          await internal.page.evaluate(() =>
            document.activeElement?.getAttribute("data-testid"),
          ),
          "open-drawer",
          `internal@${width}: drawer must restore trigger focus`,
        );
      }
      await internal.page.close();

      const candidate = await openHarness(browser, assets, "candidate", width);
      await assertNoPageOverflow(candidate.page, `candidate@${width}`);
      assert.deepEqual(
        candidate.errors,
        [],
        `candidate@${width} console/page errors`,
      );
      assert.equal(
        await candidate.page.locator(".sidebar").count(),
        0,
        `candidate@${width}: internal sidebar must not leak into Candidate shell`,
      );
      const candidateAction = candidate.page
        .locator(".submissions-table .btn")
        .first();
      const candidateActionMetrics = await candidateAction.evaluate(
        (element) => ({
          fontSize: Number.parseFloat(getComputedStyle(element).fontSize),
          height: element.getBoundingClientRect().height,
        }),
      );
      assert.ok(
        candidateActionMetrics.fontSize >= 16,
        `candidate@${width}: primary control text must be >=16px`,
      );
      assert.ok(
        candidateActionMetrics.height >= 44,
        `candidate@${width}: action target must be >=44px`,
      );
      if (width <= 640) {
        assert.equal(
          await candidate.page
            .locator(".submissions-table")
            .evaluate((element) => getComputedStyle(element).display),
          "block",
          `candidate@${width}: submissions must use structured phone presentation`,
        );
      }
      await candidate.page.close();

      const login = await openHarness(browser, assets, "login", width);
      await assertNoPageOverflow(login.page, `login@${width}`);
      assert.deepEqual(login.errors, [], `login@${width} console/page errors`);
      const primaryMetrics = await login.page
        .locator(".btn-login-primary")
        .evaluate((element) => ({
          fontSize: Number.parseFloat(getComputedStyle(element).fontSize),
          height: element.getBoundingClientRect().height,
        }));
      assert.ok(
        primaryMetrics.fontSize >= 16,
        `login@${width}: login control text must be >=16px`,
      );
      assert.ok(
        primaryMetrics.height >= 48,
        `login@${width}: login primary target must be >=48px`,
      );
      assert.equal(
        Number.parseFloat(
          await login.page
            .locator(".btn-login-link")
            .evaluate((element) => getComputedStyle(element).fontSize),
        ),
        16,
        `login@${width}: reset action must be 16px`,
      );
      const direction = await login.page
        .locator(".login-page")
        .evaluate((element) => getComputedStyle(element).flexDirection);
      assert.equal(
        direction,
        width <= 820 ? "column" : "row",
        `login@${width}: responsive split direction`,
      );
      await login.page.close();
    }
  } finally {
    await browser?.close();
  }
});
