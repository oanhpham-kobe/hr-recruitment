import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { type Browser, chromium, type Page } from "playwright";

const WIDTHS = [360, 390, 430, 768, 1024, 1280, 1393, 1440, 1920] as const;

async function bundleHarness() {
  const bundle = await build({
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
    absWorkingDir: process.cwd(),
    bundle: true,
    entryPoints: [
      "src/__tests__/fixtures/interview-browser-acceptance-harness.tsx",
    ],
    format: "iife",
    outdir: "interview-browser-acceptance-fixture",
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
    throw new Error("Interview browser acceptance fixture did not bundle");
  return { script, style };
}

async function openHarness(
  browser: Browser,
  assets: { script: string; style: string },
  width: number,
): Promise<{ page: Page; errors: string[] }> {
  const page = await browser.newPage({ viewport: { width, height: 900 } });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  await page.setContent('<div id="root"></div>');
  await page.addStyleTag({ content: assets.style });
  await page.addScriptTag({ content: assets.script });
  await page
    .locator('[data-harness-ready="interview"]')
    .waitFor({ state: "visible", timeout: 5_000 });
  return { page, errors };
}

async function assertNoPageOverflow(page: Page, label: string) {
  const dimensions = await page.evaluate(() => {
    const clientWidth = document.documentElement.clientWidth;
    const offenders = Array.from(
      document.querySelectorAll<HTMLElement>("body *"),
    )
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          tag: element.tagName.toLowerCase(),
          id: element.id,
          className: element.className,
          left: Math.round(rect.left),
          right: Math.round(rect.right),
          width: Math.round(rect.width),
          scrollWidth: element.scrollWidth,
        };
      })
      .filter((item) => item.left < -1 || item.right > clientWidth + 1)
      .sort((a, b) => b.right - a.right)
      .slice(0, 8);
    return {
      clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
      offenders,
    };
  });
  assert.ok(
    dimensions.scrollWidth <= dimensions.clientWidth + 1,
    `${label}: unexpected page overflow ${dimensions.scrollWidth} > ${dimensions.clientWidth}; offenders=${JSON.stringify(dimensions.offenders)}`,
  );
}

async function assertDrawerContract(page: Page, width: number) {
  await page.locator('[data-testid="open-interview-drawer"]').click();
  const drawer = page.locator(".ui-drawer");
  await drawer.waitFor({ state: "visible" });
  const box = await drawer.boundingBox();
  assert.ok(box, `interview@${width}: drawer must have a box`);
  if (width <= 430) {
    assert.ok(
      box.width >= width - 2,
      `interview@${width}: phone drawer must be full width`,
    );
    assert.ok(
      box.height >= 898,
      `interview@${width}: phone drawer must use the full viewport height`,
    );
  } else if (width >= 1280) {
    assert.ok(
      box.width <= 821 && box.width >= 760,
      `interview@${width}: desktop drawer must stay near the preferred 820px width`,
    );
  } else {
    assert.ok(
      box.width < width,
      `interview@${width}: tablet drawer must remain bounded`,
    );
  }
  await page.keyboard.press("Escape");
  await drawer.waitFor({ state: "detached" });
}

test("Interview production UI passes responsive browser geometry and overlay contracts", {
  timeout: 180_000,
}, async () => {
  const assets = await bundleHarness();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    for (const width of WIDTHS) {
      const { page, errors } = await openHarness(browser, assets, width);
      await assertNoPageOverflow(page, `interview@${width}`);
      assert.deepEqual(errors, [], `interview@${width}: console/page errors`);

      const table = page.locator(".interview-table");
      const tableScroll = page.locator(
        '[data-testid="interview-table-scroll"]',
      );
      const selectTarget = page.locator(".interview-select-target").first();
      const selectTargetBox = await selectTarget.boundingBox();
      assert.ok(
        selectTargetBox,
        `interview@${width}: select target must exist`,
      );
      assert.ok(
        selectTargetBox.width >= 44 && selectTargetBox.height >= 44,
        `interview@${width}: selection target must be at least 44x44`,
      );

      const filterControl = page.locator(".interview-filters input").first();
      const filterBox = await filterControl.boundingBox();
      assert.ok(
        filterBox && filterBox.height >= 44,
        `interview@${width}: filter controls must be at least 44px high`,
      );

      const badge = page.locator(".ui-status-badge--interview").first();
      const badgeWidth = await badge.evaluate(
        (element) => element.getBoundingClientRect().width,
      );
      assert.ok(
        Math.abs(badgeWidth - 144) <= 1,
        `interview@${width}: Interview badge must be 144px`,
      );

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
        const tableWidth = await table.evaluate(
          (element) => element.getBoundingClientRect().width,
        );
        assert.ok(
          Math.abs(
            tableWidth - (await tableScroll.evaluate((el) => el.clientWidth)),
          ) <= 1,
          `interview@${width}: semantic Interview table fills the current workspace`,
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
          columns[1] > columns[3] * 1.4,
          `interview@${width}: identity is visibly wider than location instead of equal auto columns`,
        );
        assert.ok(
          columns[5] >= 120,
          `interview@${width}: notes retain a readable column near the reflow threshold`,
        );
        for (const [index, reserved] of [
          [0, 48],
          [4, 168],
          [6, 100],
        ]) {
          assert.ok(
            Math.abs(columns[index] - reserved) <= 1,
            `interview@${width}: selection/status/action targets retain reserved width`,
          );
        }
        const roundCellHeights = await page
          .locator(".interview-round-row")
          .first()
          .evaluate((row) =>
            Array.from(row.children).map(
              (cell) => cell.getBoundingClientRect().height,
            ),
          );
        assert.ok(
          Math.max(...roundCellHeights) - Math.min(...roundCellHeights) <= 1,
          `interview@${width}: expanded round cells must share one aligned row`,
        );
        const overflow = await tableScroll.evaluate((element) => ({
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
        }));
        assert.ok(
          overflow.scrollWidth <= overflow.clientWidth + 1,
          `interview@${width}: fluid table shows notes/actions without horizontal scrolling`,
        );
        const firstCell = page
          .locator(".interview-table tbody tr")
          .first()
          .locator("td")
          .first();
        const identityCell = page
          .locator(".interview-table tbody tr")
          .first()
          .locator("th")
          .first();
        assert.equal(
          await firstCell.evaluate(
            (element) => getComputedStyle(element).position,
          ),
          "sticky",
          `interview@${width}: Select context must remain sticky`,
        );
        assert.equal(
          await identityCell.evaluate(
            (element) => getComputedStyle(element).position,
          ),
          "sticky",
          `interview@${width}: Application identity must remain sticky`,
        );
        const identityLeft = await identityCell.evaluate(
          (element) => getComputedStyle(element).left,
        );
        assert.equal(identityLeft, "48px");
      } else {
        assert.equal(
          await table.evaluate((element) => getComputedStyle(element).display),
          "block",
        );
        assert.equal(
          await page
            .locator(".interview-table tbody tr")
            .first()
            .evaluate((element) => getComputedStyle(element).display),
          "grid",
          `interview@${width}: phone presentation must use structured labelled rows`,
        );
        const scrollState = await tableScroll.evaluate((element) => ({
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
        }));
        assert.ok(
          scrollState.scrollWidth <= scrollState.clientWidth + 1,
          `interview@${width}: phone cards must not preserve horizontal table overflow`,
        );
      }

      if (width === 390) {
        const trigger = page.locator(
          ".interview-status-menu .ui-status-menu__trigger",
        );
        await trigger.click();
        const panel = page.locator(
          ".interview-status-menu .ui-status-menu__panel",
        );
        await panel.waitFor({ state: "visible" });
        const panelBox = await panel.boundingBox();
        assert.ok(panelBox, "interview@390: status menu panel must exist");
        assert.ok(
          panelBox.x >= -1 && panelBox.x + panelBox.width <= width + 1,
          "interview@390: status menu must stay inside the viewport",
        );
        await page.keyboard.press("Escape");
        await panel.waitFor({ state: "detached" });
        assert.equal(
          await trigger.evaluate(
            (element) => document.activeElement === element,
          ),
          true,
          "interview@390: Escape must restore focus to the status trigger",
        );
      }

      if (width === 390 || width === 768 || width === 1280) {
        await assertDrawerContract(page, width);
      }

      await assertNoPageOverflow(page, `interview@${width}:after-interactions`);
      assert.deepEqual(errors, [], `interview@${width}: interaction errors`);
      await page.close();
    }
  } finally {
    await browser?.close();
  }
});
