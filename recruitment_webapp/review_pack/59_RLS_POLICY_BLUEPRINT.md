# 59. RLS / GRANT Policy Blueprint — v1.8

This is a policy blueprint for migrations, not executable final SQL. It complements `39_SECURITY_RLS_MATRIX.md`.

## Global rules
- `anon`: no direct business-table grants.
- `authenticated`: no broad table DML; grant only minimal SELECT/RPC execute as designed.
- Candidate/HR/Interviewer mutations should primarily use explicit commands/RPCs.
- Secret/service-role stays server-only and must re-authorize before any privileged action.

## Candidate
### Candidate row
SELECT own active Candidate identity. No ordinary UPDATE of email/auth binding.

### Submission
SELECT own. Direct UPDATE is discouraged; command checks Candidate active + `NEW` and DTO allowlist. Candidate cannot SELECT `hr_note` through a broad table/view; expose a candidate-safe projection/RPC if necessary.

### Submission documents
Candidate can access own Submission document metadata/path only through authorized command/signed URL generation.

## HR
Permission helpers evaluate active `app_users`, role/permission, with Root implicit allow.
- `submissions.view`: read Submission rows only.
- `submissions.status`: authorizes status mutation including open NEW→READ.
- `applications.view` / `applications.manage`: authorizes Application table SELECT (`Root OR applications.view OR applications.manage`). **Tuyệt đối không dùng `submissions.view` để cấp quyền SELECT bảng applications.**
- `interviews.view` / `interviews.manage`: authorizes Interview table SELECT (`Root OR interviews.view OR interviews.manage`). **Tuyệt đối không dùng `submissions.view` để cấp quyền SELECT bảng interviews.**
- other mutations require their granular code.
- default HR receives all HR codes, but RLS/command still evaluates explicit effective permissions.
## Interviewer
### Historical READ (Owner Decision I)
Interviewer có quyền **SELECT / READ các Interview round và report lịch sử mà họ đã trực tiếp tham gia**:
- `app_user.is_active`
- `application.is_active`
- `interview.is_active`
- `participant.is_current` trên chính Interview đó
- `visible_to_interviewers=true`.
Application có Current Round mới **không tước quyền đọc** các round trước mà interviewer đã tham gia. Không có quyền xem các vòng hoặc Candidate mà interviewer không tham gia.

### Report WRITE (Ghi / Sửa Report)
Quyền ghi/sửa báo cáo yêu cầu:
- Target Interview là **Current Round của Application**;
- Caller sở hữu report gắn với current participant row của mình;
- Target Interview đang `access_active` và visible;
- `report_status_code` của **chính target Interview đó đang ở trạng thái non-final / writable** (không phải `HIRED` hay `REJECTED`).
Interviewer may read shared report preview fields but **never** `hr_report_note`.
## Internal identity
`users.directory_manage` can mutate business profile and unbound email typo only. Bound `auth_user_id/email/provider binding` cannot be changed by this permission. Root-only identity command executes through a protected RPC/recovery path.

## Private views
Current Round / effective outcome / final decision views remain `private`. If any public API view is required, use `security_invoker=true`, explicit grants and persona tests.

## Storage
Private buckets. Signed URL generation is a server-authorized operation:
- Candidate → own Submission docs;
- HR → permission-based;
- Interviewer → access-active current Participant + visible Interview docs only.
No Candidate access to HR/interview reports/internal notes.

## Adversarial tests required
Candidate A must fail to access Candidate B; Interviewer A must fail on non-participating session; HR Limited must fail missing permission; inactive internal user fails; parent Application inactive revokes Interviewer contextual access; service-role endpoints must still deny unauthorized caller at server authorization layer.

## Candidate temporary-resource and logical-document policies
Candidate Form Sessions and staged document changes are candidate-owned temporary resources. Candidate access requires authenticated Candidate mapping + active account + ownership; EDIT session additionally requires target Submission `NEW` at mutation time. Final logical document access derives from parent Submission/Interview authorization. `privacy_acknowledgements` authorization derives solely through Submission.

## Identity, lifecycle and delete-permission policies
- Candidate self-rebind is never direct table UPDATE; only trusted OTP provisioning may replace obsolete Auth ID under safe-rebind predicate.
- Directory manager lifecycle predicates exclude HR-role targets and Root.
- Production HR delete permission: `candidates.delete_unused`; Email History delete uses `emails.history_delete`. Submission repair-delete is MAINTENANCE_ONLY, not a normal HR permission.
- Reactivated Application restores `access_active` for active child Interviews. Only non-elapsed children satisfying `reactivation_conflict_relevant = resource_blocking AND end_at > transaction_now` participate in the reactivation conflict re-check; fully elapsed historical overlaps do not block lifecycle recovery. Current Round remains only report/outcome selector.


## Canonical Interviewer predicate source
Use `private.access_active_interviews` (or equivalent inline predicate) for contextual access. Never infer access from `resource_blocking` or Current Round.
