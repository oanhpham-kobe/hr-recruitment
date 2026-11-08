# 35. Delete / Inactive Decision Matrix

Nguyên tắc chung:
> Không có downstream business usage/reference → Hard Delete.  
> Có downstream business usage/reference → Inactive.

Activity Log không phải blocker.

| Entity | Hard Delete khi | Inactive khi | Lưu ý |
|---|---|---|---|
| Root Admin | Không | Không | Bảo vệ chống lockout |
| Internal User | **MAINTENANCE_ONLY** Root cleanup khi unbound, non-Root, non-HR và chưa từng được tham chiếu | Đã bind Auth / có HR role / đã từng là HR owner/participant/report actor business | Không expose HR UI hard-delete; Inactive không login/chọn mới |
| Khoa/Phòng | Chưa được dùng | Đã dùng trong Application | |
| Ngành/Tổ | Chưa được dùng | Đã dùng | |
| Vị trí | Chưa được dùng | Đã dùng | |
| Room | Chưa dùng | Đã nằm trong Interview | |
| Candidate | Chưa có Submission | Có Submission | Candidate dùng active flag |
| Submission | Không có Application downstream | Có Application | Owned education/docs có thể cascade |
| Application | Không có meaningful Interview/business downstream; auto-created structurally-empty Round 1 được xóa atomic cùng Application | Có meaningful Interview/report/email/docs | Durable identity không rewrite; empty default Round 1 không tính business usage |
| Interview Session | Chỉ round cuối + chưa có business usage | Có participant/report/email/doc hoặc business history | Chỉ round cuối được xử lý |
| Participant | Remove theo nghiệp vụ | is_current=false nếu cần giữ restore/history | D-11 restore/create-new |
| Interview Report | Có thể xóa test/sai nếu không cần giữ | Archive/inactive khi participant lifecycle yêu cầu | Không render khi inactive/archived |
| Email History | Có thể hard-delete trực tiếp | N/A | User yêu cầu cleanup gửi lỗi/test |
| Interview Document | Có thể hard-delete trực tiếp | N/A | Nếu cần audit có thể log action |

## Round stack rule

Ví dụ có Vòng 1,2,3:
- chỉ Vòng 3 được Delete/Inactive;
- không xử lý Vòng 2 trước khi Vòng 3 không còn tồn tại hợp lệ;
- nếu Vòng 3 inactive, không tạo Vòng 4;
- muốn tạo tiếp phải Reactivate Vòng 3 hoặc Hard Delete Vòng 3 nếu đủ điều kiện.

## v1.9 clarification — Submission email usage
Retained PRODUCTION Email Outbox/History referencing a Submission counts as downstream history and prevents unused hard-delete. TEST/WRONG cleanup rows may be removed first under their audited cleanup rule; eligibility is then re-evaluated.
