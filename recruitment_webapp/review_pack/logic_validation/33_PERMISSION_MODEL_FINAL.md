# 02. Roles, Permissions & Navigation

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

**Role HR không tự động cấp mọi quyền.** Root Admin gán từng permission.

### Permission catalog đề xuất

| Permission code | Ý nghĩa |
|---|---|
| `submissions.view` | Xem Quản lý phiếu |
| `submissions.edit` | Edit dữ liệu HR-editable của phiếu |
| `submissions.status` | Mark New/Read, xử lý status |
| `candidates.active_manage` | Active/Inactive Candidate account |
| `applications.manage` | Tạo/update/delete-or-inactive Application |
| `interviews.view` | Xem page Interview |
| `interviews.manage` | Tạo/Edit/Copy/Delete-or-inactive Session |
| `interviews.status` | Đổi Interview Schedule Status |
| `interviews.participants` | Add/reorder/remove/re-add Participant |
| `interviews.documents` | Upload/xóa tài liệu Interview |
| `interviews.email` | Gửi thư ứng viên/người tham dự + quản lý email history |
| `reports.view` | Xem page Báo cáo/Preview/PDF |
| `reports.manage_status` | Đổi Report Status/HR Note/HR owner |
| `reports.visibility` | Ẩn/Hiện với Interviewer |
| `reports.edit_interviewer` | **Sửa report của Interviewer** |
| `reports.delete` | Xóa/Inactive report theo rule |
| `master_data.manage` | Quản lý danh mục được phép |
| `users.directory_manage` | Thêm/sửa/inactive internal user directory |
| `users.permissions_manage` | **Root Admin only** |

Root Admin có implicit allow cho tất cả permission.

### Lưu ý User Directory
HR có `users.directory_manage` có thể:
- thêm internal user;
- sửa tên/chức vụ/email;
- Active/Inactive user.

HR **không được tự cấp quyền HR**. Permission assignment chỉ Root Admin.

## 3. Interviewer

Interviewer là **contextual permission**.

Một active internal user thấy một record khi:
```text
application.is_active = true
AND interview.is_active = true
AND participant.user_id = current_user
AND participant.is_current = true
AND visible_to_interviewers = true
AND app_user.is_active = true
```

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
Sidebar item chỉ hiện khi có permission tương ứng:
- Dashboard
- Nhu cầu tuyển dụng
- Quản lý phiếu ứng tuyển
- Candidate Database
- Interview
- Báo cáo phỏng vấn
- KPI & Reports
- Danh mục

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


## v1.4 default HR permission clarification
Granular permission remains the authorization model, but a newly assigned HR receives the **Full HR Permission Set by default**. Root Admin may revoke individual HR permissions. Root-only identity/permission/recovery capabilities are excluded from the HR default set. `submissions.view` alone is read-only; ordinary default HR also has `submissions.status`, therefore opening NEW still changes it to READ.

## v1.7 canonical Interviewer contextual access
All predicates are mandatory: parent `Application.is_active`, `Interview.is_active`, current-user Participant `is_current=true`, `visible_to_interviewers=true`, and Active Internal User. This canonical `access_active` + participant predicate supersedes shorter historical lists.
