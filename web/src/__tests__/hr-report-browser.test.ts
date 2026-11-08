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
    entryPoints: ["src/__tests__/fixtures/hr-report-browser-harness.tsx"],
    format: "iife",
    outdir: "hr-report-browser-fixture",
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
    throw new Error("HR Report browser fixture did not bundle");
  }
  return { script, style };
}

async function openHarness(
  browser: Browser,
  assets: { script: string; style: string },
  width: number,
  height = 900,
): Promise<{ page: Page; errors: string[] }> {
  const page = await browser.newPage({ viewport: { width, height } });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  await page.setContent('<div id="root"></div>');
  await page.addStyleTag({ content: assets.style });
  await page.addScriptTag({ content: assets.script });
  await page.locator('[data-harness-ready="hr-report"]').waitFor({
    state: "visible",
    timeout: 5_000,
  });
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

async function scrollRowStatusIntoReach(page: Page) {
  const trigger = page.getByRole("button", {
    name: "Đổi trạng thái của Nguyễn Minh Anh",
  });
  await trigger.scrollIntoViewIfNeeded();
  const box = await trigger.boundingBox();
  assert.ok(
    box && box.x >= 0 && box.x + box.width <= 390,
    "Phone card status stays fully reachable",
  );
  return trigger;
}

test("HR Report preserves fluid column alignment and contained responsive card scrolling", {
  timeout: 180_000,
}, async () => {
  const assets = await bundleHarness();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    for (const width of WIDTHS) {
      const { page, errors } = await openHarness(browser, assets, width);
      await assertNoPageOverflow(page, `hr-report@${width}`);
      assert.deepEqual(errors, [], `hr-report@${width} console/page errors`);

      const table = page.getByRole("table");
      const workspaceWidth = await page
        .locator(".content")
        .evaluate((element) => {
          const style = getComputedStyle(element);
          return (
            element.clientWidth -
            Number.parseFloat(style.paddingLeft) -
            Number.parseFloat(style.paddingRight)
          );
        });
      const wideTable = workspaceWidth > 1100;
      assert.equal(
        await table.evaluate((element) => getComputedStyle(element).display),
        wideTable ? "table" : "block",
        `${width}: composition follows available workspace`,
      );
      const tableWidth = await table.evaluate(
        (element) => element.getBoundingClientRect().width,
      );

      const headers = await page
        .getByRole("columnheader", { includeHidden: true })
        .allTextContents();
      assert.deepEqual(
        headers.map((value) => value.trim()),
        [
          "Chọn tất cả",
          "Họ và tên",
          "Vị trí",
          "Thời gian phỏng vấn",
          "Địa điểm",
          "Trạng thái",
          "Ghi chú",
          "Thao tác",
        ],
      );

      const scroll = await page
        .locator(".ui-table-scroll")
        .evaluate((element) => ({
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
        }));
      assert.ok(
        scroll.scrollWidth <= scroll.clientWidth + 1,
        `hr-report@${width}: all columns/cards fit without horizontal scrolling`,
      );
      assert.ok(
        Math.abs(tableWidth - scroll.clientWidth) <= 1,
        `hr-report@${width}: table fills its available list viewport`,
      );
      if (wideTable) {
        const columns = await table
          .locator("tbody tr")
          .first()
          .evaluate((row) =>
            Array.from(row.children).map(
              (cell) => cell.getBoundingClientRect().width,
            ),
          );
        assert.ok(
          columns[1] > columns[4] * 1.35,
          `hr-report@${width}: identity receives more width than location`,
        );
        assert.ok(
          columns[6] >= 120,
          `hr-report@${width}: notes remain readable immediately above structured reflow`,
        );
        for (const [index, reserved] of [
          [0, 48],
          [5, 168],
          [7, 100],
        ]) {
          assert.ok(
            Math.abs(columns[index] - reserved) <= 1,
            `hr-report@${width}: selection/status/action targets retain reserved width`,
          );
        }
        const axes = await table.evaluate((element) => {
          const header = element.querySelector("thead tr");
          const row = element.querySelector("tbody tr");
          if (!header || !row) throw new Error("Populated report rows missing");
          return Array.from(header.children).map((cell, index) => ({
            head: cell.getBoundingClientRect().left,
            body: row.children[index]?.getBoundingClientRect().left,
          }));
        });
        assert.ok(
          axes.every(
            (axis) =>
              axis.body !== undefined && Math.abs(axis.head - axis.body) <= 1,
          ),
          "Every report header shares its data column axis",
        );
      }

      const sticky = await table
        .locator("tbody tr")
        .first()
        .locator("td")
        .evaluateAll((cells) =>
          cells.slice(0, 2).map((cell) => ({
            position: getComputedStyle(cell).position,
            left: getComputedStyle(cell).left,
          })),
        );
      if (wideTable) {
        assert.equal(sticky[0]?.position, "sticky");
        assert.equal(sticky[0]?.left, "0px");
        assert.equal(sticky[1]?.position, "sticky");
        assert.equal(sticky[1]?.left, "48px");
      } else {
        assert.equal(sticky[0]?.position, "static");
        assert.equal(
          await page
            .locator(".ui-table-scroll")
            .evaluate((el) => getComputedStyle(el).maxHeight),
          "none",
        );
      }

      const badgeWidth = await page
        .locator(".ui-status-badge")
        .first()
        .evaluate((element) => element.getBoundingClientRect().width);
      assert.ok(
        Math.abs(badgeWidth - 144) <= 1,
        `hr-report@${width}: operational status badge must use 144px benchmark`,
      );

      await page.close();
    }
  } finally {
    await browser?.close();
  }
});

test("HR Report narrow status and filtered drawer preserve drafts and conflict bases", {
  timeout: 120_000,
}, async () => {
  const assets = await bundleHarness();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const { page, errors } = await openHarness(browser, assets, 390, 700);

    const rowStatus = await scrollRowStatusIntoReach(page);
    await rowStatus.click();
    assert.equal(await page.getByRole("menuitemradio").count(), 8);
    await page.keyboard.press("Escape");
    assert.equal(
      await rowStatus.evaluate((element) => document.activeElement === element),
      true,
      "Escape must restore focus to the status trigger",
    );

    await rowStatus.click();
    await page.getByRole("menuitemradio", { name: "Đã gửi Báo cáo" }).click();
    await page.getByText("Đã cập nhật trạng thái báo cáo.").waitFor({
      state: "visible",
    });

    await page.getByRole("checkbox", { name: "Chọn Nguyễn Minh Anh" }).check();
    const bulkStatus = page.getByRole("button", {
      name: "Đổi trạng thái đã chọn",
    });
    assert.equal(await bulkStatus.isEnabled(), true);
    await bulkStatus.click();
    await page.getByRole("menuitemradio", { name: "Tạm hoãn" }).click();
    await page
      .getByText("Đã cập nhật trạng thái cho các báo cáo đã chọn.")
      .waitFor({ state: "visible" });

    if (
      !(await page
        .locator(".workflow-filters")
        .evaluate((el) => (el as HTMLDetailsElement).open))
    )
      await page.locator(".workflow-filters > summary").click();
    await page.getByLabel("Hiển thị").selectOption("VISIBLE");
    await page.locator(".ui-table-scroll").evaluate((element) => {
      element.scrollLeft = element.scrollWidth;
    });
    await page.getByRole("button", { name: "Xem" }).first().click();
    const drawer = page.getByRole("dialog", { name: "Chi tiết báo cáo" });
    await drawer.waitFor({ state: "visible" });
    assert.equal(
      await drawer
        .getByRole("button", { name: "Tải PDF — đang chờ mẫu" })
        .isDisabled(),
      true,
    );
    assert.equal(
      await drawer.getByRole("button", { name: "Xóa / Inactive" }).count(),
      2,
    );

    const note = drawer.getByLabel("Nội dung ghi chú");
    await note.fill("Ghi chú vẫn tồn tại khi row bị filter loại");
    await drawer.getByRole("button", { name: "Ẩn với Interviewer" }).click();
    await drawer.waitFor({ state: "visible" });
    assert.equal(
      await note.inputValue(),
      "Ghi chú vẫn tồn tại khi row bị filter loại",
      "filtered refresh must not close the Drawer or discard a dirty HR Note",
    );

    await drawer.getByRole("button", { name: "Sửa" }).first().click();
    const firstParticipant = drawer.locator("article").first();
    const reportDraft = firstParticipant.locator("textarea").first();
    await reportDraft.fill("Local participant draft");

    await page.evaluate(() => {
      const edit = (
        globalThis as typeof globalThis & {
          __hrReportRemoteParticipantEdit?: (value: string) => void;
        }
      ).__hrReportRemoteParticipantEdit;
      if (!edit) throw new Error("remote edit harness is unavailable");
      edit("Remote participant edit");
    });

    if (
      !(await page
        .locator(".workflow-filters")
        .evaluate((el) => (el as HTMLDetailsElement).open))
    )
      await page.locator(".workflow-filters > summary").click();
    await page.getByLabel("Hiển thị").selectOption("ALL");
    assert.equal(
      await reportDraft.inputValue(),
      "Local participant draft",
      "refresh must preserve the local dirty participant field",
    );

    await firstParticipant.getByRole("button", { name: "Lưu báo cáo" }).click();
    await drawer
      .getByText("Dữ liệu đã thay đổi ở nơi khác. Trang đã được tải lại.")
      .waitFor({ state: "visible" });
    assert.equal(
      await reportDraft.inputValue(),
      "Local participant draft",
      "same-field conflict must not silently overwrite the remote edit",
    );

    await drawer.getByRole("button", { name: "Sửa" }).nth(1).click();
    await drawer
      .getByText(
        "Hãy lưu hoặc bỏ thay đổi đang chỉnh sửa trước khi chuyển nội dung.",
      )
      .waitFor({ state: "visible" });
    assert.equal(
      await reportDraft.inputValue(),
      "Local participant draft",
      "participant switch must not replace a dirty report draft",
    );

    const interviewsLink = drawer.getByRole("link", {
      name: "Mở trang Phỏng vấn",
    });
    assert.equal(await interviewsLink.getAttribute("aria-disabled"), "true");

    await drawer.getByRole("button", { name: "Đóng", exact: true }).click();
    const discard = page.getByRole("dialog", {
      name: "Bỏ thay đổi chưa lưu?",
    });
    await discard.waitFor({ state: "visible" });
    await discard.getByRole("button", { name: "Tiếp tục sửa" }).click();
    assert.equal(
      await reportDraft.inputValue(),
      "Local participant draft",
      "closing protection must preserve edits when discard is cancelled",
    );

    assert.deepEqual(errors, [], "HR Report interaction browser errors");
    await page.close();
  } finally {
    await browser?.close();
  }
});
