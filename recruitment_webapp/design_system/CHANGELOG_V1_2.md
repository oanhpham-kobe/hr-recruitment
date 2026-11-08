# Changelog — Design System v1.2

## 02/09/2026

Updated after owner UI review + Vercel/Supabase technical cross-check.

Changes:
- formalized wide-table `min-width + overflow-x:auto` pattern;
- Page Header/Toolbar stay outside horizontal table scroller;
- sticky table header requirement clarified;
- retained semantic `<table> + <colgroup>` and 16px typography;
- full-row pointer expansion + `stopPropagation` for child controls;
- added semantic keyboard expand control requirement;
- added URL-state / locale formatting guidance;
- clarified no-scoring Report behavior and one-representative Final Decision UX;
- added prototype-only Demo Persona Switcher specification;
- internal Login frozen to Google Workspace OAuth UI direction;
- Candidate auth remains owner decision (OTP recommended vs Magic Link);
- Candidate mobile portal elevated to go-live UI requirement;
- added Vercel/Next.js implementation guardrails;
- official PDF layout remains owner-template dependent.
