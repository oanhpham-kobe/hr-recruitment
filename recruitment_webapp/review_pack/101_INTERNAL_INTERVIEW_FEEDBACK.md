# 101. Internal interview feedback and consolidated report — local first

## Controlled source change

CR-INTERVIEW-FEEDBACK-20261105. Owner explicitly requested implementation on
05/11/2026 and selected the existing qualitative questionnaire for the first
trial. This additive contract promotes that feature from the research plan.
It does not reopen legacy report precedence, status derivation, scoring, the
official PDF layout, candidate dossier scope, or production readiness.

## Scope and roles

Canonical command and acceptance indexes are updated in `command_registry.yaml`,
`37_BACKEND_COMMAND_CONTRACTS.md`, `55_COMMAND_COVERAGE_MATRIX.md` and
`13_ACCEPTANCE_CRITERIA_AND_TEST_CASES.md` (AC-IF-01 through AC-IF-07).
Persistence is an additive migration extension: private
`interview_feedback_templates`, `interview_feedback_collections`,
`interview_feedback_invitations`, `interview_feedback_notification_intents`, and
`interview_feedback_consolidations`. Legacy declarative schema definitions retain
their meaning; executable new definitions live in the forward migration
`20261104221450_internal_interview_feedback.sql`.

- An active, bound internal identity is required; `@eiu.edu.vn` alone is never
  authorization. Use the existing internal session and permission predicates.
- HR management requires `interviews.manage` AND `reports.view` (or the existing
  Root permission semantics). An interviewer may read/respond only to their own
  invitation while still assigned to the exact interview participant.
- Link each collection to the exact Application / Interview round and a frozen
  template version. One collection per interview is sufficient for this first
  release. A retry must return the existing collection, never duplicate it.
- Creation and response writes require an active parent, current round,
  visible/access-active interview, non-final status, and active assigned users.
  Recheck authorization/context after acquiring shared lifecycle locks.
- Historical own responses may be read while still assigned; removing an
  assignment or disabling an identity revokes access. HR reads require current
  permission. Never expose another interviewer's answers to an interviewer.

## Questionnaire

- Seed a trial template from the five existing qualitative fields: Professional
  Knowledge; Necessary Skills; Qualities and Personality; Strengths and
  Limitations; Other. All five remain optional. No ratings, scores, or inferred
  final decisions. Three legacy final-decision fields remain on the legacy report.
- HR can publish a new named version containing ordered plain-text questions
  and a required flag. Published versions are immutable; editing publishes a new
  version, and existing collections continue using their original version.
- Bound question count/length and answer length, reject unknown question keys,
  and render all content as escaped text. No arbitrary HTML or template code.

## Collection and responses

- HR chooses an exact interview and a nonempty set of its current participants,
  a template, and optionally a deadline. Show the exact candidate/round before
  creating the collection. Share only name, applied position/unit, round/date.
  Do not expose personal contact details, HR notes, CVs, or other answers.
- Creation atomically persists one invitation per chosen participant plus a
  provider-paused local notification intent. Show `Queued — delivery not
  configured`; do not label it sent or invoke an external mail provider.
  Local notification persistence is not evidence of production email delivery.
- Invitations have an opaque UUID link with no PII or bearer authorization.
  The existing Google login and internal redirect boundary remain authoritative.
- Save draft and submit require optimistic version checks. Submit validates
  required questions and is atomic with audit. Submitted answers are immutable
  in this release; no implicit reopen or overwrite. Repeated identical submit
  must not create another response or audit event.
- HR can revoke an outstanding invitation with a version check and audit.
  Revoked/removed/inactive participants never silently disappear from the
  confirmed denominator. A revoked or unavailable participant blocks final
  consolidation; the UI must explain why. No waiver or partial approval yet.
- A deadline is displayed and enforced for response writes when configured.
  Do not introduce automatic reminders or outbound mail in this local release.

## Consolidated report

- HR may create a draft only when every originally chosen evaluator has a valid
  submitted response and remains authorized by the collection context.
- Freeze the exact template/questions, candidate allowlist, interview/round,
  evaluator names, answer versions and submission times in the report snapshot.
  Group answers by question, retaining attribution and empty-answer meaning.
- HR can set a plain-text report title and overall summary in the draft, then
  approve with an optimistic version check and audit. Approval is immutable.
  Recheck completeness and context at approval; no stale optimistic approval.
- The first report layout is a configurable title/summary plus the complete
  attributed questionnaire. Show it as a print-friendly page. Browser print / save
  as PDF is a local convenience; an official Word/PDF template is deferred until
  Owner supplies it. Do not claim a server PDF export exists.
- No automated summarization, selection outcome, Final Decision Source update,
  legacy report mutation, or Candidate/Application status change.

## Verification and preview

Prove cross-user/raw-table isolation, exact-round identity, template immutability,
stale draft/approval conflicts, idempotent creation/submission, required questions,
deadline/revocation/lifecycle rejection, correct completion denominator and pinned
attribution with actual local PostgreSQL tests. Exercise browser creation,
draft/reload/submit, tracking and consolidation, including keyboard/mobile use.
Any synthetic preview must be separate from production authentication; no auth
bypass or privileged database credential may be shipped to a browser.

This authorizes local implementation and verification only. Existing recovery
acceptance gates, hosted services and production deployment remain separate.
