# 68. Rate Limit Policy — v1.8

Initial defaults are configuration, not immutable business rules. Security/load testing may tune them before go-live while preserving the strategy and auditability.

| Action | Primary key | Secondary key | Initial default | Response |
|---|---|---|---|---|
| Candidate OTP request | normalized email | client IP | 5 / 15 min per email; 20 / 15 min per IP | 429 + Retry-After |
| OTP verify | auth/session/email | client IP | 10 / 15 min identity; 50 / 15 min IP | 429 + Retry-After |
| Candidate Submit | candidate_id | IP | 5 / hour; 20 / day | 429 |
| Upload reserve/finalize | candidate/app_user | IP | 30 / 15 min identity; 100 / 15 min IP | 429 |
| Internal search | app_user_id | — | 120 / min | 429 |
| Manual/system email enqueue | app_user_id + email_type | entity | 60 / hour; burst 10 / min | 429 |
| PDF generation | app_user_id | entity | 20 / hour | 429 |

## Implementation rules
- Use provider-native/distributed durable counters suitable for multi-instance Vercel execution; never in-process memory only.
- Resolve trusted client IP only through approved proxy/platform headers; do not trust arbitrary forwarded headers.
- Rate-limit decisions do not replace Auth/RLS/permission checks.
- OTP provider limits may be stricter; the effective limit is the stricter bound.
- Security Audit records repeated abuse/blocks without storing secrets.
- Staging includes burst, distributed-instance and bypass/forged-header tests.


## Candidate Update / system notification
| Endpoint/action | Primary key | Default | Behavior |
|---|---|---:|---|
| Candidate Update Save | `candidate_id + IP` | 30 / 15 min | `429 + Retry-After` before mutation execution; no partial Save |
| Candidate system HR-notification enqueue | `candidate_id + submission_id + email_type + mutation idempotency key` | idempotent per successful Save | Delivery throttle must not roll back valid Candidate Save; Outbox enqueue is transactional and provider delivery asynchronous |

## Candidate Update system-side-effect rule
Candidate Update uses the Candidate mutation endpoint limit keyed by Candidate identity + IP/session according to the table above. The exact-Submission HR notification is a committed system Outbox side effect; downstream email throttling/coalescing must not roll back a valid Candidate Save. Provider delivery rate controls act asynchronously after commit.
