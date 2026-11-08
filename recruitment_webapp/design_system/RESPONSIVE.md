# RESPONSIVE FOUNDATION — v1.8

## Status
Detailed iPad/mobile page layouts are **NOT FROZEN**. They follow Desktop v1.8 UX-UAT.

## Production scope principle
- Internal HR/Admin/Interviewer app: desktop-first.
- Candidate Login + Candidate Form + Phiếu của tôi: **mobile-ready is a go-live requirement** because external candidates are expected to use phones.

## Review viewport references
- mobile: 375–390px
- tablet portrait: 768px
- tablet landscape/small desktop: 1024px
- desktop/laptop: 1280–1440px+

These are review references, not brittle CSS device detections.

## Rules that never change
- main typography >=16px;
- no clipped VI/EN strings;
- status state remains legible/textual;
- touch controls large enough;
- Drawer/Modal content >=16px;
- long operational tables may scroll rather than shrink text.

## Desktop >=1280px
- sidebar 244px;
- sticky header + full toolbar;
- fixed colgroup table + horizontal overflow when required;
- desktop Drawer prefers 820px but is capped by available content width with safe gutters; no impossible fixed minimum vs vw cap.

## Tablet direction to prototype
- sidebar collapsed/off-canvas depending orientation;
- prioritize key table columns without changing data semantics;
- horizontal scroll remains acceptable for dense HR tables;
- toolbar may wrap or move secondary actions into More/overflow;
- Drawer may become 70–85vw or full-screen sheet in portrait;
- touch status badge/dropdown behavior tested explicitly.

## Mobile direction to prototype
### Candidate Portal
- mobile-first form flow while preserving single-page business structure;
- one-column fields;
- repeatable Education sections easy to add/remove;
- document upload optimized for phone file/photo workflows within security rules;
- full-width action area where useful;
- Phiếu của tôi uses a compact structured list/table appropriate to narrow width.

### Internal HR
- off-canvas navigation;
- filters in sheet/dialog;
- detail Drawer becomes full-screen sheet/page;
- per-page decision whether to retain horizontal table or use structured rows;
- never mechanically convert every HR table into cards if comparison is lost.

## UX-UAT order
1. Login
2. Candidate Form
3. Phiếu của tôi
4. Quản lý phiếu ứng tuyển
5. Interview
6. Báo cáo HR
7. Báo cáo Interviewer
8. Danh mục / Users & Permissions

- Candidate Form mobile includes Privacy Notice/acknowledgement before Submit.
- Candidate Inbox grouping on tablet/mobile still uses latest Submission as parent summary; historical submissions open in detail/history.


## Current owner-approved responsive UAT rules — v1.8

The executable reference is Responsive Prototype **v1.10** bundled with Full Handover v1.18. These rules are normative for the next production implementation/UAT:

- Representative QA widths: 360, 390, 430, 768, 1024 and desktop reference; constrained-height overlay checks are also required.
- Mobile Candidate forms use a one-column layout; tablet/desktop may use the approved multi-column layout. Do not reduce operational text below the Design System minimum merely to fit a desktop composition.
- Tablet data-heavy pages retain semantic tables with contained horizontal scrolling. Mobile may use structured summary rows/cards only where the page-specific contract allows it; business-critical data/actions remain reachable.
- Interview and HR Report row status badges use a **144px benchmark width**. Long English labels wrap within this width instead of stretching the cell.
- Row StatusDropdown is anchored to the status badge/button bounds, not pointer coordinates. It dismisses on selection, outside click/tap, Escape, or same-trigger toggle; Escape restores focus to the trigger.
- Interview time presentation is **time first, date after** and remains on one line whenever the available width is sufficient; wrapping occurs only when genuinely constrained.
- Mobile label `Thời gian phỏng vấn` must have enough label-column width to avoid unnecessary wrapping.
- Mobile navigation/drawers must use accessible focus management, Escape dismissal, focus restoration, background inertness/scroll lock, and must not leave visually hidden duplicate navigation available to assistive technology.
- Responsive presentation must not create a separate business workflow or duplicate server mutation semantics for mobile.


## Owner-authorized visual trial — 2026-11-05

Change reference: `CR-WORKFLOW-UI-UAT-20261105`, implementing the Owner's request to apply the supplied workflow UI skill more closely after rejecting the earlier visual result. Local trial only; final Owner visual UAT remains pending.

This presentation trial responds to the Owner's request for clearer workflow proportions. It is not final visual acceptance. Business rules, authorization, pagination and minimum 16px functional type remain unchanged.

Users and catalogs retain semantic comparison tables above 640px; below that width the same cells become labelled summary cards with all identity, role, status, property and action information reachable. Technical optimistic-version counters remain internal command tokens and are omitted from the primary list rather than consuming a desktop column. No timestamp is invented. Users trial widths are 210/240/200/130/140/200px (name, identity, job/unit, role, status, actions); catalogs use 160/260/260/160/220px. Existing exact Interview and HR report column contracts are unchanged.

Secondary Inbox and Interview filters may be disclosed to prioritize populated lists in the first viewport. Applied filters remain indicated and resettable. The questionnaire assignment form uses two columns on desktop and one on mobile. All controls retain keyboard access and 16px text.

Phone workflow summaries in this trial use full-width identity and position/contact content, compact selection/status and a short note excerpt (two visual lines). The existing explicit detail action opens the complete note and record; no source content is discarded. Interview/Inbox/HR-report desktop tables keep their frozen columns and full content. At phone widths these lists use document scrolling with pagination after the complete card list; table max-height must not constrain an overflow-visible list. HR report filters may use the same disclosed secondary-filter pattern.

Secondary row commands may be grouped under an accessible More control, with the same authorization and confirmations. The menu stays within the viewport and dismisses on Escape, outside interaction or anchor movement; opening it does not toggle the underlying row. Expanded desktop round headers remain actual table cells, with only their inner text stacked.


## Owner-authorized workflow skill update trial — 2026-11-05 v2

Change reference: `CR-WORKFLOW-UI-SKILL-V2-20261105`. The Owner supplied `workflow-app-ui-2026-11-05.zip` and requested synchronizing the existing application's interface. This scoped presentation trial supersedes conflicting placement, fixed-width and phone-scroll statements in the prior visual trial and TABLE_LAYOUT §4 for the affected rendered pages. It is pending Owner visual UAT; it does not amend business, authorization, data or acceptance gates.

- One workspace gutter after the sidebar:24px on PC (>=1024),20px tablet (768–1023),16px phone (361–767),12px small phone (<=360). Headers, filters, lists and footers share this axis. Forms may retain their readable max-width; operational workspaces fill the available width.
- Actual Inbox, Interview, HR-report, interviewer-report, Users and catalog tables size to100% of their workspace with a shared colgroup for header/body. Selection, status and action columns reserve usable widths; content columns are fluid. At content widths<=1100px dense workflow tables use structured cards; Users/catalog use cards<=900px. These are content-container thresholds, so a narrow PC window receives the same usable composition as a tablet. This trial replaces their former artboard-width horizontal-scroll presentation. Generic comparison-matrix components keep their explicitly authorized contained scrolling. Notes use a consistent three-line excerpt on wide lists and two-line excerpt on structured cards; the existing explicit detail action exposes the complete note.
- Table header and data start at the same left padding. Badges start at that column edge; only their internal icon/text group is centered. The dedicated checkbox column is a documented centered exception. Edit commands use the existing warning foreground/background semantic pair; ordinary Close/Cancel edit controls remain secondary and destructive commands retain danger semantics. Operational text stays>=16px; the144px Interview/HR-report badge benchmark remains.
- At normal laptop/tablet heights (>=700px with width>=768px) and tall phone heights (>=800px), list pages use the remaining dynamic viewport for their row/card scroller; heading/filter and pager remain outside it, with safe-area padding. Expanded filters/trial controls and shorter/zoomed viewports return to document scrolling so fields/focus are reachable. Forms, feedback composition and print reports remain document flows.
- Breakpoints and cards retain all existing detail actions and command permissions. No role is granted an action through shared presentation. The browser-local demo uses these actual application components.

## UniCouncil visual trial — 2026-11-05

`CR-UNICOUNCIL-UI-ADAPTATION-20261105` in MASTER.md supersedes prior16px-only compact UI clauses. List/navigation/filter/pager/badge UI may use14px/21px; identity names, forms, detail bodies, narratives and mobile inputs/selects remain16px. Existing workspace gutters, native percentage colgroups, card thresholds and normal-height viewport scrolling remain. Collapsed390×844 Inbox controls target at least300px of list viewport. Demo controls live in one header workspace dialog rather than above content; unselected bulk commands consume no row. Narrow Inbox summaries show identity/contact/status/note/actions; birth date/gender remain fully available in the explicit existing drawer. Full-context explanations are accessible beside the page title. Owner visual UAT is pending.
