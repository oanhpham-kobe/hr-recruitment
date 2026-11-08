import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";
import { chromium, type Page } from "playwright";

const key = "eiu-project-synthetic-uat-v1";

test("Project trial guide switches roles, opens every catalog and exports readable notes offline", {
  timeout: 90000,
}, async () => {
  const dir = await mkdtemp(join(tmpdir(), "eiu-project-preview-"));
  const out = join(dir, "guide.html");
  execFileSync(process.execPath, [
    "scripts/preview-project.mjs",
    "--build-only",
    "--output",
    out,
  ]);
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      offline: true,
      acceptDownloads: true,
    });
    const page = await context.newPage();
    const errors: string[] = [];
    const outbound: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("request", (request) => {
      if (/^https?:/.test(request.url())) outbound.push(request.url());
    });
    await page.goto(`${pathToFileURL(out).href}#/guide`);
    await page
      .getByRole("button", {
        name: "Mở bước: Gửi một phiếu ứng tuyển",
        exact: true,
      })
      .click();
    await page
      .getByRole("heading", {
        name: "Cổng ứng viên / Candidate portal",
        exact: true,
      })
      .waitFor();
    assert.equal(await selectedRole(page), "candidate");
    await route(page, "/guide");
    await page
      .getByRole("button", { name: "Mở bước: HR mở NEW → READ", exact: true })
      .click();
    await page
      .getByRole("heading", { name: "Quản lý Phiếu Ứng tuyển", exact: true })
      .waitFor();
    assert.equal(await selectedRole(page), "hr");
    await role(page, "root");
    await route(page, "/master-data");
    const catalog = page.getByLabel("Danh mục:", { exact: true });
    const values = await catalog
      .locator("option")
      .evaluateAll((options) =>
        options.map((option) => (option as HTMLOptionElement).value),
      );
    assert.equal(values.length, 11);
    for (const value of values) {
      await catalog.selectOption(value);
      await page
        .getByRole("button", { name: "+ Thêm mới", exact: true })
        .click();
      const dialog = page.getByRole("dialog");
      await dialog
        .getByRole("heading", { name: "Thêm mới mục danh mục", exact: true })
        .waitFor();
      await dialog.getByRole("button", { name: "Đóng", exact: true }).click();
      assert.equal(await catalog.inputValue(), value);
    }
    for (const width of [1440, 1366, 768, 390, 360, 320]) {
      await page.setViewportSize({
        width,
        height: width === 1366 ? 768 : width <= 430 ? 844 : 900,
      });
      for (const path of [
        "/",
        "/users",
        "/master-data",
        "/interviews",
        "/reports",
        "/interview-feedback",
      ]) {
        await route(page, path);
        if (path === "/" && width <= 767) {
          const inputSizes = await page
            .locator(
              ".application-inbox__toolbar input, .application-inbox__toolbar select",
            )
            .evaluateAll((elements) =>
              elements.map((el) =>
                Number.parseFloat(getComputedStyle(el).fontSize),
              ),
            );
          assert.ok(
            inputSizes.length > 0 && inputSizes.every((size) => size >= 16),
            "Phone filter inputs retain16px",
          );
        }
        if (path === "/" && [320, 390, 1440].includes(width)) {
          const about = page.getByRole("button", {
            name: "Thông tin về trang / About this page",
            exact: true,
          });
          await about.click();
          const context = page.locator(
            ".workflow-page-context__panel:popover-open",
          );
          await context.waitFor();
          const contextBounds = await context.boundingBox();
          assert.ok(
            contextBounds &&
              contextBounds.x >= 12 &&
              contextBounds.x + contextBounds.width <= width - 12,
            `Page explanation stays inside${width}px viewport`,
          );
          await page.keyboard.press("Escape");
          await context.waitFor({ state: "hidden" });
          assert.equal(
            await about.evaluate((el) => el === document.activeElement),
            true,
          );
        }
        if (path === "/" && width === 390) {
          const list = await page
            .locator(".application-inbox__table-scroll")
            .boundingBox();
          assert.ok(
            list && list.height >= 300,
            "Collapsed Inbox controls leave a useful phone list viewport",
          );
          assert.equal(
            await page.locator("main .preview-controls").count(),
            0,
            "Demo setup stays outside content",
          );
          const trigger = page.getByRole("button", {
            name: "Mở vai thử nghiệm / Open trial workspace",
            exact: true,
          });
          const workspace = await openWorkspace(page);
          assert.equal(
            await workspace.locator("select").count(),
            1,
            "Exactly one role selector",
          );
          assert.equal(
            await workspace
              .getByLabel("Vai thử nghiệm / Trial role", { exact: true })
              .locator("option")
              .count(),
            6,
          );
          assert.equal(
            await page.locator("#app-root").getAttribute("inert"),
            "",
          );
          await page.keyboard.press("Escape");
          await workspace.waitFor({ state: "detached" });
          assert.equal(
            await trigger.evaluate((el) => el === document.activeElement),
            true,
          );
          const menu = page.getByRole("button", {
            name: "Mở menu",
            exact: true,
          });
          await menu.click();
          const navigation = page.getByRole("dialog", {
            name: "Điều hướng nội bộ",
            exact: true,
          });
          await navigation.waitFor();
          await page.keyboard.press("Escape");
          await navigation.waitFor({ state: "detached" });
          assert.equal(
            await menu.evaluate((el) => el === document.activeElement),
            true,
          );
        }
        assert.ok(
          await page.evaluate(
            () =>
              document.documentElement.scrollWidth <=
              document.documentElement.clientWidth + 1,
          ),
          `${path}@${width} must contain horizontal scrolling`,
        );
      }
    }
    await route(page, "/users");
    const createUser = page.getByRole("button", {
      name: "+ Thêm người dùng",
      exact: true,
    });
    for (const viewport of [
      { width: 1440, height: 600 },
      { width: 768, height: 360 },
      { width: 390, height: 360 },
      { width: 360, height: 360 },
    ]) {
      await page.setViewportSize(viewport);
      await createUser.click();
      const modal = page.getByRole("dialog");
      const footer = await modal.locator(".modal-footer").boundingBox();
      assert.ok(
        footer && footer.y >= 0 && footer.y + footer.height <= viewport.height,
        "Admin dialog actions stay within constrained viewport",
      );
      await modal.getByLabel("Thuộc Khoa / Phòng").focus();
      const field = await modal.getByLabel("Thuộc Khoa / Phòng").boundingBox();
      assert.ok(
        field && field.y >= 0 && field.y + field.height <= footer.y,
        "Final field scrolls above the footer on keyboard focus",
      );
      await page.keyboard.press("Escape");
      await modal.waitFor({ state: "detached" });
      await page.waitForFunction(
        () =>
          document.activeElement?.tagName === "BUTTON" &&
          document.activeElement?.textContent?.includes("Thêm người dùng"),
      );
      assert.equal(
        await createUser.evaluate((el) => el === document.activeElement),
        true,
        "Admin dialog restores its opening button",
      );
    }
    await page.setViewportSize({ width: 1440, height: 900 });
    const more = page.locator(".users-table button[popovertarget]").first();
    await more.focus();
    await page.keyboard.press("Enter");
    const actions = page.locator(".ui-row-actions:popover-open");
    await actions.waitFor();
    const bounds = await actions.boundingBox();
    assert.ok(
      bounds &&
        bounds.x >= 0 &&
        bounds.y >= 0 &&
        bounds.x + bounds.width <= 1440 &&
        bounds.y + bounds.height <= 900,
      "Row actions stay within the viewport",
    );
    await page.keyboard.press("Escape");
    assert.equal(
      await more.evaluate((el) => el === document.activeElement),
      true,
      "Native popover restores its trigger",
    );
    await more.click();
    await page.setViewportSize({ width: 390, height: 900 });
    await actions.waitFor({ state: "hidden" });
    await page.setViewportSize({ width: 1440, height: 900 });
    const faces = await page.evaluate(async () => {
      await document.fonts.ready;
      return (await document.fonts.load('400 16px "Be Vietnam Pro"')).map(
        (face) => ({ family: face.family, status: face.status }),
      );
    });
    assert.ok(
      faces.length > 0 && faces.every((face) => face.status === "loaded"),
      "Offline HTML loads the actual local font",
    );
    await route(page, "/guide");
    await page
      .getByLabel("Ghi chú thử nghiệm / Test notes")
      .fill("Ghi chú thử: kiểm tra lại nhãn trường và lịch phỏng vấn.");
    const downloadReady = page.waitForEvent("download");
    await page
      .getByRole("button", {
        name: "Xuất ghi chú / Export readable notes",
        exact: true,
      })
      .click();
    const download = await downloadReady;
    assert.ok(download.suggestedFilename().endsWith(".txt"));
    const notePath = join(dir, "notes.txt");
    await download.saveAs(notePath);
    assert.match(await readFile(notePath, "utf8"), /kiểm tra lại nhãn trường/);
    await page.reload();
    assert.match(
      await page.getByLabel("Ghi chú thử nghiệm / Test notes").inputValue(),
      /kiểm tra lại nhãn trường/,
    );
    await page.getByRole("button", { name: "Tiếng Anh", exact: true }).click();
    await page
      .getByRole("heading", { name: "Project test workspace", exact: true })
      .waitFor();
    assert.deepEqual(outbound, []);
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
    const inside = relative(resolve(tmpdir()), resolve(dir));
    assert.ok(
      inside &&
        !inside.startsWith("..") &&
        !isAbsolute(inside) &&
        basename(dir).startsWith("eiu-project-preview-"),
    );
    await rm(dir, { recursive: true, force: true });
  }
});
async function openWorkspace(p: Page) {
  await p
    .getByRole("button", {
      name: "Mở vai thử nghiệm / Open trial workspace",
      exact: true,
    })
    .click();
  return p.getByRole("dialog", {
    name: /Không gian thử nghiệm|Trial workspace/,
  });
}
async function selectedRole(p: Page) {
  const dialog = await openWorkspace(p);
  const value = await dialog
    .getByLabel("Vai thử nghiệm / Trial role", { exact: true })
    .inputValue();
  await p.keyboard.press("Escape");
  return value;
}
async function role(p: Page, value: string) {
  const dialog = await openWorkspace(p);
  await Promise.all([
    p.waitForEvent("load"),
    dialog
      .getByLabel("Vai thử nghiệm / Trial role", { exact: true })
      .selectOption(value),
  ]);
  await p
    .getByRole("button", {
      name: "Mở vai thử nghiệm / Open trial workspace",
      exact: true,
    })
    .waitFor();
}
async function route(p: Page, path: string) {
  await p.evaluate((path) => {
    location.hash = path;
  }, path);
  await p.waitForTimeout(80);
}
async function state(p: Page) {
  return p.evaluate((k) => {
    const raw = localStorage.getItem(k);
    if (!raw) throw new Error("Synthetic state is not initialized.");
    return JSON.parse(raw);
  }, key);
}
test("Standalone project preview connects candidate, assignment, rounds and questionnaire personas without network", {
  timeout: 120000,
}, async () => {
  const dir = await mkdtemp(join(tmpdir(), "eiu-project-preview-"));
  const out = join(dir, "preview.html");
  execFileSync(process.execPath, [
    "scripts/preview-project.mjs",
    "--build-only",
    "--output",
    out,
  ]);
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      offline: true,
      viewport: { width: 1440, height: 1000 },
    });
    const page = await context.newPage();
    const errors: string[] = [];
    const network: string[] = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("request", (r) => {
      if (/^https?:/.test(r.url())) network.push(r.url());
    });
    page.on("dialog", (d) => void d.accept());
    await page.goto(`${pathToFileURL(out).href}#/guide`);
    await page
      .getByRole("heading", { name: /Phòng thử nghiệm|Project test workspace/ })
      .waitFor();
    await role(page, "candidate");
    await route(page, "/candidate");
    await page
      .getByRole("button", { name: "Tạo phiếu mới / New submission" })
      .click();
    for (const width of [360, 390]) {
      await page.setViewportSize({ width, height: 900 });
      const submit = page.getByRole("button", {
        name: "Nộp hồ sơ / Submit Application",
        exact: true,
      });
      await submit.scrollIntoViewIfNeeded();
      const bounds = await submit.evaluate((button) => {
        const range = document.createRange();
        range.selectNodeContents(button);
        const text = range.getBoundingClientRect();
        const target = button.getBoundingClientRect();
        return {
          textTop: text.top,
          textBottom: text.bottom,
          targetTop: target.top,
          targetBottom: target.bottom,
        };
      });
      assert.ok(
        bounds.textTop >= bounds.targetTop &&
          bounds.textBottom <= bounds.targetBottom,
        `candidate@${width}: submit label must remain inside its button`,
      );
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.getByLabel("Họ và tên / Full name").fill("Ứng viên thử nghiệm");
    await page.locator("#phone").fill("0901234567");
    await page.locator("#dateOfBirth").fill("1995-03-10");
    await page.locator("#address").fill("Dữ liệu mẫu Bình Dương");
    await page.locator("#doc-type-select").selectOption({ index: 0 });
    await page.locator("#file-input").setInputFiles({
      name: "trial-cv.pdf",
      mimeType: "application/pdf",
      buffer: Buffer.from("%PDF-1.4 synthetic metadata fixture"),
    });
    await page.getByText("trial-cv.pdf", { exact: false }).first().waitFor();
    await page.locator("#privacyAcknowledged").focus();
    await page.keyboard.press("Space");
    await page
      .getByRole("button", { name: "Nộp hồ sơ / Submit Application" })
      .click();
    await page
      .getByRole("heading", { name: "Cổng ứng viên / Candidate portal" })
      .waitFor();
    assert.equal(
      (await state(page)).submissions.at(-1).full_name,
      "Ứng viên thử nghiệm",
    );
    await role(page, "hr");
    await route(page, "/");
    await page.getByRole("button", { name: /Xem chi tiết phiếu của/ }).click();
    await page.getByText(/Trạng thái: READ/).waitFor();
    await page
      .getByRole("button", { name: "+ Gán vị trí tuyển dụng mới", exact: true })
      .click();
    await page
      .getByLabel("Khoa / Phòng *", { exact: true })
      .selectOption({ index: 1 });
    await page.locator("#assign-team").selectOption({ index: 1 });
    await page
      .getByLabel("Vị trí tuyển dụng *", { exact: true })
      .selectOption({ index: 1 });
    await page
      .getByLabel("Người phụ trách HR *", { exact: true })
      .selectOption({ index: 1 });
    await page
      .getByRole("button", { name: "Tạo Application", exact: true })
      .click();
    await page.waitForTimeout(100);
    assert.equal((await state(page)).applications.length, 1);
    await route(page, "/interviews");
    await page.getByRole("button", { name: "Mở", exact: true }).click();
    assert.equal(await page.locator("#app-root").getAttribute("inert"), "");
    await page.keyboard.press("Escape");
    await page.getByRole("dialog").waitFor({ state: "detached" });
    assert.equal(await page.locator("#app-root").getAttribute("inert"), null);
    await page.getByRole("button", { name: "Mở", exact: true }).click();
    const drawer = page.getByRole("dialog");
    await drawer
      .getByLabel("Bắt đầu", { exact: true })
      .fill("2027-01-10T09:00");
    await drawer
      .getByLabel("Kết thúc", { exact: true })
      .fill("2027-01-10T10:00");
    await drawer
      .getByLabel("Hình thức", { exact: false })
      .selectOption({ index: 1 });
    await drawer
      .getByLabel("Phòng", { exact: false })
      .selectOption({ index: 1 });
    await drawer.getByRole("button", { name: "Lưu lịch", exact: true }).click();
    for (const label of ["Nguyễn Minh Tâm", "Trần Thu Hà"]) {
      await drawer.getByLabel("Thêm người đang hoạt động").selectOption({
        label:
          label +
          " — " +
          (label === "Nguyễn Minh Tâm" ? "interviewerA" : "interviewerB") +
          "@eiu.edu.vn",
      });
      await drawer.getByRole("button", { name: "Thêm", exact: true }).click();
    }
    assert.equal(
      (await state(page)).applications[0].rounds[0].participants.length,
      2,
    );
    await route(page, "/reports");
    await role(page, "interviewerA");
    await page.getByRole("button", { name: "Tiếng Anh", exact: true }).click();
    await page.getByRole("button", { name: "Report", exact: true }).click();
    await page
      .getByLabel("Professional Knowledge", { exact: true })
      .fill("Knowledge from actual own form");
    await page
      .getByLabel("Conclusion", { exact: true })
      .fill("Proceed to discussion");
    await page
      .getByRole("button", { name: "Save report", exact: true })
      .click();
    await page.waitForTimeout(80);
    assert.equal((await state(page)).reports.length, 1);
    await route(page, "/interview-feedback");
    await role(page, "hr");
    await revealFeedbackSetup(page);
    await page
      .getByLabel("Candidate and interview round")
      .selectOption({ index: 1 });
    await page.getByLabel("Nguyễn Minh Tâm", { exact: true }).check();
    await page.getByLabel("Trần Thu Hà", { exact: true }).check();
    await page
      .getByRole("button", { name: "Assign forms to evaluators", exact: true })
      .click();
    await page
      .getByRole("heading", { name: "Tracking and consolidation", exact: true })
      .waitFor();
    assert.equal(
      (await state(page)).feedback.collections[0].interview_id,
      (await state(page)).applications[0].rounds[0].interviewId,
    );
    for (const who of ["interviewerA", "interviewerB"]) {
      await route(page, "/interview-feedback");
      await role(page, who);
      await page.getByRole("link", { name: /Open feedback form/ }).click();
      await page
        .locator("#answer-professional_knowledge")
        .fill(`${who} qualitative answer`);
      await page
        .getByRole("button", { name: "Save draft", exact: true })
        .click();
      await page.getByText("Saved successfully.", { exact: true }).waitFor();
      await page.reload();
      assert.equal(
        await page.locator("#answer-professional_knowledge").inputValue(),
        `${who} qualitative answer`,
      );
      await page
        .getByRole("button", { name: "Submit response", exact: true })
        .click();
      await page.getByText("Submitted — immutable", { exact: false }).waitFor();
    }
    await route(page, "/interview-feedback");
    await role(page, "hr");
    await page
      .getByRole("button", { name: "Open feedback round", exact: true })
      .click();
    await page
      .getByLabel("Report title", { exact: true })
      .fill("Trial panel report");
    await page
      .getByLabel("Overall summary", { exact: true })
      .fill("Two completed opinions");
    await page
      .getByRole("button", { name: "Create consolidated draft", exact: true })
      .click();
    await page.locator(".feedback-print-report").waitFor();
    await page
      .getByRole("button", { name: "Approve report", exact: true })
      .click();
    await page
      .locator(".feedback-print-report")
      .getByText(/Approved/)
      .waitFor();
    assert.equal((await state(page)).feedback.reports[0].state, "APPROVED");
    assert.equal(
      (await state(page)).applications[0].rounds[0].reportStatus,
      "INTERVIEW_SCHEDULING",
    );
    await page.emulateMedia({ media: "print" });
    assert.equal(
      await page.locator(".feedback-print-report").isVisible(),
      true,
    );
    await page.emulateMedia({ media: "screen" });
    for (const width of [360, 1440]) {
      await page.setViewportSize({ width, height: 900 });
      assert.ok(
        await page.evaluate(
          () =>
            document.documentElement.scrollWidth <=
            document.documentElement.clientWidth + 1,
        ),
      );
    }
    await page.setViewportSize({ width: 360, height: 900 });
    for (const [path, rowSelector, pagerSelector] of [
      ["/interviews", ".interview-table tbody tr", ".interview-pagination"],
      [
        "/inbox",
        ".application-inbox__table tbody tr",
        ".application-inbox__pagination",
      ],
    ]) {
      await route(page, path);
      const expand = page
        .locator(`${rowSelector} button[aria-expanded=false]`)
        .first();
      if (await expand.count()) await expand.click();
      const scroll = page.locator(
        path === "/interviews"
          ? ".interview-table-scroll"
          : ".application-inbox__table-scroll",
      );
      const scrollBounds = await scroll.boundingBox();
      const pager = await page.locator(pagerSelector).boundingBox();
      assert.ok(
        scrollBounds &&
          pager &&
          pager.y >= scrollBounds.y + scrollBounds.height - 1 &&
          pager.y + pager.height <= 900,
        `${path}: phone pager stays outside the bounded card list`,
      );
      await scroll.evaluate((el) => {
        el.scrollTop = el.scrollHeight;
      });
      const lastRow = await page.locator(rowSelector).last().boundingBox();
      assert.ok(
        lastRow && pager && lastRow.y + lastRow.height <= pager.y + 1,
        `${path}: the final expanded card is reachable above the pager`,
      );
      await page.setViewportSize({ width: 360, height: 500 });
      const shortLast = await page.locator(rowSelector).last().boundingBox();
      const shortPager = await page.locator(pagerSelector).boundingBox();
      assert.ok(
        shortLast &&
          shortPager &&
          shortPager.y >= shortLast.y + shortLast.height - 1,
        `${path}: short viewport returns to reachable document flow`,
      );
      await page.setViewportSize({ width: 360, height: 900 });
    }
    for (const viewport of [
      { width: 320, height: 900 },
      { width: 390, height: 360 },
      { width: 768, height: 360 },
    ]) {
      await page.setViewportSize(viewport);
      await route(page, "/interviews");
      await page
        .getByRole("button", { name: "Mở", exact: true })
        .first()
        .click();
      const drawer = page.getByRole("dialog");
      const logistics = await drawer
        .locator(".interview-form-grid > label")
        .evaluateAll((fields) =>
          fields.slice(0, 2).map((field) => {
            const bounds = field.getBoundingClientRect();
            return {
              left: bounds.left,
              right: bounds.right,
              top: bounds.top,
              bottom: bounds.bottom,
            };
          }),
        );
      assert.equal(logistics.length, 2);
      assert.ok(
        viewport.width <= 640
          ? Math.abs(logistics[0].left - logistics[1].left) <= 1 &&
              logistics[1].top >= logistics[0].bottom
          : logistics[1].left >= logistics[0].right,
        "Portalled logistics fields stack on phones and share a row on tablets",
      );
      for (const label of [
        "Bắt đầu",
        "Kết thúc",
        "Tìm người tham dự",
        "Thêm người đang hoạt động",
      ]) {
        const field = drawer.getByLabel(label).first();
        await field.focus();
        const geometry = await field.evaluate((el) => {
          const body = el.closest(".ui-drawer__body");
          if (!body) throw new Error("Drawer body missing");
          const target = el.getBoundingClientRect();
          const bounds = body.getBoundingClientRect();
          return {
            fits:
              target.left >= bounds.left - 1 &&
              target.right <= bounds.right + 1 &&
              target.top >= bounds.top - 1 &&
              target.bottom <= bounds.bottom + 1,
            client: body.clientWidth,
            scroll: body.scrollWidth,
          };
        });
        assert.ok(
          geometry.fits && geometry.scroll <= geometry.client + 1,
          `${label}: focused portalled field stays inside its narrow/short scroll area`,
        );
      }
      await page.keyboard.press("Escape");
      await drawer.waitFor({ state: "detached" });
    }
    await route(page, "/guide");
    await openWorkspace(page);
    await page
      .getByRole("button", { name: "Bắt đầu lại / Reset all", exact: true })
      .click();
    await page
      .getByRole("heading", { name: /Phòng thử nghiệm|Project test workspace/ })
      .waitFor();
    assert.equal((await state(page)).applications.length, 0);
    assert.equal((await state(page)).feedback.collections.length, 0);
    assert.deepEqual(errors, []);
    assert.deepEqual(network, []);
  } finally {
    await browser.close();
    const inside = relative(resolve(tmpdir()), resolve(dir));
    assert.ok(
      inside &&
        !inside.startsWith("..") &&
        !isAbsolute(inside) &&
        basename(dir).startsWith("eiu-project-preview-"),
    );
    await rm(dir, { recursive: true, force: true });
  }
});

async function revealFeedbackSetup(
  page: Page,
  label = "Assign feedback forms",
) {
  const summary = page.locator("summary").filter({ hasText: label });
  await summary.waitFor();
  if (
    !(await summary.evaluate(
      (el) => (el.parentElement as HTMLDetailsElement).open,
    ))
  )
    await summary.click();
}
