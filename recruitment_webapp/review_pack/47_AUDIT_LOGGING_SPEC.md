# 47. Audit Logging Specification — v1.8

## 1. Hai khái niệm tách biệt

### Business Activity Log
Dùng cho HR xem lịch sử nghiệp vụ.

### Security Audit Log
Immutable/privileged, phục vụ trace quyền và dữ liệu nhạy cảm.

Việc HR xóa một Email History record **không xóa Security Audit Log**.

### Same-Transaction Requirement & Rollback on Failure
Toàn bộ Security Audit bắt buộc được ghi **trong cùng một database transaction với mutation nghiệp vụ**. Nếu việc ghi log audit thất bại, toàn bộ transaction nghiệp vụ phải rollback.

### Payload tối thiểu (Data Minimization)
Payload audit phải mang tính chất tối thiểu và theo từng event: chỉ ghi nhận danh sách tên trường thay đổi (`changed FIELD NAMES`), metadata actor/entity/version và lý do (nếu có). **Tuyệt đối không dump toàn bộ row PII cũ/mới** vào audit log.

## 2. Events bắt buộc

- login success/failure (theo privacy policy);
- candidate submit/update;
- sensitive candidate read/download nếu policy yêu cầu;
- HR edit;
- status change;
- candidate active/inactive;
- Application create/update/delete/inactive;
- Interview create/copy/reschedule/delete/inactive;
- participant add/remove/reorder/re-add;
- report create/edit;
- final decision source change;
- permission grant/revoke;
- root admin action;
- PDF generation/download;
- email queue/send/fail/delete-history;
- file upload/download/delete;
- concurrency conflict/override outcome.

## 3. Fields

- audit id;
- timestamp;
- actor auth/app user id;
- actor type/persona;
- action;
- entity type/id;
- request id;
- correlation id;
- old/new selected values or diff;
- reason when applicable;
- source (`WEB/RPC/SYSTEM/WORKER`);
- result (`SUCCESS/DENIED/FAILED`);
- safe metadata.

## 4. Không log

- passwords/OTP;
- access/refresh token;
- secret/service-role key;
- full uploaded file content;
- long-lived signed URL token;
- unnecessary sensitive personal content.

## 5. Access

Security audit log không accessible cho Candidate/Interviewer và chỉ accessible cho Root Admin hoặc explicitly authorized security/admin role.

## Mandatory lifecycle and security audit events
Mandatory audit events include internal first-bind, Root break-glass recovery, HR-role removal, Application Reactivate, referenced-master structural-change denial, Candidate Form Session submit/cancel/expiry cleanup summary, malware-scan rejection and unused hard-delete commands. Do not store OTPs, signed URLs, secrets or file contents in audit metadata.
