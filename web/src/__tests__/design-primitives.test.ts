import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

test("bounded production primitives expose current design contracts", () => {
  assert.match(read("../components/ui/Button.tsx"), /pending/);
  assert.match(
    read("../components/ui/StatusBadge.tsx"),
    /operationalInterview/,
  );
  const menu = read("../components/ui/StatusMenu.tsx");
  assert.match(menu, /aria-haspopup="menu"/);
  assert.match(menu, /Escape/);
  assert.match(menu, /ArrowDown/);
  assert.match(menu, /ArrowUp/);
  assert.match(menu, /Home/);
  assert.match(menu, /End/);
  assert.match(menu, /rootRef/);
  const overlay = read("../components/ui/overlay.tsx");
  assert.match(overlay, /setAttribute\("inert"/);
  assert.match(overlay, /overlayStack/);
  assert.match(overlay, /activeOverlayLocks/);
  assert.match(overlay, /previous\?\.focus/);
  const css = read("../styles/ui.css");
  assert.match(css, /--badge-width-interview-operational/);
  assert.match(css, /width: min\(820px/);
});
