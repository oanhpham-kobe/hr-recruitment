import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");
const layout = read("../app/layout.tsx");
const shell = read("../components/shell/AppShell.tsx");
const candidateShell = read("../components/shell/CandidateShell.tsx");
const mobile = read("../components/shell/MobileNavigation.tsx");
const css = read("../app/globals.css");

test("candidate and internal shell responsibilities are explicit", () => {
  assert.match(layout, /resolveShellKind/);
  assert.match(layout, /CandidateShell/);
  assert.ok(layout.includes('pathname === "/candidate"'));
  assert.match(layout, /AppShell currentPath=\{pathname\}/);
  assert.match(candidateShell, /<SkipLink\s*\/>/);
  assert.doesNotMatch(candidateShell, /<main\b/);
  assert.doesNotMatch(candidateShell, /id="main-content"/);
});

test("internal mobile navigation is modal, inert and focus restoring", () => {
  assert.match(shell, /MobileNavigation/);
  assert.match(mobile, /createPortal/);
  assert.match(mobile, /aria-modal="true"/);
  assert.match(mobile, /setAttribute\("inert"/);
  assert.match(mobile, /event\.key === "Escape"/);
  assert.match(mobile, /internal-nav-trigger/);
  assert.match(css, /@media \(max-width: 1024px\)/);
  assert.match(css, /\.shell-main\s*\{[\s\S]*?margin-left:\s*0;[\s\S]*?\}/);
});
