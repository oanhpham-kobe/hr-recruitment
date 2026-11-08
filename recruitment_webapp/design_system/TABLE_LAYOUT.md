# TABLE LAYOUT — v1.8

## 1. Chosen implementation model
**Approach A: semantic `<table>` + `<colgroup>` + `table-layout: fixed`.**

This is a hard design rule for the main operational tables.

## 2. Column source of truth
Each page owns one column specification. Parent rows, expanded rows, loading skeletons and child rows reuse that same specification.

Rules:
- long-content columns receive more width;
- compact fields receive explicit smaller widths;
- checkbox/action columns are fixed;
- Status column width accounts for the group badge width;
- do not recalculate width row by row;
- do not use content-dependent auto layout as the primary layout system.

## 3. Laptop width and horizontal overflow
At 16px body typography, 8–10 operational columns may legitimately exceed the available content area on 1366–1440px laptops.

Do **not** shrink font or collapse essential content just to avoid scrolling.

Pattern:

```text
Sticky Page Header
Sticky Action Toolbar
────────────────────────────
Table Scroll Container
  └─ overflow-x:auto
      └─ <table min-width=page-spec>
          ├─ <colgroup>
          ├─ sticky <thead>
          └─ <tbody>
```

Important:
- Page Header and Action Toolbar stay outside horizontal scroll.
- Table can have a page-specific `min-width`, e.g. 1200–1700px depending on columns.
- Use smooth native scrolling; avoid custom fake scrollbars unless accessibility-tested.
- Preserve vertical sticky table header where the table viewport is long.

## 4. Alignment
- Header: left.
- Text/business content cell: left.
- Long content wraps naturally.
- Checkbox/icon-only action may use its component alignment.
- Status cell reserves the column width but the badge itself is centered within that cell.

## 5. Expanded rows
Pointer:
- click parent row non-interactive surface → expand/collapse.
- checkbox/status/actions/links call `stopPropagation()`.

Structure:
- child content remains within the same table/column model;
- child rows may leave unrelated columns blank but must align to the parent column boundaries;
- do not render a free-floating inner card whose columns no longer match the parent table.

Accessibility:
- the first/name cell includes a real semantic expand control with `aria-expanded` and associated row/group context;
- mouse/touch users do not need to click this control specifically because full-row pointer interaction is retained.

## 6. Page-level examples
### Quản lý phiếu ứng tuyển
Columns:
`Select | Tên | Email | Ngày sinh | Giới tính | SĐT | Trạng thái | HR Note | Action`

Expanded Submission rows reuse the table grid. The business values `Ngày ứng tuyển | Status | HR Note` must be aligned to explicit compatible columns, not visually indented into a separate arbitrary card.

### Interview
Parent Application identity may expand into Interview Rounds. Each Round remains aligned to defined columns such as time/location/status/note/action.

### Báo cáo phỏng vấn
One main row per Application uses Current Round. Historical rounds are opened in history/detail context rather than breaking column alignment.

### Candidate — Phiếu của tôi
If an expandable pattern is used, it follows the same rule; otherwise use a straightforward table/list appropriate for mobile.

## 7. Content wrapping
For business data:
- use `white-space: normal`;
- use `overflow-wrap: anywhere` only for unbreakable strings such as long emails/links where required;
- do not default to single-line ellipsis for HR Note/business text if the purpose of the table is to read that content.

For deliberately secondary dense metadata, page spec may choose a constrained line count, but this is an explicit override.

## 8. Status badge sizing
Within a status group:
- same width across every status;
- calculated from the longest approved label across VI/EN plus padding;
- fixed/min width in that group; not global across unrelated status groups;
- 16px semibold;
- centered text;
- must not clip or truncate.

## 9. Sticky behavior
- Page Header: sticky/fixed per shell.
- Action Toolbar: sticky directly below Page Header.
- Table Header: sticky within vertical content/table area.
- Horizontal scrolling affects table only.
- For wide operational tables, sticky context columns are **Select + primary identity (Candidate/Application name)**. Keep the sticky set minimal; test focus, z-index, border/shadow and horizontal-scroll behavior.
- Show a subtle overflow edge indicator/shadow when more horizontal content is available; it must not encode meaning by color alone.

## 10. Pagination/search
Growing HR datasets use server-side pagination/search.

UI requirements:
- preserve page/filter/sort in URL where practical;
- debounce text search;
- avoid network request on every keystroke without debounce/minimum-query logic;
- loading state must preserve column widths;
- empty state must not collapse the table shell unexpectedly.


## 11. Frozen desktop column specifications — baseline
These are Design System defaults for 1280/1440 review. Page-specific implementation may adjust only through a documented design change; parent/child rows always reuse the same `colgroup`.

### Application Inbox — min table width 1560px
| Column | Width | Wrap | Priority |
|---|---:|---|---|
| Select | 48px | no | fixed |
| Tên | 220px | yes | high |
| Email | 250px | anywhere utility only | high |
| Ngày sinh | 130px | no | medium |
| Giới tính | 100px | no | low |
| SĐT | 150px | yes | medium |
| Trạng thái | 150px | no | high |
| HR Note | 420px | yes | medium |
| Action | 92px | no | fixed |

### Interview — min table width 1480px
| Column | Width | Wrap | Priority |
|---|---:|---|---|
| Select | 48px | no | fixed |
| Ứng viên / Application | 340px | yes | high |
| Thời gian | 250px | yes | high |
| Địa điểm | 220px | yes | medium |
| Trạng thái | 170px | no | high |
| Ghi chú | 360px | yes | medium |
| Action | 92px | no | fixed |

### Báo cáo phỏng vấn HR — min table width 1610px
| Column | Width | Wrap | Priority |
|---|---:|---|---|
| Select | 48px | no | fixed |
| Họ và tên | 240px | yes | high |
| Vị trí | 300px | yes | high |
| Thời gian phỏng vấn | 240px | yes | medium |
| Địa điểm | 200px | yes | medium |
| Trạng thái | 190px | no | high |
| Ghi chú | 300px | yes | medium |
| Action | 92px | no | fixed |

### Candidate — Phiếu của tôi — desktop min width 760px
`STT 64 | Ngày ứng tuyển 220 | Trạng thái 180 | Thao tác 180 | flexible remainder`

At narrower internal layouts, preserve table width and horizontal scroll rather than reducing 16px text. Candidate mobile receives a separate responsive pattern.

## 12. Wrapping utility
Generic `.data-table td` must **not** use `overflow-wrap:anywhere`. Normal cells use `overflow-wrap: normal; word-break: normal`. Apply `.wrap-anywhere` only to email, filename, URL or identifier cells that truly contain unbreakable strings.

## 13. Single table-spec authority
`TABLE_LAYOUT.md` is the single Design source for exact desktop operational table columns/order/width/min-width/wrap/sticky behavior. Handover page docs describe business fields but must not invent a second conflicting width specification. Automated validation sums declared widths and fails when the total differs from `min-width`.

## 14. Candidate Inbox parent summary
For grouped Candidate rows, Submission-derived parent values come from the **latest Submission** ordered `submitted_at DESC, submission_id DESC`. Older submissions remain expandable historical children. Group pagination is by Candidate.
