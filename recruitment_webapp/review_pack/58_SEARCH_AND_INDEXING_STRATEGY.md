# 58. Search & Indexing Strategy — v1.8

## Goal
Support HR search by Candidate/Submission Name, Email, Phone and operational filters without browser-side full scans.

## Query model
- Server-side search/pagination only for growing datasets.
- Text input debounce: 300 ms.
- Name broad search: minimum 2 characters.
- Exact/near-exact email and phone may query immediately.
- Default page size 25; options 25/50/100.

## Index baseline
Starter schema enables `pg_trgm` and includes:
- trigram GIN on `submissions.full_name`;
- lower-case email index;
- digit-normalized phone expression index;
- status/date and parent FK indexes.

For Vietnamese accent-insensitive search, implementation must choose and test one normalized strategy before performance UAT:
1. persist normalized searchable value during trusted write command; or
2. use a vetted immutable normalization wrapper/function suitable for an expression index.

Do not ship an unindexed `ILIKE '%keyword%'` full-table strategy as the only implementation for large datasets.

## Selector search
Application selector returns **Submission rows**, not Candidate-only rows. Result item includes Candidate name/email plus Submission timestamp/status and stable `submission_id`.

## URL state
Where practical, list page filters/sort/page are represented in URL query state so back/forward/share/reload are predictable. Sensitive search terms should not be copied into telemetry.

## Performance gate
Use the NFR dataset baseline and verify p95 list/search target with realistic indexes via `EXPLAIN (ANALYZE, BUFFERS)` in staging.

## Grouped pagination and PII search rule
- Application Inbox paginates Candidate groups; child submissions are included/lazy fetched under that Candidate.
- Interview and HR Report paginate Application groups.
- Stable sort always adds immutable ID tie-breaker.
- Name/email/phone search text is not persisted in URL, browser history or shareable filter links. URL may carry page/sort/status/non-sensitive filters.

## PII request transport
Name/email/phone search values are request/client state and are not serialized into browser URLs. URL may carry page/sort/non-sensitive filters only. Server logs/analytics must redact sensitive query payloads according to `67_WEB_SECURITY_BASELINE.md`.
