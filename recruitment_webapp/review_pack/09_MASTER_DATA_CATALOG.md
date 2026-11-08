# 09. Danh mục / Master Data — Phase 1 Physical Model

## 1. Menu cha: Danh mục
Các mục Phase 1 có physical table/FK tương ứng:
- Khoa/Phòng
- Ngành/Tổ
- Vị trí
- Nhóm vị trí
- Phòng/Địa điểm
- Hình thức phỏng vấn
- Người dùng
- Học vấn
- Nguồn tuyển dụng
- Loại tài liệu
- Lý do hủy
- Lý do từ chối

Permission catalog là cấu hình security; Root Admin quản trị, không phải danh mục nghiệp vụ thông thường cho HR.

## 2. Khoa/Phòng → Ngành/Tổ → Vị trí
Searchable dependent dropdown. Position physically references Unit and optional Team. Application repeats these as a historical/assignment snapshot but DB/RPC enforces null-safe equality with Position.

## 3. Nhóm vị trí
Physical table with at least:
- code; VI/EN label;
- `requires_demo_topic`;
- active.

Position references Position Group by FK.

## 4. Học vấn
Physical Qualification table. Education row references Qualification by FK; values remain HR-editable master data under Delete/Inactive rule.

## 5. Hình thức phỏng vấn
Fields:
- code, VI/EN label;
- `requires_room`;
- `requires_meeting_link`;
- active.

Scheduling command validates these metadata instead of hard-coding only the visible label.

## 6. Người dùng
Fields include Name, EIU Email, Job Title, Unit, Active, Auth binding, HR role and Root flag.

Identity rule:
- before Auth bind: directory manager may correct EIU email typo;
- after bind: email/Auth identity change is Root-only in Phase 1;
- Root identity change uses recovery process;
- inactive user cannot login or be newly selected; historical snapshots remain.

New HR receives Full HR Permission Set by default; Root Admin may revoke individual permissions.

## 7. Recruitment Source / Document Type / Reasons
All are physical lookup tables in Phase 1. Referenced values are inactivated rather than hard-deleted.

Document Type can carry scope/metadata used by UI and upload validation.

## 8. Delete rule
- no business reference → hard delete allowed;
- referenced → Inactive;
- inactive values excluded from default selectors;
- Root Admin protected.

## Historical master-data semantics
- Referenced master records cannot change **structural meaning**. Structural change = create a new record + Inactive old record.
- Display-label typo corrections may be allowed with optimistic versioning + audit when business meaning is unchanged.
- `Inactive` means unavailable for new selection, not invalid for historical records. Existing Interviews using an inactive Interview Format remain operable.
- All Phase-1 masters use consistent `updated_at + version_no`.
- `document_types.scope_code` must be seeded explicitly, not defaulted blindly: CV/Degree/Transcript/Certificates = SUBMISSION; Slide/Publication/Portfolio = INTERVIEW; Other = BOTH.
- `requires_demo_topic` is advisory UI metadata in Phase 1; it does not create an undocumented blocking rule. Cancellation/Rejection reason and Recruitment Source remain optional unless a future owner decision makes them required.

- `Recruitment Source` is optional HR-editable Submission metadata in Phase 1, not Candidate-required input.
- Cancellation reason is optional only while Schedule Status = CANCELLED; leaving CANCELLED clears current reason while audit retains history. Rejection reason is optional only while Report Status = REJECTED; leaving REJECTED clears current reason while audit retains history.
