# COMPONENTS — v1.8

## 1. AppShell
- dark EIU sidebar + main workspace;
- sticky header;
- top-right `VI | EN`;
- permission-aware navigation.

## 2. Button
Variants: Primary, Secondary, Ghost, Danger, IconButton.
- Font: 16px / 500–600.
- Standard height 42–44px.
- Destructive action cần confirmation.

## 3. StatusBadge
- Text bắt buộc; color chỉ hỗ trợ.
- **16px / semibold**.
- Cùng status group → **cùng width**.
- Width lấy theo label dài nhất VI/EN của group, nhưng chỉ đủ dùng, không full-cell.
- Text căn giữa.
- Nếu user có quyền đổi status: badge là button-like control, click mở StatusMenu.
- Nếu không có quyền: read-only badge.

## 4. StatusDropdown / StatusMenu
- Toolbar chỉ dùng **1 nút `Status`**.
- Row badge có thể mở cùng menu.
- Current status có check/selected indication.
- Menu action luôn qua business validation.
- Click badge/menu phải stop row expand/open event.

## 5. SearchField / Combobox
- Input text 16px.
- Type-to-search.
- Searchable combobox single/dependent/multi.
- Candidate option 2 dòng: Name + email.

## 6. DataTable
- semantic `<table>` + `<colgroup>`;
- `table-layout: fixed`;
- page-specific `min-width` when columns exceed the viewport;
- wrapped by a dedicated `overflow-x:auto` table container;
- Page Header/Action Toolbar stay outside horizontal scroll;
- sticky `<thead>` for long lists;
- header 16px semibold;
- cells 16px;
- all business text left aligned;
- long content wraps;
- row hover/focus/selected states are distinct;
- pagination/search is server-backed for growing datasets.

## 7. ExpandableDataRow
- Pointer click toàn parent row non-interactive surface → expand/collapse.
- Không bắt pointer user click riêng chevron.
- Checkbox, status badge, links, combobox and action icons stop propagation.
- First/name cell contains a real semantic expand button for keyboard/screen-reader access (`aria-expanded`).
- Parent không có child → click row mở Drawer.
- Child row → click mở Drawer.
- Child content alignment theo `TABLE_LAYOUT.md`.

## 8. DetailDrawer
- Desktop preferred width **820px**; actual width = `min(820px, available-content-width)` with safe viewport gutters. Below the responsive breakpoint use the full-width/sheet rule.
- Header sticky, body scroll, footer sticky khi edit.
- Layout `Label | Value`.
- Label 16px semibold; value 16px regular.
- Long value wraps.
- Action text 16px.

## 9. Modal / Popup
- Body, labels, controls ≥16px.
- Focused action only.
- Form/action rộng hơn khi translation English cần thêm space.

## 10. ConfirmationDialog
- Title + consequence.
- Cancel trước, destructive sau.
- Không destructive action bằng Enter ngoài ý muốn.

## 11. FilterBar / StickyActionToolbar
- Sticky dưới page header.
- 16px controls.
- `Status` là một dropdown.
- Search/filter area có thể wrap trong responsive phase.

## 12. FormSection
- Label/value/input 16px.
- Helper 14px allowed.
- Single-page form.
- repeated groups add/remove rõ.

## 13. FileList / FilePreview
- filename 16px;
- metadata 14px;
- actions theo permission;
- long filename wrap hoặc accessible full value.

## 14. EmailPreview
- toàn bộ body/field 16px;
- To/CC/Subject/Body;
- **No email attachments in Phase 1**; attachment UI is deferred.
- Hủy | Gửi.

## 15. Report fields
**Không có score/rating/điểm.**
Interviewer report gồm các trường text đã chốt:
1. Kiến thức chuyên môn / Professional Knowledge
2. Kỹ năng cần thiết / Necessary Skills
3. Phẩm chất, tính cách / Qualities and Personality
4. Điểm mạnh và hạn chế / Strengths and Limitations
5. Khác / Other
6. Kết luận / Conclusion
7. Dự kiến công việc cụ thể được phân công / Expected Specific Job Assigned
8. Thời gian dự kiến tuyển dụng / Expected Recruitment Time

## 16. InlineError / Warning / Toast
- text ≥16px khi là primary message;
- 14px chỉ cho metadata phụ;
- không chỉ dùng color/icon.

## 17. UserCard
Sidebar bottom:
- name 16px semibold;
- role 14px;
- avatar/initials + account menu.

## 18. LanguageSwitcher
- text control `VI | EN`;
- top-right;
- selected language visually clear;
- keyboard accessible;
- default VI.


## 19. Pagination / ResultCount
- 16px controls/text.
- Current page, sort and important filters can synchronize to URL query params.
- Loading must preserve table geometry.

## 20. AsyncStatus
- Accessible pending/success/error pattern; use `aria-live` where appropriate.
- Pending buttons keep width and prevent repeat clicks.
- Client pending state does not replace backend idempotency.

## 21. DemoPersonaSwitcher
- Prototype/dev/demo only.
- Clearly labeled `Demo`.
- Options: Root Admin, HR Full, HR Limited, Interviewer, Candidate.
- Switch changes effective prototype menus/actions/permissions.
- Must not exist in production render path.


## 22. SubmissionSelector
Dedicated selector for creating/choosing an Application source. Option must show Candidate name, verified email, Submission date and Submission status. It returns `submission_id`, never only Candidate ID.

## 23. PrivacyNoticeAcknowledgement
Candidate Form final section: localized notice summary/details, notice version, required acknowledgement checkbox, validation message and Submit-disabled state until valid.

## 24. AuthBindingBadge / security identity action
User Directory displays `Bound` / `Unbound`. Unbound email typo correction may live in normal directory edit when authorized. Bound identity change is a separate privileged Root-only action, never the generic Edit form.

## 25. MasterUsageGuard
Referenced master rows show usage/reference state. Structural edits are disabled with guidance to create a new row and Inactive the old record; typo/display-label corrections may remain available under audited policy.

## UniCouncil visual trial — 2026-11-05

`CR-UNICOUNCIL-UI-ADAPTATION-20261105` in MASTER.md supersedes conflicting16px-only list/navigation/filter/pager/badge clauses: these scoped UI elements may use14px/21px; identity names remain16px semibold. Forms, dialog/drawer content and report narratives remain16px, including inline dialogs inside lists. AppShell uses the real aspect-preserved EIU logo and outline SVG icons. The optional demo workspace slot supplies presentation only; its single role/reset/guide dialog never grants production authority. Page explanations move into an accessible context disclosure beside the one main title. Empty bulk controls remain hidden until selection; announcements and safe focus after commands remain available.
