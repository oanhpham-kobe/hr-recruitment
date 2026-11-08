import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

test("candidate and internal operational pages converge on responsive design contracts", () => {
  const candidateCss = read("../styles/candidate-portal.css");
  const submissions = read("../components/candidate/SubmissionsList.tsx");
  const inboxRows = read("../components/inbox/ApplicationInboxTableRows.tsx");
  const globals = read("../app/globals.css");

  assert.doesNotMatch(candidateCss, /font-size:\s*(14|15)px/);
  assert.match(
    candidateCss,
    /\.btn-sm[\s\S]*min-height:\s*44px[\s\S]*font-size:\s*16px/,
  );
  assert.match(
    candidateCss,
    /@media \(max-width: 640px\)[\s\S]*\.submissions-table td::before/,
  );
  assert.match(submissions, /data-label="Trạng thái \/ Status"/);
  assert.doesNotMatch(submissions, /minHeight: "36px"|fontSize: "14px"/);

  assert.match(globals, /\.submission-drawer[\s\S]*max-width:\s*820px/);
  assert.match(
    globals,
    /\.submission-drawer__close-btn[\s\S]*width:\s*44px[\s\S]*height:\s*44px/,
  );
  assert.match(
    globals,
    /@container workflow-workspace \(max-width: 1100px\)[\s\S]*\.application-inbox__table tbody[\s\S]*display:\s*grid/,
  );
  assert.match(
    globals,
    /\.submission-drawer[\s\S]*width:\s*100vw[\s\S]*height:\s*100dvh/,
  );
  assert.match(inboxRows, /data-label="Candidate"/);
  assert.match(inboxRows, /data-label="HR Note"/);
});
