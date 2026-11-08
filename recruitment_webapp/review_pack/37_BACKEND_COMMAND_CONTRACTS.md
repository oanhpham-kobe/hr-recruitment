# 37. Backend Command Contracts — v1.12

## 1. Hard architecture rules
Every UI mutation maps to one explicit trusted backend command. The browser must not orchestrate multi-write business mutations. Commands run through authenticated Server Action/API → transactional RPC/database command.

Each command defines actor, permission, writable DTO, preconditions, lock order, idempotency, side effects, audit, output and structured error codes.

Shared requirements:
- Candidate DTO and HR DTO are separate allowlists.
- PII search values are not placed in URLs.
- Any outcome-changing command must call authoritative Submission recalculation in the same transaction.
- Any schedule-resource mutation must lock the Interview row first, then acquire deterministic resource locks and re-check conflicts.

## 2. Core error codes
`UNAUTHENTICATED`, `FORBIDDEN`, `NOT_FOUND`, `INVALID_STATE`, `VALIDATION_ERROR`, `STALE_VERSION`, `FORM_SESSION_EXPIRED`, `UPLOAD_RESERVATION_EXPIRED`, `DUPLICATE_APPLICATION`, `APPLICATION_DURABLE_IDENTITY_IMMUTABLE`, `PRIVACY_NOTICE_UNAVAILABLE`, `SCHEDULE_CONFLICT_CANDIDATE`, `SCHEDULE_CONFLICT_INTERVIEWER`, `SCHEDULE_CONFLICT_ROOM`, `LATEST_ROUND_REQUIRED`, `ROOT_ADMIN_PROTECTED`, `IDENTITY_REBIND_FORBIDDEN`, `USER_INACTIVE`, `UPLOAD_LIMIT_EXCEEDED`, `UNSUPPORTED_FILE_TYPE`, `MALWARE_SCAN_REQUIRED`, `IDEMPOTENCY_REPLAY`, `INVALID_PERMISSION_DEPENDENCY`, `INTERNAL_ERROR`.

## 3. Candidate identity and first-login provisioning
### `provision_candidate_identity()`
Verified Candidate OTP session only. Normalize verified email → find by current `auth_user_id` → trusted fallback by verified email → create Candidate if absent → safe bind if unbound → block inactive Candidate → audit. Never create a duplicate Candidate solely because Supabase Auth user ID was recreated.

### `start_candidate_form_session(mode, submission_id?)`
Creates short-lived `candidate_form_session`. Server selects the single published Privacy Notice where `is_current=true AND effective_from<=now()` and pins its `notice_version` into `presented_privacy_notice_version`; if none is available, fail closed with `PRIVACY_NOTICE_UNAVAILABLE`. `NEW_SUBMISSION` has no Submission parent and `base_submission_version_no=NULL`. `EDIT_SUBMISSION` requires owner + Active Candidate + Submission `NEW`, stores non-null base Submission version. Session creation is audited and never trusts a client-supplied notice version.

### `cancel_candidate_form_session()`
Marks an `OPEN` unexpired session `CANCELLED` and schedules temp-object cleanup. No persisted Submission/file version is changed. `SUBMITTED`, `CANCELLED` and `EXPIRED` are terminal and cannot reopen.

### Candidate Form Session authoritative lifecycle
Canonical transitions are `OPEN → SUBMITTED`, `OPEN → CANCELLED`, `OPEN → EXPIRED` only. Candidate submit/save/cancel commands may move their own OPEN session to SUBMITTED/CANCELLED; the expiry worker may persist OPEN→EXPIRED for housekeeping. **Business validity never waits for the worker:** Stage, Save, Submit and Finalize synchronously require `status_code = OPEN AND expires_at > transaction_now`. Once wall-clock expiry has passed, the command returns `FORM_SESSION_EXPIRED` even if the row has not yet been marked EXPIRED. Expired/terminal sessions never reopen. Every persisted lifecycle transition updates `updated_at` and is audited.

Upload Reservations are subordinate to the Form Session. ADD/REPLACE Stage and Save/Submit/Finalize synchronously require the reservation to belong to the session and `expires_at > transaction_now`; finalization additionally requires `VALIDATED` + malware `CLEAN`. A wall-clock-expired reservation returns `UPLOAD_RESERVATION_EXPIRED` even if cleanup has not yet changed its status. Reservation expiry cannot extend the parent Form Session; cleanup may mark expired/cancelled reservations after business commands have already failed closed.

## 4. Candidate Submission commands
### `submit_candidate_submission(form_session_id, payload, privacy_notice_version, idempotency_key)`
Actor: Candidate. Preconditions: verified identity, active Candidate, unexpired `OPEN` NEW_SUBMISSION form session (`expires_at > transaction_now`), required CV pending/finalizable, max 5 files, all ADD reservations unexpired + `VALIDATED` + malware `CLEAN`.

Payload allowlist:
- `full_name` (min 1, max 200, trimmed, required)
- `phone` (max 32, normalized, required)
- `date_of_birth` (1900-01-01 .. TODAY, required)
- `gender` (`MALE` | `FEMALE`, required; no OTHER in Phase 1)
- `address` / `current_address` (max 500, trimmed, required)
- `education` (array of optional child rows: `period_text`, `qualification_id`, `major`, `institution`, `sort_order` 1-based; max 20 rows)
- Document upload reservations / staged operations.

Verified email (`email_snapshot`) derives exclusively from verified Auth identity and is immutable. The command rejects `candidate_notes`, `work_experiences`, and `activities`.

Transaction:
1. lock Candidate/form session and synchronously recheck `status=OPEN AND expires_at > transaction_now`;
2. **Strong-current privacy notice verification:** assert presented `privacy_notice_version` equals current effective published version (`is_current=true`). If notice version has changed since session open, reject with `PRIVACY_NOTICE_CHANGED`, preserving form session and draft for retry;
3. validate `CandidateSubmissionCreate` allowlist and bounds;
4. run the locked staged-document-plan validator (all ADD uploads VALIDATED+CLEAN, effective file count ≤5, effective current CV exists);
5. create Submission snapshot with canonical columns (`full_name, phone, date_of_birth, gender_code, current_address, email_snapshot`);
6. bind/finalize staged document changes into logical document headers + immutable versions. Staged ADD inserts a NEW `submission_document_logicals` header without requiring `UNIQUE(submission_id, document_type_id)`; sets `created_by_candidate_id = Candidate, created_by_app_user_id = NULL`; versions set `uploaded_by_candidate_id = Candidate, uploaded_by_app_user_id = NULL`;
7. create privacy acknowledgement in `privacy_acknowledgements(submission_id, notice_version, acknowledged_at, source_code)`;
8. update Candidate current profile because this becomes latest submitted snapshot;
9. enqueue HR notification;
10. mark form session SUBMITTED;
11. audit + commit.

No Submission row is pre-created merely by opening the form.

### `update_candidate_submission(form_session_id, payload, privacy_acknowledged, idempotency_key)`
Actor: Candidate owner. Re-check on Save: Candidate active, Form Session still `OPEN` and unexpired, Submission still `NEW`, expected version matches; every staged ADD/REPLACE reservation is also unexpired at transaction time.

Same payload allowlist as Submit. Candidate Edit **tuyệt đối không nhận, không sửa, không xóa và không ghi đè** các field/bảng con thuộc quyền HR: `other_info`, `hr_note`, `submission_work_experiences`, `submission_activities`. Dữ liệu HR-only này được bảo toàn nguyên vẹn sau update.

**Strong-current privacy notice verification:** The Form Session has server-pinned `presented_privacy_notice_version`; Save requires acknowledgement of that exact version. Transaction asserts that the effective published notice has not changed. If notice version changed, reject with `PRIVACY_NOTICE_CHANGED`, preserving draft.

Staged REPLACE/DELETE target an existing `logical_document_id`. Staged ADD inserts a new logical header. Any text or file-only successful Save touches Submission aggregate and increments `version_no` exactly once. Refresh Candidate current-profile cache when this Submission is latest. Enqueue exact-`submission_id` HR notification inside the same transaction before commit; audit + commit.

### `get_submission_detail(submission_id)` — Pure Read
Requires `submissions.view`. Pure data retrieval; **tuyệt đối không bao giờ làm thay đổi trạng thái từ NEW sang READ**. Passive server render, data fetch, prefetch, refresh danh sách hay background preview bắt buộc chỉ gọi hàm này.

### `open_submission(submission_id)` — Explicit Open Command
Explicit user-intent command invoked when HR explicitly opens a NEW submission from inbox. Requires `submissions.view`. If actor also has `submissions.status` and current status is `NEW`, atomically sets `READ`. If actor lacks `submissions.status`, execution is read-only without mutation.

### `update_submission_by_hr()`
`submissions.edit`; HR-specific DTO only. Candidate verified email/security identity is immutable. Candidate-owned fields are edited via dedicated correction command. After update, call `refresh_candidate_current_profile(candidate_id)` when the edited Submission is latest; older Submission edits do not alter Candidate cache.

### `correct_submission_candidate_fields_by_hr(submission_id, full_name, phone, date_of_birth, gender_code, current_address, expected_version, reason)`
Dedicated trusted correction action (Owner Decision G). Permission: `submissions.edit` (or Root implicit).
Allowed fields ONLY: `full_name`, `phone`, `date_of_birth`, `gender_code`, `current_address`.
Email is NOT editable through ordinary correction.
Requirements:
1. lock target Submission row `FOR UPDATE` and assert optimistic `expected_version`;
2. require at least one correction field provided (null means unpatched);
3. validate provided fields against canonical Candidate validation bounds;
4. update provided fields, bump `version_no`, record `updated_by_internal_user_id`;
5. refresh Candidate current profile cache if this Submission is latest;
6. record same-transaction Security Audit: changed FIELD NAMES, actor/entity/version metadata, optional reason (no full old/new PII dump);
7. rollback all changes if audit insert fails.

### `recover_candidate_email_identity(candidate_id, new_email, reason)`
Dedicated trusted action for Candidate email recovery (Owner Decision H).
Permission: `candidates.identity_manage` (Root Admin implicit; specific HR by explicit delegation only; NOT default HR).
Requirements:
1. target Candidate exists;
2. `new_email` normalized and unique across all Candidate accounts;
3. verified Auth identity update/rebind;
4. update Candidate login identity (`candidates.email`);
5. historical Submission `email_snapshot` remains unchanged (immutable history);
6. future Submissions use the new verified email;
7. revoke obsolete sessions/binding where supported;
8. sets transaction-local setting `recruitment.candidate_email_recovery_active = 'on'` to safely pass `private.protect_candidate_verified_email()` trigger while keeping ordinary updates strictly blocked with `CANDIDATE_VERIFIED_EMAIL_IMMUTABLE`;
9. mandatory same-transaction Security Audit.
### `set_submission_manual_status(candidate_id, status, expected_latest_submission_id, expected_version)`
Only the **deterministic latest Submission** of the Candidate may be manually changed. Backend locks Candidate, resolves latest Submission by `submitted_at DESC, submission_id DESC`, compares `expected_latest_submission_id` + optimistic version, then allows only `NEW`/`READ` when no active Application exists. **Neither `NEW` nor `READ` may be written manually while any active Application exists.** Historical child Submission status is read-only for the Phase-1 workflow and crafted exact-Submission requests cannot bypass this rule. Starter SQL must expose only a Candidate-level/latest-safe helper (or an equivalently guarded helper); an exact historical `submission_id` writer is forbidden. `PROCESSED`, `DONE`, `CLOSED` are system-derived only. Candidate Active/Inactive does not restrict internal HR manual NEW/READ; inactivity affects Candidate Portal access only. Bulk manual-status mutation is ALL_OR_NOTHING and uses the exact same latest-only eligibility rule.

### `recalculate_submission_status(submission_id)`
Internal authoritative status calculator. Mandatory parent `Submission FOR UPDATE` lock before evaluating Applications.

**Authoritative Application outcome resolver:** Application outcome derives solely from the Current Round (highest `round_no` among `access_active` Interviews for that Application):
- Current Round `report_status_code = HIRED` → `HIRED`
- Current Round `report_status_code = REJECTED` → `REJECTED`
- Otherwise → `IN_PROGRESS`.
Older active rounds never independently determine Application outcome.

Rules for Submission recalculation:
- No active Application → preserve existing manual `NEW/READ`;
- If coming from a derived state after the final Application is removed/inactivated → return `READ`;
- Any active Application effective Current Round outcome `HIRED` → `DONE`;
- All active Applications effective Current Round outcome `REJECTED` → `CLOSED`;
- Otherwise with active Application → `PROCESSED`.

**Helper security:** `public.recalculate_submission_status(uuid)` is an INTERNAL helper. Execute permission is revoked from `PUBLIC, anon, authenticated` and granted only to `postgres, service_role`. Trusted SECURITY DEFINER business commands execute it under their definer context.

### Submission delete reachability + `delete_unused_candidate()`
**Normal production HR does not hard-delete a successfully submitted Submission.** Candidate Submit/Update mandatorily creates retained PRODUCTION email trace bound to the exact `submission_id`; that trace is downstream business history, therefore every normal production submitted Submission is retention-managed rather than eligible for a Phase-1 HR hard-delete command. `delete_unused_submission` is classified **MAINTENANCE_ONLY** for test/import/data-repair states that never acquired retained production business usage; it is not exposed in normal HR UI/permissions. Retained PRODUCTION email usage still **blocks `delete_unused_submission()`** even in that maintenance path.

`delete_unused_candidate()` remains Phase-1 HR behavior only for a truly unused Candidate. It locks the Candidate, discovers OPEN Form Sessions/temp reservations (including a never-submitted form), durably captures Storage cleanup paths, cancels sessions/reservations, then deletes only when no submitted/business usage exists. If durable cleanup capture cannot commit, deletion fails. Exact production permission is `candidates.delete_unused`; Root maintenance is separate. Used records are Inactive/retention-managed; Security Audit is immutable.

## 5. Applications
### `create_or_update_application()`
Input identifies one specific `submission_id`; backend never guesses latest Submission. Durable Application identity is globally unique by `(submission_id, unit_id, department_team_id, position_id)`. Exact duplicate active or inactive resolves to the same row: active duplicate requires confirmation/update; inactive duplicate uses Reactivate rather than creating a second identity. Locks parent Submission; validates hierarchy/owner; creates Application + empty Round 1 only when identity does not exist; recalculates Submission.

### `reactivate_application()`
Supported Phase 1. Expected version; referenced masters may be inactive historically but durable identity remains valid. Lock parent Submission/Application and require an eligible Active HR/root owner (or atomically reassign one). Enumerate only non-elapsed child Interviews that would become `reactivation_conflict_relevant = resource_blocking AND end_at > transaction_now` at transaction time; for each, require every current Participant user active **before** running shared conflict locking/re-check. A fully elapsed interval (`end_at <= transaction_now`) remains historical and **does not block lifecycle reactivation**. Any still-relevant Candidate/Room/Interviewer conflict blocks reactivation atomically. Then enable Application, restore `access_active` context for active children, recalculate Submission and audit. Current Round only selects report/outcome; it does not limit future/current resource conflicts.

### `delete_or_inactivate_application()`
Empty auto-created Round 1 is an owned default child and does not count as business history. If truly unused, delete that Round and Application atomically. Otherwise Inactive. Inactivation makes all child Interviews `access_active=false` without erasing history. Recalculate Submission.

## 6. Interview rounds, Copy and schedule
### `create_next_interview_round()`
Lock Application + latest Interview.

**Gate (Owner Decision A):**
1. Latest relevant existing Interview must be active (`is_active=true`).
2. Latest relevant active Interview `report_status_code <> 'HIRED'`. If `HIRED`, new round creation is terminal and rejected.
3. Schedule Status `CANCELLED` **does NOT block** creating the next round.
Allocate `max(round_no)+1`; Demo Topic blank; idempotent. Recalculate parent Submission if current-round semantics change.

### `reschedule_confirmed_interview(interview_id, start_at, end_at, interview_format_id, room_id, meeting_link, expected_version, idempotency_key)`
Dedicated trusted action (Owner Decision J). Permission: `interviews.manage`.
Target Interview must currently have `schedule_status_code = 'CONFIRMED'`.
Atomic transaction:
1. lock target Interview row, verify `CONFIRMED` status and `expected_version`;
2. revalidate every current Participant is an Active Internal User;
3. acquire deterministic Candidate/Room/Interviewer resource locks;
4. re-check `[start_at, end_at)` schedule conflicts;
5. update schedule time, format, room/link and set `schedule_status_code = 'AWAITING'`;
6. record Security Audit;
7. on any validation, conflict, or audit failure, rollback all changes: original schedule and `CONFIRMED` status remain intact.
### `copy_interview_schedule()` — dedicated trusted Save-Copy command
The Copy UI may create a client-side draft/prefill, but that draft performs **no DB mutation**. Pressing **Save Copy** invokes exactly this trusted command; no generic “normal save command” may infer Copy semantics.

Input identifies the source `interview_id`, exact target `application_id`, expected source/target versions, copied schedule/logistics draft, selected current Participants and an idempotency key. The command locks the target Application and relevant latest/target Interview rows before choosing the target Round.

Atomic target rule:
- same Application → create/fill the next legal round under the normal round-allocation rule;
- different Application → if `private.is_structurally_empty_default_round(target_round1_id)` returns true, fill that exact default Round 1; otherwise create the next legal round. Copy/delete flows share this exact predicate.

Before commit, the command revalidates every selected/current Participant is an Active Internal User, applies the shared deterministic Candidate/Room/Interviewer resource-lock + `[start,end)` conflict framework, writes `copied_from_interview_id`, preserves copied schedule/logistics, keeps Demo Topic blank for a newly-created target Round, recalculates affected Submission status when current-round semantics change, audits, and commits atomically. Retry with the same idempotency key must not create a second Round.

**Copy provenance counts as business usage.** `private.is_structurally_empty_default_round()` returns false when the Round has `copied_from_interview_id` or when any other Interview references it through `copied_from_interview_id`. Delete/copy flows therefore never attempt a raw FK-restricted delete of a provenance node.

### Shared Interview mutation lock order
Used by reschedule, add/re-add participant on a scheduled Interview, reactivate, CANCELLED→operational, format/room/time change:
1. lock target Interview row;
2. resolve effective parent Application/Candidate;
3. snapshot current room + current participant set;
4. **revalidate every current Participant maps to an existing `app_user` with `is_active=true`; otherwise fail `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED`;**
5. acquire deterministic transaction resource locks for Candidate, Room and Interviewers;
6. re-read participant/resource set; if changed, recompute locks/retry command and repeat participant-eligibility validation;
7. re-check `[start_at,end_at)` Candidate/Room/Interviewer conflicts;
8. apply mutation;
9. audit;
10. commit.

### `save_interview_schedule()`
Validates time, format metadata and normalized room/link. Before a first schedule/reschedule can leave the Interview resource-blocking, `validate_current_participants_operationally_eligible(interview_id)` must PASS. Candidate, Room, Interviewer conflicts are blocking. Adjacent intervals where end=start do not overlap.

### `change_interview_schedule_status()`
Flexible order. `CANCELLED → operational` first revalidates all current Participants active, then runs the shared Candidate/Room/Interviewer conflict framework. Historical inactive Interview Format does not block lifecycle changes when the same format remains referenced.

### `reactivate_interview()`
Latest applicable round only; Application must be active; expected version; revalidate all current Participants active before operationalization; shared conflict framework; no middle-round reactivation when later active round exists.

### `delete_or_inactivate_interview()`
Latest round only. Empty/unused → hard delete; used → inactive. No renumber. Before any Interview hard-delete, lock the Interview and its `upload_reservations`; for every reservation/temp object, snapshot `temp_bucket/temp_path` into `storage_cleanup_queue` durably, mark/cancel the reservation as appropriate, then remove the reservation row so the `ON DELETE RESTRICT` parent FK can pass. **Cleanup-capture failure aborts hard-delete.** A trusted delete must never rely on FK cascade to silently discard reservation metadata while a temp object may still exist. Recalculate parent Submission when current/effective outcome changes.

## 7. Interview format normalization
When changing format, command reads master metadata. If `requires_room=false`, clear `room_id`; if `requires_meeting_link=false`, clear `meeting_link`. HYBRID may keep both when metadata requires both. Inactive format is not selectable for a new/change operation but remains valid for historical Interviews already using it.

## 8. Participants
All participant mutations lock Interview row first.

### `add_interview_participant()`
Active user, no duplicate, snapshot current Directory identity. If schedule is operational, shared conflict framework includes the new Interviewer before insert.

### `remove_interview_participant()`
Warn if report exists. Mark participant not current/archive report per history policy. Reorder remaining participants atomically.

### `readd_interview_participant()`
Ask `RESTORE_OLD_REPORT` or `CREATE_NEW_REPORT`. Lock Interview, verify no current duplicate, and re-check conflict if Interview is `resource_blocking`.
- `RESTORE_OLD_REPORT`: selected historical Participant → `is_current=true`, `removed_at=NULL`, deterministic order, version bump; its Report → `is_active=true`, `is_archived=false`, preserve content and original `decision_updated_at/by`, version bump; audit `RESTORE_PARTICIPANT_REPORT`.
- `CREATE_NEW_REPORT`: old Participant/report stay historical/archived; create new Participant snapshot from current Directory identity and new empty report lifecycle.
Both paths are atomic.

### `reorder_interview_participants()`
Input complete current list; expected versions; temporary ordering strategy prevents unique collisions.

## 9. Reports
### `save_interviewer_report()`
No scoring. Field-aware patch:
- Request passes `expected_version_no` and `base_values` for each patched field;
- Server locks report row and compares current DB value with `base_values`:
  - `current == base`: safe field patch;
  - `current != base`: same-field conflict. HR stale conflict rejects with `STALE_VERSION`; Interviewer editing own report resolves with owner-wins. Disjoint fields merge cleanly.
- Only actual changes to the 3 Final Decision fields update `decision_updated_at/by`; qualitative edits never move Final Decision Source.
- **Blank conclusion allowed (Owner Decision F):** HR may set `HIRED` or `REJECTED` even when Conclusion, Expected Job, and Expected Recruitment Time are blank. No Conclusion-required invariant.
### `update_hr_report_note(interview_id, hr_report_note, expected_version)`
Requires `reports.view + reports.manage_status`. Edits **only** HR-only `hr_report_note`; it never changes `report_status_code`, Application `hr_owner_id`, or `interview_note`. Optimistic versioning + audit are mandatory. `hr_report_note` remains excluded from every Interviewer-readable projection.

### `delete_or_inactivate_report(report_id)`
Report-specific action only. The aggregate HR Report drawer does not expose an ambiguous top-level Delete. Used/historical report inactivation must enter canonical archived state `is_active=false, is_archived=true`; restored/current state is `is_active=true, is_archived=false`. No third boolean combination is legal. Interview Session deletion belongs to Interview module.

## 10. Documents / Storage
### `reserve_candidate_form_upload(form_session_id)` / `reserve_interview_upload(interview_id)`
Create short-lived temp/quarantine reservation. Validate requested type/scope and max intent. Candidate form upload does not require a Submission ID. Interview reservation must reference an existing Interview through a physical FK; nonexistent `interview_id` is rejected.

### `validate_staged_upload()`
Validate extension + declared MIME + detected MIME/magic bytes + size ≤5 MB; run malware scanning. Images strip EXIF/geolocation metadata where practical. A file is not finalizable unless scan is `CLEAN`.

### `stage_candidate_document_change()`
Records ADD/REPLACE/DELETE against an unexpired `OPEN` form session; synchronous stage validation requires `expires_at > transaction_now` for the Form Session and, for ADD/REPLACE, the Upload Reservation; no current persisted document is altered until Save/Submit. NEW_SUBMISSION accepts ADD only. Reservation/session/type identity must match, and DB guards prevent one reservation or one target logical document from being staged ambiguously more than once. **REPLACE/DELETE require the target logical document to have exactly one current version at stage-time.** Save/Submit locks the logical header + current version and re-checks the same invariant; a target that became historical/stale is rejected with `INVALID_DOCUMENT_TARGET` and can never be silently resurrected.

### `finalize_interview_upload()`
Locks Interview/document logical header; validates scope/count/scan; creates immutable version/current switch.

### `cleanup_abandoned_uploads()`
Scheduled worker removes expired/cancelled temp objects and stale reservations; never deletes current logical document versions.

Approved formats remain PDF, DOC/DOCX, PPT/PPTX, PNG, JPG/JPEG; malware scanning is a production go-live requirement because external legacy Office formats are allowed.

## 11. Email
### `enqueue_email()` / `send_email()`
Phase 1 system-generated emails have **no attachments**. Recipients are derived/validated from entity + email type; arbitrary recipient override is not permitted for system flows unless an explicit privileged command exists. Business transaction inserts Outbox; worker sends after commit.

Semantics: at-least-once delivery with idempotent enqueue + best-effort deduplication. Outbox records deployment `environment_code`; worker-created Email History preserves that environment. Worker uses leased claim (`FOR UPDATE SKIP LOCKED` or equivalent), stale SENDING recovery, attempts and provider IDs. Acceptance criteria must not promise impossible exactly-once delivery.

## 12. Candidate lifecycle
`set_candidate_active()` preserves history. Inactive blocks Candidate Portal only; internal recruitment may continue.
- `active=false`: set `inactive_at=now()` and `inactive_by=actor` atomically.
- `active=true`: clear `inactive_at/inactive_by`, then evaluate all Submissions. If a Submission has no active Application, explicitly set it to `READ`; otherwise derive `PROCESSED/DONE/CLOSED` from actual Applications.
Generic recalculation outside this lifecycle action may still preserve manual `NEW/READ` when no Application exists. Immutable Security Audit is the historical record of every inactive/reactivate event.

## 13. Internal Users / RBAC
### `create_internal_user()`
Directory manager may create approved EIU directory row.

### `provision_internal_identity_on_first_google_login()`
Verified Google provider + verified normalized `@eiu.edu.vn` email + active allowlisted `app_users` row + `auth_user_id IS NULL` + no conflicting binding → atomic bind + audit. If row already bound to a different Auth ID, reject; never auto-rebind.

### `assign_hr_role_with_defaults()`
Root only. Adds HR role and Full HR Permission Set. Permission prerequisites are included automatically.

### `remove_hr_role()`
Root only. Before role removal, server checks Active Applications owned by the target HR. If any exist, role removal is blocked with `ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED` unless those Applications are reassigned atomically to another eligible Active HR/root in the same trusted administrative operation. After the owner invariant is satisfied, remove HR role and revoke HR-default/custom HR permissions by Phase-1 default; historical inactive ownership/snapshots remain. Active sessions re-resolve effective authorization on the next request; security-sensitive UI refreshes immediately.

### `update_internal_user_directory()`
Directory business profile. Email typo correction only while Auth unbound. This command does not alter HR role, permissions, bound identity or Root status.

### `set_internal_user_active(target_user_id, active, expected_version)`
Actor with `users.directory_manage` may change Active state only for a **non-HR, non-Root** internal user. A target with HR role is Root-only; Root is protected; HR self-deactivation is not allowed through normal UI. Before any `active=true → false` transition, the trusted command locks the target User and blocks two stranding cases: **(1)** Active Application owner without atomic reassignment → `ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED`; **(2)** current Participant on any non-elapsed `resource_blocking` Interview without remove/replace/reassignment → `FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED`. The same participant guard applies regardless of HR/non-HR target authority; Root privilege does not bypass the business invariant. After guards pass, apply lifecycle change, force authorization/session re-evaluation on subsequent requests, and write immutable security audit.

### `change_internal_user_identity()`
Root-only for already-bound non-root users. Root Admin identity uses break-glass runbook only.

### Permission dependencies
Effective permission grants must enforce prerequisites: `*.edit/status/delete/email/manage` requires corresponding `*.view` where a view permission exists. Root UI auto-grants prerequisites or blocks invalid combinations. Backend command checks required read/context permission as well.

## 14. Master Data
`create_master_item`, `update_master_item`, `delete_or_inactivate_master_item` use optimistic versioning. Referenced master structural semantics are immutable: changing meaning requires a new row and Inactive old row. Typo/display-label corrections may be allowed with audit when they do not change business meaning. Inactive historical masters remain readable/operable but cannot be selected for new references.

Metadata with no hard Phase-1 effect is explicitly advisory/optional in `seed_master_data.json`; coding agents must not invent blocking behavior.

## 15. Bulk operations
Bulk behavior is command-specific, never inferred by the frontend:
- Bulk latest Submission manual status NEW/READ: all-or-nothing.
- Bulk common Application assignment: all-or-nothing.
- Bulk email: per-item result because delivery is asynchronous.
- Bulk delete/inactive/status: explicit contract must state atomic vs partial before the UI exposes it.

Batch responses expose `success[]` and `failed[{id,error_code}]` when partial semantics are chosen.

## 16. Background boundary
Critical audit, permission changes, status recalculation and invariants are inside business transactions. Email delivery, malware scan orchestration, orphan cleanup and non-critical telemetry run after commit through durable workers, while finalization waits for required security scan results.

## Explicit trusted-command contracts
The following commands close remaining UI → command gaps. Each is a trusted server/RPC command; direct browser table mutation is not an alternative.

### `mutate_submission_documents_by_hr(submission_id, expected_version, mutation_plan, idempotency_key)`
Requires `submissions.view + submissions.edit`. Locks Submission + affected logical-document headers + current versions. REPLACE/DELETE may target only a logical header with exactly one current version and re-check that target-current invariant inside the transaction. Validates document scope, approved type, 5 MB/file, max 5 effective current files, malware `CLEAN`, current CV invariant and logical-version invariants. Applies ADD/REPLACE/DELETE atomically, increments `Submission.version_no` exactly once even for file-only changes, audits and is idempotent.

### `delete_interview_document(interview_document_id, expected_version)`
Requires `interviews.view + interviews.documents`. Validates exact Interview context and document usage, deletes only under the existing Interview Document delete rule, durably schedules Storage object cleanup before metadata loss, and audits.

### `delete_email_history(email_history_id, cleanup_reason_code, reason_text)`
Requires `emails.history_view + emails.history_delete` **and parent contextual read permission** for the subject record (`submissions.view`, `interviews.view`, `reports.view`, or Application context through its Submission, according to `email_type`). RLS must hide history rows when that parent context is unavailable.

Deletion is machine-deterministic:
- `TEST_RECORD` is accepted only for a row created in `environment_code=TEST`;
- `WRONG_RECORD` is an explicit authorized human cleanup classification and requires non-empty `reason_text`.

Any other reason is rejected. Immutable Security Audit stores actor, parent context, classification and reason. Outbox/provider records are not silently rewritten.

### `update_application_hr_owner(application_id, hr_owner_id, expected_version)`
Requires `applications.manage`. HR owner is an Application concern, not a Report permission. Locks Application, validates target owner is Active HR/root, writes old/new owner audit and optimistic version update.

**Operational owner invariant:** every Active Application must have an eligible Active HR/root owner. `reactivate_application()` revalidates this invariant before enabling the Application. Root cannot deactivate an HR or remove the HR role while that user owns Active Applications unless those Applications are reassigned atomically to another eligible Active HR/root first. Historical Inactive Applications may retain an inactive former owner reference.


### `provision_candidate_identity()` — recreated Auth branch
When verified OTP email matches an existing Candidate but `auth_user_id` contains an obsolete/recreated Auth identity, command may replace old→new only under the Candidate-specific safe-rebind predicate: exact verified normalized email, Candidate row lock, no other Candidate uses new Auth ID, no contradictory identity state, security audit old/new. Internal User rebind rules are separate and remain privileged.

### `set_candidate_active(candidate_id, active, expected_version)` — reactivation mode
On `active=true`, evaluate all Submissions. If a Submission has no active Application, result is `READ`; otherwise derive `PROCESSED/DONE/CLOSED` from actual Applications. This lifecycle exception is authoritative for Candidate reactivation.

### `change_report_status(interview_id, status, expected_version)`
Requires `reports.view + reports.manage_status`. This is the **single trusted mutation path** for `interviews.report_status_code`. It may change Current Round Report Status only. Transaction locks Current Round + parent Application/Submission, validates permission/state/version, updates status, calls authoritative `recalculate_submission_status()` before commit, writes audit, then commits. It does not change `hr_report_note` or Application HR owner.

### `set_report_visibility(interview_id, visible, expected_version)`
Requires `reports.view + reports.visibility`; updates current Interview visibility with optimistic concurrency and audit.

### `bulk_create_or_update_applications(items[])`
Requires `applications.manage + submissions.view`; **ALL_OR_NOTHING** for common assignment operation. Every item names an exact Submission; no implicit latest selection.

### `bulk_enqueue_email(items[])`
Requires the corresponding email/context permission for each item. Per-item enqueue result; client/idempotency retry does not duplicate logical Outbox rows. Delivery remains at-least-once.

### `create_master_item(...)` / `update_master_item(...)` / `delete_or_inactivate_master_item(...)`
Require `master_data.manage`. Referenced structural semantics are immutable; unused may hard-delete, used becomes Inactive. Historical inactive values remain usable by existing records but cannot be newly selected.

### `grant_hr_permission(...)` / `revoke_hr_permission(...)`
Root-only. Enforce permission dependencies; security audit required.

### `root_admin_break_glass_recovery(...)`
Not a normal UI command. Runs only under `61_ROOT_ADMIN_BREAK_GLASS_RECOVERY.md` with approval, controlled migration/function, verification, immutable audit and rehearsal evidence.

### Interview hard-delete temp-upload cleanup ordering
`delete_or_inactivate_interview()` and its batch equivalent must lock Interview + related Upload Reservations, insert durable `storage_cleanup_queue` rows for every temp object, then cancel/remove reservations before hard-delete. `upload_reservations.interview_id` uses `ON DELETE RESTRICT`; raw/cascade deletion is forbidden. If cleanup intent cannot be committed, the Interview hard-delete fails.

### Hard-delete session/temp cleanup ordering
`delete_unused_candidate()` production flow must lock target, discover OPEN Candidate Form Sessions/temp reservations, durably enqueue Storage cleanup references, cancel sessions, then delete only a truly never-used Candidate. `delete_unused_submission` is MAINTENANCE_ONLY and may run only against non-production/import/test repair data with no retained business trace; it is not an HR production permission. If durable cleanup capture cannot commit, hard-delete fails.



## Canonical helpers and maintenance-only lifecycle
### `refresh_candidate_current_profile(candidate_id)`
Internal helper: lock Candidate; select latest surviving Submission by `submitted_at DESC, submission_id DESC`; set `current_full_name/current_phone/last_submission_at`, or clear them if no Submission remains. Called after new Submission, latest Candidate/HR edit, MAINTENANCE_ONLY Submission repair-delete, and repair/migration. A maintenance repair-delete refreshes Candidate current profile afterward.

### Internal User unused cleanup
Hard-delete Internal User is MAINTENANCE_ONLY / Root-operated, not an HR UI command. Eligible only if unbound (`auth_user_id IS NULL`), non-Root, no HR role/permissions and never referenced. Otherwise Inactive. Audit required.

### Privacy Notice publication
Published Privacy Notice content/locale/hash/published/effective fields are immutable; only `is_current` may change. New wording creates new `notice_version`. Publication/current switching is **maintenance/deployment-only in Phase 1**, not a Candidate/HR UI mutation, and follows `78_PRIVACY_NOTICE_PUBLICATION_RUNBOOK.md`. A future-effective notice is inserted with `is_current=false`; the current pointer is switched only at/after `effective_from` in one transaction so an existing effective current notice is never intentionally removed first. Starting Form Session fails `PRIVACY_NOTICE_UNAVAILABLE` if no current notice with `effective_from <= now()`.

## Candidate notification side-effect rule
Candidate Submit/Update HR notification is a system side effect inserted into Outbox in the same business transaction. Candidate endpoint abuse controls apply before the business command. Notification coalescing/throttling may delay or merge downstream delivery but **must not invalidate or roll back an otherwise valid Candidate Save** merely because an email-specific delivery quota is reached. The committed Outbox/event remains traceable to exact `submission_id`.


## Phase-1 named batch commands

All lifecycle/status batches below are **ALL_OR_NOTHING**. The server validates the full selected set, acquires deterministic locks, performs all writes/derived recalculations/audit in one transaction, or rolls back the entire batch. Browser-side loops over single-row commands are forbidden as the production contract.

### `bulk_set_candidate_active(candidate_ids, active, expected_versions[])`
Requires Candidate lifecycle permission for every selected Candidate. Selection entity = Candidate. Candidate lifecycle rules, inactive metadata, portal effects and per-Submission reactivation recalculation are identical to the single-Candidate command. Each Candidate receives per-item audit plus one batch audit event. Any stale/ineligible item aborts the whole batch; Internal-User owner/participant guards are not part of Candidate lifecycle.

### `bulk_set_latest_submission_manual_status(candidate_ids, status, expected_latest_submission_ids, expected_versions[])`
Requires Submission status permission for every selected Candidate. **Selection entity = Candidate**, matching the Application Inbox checkbox model. For each selected Candidate the server locks the Candidate, resolves deterministic latest Submission (`submitted_at DESC, submission_id DESC`), rechecks it against `expected_latest_submission_ids`, and rechecks optimistic versions. Only `NEW`/`READ` are legal manual targets. Any active Application on any resolved latest Submission rejects the **entire batch**. Candidate Active/Inactive does **not** change internal HR manual-status eligibility; the batch matches `set_submission_manual_status()` exactly. No historical child Submission may be mutated from this Candidate-level UX. This is the single batch writer for visible bulk Mark New/Read; browser loops and overlapping legacy Mark-New batch writers are forbidden.

### `bulk_delete_or_inactivate_interviews(interview_ids, expected_versions[])`
Requires Interview manage/delete rights for every selected Interview. Applies the same current/highest-round, meaningful-history, document/email/report/participant, Interview upload-reservation cleanup and parent-Submission recalculation rules as the single command. Every hard-delete target must durably capture temp-object cleanup before any Interview is deleted. Any item that cannot take the requested lifecycle action aborts the whole batch; no reservation/object cleanup is left orphaned.

### `bulk_change_interview_schedule_status(interview_ids, target_status, expected_versions[])`
Requires `interviews.status` + prerequisite `interviews.view` for every selected Interview. For every selected Interview whose transition would make it `resource_blocking`, the transaction locks the Interview, validates every current Participant resolves to an Active Internal User, acquires Candidate/Room/Interviewer resource locks, re-reads the Participant/resource snapshot, repeats eligibility when the set changed, then runs the same deterministic Candidate/Room/Interviewer conflict engine as the single writer. Stable inactive-participant failure is `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED`. **ALL_OR_NOTHING:** one invalid transition, inactive current Participant or resource conflict aborts the entire selected batch; no Interview changes.

### `bulk_change_report_status(interview_ids, target_report_status, expected_versions[])`
Requires Report status permission for every selected Current Round. `change_report_status()` semantics remain the only underlying writer for `report_status_code`; the batch command applies that writer atomically to the selected set and recalculates every affected parent Submission before commit.


### Internal User lifecycle guard for future/current Interview participation
Normal Internal User deactivation is blocked when the target user is a current Participant on any non-elapsed `resource_blocking` Interview. The stable business error is `FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED`; HR/Root must remove/replace the Participant first. Historical removed participation remains readable. Re-add requires `app_user.is_active = true` and otherwise returns `USER_INACTIVE_NOT_SELECTABLE`.


### Submission hard-delete and retained production-email trace
For Phase 1, retained **PRODUCTION** Email Outbox/Email History usage is downstream business history and **makes normal production Submission hard-delete ineligible; `delete_unused_submission` is MAINTENANCE_ONLY**. This preserves the exact `submission_id` relational trace. TEST/WRONG operational email history may be removed only through its dedicated cleanup rules; immutable Security Audit remains. Therefore the maintenance-only delete path must reject a Submission referenced by retained production email records rather than relying on `ON DELETE SET NULL`.


Plain contract summary: retained PRODUCTION email usage is downstream history and makes normal production Submission hard-delete ineligible; `delete_unused_submission` is MAINTENANCE_ONLY.

## Stable Command Error Codes
All backend commands, TypeScript adapters, and RPCs use this canonical stable error-code registry:

| Error Code | Category / Meaning |
|---|---|
| `UNAUTHENTICATED` | Caller is not authenticated |
| `FORBIDDEN` | Caller lacks required permission or authorization |
| `NOT_FOUND` | Target entity not found |
| `INVALID_STATE` | Operation illegal in target entity's current status |
| `VALIDATION_ERROR` | Request payload fails validation contract or bounds |
| `STALE_VERSION` | Optimistic concurrency conflict / version mismatch |
| `FORM_SESSION_EXPIRED` | Candidate Form Session expired |
| `UPLOAD_RESERVATION_EXPIRED` | Upload reservation expired |
| `DUPLICATE_APPLICATION` | Exact duplicate Application assignment |
| `APPLICATION_DURABLE_IDENTITY_IMMUTABLE` | Attempt to mutate immutable Application identity |
| `PRIVACY_NOTICE_UNAVAILABLE` | No current effective privacy notice published |
| `PRIVACY_NOTICE_CHANGED` | Privacy notice changed between session open and submit/update |
| `SCHEDULE_CONFLICT_CANDIDATE` | Candidate has overlapping operational schedule |
| `SCHEDULE_CONFLICT_INTERVIEWER` | Interviewer has overlapping operational schedule |
| `SCHEDULE_CONFLICT_ROOM` | Room has overlapping operational schedule |
| `LATEST_ROUND_REQUIRED` | Operation permitted only on latest Interview round |
| `ROOT_ADMIN_PROTECTED` | Root Admin account identity protected |
| `IDENTITY_REBIND_FORBIDDEN` | Identity rebinding not authorized |
| `USER_INACTIVE` | Caller or target user account is inactive |
| `UPLOAD_LIMIT_EXCEEDED` | File size or count limit exceeded |
| `UNSUPPORTED_FILE_TYPE` | File extension/type not permitted |
| `MALWARE_SCAN_REQUIRED` | File has not passed malware scan |
| `IDEMPOTENCY_REPLAY` | Idempotent command replay |
| `INVALID_PERMISSION_DEPENDENCY` | Permission prerequisite violated |
| `INACTIVE_DOCUMENT_TYPE` | Document type is inactive in master data |
| `INVALID_DOCUMENT_TYPE` | Unknown document type |
| `INVALID_FILE_TYPE` | Declared file type invalid |
| `FILE_SIZE_EXCEEDED` | File exceeds maximum allowed size (5 MB) |
| `INVALID_ACTION` | Action code or transition not permitted |
| `INVALID_CONTENT_SIGNATURE` | File magic bytes do not match declared type |
| `INVALID_MIME_TYPE` | MIME type not allowed |
| `INVALID_DOCUMENT_TARGET` | Staged document target logical document invalid |
| `UPLOAD_RESERVATION_NOT_CLEAN` | Upload reservation not in clean/validated state |
| `MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED` | Total current files exceeds maximum of 5 |
| `REQUIRED_CV_DOCUMENT_MISSING` | Mandatory CV/Resume missing from document plan |
| `HISTORICAL_SUBMISSION_READ_ONLY` | Historical Submission status cannot be mutated |
| `ALREADY_EXISTS_INACTIVE` | Target entity already exists in inactive state |
| `INVALID_HIERARCHY` | Unit, Team, and Position hierarchy mismatch |
| `INTERNAL_ERROR` | Unexpected server or database exception |
| `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED` | Participant is inactive and must be reassigned before scheduling |
| `INACTIVE_QUALIFICATION_NOT_SELECTABLE` | Selected qualification level is inactive |
| `ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED` | Cannot inactivate HR user or remove HR role while user owns active Applications |
| `FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED` | Cannot inactivate user while user is current participant on future operational interview |
| `USER_INACTIVE_NOT_SELECTABLE` | Inactive internal user cannot be re-added as active participant |

## CR-INTERVIEW-FEEDBACK-20261105 — additive local-first commands

The complete feature contract is `101_INTERNAL_INTERVIEW_FEEDBACK.md`; the legacy
commands and report/outcome rules above retain their existing semantics.

| Command | Authority | Transaction |
|---|---|---|
| `publish_interview_feedback_template` | `interviews.manage` AND `reports.view`, or Root | Publish a new immutable plain-text questionnaire version; actor-scoped idempotency and audit |
| `create_interview_feedback_collection` | Same HR authority | Exact current round/selected participants; one collection, invitations and provider-paused notification intents atomically |
| `save_interview_feedback_response` | Active bound exact invitation owner/current participant | Optimistic draft/submit, required-answer validation, deadline/context check, immutable submission and safe identical retry |
| `revoke_interview_feedback_invitation` | Same HR authority | Versioned outstanding-only revocation; keep original evaluator denominator |
| `save_interview_feedback_consolidation` | Same HR authority | Complete original evaluator set; pinned attributed snapshot, versioned title/summary draft and immutable approval |

All mutations recheck authorization after the shared lifecycle locks. New reads
`get_interview_feedback_workspace`, `get_interview_feedback_collection`, and
`get_interview_feedback_invitation` return explicit allowlisted projections.
The invitation endpoint always returns OWN mode, including for HR participants.
Private feature tables have no raw authenticated access. Notification intent
persistence is not email delivery. Browser printing is not an official PDF export.

Additional stable errors: `CONTEXT_NOT_WRITABLE`, `DEADLINE_PASSED`,
`REQUIRED_ANSWER_MISSING`, `ALREADY_SUBMITTED`, `INVITATION_REVOKED`,
`COMPLETENESS_REQUIRED`, `ALREADY_APPROVED`; existing auth/validation/version
errors remain applicable. No private backend exception text is shown in the UI.

## CR-DRIVE-FILES-HOSTED-20261105

`102_PRIVATE_DRIVE_DOCUMENT_STORAGE.md` governs `bind_candidate_drive_object`,
`claim_drive_upload_attempt`, `seal_drive_upload_attempt`,
`resolve_drive_object_location`, `resolve_drive_cleanup_location`,
`resolve_drive_scan_attempt` and `authorize_drive_document_read`.
Only narrow worker roles execute these operations; they do not replace user
context authorization, real malware scanning or the existing cleanup fence.

Provider claim routing uses `claim_drive_document_scan_requests` and
`claim_drive_storage_cleanup_jobs` for bound Drive objects; original claim RPCs
retain their signatures and select legacy Supabase work only. Filtering happens
inside the database before locking/limiting and exhausted-cleanup selection.
