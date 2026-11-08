# 67. Web Security Baseline — v1.8

This is the production target behavior for Vercel/Next.js + Supabase. Framework syntax may differ, but evidence must prove the behavior.

## Transport and headers
- HTTPS only. Production HSTS target: `max-age=31536000; includeSubDomains` after domain readiness is verified.
- `Content-Security-Policy`: default deny-by-omission; baseline includes `default-src 'self'`, `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'none'`, `form-action 'self'`; script/style/connect/img/font sources are allowlisted for the pinned app/Supabase/Vercel assets actually used. Prefer nonce/hash-compatible CSP rather than `unsafe-inline` where feasible.
- `X-Content-Type-Options: nosniff`.
- `Referrer-Policy: strict-origin-when-cross-origin` or stricter.
- `Permissions-Policy`: deny camera/microphone/geolocation and other unused powerful features.
- Clickjacking protection: CSP `frame-ancestors 'none'`; `X-Frame-Options: DENY` fallback where supported.

## Cookies/session
Auth/session cookies: Secure in production, HttpOnly when managed server-side, appropriate SameSite (normally Lax unless a verified OAuth flow requires otherwise), scoped Path/Domain, no secrets in browser storage.

## CSRF / origin
Cookie-authenticated state-changing Server Actions/RPC/API routes validate authenticated session plus same-origin/approved Origin/Host semantics. Do not rely on SameSite alone for privileged mutations.

## CORS
No wildcard CORS for credentialed recruitment APIs. Allow only explicit production/staging origins that need browser access.

## Sensitive caching
PII HTML/API/RPC/file metadata responses default `Cache-Control: private, no-store` unless a reviewed safer exception exists. Private file URLs are short-lived; no shared CDN cache of authenticated PII responses.

## Logging/error redaction
Do not log OTP, session cookies, access/refresh tokens, secret keys, raw CV content, full document URLs with signatures, or unnecessary PII search terms. Production errors return stable codes; sensitive internals stay server logs with redaction.

## Test evidence
Automated header tests, CSRF/origin negative tests, CORS tests, cookie flags, cache-control tests, log-redaction tests and security scan evidence are Production UAT gates.
