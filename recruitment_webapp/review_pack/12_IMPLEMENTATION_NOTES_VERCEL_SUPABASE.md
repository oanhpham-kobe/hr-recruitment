> Current technical source-of-truth is determined by `source_registry.yaml`; do not stop at a remembered numeric file range.

# 12. Implementation Notes – Vercel + Supabase

> Tài liệu này là summary. Technical source-of-truth chi tiết nằm ở `37`–`50`.

## Stack target

- Next.js App Router on Vercel.
- Supabase Postgres + Auth + Storage.
- `@supabase/ssr` cho cookie-based auth trong Next.js.
- Server Components mặc định; Client Components chỉ cho interaction cần JS.

## Auth

Internal:
- Google Workspace OAuth only;
- `@eiu.edu.vn`;
- phải map tới active `app_users`.

Candidate:
- verified email identity; email immutable;
- Candidate production auth method: **Email OTP code**; Internal: Google Workspace OAuth only.

## Data access

- RLS all exposed business tables.
- explicit GRANT/REVOKE.
- publishable key browser-safe; secret/service-role server-only.
- server-side secret calls vẫn phải tự authorize.
- complex helpers `SECURITY DEFINER SET search_path=''`, private schema, restricted execute.

## Mutations

Không để browser tự orchestration nhiều writes. Dùng transactional commands/RPC từ authenticated Server Actions.

## Views

Current Round / outcome / final decision implementation views không expose trực tiếp mặc định; đặt `private` hoặc `security_invoker` + grants/RLS khi thật sự cần.

## Storage

Private buckets, Storage RLS, MIME/size policy, authenticated/short-lived preview. Không dùng public URL cho recruitment documents.

## Vercel/React

- authenticate Server Actions như API routes;
- avoid request waterfalls; parallel independent reads;
- minimize client serialization/bundle;
- server-side pagination/search;
- filters/page/sort nên deep-link qua URL;
- preview deploy before production.

## Deployment

- local / staging / production tách biệt;
- Vercel preview có thể map Supabase preview branch nhưng phải chạy grant/RLS/trigger smoke tests;
- production PII không seed sang preview.

## Production readiness

Chưa production-ready cho tới khi pass `45_PRODUCTION_UAT_GATE.md` và owner decisions ở `50_OWNER_DECISIONS_PENDING.md` được đóng.


## Server-side implementation requirements
- Pin Next.js/Supabase package versions and commit lockfile; auth upgrade regression in CI.
- Shared schedule RPCs use mandatory transaction advisory/resource locks before conflict recheck.
- Search uses server pagination + normalized/indexed fields (`pg_trgm`/normalized strategy), not whole-table browser filtering or unrestricted `%ILIKE%`.
- Private Storage only; reserve/finalize upload protocol.
- Never expose secret/service-role credential to browser; every privileged server path re-authorizes business permission/context.

## Form-session and lifecycle implementation additions
- Candidate pre-submit/edit file state must not be stored in mutable process memory; use persisted short-lived Form Session/Storage reservation.
- Internal Google first-login binding is an authenticated transactional provisioning command, not directory edit.
- Search terms containing PII must not be put into shareable URLs; use controlled request/server action state.
- Pin Supabase SSR/auth dependencies and lockfile; include first-bind and session authorization regression tests.
- Malware scan is mandatory before promoting candidate DOC/PPT/PDF/image uploads to final private objects.
