# 10. UI/UX Specification — aligned with Design System v1.8

> Visual source-of-truth is the separate **EIU Recruitment Design System v1.8** pack. This file records the product-specific UI behavior that must stay aligned with frozen business logic.

## 1. Global app shell

Internal desktop app:
- fixed left sidebar: **244px**;
- sticky Page Header;
- `VI | EN` in the top-right utility area, default **VI**;
- sticky Action Toolbar immediately below Page Header;
- page content scrolls independently;
- wide tables scroll horizontally inside their own table container; header/toolbar stay outside that horizontal scroller;
- right-side Detail Drawer does not cover desktop sidebar.

Candidate Portal uses the same visual language but simpler navigation and mobile-priority layouts.

## 2. Typography — hard rule

- Main/body/table content: **minimum 16px**.
- Table header: **16px / semibold (600)**.
- Status badge: **16px / semibold (600)**.
- Input/select/button/field value: **16px**.
- Drawer/modal/popup/preview body: **16px**.
- Labels: **16px / semibold**.
- Helper/meta text may use 14px only when genuinely secondary.

Do not shrink text to force dense operational tables into a laptop viewport.

## 3. Operational tables

Chosen implementation model:

> **Semantic `<table>` + `<colgroup>` + `table-layout: fixed`.**

Rules:
- each page owns one fixed column specification;
- parent rows, expanded rows, loading skeletons and child rows reuse that specification;
- long-content columns receive more width;
- compact columns have explicit width/min/max as needed;
- main table can define a page-specific `min-width` (often 1200–1700px for dense HR tables);
- wrap table in `overflow-x:auto`;
- sticky `<thead>` for long vertical lists;
- header and content cells are left-aligned;
- long business content wraps to new lines rather than default ellipsis;
- status badge itself is centered inside the Status cell;
- server-side pagination/search is expected as data grows.

### Horizontal scroll structure

```text
Sticky Page Header
Sticky Action Toolbar
────────────────────────────
Table Scroll Container
  └─ overflow-x:auto
      └─ table min-width=page spec
          ├─ colgroup
          ├─ sticky thead
          └─ tbody
```

The toolbar must not slide horizontally with the table.

## 4. Expandable row interaction

Pointer behavior:
- parent with children: click anywhere on the **non-interactive row surface** → expand/collapse;
- chevron is only an affordance, not the only click target;
- Checkbox, Status Badge, links, buttons, menus, comboboxes and action icons must stop propagation;
- parent without children: row click opens the Drawer;
- child row click opens the exact child/entity Drawer.

Accessibility:
- include a real semantic expand control/button with `aria-expanded` and accessible name in the first/name cell;
- keyboard users can expand/collapse without relying on a clickable `<tr>` only.

## 5. Status badges and status actions

Badge rules:
- equal width inside the same status group;
- width is sized to the longest approved label across **VI and EN**, with only modest horizontal padding;
- 16px semibold;
- badge text centered;
- color never carries status meaning alone.

Authorized HR/Root Admin can change status through either:
1. one toolbar `Status` dropdown for selected records;
2. clicking the individual row Status Badge.

Both entry points must invoke the same business validation/permission logic.

Read-only personas see a non-interactive badge.

## 6. Language / i18n

- Entire software supports Vietnamese and English.
- Default language: **Vietnamese**.
- Switcher: **`VI | EN`** at top right.
- Switch applies to navigation, page titles, table headers, buttons, status labels, filters, Drawer, modal, validation/warnings and previews.
- User-entered content is not automatically translated.
- Switching language preserves current route/filter state and unsaved form data where safe.
- Date/number formatting is locale-aware; business timezone is `Asia/Ho_Chi_Minh`.

## 7. Drawer

- Opens from right.
- Desktop typical width: **760–860px**, page-specific when needed.
- Layout uses one fixed Label column + one Value column.
- Values wrap for long content.
- Header/action/footer may be sticky when useful.
- One main `Edit` action edits all permitted fields in the Drawer.
- Save/Cancel + unsaved-change warning.

## 8. Modal / Popup

Use Modal for focused actions:
- create/update assignment;
- schedule interview;
- email preview;
- status confirmation;
- destructive confirmation.

Main content typography remains >=16px.

## 9. Searchable combobox / dependent dropdown

Searchable inputs match typed text and support Vietnamese normalization where appropriate.

`Ứng tuyển` uses a dedicated **SubmissionSelector**, never a Candidate-only selector. Search may match Candidate name, verified email and phone, but every selectable option identifies one exact Submission.

Submission option:

**Nguyễn Văn A**  
`abc@email.com`  
`Phiếu: 01/09/2026 · READ`

The component returns `submission_id`; backend never guesses the latest Submission. When opened from a Submission drawer, that `submission_id` is preselected/locked.

Dependent hierarchy:

`Khoa/Phòng → Ngành/Tổ → Vị trí`

- Unit filters Team;
- Team filters Position;
- if Team blank, Position can list Unit-level positions according to master-data rules.

## 10. Quản lý phiếu ứng tuyển

Main columns:

`Select | Tên | Email | Ngày sinh | Giới tính | SĐT | Trạng thái | HR Note | Action`

When Candidate has multiple Submissions:
- parent row click expands;
- child Submission rows reuse the same colgroup;
- business values `Ngày ứng tuyển | Status | HR Note` align to explicit compatible columns;
- no free-floating inner card with drifting columns;
- child row click opens the Submission Drawer.

Single Submission: main row click can open Drawer directly.

## 11. Interview page

Application row displays:

**Nguyễn Văn A**  
`Giảng viên Điện tử – Viễn thông - Khoa Kỹ thuật`

Do not use `·` as separator.

One Application may expand to Vòng 1/2/N. Round child rows remain aligned to the page column spec.

Copy action is independent and does not trigger row expansion.

## 12. Interview Report — no scoring

Hard rule:
- no score;
- no star rating;
- no competency scale;
- no pass percentage.

Each Interviewer report has only:

Qualitative fields:
1. Kiến thức chuyên môn / Professional Knowledge
2. Kỹ năng cần thiết / Necessary Skills
3. Phẩm chất, tính cách / Qualities and Personality
4. Điểm mạnh và hạn chế / Strengths and Limitations
5. Khác / Other

Final Decision block:
6. Kết luận / Conclusion
7. Dự kiến công việc cụ thể được phân công / Expected Specific Job Assigned
8. Thời gian dự kiến tuyển dụng / Expected Recruitment Time

The UI does **not** require every Interviewer to fill fields 6–8. Normally one representative enters the agreed decision. If another Interviewer later changes a final field, that becomes the later agreed revision under the business rule.

## 13. PDF/Print Preview

- Use Current Round only for the current Preview/PDF.
- Interviewer order follows `participant_order`.
- Historical rounds remain in database/history, not merged into the current PDF.
- Final Decision block is sourced from one report according to `decision_updated_at`.
- Do not invent Quốc hiệu/Tiêu ngữ/Tên Hội đồng or other administrative elements.
- Pixel-perfect print layout waits for the official EIU template.

## 14. Demo Persona Switcher — prototype only

Clickable prototype/development may include:
- Root Admin;
- HR Full;
- HR Limited;
- Interviewer;
- Candidate.

It must change menus/actions realistically, but **must not exist as a production authorization mechanism** and must be excluded from production builds.

## 15. Responsive status

Detailed iPad/mobile layout is not yet frozen.

Go-live requirement:
- Candidate Login;
- Candidate Form;
- Phiếu của tôi;

must be mobile-ready.

Internal HR/Admin/Interviewer operations remain desktop-first, then iPad/mobile are designed and UAT-tested after the Desktop prototype revision.

## Owner-authorized UniCouncil visual trial — 2026-11-05

`CR-UNICOUNCIL-UI-ADAPTATION-20261105`, defined in Design System MASTER.md with matching TOKENS/COMPONENTS/ACCESSIBILITY/RESPONSIVE clauses, supersedes conflicting16px-only operational type and demo-control placement. Compact lists/navigation/filters/pagers/badges may use14px/21px; identity names, body/forms, full detail and report narrative remain16px. Mobile inputs/selects remain16px, touch targets44px and contrast/focus requirements unchanged. The existing explicit drawer exposes birth date/gender omitted from narrow Inbox summaries. No business, permission, privacy, ID/version or demo-store behavior is changed. Final Owner visual UAT is pending.
