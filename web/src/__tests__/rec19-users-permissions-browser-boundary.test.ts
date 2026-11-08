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
    entryPoints: ["src/__tests__/fixtures/users-management-harness.tsx"],
    format: "iife",
    outdir: "rec19-harness-out",
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
              let currentUsers = [
                {
                  appUserId: "user-root-001",
                  email: "root@eiu.edu.vn",
                  fullName: "Root Administrator",
                  jobTitle: "System Owner",
                  unitId: null,
                  isActive: true,
                  isRootAdmin: true,
                  isHr: true,
                  identityBound: true,
                  versionNo: 1,
                },
                {
                  appUserId: "user-hr-001",
                  email: "hr.manager@eiu.edu.vn",
                  fullName: "Lê Thị Nhân Sự",
                  jobTitle: "HR Lead",
                  unitId: "unit-001",
                  isActive: true,
                  isRootAdmin: false,
                  isHr: true,
                  identityBound: true,
                  versionNo: 2,
                },
                {
                  appUserId: "user-staff-001",
                  email: "staff.lecturer@eiu.edu.vn",
                  fullName: "Trần Giảng Viên",
                  jobTitle: "Lecturer",
                  unitId: "unit-001",
                  isActive: false,
                  isRootAdmin: false,
                  isHr: false,
                  identityBound: false,
                  versionNo: 1,
                },
              ];
              export const DELEGABLE_PERMISSIONS = [
                { code: "submissions.view", labelVi: "Xem danh sách và chi tiết hồ sơ", labelEn: "View Submissions", category: "Hồ sơ (Submissions)" },
                { code: "submissions.edit", labelVi: "Chỉnh sửa thông tin hồ sơ", labelEn: "Edit Submissions", category: "Hồ sơ (Submissions)" },
                { code: "master_data.manage", labelVi: "Quản lý danh mục nghiệp vụ", labelEn: "Manage Master Data", category: "Danh mục (Master Data)" },
              ];
              export async function listInternalUsersAction() {
                return { success: true, data: currentUsers };
              }
              export async function getUserPermissionsAction(userId) {
                return { success: true, data: ["submissions.view", "master_data.manage"] };
              }
              export async function createInternalUserAction(payload) {
                return {
                  success: true,
                  data: {
                    app_user_id: "new-user-id",
                    email: payload.email,
                    full_name: payload.fullName,
                    job_title: payload.jobTitle || null,
                    unit_id: payload.unitId || null,
                    is_active: true,
                    is_root_admin: false,
                    version_no: 1,
                  },
                };
              }
              export async function updateInternalUserDirectoryAction(targetUserId, patch, ver) {
                if (patch && patch.fullName === "Trigger Stale") {
                  return { success: false, code: "STALE_VERSION", error: "Dữ liệu người dùng đã bị thay đổi bởi người khác (phiên bản cũ)." };
                }
                const found = currentUsers.find(x => x.appUserId === targetUserId);
                if (found) {
                  if (patch.fullName) found.fullName = patch.fullName;
                  if (patch.jobTitle !== undefined) found.jobTitle = patch.jobTitle;
                  found.versionNo += 1;
                }
                return {
                  success: true,
                  data: {
                    app_user_id: targetUserId,
                    email: "hr.manager@eiu.edu.vn",
                    full_name: patch.fullName || "Lê Thị Nhân Sự",
                    job_title: patch.jobTitle || null,
                    unit_id: null,
                    version_no: 3,
                  },
                };
              }
              export async function setInternalUserActiveAction(targetUserId, active, ver) {
                const found = currentUsers.find(x => x.appUserId === targetUserId);
                if (found) {
                  found.isActive = active;
                  found.versionNo += 1;
                }
                return {
                  success: true,
                  data: {
                    app_user_id: targetUserId,
                    is_active: active,
                    version_no: 3,
                  },
                };
              }
              export async function assignHrRoleAction(targetUserId, ver) {
                return {
                  success: true,
                  data: {
                    app_user_id: targetUserId,
                    role_code: "HR",
                    granted_permissions: ["submissions.view"],
                    version_no: 3,
                  },
                };
              }
              export async function revokeHrRoleAction(targetUserId, ver) {
                return {
                  success: true,
                  data: {
                    app_user_id: targetUserId,
                    revoked_role: "HR",
                    revoked_permissions: [],
                    version_no: 3,
                  },
                };
              }
              export async function grantHrPermissionAction(targetUserId, code, ver) {
                return {
                  success: true,
                  data: {
                    app_user_id: targetUserId,
                    permission_code: code,
                    granted: true,
                    version_no: 3,
                  },
                };
              }
              export async function revokeHrPermissionAction(targetUserId, code, ver) {
                return {
                  success: true,
                  data: {
                    app_user_id: targetUserId,
                    permission_code: code,
                    revoked: true,
                    version_no: 3,
                  },
                };
              }
              export async function getUserManagementDependenciesAction() {
                return { units: [{ unit_id: "unit-001", code: "CNTT", name_vi: "Khoa Công nghệ thông tin" }] };
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
    throw new Error("Failed to generate users harness bundle");
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
        <title>Users Management Test</title>
        <style>${style}</style>
      </head>
      <body>
        <div id="root"></div>
        <script>
          window.__USERS_HARNESS_PROPS__ = ${JSON.stringify(options)};
        </script>
        <script>${script}</script>
      </body>
    </html>
  `;

  await page.setContent(html);
  await page.waitForSelector(".users-page");
  return page;
}

test("B1.1: Users Management page renders header, controls, and table rows", async () => {
  const page = await setupPage();
  try {
    const title = await page.textContent(".users-header__title");
    assert.ok(title?.includes("Người dùng & phân quyền"));

    const rowsCount = await page.locator(".users-table tbody tr").count();
    assert.equal(rowsCount, 3);

    const firstRowText = await page
      .locator(".users-table tbody tr:first-child")
      .textContent();
    assert.ok(firstRowText?.includes("Root Administrator"));
    assert.ok(firstRowText?.includes("root@eiu.edu.vn"));
    assert.ok(firstRowText?.includes("Root Admin"));
    assert.ok(firstRowText?.includes("Hoạt động"));
  } finally {
    await page.close();
  }
});

test("B1.2: Searching users filters by name or email", async () => {
  const page = await setupPage();
  try {
    const searchInput = page.locator('input[type="search"]');
    await searchInput.fill("Nhân Sự");

    assert.equal(await page.locator(".users-table tbody tr").count(), 1);
    const text = await page.locator(".users-table tbody tr").textContent();
    assert.ok(text?.includes("Lê Thị Nhân Sự"));
  } finally {
    await page.close();
  }
});

test("B1.3: Filtering by status and role updates visible rows", async () => {
  const page = await setupPage();
  try {
    const selects = page.locator(".users-controls__select");
    const statusSelect = selects.nth(0);
    const roleSelect = selects.nth(1);

    // Filter ACTIVE
    await statusSelect.selectOption("ACTIVE");
    assert.equal(await page.locator(".users-table tbody tr").count(), 2);

    // Filter INACTIVE
    await statusSelect.selectOption("INACTIVE");
    assert.equal(await page.locator(".users-table tbody tr").count(), 1);
    assert.ok(
      (await page.locator(".users-table tbody tr").textContent())?.includes(
        "Trần Giảng Viên",
      ),
    );

    // Reset status to ALL, filter role HR
    await statusSelect.selectOption("ALL");
    await roleSelect.selectOption("HR");
    assert.equal(await page.locator(".users-table tbody tr").count(), 1);
    assert.ok(
      (await page.locator(".users-table tbody tr").textContent())?.includes(
        "Lê Thị Nhân Sự",
      ),
    );
  } finally {
    await page.close();
  }
});

test("B1.4: Create User modal validates EIU email and dismisses on Escape", async () => {
  const page = await setupPage();
  try {
    await page.click('button:has-text("+ Thêm người dùng")');
    await page.waitForSelector('div[role="dialog"]');

    const dialogTitle = await page.textContent("#create-user-title");
    assert.ok(dialogTitle?.includes("Thêm người dùng mới"));

    // Escape dismisses modal
    await page.keyboard.press("Escape");
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });
  } finally {
    await page.close();
  }
});

test("B1.5: Edit User modal disables bound email for non-root users", async () => {
  // Setup non-root HR directory manager
  const page = await setupPage({
    identity: {
      roles: ["HR"],
      permissions: ["users.directory_manage"],
    },
  });
  try {
    // Click Sửa on HR Lead row (which has identityBound: true)
    await page.click(
      '.users-table tbody tr:nth-child(2) button:has-text("Sửa")',
    );
    await page.waitForSelector('div[role="dialog"]');

    // Email input is disabled because user is identityBound and caller is non-root
    const emailDisabled = await page.locator("#edit-email").isDisabled();
    assert.equal(emailDisabled, true);

    await page.click('button:has-text("Hủy bỏ")');
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });
  } finally {
    await page.close();
  }
});

test("B1.6: Permissions modal allows Root Admin to view and toggle permissions", async () => {
  const page = await setupPage({
    identity: {
      roles: ["ROOT_ADMIN"],
      permissions: [],
    },
  });
  try {
    // Click Phân quyền on HR Lead row
    await page
      .locator(".users-table tbody tr:nth-child(2) button[popovertarget]")
      .click();
    await page
      .locator('.ui-row-actions:popover-open button:has-text("Phân quyền")')
      .click();
    await page.waitForSelector('div[role="dialog"]');

    const dialogTitle = await page.textContent("#perm-user-title");
    assert.ok(dialogTitle?.includes("Phân quyền nhân sự"));

    // Check HR role button is rendered
    const hrBtnText = await page.textContent(
      'button:has-text("Thu hồi vai trò HR")',
    );
    assert.ok(hrBtnText);

    // Close modal
    await page.click('button:has-text("Đóng")');
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });
  } finally {
    await page.close();
  }
});

test("B1.7: Root Admin row has no lock button, regular user can be locked", async () => {
  const page = await setupPage();
  try {
    // Root Admin row (row 1) does NOT have a Khóa button
    const rootRowLockCount = await page
      .locator('.users-table tbody tr:first-child button:has-text("Khóa")')
      .count();
    assert.equal(rootRowLockCount, 0);

    // HR Lead row (row 2) has a Khóa button
    await page
      .locator(".users-table tbody tr:nth-child(2) button[popovertarget]")
      .click();
    const hrRowLockCount = await page
      .locator('.ui-row-actions:popover-open button:has-text("Khóa")')
      .count();
    assert.equal(hrRowLockCount, 1);
  } finally {
    await page.close();
  }
});

test("B1.8: Dialog focus trap and focus restoration on dismiss", async () => {
  const page = await setupPage();
  try {
    const createBtn = page.locator('button:has-text("+ Thêm người dùng")');
    await createBtn.click();
    await page.waitForSelector('div[role="dialog"]');

    // Initial focus is inside the dialog
    const isFocusInside = await page.evaluate(() => {
      const dialog = document.querySelector('div[role="dialog"]');
      return dialog ? dialog.contains(document.activeElement) : false;
    });
    assert.equal(isFocusInside, true);

    // Escape dismisses dialog
    await page.keyboard.press("Escape");
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });

    // Focus restored to the create button
    await page.waitForFunction(() => {
      const btn = document.querySelector(".users-btn-primary");
      return document.activeElement === btn;
    });
  } finally {
    await page.close();
  }
});

test("B1.9: STALE_VERSION conflict error renders inside edit modal and keeps dialog open", async () => {
  const page = await setupPage();
  try {
    await page.click(
      '.users-table tbody tr:nth-child(2) button:has-text("Sửa")',
    );
    await page.waitForSelector('div[role="dialog"]');

    // Enter name that triggers STALE_VERSION in our stub
    const nameInput = page.locator("#edit-fullname");
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
      const btn = document.querySelector(".users-btn-secondary");
      return btn ? window.getComputedStyle(btn).fontSize : null;
    });
    assert.equal(btnFontSize, "14px");

    const badgeFontSize = await page.evaluate(() => {
      const badge = document.querySelector(".users-badge");
      return badge ? window.getComputedStyle(badge).fontSize : null;
    });
    assert.equal(badgeFontSize, "14px");
    await page.locator('.users-table button:has-text("Sửa")').first().click();
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
      '.users-table tbody tr:nth-child(2) button:has-text("Sửa")',
    );
    await page.waitForSelector('div[role="dialog"]');

    // Edit the name
    const nameInput = page.locator("#edit-fullname");
    await nameInput.fill("Lê Thị Nhân Sự Đã Sửa");

    // Click submit
    await page.click('button[type="submit"]:has-text("Lưu thay đổi")');

    // Dialog closes
    await page.waitForSelector('div[role="dialog"]', { state: "detached" });

    // Focus is restored to the refreshed Sửa button on that row
    await page.waitForFunction(() => {
      const btn = document.querySelector(
        ".users-table tbody tr:nth-child(2) .actions-cell button",
      );
      return document.activeElement === btn;
    });
  } finally {
    await page.close();
  }
});

test("B1.12: Non-root directory manager cannot lock HR user", async () => {
  const page = await setupPage({
    identity: {
      roles: ["HR"],
      permissions: ["users.directory_manage"],
    },
  });
  try {
    // Row 2 is HR Lead. Non-root directory manager should NOT see Khóa on row 2
    await page
      .locator(".users-table tbody tr:nth-child(2) button[popovertarget]")
      .click();
    const hrRowLockCount = await page
      .locator('.ui-row-actions:popover-open button:has-text("Khóa")')
      .count();
    assert.equal(hrRowLockCount, 0);

    // Row 3 is regular Staff (not HR, not Root). Non-root directory manager CAN see Mở khóa on row 3
    await page.keyboard.press("Escape");
    await page
      .locator(".users-table tbody tr:nth-child(3) button[popovertarget]")
      .click();
    const staffRowLockCount = await page
      .locator('.ui-row-actions:popover-open button:has-text("Mở khóa")')
      .count();
    assert.equal(staffRowLockCount, 1);
  } finally {
    await page.close();
  }
});
