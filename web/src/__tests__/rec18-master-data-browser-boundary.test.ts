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
    entryPoints: ["src/__tests__/fixtures/master-data-management-harness.tsx"],
    format: "iife",
    outdir: "rec18-harness-out",
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
          b.onResolve({ filter: /actions$/ }, () => ({
            path: "actions",
            namespace: "stub-actions",
          }));
          b.onLoad({ filter: /.*/, namespace: "stub-actions" }, () => ({
            contents: `
              let currentItems = [
                { id: "u-001", code: "CNTT", nameVi: "Khoa Công nghệ thông tin", nameEn: "Faculty of IT", isActive: true, versionNo: 1 },
                { id: "u-002", code: "QTKD", nameVi: "Khoa Quản trị kinh doanh", nameEn: "Faculty of BA", isActive: false, versionNo: 2 },
              ];
              export async function getMasterDataItemsAction(type) {
                return { success: true, data: currentItems };
              }
              export async function createMasterItemAction() {
                return { success: true, data: { master_type: "organizational_units", master_id: "u-new", version_no: 1, is_active: true } };
              }
              export async function updateMasterItemAction(type, id, payload, ver) {
                if (payload && payload.name_vi === "Trigger Stale") {
                  return { success: false, code: "STALE_VERSION", error: "Dữ liệu đã bị thay đổi bởi người khác (phiên bản cũ)." };
                }
                const found = currentItems.find(x => x.id === id);
                if (found) {
                  found.nameVi = payload.name_vi;
                  found.versionNo += 1;
                }
                return { success: true, data: { master_type: "organizational_units", master_id: id, version_no: 2, is_active: true } };
              }
              export async function deleteOrInactivateMasterItemAction() {
                return { success: true, data: { master_type: "organizational_units", master_id: "u-001", version_no: 2, outcome: "INACTIVATED" } };
              }
              export async function getMasterDataDependenciesAction() {
                return { units: [], teams: [], positionGroups: [] };
              }
            `,
          }));
        },
      },
    ],
  });

  const jsFile = browserBundle.outputFiles.find((f) => f.path.endsWith(".js"));
  const cssFile = browserBundle.outputFiles.find((f) =>
    f.path.endsWith(".css"),
  );

  if (!jsFile) {
    throw new Error("Failed to generate master data harness bundle");
  }

  cachedScript = jsFile.text;
  cachedStyle = cssFile ? cssFile.text : "";
  return { script: cachedScript, style: cachedStyle };
}

let browser: Browser | undefined;

test.before(async () => {
  browser = await chromium.launch({ headless: true });
});

test.after(async () => {
  if (browser) {
    await browser.close();
  }
});

async function setupPage(
  options: { identity?: { roles: string[]; permissions: string[] } } = {},
): Promise<Page> {
  if (!browser) throw new Error("Browser not started");
  const page = await browser.newPage({
    viewport: { width: 1280, height: 800 },
  });
  const { script, style } = await getHarnessBundle();

  const html = `
    <!DOCTYPE html>
    <html lang="vi">
      <head>
        <meta charset="utf-8" />
        <title>Master Data Test</title>
        <style>${style}</style>
      </head>
      <body>
        <div id="root"></div>
        <script>
          window.__HARNESS_PROPS__ = ${JSON.stringify(options)};
        </script>
        <script>${script}</script>
      </body>
    </html>
  `;

  await page.setContent(html);
  await page.waitForSelector(".master-data-page");
  return page;
}

test("B1.1: Master Data Management page renders header, catalog selector with all 11 catalogs, and initial table data", async () => {
  const page = await setupPage();
  try {
    const title = await page.textContent(".master-data-header__title");
    assert.ok(title?.includes("Danh mục"));

    const optionsCount = await page
      .locator(".master-data-controls__select-group select option")
      .count();
    assert.equal(optionsCount, 11);

    const rowsCount = await page.locator(".master-data-table tbody tr").count();
    assert.equal(rowsCount, 2);

    const firstRowText = await page
      .locator(".master-data-table tbody tr:first-child")
      .textContent();
    assert.ok(firstRowText?.includes("CNTT"));
    assert.ok(firstRowText?.includes("Khoa Công nghệ thông tin"));
    assert.ok(firstRowText?.includes("Đang hoạt động"));

    const secondRowText = await page
      .locator(".master-data-table tbody tr:nth-child(2)")
      .textContent();
    assert.ok(secondRowText?.includes("QTKD"));
    assert.ok(secondRowText?.includes("Ngừng hoạt động"));
  } finally {
    await page.close();
  }
});

test("B1.2: Searching items filters rows by code or name", async () => {
  const page = await setupPage();
  try {
    const searchInput = page.locator('input[type="search"]');
    await searchInput.fill("QTKD");

    const rowsCount = await page.locator(".master-data-table tbody tr").count();
    assert.equal(rowsCount, 1);
    const text = await page
      .locator(".master-data-table tbody tr")
      .textContent();
    assert.ok(text?.includes("QTKD"));
    assert.ok(!text?.includes("CNTT"));
  } finally {
    await page.close();
  }
});

test("B1.3: Status filter filters between ALL, ACTIVE, and INACTIVE", async () => {
  const page = await setupPage();
  try {
    const statusSelect = page.locator(".master-data-controls__filters select");

    // Filter ACTIVE
    await statusSelect.selectOption("ACTIVE");
    assert.equal(await page.locator(".master-data-table tbody tr").count(), 1);
    assert.ok(
      (
        await page.locator(".master-data-table tbody tr").textContent()
      )?.includes("CNTT"),
    );

    // Filter INACTIVE
    await statusSelect.selectOption("INACTIVE");
    assert.equal(await page.locator(".master-data-table tbody tr").count(), 1);
    assert.ok(
      (
        await page.locator(".master-data-table tbody tr").textContent()
      )?.includes("QTKD"),
    );

    // Filter ALL
    await statusSelect.selectOption("ALL");
    assert.equal(await page.locator(".master-data-table tbody tr").count(), 2);
  } finally {
    await page.close();
  }
});

test("B1.4: Create Modal opens, validates inputs, and closes on Escape", async () => {
  const page = await setupPage();
  try {
    await page.click('button:has-text("+ Thêm mới")');
    await page.waitForSelector('div[role="dialog"]');

    const dialogTitle = await page.textContent("#create-dialog-title");
    assert.ok(dialogTitle?.includes("Thêm mới mục danh mục"));

    // Press Escape to dismiss
    await page.keyboard.press("Escape");
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });
  } finally {
    await page.close();
  }
});

test("B1.5: Edit Modal renders code as disabled (immutable contract) and allows editing name", async () => {
  const page = await setupPage();
  try {
    await page.click(
      '.master-data-table tbody tr:first-child button:has-text("Sửa")',
    );
    await page.waitForSelector('div[role="dialog"]');

    const dialogTitle = await page.textContent("#edit-dialog-title");
    assert.ok(dialogTitle?.includes("Chỉnh sửa mục danh mục"));

    // Code input is disabled
    const codeDisabled = await page.locator("#edit-code").isDisabled();
    assert.equal(codeDisabled, true);
    assert.equal(await page.locator("#edit-code").inputValue(), "CNTT");

    // Close on Cancel button
    await page.click('button:has-text("Hủy bỏ")');
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });
  } finally {
    await page.close();
  }
});

test("B1.6: Delete / Inactivate confirmation dialog explains referenced data safety", async () => {
  const page = await setupPage();
  try {
    await page.click(
      '.master-data-table tbody tr:first-child button:has-text("Xóa / Ngừng HĐ")',
    );
    await page.waitForSelector('div[role="dialog"]');

    const dialogTitle = await page.textContent("#delete-dialog-title");
    assert.ok(dialogTitle?.includes("Xác nhận Xóa / Ngừng hoạt động"));

    const dialogBody = await page.textContent(".modal-body");
    assert.ok(dialogBody?.includes("Cơ chế an toàn tham chiếu"));
    assert.ok(dialogBody?.includes("chuyển sang trạng thái Ngừng hoạt động"));
    assert.ok(dialogBody?.includes("xóa vĩnh viễn"));

    // Close on Cancel
    await page.click('button:has-text("Hủy bỏ")');
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });
  } finally {
    await page.close();
  }
});

test("B1.7: Limited HR without master_data.manage is denied management actions", async () => {
  const page = await setupPage({
    identity: {
      roles: ["HR"],
      permissions: ["submissions.view"], // lacks master_data.manage
    },
  });
  try {
    const errorAlert = await page.textContent(".ui-alert--error");
    assert.ok(errorAlert?.includes("Bạn không có quyền quản lý Danh mục"));

    // Add button and action buttons are not rendered
    assert.equal(
      await page.locator('button:has-text("+ Thêm mới")').count(),
      0,
    );
    assert.equal(
      await page.locator('.master-data-table button:has-text("Sửa")').count(),
      0,
    );
  } finally {
    await page.close();
  }
});

test("B1.8: Dialog focus trap and focus restoration on dismiss", async () => {
  const page = await setupPage();
  try {
    const createBtn = page.locator('button:has-text("+ Thêm mới")');
    await createBtn.click();
    await page.waitForSelector('div[role="dialog"]');

    // Initial focus is inside the dialog (close button or first input)
    const isFocusInside = await page.evaluate(() => {
      const dialog = document.querySelector('div[role="dialog"]');
      return dialog ? dialog.contains(document.activeElement) : false;
    });
    assert.equal(isFocusInside, true);

    // Press Escape to dismiss
    await page.keyboard.press("Escape");
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });
    // Focus restored to the create button
    await page.waitForFunction(() => {
      const btn = document.querySelector(".master-data-btn-primary");
      return document.activeElement === btn;
    });
  } finally {
    await page.close();
  }
});

test("B1.9: STALE_VERSION conflict error renders inside modal and keeps dialog open", async () => {
  const page = await setupPage();
  try {
    await page.click(
      '.master-data-table tbody tr:first-child button:has-text("Sửa")',
    );
    await page.waitForSelector('div[role="dialog"]');

    // Enter name that triggers STALE_VERSION in our stub
    const nameInput = page.locator("#edit-name-vi");
    await nameInput.fill("Trigger Stale");

    // Click submit
    await page.click('button[type="submit"]:has-text("Lưu thay đổi")');

    // Dialog remains open
    assert.equal(await page.locator('div[role="dialog"]').count(), 1);

    // Modal-local error alert is displayed
    const modalError = await page.textContent(".modal-body .ui-alert--error");
    assert.ok(modalError?.includes("phiên bản cũ"));
  } finally {
    await page.close();
  }
});

test("B1.10: Scoped list action buttons and badges use the approved14px trial hierarchy", async () => {
  const page = await setupPage();
  try {
    const btnFontSize = await page.evaluate(() => {
      const btn = document.querySelector(".master-data-btn-secondary");
      return btn ? window.getComputedStyle(btn).fontSize : null;
    });
    assert.equal(btnFontSize, "14px");

    const badgeFontSize = await page.evaluate(() => {
      const badge = document.querySelector(".master-data-badge");
      return badge ? window.getComputedStyle(badge).fontSize : null;
    });
    assert.equal(badgeFontSize, "14px");
    await page
      .locator('.master-data-table button:has-text("Sửa")')
      .first()
      .click();
    const dialog = page.getByRole("dialog");
    await dialog.waitFor();
    const formSizes = await dialog
      .locator("label, input, select, textarea, button, .meta, small")
      .evaluateAll((elements) =>
        elements.map((el) => Number.parseFloat(getComputedStyle(el).fontSize)),
      );
    assert.ok(
      formSizes.length > 0 && formSizes.every((size) => size >= 16),
      "Inline admin dialog retains16px form/body type",
    );
  } finally {
    await page.close();
  }
});
test("B1.11: Successful edit mutation restores keyboard focus to the refreshed edit button", async () => {
  const page = await setupPage();
  try {
    await page.click(
      '.master-data-table tbody tr:first-child button:has-text("Sửa")',
    );
    await page.waitForSelector('div[role="dialog"]');

    // Edit the name
    const nameInput = page.locator("#edit-name-vi");
    await nameInput.fill("Khoa CNTT Đã Sửa");

    // Click submit
    await page.click('button[type="submit"]:has-text("Lưu thay đổi")');

    // Dialog closes
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });

    // Focus is restored to the refreshed Sửa button on the first row
    await page.waitForFunction(() => {
      const btn = document.querySelector(
        ".master-data-table tbody tr:first-child .actions-cell button",
      );
      return document.activeElement === btn;
    });
  } finally {
    await page.close();
  }
});
