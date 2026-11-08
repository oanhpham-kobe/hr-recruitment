# DESIGN REVIEW CHECKLIST — v1.8

## Foundation
- [ ] Be Vietnam Pro consistent.
- [ ] Main content >=16px.
- [ ] Table header 16px semibold.
- [ ] Status badge 16px semibold.
- [ ] Helper only drops to 14px when secondary.

## Sidebar / shell
- [ ] Dark EIU-blue desktop sidebar 244px.
- [ ] Logo/product identity clear.
- [ ] Active item visually obvious.
- [ ] Page Header + Action Toolbar remain visible as designed.
- [ ] `VI | EN` top-right, default VI.

## Tables
- [ ] Semantic table + colgroup + fixed page spec.
- [ ] Table has suitable min-width instead of shrinking text.
- [ ] Horizontal scroll is limited to table container.
- [ ] Toolbar does not move horizontally with table.
- [ ] Sticky table header works without overlap.
- [ ] header/content cells left aligned.
- [ ] long business content wraps.
- [ ] expanded child aligns to parent columns.
- [ ] pointer click on parent row expands/collapses.
- [ ] checkbox/status/action/link does not trigger parent expand.
- [ ] semantic keyboard expand control exists.

## Status
- [ ] Same group badges equal width.
- [ ] Badge text centered and not clipped in VI/EN.
- [ ] one toolbar Status dropdown.
- [ ] authorized badge click opens same Status menu.
- [ ] read-only badge has non-interactive semantics.

## Drawer / Modal / Preview
- [ ] body >=16px.
- [ ] `Label | Value` alignment consistent.
- [ ] long text/EN translation wraps.
- [ ] focus trap/return focus/Esc/unsaved state correct.

## Report
- [ ] no score/rating/stars/points.
- [ ] exact 5 qualitative + 3 final-decision fields.
- [ ] UI does not imply every Interviewer must fill final block.
- [ ] final-source metadata is HR-only as specified.
- [ ] official PDF structure is not invented before owner template.

## Language / locale
- [ ] switching VI/EN preserves current state.
- [ ] system copy switches; user-entered content does not.
- [ ] document language attribute updates.
- [ ] dates/numbers use locale-aware formatting.

## Prototype persona
- [ ] available in prototype/dev when useful.
- [ ] each persona changes effective prototype permissions.
- [ ] clearly labeled Demo.
- [ ] absent from production build/path.

## Accessibility
- [ ] semantic buttons/links/forms.
- [ ] visible focus.
- [ ] keyboard interaction.
- [ ] async/error feedback accessible.
- [ ] no color-only state.
- [ ] reduced motion.

## Responsive/go-live
- [ ] Desktop v1.8 UAT complete before responsive freeze.
- [ ] Candidate Login mobile pass.
- [ ] Candidate Form mobile pass.
- [ ] Phiếu của tôi mobile pass.
- [ ] Internal tablet/mobile scope documented before production acceptance.


## Current additional checks — v1.8
- [ ] Every normal-size status foreground/background pair passes ≥4.5:1.
- [ ] Application Inbox / Interview / HR Report use approved colgroup widths at 1280 and 1440.
- [ ] Parent and expanded rows share exact columns.
- [ ] No generic table cell uses `overflow-wrap:anywhere`; only `.wrap-anywhere` cells do.
- [ ] Future-hidden modules are absent from production sidebar.


## Inherited Review-v3 checks — current in v1.8
- [ ] HR Report table width arithmetic equals 1610px.
- [ ] TableScrollContainer present on HR Report.
- [ ] Select + identity sticky columns tested at 1280/1440.
- [ ] Candidate Inbox parent summary is latest Submission.
- [ ] SubmissionSelector shows date + status and returns submission_id.
- [ ] Candidate Form includes Privacy acknowledgement.
- [ ] Email Preview has no attachment control in Phase 1.
- [ ] Users & Permissions distinguishes Bound/Unbound identity.
- [ ] Catalog referenced-record lifecycle is explicit.
- [ ] Drawer rule works at 1280 without contradictory min/max.
- [ ] Gold not used as normal body-text color on light surface.
- [ ] PII search not serialized into URL.

## Candidate EDIT Privacy
- [ ] EDIT_SUBMISSION shows the server-pinned Privacy Notice and Save cannot proceed without valid acknowledgement.
- [ ] Already-acknowledged same version is handled idempotently; newly pinned version requires acknowledgement.
- [ ] 200% text zoom has no loss of content/functionality.
- [ ] 400% reflow passes where WCAG SC 1.4.10 applies; wide semantic data tables may retain intentional two-dimensional scrolling.
- [ ] Focus remains visible and reachable in sticky-column layouts.
