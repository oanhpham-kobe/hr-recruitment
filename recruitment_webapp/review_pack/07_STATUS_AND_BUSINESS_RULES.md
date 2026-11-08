# 07. Status & Business Rules

## 1. Candidate Account

`candidate.is_active` là manual override.

- Active → Candidate login Portal.
- Inactive → không login được.
- Khi Inactive, HR UI có thể hiển thị effective status `Inactive`.
- Active lại → Submission status được tính lại theo dữ liệu hiện hành.

## 2. Submission Status

Business status:
`NEW / READ / PROCESSED / DONE / CLOSED`

Candidate-facing:
- NEW → Mới
- READ / PROCESSED → Đang xử lý
- DONE / CLOSED → Hoàn thành
- Candidate Inactive → không truy cập Portal.

Rules:
- Submit → NEW.
- HR mở → READ.
- Mark New chỉ khi không còn active Application.
- Có active Application → PROCESSED.
- Any active Application outcome HIRED → DONE.
- All active Applications outcome REJECTED → CLOSED.
- Không còn active Application:
  - nếu current status là `NEW` hoặc `READ` → giữ nguyên manual state;
  - nếu current status là derived (`PROCESSED`/`DONE`/`CLOSED`) do Application cuối bị remove/inactivate → về `READ`.
- Candidate Reactivate là lifecycle exception: nếu không có active Application → `READ`.
- Candidate Inactive override không xóa status gốc.

## 3. Application identity/outcome

Identity:
`submission_id + unit_id + department_team_id + position_id`

Nếu khác identity → Application khác.

Authoritative effective outcome resolver:
- Outcome của Application được tính **DUY NHẤT từ Current Round** (Interview có `round_no` lớn nhất trong các session `access_active` của Application đó):
  - Current Round `report_status_code = 'HIRED'` → `HIRED`
  - Current Round `report_status_code = 'REJECTED'` → `REJECTED`
  - Các trường hợp còn lại → `IN_PROGRESS`
- Các vòng active cũ hơn **tuyệt đối không độc lập quyết định outcome của Application**.
- Toàn bộ logic tính toán Submission status (`recalculate_submission_status`) và Candidate reactivation recalculation bắt buộc dùng chung một resolver nội bộ duy nhất; không lặp lại mệnh đề `EXISTS(historical HIRED/REJECTED)`.
- Hàm `recalculate_submission_status` là internal helper: thu hồi quyền chạy của `PUBLIC`, `anon`, `authenticated`; chỉ cấp cho `postgres` và `service_role`.
## 4. Interview Schedule Status (Owner Decision A)

`AVAILABLE / SCHEDULED / AWAITING / CONFIRMED / CANCELLED`

- HR đổi thủ công; **không có sequence bắt buộc**, cho phép chuyển trực tiếp giữa các trạng thái.
- Mỗi Interview round có đúng một Schedule Status tại một thời điểm.
- `CONFIRMED` khóa Edit thông thường; muốn đổi lịch phải qua trusted action `reschedule_confirmed_interview`.
- `CANCELLED` là trạng thái lịch, **không chặn tạo vòng tiếp theo** và không tính vào xung đột tài nguyên (`resource_blocking`).
## 5. Report Status

Thuộc Interview Session:

`INTERVIEW_SCHEDULING / AWAITING_INTERVIEW / WAITING_FOR_REPORT / REPORT_SUBMITTED / FOLLOW_UP / ON_HOLD / HIRED / REJECTED`

- HR đổi thủ công.
- Không ép sequence.
- HIRED/REJECTED khóa Edit của Interviewer.
- HR có permission `reports.edit_interviewer` vẫn được sửa report, nhưng concurrency rule phải áp dụng.

## 6. Current Round

Current Round = Session có `round_no` lớn nhất trong tập `access_active` (`Application.is_active AND Interview.is_active`).

- Page Báo cáo/Preview/PDF dùng Current Round.
- Tạo vòng mới → Current Round đổi sang vòng mới.
- Vòng mới report_status = INTERVIEW_SCHEDULING.
- Nếu latest created round inactive → không tạo round mới.
- Chỉ latest created round được Delete/Inactive.
- Không renumber lịch sử.

## 7. Warning vs Blocking

### Warning + cho tiếp tục
- status combination bất thường;
- exact duplicate Application (sau confirm sẽ update existing).

### Block
- Edit Interview khi CONFIRMED.
- Candidate edit khi không New.
- Mark New khi còn active Application.
- Tạo round mới khi latest round inactive.
- Delete/Inactive vòng giữa khi có vòng sau.
- Interviewer/room time overlap.
- Candidate time overlap: **BLOCK** across all `resource_blocking` Interview Sessions of the same Candidate.
- stale HR update.
- action không có permission.

## 8. Delete/Inactive

- Chưa có business usage/reference → Hard Delete.
- Có usage/reference → `is_active=false`.

Activity Log **không** tính là business reference để chặn hard delete.

Owned child data có thể cascade khi parent hợp lệ để hard-delete; downstream business reference mới là blocker.

## 9. Root Admin

- Chỉ 1.
- All permissions.
- Không cho Inactive/Delete trong Phase 1.
- Chỉ Root Admin gán/revoke HR permissions.


## 10. Final Decision Source

- Không yêu cầu tất cả Interviewer nhập 3 final decision fields.
- Hội đồng thống nhất; thông thường 01 Interviewer đại diện nhập.
- Nếu Interviewer khác sửa một trong 3 field sau đó, đó là decision revision mới.
- Final source dựa trên `decision_updated_at`, không dùng generic `updated_at`.
- `decision_updated_at/by` chỉ đổi khi Conclusion / Expected Specific Job / Expected Recruitment Time thay đổi.
- Sửa 5 evaluation fields không đổi Final Decision Source.
- Cả 3 field final luôn lấy từ cùng một source report.

## Submission lifecycle and master-history rules
Submission manual states: `NEW`, `READ`. Submission derived states: `PROCESSED`, `DONE`, `CLOSED`; only the authoritative recalculation function may set derived states. Outcome-changing transactions lock parent Submission before recalculation.

Application supports Reactivate in Phase 1. Inactive Application makes child Interview `access_active=false`; reactivation restores access-active semantics only after required validations/conflict checks.

Referenced inactive master values remain valid for history but cannot be newly selected.


## Canonical status and Interview predicates
- Generic Submission recalculation does **not** convert untouched `NEW` to `READ` merely because no Application exists.
- `access_active`, `current_round`, and `resource_blocking` are distinct; see `73_DOMAIN_GLOSSARY_AND_CANONICAL_PREDICATES.md`.
- Every active, non-CANCELLED Interview with a real `[start_at,end_at)` interval is resource-blocking even when it is not Current Round. Current Round is only the report/outcome/PDF selector.
- Application identity is durable/global for one `Submission + Unit + Team + Position`; exact same assignment is reactivated/updated, never duplicated.
