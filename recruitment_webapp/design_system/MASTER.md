# MASTER — EIU Recruitment Design System v1.8

## 1. Design direction
**Institutional Enterprise / Clean Productivity UI**.

Priority:
1. readable data;
2. fast operational actions;
3. minimal unnecessary clicks;
4. preserve context;
5. consistent EIU identity;
6. accessibility and resilient bilingual layouts.

Avoid heavy glassmorphism, neon, decorative gradients, excessive card rounding, heavy shadows, or emoji as functional icons.

## 2. Brand foundation
- Primary EIU Blue: `#144069`
- EIU Gold: `#A78656`
- Canvas: `#F8F6F1`
- Surface: `#FFFFFF`
- Body text: `#303033`
- Font: **Be Vietnam Pro**

## 3. Desktop app shell
### Internal app
- Fixed left sidebar: **244px**.
- Dark EIU-blue gradient/sidebar visual direction based on MedLabs.
- Group headings use restrained gold accent.
- Active navigation = light/white pill with EIU-blue text/icon.
- User card at sidebar bottom.
- Sticky page header.
- `VI | EN` in top-right utility region.
- Sticky action toolbar immediately below page header.
- Main content scrolls independently.
- Wide tables scroll horizontally inside their own table container; header/toolbar remain visible and do not move horizontally.
- Detail Drawer opens from right and does not cover desktop sidebar.

### Candidate portal
Same brand/component language, simpler navigation and mobile-priority behavior.

## 4. Language
- Default: Vietnamese.
- Switcher: `VI | EN`.
- All system-generated UI text goes through the i18n layer.
- User-entered content is not automatically translated.
- Date/number formatting uses locale-aware APIs such as `Intl.DateTimeFormat`/`Intl.NumberFormat`; business timezone rules come from Technical Handover.

## 5. Typography — hard rule
- Main content: **>=16px**.
- Table header: **16px / 600**.
- Table body: **16px / 400–500**.
- Status badge: **16px / 600**.
- Inputs/selects/buttons/field values: **16px**.
- Drawer/modal/popup/preview body: **16px**.
- Labels: **16px / 600**.
- Helper/meta may be 14px only when clearly secondary.

Never reduce font size to force a dense table into a laptop viewport.

## 6. Table rules — hard rule
- Use semantic HTML `<table>` where the information is tabular.
- Use `table-layout: fixed` and page-specific `<colgroup>`.
- Define a minimum table width when total column requirements exceed available viewport.
- Wrap the table in an `overflow-x:auto` container.
- Keep sticky Page Header and Action Toolbar outside the horizontal scroller.
- Use sticky `<thead>` for long vertical lists.
- Header and content cells are left-aligned.
- Long content wraps; no default ellipsis for important business data.
- Status badge is centered within Status cell.
- Expanded rows reuse the same column system and must not visually drift from parent columns.
- Server pagination/search is preferred for growing operational datasets; UI must not assume all rows are loaded.

## 7. Expand interaction
Pointer behavior:
- Parent with children: click anywhere on the non-interactive row surface → expand/collapse.
- Chevron is a visual affordance, not the only click target.
- Checkbox, status badge, links, buttons, menus, comboboxes and other controls stop propagation.
- Parent without children: row click opens its Drawer.
- Child row click opens the exact child/entity Drawer.

Keyboard/accessibility behavior:
- Do not rely on a non-semantic `<tr tabindex=0 role=button>` as the only keyboard solution.
- Provide a real expand/collapse button/control in the first/name cell with `aria-expanded` and an accessible name.
- Pointer users can still click the full row.

## 8. Status interaction
Two entry points share one state-changing component/menu:
1. toolbar `Status` dropdown for selected rows;
2. row Status badge for authorized individual-row change.

Rules:
- permission-aware;
- read-only users get non-interactive badges;
- same business validation/warnings regardless of entry point;
- status transitions remain manual/flexible where Business Logic says so;
- badge widths equal within each status group and accommodate approved VI/EN labels.

## 9. Page header/action toolbar
Page Header:
- target height around 72–76px;
- title + optional short description;
- top-right utilities: language/user/help as appropriate.

Action Toolbar:
- sticky below Page Header;
- primary/bulk actions left;
- search/filter tools right where space allows;
- `Đã chọn N / N selected` when applicable;
- one Status dropdown, not a row of status buttons.

## 10. Drawer / Modal / Preview
Drawer:
- detail-heavy content;
- desktop Drawer width follows the single Drawer token/formula in `TOKENS.md`; do not restate independent min/max rules;
- `Label | Value` structure;
- sticky header/footer/action region where helpful;
- long text wraps.

Modal:
- focused actions such as status confirmation, scheduling form, email preview, delete confirmation.

Preview:
- on-screen body typography follows the same >=16px product rule;
- print/PDF typography may be driven by the official EIU print template rather than the application UI scale.

## 11. Report UI — hard rule
No score/rating/stars/points/percentage scale.

The report form contains only the frozen qualitative and final-decision text fields.
The UI does not require every Interviewer to fill the Final Decision block. Normally one representative fills it after panel agreement; if another Interviewer later changes a final field, Business Logic treats that as a later agreed revision.

## 12. Prototype-only persona switcher
A Demo Persona Switcher may exist only in prototype/development/demo builds for testing:
- Root Admin
- HR Full
- HR Limited
- Interviewer
- Candidate

It must alter visible menus/actions/permissions realistically and must be excluded from production builds.

## 13. Accessibility baseline
- semantic HTML before ARIA simulation;
- visible `focus-visible`;
- keyboard access;
- labeled controls/icon buttons;
- asynchronous feedback via accessible status/error patterns (`aria-live` where appropriate);
- no color-only status;
- reduced motion;
- unsaved-change protection for long forms;
- bilingual/responsive text resilience.

## 14. UI state and navigation
- Important filter/sort/page/tab state should be reflected in URL query params where useful so refresh/back/forward/deep-link behavior remains predictable.
- Switching VI/EN must preserve current route, filters, selection where safe, and unsaved form values.
- Avoid module-level mutable request/user state in SSR implementation.

## 15. Responsive roadmap
1. update Desktop Clickable Prototype to v1.8;
2. desktop UX-UAT;
3. iPad landscape/portrait;
4. mobile layouts;
5. Candidate mobile UAT as go-live gate;
6. responsive/UI Freeze.


## Current hardening decisions — v1.8
- semantic status text targets WCAG 2.2 AA;
- page-owned deterministic desktop `colgroup` widths are specified in TABLE_LAYOUT;
- generic wrap-anywhere is prohibited;
- future business modules stay hidden until promoted into scope;
- Desktop prototype must be resynced to these tokens/specs before UI freeze.


## Current operational clarifications — v1.8
- Candidate Inbox parent row summarizes latest Submission; history remains expandable.
- Wide operational tables keep Select + primary identity as sticky context columns where horizontal scrolling is required.
- Phase-1 system email preview contains no attachments.
- Candidate Form ends with required Privacy Notice acknowledgement.
- User/Permissions UI distinguishes Auth Bound/Unbound and separates Root-only identity actions.
- Catalog UI must make referenced structural fields non-editable and explain create-new + inactivate-old lifecycle.
- PII search text is not reflected into shareable URLs.


## v1.8 release evidence
- 200% text zoom: no loss of functionality.
- 400% reflow where WCAG SC 1.4.10 applies; wide semantic tables may retain intentional two-dimensional scrolling.
- Sticky-column focus remains visible. Missing visual baseline = `INCONCLUSIVE`.

## Owner-authorized UniCouncil adaptation trial — 2026-11-05

Change reference: `CR-UNICOUNCIL-UI-ADAPTATION-20261105`. The Owner requested applying the supplied UniCouncil reference to the existing Site. This controlled presentation trial supersedes conflicting 16px-only operational typography and repeated demo-control placement in earlier clauses, including the prior workflow trials. Final Owner visual UAT is pending. Business, authorization, privacy, IDs, version tokens and browser-local demo semantics are unchanged.

- Use the unmodified EIU logo at its original aspect ratio, a consistent outline SVG navigation family, a compact workspace header and one clear content page title. The demo-only role/reset/guide control belongs in a single workspace dialog reached by a visible “Vai thử nghiệm / Trial role” header entry on desktop and phone. An optional shell slot is presentation only and never grants production role authority.
- Scoped list/navigation/filter/pagination/button/badge UI may use **14px / 21px**; list identity names remain 16px semibold. This is a deliberate information hierarchy, not an emergency response to overflow. Generic body, form fields, drawer/dialog content, report narratives and Candidate form remain **16px**. Mobile inputs/selects/textareas remain at least16px. No functional UI falls below14px. The Be Vietnam Pro font assets remain loaded. Touch targets remain44px; status contrast/focus/text labels and native percentage colgroups remain intact.
- Page titles, primary filters, data and pager share the existing symmetric workspace gutter. Secondary page explanations are optional context disclosures; the explanation remains reachable. Unselected bulk commands need no separate empty toolbar; row selection exposes them, selection changes remain announced and command completion returns focus to the list.
- Inbox cards prioritize identity, contact, state and actions. Birth date/gender may be omitted from the narrow summary only because the existing explicit detail drawer exposes both completely. HR-note excerpts remain two lines on cards and three on desktop lists. No Application summary or owner is inferred from Candidate identity.
- Collapsed filters at390×844 target at least300px of usable Inbox list viewport. Lists retain viewport scrolling at normal heights and document flow for expanded filters/short viewports; all full details, commands, translations and roles remain reachable.
