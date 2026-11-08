# 01. Product Scope & Architecture

## 1. Mục tiêu

Xây dựng web app tuyển dụng nội bộ giúp HR xử lý hồ sơ từ lúc ứng viên tạo phiếu đến Interview và Báo cáo phỏng vấn mà không phải vừa thao tác ngoài hệ thống vừa nhập lại AppSheet.

Nguyên tắc:
> **Thiết kế xoay quanh hành động của HR; KPI/tracking là đầu ra của hành động.**

## 2. Kiến trúc nghiệp vụ cốt lõi

```text
Candidate
  └── Submission (Phiếu ứng tuyển)
        └── Application
              ├── Interview Session - Vòng 1
              │     ├── Participants
              │     ├── Interview Documents
              │     ├── Email History
              │     └── Interview Reports (1 người = 1 report)
              ├── Interview Session - Vòng 2
              └── Interview Session - Vòng N
```

### Candidate
Một tài khoản ứng viên theo verified email.

### Submission
Mỗi lần Candidate gửi form là một snapshot riêng. Cùng email có thể có nhiều Submission.

### Application
Một lần xét **một Submission** cho đúng một tổ hợp:

`Khoa/Phòng + Ngành/Tổ + Vị trí`

Tổ hợp này là identity của Application. Nếu một thông tin trong tổ hợp khác → tạo Application khác.

### Interview Session
Một vòng phỏng vấn của Application.
Một Application có thể có nhiều vòng ngay Phase 1.

### Interview Report
Mỗi participant có một report riêng theo từng Interview Session.

## 3. Current Round

`Current Round` = Interview Session có `round_no` lớn nhất trong tập `access_active` của Application (`Application.is_active AND Interview.is_active`).

- Page Interview quản lý tất cả vòng.
- Page Báo cáo phỏng vấn chỉ dùng Current Round cho bảng chính/Preview/PDF.
- Vòng cũ vẫn giữ lịch sử.
- Nếu current round bị inactive, hệ thống fallback về active round gần nhất trước đó.
- Không được tạo vòng mới nếu round có round_no lớn nhất đang inactive.

## 4. Application durable identity không được rewrite

Ngay từ khi Application được tạo, tổ hợp `Submission + Khoa/Phòng + Ngành/Tổ + Vị trí` là durable identity và **không được đổi** trên chính Application đó.
- Muốn xét tổ hợp khác → tạo/tìm Application khác theo identity mới.
- Exact duplicate cùng tổ hợp, dù Active hay Inactive, luôn resolve về cùng một Application ID.
- Nếu Active → warning + confirm rồi update các field không thuộc identity.
- Nếu Inactive → dùng Reactivate; không tạo duplicate Application ID.

## 5. Role model

### Root Admin
- Chỉ 1 user duy nhất.
- Có toàn quyền.
- Gán/revoke permission cho HR.
- Không được hard-delete/inactive trong Phase 1 để tránh lockout.

### HR
- Là internal user có role `Chuyên viên HR`.
- Quyền chi tiết được Root Admin gán theo permission.
- Có thể được cấp quyền sửa report của Interviewer.

### Interviewer
- Không cần role cố định riêng.
- Active internal user được chọn trong Participants sẽ có quyền contextual trên đúng Interview Session đó.

### Candidate
- Login bằng verified email.
- Chỉ xem/chỉnh dữ liệu Candidate Portal theo rule.

## 6. Tech direction

- Frontend/hosting: Vercel + Next.js App Router.
- Backend/Auth/DB/Storage: Supabase.
- PostgreSQL RLS + explicit grants bắt buộc.
- Sensitive implementation views để private/non-exposed hoặc security-invoker nếu expose.
- Mutations nhiều side effect qua authenticated Server Action + transactional RPC/DB command.
- Optimistic concurrency + idempotency cho action nhạy cảm.
- Business Logic v1.2 frozen; **Technical Specification Freeze** must pass before production coding. Production migration/RLS/RPC/race/storage/performance/backup/deployment evidence belongs to the post-coding **Implementation Validation / Migration Freeze**, not to the pre-code specification freeze.


## Architecture gate and authorization boundary
Business Logic remains frozen while Technical Architecture has a separate gate. v1.17 is the current implementation-contract **frozen specification package**, not a production migration bundle. One UI mutation must map to one explicit backend command; private data access is enforced by RLS/GRANT plus server authorization, not UI visibility.

## Candidate form sessions and lifecycle architecture
Pre-submit Candidate uploads live under a temporary Candidate Form Session; a Submission remains a submitted snapshot and is created only on Submit. Submission operational status has manual states NEW/READ and system-derived states PROCESSED/DONE/CLOSED. Candidate Inbox parent summary uses latest Submission; historical submissions remain preserved. Application can be Reactivated in Phase 1 under validation/audit.
