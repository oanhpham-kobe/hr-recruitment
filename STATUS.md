# STATUS — EIU Recruitment

Feature map and open items. Git and CI are the authority for exact code state;
update this file when a feature changes status.

Baseline: imported on 2026-11-08 from the previous repository, branch
`codex/drive-files-hosted-deployment-20261105` at `7aa68cc`, which contains
every earlier integration, recovery and feature branch. Full Integration CI
(web and database) passed on that exact SHA (previous repository, run
`42438133424`). The previous repository is the archive for task history,
review evidence and superseded specification versions.

Business model: Candidate → Submission → Application (Department + Major/Team +
Position) → interview rounds → reports. Roles: Root Admin, HR, Interviewer,
Candidate.

## A. Done and accepted

| Module (route) | Scope |
|---|---|
| Sign-in (`/login`, `/auth/*`) | Candidate email OTP; internal Google Workspace sign-in with first-login provisioning |
| Candidate portal (`/candidate`) | Form session, privacy notice, autosave, up to 5 files × 5 MB, submit and update |
| HR inbox (`/`) | Grouped table, search and filters, indexed pagination, detail drawer, HR notes, document preview, Application creation, bulk status and assignment, candidate lifecycle, HR submission editing |
| Interviews (`/interviews`) | Rounds, schedule conflict locking, participants, schedule copy, Application reactivation |
| Reports (`/reports`) | Interviewer own report, HR report management, final decision |
| Master data (`/master-data`) | 11 catalogs with lifecycle and reference history |
| Users & permissions (`/users`) | Internal directory, HR RBAC, identity lifecycle |
| Email, documents, workers | Email outbox and history, document scan protocol, storage cleanup runner. Contracts and code only: no real email provider or malware scanner is connected |
| Design system | Tokens, responsive shell, UI primitives, design-contract lint, browser acceptance gate |

## B. In the code, not yet formally accepted

| Feature | State | Next step |
|---|---|---|
| Internal interview feedback (`/interview-feedback`) | Questionnaire versions, per-round assignments, drafts and submission, HR consolidation and approval, printing. Independent local review passed | Owner acceptance |
| Recovery 009 — residual deadlock repairs | Product repair included; database CI on this baseline passes | Owner acceptance |
| UniCouncil-style UI refresh | Local review passed | Owner visual UAT |

## C. In progress

| Feature | Missing |
|---|---|
| Private Google Drive document storage | Owner decision 2026-11-10: Drive is the only store for new files and Drive's own malware scan is the verdict source (doc 102, CR-DRIVE-NATIVE-SCAN-20261110). Database layer, gateway worker (wrangler build, every-minute cron), browser upload/preview/download transport and the `/api/cron/storage-cleanup` route are in code with unit tests. Missing: hosted deployment, OAuth credentials, AC-DRIVE-05 evidence, EICAR test, worker CPU measurement on the Cloudflare free plan. Interview documents have no Drive binding yet |
| Email delivery | Owner decision 2026-11-10: Gmail API of the EIU Workspace (doc 43). Delivery runner, Gmail provider, `/api/cron/email-delivery` and the `email_worker` runtime binding migration are in code with unit and SQL tests. Missing: OAuth credentials, hosted `private.email_configuration` (delivery is paused by default), a real send on staging, Owner-approved email copy |
| Search / performance / ops / release hardening | Indexed inbox search done; the remaining release-hardening work is not yet specified |

## D. Before production

- data retention, archive and purge implementation;
- CSV export formula-injection hardening;
- production scanner operations and session resilience;
- candidate OTP rate limiting behind shared NAT/proxy;
- candidate PII and data-minimization readiness;
- SLOs, alerts, backup and restore rehearsal;
- production UAT (`recruitment_webapp/review_pack/45_PRODUCTION_UAT_GATE.md`).

Hidden in Phase 1 by design: dashboard, recruitment requests, candidate
database, KPI reports, offer/approval/onboarding.

## E. Environments

- Supabase development project `eiu-recruitment-dev` (region `ap-southeast-1`):
  foundation migrations applied; later migrations not yet applied there.
- Vercel staging deployment exists; production is not configured.
- Owner-supplied official PDF/report templates are still pending.
