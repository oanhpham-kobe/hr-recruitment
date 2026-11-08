# 13. Acceptance Criteria — Business Core v1.2 + Technical Architecture v1.18

Business rules remain frozen except the explicitly accepted Final Decision timestamp correction. Technical architecture remains under Technical Closure Gate.

## A. Candidate / Auth

**AC-01 Verified email** — Candidate email comes from verified Auth identity and is not editable through Candidate/HR profile UI.

**AC-02 New Submission** — Each submit creates a new Submission snapshot.

**AC-03 Candidate inactive** — Candidate Inactive cannot access Portal; internal history remains.

**AC-04 Candidate edit** — Candidate can edit only when Candidate Active + Submission `NEW` + version is not stale.

**AC-04T Internal auth** — Internal users authenticate with Google Workspace OAuth, use `@eiu.edu.vn`, exist in `app_users`, and are Active.

## B. Submission

**AC-05 Group** — Same Candidate displays grouped Submissions; child columns: `Ngày ứng tuyển | Trạng thái | HR Note`.

**AC-06 Mark New** — Only when there is no active Application.

**AC-07 Bulk Mark New** — All-or-nothing.

**AC-08 Derived status** — any active Application `HIRED` → `DONE`; all active Applications `REJECTED` → `CLOSED`; active non-final → `PROCESSED`. With no active Application, generic recalculation preserves manual `NEW/READ`; only a Submission coming from a derived state falls back to `READ`. Candidate Reactivate is the deliberate lifecycle exception that forces no-active-Application to `READ`.

**AC-08T Submission identity** — DB/server rejects a Submission whose email does not match its Candidate verified identity.

## C. Application

**AC-09 Identity** — durable Application identity = Submission + Khoa/Phòng + Ngành/Tổ + Vị trí and is globally unique across active/inactive history; exact same assignment reuses/reactivates the same Application ID.

**AC-10 Different identity** — Different assignment identity → different Application.

**AC-11 Exact duplicate** — warning + explicit confirmation → update existing active Application; no duplicate ID.

**AC-12 Identity history** — Application with Interview history is not rewritten into a different assignment.

**AC-12T Candidate integrity** — Application derives Candidate through Submission; no independent `candidate_id` can disagree.

**AC-12U Hierarchy integrity** — Application Unit/Team must match Position hierarchy.

**AC-12H HR owner integrity** — HR owner must be Active and HR-eligible/root according to the permission model.

## D. Interview rounds

**AC-13 Multiple rounds** — One Application supports multiple Interview Sessions in Phase 1.

**AC-14 Round 1** — New Application creates Round 1 with default schedule/report statuses.

**AC-15 Demo Topic** — belongs to Interview Session; each new round begins blank.

**AC-16 Latest round lifecycle** — only latest existing round may Delete/Inactive.

**AC-17 Latest inactive** — latest inactive blocks creating a subsequent round.

**AC-18 No renumber** — historical round numbers are never renumbered.

**AC-18T Round allocation** — concurrent next-round requests cannot create duplicate `round_no`.

## E. Schedule

**AC-19 Manual status** — Save/email does not auto-change schedule status.

**AC-20 CONFIRMED lock** — schedule details cannot be edited while `CONFIRMED`; HR changes status first.

**AC-21 Interviewer conflict** — active, non-cancelled Interviewer overlap blocks Save.

**AC-22 Room conflict** — active, non-cancelled Room overlap blocks Save.

**AC-22C Candidate conflict** — BLOCK overlapping `resource_blocking` sessions of the same Candidate.

**AC-23 Copy** — Copy creates a new editable schedule context; Demo Topic is blank; server conflict check occurs before commit.

## F. Participants

**AC-24 Order** — current `participant_order` is unique within the session and drives PDF/display order.

**AC-25 Snapshot** — name/job title/email history remains unchanged when User Directory changes.

**AC-26 Remove/re-add** — remove with report warns; removed participant loses access/current PDF. Re-add offers Restore old report or Create new.

**AC-26T Report ownership** — active Interview Report must reference an Interview Participant; a non-participant cannot own a report.

## G. Report

**AC-27 One row/Application** — HR Report page uses Current Active Latest Round.

**AC-28 PDF Current Round** — Preview/PDF uses Current Round only; prior rounds remain history.

**AC-29 Separate reports** — each Participant has an independent report.

**AC-30 No scoring** — no star, score, rating, pass percentage, or competency scale.

**AC-31 Final Decision source** — panel normally agrees and one representative fills the 3 final fields. Current source is the eligible report with newest `decision_updated_at`, not generic `updated_at`.

**AC-32 Decision timestamp** — only changes to `Conclusion`, `Expected Specific Job Assigned`, or `Expected Recruitment Time` update `decision_updated_at`/`decision_updated_by`.

**AC-33 Qualitative edit isolation** — editing one of the 5 qualitative fields does not change Final Decision Source.

**AC-34 Whole decision block** — all three final fields are read from the same source report; never merge across Interviewers.

**AC-35 Fallback** — if current source clears all three final fields, fall back to the next eligible report if one exists.

**AC-36 Interviewer final lock** — `HIRED`/`REJECTED` prevents Interviewer edit until HR changes status away.

**AC-37 HR edit Interviewer report** — only with `reports.edit_interviewer`.

**AC-38 Field-aware concurrency** — HR/Interviewer different-field edits preserve both; same-field conflict resolves to Interviewer; stale HR reloads; no stale whole-row overwrite.

## H. Permissions / Security

**AC-39 Exactly one Root after bootstrap** — cannot create a second Root; existing Root cannot ordinary demote/inactive/delete.

**AC-40 HR granular permissions** — HR role alone does not authorize every action.

**AC-41 Permission assignment** — only Root Admin grants/revokes HR permissions.

**AC-42 Interviewer contextual** — must be current Participant + visible + Active user/session; backend/RLS denies otherwise.

**AC-43 RLS and GRANTs** — exposed business tables have RLS and explicit grants; frontend-hidden controls are not security boundaries.

**AC-44 View security** — derived views are private by default; exposed views must use safe invoker/grant strategy and pass role tests.

**AC-45 Secret isolation** — no Supabase secret/service-role key is shipped to browser; privileged server use still performs authorization.

## I. Delete / Inactive

**AC-46 Unused Candidate / empty Interview-owned default** — hard delete remains only where the current delete matrix explicitly permits it. A successfully submitted production Submission is retention-managed and is not a normal HR hard-delete target.

**AC-47 Used** — business history exists → inactive.

**AC-48 Audit does not block cleanup** — Activity/Audit Log alone does not turn an otherwise-unused business record into “used”.

**AC-49 Audit immutable** — business Email History may be removed per frozen rule, but immutable audit records of actions are not mutable/deletable through application UI.

## J. Idempotency / transactions

**AC-50 Atomic commands** — multi-side-effect mutations execute as one server/RPC transaction or equivalent atomic command boundary.

**AC-51 Idempotency** — retries/double-clicks do not duplicate Submission/Application/Round/email enqueue/document finalization/persisted PDF job where applicable.

**AC-52 Structured errors** — backend returns stable business/technical error codes for expected conflicts and stale state.

## K. Files / email / operations

**AC-53 Private files** — candidate/interview documents are stored privately; authorization is enforced for each access.

**AC-54 Upload policy** — server accepts only PDF/DOC/DOCX/PPT/PPTX/PNG/JPG/JPEG with signature/MIME validation; max 5 MB/file, max 5 current files/parent, current CV required, malware `CLEAN` mandatory, and active content is not arbitrarily browser-rendered.

**AC-55 Email outbox** — business transaction commits before external delivery. Browser/double-click/request retry with the same idempotency scope/key must not create duplicate logical Outbox rows. Provider delivery is at-least-once; duplicate recipient delivery after provider-accept/worker-crash is possible and must be observable/audited.

**AC-56 Timezone** — timestamps use `timestamptz`; UI business display uses `Asia/Ho_Chi_Minh`; date-only values do not undergo timezone conversion.

**AC-57 Candidate mobile** — Candidate Login/Form/Phiếu của tôi must pass mobile UAT before production go-live.

## L. Production gate

Production go-live additionally requires the checklist in `45_PRODUCTION_UAT_GATE.md`, including finalized RLS/GRANTs, Auth, upload limits, privacy/retention, backups/restore, monitoring, email provider, mobile Candidate Portal, and official PDF template if PDF is used operationally.


## Technical acceptance — authorization, concurrency and platform integrity
1. View-only HR opens NEW Submission → remains NEW; default/full HR opens → READ.
2. Candidate cannot edit READ; HR can Mark New and Candidate can then edit.
3. Bound user identity cannot be rebound by `users.directory_manage`; unbound email typo can be corrected.
4. Interview Note and HR Report Note persist separately; Interviewer can never retrieve HR Report Note.
5. Two concurrent conflicting schedule saves cannot both commit. Test Candidate, Room and Interviewer races.
6. Add/re-add participant to scheduled session blocks conflicting Interviewer. Reactivate/CANCELLED→active blocks conflicts.
7. Candidate first OTP login provisions exactly one Candidate; recreated Auth identity with same verified email does not duplicate.
8. Application create uses selected Submission ID, never implicit latest.
9. Position with NULL Team rejects Application carrying any Team.
10. Parent Application inactive makes child Interview `access_active=false` for current-view/RLS/conflict.
11. Empty auto-created Round 1 can be cascaded in unused Application hard-delete; any meaningful history prevents hard-delete.
12. Candidate patch rejects HR/system fields.
13. Upload rejects >5 MB, 6th current file, and unapproved MIME/signature.
14. Outbox worker duplicate/retry test demonstrates no exactly-once assumption; provider duplicate possibility is documented/audited.
15. Privacy acknowledgement records exact notice version.
16. Status token contrast passes WCAG AA target for normal 16px text.
17. Package consistency validator fails if a source parser unexpectedly returns zero expected permissions/fields.

## Technical acceptance — form sessions, documents and lifecycle
- **AC-UP-01:** Candidate can upload required CV before Submission exists using an open form session; Submit atomically creates Submission and binds CLEAN staged files.
- **AC-UP-02:** Candidate stages replace/delete then presses Cancel → persisted current file/version is unchanged.
- **AC-UP-03:** A staged ADD/REPLACE whose reservation is not `VALIDATED` + malware `CLEAN` cannot be committed by Submit/Save.
- **AC-UP-04:** Effective Candidate documents after applying pending ADD/REPLACE/DELETE cannot exceed 5 current files and must retain at least one current CV.
- **AC-UP-05:** NEW_SUBMISSION cannot stage REPLACE/DELETE; one upload reservation cannot back two staged document mutations; one target logical document cannot have two simultaneous pending mutations in one form session.
- **AC-UP-06:** Candidate starts upload while NEW, HR opens it to READ before Save → finalize/Save re-check blocks Candidate mutation.
- **AC-STAT-01:** HR may manually set only NEW/READ; direct PROCESSED/DONE/CLOSED request is rejected.
- **AC-STAT-02:** two concurrent Application outcome changes on same Submission serialize on parent lock and final derived status is correct.
- **AC-SCH-09:** concurrent reschedule vs add participant cannot create hidden Interviewer conflict because Interview row is locked before participant snapshot/resource locks.
- **AC-AUTH-04:** first Google login of active allowlisted unbound internal user atomically binds matching verified EIU identity; conflicting existing binding rejects.
- **AC-MASTER-03:** referenced Position structural reassignment is rejected; create-new/inactivate-old path succeeds.
- **AC-FMT-04:** historical Interview using later-inactivated format can still be cancelled/reactivated under lifecycle rules; inactive format cannot be newly selected.
- **AC-COPY-03:** copy to another Application fills structurally empty default Round 1; otherwise creates next round.
- **AC-GRP-01:** Candidate Inbox pagination never splits one Candidate's child submissions across different parent pages.
- **AC-EMAIL-04:** Phase 1 email preview/send contains no file attachments. Provider accepted + worker crash scenario is documented as possible duplicate under at-least-once delivery.
- **AC-PRIV-03:** privacy acknowledgement is bound to Submission; Candidate identity derives through Submission, no redundant mismatched candidate_id.
- **AC-DS-05:** HR Report table declared min-width equals sum of frozen columns; validator fails on mismatch.

## Technical acceptance — identity, reactivation and command coverage
- **AC-CAND-REACT-01:** Candidate inactive with Submission `NEW` and no active Application → Reactivate Candidate → Submission becomes `READ`.
- **AC-CAND-REACT-02:** Candidate inactive with active in-progress Application → Reactivate → `PROCESSED`; effective HIRED → `DONE`; all rejected → `CLOSED`.
- **AC-DOC-HR-01:** HR file-only Submission document Save increments aggregate `Submission.version_no` exactly once; a second edit session on the old version fails `STALE_VERSION`.
- **AC-DOC-HR-02:** HR cannot delete the only effective current CV or create >5 effective current files.
- **AC-EMAIL-05:** Client/API retry with same idempotency scope does not duplicate logical enqueue; provider-level duplicate after accepted-send/worker-crash is permitted and audited.
- **AC-USR-ACT-01:** `users.directory_manage` may Active/Inactive a non-HR internal user.
- **AC-USR-ACT-02:** non-root HR cannot deactivate an HR-role target.
- **AC-USR-ACT-03:** Root Admin cannot be deactivated; HR self-deactivation through normal UI is rejected.
- **AC-AUTH-05:** Candidate recreated Auth identity with same verified email safely rebinds exactly one existing Candidate under row lock; conflicting identity evidence rejects.
- **AC-PRIV-04:** Candidate Form Session pins a server-published Privacy Notice version; client cannot acknowledge an arbitrary/unpublished version.
- **AC-EMAIL-06:** Candidate Submit/Update notification Outbox/History is relationally linked to the exact `submission_id`.
- **AC-APP-REACT-04:** exact durable Application identity cannot exist twice. Create/assignment lookup for the same identity resolves the existing Application; if it is inactive, Reactivate that same row. Database global uniqueness prevents active/inactive duplicates.
- **AC-APP-REACT-05:** Application Reactivate revalidates every non-elapsed child Interview that would become `reactivation_conflict_relevant = resource_blocking AND end_at > transaction_now`; fully elapsed past-only overlaps do not block reactivation. Any still-relevant Candidate/Room/Interviewer conflict blocks entire reactivation. Current Round only selects report/outcome.
- **AC-MASTER-04:** referenced Room identity-bearing fields cannot be structurally repurposed; create-new/inactivate-old path succeeds.
- **AC-DEL-03:** hard-delete with OPEN Candidate Form Session first durably records temp Storage cleanup, cancels session, then deletes; cleanup-capture failure blocks delete.
- **AC-CMD-01:** every production UI mutation maps to an entry in `command_registry.yaml`, contract text and at least one acceptance identifier.



## Semantic acceptance — canonical state, privacy and identity
- **AC-STAT-03:** `NEW` + no active Application + generic recalc → `NEW`.
- **AC-STAT-04:** `READ` + no active Application + generic recalc → `READ`.
- **AC-STAT-05:** derived status + final active Application removed/inactivated → `READ`.
- **AC-PRIV-EDIT-01:** EDIT Form Session pins current/effective Privacy Notice and Save requires acknowledgement.
- **AC-PRIV-EDIT-02:** same notice version already acknowledged → idempotent, no duplicate acknowledgement.
- **AC-PRIV-EDIT-03:** new pinned notice version during later EDIT → exact version appended to acknowledgement history.
- **AC-PRIV-EDIT-04:** arbitrary/unpublished version rejected; no current/effective notice → `PRIVACY_NOTICE_UNAVAILABLE`.
- **AC-CAND-UPD-EMAIL-01:** Candidate Update creates one logical exact-Submission Outbox notification under idempotency replay.
- **AC-CONC-DOC-01:** file-only Save bumps Submission version exactly once; stale parallel session fails `STALE_VERSION`.
- **AC-CACHE-01:** latest Candidate/HR edit refreshes Candidate cache; older edit does not.
- **AC-CACHE-02:** MAINTENANCE_ONLY repair-delete of a non-production/legacy unused latest Submission refreshes cache to the next surviving snapshot or clears it; this is not normal HR production behavior.
- **AC-PART-RESTORE-01:** RESTORE_OLD_REPORT restores Participant current state + unarchives same Report and preserves decision source metadata.
- **AC-PART-RESTORE-02:** CREATE_NEW_REPORT leaves old history archived and creates new current Participant/report.
- **AC-APP-ID-01:** durable Application identity is globally unique across active/inactive rows.
- **AC-ACCESS-01:** inactive parent Application revokes Interviewer contextual access.
- **AC-RESOURCE-01:** non-current active/non-CANCELLED scheduled Interview still blocks resource overlap.
- **AC-PRIV-IMM-01:** published Privacy Notice content/hash/effective metadata cannot mutate; new content requires new version.

## Source-governance and lifecycle acceptance
- **AC-PRIV-SESSION-01:** starting NEW or EDIT Candidate Form Session server-selects exactly one current/effective Privacy Notice (`is_current=true`, `effective_from<=now()`), pins it in the session, and fails `PRIVACY_NOTICE_UNAVAILABLE` when none exists.
- **AC-CAND-DEL-SESSION-01:** hard-delete of an unused Candidate with OPEN form/temp uploads first durably captures cleanup paths, cancels sessions/reservations, then deletes; failed cleanup capture blocks delete.
- **AC-USR-DEL-01:** Internal User hard-delete is not exposed in normal HR UI; Root maintenance cleanup is eligible only for unbound, non-HR, non-Root, never-referenced rows.
- **AC-APP-ID-02:** identity fields of an existing Application are immutable even before Interview history; changing assignment resolves/creates another durable Application instead.
- **AC-NOTIFY-01:** Candidate Update rate limiting applies to the Candidate mutation endpoint; system HR-notification throttling/coalescing must not roll back an otherwise valid Candidate Save.
- **AC-PRIV-CURRENT-01:** published/effective Privacy Notice lookup fails closed when the current pointer is missing, future-dated, or otherwise unavailable.

## Behavior-specific acceptance — command ownership and adversarial integrity
- **AC-REPORT-STATUS-01:** exactly one trusted command, `change_report_status`, writes `interviews.report_status_code`; HR-note command cannot write status.
- **AC-REPORT-STATUS-02:** every successful Report Status change locks Current Round/parent Submission and recalculates Submission before commit.
- **AC-REPORT-STATUS-03:** stale/non-current-round Report Status mutation is rejected.
- **AC-HR-NOTE-01:** `update_hr_report_note` changes only `hr_report_note`; Interviewer cannot retrieve it and no Submission recalc occurs from note-only edit.
- **AC-DOC-TARGET-01:** staged Candidate REPLACE requires target logical document to have exactly one current version.
- **AC-DOC-TARGET-02:** staged Candidate DELETE requires target logical document to have exactly one current version.
- **AC-DOC-TARGET-03:** historical/no-current logical target cannot be resurrected or bypass max-five current-file invariant.
- **AC-DOC-TARGET-04:** if a valid staged target loses/changes its current version before Save, Save fails `INVALID_DOCUMENT_TARGET` with no materialization.
- **AC-EMAIL-HIST-01:** Email History SELECT/DELETE requires `emails.history_view` plus exact parent contextual read; cross-context ID access is denied.
- **AC-EMAIL-HIST-02:** Delete requires `emails.history_delete` and deterministic cleanup classification: TEST only for TEST environment; WRONG requires mandatory reason; immutable audit persists.
- **AC-OWNER-LIFE-01:** an Application cannot be activated/reactivated with an ineligible HR owner; same transaction may reassign to eligible owner.
- **AC-OWNER-LIFE-02:** HR deactivation/HR-role removal is blocked while Active Applications remain owned unless reassigned atomically.
- **AC-APP-REACT-PAST-01:** fully elapsed historical schedule overlaps do not block Application Reactivate; non-elapsed conflicts still block atomically.
- **AC-PRIV-PUBLISH-01:** future-effective Privacy Notice is published non-current; current pointer switches at/after effective time in one transaction without an unintended no-current/effective gap.
- **AC-CAND-INACTIVE-01:** Candidate inactive sets `inactive_at/by`; reactivate clears them; immutable audit preserves lifecycle history.
- **AC-REPORT-LIFE-01:** Interview Report lifecycle permits only current `(active=true, archived=false)` or historical `(active=false, archived=true)` states.
- **AC-PERM-VIEW-01:** non-root Directory Manager cannot view another user's granular effective permissions; Root can, and a user may view own effective permissions.


## Batch, state and invariant acceptance
- **AC-STAT-MANUAL-READ-01:** any active Application + manual `READ` request is rejected; authoritative derived status remains unchanged.
- **AC-STAT-MANUAL-NEW-01:** any active Application + manual `NEW` request is rejected.
- **AC-STAT-MANUAL-NOAPP-01:** with no active Application, manual `NEW/READ` remains permitted subject to permission/version rules.
- **AC-BULK-01:** every visible Phase-1 lifecycle/status bulk action maps to one named batch command with declared atomicity; browser loops over single-row commands are not the production contract.
- **AC-MASTER-ACTIVE-01:** new/changed Unit/Team/Position/Room/Qualification/Source/Reason references require active master rows; unchanged historical inactive references remain valid.
- **AC-PART-ACTIVE-01:** re-adding an inactive Internal User is rejected; normal deactivation is blocked while that user remains a current participant on a non-elapsed resource-blocking Interview.
- **AC-FORM-OWNER-01:** Candidate Form EDIT session cannot target another Candidate's Submission.
- **AC-PRIV-DELETE-01:** published Privacy Notice cannot be normally deleted.
- **AC-ROUND-EMPTY-01:** Copy and unused-Application delete use the same `private.is_structurally_empty_default_round()` predicate.
- **AC-PART-LIFE-01:** current Participant implies `removed_at IS NULL`; removed historical Participant implies `removed_at IS NOT NULL`.
- **AC-CAND-EMAIL-01:** Candidate verified email cannot be modified by normal profile/business mutation.


## Targeted review acceptance
- **AC-PERM-INT-STATUS-01:** HR with `interviews.manage` but without `interviews.status` cannot execute single Interview Schedule Status change (`FORBIDDEN`).
- **AC-PERM-INT-STATUS-02:** The same actor cannot execute `bulk_change_interview_schedule_status`; no selected Interview mutates.
- **AC-PERM-INT-STATUS-03:** `interviews.status` + prerequisite `interviews.view` authorizes equivalent single/bulk Schedule Status transitions, subject to the same state/conflict rules.
- **AC-FORM-EXP-01:** Form Session row still says `OPEN` but `expires_at <= transaction_now` → Stage/Save/Submit/Finalize fail `FORM_SESSION_EXPIRED`; cleanup timing cannot make it temporarily valid.
- **AC-UP-EXP-01:** ADD/REPLACE reservation still says `VALIDATED/CLEAN` but `expires_at <= transaction_now` → Stage/Save/Submit/Finalize fail `UPLOAD_RESERVATION_EXPIRED` (or the canonical expiry error wrapper) with no materialization.
- **AC-FORM-LIFE-01:** Only `OPEN → SUBMITTED`, `OPEN → CANCELLED`, `OPEN → EXPIRED` persist; terminal sessions never reopen and lifecycle transitions update timestamp/audit evidence.
- **AC-OPEN-SUB-01:** `submissions.view` without `submissions.status` can open a NEW Submission as pure read; status remains NEW.
- **AC-OPEN-SUB-02:** `submissions.view + submissions.status` opening NEW performs the one conditional NEW→READ mutation atomically.
- **AC-STAT-INACTIVE-01:** Candidate Inactive with latest Submission NEW/READ and no active Application remains eligible for single manual NEW/READ by authorized HR.
- **AC-STAT-INACTIVE-02:** The same Candidate is equally eligible inside Candidate-level bulk manual NEW/READ; Candidate inactivity alone must not abort the batch.
- **AC-PROT-EDU-01:** Prototype Education requiredness/min-items does not exceed Validation Contract; current Phase 1 allows zero rows and does not mark the four Education fields required.
- **AC-PRIV-NEW-UI-01:** NEW_SUBMISSION Privacy acknowledgement is unchecked on initial render and must be explicitly selected before Submit.
- **AC-REPORT-AUTH-01:** Interviewer may save only own report under current participant context; HR branch requires both `reports.view` and `reports.edit_interviewer`; pseudo-permission strings are not implementation authority.


## Lifecycle reachability + scheduling/copy acceptance
- **AC-PART-OPER-01:** Unscheduled Interview with an inactive current Participant cannot be scheduled; fail `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED` before conflict commit.
- **AC-PART-OPER-02:** CANCELLED Interview with an inactive current Participant cannot transition to an operational schedule status.
- **AC-PART-OPER-03:** Inactive Application cannot reactivate a non-elapsed child Interview into operational state while any current Participant user is inactive.
- **AC-PART-OPER-04:** When every current Participant is active, normal Candidate/Room/Interviewer conflict locking/checks execute; adjacent `[start,end)` boundaries remain allowed.
- **AC-SUB-DEL-REACH-01:** Normal successful production Candidate Submit creates retained exact-Submission PRODUCTION email trace; `delete_unused_submission` is therefore classified MAINTENANCE_ONLY/not normal HR production capability. Maintenance delete must still reject retained production usage.
- **AC-SCH-SRC-01:** Normal schedule Save blocks Candidate, Room and Interviewer overlap, ignores CANCELLED/access-inactive/no-interval rows, and allows `end=start` adjacency.
- **AC-STAT-LATEST-01:** single manual Submission status mutation resolves and verifies deterministic latest Submission; historical child Submission cannot be mutated by a crafted exact-ID request.
- **AC-RP-COPY-01:** Copy to another Application fills structurally empty target Round 1; otherwise creates next legal round. Initial draft copies schedule/logistics and leaves Demo Topic blank.
- **AC-ROUND-PROV-01:** Round with outgoing or incoming Copy provenance is business-used for structural-empty/delete purposes and never falls through to an unexpected raw FK delete error.

## Cross-layer acceptance — Education, exact Submission identity and participant eligibility — Education, exact Submission identity and participant eligibility
- **AC-EDU-DB-01:** `validation_contract.yaml` Education `required_fields=[]` is reflected physically: zero rows and partially populated Education rows permitted by the contract persist without a DB `NOT NULL` contradiction.
- **AC-EDU-DB-02:** `submission_education` business columns `period_text`, `qualification_id`, `major`, `institution` remain nullable until/unless a future frozen Validation Contract explicitly adds per-row requiredness.
- **AC-PROTO-SUBSEL-01:** production-intent Application assignment UI uses exact `SubmissionSelector`; selected value is `submission_id`, never Candidate ID or implicit latest.
- **AC-PROTO-SUBSEL-02:** two Submissions from the same Candidate render as two distinct choices with Candidate name, verified email, submitted date and Submission status.
- **AC-PART-OPER-CREATE-01:** Create resource-blocking Interview with any selected inactive Internal User → `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED`; no Interview is created.
- **AC-PART-OPER-COPY-01:** Copy schedule whose prefilled/selected Participant set contains an inactive Internal User → `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED`; no target Round is created/filled.
- **AC-STAT-LATEST-SQL-01:** starter SQL manual-status helper locks Candidate, resolves deterministic latest Submission, verifies expected latest ID/version, and cannot mutate a historical child Submission by exact ID.
- **AC-USR-LIFE-REG-01:** `set_internal_user_active` machine registry declares both Active-Application owner reassignment guard and non-elapsed resource-blocking current-Participant reassignment guard.

## Cross-layer acceptance — nullable Education, bulk schedule parity, source coherence
- **AC-EDU-NULL-01:** Education row with `qualification_id=NULL` and another optional Education field populated is accepted; NULL skips active-master qualification validation.
- **AC-EDU-NULL-02:** Education row with a non-null inactive `qualification_id` is rejected with `INACTIVE_QUALIFICATION_NOT_SELECTABLE`.
- **AC-EDU-NULL-03:** An unchanged historical inactive non-null qualification remains readable/operable; the active-master guard applies only to INSERT or changed non-null selection.
- **AC-PART-OPER-BULK-01:** if any selected CANCELLED/dormant Interview would become resource-blocking while a current Participant is inactive, `bulk_change_interview_schedule_status` aborts the entire batch with `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED`; no selected Interview mutates.
- **AC-BULK-SCH-01:** bulk Interview schedule-status mutation is ALL_OR_NOTHING across transition validation, Active-Participant eligibility and resource conflicts; one failure rolls back every selected Interview.
- **AC-SCH-CANDIDATE-BULK-01:** a same-Candidate overlap in any selected Interview blocks the whole schedule-status batch.
- **AC-SCH-ROOM-BULK-01:** a Room overlap in any selected Interview blocks the whole schedule-status batch when the format uses a Room.
- **AC-SCH-INTERVIEWER-BULK-01:** an Interviewer overlap in any selected Interview blocks the whole schedule-status batch.
- **AC-REACT-CANON-01:** Application Reactivate evaluates only non-elapsed children satisfying `reactivation_conflict_relevant`; fully elapsed historical intervals never block lifecycle recovery.
- **AC-SOURCE-BASELINE-01:** all CURRENT machine baseline declarations resolve to Full/Technical v1.18, Design v1.8 and Responsive v1.10, while historical versions are allowed only in explicitly historical/changelog evidence.
- **AC-RESP-AUTH-01:** Responsive `README.md` and `VERSION.md` both declare Responsive v1.10 authority against Full Handover v1.18 + Design System v1.8.


## Targeted acceptance additions — current
- **AC-INT-UP-FK-01:** Interview Upload Reservation with nonexistent `interview_id` is rejected by the physical FK; FK uses `ON DELETE RESTRICT`.
- **AC-INT-UP-DEL-01:** hard-delete Interview with temp/nonterminal Upload Reservation first durably records bucket/path in `storage_cleanup_queue`, then cancels/removes reservation; no orphan reservation/object is possible.
- **AC-INT-UP-DEL-02:** failure to persist any required temp-object cleanup intent aborts Interview hard-delete.
- **AC-BULK-CAND-LIFE-01:** Bulk Candidate Active/Inactive writes `is_active + inactive_at + inactive_by` atomically for every selected Candidate; one stale/ineligible item rolls back all.
- **AC-BULK-CAND-LIFE-02:** Bulk Candidate Reactivate applies the same per-Submission reactivation recalculation as single Candidate and records per-Candidate + batch audit.
- **AC-BULK-INT-DEL-01:** Bulk Interview delete/inactivate prevalidates all selected Interviews and all hard-delete temp-cleanup prerequisites before mutation; one failure leaves every selected Interview unchanged.
- **AC-BULK-REPORT-01:** Bulk Report Status re-resolves Current Round/versions for every selected Application; one stale/current-round mismatch rolls back all and successful commit recalculates all affected parent Submissions.
- **AC-CRIT-QA-01:** both Interview Schedule Status critical controls (single and bulk) map to named browser QA assertions; validation fails if either control lacks executable evidence in the current Owner-UAT prototype.
- **AC-INT-EMAIL-WS-01:** Internal User email must match the exact `@eiu.edu.vn` domain and the local part may not contain whitespace; lookalike/subdomain/suffix forms remain rejected.

## Implementation governance / Copy-command acceptance

- **AC-GATE-SEQ-01:** Technical Specification Freeze is a semantic/source gate before coding; production migrations/RLS/RPC/race/storage/performance/backup/deployment evidence is required at Implementation Validation/Migration Freeze after implementation exists, not both before and after Technical Freeze.
- **AC-COPY-CMD-01:** Copy draft performs no DB mutation; Save Copy maps to exactly `copy_interview_schedule`, which atomically selects/fills the target Round, records provenance, applies Active-Participant and Candidate/Room/Interviewer conflict guards, is idempotent, and audits.
- **AC-SOURCE-RESP-VERSION-01:** CURRENT scope/design/prototype authority declares Full/Technical v1.18 + Design v1.8 + Responsive Prototype v1.10; stale current v1.9/v1.12/v1.15/v1.17 authority assertions are forbidden outside historical/changelog context.
## Source-sync / critical Copy evidence

- **AC-COPY-ENGINE-01:** `copy_interview_schedule` is declared as a user of the canonical shared Candidate/Room/Interviewer schedule-conflict engine in command contract, structured app spec and concurrency spec.
- **AC-RP-COPY-USED-01:** Save Copy to another Application whose default Round1 is already business-used creates the next legal round, preserves existing Round1 and records Copy provenance.
- **AC-CRIT-COPY-QA-01:** every `INTERVIEW-COPY-SAVE.browser_qa` ID resolves to a current Responsive Browser QA result; unresolved QA IDs fail package validation.
- **AC-ALLINONE-LABEL-01:** generated All-in-One header and validator expectation match current Full Handover v1.18; stale generated current-version labels are forbidden.

## Technical Source v1.18 Acceptance Additions
- **AC-APP-VIEW-01:** HR user with `applications.view` or `applications.manage` can SELECT Application rows; caller with only `submissions.view` is denied Application SELECT.
- **AC-CAND-CORR-01:** HR user with `submissions.edit` can correct Candidate full_name, phone, date_of_birth, gender_code, current_address via `correct_submission_candidate_fields_by_hr` with optimistic version check, validation bounds, and audit logging changed field names without dumping full PII.
- **AC-CAND-REC-01:** Root Admin or HR with `candidates.identity_manage` can recover Candidate login email identity via `recover_candidate_email_identity`, updating verified Auth identity and Candidate record while preserving historical Submission email snapshots and revoking obsolete sessions.
- **AC-PRIV-STG-01:** Candidate Submit and Save Edit verify that the presented notice version matches the current effective published version at transaction time; mismatch returns stable `PRIVACY_NOTICE_CHANGED`, preserving form session and draft for retry.
- **AC-RESCHED-01:** `reschedule_confirmed_interview` atomically re-checks Candidate/Room/Interviewer conflicts, updates schedule/meeting details, and resets Schedule Status to `AWAITING`; conflict or validation failure rolls back all changes.
- **AC-ROUND-HIRED-01:** Creating next Interview round is blocked if the latest active Interview has report status `HIRED`; Schedule Status `CANCELLED` does not block creating next round.
- **AC-REPORT-HIST-01:** Interviewer has read-only access to historical Interview rounds they personally participated in (`interview_participants.is_current=true`); report write requires target Interview is Application Current Round, caller is current participant, and report status is non-final/writable.
- **AC-REPORT-MERGE-01:** Report save applies field-aware merge using `expected_version_no` and `base_values`; disjoint field updates merge cleanly, same-field conflict on HR update rejects with `STALE_VERSION`.
- **AC-RESOLVE-OUTCOME-01:** Application effective outcome is resolved solely from Application Current Round (highest `round_no` among access-active Interviews): HIRED => HIRED, REJECTED => REJECTED, otherwise IN_PROGRESS.
- **AC-DETAIL-PURE-01:** `get_submission_detail()` is a pure read and never mutates Submission status from NEW to READ; only explicit user-intent `open_submission()` may execute NEW->READ transition.
- **AC-DOC-MAT-01:** Candidate document staged ADD creates a new logical document header without requiring `UNIQUE(submission_id, document_type_id)`; multiple logical files of the same type may coexist; Candidate-created rows set candidate creator/uploader metadata and NULL app_user.

## CR-INTERVIEW-FEEDBACK-20261105 acceptance

- **AC-IF-01:** Actual authenticated identities prove own-only invitation access, private-table/helper denial, inactive/unbound/unassigned rejection, positive limited-HR authorization with both permissions and rejection with either missing. HR invitation endpoint remains OWN.
- **AC-IF-02:** Published question versions are immutable; publishing another version preserves questions on existing collections. Only ordered bounded plain-text questions, no scoring.
- **AC-IF-03:** Exact current round and selected current bound participants are enforced. Repeated/concurrent creation produces one collection/invitation/paused intent per selection; UI never claims delivery.
- **AC-IF-04:** Stale drafts do not overwrite data; identical submit retries do not duplicate audit. Required answers and deadlines are enforced. Hidden/final/inactive/historical contexts reject draft writes. Submitted answers remain immutable and keyboard-readable in full.
- **AC-IF-05:** Original evaluator denominator survives revocation/removal/inactivation. Incomplete or unavailable sets cannot consolidate/approve. Snapshot pins template, safe candidate context, every evaluator, answer version and submission time; draft edits never rewrite it.
- **AC-IF-06:** Real synchronized database sessions prove create retry, same-user draft conflict, revoke/submit, remove/approve, post-wait permission revocation, next-round/submit and existing email-lock composition without deadlocks or unauthorized commits.
- **AC-IF-07:** Browser proves assignment, draft reload, separate evaluator submission, HR individual inspection, full attributed consolidation/approval/print; keyboard required-field feedback, responsive containment, pagination selection consistency and explicit fresh-version reload preserve user intent. Production auth and legacy decision/status remain unchanged.


## CR-DRIVE-FILES-HOSTED-20261105

AC-DRIVE-01, AC-DRIVE-02, AC-DRIVE-03, AC-DRIVE-04 and AC-DRIVE-05 are defined in
`102_PRIVATE_DRIVE_DOCUMENT_STORAGE.md`: actual-role isolation, immutable binding,
legacy-write exclusion, fenced upload/inspection, retained-version cleanup and
configured gateway/scanner end-to-end evidence. AC-DRIVE-05 remains a runtime gate.

AC-DRIVE-06 in `102_PRIVATE_DRIVE_DOCUMENT_STORAGE.md` requires database-side
provider isolation for scan/cleanup claim and exhaustion selection, including
actual-role mixed-queue and concurrent-claim verification.
