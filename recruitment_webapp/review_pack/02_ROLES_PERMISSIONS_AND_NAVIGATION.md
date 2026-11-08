# 02. Roles, Permissions & Navigation

## Additive navigation — CR-INTERVIEW-FEEDBACK-20261105

Internal navigation includes `/interview-feedback` (Nhận xét phỏng vấn / Interview
feedback). It opens an own-invitation workspace for assigned internal users; HR
management additionally requires `interviews.manage` AND `reports.view`, with
existing Root semantics. The link itself grants no data access. The full new
contract is `101_INTERNAL_INTERVIEW_FEEDBACK.md`; legacy navigation and rights
below retain their meaning. Synthetic persona controls exist only in the
separate localhost preview fixture, never production routes.

## 1. Root Admin

- Hệ thống có **duy nhất 01 Root Admin**.
- Root Admin có toàn bộ permission.
- Chỉ Root Admin được:
  - gán/revoke permission của HR;
  - thay đổi role HR;
  - quản lý quyền hệ thống.
- Root Admin không được Inactive/Hard Delete trong Phase 1 để tránh mất quyền quản trị.
- Root Admin vẫn phải tuân thủ các business safety rule như `CONFIRMED` lock, conflict validation, confirmation dialog; “toàn quyền” không đồng nghĩa silent bypass.

## 2. HR

Một User muốn làm HR phải:
- là internal user Active;
- email hợp lệ `@eiu.edu.vn`;
- có role `Chuyên viên HR`.

Hệ thống vẫn dùng permission granular, nhưng **HR mới được tạo mặc định nhận Full HR Permission Set** để phù hợp vận hành thực tế. Root Admin có thể revoke từng permission để tạo HR hạn chế. Các quyền Root-only/security identity không thuộc Full HR Permission Set.

### Permission catalog đề xuất

| Permission code | Ý nghĩa |
|---|---|
| `submissions.view` | Xem Quản lý phiếu |
| `submissions.edit` | Edit dữ liệu HR-editable của phiếu |
| `submissions.status` | Mark New/Read, xử lý status |
| `candidates.active_manage` | Active/Inactive Candidate account |
| `candidates.delete_unused` | Hard-delete Candidate chưa có Submission/business usage |
| `applications.view` | Xem Application rows/details |
| `applications.manage` | Tạo/update/delete-or-inactive Application; requires `applications.view` |
| `interviews.view` | Xem page Interview |
| `interviews.manage` | Tạo/Edit/Copy/Delete-or-inactive Session |
| `interviews.status` | Đổi Interview Schedule Status |
| `interviews.participants` | Add/reorder/remove/re-add Participant |
| `interviews.documents` | Upload/xóa tài liệu Interview |
| `interviews.email` | Gửi thư ứng viên/người tham dự |
| `emails.history_view` | Xem Email History trong đúng parent/context |
| `emails.history_delete` | Xóa Email History với cleanup classification hợp lệ; requires `emails.history_view` |
| `reports.view` | Xem page Báo cáo/Preview/PDF |
| `reports.manage_status` | Đổi Report Status / HR Report Note |
| `reports.visibility` | Ẩn/Hiện với Interviewer |
| `reports.edit_interviewer` | **Sửa report của Interviewer** |
| `reports.delete` | Xóa/Inactive report theo rule |
| `master_data.manage` | Quản lý danh mục được phép |
| `users.directory_manage` | Thêm/sửa/inactive internal user directory; được sửa email typo **chỉ khi user chưa bind Auth** |
| `users.identity_manage` | Security identity rebinding; **Root Admin only trong Phase 1** |
| `users.permissions_manage` | **Root Admin only** |
| `candidates.identity_manage` | Khôi phục email đăng nhập Candidate; Root Admin implicit, HR delegated nếu được cấp (không thuộc default HR) |

Root Admin có implicit allow cho tất cả permission.

### Default HR Permission Set
Khi Root Admin tạo/gán role `Chuyên viên HR`, hệ thống mặc định cấp **toàn bộ HR permission codes** (bao gồm `applications.view`, nhưng không gồm `candidates.identity_manage`, `users.identity_manage`, `users.permissions_manage` và các Root-only recovery actions). Root Admin có thể revoke từng quyền sau đó.

Hệ quả quan trọng: HR mặc định có `submissions.status`, vì vậy workflow bình thường vẫn là **mở Submission NEW → READ**. Permission granular tồn tại để hỗ trợ HR Limited, không phải để HR mặc định thiếu quyền.

### Lưu ý User Directory
HR có `users.directory_manage` có thể:
- thêm internal user;
- sửa tên/chức vụ/business profile;
- Active/Inactive **non-HR, non-Root internal user** theo rule;
- sửa email `@eiu.edu.vn` để sửa typo **khi `auth_user_id` chưa được bind**.

Sau khi Google/Auth identity đã bind, `email`, `auth_user_id`, provider binding là **security identity**, không còn là directory text field. Rebinding user đã bind là Root-only trong Phase 1; Root Admin identity chỉ đổi qua recovery procedure riêng.

HR **không được tự cấp quyền HR**. Permission assignment chỉ Root Admin.

Permission dependencies are authoritative: edit/status/delete/email/manage capabilities require the corresponding view/context permission where one exists; Root permission UI auto-grants prerequisites or blocks invalid combinations. Normal Phase-1 Submission creation remains Candidate-owned.

Permission-detail visibility: Root may view every user's granular effective permissions. A non-root `users.directory_manage` user can view allowed directory/lifecycle fields but not another user's granular effective-permission list; non-root may view only their own effective permissions.

## 3. Interviewer

Interviewer là **contextual permission**.

Một active internal user chỉ thấy một record khi **toàn bộ** predicate sau đúng:
```text
application.is_active = true
AND interview.is_active = true
AND participant.user_id = current_user
AND participant.is_current = true
AND visible_to_interviewers = true
AND app_user.is_active = true
```
Hai điều kiện đầu là canonical `access_active`. Inactive parent Application thu hồi contextual access ngay nhưng không xóa lịch sử.

Được:
- xem Interview info của Session mình tham dự;
- xem/tải tài liệu;
- tạo/edit report của chính mình khi Report Status chưa final;
- xem shared Preview;
- tải PDF.

Không được:
- đổi Interview;
- sửa report người khác;
- đổi HR status;
- thấy HR Note/HR owner/final-source metadata;
- thấy Session khác nếu không phải participant.

## 4. Candidate

- Login/xác thực email.
- Candidate email lấy từ Auth, read-only.
- Không ai edit Candidate email trong Candidate/Profile/Submission.
- Candidate Active mới vào Portal.
- Tạo Submission mới.
- Xem Phiếu của tôi.
- Edit khi Candidate-facing status = `Mới`.
- Không thấy HR Note/Application/Interview/Report nội bộ.

## 5. Navigation

### Root Admin
Tất cả internal pages + quản trị permissions.

### HR
Sidebar item Phase 1 chỉ hiện khi có permission tương ứng:
- Quản lý phiếu ứng tuyển — `PHASE1_RENDERED`
- Interview — `PHASE1_RENDERED`
- Báo cáo phỏng vấn — `PHASE1_RENDERED`
- Danh mục — `PHASE1_RENDERED` khi có quyền
- Người dùng & Phân quyền — `PHASE1_RENDERED` khi có quyền

Các module sau hiện là `FUTURE_HIDDEN / NOT_RENDERED`, không tạo menu rỗng:
- Dashboard
- Nhu cầu tuyển dụng
- Candidate Database
- KPI & Reports

### Interviewer
- Báo cáo phỏng vấn

### Candidate
- Đăng ký mới
- Phiếu của tôi

## 6. HR sửa report của Interviewer

Nếu HR có `reports.edit_interviewer`:
- HR được mở report của từng interviewer và sửa.
- `updated_by/updated_at` ghi đúng HR.
- Nếu HR đang sửa bản stale và Interviewer đã cập nhật trước → HR bị block và phải reload.
- Nếu Interviewer đang dùng bản stale do HR vừa sửa → Interviewer được ưu tiên ghi bản của mình; conflict được log.
- HR-to-HR stale update → block/reload.
- Interviewer same-account multi-tab stale update → block/reload.

## 7. RLS bắt buộc

UI ẩn nút **không đủ**. Backend/RLS phải enforce:
- Candidate ownership + active + editable status.
- HR permission code cho từng action.
- Interviewer contextual access.
- Root Admin unique.
- Internal user Active/domain validation.
