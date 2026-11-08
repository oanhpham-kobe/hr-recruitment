# 63. Batch Operation Semantics — v1.12

Bulk UI does not imply one universal transaction policy. Each action maps to a named batch command and declares atomicity.

| Operation | Phase-1 semantics |
|---|---|
| Candidate-level latest Submission Mark New/Read | ALL_OR_NOTHING |
| Bulk common Application assignment | ALL_OR_NOTHING |
| Bulk Inactive/Delete where offered | ALL_OR_NOTHING by default; command may narrow scope before mutation |
| Bulk status transition | ALL_OR_NOTHING unless the specific status command documents per-item mode |
| Bulk email | PER_ITEM_ENQUEUE_RESULT; delivery remains asynchronous |

Partial-mode response must return `success[]` and `failed[{id,error_code}]`. Atomic commands return a single failure with no committed subset. UI must describe the chosen behavior before confirmation.


## Phase-1 visible bulk action registry

| UI bulk action | Selection entity | Named command | Atomicity |
|---|---|---|---|
| Candidate Active/Inactive | Candidate | `bulk_set_candidate_active` | ALL_OR_NOTHING |
| Latest Submission Mark New/Read | Candidate | `bulk_set_latest_submission_manual_status` | ALL_OR_NOTHING |
| Interview Delete/Inactive | Interview | `bulk_delete_or_inactivate_interviews` | ALL_OR_NOTHING |
| Interview Schedule Status | Interview | `bulk_change_interview_schedule_status` | ALL_OR_NOTHING |
| HR Report Status | Current-Round Interview | `bulk_change_report_status` | ALL_OR_NOTHING |
| Email enqueue | exact business recipients/entities | `bulk_enqueue_email` | governed by existing email batch contract |

For Application Inbox manual Submission status, Candidate is the UI selection entity; the server resolves and revalidates each deterministic latest Submission under lock. Historical child Submissions are read-only in this bulk UX.

Frontend code must not emulate these lifecycle/status batches by invoking single-row commands in a loop. A failed precondition/conflict on one selected item returns structured failure and commits none of the selected mutations.

## Permission and lifecycle parity clarification
- `bulk_change_interview_schedule_status` requires `interviews.status` + `interviews.view`, exactly matching the single protected field authorization.
- `bulk_set_latest_submission_manual_status` uses the same manual-status eligibility as the single writer: active Application blocks; Candidate Active/Inactive alone does not.

## Command-specific batch parity — current
- **Candidate lifecycle batch parity:** each selected Candidate receives the same `is_active/inactive_at/inactive_by` state transition and per-Submission reactivation recalculation as `set_candidate_active`; per-Candidate audit plus one batch audit event; any stale item aborts all.
- **Interview delete/inactivate batch:** prevalidate all hard-delete temp-upload cleanup prerequisites and durably capture all required cleanup intents before deleting any selected Interview.
- **Report Status batch:** re-resolve Current Round + optimistic versions for the full set; one stale/current-round mismatch aborts all; successful commit recalculates every affected Submission.

## Deterministic Bulk Locking & Bounded Batch Size
Tất cả các bulk commands tác động lên nhiều thực thể bắt buộc:
1. **Sắp xếp target IDs xác định:** sắp xếp toàn bộ danh sách ID theo thứ tự tăng dần (`ORDER BY id ASC`) trước khi acquire row locks để loại trừ nguy cơ deadlock giữa các transaction chạy song song;
2. **Bounded batch size:** áp dụng giới hạn kích thước mảng đầu vào tối đa là **100 items** cho mỗi lần gọi lệnh; request vượt quá 100 items sẽ bị từ chối với `VALIDATION_ERROR`.
