# AUTH & LOGIN — v1.8

## 1. Visual direction
Retain EIU MedLabs-inspired presentation:
- desktop split campus image + login panel/card;
- clear EIU identity;
- Be Vietnam Pro;
- institutional, uncluttered tone;
- `VI | EN` at top-right.

## 2. Internal EIU user
Production direction is **Google Workspace OAuth only**:
- Root Admin / HR / Interviewer;
- email must be `@eiu.edu.vn`;
- user must already exist and be Active in `app_users`;
- successful Google authentication alone does not grant application access;
- role/permission/context is resolved after Auth.

If the authenticated Google identity is not allowlisted/Active, show a clear access-denied/support state.

Internal email change is not a normal profile text edit; it uses the technical Identity Change flow.

## 3. Candidate
- email is verified Auth identity and immutable in application profile/forms;
- inactive Candidate cannot enter Portal;
Candidate production login is **Email OTP code**. Do not expose Magic Link as an alternate production method unless a later change request reopens Auth UX.

## 4. SSR implementation implication
Next.js implementation uses Supabase server-side cookie sessions. UI must tolerate auth refresh/redirect/loading states and not infer authorization from client-only state.

## 5. Typography
- labels/input/button/body >=16px;
- helper 14px allowed;
- clear focus/error/disabled/pending states.

## 6. Errors/states
Design states for:
- Candidate inactive;
- Internal user not provisioned;
- Internal user inactive;
- wrong/non-EIU Google account for internal portal;
- expired/invalid Candidate OTP;
- rate-limited retry;
- temporary system/Auth error.

Avoid disclosing unnecessary account existence details on public Candidate flows.

## 7. Responsive
Candidate Login must be mobile production-ready before go-live. Internal login should still work on tablet/mobile even if the HR operational pages remain desktop-first.


## Current internal first-bind state — v1.8
For an Active allowlisted Internal User whose directory row is `Unbound`, first verified Google login performs an atomic first-bind. UI errors distinguish `Not provisioned`, `Inactive`, `Identity already bound elsewhere`, and generic Auth failure. Bound identity change is never offered in normal login/directory UI.
