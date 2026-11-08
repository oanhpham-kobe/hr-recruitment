# 41. Storage & Upload Security — v1.8

## Approved file policy
- PDF: `.pdf`
- Word: `.doc`, `.docx`
- PowerPoint: `.ppt`, `.pptx`
- Images: `.png`, `.jpg`, `.jpeg`
- **5 MB maximum per file**
- **5 current files maximum per Submission and per Interview Session**
- Candidate form: CV required; Degree/Transcript/Certificate/Other optional.

Reject HTML, SVG, executable, script, archive and unapproved formats. Extension alone is insufficient: validate claimed MIME and content signature/magic bytes where feasible.

## Buckets
CR-DRIVE-FILES-HOSTED-20261105: `102_PRIVATE_DRIVE_DOCUMENT_STORAGE.md` extends
bucket/path into immutable logical identities backed by a private provider
binding. Existing Supabase storage remains the default until Drive is configured.
This does not change upload limits, mandatory CLEAN, locks, retention or audit.

Private buckets only. No public CV/degree/report/demo URL. Browser gets short-lived authorized signed URL; initial target TTL 1–5 minutes for sensitive documents.

## Two-phase protocol
1. `reserve_upload` authorizes actor, parent, intended type/count/size and creates temp/quarantine path.
2. Client/server uploads object to temp path.
3. Validation verifies extension/MIME/signature/size and **mandatory production malware scan** before final promotion.
4. Lock parent, enforce max current files, insert metadata/version atomically, switch current version, retire previous version.
5. Async cleanup removes expired/orphan temp objects.

DB rollback cannot rollback Object Storage, so direct “upload then hope metadata insert succeeds” is prohibited.

## Preview/download
PDF/image may preview in hardened same-origin viewer where safe. Word/PPT normally download unless a vetted converter/viewer is added. Never inline-render arbitrary HTML/SVG.

## Path/metadata
Server-generated object key; preserve original filename only as metadata; normalize header/content-disposition; unique bucket/path; checksum when available.

## Candidate staged upload/edit protocol
1. Open short-lived Candidate Form Session (NEW or EDIT); persisted lifecycle is `OPEN → SUBMITTED | CANCELLED | EXPIRED` only.
2. Reserve temp/quarantine path against Form Session; no Submission ID is required for a new form.
3. Validate extension + declared/detected MIME + magic bytes + 5 MB limit.
4. Run malware scan; because DOC/PPT are allowed, `CLEAN` is mandatory before finalization.
5. Candidate document ADD/REPLACE/DELETE remains pending in form session; stage requires Form Session `OPEN` and unexpired, and ADD/REPLACE reservation unexpired.
6. Submit/Save locks parent/session, synchronously re-checks Form Session `OPEN` + unexpired, Candidate active + Submission NEW for edits, calls the authoritative staged-plan validator (`private.validate_candidate_form_document_plan()` or its migration-equivalent), validates max 5 effective current files + required current CV + every staged ADD/REPLACE as unexpired + `VALIDATED/CLEAN`, then atomically writes logical headers/versions and marks staged changes applied.
7. Cancel/expiry cleans pending objects; persisted current versions remain unchanged. Async cleanup is housekeeping only; wall-clock expiry blocks Stage/Save/Submit/Finalize synchronously.
8. Image EXIF/geolocation metadata is stripped where practical before final object promotion.

Logical model uses a header (`submission_document_logicals` / `interview_document_logicals`) that fixes parent + `document_type_id`, and version rows cannot switch parent/type. Bảng `submission_document_logicals(submission_id, document_type_id)` **KHÔNG PHẢI là unique constraint**; nhiều file cùng loại (ví dụ nhiều chứng chỉ) được phép tồn tại trong hạn mức max 5 files. Staged `ADD` luôn tạo một logical document header mới; staged `REPLACE` và `DELETE` bắt buộc trỏ tới `logical_document_id` cụ thể đã có. Client/browser **tuyệt đối không tự sinh reservation ID hay temp object path** mà phải qua lệnh server có thẩm quyền `reserve_candidate_form_upload`.

## Interview reservation / hard-delete protocol
- `upload_reservations.interview_id` is a real FK to `interviews(interview_id)` with `ON DELETE RESTRICT`; an Interview reservation cannot reference a nonexistent parent.
- Interview hard-delete must lock parent + reservations, durably insert each temp bucket/path into `storage_cleanup_queue`, then cancel/remove reservation rows before deleting the Interview.
- Durable cleanup-capture failure blocks the hard-delete. The Storage cleanup worker may run later, but the cleanup intent must already survive the parent deletion.
- `is_structurally_empty_default_round()` remains a business-history predicate; temp reservations are a separate **cleanup prerequisite**, not a reason to pretend the Round has meaningful recruitment history.
- FK cascade is forbidden for Interview reservations because PostgreSQL deletion cannot remove the corresponding Object Storage object transactionally.
