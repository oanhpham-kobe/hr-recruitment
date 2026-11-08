# 14. Scope & Open Items — v1.18

## Business Logic
**v1.2 FROZEN.** Reopen only through Change Request or a proven contradiction.

## Design System
**v1.8 CURRENT.** Desktop foundation current; Desktop prototype must be resynced/UAT-approved. Detailed iPad/mobile design is not frozen. Candidate Portal mobile is a go-live requirement.

## Technical Architecture
**v1.18 TECHNICAL SPECIFICATION FROZEN / READY TO IMPLEMENT.** Current technical source extends through docs 99–100 and uses `source_registry.yaml` for CURRENT/HISTORICAL governance. Technical Specification Freeze is semantic/source freeze; post-coding implementation evidence is a separate gate.

## Owner decisions
Closed:
- Candidate conflict = BLOCK.
- Candidate Auth = Email OTP.
- Upload = PDF/Word/PPT/PNG/JPEG, max 5 files, max 5 MB/file.
- Current business retention = no automatic purge; capacity warning + owner-directed upgrade/archive/purge.

Official PDF pixel template is **DEFERRED** until owner supplies approved EIU template; it is not an unresolved core architecture question.

Independent Planner Review v1.0 introduced **no new HR owner decision**. v1.16 resolves gate sequencing and Copy trusted-command authority while retaining the v1.15 scheduling/storage/lifecycle fixes. The alignment is mapped in doc 97. Responsive Prototype v1.10 remains the executable visual-UAT reference against Design System v1.8 and is NOT FROZEN pending Owner Visual UAT.

## Implementation evidence required before Implementation Validation / Migration Freeze
- executable RLS/GRANT migrations + adversarial tests;
- RPC/command implementation + command coverage integration tests;
- mandatory schedule/document/concurrency race tests;
- schema migration clean-install test;
- Storage policies + two-phase upload tests;
- Auth provisioning/rebind/root-recovery tests;
- query plan/performance against NFR baseline;
- privacy publication + archive/purge runbook rehearsal;
- backup/restore rehearsal;
- responsive desktop/tablet/mobile UX/accessibility UAT using bundled Prototype v1.10 before UI visual sign-off / Production UAT.

## Future product modules — hidden in Phase 1
Dashboard; Nhu cầu tuyển dụng; Candidate Database; KPI & Reports; Offer/Approval/Onboarding automation; advanced analytics. These remain `FUTURE_HIDDEN / NOT_RENDERED` until explicitly promoted through Change Request.
