# 39. Security / RLS Matrix — v1.8

## 1. Principles

- RLS bắt buộc cho exposed business tables.
- `anon`: không đọc/ghi dữ liệu tuyển dụng.
- `authenticated`: chỉ quyền tối thiểu.
- Browser dùng Supabase publishable key; **không bao giờ** secret/service-role key.
- Service-role/server code vẫn phải tự authorize trước khi thao tác vì service-role bypass RLS.
- Mutations phức tạp ưu tiên RPC/Server Action, không direct table DML.

## 2. Identity helpers

Private helpers đề xuất:
- `private.current_app_user_id()`
- `private.is_root_admin()`
- `private.has_permission(code)`
- `private.is_candidate_owner(candidate_id)`
- `private.is_current_interview_participant(interview_id)`

Nếu dùng `SECURITY DEFINER`:
- `set search_path=''`;
- explicit qualified table names;
- revoke execute khỏi public/anon; chỉ grant nơi cần.

## 3. Read matrix

| Entity | Candidate | HR | Interviewer | Root Admin |
|---|---|---|---|---|
| Candidate | own | permission | no | all |
| Submission | own | permission | no | all |
| Submission documents | own | permission | no | all |
| Application | no/internal-hidden | permission | contextual minimal | all |
| Interview Session | no | permission | participant + visible | all |
| Participants | no | permission | own/current session list | all |
| Interview documents | no | permission | current participant + visible | all |
| Interview reports | no | permission | current session; read shared report per business | all |
| HR notes | no | permission | no | all |
| User directory | no | allowed subset | contextual names needed | all |
| Permissions | no | own effective view if desired | no | all |
| Audit log | no | restricted admin/security | no | all |

## 4. Write matrix

Candidate:
- writes own Submission only through command and only while `NEW`;
- email immutable;
- own Storage path only.

HR:
- command permission checks by granular code;
- `reports.edit_interviewer` required to edit Interviewer report;
- `users.permissions_manage` Root Admin only.

Interviewer:
- write own active report for current participation only;
- cannot update another participant report;
- cannot edit when Current Round report status is final.

Root Admin:
- implicit all app permissions;
- still subject to business safety guards unless specific recovery procedure.


## 4A. Direct-table/RPC access blueprint

| Entity | Candidate SELECT | Candidate write | HR SELECT | HR write | Interviewer SELECT | Interviewer write |
|---|---|---|---|---|---|---|
| `candidates` | own active | provisioning/profile command only | permissioned | candidate-active command | no | no |
| `submissions` | own | Candidate command only while NEW | `submissions.view` | `submissions.edit/status` commands | no | no |
| `submission_documents` | own | upload commands | `submissions.view/edit` as defined | document commands | no | no |
| `applications` | no | no | Root OR `applications.view` OR `applications.manage` (không dùng `submissions.view`) | commands | contextual minimal if needed | no |
| `interviews` | no | no | Root OR `interviews.view` OR `interviews.manage` (không dùng `submissions.view`) | commands | access-active participant + visible (historical READ: participated rounds; WRITE: current round + writable status) | no |
| `interview_participants` | no | no | permissioned | participant commands | current session list only | no |
| `interview_documents` | no | no | permissioned | document commands | access-active participant + visible | no |
| `interview_reports` | no | no | `reports.view` | report commands | shared current-session read | own report command only |
| `app_users` | no | no | allowed directory subset | directory command | contextual identity subset | no |
| `app_user_permissions` | no | no | own/effective if needed | Root commands only | no | no |
| `email_outbox/audit` | no | no | restricted server/admin view | server/worker only | no | no |

`hr_report_note` should not be exposed through a broad Interviewer-readable row shape. Prefer a safe projection/RPC or field-separated query contract so column confidentiality is not dependent on frontend hiding.

## 5. Views

Implementation views (`Current Round`, `Application Outcome`, `Final Decision Source`) nằm ở `private` schema.

Nếu một view bắt buộc expose:
- use `security_invoker=true`;
- explicit grants;
- test RLS with Candidate/HR/Interviewer identities.

## 6. Storage

Private buckets only.

Storage RLS phải kiểm soát:
- candidate own submission paths;
- HR permission-based read/write;
- interviewer read only interview-document paths của session current + visible;
- no public bucket for CV/degrees/transcripts/reports.

## 7. RLS performance

- index FK/ownership columns dùng trong policies;
- use `(select auth.uid())` where appropriate;
- tránh self-recursive RLS;
- complex permission lookup có thể dùng private `SECURITY DEFINER` helper đã khóa execute.

## 8. Required security test personas

- anonymous;
- Candidate A;
- Candidate B;
- HR full;
- HR limited;
- Interviewer A;
- Interviewer B;
- inactive internal user;
- inactive candidate;
- Root Admin.


## Authorization hardening rules
- Interviewer contextual SELECT requires `application.is_active AND interview.is_active AND participant.is_current AND visible_to_interviewers AND app_user.is_active`.
- Candidate inactive does not hide internal records from authorized HR.
- `hr_report_note` is HR-only; never selected through Interviewer policy/view.
- `users.directory_manage` never authorizes rebinding an already-bound Auth identity. `users.identity_manage` is Root-only in Phase 1.
- `submissions.view` by itself is read-only; NEW→READ side effect requires `submissions.status`.
- Storage policies mirror the same ownership/context rules; signed URL creation is itself authorized server-side.


## Migration blueprint
See `59_RLS_POLICY_BLUEPRINT.md` for per-persona predicate intent and adversarial test requirements. Final executable policies/GRANTs must be reviewed on the actual Supabase migration bundle before **Implementation Validation / Migration Freeze**. The pre-code Technical Specification Freeze reviews policy intent/blueprints, not nonexistent production migrations.

## Candidate Form Session and logical-document RLS scope
Policies/migrations must cover `candidate_form_sessions`, `candidate_form_document_changes`, `submission_document_logicals`, `interview_document_logicals` and revised `upload_reservations`. Candidate may access only own open Form Session and own staged uploads; Interview upload remains HR-permission controlled. Logical headers inherit parent authorization.

Permission dependency is not delegated to UI: an action command requires its action permission plus view/context prerequisite.


## Canonical Interviewer contextual predicate
Interviewer RLS/contextual access must include `Application.is_active=true AND Interview.is_active=true` before participant/visibility/user checks. Do not use schedule status for access authorization. `resource_blocking` is a scheduling predicate, not an RLS predicate.

## Email History, permission-display and owner-lifecycle rules
- Email History SELECT requires `emails.history_view` **plus** the parent/context read predicate derived from `email_type`; a raw `email_history_id` never grants access.
- Email History DELETE requires `emails.history_view + emails.history_delete` plus the same parent context and accepted cleanup classification. Root bypass remains audited.
- Non-root `users.directory_manage` does not grant visibility into another user's granular effective-permission list. Root may view all; non-root may see only the role/protected-state needed for lifecycle plus their own effective permissions.
- Active Application owner invariant: `hr_owner_id` must resolve to Active HR/root. HR-role removal/deactivation is blocked while Active Applications remain owned unless reassignment is part of the same trusted operation.
