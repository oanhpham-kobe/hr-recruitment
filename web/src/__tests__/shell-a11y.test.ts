import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

function readSource(relativePath: string): string {
  return fs.readFileSync(path.resolve(relativePath), "utf8");
}

test("AppShell composes the required semantic landmark-bearing shell", () => {
  const source = readSource("src/components/shell/AppShell.tsx");

  // AppShell is a stateful client component because it owns responsive
  // navigation. Runtime landmark behavior is covered by the production shell
  // browser test; this static contract keeps composition explicit without
  // invoking client Hooks under the react-server test condition.
  assert.match(source, /<SkipLink\s*\/>/);
  assert.match(
    source,
    /<Sidebar\s+currentPath=\{currentPath\}\s+navItems=\{navItems\}[\s\S]*?accountLabel=\{accountLabel\}\s*\/>/,
  );
  assert.match(source, /<MobileNavigation[\s\S]*?navItems=\{navItems\}/);
  assert.match(source, /<Header[\s\S]*?mobileNavOpen=\{mobileNavOpen\}/);
  assert.match(
    source,
    /<main\s+id="main-content"\s+tabIndex=\{-1\}\s+className="content">/,
  );
});

test("SkipLink source keeps an accessible skip link targeting #main-content", () => {
  const source = readSource("src/components/shell/SkipLink.tsx");

  assert.match(source, /<a href="#main-content" className="skip-link">/);
  assert.match(source, /Chuyển đến nội dung chính \/ Skip to main content/);
});

test("Sidebar source keeps semantic navigation, active state, and user identity contracts", () => {
  const source = readSource("src/components/shell/Sidebar.tsx");

  assert.match(source, /const \{ locale \} = useAppLocale\(\)/);
  assert.match(source, /<aside[\s\S]*?className="sidebar"/);
  assert.match(source, /"Thanh điều hướng chính" : "Main sidebar"/);
  assert.match(source, /<Brand\s*\/>/);
  assert.match(
    readSource("src/components/shell/Brand.tsx"),
    /className="brand-logo"/,
  );
  assert.match(source, /<nav[\s\S]*?className="sidebar-nav"/);
  assert.match(source, /"Menu chức năng" : "Navigation menu"/);
  assert.match(source, /aria-current=\{isCurrent \? "page" : undefined\}/);
  assert.match(source, /className="user-avatar"/);
  assert.match(source, /role="img"/);
  assert.match(source, /"Ảnh đại diện người dùng" : "User avatar"/);
});

test("Header source keeps title and semantic locale controls", () => {
  const source = readSource("src/components/shell/Header.tsx");

  assert.match(source, /const \{ locale, setLocale \} = useAppLocale\(\)/);
  assert.match(source, /<header className="topbar">/);
  assert.match(source, /<h1>\{title\}<\/h1>/);
  assert.match(source, /<fieldset className="language-switcher">/);
  assert.match(source, /<legend className="sr-only">/);
  assert.match(source, /"Chọn ngôn ngữ" : "Choose language"/);
  assert.match(source, /aria-pressed=\{locale === "vi"\}/);
  assert.match(source, /aria-pressed=\{locale === "en"\}/);
  assert.match(source, /onClick=\{\(\) => setLocale\("vi"\)\}/);
  assert.match(source, /onClick=\{\(\) => setLocale\("en"\)\}/);
  assert.match(source, />\s*VI\s*<\/button>/);
  assert.match(source, />\s*EN\s*<\/button>/);
});

test("loading boundary source conforms to accessible status semantics", () => {
  const source = readSource("src/app/loading.tsx");

  assert.match(
    source,
    /<div role="status" aria-live="polite" className="loading-indicator">/,
  );
  assert.match(source, /Đang tải\.\.\. \/ Loading\.\.\./);
});

test("globals.css defines focus visibility, reduced motion, and skip link styles", () => {
  const globalsCss = readSource("src/app/globals.css");

  assert.match(
    globalsCss,
    /:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--eiu-blue\)/,
  );
  assert.match(globalsCss, /outline-offset:\s*2px/);

  assert.match(globalsCss, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
  assert.match(globalsCss, /animation-duration:\s*0\.01ms/);
  assert.match(globalsCss, /transition-duration:\s*0\.01ms/);

  assert.match(globalsCss, /\.skip-link\s*\{[^}]*position:\s*absolute/);
  assert.match(globalsCss, /\.skip-link\s*\{[^}]*top:\s*-999px/);
  assert.match(globalsCss, /\.skip-link:focus\s*\{[^}]*top:\s*16px/);
});
