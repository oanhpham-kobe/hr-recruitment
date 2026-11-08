# 43. Email Delivery Specification — v1.8

## Delivery semantics
Business transaction inserts an Outbox row and commits. Worker delivers later. Do **not** claim exactly-once delivery. Target semantics: **at-least-once delivery with idempotent enqueue + best-effort/provider-assisted deduplication**.

## Outbox lease fields
`locked_at`, `locked_until`, `worker_id`, `attempt_no`, `next_attempt_at`, `last_error`, `provider_message_id`. Worker claims with `FOR UPDATE SKIP LOCKED` or equivalent, supports stale-SENDING recovery and bounded retry.

## Enqueue
Candidate Submit/Update notification is enqueued in the same business transaction as Submission change; frontend never performs a second independent “send” call for required system notifications.

## Recipient allowlist
System email recipients derive from the referenced Candidate/Participant/entity and email type. Arbitrary recipient override requires a separately authorized manual-email capability.

Phase 1 has no system-email attachments. A future attachment feature requires a separate change request with immutable document-version references and attachment-class allowlists.

## User-facing history
Frozen business rule remains: HR may delete wrong/test Email History. The immutable audit still records send/delete activity.

## Provider
Production uses approved custom SMTP/provider with SPF/DKIM/DMARC. Auth OTP and recruitment operational email may share infrastructure but have separate templates/rate limits/telemetry.

## Phase 1 attachment policy
System-generated email attachments are **deferred beyond Phase 1**. Outbox does not resolve mutable logical documents for sending. Preview and send use recipient/subject/body only.

Delivery guarantee wording: **at-least-once with idempotent enqueue and best-effort deduplication**. A provider-accepted email followed by worker crash before `SENT` persistence may be delivered twice unless the selected provider offers its own idempotency guarantee.

## Retry and delivery semantics
Two retry layers are distinct:
1. **Client/API retry:** same logical idempotency scope/key must not create a duplicate logical Outbox row.
2. **Worker/provider delivery retry:** remains at-least-once. Provider-accepted mail followed by worker failure before local `SENT` persistence can result in duplicate recipient delivery.

Specifications and acceptance tests must use “prevent duplicate logical enqueue” for layer 1 and must never promise exactly-once recipient delivery for layer 2.

Candidate Submission notification rows carry nullable `submission_id` so a Submit/Update email is traceable to the exact Submission even when one Candidate has many historical Submissions.

## Stale preview / outbox guard
Preview và send email nghiệp vụ/lịch phỏng vấn bắt buộc bind với phiên bản dữ liệu và danh sách participant chính xác. Nếu lịch hoặc danh sách người nhận thay đổi trước khi enqueue/send, outbox không được gửi dữ liệu cũ; lệnh phải kiểm tra fingerprint/version tại ranh giới enqueue/send.

## Non-production environment safety
Môi trường non-production (DEV/Local/CI) mặc định an toàn: environment code là `TEST`, **tuyệt đối không hardcode `'PRODUCTION'` trong các RPC nghiệp vụ**. DEV và CI không được gửi email tới người nhận thực bên ngoài trừ khi có cấu hình trusted riêng biệt.

