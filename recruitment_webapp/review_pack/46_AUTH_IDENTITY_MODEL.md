# 46. Authentication & Identity Model — v1.8

## Internal User
Production: Google Workspace OAuth only. Access requires verified `@eiu.edu.vn`, matching Active `app_users`. OAuth does not grant HR permissions by itself.

### Identity change
- `auth_user_id IS NULL`: HR with `users.directory_manage` may correct an EIU email typo.
- after bind: email/auth/provider binding is security identity; Root-only `users.identity_manage` in Phase 1.
- Root Admin identity itself changes only through documented recovery procedure.

## Candidate
Production method is **Email OTP code**. Verified email is Candidate identity; email is read-only in form/profile. Inactive Candidate cannot access Portal. OTP request/login/submission endpoints require rate limits.

### First login/provisioning
Trusted atomic provisioning: resolve current `auth_user_id`; fallback by verified normalized email; create Candidate if absent; safely bind recreated Auth identity to existing Candidate when appropriate; block inactive Candidate; audit. Frontend cannot create duplicate Candidate directly.

## Next.js/Supabase SSR
Use App Router + cookie session and the supported Supabase SSR approach for the pinned project version. Pin package versions + lockfile; CI includes auth/session regression when upgrading Supabase/Next.js dependencies.

## Internal first Google login
`provision_internal_identity_on_first_google_login()` is distinct from identity-change/rebind. Preconditions: provider Google, verified normalized `@eiu.edu.vn`, active allowlisted `app_users` exact email match, `auth_user_id IS NULL`, and current Auth ID is not bound elsewhere. It atomically binds + audits. If the directory row is already bound to a different Auth identity, reject and require Root-only recovery/rebind path.

Root Admin identity recovery is governed by `61_ROOT_ADMIN_BREAK_GLASS_RECOVERY.md`, never ordinary directory edit.
