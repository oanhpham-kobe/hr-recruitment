import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { build } from "esbuild";
import { type Browser, chromium } from "playwright";
import { reduceApplicationInboxReadState } from "@/components/inbox/ApplicationInboxTable";
import {
  type ApplicationInboxSubmission,
  filterApplicationInboxGroups,
  INITIAL_APPLICATION_INBOX_FILTERS,
  paginateApplicationInboxGroups,
  projectApplicationInboxGroups,
} from "@/lib/application-inbox/model";
import {
  ApplicationInboxAccessError,
  loadApplicationInbox,
} from "@/lib/application-inbox/server";
import type { AppSession } from "@/lib/auth/session";

const candidateOneLatest: ApplicationInboxSubmission = {
  submissionId: "submission-2",
  candidateId: "candidate-1",
  status: "READ",
  fullName: "Nguyễn Thị An",
  dateOfBirth: "1995-08-15",
  gender: "FEMALE",
  phone: "0901 234 567",
  hrNote: "Đã liên hệ",
  submittedAt: "2026-09-02T09:00:00.000Z",
  hasApplication: false,
  versionNo: 1,
};

const candidateOneHistorical: ApplicationInboxSubmission = {
  ...candidateOneLatest,
  submissionId: "submission-1",
  status: "NEW",
  submittedAt: "2026-08-15T09:00:00.000Z",
};

const candidateTwo: ApplicationInboxSubmission = {
  ...candidateOneLatest,
  submissionId: "submission-3",
  candidateId: "candidate-2",
  fullName: "Trần Minh Bình",
  status: "PROCESSED",
  submittedAt: "2026-08-01T09:00:00.000Z",
  hasApplication: true,
  phone: "0987 654 321",
};

function internalSession(
  permissions: string[],
  isInternal = true,
  roles = isInternal ? ["HR"] : ["CANDIDATE"],
): AppSession {
  return {
    isAuthenticated: true,
    user: {
      authUserId: "internal-auth-user",
      email: isInternal ? "hr@eiu.edu.vn" : "candidate@example.com",
      isInternal,
      isCandidate: !isInternal,
      appUserId: isInternal ? "app-user-1" : undefined,
      candidateId: isInternal ? undefined : "candidate-1",
      roles,
      permissions,
    },
  };
}

function createInboxClient(options: {
  rows?: Record<string, unknown>[];
  isRootAdmin?: boolean;
}) {
  let submissionQueryCount = 0;
  const rpcCalls: { args: Record<string, unknown>; name: string }[] = [];

  const client = {
    rpc(name: string, args: Record<string, unknown>) {
      submissionQueryCount += 1;
      rpcCalls.push({ name, args });
      return Promise.resolve({ data: options.rows ?? [], error: null });
    },
    from(table: string) {
      if (table === "app_users") {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: async () => ({
                    data: { is_root_admin: options.isRootAdmin === true },
                    error: null,
                  }),
                };
              },
            };
          },
        };
      }

      throw new Error(`Unexpected table query: ${table}`);
    },
  } as unknown as SupabaseClient;

  return {
    client,
    getRpcCalls: () => rpcCalls,
    getSubmissionQueryCount: () => submissionQueryCount,
  };
}

test("Application Inbox read seam rejects unauthenticated, Candidate, and internal callers without submissions.view before PII fetch", async () => {
  const unauthenticatedClient = createInboxClient({});
  await assert.rejects(
    () =>
      loadApplicationInbox({
        client: unauthenticatedClient.client,
        resolveSession: async () => ({ isAuthenticated: false, user: null }),
      }),
    ApplicationInboxAccessError,
  );
  assert.equal(unauthenticatedClient.getSubmissionQueryCount(), 0);

  const candidateClient = createInboxClient({});
  await assert.rejects(
    () =>
      loadApplicationInbox({
        client: candidateClient.client,
        resolveSession: async () => internalSession(["candidate.self"], false),
      }),
    ApplicationInboxAccessError,
  );
  assert.equal(candidateClient.getSubmissionQueryCount(), 0);

  const internalClient = createInboxClient({});
  await assert.rejects(
    () =>
      loadApplicationInbox({
        client: internalClient.client,
        resolveSession: async () => internalSession([]),
      }),
    ApplicationInboxAccessError,
  );
  assert.equal(internalClient.getSubmissionQueryCount(), 0);
});

test("Application Inbox Root Admin bypasses submissions.view and receives only mapped Candidate groups", async () => {
  const client = createInboxClient({
    isRootAdmin: true,
    rows: [
      {
        submission_id: "submission-2",
        candidate_id: "candidate-1",
        status_code: "READ",
        full_name: "Nguyễn Thị An",
        date_of_birth: "1995-08-15",
        gender_code: "FEMALE",
        phone: "0901 234 567",
        hr_note: null,
        submitted_at: "2026-09-02T09:00:00.000Z",
        candidates: {
          candidate_id: "candidate-1",
          email: "an@example.com",
          is_active: true,
        },
        email: "an@example.com",
        is_candidate_active: true,
        has_application: false,
        total_count: 1,
        applications: [],
        private_address: "must not reach the view",
      },
    ],
  });

  const result = await loadApplicationInbox({
    client: client.client,
    resolveSession: async () => internalSession([], true, ["ROOT_ADMIN"]),
  });

  assert.equal(client.getSubmissionQueryCount(), 1);
  assert.equal(result.page, 1);
  assert.equal(result.pageCount, 1);
  assert.deepEqual(result.groups, [
    {
      candidateId: "candidate-1",
      email: "an@example.com",
      isCandidateActive: true,
      candidateVersionNo: 1,
      latestSubmissionId: "submission-2",
      latestSubmissionVersionNo: 1,
      submissions: [
        {
          submissionId: "submission-2",
          candidateId: "candidate-1",
          status: "READ",
          fullName: "Nguyễn Thị An",
          dateOfBirth: "1995-08-15",
          gender: "FEMALE",
          phone: "0901 234 567",
          hrNote: null,
          submittedAt: "2026-09-02T09:00:00.000Z",
          hasApplication: false,
          versionNo: 1,
        },
      ],
    },
  ]);
});

test("Candidate projection takes the deterministic latest Submission and paginates Candidate groups without splitting children", () => {
  const groups = projectApplicationInboxGroups([
    candidateOneHistorical,
    candidateTwo,
    candidateOneLatest,
  ]);
  groups[0].email = "an@example.com";
  groups[1].email = "binh@example.com";

  assert.equal(groups[0].candidateId, "candidate-1");
  assert.equal(groups[0].submissions[0].submissionId, "submission-2");
  assert.equal(groups[0].submissions.length, 2);
  assert.equal(groups[1].candidateId, "candidate-2");

  const firstPage = paginateApplicationInboxGroups(groups, 1, 1);
  const secondPage = paginateApplicationInboxGroups(groups, 2, 1);
  assert.deepEqual(
    firstPage.groups[0].submissions.map(
      (submission) => submission.submissionId,
    ),
    ["submission-2", "submission-1"],
  );
  assert.deepEqual(
    secondPage.groups[0].submissions.map(
      (submission) => submission.submissionId,
    ),
    ["submission-3"],
  );
});

test("Application Inbox server seam normalizes request-local filters and preserves Candidate page inputs at the RPC boundary", async () => {
  const client = createInboxClient({
    rows: [
      {
        submission_id: "submission-2",
        candidate_id: "candidate-1",
        status_code: "READ",
        full_name: "Nguyễn Thị An",
        date_of_birth: "1995-08-15",
        gender_code: "FEMALE",
        phone: "0901 234 567",
        hr_note: null,
        submitted_at: "2026-09-02T09:00:00.000Z",
        email: "an@example.com",
        is_candidate_active: true,
        has_application: false,
        total_count: 50,
      },
      {
        submission_id: "submission-1",
        candidate_id: "candidate-1",
        status_code: "NEW",
        full_name: "Nguyễn Thị An",
        date_of_birth: "1995-08-15",
        gender_code: "FEMALE",
        phone: "0901 234 567",
        hr_note: null,
        submitted_at: "2026-08-15T09:00:00.000Z",
        email: "an@example.com",
        is_candidate_active: true,
        has_application: false,
        total_count: 50,
      },
    ],
  });

  const result = await loadApplicationInbox({
    client: client.client,
    filters: {
      query: "  An  ",
      status: "READ",
      dateFrom: "2026-09-01",
      dateTo: "2026-09-02",
      candidateActivity: "ACTIVE",
      newRead: "READ",
      application: "NO_APPLICATION",
    },
    page: 2,
    pageSize: 25,
    resolveSession: async () => internalSession(["submissions.view"]),
  });

  assert.deepEqual(client.getRpcCalls(), [
    {
      name: "list_application_inbox",
      args: {
        p_query: "An",
        p_status: "READ",
        p_date_from: "2026-09-01",
        p_date_to: "2026-09-02",
        p_candidate_activity: "ACTIVE",
        p_new_read: "READ",
        p_application: "NO_APPLICATION",
        p_page: 2,
        p_page_size: 25,
      },
    },
  ]);
  assert.equal(result.page, 2);
  assert.equal(result.pageCount, 2);
  assert.deepEqual(
    result.groups[0].submissions.map((submission) => submission.submissionId),
    ["submission-2", "submission-1"],
  );
});

test("Application Inbox clears an initial server error after a successful refetch", () => {
  const loadedGroups = projectApplicationInboxGroups([candidateOneLatest]);
  const recovered = reduceApplicationInboxReadState(
    {
      inbox: { groups: [], page: 1, pageCount: 1 },
      errorMessage: "Không thể tải Phiếu Ứng tuyển. Vui lòng thử lại.",
    },
    {
      type: "loaded",
      inbox: { groups: loadedGroups, page: 1, pageCount: 1 },
    },
  );

  assert.equal(recovered.errorMessage, undefined);
  assert.deepEqual(recovered.inbox, {
    groups: loadedGroups,
    page: 1,
    pageCount: 1,
  });
});
test("Application Inbox reducer updates group versions and submission fields on submission_updated", () => {
  const loadedGroups = projectApplicationInboxGroups([candidateOneHistorical]);
  assert.equal(loadedGroups[0].latestSubmissionVersionNo, 1);
  assert.equal(loadedGroups[0].submissions[0].status, "NEW");
  assert.equal(loadedGroups[0].submissions[0].versionNo, 1);

  const updated = reduceApplicationInboxReadState(
    { inbox: { groups: loadedGroups, page: 1, pageCount: 1 } },
    {
      type: "submission_updated",
      submissionId: "submission-1",
      hrNote: "Updated HR Note via drawer",
      versionNo: 2,
      status: "READ",
      hasApplication: false,
    },
  );

  assert.equal(updated.inbox.groups[0].latestSubmissionVersionNo, 2);
  assert.equal(updated.inbox.groups[0].submissions[0].versionNo, 2);
  assert.equal(updated.inbox.groups[0].submissions[0].status, "READ");
  assert.equal(
    updated.inbox.groups[0].submissions[0].hrNote,
    "Updated HR Note via drawer",
  );
});

test("PII filter model supports observable groups and reset restores results", () => {
  const groups = projectApplicationInboxGroups([
    candidateOneLatest,
    candidateTwo,
  ]).map((group) => ({
    ...group,
    email:
      group.candidateId === "candidate-1"
        ? "an@example.com"
        : "binh@example.com",
    isCandidateActive: group.candidateId === "candidate-1",
  }));

  const searched = filterApplicationInboxGroups(groups, {
    ...INITIAL_APPLICATION_INBOX_FILTERS,
    query: "0901 234",
  });
  assert.deepEqual(
    searched.map((group) => group.candidateId),
    ["candidate-1"],
  );

  const filtered = filterApplicationInboxGroups(groups, {
    ...INITIAL_APPLICATION_INBOX_FILTERS,
    candidateActivity: "INACTIVE",
    application: "HAS_APPLICATION",
  });
  assert.deepEqual(
    filtered.map((group) => group.candidateId),
    ["candidate-2"],
  );
  assert.equal(
    filterApplicationInboxGroups(groups, INITIAL_APPLICATION_INBOX_FILTERS)
      .length,
    2,
  );
});

test("Application Inbox keyboard expansion and checkbox hit area use real client state", {
  timeout: 60_000,
}, async () => {
  const browserBundle = await build({
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
    absWorkingDir: process.cwd(),
    bundle: true,
    entryPoints: [
      "src/__tests__/fixtures/application-inbox-expansion-harness.tsx",
    ],
    format: "iife",
    outdir: "application-inbox-browser-fixture",
    platform: "browser",
    conditions: ["browser"],
    write: false,
  });
  const script = browserBundle.outputFiles.find((file) =>
    file.path.endsWith(".js"),
  )?.text;
  const style = browserBundle.outputFiles.find((file) =>
    file.path.endsWith(".css"),
  )?.text;
  if (!script || !style) {
    throw new Error("Application Inbox browser fixture did not bundle");
  }

  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") pageErrors.push(message.text());
    });
    await page.setContent('<div id="root"></div>');
    await page.addStyleTag({ content: style });
    await page.addScriptTag({ content: script });
    await page
      .locator("label.application-inbox__selection-control")
      .first()
      .waitFor({ state: "visible", timeout: 5_000 });
    assert.deepEqual(pageErrors, []);

    const checkbox = page.getByRole("checkbox", {
      name: "Chọn Candidate Nguyễn Thị An",
    });
    const checkboxHitArea = page
      .locator("label.application-inbox__selection-control")
      .first();
    const checkboxBounds = await checkboxHitArea.boundingBox();
    assert.ok(checkboxBounds);
    assert.ok(checkboxBounds.width >= 44);
    assert.ok(checkboxBounds.height >= 44);
    assert.equal(
      await page
        .locator(".application-inbox__table th")
        .first()
        .evaluate((element) =>
          Math.round(element.getBoundingClientRect().width),
        ),
      48,
    );
    await checkboxHitArea.click({
      position: {
        x: checkboxBounds.width - 1,
        y: checkboxBounds.height / 2,
      },
    });
    assert.equal(await checkbox.isChecked(), true);
    await checkbox.focus();
    assert.equal(
      await page.evaluate(
        () => document.activeElement?.getAttribute("type") === "checkbox",
      ),
      true,
    );

    const firstExpandButton = page.locator(
      'button[aria-controls="candidate-group-candidate-1"]',
    );
    await firstExpandButton.focus();
    assert.equal(
      await page.evaluate(
        () =>
          document.activeElement?.getAttribute("aria-controls") ===
          "candidate-group-candidate-1",
      ),
      true,
    );
    await firstExpandButton.press("Enter");
    await page
      .locator("#candidate-group-candidate-1 .application-inbox__child-row")
      .waitFor({ state: "attached", timeout: 5_000 });
    assert.equal(await firstExpandButton.getAttribute("aria-expanded"), "true");

    const secondExpandButton = page.locator(
      'button[aria-controls="candidate-group-candidate-2"]',
    );
    await secondExpandButton.focus();
    await secondExpandButton.press("Space");
    await page
      .locator("#candidate-group-candidate-2 .application-inbox__child-row")
      .waitFor({ state: "attached", timeout: 5_000 });
    assert.equal(
      await firstExpandButton.getAttribute("aria-expanded"),
      "false",
    );
    assert.equal(
      await secondExpandButton.getAttribute("aria-expanded"),
      "true",
    );
    assert.equal(
      await page
        .locator("#candidate-group-candidate-1 .application-inbox__child-row")
        .count(),
      0,
    );
    assert.equal(
      await page
        .locator("#candidate-group-candidate-2 .application-inbox__child-row")
        .count(),
      1,
    );
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});
