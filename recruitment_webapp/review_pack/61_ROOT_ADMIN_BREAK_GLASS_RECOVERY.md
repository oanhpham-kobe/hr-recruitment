# 61. Root Admin Break-Glass Recovery Runbook — v1.8

## Purpose
Recover the single Root Admin identity only when normal Google/Auth binding can no longer be used. This is an operational emergency path, not an application UI feature.

## Preconditions
- Incident ticket/change record exists.
- Identity of replacement/recovered EIU account is independently verified.
- Approval by the designated EIU system owner and one additional authorized approver.
- Operator has controlled production database migration/admin access; application secret keys are not used in browser.

## Procedure
1. Put privileged user-management changes into maintenance/restricted mode if practical.
2. Export current Root directory row, Auth mapping reference and relevant audit entries.
3. Verify new Google Workspace email is `@eiu.edu.vn`, active and not bound to another `app_users` row.
4. Execute a **versioned, reviewed one-time migration/function** that is allowed to bypass the normal Root identity trigger only for the exact Root row and exact verified target identity. Never use ad-hoc direct SQL without change record.
5. Update Root `email/auth_user_id` binding atomically; do not change `is_root_admin=true` or Active status.
6. Insert immutable `ROOT_BREAK_GLASS_RECOVERY` security audit event with ticket/change ID, approvers and before/after identity IDs (no tokens/secrets).
7. Revoke old sessions/credentials where supported and force fresh Google login.
8. Verify Root can login and Root-only actions work; verify old identity cannot.
9. Exit maintenance/restricted mode.
10. Record post-incident review and rollback evidence.

## Rollback
The recovery migration must include a reviewed inverse operation using the pre-change snapshot. Rollback is allowed only while the prior identity is still verified and safe.

## Secret custody
- Database/production administrative credentials live in approved secret management, never repository/browser/local shared notes.
- At least two authorized operators should be able to recover access under EIU policy; no single undocumented personal credential should be the only path.

## Testing
Rehearse in isolated staging before go-live and after major Auth/identity changes. Production rehearsal should not change the real Root identity; validate the controlled migration path using a test privileged account.
