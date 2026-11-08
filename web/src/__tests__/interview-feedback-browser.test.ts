import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import test from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { type Browser, chromium, type Page } from "playwright";

const port = 3418;
const base = `http://127.0.0.1:${port}`;
async function ready() {
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(base)).ok) return;
    } catch {}
    await sleep(200);
  }
  throw new Error("Preview test server did not start");
}
async function persona(page: Page, value: string) {
  await page.getByLabel("Trial persona").selectOption(value);
  await page
    .getByRole("heading", { name: "Interview feedback", exact: true })
    .waitFor();
}
async function setup(page: Page) {
  page.on("dialog", (dialog) => void dialog.accept());
  await page.addInitScript(() =>
    localStorage.setItem("eiu-recruitment-locale", "en"),
  );
  await page.goto(`${base}/interview-feedback`);
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
}
async function openOwn(page: Page) {
  await page.getByRole("link", { name: /Open feedback form/ }).click();
  await page
    .getByRole("heading", { name: "Individual feedback", exact: true })
    .waitFor();
}
async function noOverflow(page: Page, width: number) {
  await page.setViewportSize({ width, height: 900 });
  const size = await page.evaluate(() => ({
    w: document.documentElement.clientWidth,
    scroll: document.documentElement.scrollWidth,
  }));
  assert.ok(
    size.scroll <= size.w + 1,
    `Unexpected overflow at ${width}: ${JSON.stringify(size)}`,
  );
}
test("Feedback shared UI supports assignment, draft reload, own-only responses, approval and complete print snapshot", {
  timeout: 90000,
}, async () => {
  const server = spawn(
    process.execPath,
    ["scripts/preview-interview-feedback.mjs"],
    {
      env: { ...process.env, FEEDBACK_PREVIEW_PORT: String(port) },
      stdio: "pipe",
    },
  );
  let browser: Browser | undefined;
  try {
    await ready();
    browser = await chromium.launch();
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1000 },
    });
    const errors: string[] = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await setup(page);
    assert.ok(
      await page
        .getByText("Queued — delivery not configured. No email has been sent.")
        .isVisible(),
    );
    assert.equal(
      await page
        .getByRole("button", { name: "Create consolidated draft", exact: true })
        .isEnabled(),
      false,
    );
    await noOverflow(page, 360);
    await noOverflow(page, 1440);
    await persona(page, "evaluator-one");
    assert.equal(
      await page
        .getByRole("heading", { name: "Feedback tracking", exact: true })
        .count(),
      0,
    );
    await openOwn(page);
    await page
      .locator("#answer-professional_knowledge")
      .fill("First evaluator — careful technical understanding.");
    await page.getByRole("button", { name: "Save draft", exact: true }).click();
    await page.getByText("Saved successfully.", { exact: true }).waitFor();
    await page.reload();
    await page.locator("#answer-professional_knowledge").waitFor();
    assert.equal(
      await page.locator("#answer-professional_knowledge").inputValue(),
      "First evaluator — careful technical understanding.",
    );
    await page
      .locator("#answer-other_comment")
      .fill(
        Array.from(
          { length: 80 },
          (_, i) => `Detailed observation ${i + 1}`,
        ).join("\n"),
      );
    await page
      .getByRole("button", { name: "Submit response", exact: true })
      .click();
    await page.getByText("Submitted — immutable", { exact: false }).waitFor();
    assert.equal(
      await page
        .locator("#answer-professional_knowledge")
        .evaluate((element: HTMLTextAreaElement) => element.readOnly),
      true,
    );
    await page.locator("#answer-other_comment").focus();
    await page.keyboard.press("Control+End");
    assert.ok(
      await page
        .locator("#answer-other_comment")
        .evaluate(
          (element: HTMLTextAreaElement) =>
            element === document.activeElement &&
            element.readOnly &&
            element.scrollTop > 0 &&
            element.value.endsWith("Detailed observation 80"),
        ),
    );
    await persona(page, "evaluator-two");
    await openOwn(page);
    assert.equal(
      await page
        .getByText("First evaluator — careful technical understanding.", {
          exact: true,
        })
        .count(),
      0,
    );
    await page
      .locator("#answer-professional_knowledge")
      .fill("Second evaluator — clear explanations.");
    await page
      .getByRole("button", { name: "Submit response", exact: true })
      .click();
    await page.getByText("Submitted — immutable", { exact: false }).waitFor();
    await persona(page, "hr");
    await page
      .getByRole("button", { name: "Open feedback round", exact: true })
      .click();
    await page.getByText("View response", { exact: true }).first().click();
    assert.ok(
      await page
        .getByText("First evaluator — careful technical understanding.", {
          exact: true,
        })
        .isVisible(),
    );
    await page
      .getByLabel("Report title", { exact: true })
      .fill("Panel feedback — local trial");
    await page
      .getByLabel("Overall summary", { exact: true })
      .fill("Both evaluators completed their qualitative feedback.");
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
    assert.equal(
      await page.getByLabel("Report title", { exact: true }).isDisabled(),
      true,
    );
    assert.equal(await page.locator(".feedback-print-report h3").count(), 7);
    assert.ok(
      (await page
        .locator(".feedback-print-report")
        .getByText("No answer supplied", { exact: true })
        .count()) >= 5,
    );
    for (const width of [360, 1440]) await noOverflow(page, width);
    await page.emulateMedia({ media: "print" });
    assert.equal(
      await page
        .getByRole("button", { name: "Approve report", exact: true })
        .isVisible(),
      false,
    );
    assert.equal(
      await page
        .getByText("Tracking and consolidation", { exact: true })
        .isVisible(),
      false,
    );
    assert.ok(
      await page
        .locator(".feedback-print-report")
        .getByText("Second evaluator — clear explanations.", { exact: true })
        .isVisible(),
    );
    assert.deepEqual(errors, []);
  } finally {
    await browser?.close();
    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});
test("Feedback UI preserves unsaved answers on stale save and reloads latest versions explicitly", {
  timeout: 90000,
}, async () => {
  const server = spawn(
    process.execPath,
    ["scripts/preview-interview-feedback.mjs"],
    {
      env: { ...process.env, FEEDBACK_PREVIEW_PORT: String(port) },
      stdio: "pipe",
    },
  );
  let browser: Browser | undefined;
  try {
    await ready();
    browser = await chromium.launch();
    const context = await browser.newContext();
    const first = await context.newPage();
    await setup(first);
    await persona(first, "evaluator-one");
    await openOwn(first);
    const second = await context.newPage();
    second.on("dialog", (d) => void d.accept());
    await second.goto(first.url());
    await second.locator("#answer-professional_knowledge").waitFor();
    await first
      .locator("#answer-professional_knowledge")
      .fill("Saved in first tab");
    await first
      .getByRole("button", { name: "Save draft", exact: true })
      .click();
    await first.getByText("Saved successfully.", { exact: true }).waitFor();
    await second
      .locator("#answer-professional_knowledge")
      .fill("Unsaved second tab text");
    await second
      .getByRole("button", { name: "Save draft", exact: true })
      .click();
    await second
      .getByRole("alert")
      .filter({ hasText: "The record changed" })
      .waitFor();
    assert.equal(
      await second.locator("#answer-professional_knowledge").inputValue(),
      "Unsaved second tab text",
    );
    await first
      .locator("#answer-professional_knowledge")
      .fill("Newest after conflict");
    await first
      .getByRole("button", { name: "Save draft", exact: true })
      .click();
    await first.getByText("Saved successfully.", { exact: true }).waitFor();
    await second
      .getByRole("button", { name: "Use latest version", exact: true })
      .click();
    await second.waitForFunction(
      () =>
        (
          document.querySelector(
            "#answer-professional_knowledge",
          ) as HTMLTextAreaElement
        )?.value === "Newest after conflict",
    );
    assert.equal(
      await second.locator("#answer-professional_knowledge").inputValue(),
      "Newest after conflict",
    );
  } finally {
    await browser?.close();
    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});

test("Feedback template publishing keeps required fields and revocation keeps the confirmed denominator", {
  timeout: 90000,
}, async () => {
  const server = spawn(
    process.execPath,
    ["scripts/preview-interview-feedback.mjs"],
    {
      env: { ...process.env, FEEDBACK_PREVIEW_PORT: String(port) },
      stdio: "pipe",
    },
  );
  let browser: Browser | undefined;
  try {
    await ready();
    browser = await chromium.launch();
    const page = await browser.newPage({
      viewport: { width: 360, height: 900 },
    });
    page.on("dialog", (d) => void d.accept());
    await page.addInitScript(() =>
      localStorage.setItem("eiu-recruitment-locale", "en"),
    );
    await page.goto(`${base}/interview-feedback`);
    await revealFeedbackSetup(page, "Questionnaire versions");
    await page
      .getByRole("button", { name: "New template", exact: true })
      .click();
    await page
      .getByLabel("Template name", { exact: true })
      .fill("Required trial");
    await page
      .getByRole("checkbox", { name: "Required", exact: true })
      .first()
      .focus();
    await page.keyboard.press("Space");
    assert.equal(
      await page
        .getByRole("checkbox", { name: "Required", exact: true })
        .first()
        .isChecked(),
      true,
    );
    await page
      .getByRole("button", { name: "Publish version", exact: true })
      .focus();
    await page.keyboard.press("Enter");
    await page
      .getByText("New version published. Existing collections are unchanged.", {
        exact: true,
      })
      .waitFor();
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
      .getByRole("heading", { name: "Tracking and consolidation" })
      .waitFor();
    await noOverflow(page, 360);
    await persona(page, "evaluator-one");
    await openOwn(page);
    await page.getByRole("button", { name: "Save draft", exact: true }).click();
    await page.getByText("Saved successfully.", { exact: true }).waitFor();
    await page
      .getByRole("button", { name: "Submit response", exact: true })
      .click();
    assert.equal(
      await page
        .locator("#answer-professional_knowledge")
        .evaluate((e: HTMLTextAreaElement) => e.validity.valueMissing),
      true,
    );
    assert.equal(
      await page.getByText("Submitted — immutable", { exact: false }).count(),
      0,
    );
    assert.equal(
      await page
        .locator("#answer-professional_knowledge")
        .evaluate((element) => element === document.activeElement),
      true,
    );

    await persona(page, "hr");
    await page
      .getByRole("button", { name: "Open feedback round", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Revoke", exact: true })
      .first()
      .click();
    await page
      .getByText("Nguyễn Minh Tâm: Invitation revoked", { exact: true })
      .waitFor();
    assert.equal(
      await page
        .getByRole("button", { name: "Create consolidated draft", exact: true })
        .isEnabled(),
      false,
    );
    assert.ok(
      await page.getByText("Submitted: 0/2", { exact: true }).isVisible(),
    );
  } finally {
    await browser?.close();
    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});
test("Feedback pagination cannot submit a template or participant hidden on another page", {
  timeout: 90000,
}, async () => {
  const server = spawn(
    process.execPath,
    ["scripts/preview-interview-feedback.mjs"],
    {
      env: { ...process.env, FEEDBACK_PREVIEW_PORT: String(port) },
      stdio: "pipe",
    },
  );
  let browser: Browser | undefined;
  try {
    await ready();
    browser = await chromium.launch();
    const page = await browser.newPage();
    page.on("dialog", (d) => void d.accept());
    await page.addInitScript(() =>
      localStorage.setItem("eiu-recruitment-locale", "en"),
    );
    await page.goto(`${base}/interview-feedback`);
    await revealFeedbackSetup(page);
    await page.getByLabel("Candidate and interview round").waitFor();
    await page.evaluate(() => {
      const key = "eiu-synthetic-interview-feedback-v1";
      const value = JSON.parse(localStorage.getItem(key) ?? "{}");
      const template = value.templates[0];
      const interview = value.interviews[0];
      value.templates = Array.from({ length: 51 }, (_, n) => ({
        ...template,
        template_id: `10100000-0000-4000-8000-${String(n + 100).padStart(12, "0")}`,
        name: `Template ${n + 1}`,
      }));
      value.interviews = Array.from({ length: 51 }, (_, n) => ({
        ...interview,
        interview_id: `10100000-0000-4000-8000-${String(n + 200).padStart(12, "0")}`,
        candidate_name: `Candidate ${n + 1}`,
      }));
      localStorage.setItem(key, JSON.stringify(value));
    });
    await page.reload();
    await revealFeedbackSetup(page);
    await page.getByLabel("Published questionnaire").selectOption({ index: 2 });
    await revealFeedbackSetup(page);
    await page
      .getByLabel("Candidate and interview round")
      .selectOption({ index: 1 });
    await page.getByLabel("Nguyễn Minh Tâm", { exact: true }).check();
    await page.getByRole("button", { name: "Next page", exact: true }).click();
    await page.getByText("Page 2", { exact: true }).waitFor();
    assert.equal(
      await page.getByLabel("Candidate and interview round").inputValue(),
      "",
    );
    await revealFeedbackSetup(page);
    await page
      .getByLabel("Candidate and interview round")
      .selectOption({ index: 1 });
    assert.equal(
      await page
        .getByRole("button", {
          name: "Assign forms to evaluators",
          exact: true,
        })
        .isEnabled(),
      false,
    );
    await page.getByLabel("Nguyễn Minh Tâm", { exact: true }).check();
    assert.equal(
      await page
        .getByLabel("Published questionnaire")
        .locator("option:checked")
        .textContent(),
      "Template 2 · v1",
    );
    await revealFeedbackSetup(page);
    await page
      .getByLabel("Published questionnaire")
      .selectOption("10100000-0000-4000-8000-000000000150");
    assert.equal(
      await page.getByLabel("Published questionnaire").inputValue(),
      "10100000-0000-4000-8000-000000000150",
    );
    await page
      .getByRole("button", { name: "Assign forms to evaluators", exact: true })
      .click();
    await page
      .getByRole("heading", { name: "Tracking and consolidation" })
      .waitFor();
    assert.ok(
      await page
        .getByText("Template 51 · Version 1", { exact: true })
        .isVisible(),
    );
  } finally {
    await browser?.close();
    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
  }
});

test("Feedback second interview page retains a visible authorized template and supports publishing there", {
  timeout: 90000,
}, async () => {
  const server = spawn(
    process.execPath,
    ["scripts/preview-interview-feedback.mjs"],
    {
      env: { ...process.env, FEEDBACK_PREVIEW_PORT: String(port) },
      stdio: "pipe",
    },
  );
  let browser: Browser | undefined;
  try {
    await ready();
    browser = await chromium.launch();
    const page = await browser.newPage();
    page.on("dialog", (d) => void d.accept());
    await page.addInitScript(() =>
      localStorage.setItem("eiu-recruitment-locale", "en"),
    );
    await page.goto(`${base}/interview-feedback`);
    await revealFeedbackSetup(page);
    await page.getByLabel("Candidate and interview round").waitFor();
    await page.evaluate(() => {
      const key = "eiu-synthetic-interview-feedback-v1";
      const value = JSON.parse(localStorage.getItem(key) ?? "{}");
      const interview = value.interviews[0];
      value.interviews = Array.from({ length: 51 }, (_, n) => ({
        ...interview,
        interview_id: `10100000-0000-4000-8000-${String(n + 200).padStart(12, "0")}`,
        candidate_name: `Candidate ${n + 1}`,
      }));
      localStorage.setItem(key, JSON.stringify(value));
    });
    await page.reload();
    const originalTemplate = await page
      .getByLabel("Published questionnaire")
      .inputValue();
    await page.getByRole("button", { name: "Next page", exact: true }).click();
    await page.getByText("Page 2", { exact: true }).waitFor();
    assert.equal(
      await page.getByLabel("Published questionnaire").inputValue(),
      originalTemplate,
    );
    assert.equal(
      await page
        .getByLabel("Published questionnaire")
        .locator("option:checked")
        .textContent(),
      "Phiếu nhận xét phỏng vấn / Interview feedback · v1",
    );
    await revealFeedbackSetup(page);
    await page
      .getByLabel("Candidate and interview round")
      .selectOption({ index: 1 });
    await page.getByLabel("Nguyễn Minh Tâm", { exact: true }).check();
    assert.equal(
      await page
        .getByRole("button", {
          name: "Assign forms to evaluators",
          exact: true,
        })
        .isEnabled(),
      true,
    );
    await page
      .getByRole("button", { name: "Assign forms to evaluators", exact: true })
      .click();
    await page
      .getByRole("heading", { name: "Tracking and consolidation" })
      .waitFor();
    assert.ok(
      await page
        .getByText(
          "Phiếu nhận xét phỏng vấn / Interview feedback · Version 1",
          { exact: true },
        )
        .isVisible(),
    );
    await page
      .getByRole("button", { name: "Back to workspace", exact: true })
      .click();
    await revealFeedbackSetup(page, "Questionnaire versions");
    await page
      .getByRole("button", { name: "New template", exact: true })
      .click();
    await page
      .getByLabel("Template name", { exact: true })
      .fill("Published on page two");
    await page
      .getByRole("button", { name: "Publish version", exact: true })
      .click();
    await page
      .getByText("New version published. Existing collections are unchanged.", {
        exact: true,
      })
      .waitFor();
    assert.equal(
      await page
        .getByLabel("Published questionnaire")
        .locator("option:checked")
        .textContent(),
      "Published on page two · v1",
    );
    assert.equal(
      await page
        .getByRole("button", { name: "Next page", exact: true })
        .isEnabled(),
      false,
    );
  } finally {
    await browser?.close();
    if (server.exitCode === null) {
      server.kill();
      await once(server, "exit");
    }
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
