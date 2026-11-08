import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const src = path.join(root, "src");
const tokenFile = path.join(src, "styles", "tokens.css");
const tokenText = fs.readFileSync(tokenFile, "utf8");
const declaredTokens = new Set(
  [...tokenText.matchAll(/(--[A-Za-z0-9_-]+)\s*:/g)].map((m) => m[1]),
);
const failures = [];

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

const files = walk(src).filter((f) => /\.(css|tsx|ts)$/.test(f));
const forbiddenAliases = [
  "--font-stack",
  "--surface-muted",
  "--surface-hover",
  "--ink-900",
  "--ink-800",
  "--ink-700",
  "--ink-500",
  "--accent",
  "--radius-pill",
  "--status-danger-border",
  "--status-warning-border",
  "--font-size-title-page",
];

for (const file of files) {
  const rel = path.relative(root, file).replaceAll(path.sep, "/");
  const text = fs.readFileSync(file, "utf8");

  for (const match of text.matchAll(/var\((--[A-Za-z0-9_-]+)/g)) {
    if (!declaredTokens.has(match[1]))
      failures.push(`${rel}: undefined design token ${match[1]}`);
  }
  for (const alias of forbiddenAliases) {
    if (text.includes(alias))
      failures.push(`${rel}: forbidden legacy design token ${alias}`);
  }
  if (/\.tsx?$/.test(file) && /var\(--[A-Za-z0-9_-]+\s*,/.test(text)) {
    failures.push(
      `${rel}: TS/TSX token fallback is forbidden; use declared runtime tokens`,
    );
  }

  if (file.endsWith(".css")) {
    const allowedPrimitiveFile =
      rel === "src/app/globals.css" ||
      rel === "src/styles/ui.css" ||
      rel === "src/styles/workflow.css";
    if (!allowedPrimitiveFile) {
      for (const selector of ["btn-primary", "btn-secondary", "status-badge"]) {
        const rx = new RegExp(`(^|[}\\n])\\s*\\.${selector}(?=\\s*[:,{])`, "m");
        if (rx.test(text))
          failures.push(
            `${rel}: feature-local generic primitive .${selector} is forbidden`,
          );
      }
    }

    // Enforce literal sizes only on selectors that clearly represent controls/primary feedback.
    for (const block of text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selector = block[1].trim();
      const body = block[2];
      const primarySelector =
        /(^|[\s>+~,.:#])(button|input|select|textarea)([\s>+~,.:#[]|$)|\.btn(?:[-_\s.:#[]|$)|close-btn|dismiss-btn|status-menu__trigger|form-server-error|portal-alert/.test(
          selector,
        );
      if (!primarySelector) continue;
      for (const size of body.matchAll(
        /font-size:\s*([0-9]+(?:\.[0-9]+)?)px/g,
      )) {
        // CR-UNICOUNCIL-UI-ADAPTATION-20261105: explicit scoped UI floor.
        // Generic forms, messages and portalled detail bodies keep16px.
        const compactScope =
          (rel === "src/styles/workflow.css" &&
            selector.includes(".workflow-list-page")) ||
          (rel === "src/app/globals.css" && selector === ".lang-btn") ||
          (rel.endsWith("project-preview/preview.css") &&
            selector === ".preview-workspace-trigger");
        const minimum = compactScope ? 14 : 16;
        if (Number(size[1]) < minimum)
          failures.push(
            `${rel}: ${selector} uses ${size[1]}px primary/control text (minimum ${minimum}px)`,
          );
      }
      for (const height of body.matchAll(
        /min-height:\s*([0-9]+(?:\.[0-9]+)?)px/g,
      )) {
        if (Number(height[1]) < 44)
          failures.push(
            `${rel}: ${selector} uses ${height[1]}px minimum control height`,
          );
      }
    }
  }
}

const compactCss = fs.readFileSync(
  path.join(src, "styles/workflow.css"),
  "utf8",
);
if (
  !/\.workflow-list-page input[\s\S]*?font-size:\s*16px/.test(compactCss) ||
  !/@media \(min-width: 768px\) [\s\S]*?font-size:\s*14px/.test(compactCss)
) {
  failures.push(
    "src/styles/workflow.css: mobile input16px / desktop compact14px scope missing",
  );
}
if (!tokenText.includes("--badge-width-interview-operational: 144px")) {
  failures.push(
    "src/styles/tokens.css: missing 144px operational Interview badge token",
  );
}
for (const required of [
  "components/ui/Button.tsx",
  "components/ui/StatusBadge.tsx",
  "components/ui/StatusMenu.tsx",
  "components/ui/Dialog.tsx",
  "components/ui/Drawer.tsx",
  "components/ui/TableScrollContainer.tsx",
]) {
  if (!fs.existsSync(path.join(src, required)))
    failures.push(`src/${required}: required production primitive missing`);
}

if (failures.length) {
  console.error("DESIGN CONTRACT VALIDATION: FAIL");
  for (const failure of [...new Set(failures)].sort())
    console.error(` - ${failure}`);
  process.exit(1);
}
console.log("DESIGN CONTRACT VALIDATION: PASS");
console.log(` - scanned ${files.length} production CSS/TS/TSX files`);
console.log(` - declared runtime tokens: ${declaredTokens.size}`);
