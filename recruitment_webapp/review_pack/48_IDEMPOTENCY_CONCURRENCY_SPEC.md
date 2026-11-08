# 48. Idempotency & Concurrency Specification — v1.8

## Idempotency
Required for Candidate Submit, Create Application, Create Next Round, Copy/Save logical schedule mutation where retry can duplicate, enqueue email, finalize upload, persisted PDF generation. Same actor/scope/command/key returns prior result.

## Optimistic locking
Mutable entities use `version_no`; client sends expected version. Stale update fails unless the specific report merge algorithm safely merges disjoint patches.

## Report concurrency & Field-Aware Merge
Mỗi Interviewer sở hữu một report riêng. HR có thể sửa report theo quyền được cấp.
- Request patch gửi kèm `expected_version_no` và `base_values` cho từng field được sửa.
- Server lock row report và so sánh giá trị hiện tại trong DB với `base_values`:
  - `current == base`: patch an toàn;
  - `current != base`: conflict trên cùng field.
- Với HR: conflict cùng field → từ chối với `STALE_VERSION` để client reload; các field disjoint được merge tự động.
- Với Interviewer sửa report của chính mình: owner-wins cho eligible conflict cùng field; các field disjoint được merge.
- Tuyệt đối không cho phép ghi đè toàn bộ row (whole-row overwrite) khi stale.
- Decision fields form one logical block: chỉ khi một trong 3 final fields thực sự thay đổi thì mới cập nhật `decision_updated_at/by`.
## Mandatory schedule consistency
Transaction alone under Read Committed is insufficient. Every mutation that can create/restore an operational interval must:
1. identify Candidate, Room, current Interviewers;
2. acquire transaction-level advisory locks in deterministic sorted resource order;
3. re-query conflicts;
4. mutate;
5. commit.

Shared engine applies to **Save Copy (`copy_interview_schedule`)**, save/reschedule, add/re-add participant when scheduled, reactivate, and CANCELLED→active status. Save Copy is not a client-only final mutation: the client draft remains non-mutating, while the trusted Save Copy command uses this shared deterministic Candidate/Room/Interviewer lock + conflict engine before commit.

Interval semantic: `[start_at,end_at)`. Do not use the legacy overloaded `effective_active` term. Canonical predicates are:
- `access_active` = active Application + active Interview;
- `resource_blocking` = `access_active` + schedule status not `CANCELLED` + both interval endpoints present.
Every `resource_blocking` Interview participates in conflict checks, whether or not it is Current Round.


## Confirmed Reschedule Concurrency (Owner Decision J)
Khi một Interview đang ở trạng thái `CONFIRMED` cần đổi lịch/phòng/meeting link:
- Thao tác diễn ra qua một backend transaction nguyên tử duy nhất (`reschedule_confirmed_interview`);
- Kiểm tra quyền `interviews.manage`, optimistic version, idempotency;
- Thực hiện khóa tài nguyên Candidate/Room/Interviewer và kiểm tra conflict theo framework chuẩn;
- Cập nhật thời gian/phòng/link và đồng thời chuyển `schedule_status_code` thành `AWAITING` trong cùng một transaction;
- Nếu có bất kỳ lỗi validation, conflict hoặc audit nào, toàn bộ transaction rollback: lịch cũ và trạng thái `CONFIRMED` ban đầu được giữ nguyên vẹn.

## Deterministic Bulk Locking
Tất cả các thao tác hàng loạt (bulk operations) tác động lên nhiều row bắt buộc phải:
1. Sắp xếp danh sách target ID theo thứ tự tăng dần xác định (deterministic ascending order) trước khi acquire row locks để chống deadlock;
2. Áp dụng giới hạn kích thước batch xác định (bounded batch size: tối đa 100 items/lần).
## Participant concurrency
Add/remove/re-add/reorder lock the Interview. Reorder writes a complete ordered set; no duplicate current order. Re-add to an already scheduled Interview revalidates conflict.

## Round allocation
Lock Application, then allocate max round+1.

## Mandatory lock order
For all Interview resource mutations: lock **Interview row first** → resolve parent/Candidate → snapshot current Room/Participants → acquire deterministic advisory/resource locks → re-read participant/resource set → conflict check → mutate. This closes reschedule ↔ add/re-add participant races.

For all Application/current-round/report-outcome mutations: lock parent **Submission** before authoritative status recalculation.

Candidate Save/Submit uses form-session idempotency; staged file changes and text commit together.


## Application Reactivate concurrency
`reactivate_application()` locks the durable Application identity/Submission, revalidates eligible Active HR/root ownership, then enumerates every non-elapsed child Interview that would become `reactivation_conflict_relevant = resource_blocking AND end_at > transaction_now`. It acquires resource locks in deterministic global order and re-checks Candidate/Room/Interviewer overlaps before enabling the parent. Reactivation is all-or-nothing for non-elapsed operational intervals. Fully elapsed intervals remain historical and do not block lifecycle recovery even if another historical record overlaps the same past interval.
