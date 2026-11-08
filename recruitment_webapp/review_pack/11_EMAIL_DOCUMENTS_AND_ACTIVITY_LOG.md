# 11. Email, Documents & Activity/Audit Log — v1.8

## 1. Manual email actions

Page Interview keeps two manual actions:
1. **Gửi thư ứng viên / Send to Candidate**
2. **Gửi thư người tham dự / Send to Participants**

Rules:
- Preview before send.
- Send does not automatically change Interview status.
- Can send from selected table rows or individual drawer where permitted.
- Final email copy/templates are still owner input before UAT/go-live.

## 2. Transactional Outbox

Production implementation must not keep a business DB transaction open while calling an external email provider.

Pattern:

`Business command → create email_outbox → COMMIT → worker/server sender → update delivery state → create/update Email History → immutable audit`

Outbox supports:
- `QUEUED / SENDING / SENT / FAILED / CANCELLED`
- attempt number
- retry schedule
- provider message ID
- structured error
- idempotency key

This prevents duplicate **logical Outbox enqueue** on browser retry/double click and avoids partial business transactions. Provider recipient delivery remains at-least-once and can duplicate after provider-accepted/worker-crash edge case.

## 3. Email History vs Security Audit

These are intentionally separate concepts.

### Email History
User-facing operational list. Keep the frozen business behavior:
- checkbox selection;
- Delete available for wrong/test records;
- email-history records must not permanently block cleanup of test business data.

### Immutable audit
Regardless of whether a user-facing Email History row is later deleted, Security/Activity Audit retains events such as:
- send requested;
- send result;
- Email History deleted;
- who performed it and when.

Therefore operational cleanup does not destroy security traceability.

## 4. Candidate notifications

After:
- Candidate creates a Submission;
- Candidate updates a NEW Submission;

→ include HR notification Outbox enqueue **inside the same Candidate Submit/Update transaction before COMMIT**. External provider delivery occurs after commit.

Recipients are configuration/master data, not hard-coded source code.

## 5. Candidate documents

CR-DRIVE-FILES-HOSTED-20261105: the additive provider/hosted-development contract
is `102_PRIVATE_DRIVE_DOCUMENT_STORAGE.md`. Private Drive may back immutable
bucket/path aliases; contextual authorization, audit, versions and CLEAN remain
mandatory. Plugin access does not configure application OAuth or malware scanning.

Candidate document groups:
- CV — required by business form;
- Degree;
- Transcript;
- Certificate;
- Other.

Technical rules:
- private Storage bucket;
- whitelist MIME/extensions;
- per-bucket/file-size limit;
- normalized storage object key;
- metadata captured in DB;
- replacement creates a new version of the same logical document;
- no public URL persisted;
- authenticated download or short-lived signed URL only.

Production whitelist/limits are frozen: PDF, DOC/DOCX, PPT/PPTX, PNG/JPG/JPEG; max 5 files per parent; max 5 MB/file.

## 6. Interview documents

HR may upload interview/demo materials. Interviewer may preview/download only while contextual access is valid.

Candidate never receives access to internal Interview documents.

Documents are scoped to the exact Interview Session so Round 1 and Round 2 do not overwrite one another.

## 7. Preview security

Do not browser-render arbitrary active content.

Phase-1 baseline under review:
- PDF / supported image formats may preview;
- DOCX/PPTX may download or use a controlled conversion/preview flow;
- HTML, SVG, executable and archive formats are not accepted without an explicit use case/security review.

## 8. Activity/Audit events — mandatory for sensitive actions

At minimum log:
- auth success/failure where available and policy-appropriate;
- Candidate Submission create/update;
- sensitive Candidate record read where auditing is required;
- document preview/download;
- HR edit / HR Note change;
- status change;
- Application create/update/delete/inactive;
- Interview create/copy/schedule/status/delete/inactive;
- participant add/remove/reorder/restore;
- Interviewer report save/edit;
- HR editing an Interviewer report;
- Final Decision block change;
- permission grant/revoke;
- Candidate/Internal User active/inactive;
- Root Admin actions;
- PDF generation/download;
- email enqueue/send/failure/history deletion;
- conflict override/confirmation when the business rule permits an override.

Audit log is append-only and is not treated as a business usage reference for the hard-delete/inactive rule.

## 9. Audit metadata

Recommended:
- `request_id`
- `correlation_id`
- actor IDs/type
- source
- reason where relevant
- old/new values with sensitive-field redaction policy
- optional `ip_hash` / `user_agent` if approved by privacy policy

Never store passwords, OTPs, refresh tokens, OAuth provider tokens, secret keys, or signed URLs as audit payloads.


## Document, email-delivery and privacy controls
- Candidate/Interview document limits: approved PDF/Word/PPT/PNG/JPEG; max 5 files per parent; max 5 MB/file.
- Upload uses reserve/finalize two-phase flow; abandoned temp objects are cleaned asynchronously.
- System email recipients are allowlisted/derived by email type. Phase 1 system emails have no attachments; any future attachment feature requires immutable document-version references and an explicit allowlist.
- Email Outbox delivery is at-least-once with best-effort deduplication, leased worker claims and stale-SENDING recovery.
- Privacy notice acknowledgement version/timestamp is persisted per Submission.

## Phase 1 email and Candidate-document behavior
- **Phase 1 system emails do not support attachments.** Preview fields are To/CC (where applicable), Subject and Body only.
- Delivery semantics are at-least-once with idempotent enqueue + best-effort deduplication; acceptance criteria must not claim guaranteed no duplicate after provider-accepted/worker-crash edge case.
- Candidate file changes during Edit are staged in a Candidate Form Session; Save atomically applies text + document versions, Cancel leaves persisted documents untouched and cleans pending temp objects.
- New Candidate Form uploads are associated with form/upload session, not a nonexistent Submission ID.
- External legacy Office formats are allowed by owner decision, therefore malware scanning is a go-live requirement before finalization/download exposure.


## Candidate notification transaction rule
Candidate Submit and Candidate Update both create one idempotent logical HR notification linked to exact `submission_id`. Candidate mutation rate limits run before mutation; notification delivery throttling must not roll back an otherwise valid Save.

## Email History authorization and cleanup
Email History has a separate `emails.history_view` permission. Read/delete always also requires parent contextual authorization derived from `email_type`; knowing an ID is not authorization. Delete requires `emails.history_view + emails.history_delete` and one accepted cleanup classification: `TEST_RECORD` only for `environment_code=TEST`, or `WRONG_RECORD` with mandatory reason text. The cleanup classification/reason is written to immutable Security Audit before the operational history row is removed.
