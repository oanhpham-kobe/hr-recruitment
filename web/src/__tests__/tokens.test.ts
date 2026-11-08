import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

function loadStyles(): { tokensCss: string; globalsCss: string } {
  const tokensPath = path.resolve("src/styles/tokens.css");
  const globalsPath = path.resolve("src/app/globals.css");

  const tokensCss = fs.readFileSync(tokensPath, "utf8");
  const globalsCss = fs.readFileSync(globalsPath, "utf8");

  return { tokensCss, globalsCss };
}

test("design system v1.8 tokens define all canonical brand colors", () => {
  const { tokensCss } = loadStyles();

  assert.match(tokensCss, /--eiu-blue:\s*#144069/i);
  assert.match(tokensCss, /--eiu-gold:\s*#a78656/i);
  assert.match(tokensCss, /--eiu-cream:\s*#f6f1e8/i);
  assert.match(tokensCss, /--canvas:\s*#f8f6f1/i);
  assert.match(tokensCss, /--surface:\s*#ffffff/i);
  assert.match(tokensCss, /--ink-950:\s*#303033/i);
  assert.match(tokensCss, /--ink-600:\s*#68686b/i);
  assert.match(tokensCss, /--line:\s*#e2d9cc/i);
});

test("design system v1.8 tokens define all canonical sidebar tokens", () => {
  const { tokensCss } = loadStyles();

  assert.match(tokensCss, /--sidebar-width:\s*244px/);
  assert.match(tokensCss, /--sidebar-bg-top:\s*#0e416f/i);
  assert.match(tokensCss, /--sidebar-bg-bottom:\s*#082f52/i);
  assert.match(tokensCss, /--sidebar-text:\s*#f7fafc/i);
  assert.match(tokensCss, /--sidebar-muted:\s*#d9e4ee/i);
  assert.match(tokensCss, /--sidebar-heading:\s*#e6c88f/i);
  assert.match(tokensCss, /--sidebar-active-bg:\s*#ffffff/i);
  assert.match(tokensCss, /--sidebar-active-text:\s*#144069/i);
  assert.match(
    tokensCss,
    /--sidebar-border:\s*rgba\(255,\s*255,\s*255,\s*0\.14\)/,
  );
});

test("design system v1.8 tokens define WCAG 2.2 AA compliant semantic status colors", () => {
  const { tokensCss } = loadStyles();

  // Success (text #3B6A2A, bg #EAF3E6)
  assert.match(tokensCss, /--status-success-text:\s*#3b6a2a/i);
  assert.match(tokensCss, /--status-success-bg:\s*#eaf3e6/i);

  // Warning (text #8A4F00, bg #FFF0DE)
  assert.match(tokensCss, /--status-warning-text:\s*#8a4f00/i);
  assert.match(tokensCss, /--status-warning-bg:\s*#fff0de/i);

  // Danger (text #B44425, bg #F8E5E0)
  assert.match(tokensCss, /--status-danger-text:\s*#b44425/i);
  assert.match(tokensCss, /--status-danger-bg:\s*#f8e5e0/i);

  // Info (text #144069, bg #E5EDF5)
  assert.match(tokensCss, /--status-info-text:\s*#144069/i);
  assert.match(tokensCss, /--status-info-bg:\s*#e5edf5/i);

  // Neutral (text #68686B, bg #EEF0F1)
  assert.match(tokensCss, /--status-neutral-text:\s*#68686b/i);
  assert.match(tokensCss, /--status-neutral-bg:\s*#eef0f1/i);

  // Follow-up (text #4B479D, bg #ECEBFA)
  assert.match(tokensCss, /--status-followup-text:\s*#4b479d/i);
  assert.match(tokensCss, /--status-followup-bg:\s*#ecebfa/i);
});

test("base typography retains16px with an explicit approved compact workflow scope", () => {
  const { tokensCss, globalsCss } = loadStyles();

  // Font family includes Be Vietnam Pro
  assert.match(tokensCss, /"Be Vietnam Pro"/);

  // Base token definitions remain16px; the documented scoped trial uses14px.
  assert.match(tokensCss, /--font-size-base:\s*16px/);
  assert.match(tokensCss, /--font-size-body:\s*16px/);
  assert.match(tokensCss, /--font-size-table-header:\s*16px/);
  assert.match(tokensCss, /--font-size-table-cell:\s*16px/);
  assert.match(tokensCss, /--font-size-label:\s*16px/);
  assert.match(tokensCss, /--font-size-button:\s*16px/);
  assert.match(tokensCss, /--font-size-badge:\s*16px/);
  assert.match(tokensCss, /--font-size-meta:\s*14px/);

  const compactCss = fs.readFileSync(
    path.resolve("src/styles/workflow.css"),
    "utf8",
  );
  assert.match(compactCss, /CR-UNICOUNCIL-UI-ADAPTATION-20261105/);
  assert.match(
    compactCss,
    /\.workflow-list-page table[\s\S]*?font-size:\s*14px/,
  );
  assert.match(
    compactCss,
    /@media \(min-width: 768px\)[\s\S]*?font-size:\s*14px/,
  );
  assert.match(compactCss, /\[role="dialog"\][\s\S]*?font-size:\s*16px/);

  // globals.css supplies the16px base for body, table, forms and controls.
  assert.match(globalsCss, /font-size:\s*16px/);
  assert.match(globalsCss, /body,\s*\n?table/);
});

test("spacing scale and badge sizing tokens meet v1.8 specification", () => {
  const { tokensCss } = loadStyles();

  // Spacing scale: 4, 8, 12, 16, 20, 24, 32, 40, 48, 64
  assert.match(tokensCss, /--space-1:\s*4px/);
  assert.match(tokensCss, /--space-2:\s*8px/);
  assert.match(tokensCss, /--space-3:\s*12px/);
  assert.match(tokensCss, /--space-4:\s*16px/);
  assert.match(tokensCss, /--space-5:\s*20px/);
  assert.match(tokensCss, /--space-6:\s*24px/);
  assert.match(tokensCss, /--space-8:\s*32px/);
  assert.match(tokensCss, /--space-10:\s*40px/);
  assert.match(tokensCss, /--space-12:\s*48px/);
  assert.match(tokensCss, /--space-16:\s*64px/);

  // Badge widths
  assert.match(tokensCss, /--badge-width-submission:\s*112px/);
  assert.match(tokensCss, /--badge-width-interview:\s*112px/);
  assert.match(tokensCss, /--badge-width-interview-operational:\s*144px/);
  assert.match(tokensCss, /--badge-width-candidate:\s*128px/);
  assert.match(tokensCss, /--badge-width-report:\s*168px/);
});
