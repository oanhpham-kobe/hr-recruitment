# 40. Database Invariants — v1.12

Hard invariants must not depend only on frontend behavior.

1. Exactly one Root Admin **after bootstrap**: partial unique prevents >1; protected bootstrap/recovery command prevents 0 in normal operation. Root email/auth binding cannot be changed through ordinary directory update.
2. Candidate verified email unique; Submission email snapshot must match Candidate email at snapshot write.
3. Application references Submission only; Candidate derives through Submission.
4. Application hierarchy uses null-safe equality: Unit and Team must match Position, including `NULL = NULL` semantics via `IS DISTINCT FROM`.
5. `round_no > 0`, unique `(application_id, round_no)`.
6. `start_at < end_at` when both exist; operational overlap semantics `[start,end)`.
7. `access_active` Interview = active parent Application AND active Interview. `resource_blocking` additionally requires non-CANCELLED status + complete interval; Current Round is highest `round_no` among access-active Interviews.
8. Current participant user/order unique; participant order >0.
9. Active report belongs to a Participant; one active/non-archived report per Participant.
10. Decision metadata moves only when one of the 3 final fields changes.
11. Logical documents: unique `(logical_document_id,version_no)`, unique current version per logical document, unique storage path, ≤5 MB/file. Bảng `submission_document_logicals(submission_id, document_type_id)` **KHÔNG PHẢI là unique key**; nhiều file cùng loại được phép tồn tại trong hạn mức max 5 current files. Metadata creator/uploader tuân thủ XOR (Candidate vs internal user). Server đánh số `sort_order` 1-based (`1..n`). Max 5 current files per parent enforced in parent-locked finalize command.
12. Interview operational/report notes are separate columns with separate authorization.
13. Internal bound Auth identity cannot be rebound by ordinary directory update; Root identity protected.
14. Master-data FK/reference integrity; referenced item is inactive rather than hard-deleted.
15. Email Outbox logical enqueue idempotency unique; audit log append-only.
16. Schedule mutation obtains deterministic advisory locks on Candidate/Room/Interviewers and rechecks conflicts before commit.
17. Auto-created empty Round 1 does not by itself make Application “used”; hard-delete command may delete both atomically only while the round is structurally empty.

## invariants
- Candidate Form Session is the parent for pre-Submission uploads; no Submission is created on form open.
- Staged Candidate document mutation rows are valid only while the Form Session is `OPEN` **and `expires_at > transaction_now`**; NEW_SUBMISSION permits staged `ADD` only; reservation/session/type identity must match; one reservation cannot back multiple staged mutations; one persisted logical document cannot have multiple simultaneous pending mutations in the same session.
- Before Candidate Submit/Save, `private.validate_candidate_form_document_plan()` must run under the locked Form Session and enforce: Form Session unexpired; every ADD/REPLACE reservation unexpired + `VALIDATED` + malware `CLEAN`; effective current file count ≤5; at least one effective current CV remains. Cleanup workers are housekeeping only and never define business validity.
- Document logical header fixes parent + document type; every version under a logical ID inherits the same parent/type.
- Privacy acknowledgement lưu theo `(submission_id, notice_version)` với các cột vật lý: `privacy_acknowledgement_id, submission_id, notice_version, acknowledged_at, source_code`. Không có các cột `candidate_id`, `submission_version_no`, `privacy_notice_version`.
- Submission status manual set is limited to NEW/READ. PROCESSED/DONE/CLOSED are derived by one authoritative recalculation function. Outcome của Application được tính duy nhất từ Current Round (highest `round_no` among access-active Interviews: HIRED => HIRED, REJECTED => REJECTED, otherwise IN_PROGRESS). Internal helper `recalculate_submission_status(uuid)` thu hồi execute của `PUBLIC, anon, authenticated`; chỉ cấp cho `postgres, service_role`.
- Tạo vòng tiếp theo yêu cầu round cuối cùng đang Active và có `report_status_code <> 'HIRED'`. Trạng thái lịch `CANCELLED` không chặn tạo vòng tiếp theo.
- Outcome-changing transactions lock parent Submission before recalculation.
- Schedule-resource transactions lock target Interview before reading participant set and acquiring Candidate/Room/Interviewer locks.
- Referenced master structural semantics are immutable; inactive historical references remain valid.
- Current Candidate profile cache, when used, is sourced only from latest submitted snapshot; editing an older Submission cannot overwrite it.


## invariants
- Durable Application identity `(submission_id, unit_id, department_team_id, position_id)` is globally unique across Active/Inactive history.
- Candidate Form Session always pins Privacy Notice; EDIT requires target Submission + base version; NEW requires neither.
- Published Privacy Notice content/hash/publish/effective fields are immutable; only `is_current` lifecycle pointer may change.
- Candidate current-profile cache refreshes from latest surviving Submission through one helper.
- All `resource_blocking` Interviews participate in conflict checks regardless of Current Round.
- Interviewer contextual access requires active parent Application as part of `access_active`.

## Current semantic invariants
- Candidate Form Session always pins non-null server-published Privacy Notice; EDIT additionally requires non-null base Submission version.
- Published/referenced Privacy Notice content/hash/published/effective metadata is immutable; new content uses a new version.
- Candidate current-profile cache equals latest surviving Submission by `submitted_at DESC, submission_id DESC`; repair helper is authoritative after latest edit/delete.
- Application durable identity is globally unique and immutable from creation, irrespective of interview history.
- Interviewer contextual access uses `access_active = application.is_active AND interview.is_active`; `resource_blocking` additionally requires non-CANCELLED scheduled interval, independent of Current Round.

## Additional invariants
- Candidate staged/HR Submission `REPLACE` or `DELETE` may target only a logical document with exactly one current version; stage-time and transaction Save-time both enforce it.
- Active Application owner must resolve to an Active HR/root; HR deactivation/role removal cannot strand Active Applications.
- Candidate inactive metadata matches current lifecycle state: Active => inactive fields null; Inactive => timestamp/actor present.
- Interview Report lifecycle is canonical: current = `is_active=true AND is_archived=false`; historical = `is_active=false AND is_archived=true`.
- Privacy/document SHA-256 values use 64 hexadecimal characters when present.
- Operational Email History stores deployment environment; deletion is contextual + classified + audited.


## Zero-UUID Team sentinel
The durable Application identity index uses `00000000-0000-0000-0000-000000000000` only as the SQL sentinel for a NULL `department_team_id`. `department_teams.department_team_id` has a DB CHECK that forbids this UUID as a real master key, so the expression index cannot collide with a legitimate Team row.

## Candidate Form Session lifecycle — v1.12 current contract
- Canonical persisted transitions: `OPEN → SUBMITTED | CANCELLED | EXPIRED`; terminal states never reopen.
- Stage/Save/Submit/Finalize use wall-clock expiry synchronously; stale `OPEN` rows past `expires_at` fail `FORM_SESSION_EXPIRED`.
- ADD/REPLACE reservations past `expires_at` fail `UPLOAD_RESERVATION_EXPIRED` even before cleanup persists `EXPIRED`.
- Lifecycle persistence updates `updated_at`; business mutation/terminal transition is auditable.


## Operational Participant invariant — v1.12
No trusted mutation may make an Interview resource-blocking unless `private.all_current_participants_selectable(interview_id)=true`. Dormant/CANCELLED/access-inactive Interviews may retain historical current Participant rows whose users later become inactive, but scheduling/uncancelling/reactivation must fail until HR removes/replaces them.

## Copy provenance invariant — v1.12
`private.is_structurally_empty_default_round()` is false for outgoing or incoming `copied_from_interview_id` provenance. Provenance nodes are business-used and protected from accidental raw FK-restricted hard-delete attempts.

## Interview upload reservation integrity — v1.16
- `upload_reservations.interview_id` references a real Interview and uses `ON DELETE RESTRICT`.
- Interview hard-delete must first durably snapshot every temp object into `storage_cleanup_queue`, then cancel/remove reservation rows; cleanup-capture failure blocks delete.
- `storage_cleanup_queue` intentionally stores snapshot IDs/paths without parent FK so the worker can complete cleanup after the business parent has been removed.
- No trusted single or bulk Interview delete may leave an orphan reservation or uncaptured temp object.
