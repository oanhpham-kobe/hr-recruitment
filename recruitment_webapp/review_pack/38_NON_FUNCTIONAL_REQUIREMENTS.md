# 38. Non-functional Requirements — Phase 1 Baseline Targets — v1.8

These are initial acceptance targets for architecture/UAT. IT may revise them before Technical Freeze through documented change control, but “TBD everywhere” is no longer allowed.

## Performance
- List/search API p95: **≤1.5 s** at 10,000 Submissions / 30,000 Interviews test dataset, excluding client network beyond normal Vietnam broadband.
- Core mutation p95: **≤2.0 s** excluding external provider delivery/upload transfer.
- Initial page shell/navigation p75: target **≤2.5 s** on normal office broadband; large table data loads independently.
- Server pagination: 25 default, options 25/50/100.
- Search debounce: 300 ms; minimum 2 characters for broad name search; exact email/phone may search immediately.
- No full-dataset browser filtering.

## Capacity baseline
- 10,000 Candidate Submissions/year baseline sizing target.
- 50 concurrent internal users, 200 concurrent Candidate sessions during spikes.
- 5 files max per Submission or Interview Session; 5 MB/file.
- Architecture should scale upward without schema redesign; capacity is not a contractual ceiling.

## Reliability / concurrency
- Atomic commands; idempotency for duplicate-prone mutations.
- Mandatory schedule resource lock + conflict recheck.
- Optimistic locking with `version_no`.
- Email Outbox separated from business transaction.

## Timezone
DB events = `timestamptz`; UI business timezone = `Asia/Ho_Chi_Minh`; date-only fields remain PostgreSQL `date`.

## Availability / backup baseline
- Application availability target for Phase 1 internal service: **99.5% monthly**, excluding approved maintenance/provider-wide incidents.
- Database target RPO: **≤24 hours** minimum; target RTO **≤8 hours**. If the purchased Supabase plan supports stronger PITR, use it.
- Storage objects require separate backup/export strategy; DB backup alone is insufficient.
- Restore rehearsal before go-live and at least annually or after material architecture change.

## Email
- Retry transient failures with bounded exponential backoff for up to **24 hours** or provider-specific equivalent.
- Permanent failure is surfaced to HR; no infinite retry.

## Logging / Audit
- Operational application logs: at least **30 days** searchable in the chosen observability platform.
- Business/security audit: **no automatic purge under current EIU business policy**; capacity monitoring applies.

## Storage/capacity warning
No automatic business-data expiry/purge. Admin capacity dashboard/alerts should support configurable thresholds; recommended initial warnings at 70%, 85%, 95% of purchased quota. EIU then decides upgrade capacity or export/archive locally and explicitly purge selected data.

## Security
HTTPS, RLS + explicit grants, server-only secrets, Candidate rate limits, CSP/security headers, dependency scanning, auth regression tests, no service-role in browser.

## Accessibility
Target WCAG 2.2 AA for supported production UI. Candidate Portal must be mobile-ready before go-live.

## Privacy, upload and grouped-pagination requirements
- PII search terms must not be stored in URL/browser history.
- Malware scan pipeline is required for production because `.doc/.ppt` from external candidates are allowed.
- Candidate form temp upload/session cleanup job must have observable backlog and alert on stale objects.
- Grouped pagination unit: Candidate for Application Inbox; Application for Interview/HR Report.
- Stable sorting always includes an immutable ID tie-breaker.
