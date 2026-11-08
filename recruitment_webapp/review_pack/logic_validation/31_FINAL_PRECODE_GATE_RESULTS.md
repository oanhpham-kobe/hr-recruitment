# 31. Final Pre-code Gate Results

**Ngày chạy:** 02/09/2026  
**Phạm vi:** Core Recruitment Intake → Interview → Interview Report  
**Kết quả:** **PASS – Không phát hiện owner/business blocker mới**

## 1. Regression Test

Đã chạy 89 spec-level regression cases sau khi chốt D-01→D-14, F-01→F-09 và permission model mới.

- PASS_SPEC: 84
- TECH_GUARD: 5
- BUSINESS_BLOCKER: 0

Chi tiết: `final_regression_results.csv`.

## 2. Entity Ownership Review

**PASS**

Đã khóa ownership quan trọng:
- Application: Khoa/Phòng + Ngành/Tổ + Vị trí + HR owner.
- Interview Session: round/demo/schedule/report-status/logistics/note/visibility.
- Interview Report: evaluation + decision block từng interviewer.
- Submission: Candidate snapshot + HR Note.
- User/Permission: internal identity + granular permission.

Phát hiện và đã xử lý:
- Demo Topic chuyển về Interview Session.
- Report Status chuyển về Interview Session.
- Application durable identity không được rewrite sau khi Application được tạo; assignment khác phải dùng Application identity khác.
- Page Báo cáo dùng Current Active Latest Round.

## 3. Delete / Inactive Review

**PASS**

Rule thống nhất:
- no downstream business usage → Hard Delete;
- có usage → Inactive;
- Activity Log không block;
- chỉ latest round được delete/inactive;
- root admin không delete/inactive.

## 4. Permission / Security Simulation

**PASS ở mức business spec**

- 1 Root Admin duy nhất, full rights.
- HR granular permissions do Root Admin cấp.
- HR có thể được cấp `reports.edit_interviewer`.
- HR không tự cấp quyền cho mình.
- Interviewer contextual access.
- Candidate isolation.
- UI permission phải đi kèm RLS/backend guard.

## 5. Concurrency Simulation

**PASS với technical guard bắt buộc**

- HR vs HR stale update → block.
- HR vs Interviewer report → Interviewer win; HR stale block.
- Same Interviewer multi-tab stale → block.
- duplicate Application race → DB unique.
- round_no race → transaction/lock.
- schedule conflict race → server re-check.

## 6. Technical Guard còn phải implement

Không cần owner quyết định thêm, nhưng IT phải triển khai:

1. Partial unique constraint cho 1 Root Admin.
2. Unique Application identity có xử lý `Ngành/Tổ = NULL`.
3. Transaction/lock khi cấp `round_no`.
4. Transactional schedule conflict check.
5. Sync Internal User email với Supabase Auth.
6. Permission helper/RLS (`is_root_admin`, `has_permission`).
7. Optimistic versioning cho Interview/Report/Submission edit.
8. Current Round view/function dùng thống nhất toàn hệ thống.

## 7. Gate Decision

### Business Logic Core
**FROZEN v1.2**

### UX/UI
Chưa freeze visual; chờ Design System repo.

### Code
Có thể bước sang:
1. UX/UI mapping/prototype;
2. DB schema review kỹ thuật;
3. RLS/permission implementation plan;
4. coding sau UX UAT.

Không cần thêm business decision trước bước UX/UI.
