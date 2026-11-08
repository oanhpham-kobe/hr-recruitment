# PAGE OVERRIDES — v1.8

These rules are normative page details that complement `TABLE_LAYOUT.md` and component specs.

## Candidate Form
Final section before Submit:
- Privacy Notice title + localized summary/details link;
- Notice version metadata;
- required acknowledgement checkbox;
- validation error when not acknowledged;
- Submit disabled until required form + CV + acknowledgement are valid.
File add/replace/delete shown as pending until Save/Submit; Cancel discards pending file changes.

## Quản lý phiếu ứng tuyển
Parent row uses latest Submission snapshot for Name/DOB/Gender/Phone/Status/HR Note; verified Email remains Candidate identity. Older Submissions expand as history. Pagination entity = Candidate. Sticky context = Select + Name.

## Interview
`Ứng tuyển` uses `SubmissionSelector`, option shows Candidate Name, verified Email, submitted date and status. Inactive history filter: Active / Inactive / All. Application can be Reactivated when permitted. Sticky context = Select + Candidate/Application identity.

## Báo cáo phỏng vấn HR
Table uses `TableScrollContainer`, exact min-width 1610px from `TABLE_LAYOUT.md`, sticky Select + Họ và tên. Aggregate drawer does **not** have a generic Delete. Delete/Inactive is report-specific next to a concrete participant report.

## Email Preview
Phase 1 fields: To, CC when supported, Subject, Body. **No Attachments control.**

## Người dùng & Phân quyền
Persona-specific desktop columns:
- **Root Admin:** `Họ tên | Email EIU | Auth binding | Active | HR role | Effective permissions | Cập nhật gần nhất | Action`
- **Non-root Directory Manager:** `Họ tên | Email EIU | Auth binding | Active | HR role/protected state | Cập nhật gần nhất | Action` — no other-user granular permission details.
- `Auth binding`: `Bound` / `Unbound`.
- Unbound: authorized directory edit may correct EIU email typo.
- Bound: generic Edit does not expose email/Auth rebind. Root-only security action is separate.
- Root row shows protected state; dangerous identity action is absent from normal UI.
- Root Permission editor auto-selects prerequisites or blocks incoherent combinations. Non-root may view only their own effective permissions outside this directory table; another user's granular list is not exposed without a future explicit permission.

## Danh mục
Default columns:
`Tên | Code | Parent/Scope (when applicable) | Active | Đang được sử dụng | Cập nhật gần nhất | Action`
Filters: `Active | Inactive | All`.
Referenced rows:
- structural fields disabled;
- show reference/usage indication;
- message: `Bản ghi đang được sử dụng. Để thay đổi cấu trúc, hãy tạo bản ghi mới và ngưng sử dụng bản ghi hiện tại.`
Display-label typo correction may remain available when policy allows.

## Search state
PII search text (name/email/phone) is not stored in URL. URL may keep page/sort/status/non-sensitive filters.

## Inherited Review-v4 amendments — still current in v1.8
### HR Submission Inbox documents
Drawer includes `FileList` + `FilePreview` + async scan/upload state. Upload/Replace/Delete actions are permission-controlled and show max-5/current-CV/malware errors from trusted command responses.

### User lifecycle governance
`AuthBindingBadge` distinguishes Bound/Unbound. Directory manager can lifecycle only non-HR/non-Root users; HR-role target Active/Inactive is Root-only. Bound identity rebind remains privileged.

### Email
Phase 1 has no attachments. UI may state “queued/sent/failed”; client retry prevents duplicate logical enqueue only. It must not claim exactly-once recipient delivery.


## Candidate EDIT Privacy
EDIT_SUBMISSION uses the same final `PrivacyNoticeAcknowledgement`. Server-pinned notice version is shown; Save disabled until acknowledged. Already-acknowledged same version may render satisfied, but server validates it. Newly pinned version requires new acknowledgement.

## Internal User delete classification
Normal Users & Permissions UI does **not** expose Internal User hard-delete. Unbound/non-HR/non-Root/never-referenced cleanup is Root maintenance-only. Bound or historically used users use Active/Inactive lifecycle; security identity rebind remains a distinct privileged action.


## Responsive Interview / HR Report status controls — v1.8

- Interview and HR Report row status badges use the 144px benchmark width; longer English labels wrap inside the badge.
- Clicking a row status badge opens the dropdown anchored to that badge's bounds. The menu must not be positioned from pointer coordinates.
- Same-trigger toggle, outside interaction, Escape, and selection all dismiss the dropdown. Escape returns focus to the triggering badge/button.
- Interview time is rendered time-first, then date; it stays single-line when space permits.
- Mobile `Thời gian phỏng vấn` label should remain unwrapped at approved mobile widths where the contract provides sufficient label-column space.
