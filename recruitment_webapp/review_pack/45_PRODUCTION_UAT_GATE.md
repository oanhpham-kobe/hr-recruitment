# 45. Production UAT Gate — v1.8

Không go-live nếu còn P0/P1 security/data-integrity blocker.

## A. Business regression

- Candidate → Submission → Application → multi-round Interview → Report → final outcome.
- Multiple Applications.
- Delete/Inactive.
- permission variants.
- VI/EN.
- current round/PDF.
- decision source based on `decision_updated_at`.

## B. Auth/RBAC

- Candidate cannot access another Candidate.
- HR limited cannot call forbidden RPC even via devtools/direct request.
- Interviewer cannot access non-participant records.
- Inactive user blocked.
- Root Admin protected.
- service-role never present in client bundle/network.

## C. RLS/View/Grant

Test all SELECT/INSERT/UPDATE/DELETE/RPC combinations by persona.

Verify private/security-invoker views do not leak rows.

## D. Schedule

- interviewer conflict block;
- room conflict block;
- Candidate conflict blocking;
- race: 2 HR save overlapping schedule simultaneously.

## E. Concurrency

- HR vs HR stale block;
- same Interviewer multi-tab stale block;
- HR vs Interviewer different fields merge safely;
- same field conflict follows Interviewer-wins rule;
- qualitative edit does not change Final Decision Source;
- decision-field edit does.

## F. Storage

- forbidden MIME/size block;
- block 6th current file and >5 MB file;
- reserve/finalize/orphan cleanup test;
- Candidate path isolation;
- Interviewer document isolation;
- inactive access block;
- signed/authenticated preview expiration/access tests;
- malware scanning is mandatory: `PENDING` cannot finalize; `INFECTED` rejects; `ERROR`/scanner unavailable fails closed under defined retry; only `CLEAN` is eligible.

## G. Email

- outbox idempotency;
- retry temporary failure;
- permanent failure visible;
- no duplicate enqueue on refresh/double click; provider retry semantics tested/documented as at-least-once;
- deleted user-facing History still leaves audit event.

## H. Responsive

Before go-live:
- Candidate Login/Form/Phiếu của tôi mobile-ready;
- internal HR target viewport documented;
- keyboard/focus/a11y smoke tests.

## I. Recovery

- DB restore test PASS;
- Storage recovery test PASS;
- root admin recovery procedure tested without weakening normal protections.

## J. Compliance

- privacy notice approved;
- current no-auto-purge policy + capacity/archive procedure approved; legal review confirms any mandatory retention/deletion obligations;
- data request/purge process documented;
- vendor/data-location review approved if required.


## K. Technical conformance
- Schema Conformance Matrix matches migrations.
- Command Coverage Matrix has no unmapped production mutation.
- Package validator fails closed when a source parser unexpectedly returns zero expected values.
- Search/index performance meets NFR baseline using realistic staging data.
- Status color contrast meets WCAG 2.2 AA for normal 16px text.

## Candidate Form, concurrency and identity gate checks
- [ ] Pre-submit upload works without pre-creating Submission.
- [ ] Candidate Cancel after staged replace/delete leaves persisted current documents unchanged.
- [ ] Malware scan blocks INFECTED/ERROR/not-clean file finalization.
- [ ] Concurrent Submission outcome changes produce correct derived status.
- [ ] Concurrent reschedule/add-participant race test passes.
- [ ] First Google login binds only exact active allowlisted unbound internal user.
- [ ] Root break-glass recovery rehearsed with audit evidence.
- [ ] Referenced master structural changes are rejected; inactive historical references remain operable.
- [ ] Grouped pagination does not split Candidate/Application groups.
- [ ] System emails contain no attachments in Phase 1.


## L. Browser / click-path / accessibility evidence
Run staging evidence at 375, 768, 1280, 1440px per `75_RELEASE_EVIDENCE_MATRIX.md`. Evidence includes axe plus keyboard-only journeys, focus visibility/return, screen-reader form/landmark sanity, 200% text zoom without functional loss, and 400% reflow where WCAG SC 1.4.10 applies. Wide semantic data tables may intentionally retain two-dimensional scrolling. Missing visual baseline = `INCONCLUSIVE`, not PASS.

## Scanner fail-closed evidence
Production malware scanning is mandatory, not feature-optional. UAT must evidence: `PENDING` cannot finalize; `INFECTED` rejects; `ERROR`/scanner unavailable fails closed with controlled retry/recovery; only `CLEAN` is eligible for finalize. There is no production bypass for accepted Candidate/Interview files.

Privacy Notice publication/current-switch rehearsal follows `78_PRIVACY_NOTICE_PUBLICATION_RUNBOOK.md`; production evidence must show no unintended no-current/effective gap.
