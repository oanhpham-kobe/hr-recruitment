# EIU Recruitment Design System v1.8

## Mục đích
Design System hiện hành cho App Tuyển dụng EIU, cập nhật sau:
- Business Logic Core v1.2;
- Desktop wireframe/clickable prototype review;
- UI rule review của owner;
- technical cross-check với Vercel Agent Skills và Supabase implementation constraints ngày 02/09/2026.

## Nguồn tham chiếu
1. **Business Logic Core v1.2** — source of truth về nghiệp vụ/status/quyền/data ownership.
2. **UI UX Pro Max** — design-system structure, accessibility/resilient UI principles.
3. **EIU MedLabs** — EIU brand direction, Be Vietnam Pro, login/sidebar visual language.
4. **Vercel Agent Skills** — React/Next.js performance + Web Interface Guidelines.
5. **Supabase technical closure** — auth/security/storage constraints that affect UI states.

## Source-of-truth order
1. Business Logic / Technical Handover current version.
2. `MASTER.md`.
3. `TOKENS.md`, `TABLE_LAYOUT.md`, `I18N.md`, `SIDEBAR_NAVIGATION.md`.
4. `COMPONENTS.md`, `PATTERNS.md`, `ACCESSIBILITY.md`, `RESPONSIVE.md`.
5. `AUTH_AND_LOGIN.md`.
6. `pages/*.md` page-specific rules; they may not override a hard rule without a documented change request.

## Current hard rules
- Dark EIU-blue MedLabs-inspired desktop sidebar.
- `VI | EN` top-right; default Vietnamese; whole application UI is bilingual.
- Main body, tables, forms, drawers, modals and previews: **minimum 16px**.
- Table header and Status badge: **16px semibold**.
- Semantic `<table>` + `<colgroup>` + fixed page-level column spec.
- Wide tables keep readable columns and use horizontal scrolling; **do not shrink typography to fit**.
- Sticky page header/action toolbar; table header sticky inside the table scroll context.
- Parent row: pointer click anywhere on the row expands/collapses. Nested interactive controls do not trigger row expansion.
- Accessible keyboard expansion is exposed through a semantic control in the first/name cell rather than making `<tr>` behave like a fake button.
- Long business text wraps; table content cells are left-aligned; Status badge is centered inside its cell.
- Same status group uses equal badge width based on the longest approved VI/EN label.
- Toolbar exposes one `Status` dropdown; authorized users can also click the row badge to open the same status menu.
- Interview Reports have **no scoring/rating/points/stars**.
- Final Decision Source is not an extra UI score: it is derived from decision-specific metadata in Business Logic.
- Prototype-only Demo Persona Switcher is permitted in dev/demo builds only; never production.

## Responsive status
- Desktop rules: current.
- Candidate Login/Form/Phiếu của tôi: mobile readiness is required before go-live.
- Internal HR: desktop-first; iPad/mobile detailed layouts are the next design phase.

## Files
- `MASTER.md` — global design rules.
- `TOKENS.md` — brand/type/spacing/radius/layout tokens.
- `SIDEBAR_NAVIGATION.md` — desktop navigation.
- `TABLE_LAYOUT.md` — table/colgroup/scroll/expand contract.
- `I18N.md` — VI/EN behavior.
- `COMPONENTS.md` — reusable components.
- `PATTERNS.md` — cross-page interaction patterns.
- `ACCESSIBILITY.md` — accessibility hard requirements.
- `RESPONSIVE.md` — responsive foundation/go-live scope.
- `AUTH_AND_LOGIN.md` — Login UI states.
- `PROTOTYPE_PERSONA_SWITCHER.md` — prototype/dev-only permission testing utility.
- `IMPLEMENTATION_NOTES_VERCEL.md` — UI implementation guardrails for Next.js/Vercel.
- `DESIGN_REVIEW_CHECKLIST.md` — review checklist.
- `PAGE_OVERRIDES_V1_8.md` — normative page-specific security/lifecycle/privacy rules.

## Status
- **Business Logic:** Core v1.2 FROZEN; technical amendments are tracked in Full Handover v1.18 without reopening frozen HR workflow.
- **Design System:** v1.8 CURRENT.
- **Responsive Prototype:** v1.10 cross-layer-aligned; Owner Visual UAT still required; NOT FROZEN.
- **Responsive detailed design:** NOT FROZEN.
- **Production Technical Architecture:** separate Technical Closure Gate; not implied by this Design System.


### v1.5 changes from External Review v3
- Candidate Inbox parent summary fixed to latest Submission.
- HR Report table min-width arithmetic corrected to 1610px; table spec is single Design authority.
- Sticky context columns for wide operational tables.
- Phase-1 email attachment UI removed.
- Candidate Privacy acknowledgement and dedicated SubmissionSelector added.
- Bound/Unbound identity and referenced-master lifecycle states added.
- Drawer width contradiction removed; gold usage restricted for body-text accessibility.
- PII search must not be serialized into URLs.
- Prototype remains pending resync; iPad/mobile detailed design remains next phase.
## Validation
- `DESIGN_VALIDATION.txt`: final v1.8 design consistency result.
- `tools/validate_design.py`: inspectable/re-runnable validator, including automatic table-width arithmetic.


### v1.5 changes from External Full Review v4
- Removed remaining Drawer width contradiction package-wide.
- HR Submission Inbox now declares FileList/FilePreview/AsyncStatus.
- Email retry language distinguishes idempotent logical enqueue from at-least-once provider delivery.
- User lifecycle UI makes HR-role target lifecycle Root-only.
- Current version headers/component numbering cleaned and semantic validator expanded.


### Prior release changes incorporated
- Candidate EDIT uses pinned Privacy Notice acknowledgement semantics.
- Measurable 200% zoom / 400% reflow evidence.
- Prototype sync target is Design System v1.8.

### v1.8 changes from External Full Review v6
- Users & Permissions now scopes granular effective-permission visibility: Root sees all; non-root directory managers do not see other users' granular permissions, while a user may see own effective permissions.
- Candidate/Report visual model unchanged; only security projection and current version metadata updated.


### v1.8 responsive/UAT additions
- Responsive Prototype v1.10 is the executable reference bundled with Full Handover v1.18.
- See `CHANGELOG_V1_8.md`, `RESPONSIVE.md`, `PATTERNS.md`, and `PAGE_OVERRIDES_V1_8.md`.
