# ACCESSIBILITY — v1.8

## 1. Typography
- Product main content >=16px.
- Table header/badge 16px semibold.
- Helper/meta 14px only when secondary.
- Never reduce text because a table is wide.

## 2. Semantic controls
Prefer native semantics:
- `<button>` for actions;
- `<a>`/Next Link for navigation;
- `<label>` associated with form controls;
- semantic table elements for tabular data.

ARIA supplements semantics; it does not replace them unnecessarily.

## 3. Expandable rows
Pointer users may click the whole parent row.

Keyboard/screen-reader users receive a real expand/collapse control in the first/name cell:
- accessible name;
- `aria-expanded`;
- visible focus;
- keyboard activation.

Nested checkbox/status/action controls must not cause the parent row action.

## 4. Focus & keyboard
- all interactive controls have visible `:focus-visible`;
- no keyboard traps except correctly managed modal/dialog focus traps;
- Drawer/Modal returns focus to trigger when closed;
- Status menu/combobox/navigation work with keyboard.

## 5. Status and color
- every state has a text label;
- color is supplementary;
- clickable badge has an action label such as `Thay đổi trạng thái: Đã đọc`;
- read-only badge is not exposed as an interactive control.

## 6. Forms and errors
- persistent labels; placeholders do not replace labels;
- field errors connect through `aria-describedby` where appropriate;
- long forms provide a clear error summary/focus strategy;
- async success/error status uses accessible notification patterns (`aria-live` where appropriate);
- warn before navigation/close when unsaved edits exist.

## 7. Responsive text/content
- long Vietnamese/English strings wrap without clipping;
- badge labels never truncate;
- zoom remains usable;
- touch targets target >=44x44px in touch layouts; desktop icon controls should remain comfortably clickable.

## 8. Language
- `VI | EN`, no flags;
- current selection is programmatically/visually clear;
- document `lang` updates with UI language;
- dates/numbers use locale-aware formatting.

## 9. Motion
- respect `prefers-reduced-motion`;
- motion is subtle and functional;
- no essential information depends on animation.

## 10. Login/auth feedback
- auth errors are text, not toast-only;
- loading/redirect state is announced;
- Candidate inactive/Internal unauthorized state has a clear recovery/support path without leaking sensitive account information.


## Current semantic color gate — v1.8
All 14–16px normal text, including status badges, must reach 4.5:1 contrast against the final rendered background. Current success/warning foregrounds were darkened in TOKENS v1.8. Contrast regression is part of Design Review Checklist.


## Current additional checks — v1.8
- Brand gold on light backgrounds is not used for normal body text unless measured contrast passes the target.
- Sticky context columns preserve visible focus rings and do not obscure horizontally scrolled content.
- Horizontal overflow has a non-essential edge indicator/shadow; keyboard users can still reach all table controls.

## Measurable reflow/zoom gate
- 200% text zoom → no loss of content/functionality.
- 400% reflow where WCAG SC 1.4.10 applies; wide data tables are intentional two-dimensional-scroll exception.
- Keyboard focus remains visible with sticky columns/horizontal scroll.
- axe is required but not full WCAG proof; manual keyboard/screen-reader sanity evidence is also required.


## Responsive overlay/status-menu keyboard behavior — v1.8

- Status menu triggers expose an accessible name/state and remain keyboard operable.
- Escape closes the open status menu and restores focus to its trigger.
- Mobile navigation and full-screen drawers must not leave inactive background controls focusable; use inertness/semantic hiding plus focus restoration.
- Long localized status labels may wrap within the approved badge width; meaning must never rely on color alone.

## UniCouncil visual trial — 2026-11-05

`CR-UNICOUNCIL-UI-ADAPTATION-20261105` in MASTER.md permits scoped operational list/navigation/filter/pager/badge UI at14px/21px. No functional UI may be smaller than14px. Identity names and all generic body, Candidate forms, drawer/dialog content and report narrative remain16px; mobile inputs/selects remain16px. Inline dialogs must explicitly restore16px so ancestor list styles cannot reduce their field labels, values, actions or full-detail metadata. Controls retain44px touch targets,4.5:1 text contrast, visible focus and zoom/reflow access. The single workspace dialog and mobile navigation dismiss on Escape, contain focus and restore the trigger.
