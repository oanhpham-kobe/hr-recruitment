# PATTERNS — v1.8

## 1. Sticky header + toolbar + table scroller
`PageHeader → StickyActionToolbar → PageContent → HorizontalTableScroller`.

Toolbar must not move horizontally with the table.

## 2. Master-detail
- non-expandable row click → Drawer;
- closing Drawer returns user to previous filter/page/scroll context;
- important filter/page state persists in URL where useful.

## 3. Expand-then-open
- parent row pointer click → expand/collapse;
- nested controls stop propagation;
- semantic expand control remains available for keyboard/screen-reader users;
- child row click → exact detail Drawer.

## 4. Table column discipline
- semantic table + colgroup;
- page-level column spec;
- fixed minimum table width when necessary;
- horizontal scroll instead of font reduction;
- parent/child alignment;
- content wraps.

## 5. Status change
- one toolbar `Status` dropdown;
- clickable badge is individual-row shortcut for authorized users;
- same StatusMenu component/validation path;
- read-only badge is not styled/announced as a button;
- warnings/confirmations remain governed by Business Logic.

## 6. Bulk actions
- checkbox selection;
- selected-count feedback;
- all-or-nothing where business rule says so;
- failed bulk validation names the blocking record(s);
- double-submit protection in UI plus backend idempotency where mutation is retriable.

## 7. Dependent master data
`Khoa/Phòng → Ngành/Tổ → Vị trí` using searchable dependent comboboxes.

## 8. Interview rounds
Same Application = same Submission + assignment identity. Multiple Interview Sessions/Rounds sit under that Application.

- Interview page manages every round.
- Report page main table uses Current Round only.
- new round Demo Topic blank.

## 9. Copy Interview
- creates a new editable draft context, not an immediate blind duplicate;
- HR may change target Application/Candidate where allowed by the flow;
- Demo Topic blank for a new round;
- server conflict validation before commit;
- pointer/UI precheck is supplementary only.

## 10. Report collaboration
- one independent report per Participant;
- no scoring;
- normally one representative fills Final Decision block;
- HR may edit Interviewer report only with permission;
- same-field HR/Interviewer concurrency resolves to Interviewer; different-field edits should be preserved through field-aware patching;
- Final Decision source changes only when one of its 3 fields changes.

## 11. Email preview/send
- manual action → Preview → confirm Send;
- email send is asynchronous/outbox-backed in production;
- UI shows queued/sent/failed state without silently changing Interview status;
- client/API retry with the same idempotency scope must not create duplicate logical Outbox enqueue; provider delivery is at-least-once and may duplicate delivery in the documented provider-accepted/worker-crash edge case.

## 12. Language switch
- default VI;
- `VI | EN` top-right;
- switch changes system UI without resetting current route/filter/unsaved form state;
- user-entered data is not translated;
- date/number format follows locale while business timezone remains fixed by technical spec.

## 13. Delete vs Inactive
- unused/no business history → Hard Delete;
- used/history → Inactive;
- confirmation copy states the consequence clearly.

## 14. Async/loading/error
- stable skeleton/layout, no large content shift;
- async result/error announced accessibly where relevant;
- retry action clear;
- button pending state keeps button width and prevents repeated clicks;
- backend remains authoritative for idempotency and conflicts.

## 15. Prototype Persona
Demo Persona Switcher may simulate permission variations in prototype/dev only. It is not a production component.


## Current grouped pagination — v1.8
Candidate Inbox paginates Candidate groups; Interview and HR Report paginate Application groups. Stable sort includes ID tie-breaker. Do not paginate raw child records if it would split one visual group across pages.

## Current search state — v1.8
Page/sort/status/non-sensitive filters may be URL state. Name/email/phone search terms remain local/request state and are not copied into URL.


## Anchored status menu — v1.8

Status menus opened from a row badge or toolbar Status control are anchored to the trigger element rectangle. They must not use the exact pointer click coordinates as the menu origin. Dismissal: selection, outside pointer/tap, Escape, or same-trigger toggle. Escape restores trigger focus.
