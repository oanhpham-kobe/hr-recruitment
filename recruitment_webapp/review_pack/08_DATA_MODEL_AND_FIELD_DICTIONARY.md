# 08. Data Model & Field Ownership — v1.8

Business entity ownership remains based on Business Logic Core v1.2. Current v1.8 incorporates the accumulated schema-conformance amendments from prior external reviews.

## 1. Candidate
Physical fields:
- `candidate_id`
- `auth_user_id` — verified Supabase Auth identity
- `email` — verified, immutable as normal profile field
- `current_full_name` / `current_phone`
- `last_submission_at`
- `is_active`
- `inactive_at` / `inactive_by`
- `created_at` / `updated_at` / `version_no`

Rules:
- first verified OTP login provisions/finds Candidate atomically;
- fallback by verified normalized email is allowed only inside the trusted provisioning command to reconnect a recreated Auth identity without duplicating Candidate;
- inactive Candidate cannot access Portal but internal recruitment history/process remains.

## 2. Submission
One form submission snapshot:
- `submission_id`, `candidate_id`
- `status_code`
- `full_name`, `date_of_birth`, `gender_code`, `current_address`, `phone`, `email_snapshot`, `other_info`
- `hr_note`
- `submitted_at`, `created_at`, `updated_at`
- `updated_by_internal_user_id`, `updated_by_candidate_id`
- `version_no`

Invariant: `email_snapshot = Candidate.email` at creation/update of identity snapshot.

Candidate-owned mutable fields in Candidate Submit/Edit:
- `full_name` (min 1, max 200, trimmed)
- `phone` (max 32, normalized)
- `date_of_birth` (1900-01-01 .. TODAY)
- `gender_code` (`MALE` | `FEMALE`)
- `current_address` (max 500)
- Education child rows: `period_text` (<=100), `qualification_id` (active FK), `major` (<=255), `institution` (<=255), `sort_order` (1-based 1..n). Optional.
- Candidate documents.

Verified email (`email_snapshot`) derives from Auth and is immutable for the Candidate.

HR-only fields: `other_info`, `hr_note`, `submission_work_experiences`, `submission_activities`. Candidate Submit/Edit **tuyệt đối không nhận, không sửa, không xóa và không ghi đè** các field/bảng con này.

Children: Education, Working Experiences (HR-only), Activities (HR-only), Documents, Privacy Acknowledgement.

### Privacy Acknowledgement
Physical identity: `(submission_id, notice_version)`.
Physical columns:
- `privacy_acknowledgement_id` (PK, UUID)
- `submission_id` (FK to submissions)
- `notice_version` (text)
- `acknowledged_at` (timestamptz)
- `source_code` (text, e.g. `'CANDIDATE_PORTAL'`)
Không có các cột `candidate_id`, `submission_version_no`, hay `privacy_notice_version`.
## 3. Submission Documents
### Submission Document Logical Header
Stable business identity for one document across immutable versions:
- `logical_document_id`
- `submission_id`
- `document_type_id`
- creator metadata

The logical header owns **parent Submission + document type**. Those semantic fields are immutable once created.

**Non-unique document type invariant:** `submission_document_logicals(submission_id, document_type_id)` **KHÔNG PHẢI là unique key**. Một Submission có thể có nhiều logical document cùng `document_type_id` (ví dụ 2 file CERTIFICATE) miễn là tổng số file hiện hành thỏa mãn giới hạn `max 5 files`. Staged `ADD` luôn tạo một logical document header mới; staged `REPLACE` và `DELETE` bắt buộc trỏ tới một `logical_document_id` cụ thể đã tồn tại.

Metadata creator / uploader tuân thủ XOR:
- Logical header do Candidate tạo: `created_by_candidate_id = Candidate`, `created_by_app_user_id = NULL`.
- Document version do Candidate upload: `uploaded_by_candidate_id = Candidate`, `uploaded_by_app_user_id = NULL`.
### Submission Document Version
Immutable storage/version record:
- `document_id`
- `logical_document_id`
- `version_no > 0`, `is_current`
- `storage_bucket`, `storage_path`, `original_filename`
- `mime_type`, `file_size_bytes`, `checksum_sha256`
- uploader identity + `uploaded_at`

A version row does **not** duplicate `submission_id` or `document_type_id`; those derive through the logical header.

Constraints:
- unique `(logical_document_id, version_no)`;
- unique current row per `logical_document_id`;
- unique `(storage_bucket, storage_path)`;
- `REPLACE`/`DELETE` may target only a logical header that has exactly one current version at both stage-time and Save-time;
- max 5 current logical files per Submission; max 5 MB/file; formats limited to approved PDF/Word/PPT/PNG/JPEG whitelist.

Candidate form requiredness is frozen: **CV required; Degree/Transcript/Certificate/Other optional**.

## 4. Application
Identity:
- `application_id`
- `submission_id`
- `unit_id`
- optional `department_team_id`
- `position_id`
- `hr_owner_id`
- `is_active`
- timestamps + `updated_by` + `version_no`

`candidate_id` is not duplicated; Candidate derives through Submission.

Hierarchy invariant is null-safe:
- Application Unit = Position Unit;
- Application Team **IS NOT DISTINCT FROM** Position Team, including NULL;
- Team, when non-null, belongs to Unit.

One Submission may have multiple Applications for different assignments. The durable identity `(submission_id, unit_id, department_team_id, position_id)` is globally unique across active/inactive history. Exact same assignment resolves the same Application ID: active row may be updated after duplicate confirmation; inactive row is Reactivated. Identity fields are immutable from creation.

## 5. Interview Session
Each round owns:
- `interview_id`, `application_id`, `round_no`
- `demo_topic`
- `start_at`, `end_at`
- `interview_format_id`, `room_id`, `meeting_link`
- `schedule_status_code`, `report_status_code`
- `interview_note` — Interview operational note
- `hr_report_note` — HR-only report-management note
- `visible_to_interviewers`
- `copied_from_interview_id`
- `is_active`
- timestamps + `updated_by` + `version_no`

`access_active = Application.is_active AND Interview.is_active` is the canonical contextual-access base. `current_round` is the highest round among access-active Interviews and is used for current report/outcome/PDF. `resource_blocking = access_active AND non-CANCELLED AND scheduled interval exists` is the conflict predicate and applies to every matching round, independent of Current Round. Candidate inactive does **not** turn internal Interview history/process off.

## 6. Interview Participant
- `interview_participant_id`, `interview_id`, `app_user_id`
- `participant_order > 0`
- snapshot Name/Job Title/Email
- `is_current`, `created_at`, `updated_at`, `removed_at`, `version_no`

Current participants are unique by user and by order inside an Interview. Add/re-add/reorder lock the Interview and re-run schedule conflict checks when the resulting participant becomes active.

## 7. Interview Report
Belongs directly to `interview_participant_id`.

Fields:
- 5 qualitative fields;
- 3 final-decision fields;
- `decision_updated_at`, `decision_updated_by`;
- `is_active`, `is_archived` — canonical lifecycle only: current `(true,false)` or historical archived `(false,true)`;
- `created_at`, `created_by`, `updated_at`, `updated_by`, `version_no`.

No scoring/rating exists.

### Final Decision
The panel discusses and normally one representative fills the final block. Other Interviewers are not required to fill it.

Only changes to Conclusion / Expected Specific Job Assigned / Expected Recruitment Time update decision metadata. Qualitative edits do not move the Final Decision Source. Current source is the eligible report in Current Round with latest `decision_updated_at`; all three final fields come from the same report.

## 8. Internal User & identity
`app_users` contains directory/business profile + Auth binding.

- HR `users.directory_manage` may correct email while `auth_user_id IS NULL`.
- once bound, email/Auth binding is security identity; rebinding is Root-only in Phase 1 (`users.identity_manage`).
- Root Admin identity cannot be changed by ordinary directory/security command; use recovery procedure.
- newly assigned HR receives Full HR Permission Set by default; Root may revoke individual HR permissions.

## 9. Master Data — physical Phase 1
Physical lookup entities exist for:
- Khoa/Phòng; Ngành/Tổ; Position; Position Group;
- Qualification;
- Interview Format including `requires_room` / `requires_meeting_link`;
- Room; Recruitment Source; Document Type;
- Cancellation Reason; Rejection Reason;
- Permission catalog.

Referenced master data is Inactive rather than hard-deleted.

## 10. Email delivery
`email_outbox` is operational delivery queue with lock/lease fields, attempts, provider ID and idempotency key. Semantics: **at-least-once delivery with idempotent enqueue and best-effort/provider-assisted deduplication**, not guaranteed exactly-once.

User-facing `email_history` may be deleted under the frozen business rule, while immutable security audit preserves the delete/send event.

## 11. Privacy acknowledgement
Technical capability records `notice_version`, acknowledgement timestamp, Submission and source. Legal wording/policy remains EIU-owned.

## 12. Upload reservation/finalization
Object Storage and PostgreSQL do not share one transaction. Upload follows reserve → temporary/quarantine object → validate → finalize metadata/current version → retire previous version → cleanup orphan flow.

## 13. Audit
Activity/audit includes actor, action, entity, request/correlation IDs, source/reason, diff and timestamp. No secrets/tokens. Security audit is immutable.

## 14. Derived views
Implementation views remain private by default and use access-active semantics. If exposed, `security_invoker`, explicit GRANT and adversarial RLS tests are mandatory.

## 15. Field classification
Each field is classified in `54_SCHEMA_CONFORMANCE_MATRIX.md` as PHYSICAL / DERIVED / SNAPSHOT / CONFIG / DEFERRED. That matrix is the conformance bridge between this dictionary and `database_schema.sql`.
