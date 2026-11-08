# UI Implementation Notes — Next.js / Vercel

These notes translate the current Design System into implementation guardrails. They do not replace Technical Handover security/RPC rules.

## 1. Server-first
- Next.js App Router.
- Prefer Server Components for read-only/server data composition.
- Use Client Components only where interaction/browser state requires them.
- Never store request/user data in mutable module-level state.

## 2. Server Actions
Treat every Server Action as a public mutation endpoint:
- authenticate;
- authorize;
- validate;
- call the approved transactional command/RPC;
- return structured result/errors.

Hidden/disabled buttons are UX only.

## 3. Avoid waterfalls
Start independent server reads early and resolve them in parallel where dependencies allow.
Examples:
- current user permissions + independent lookup/master data;
- page records + independent filter catalogs;
- Drawer documents + independent metadata if authorization boundary permits.

Do not parallelize dependent transaction steps.

## 4. Client bundle
- avoid shipping full master catalogs/permission maps when a page needs a subset;
- direct imports where practical;
- lazy/dynamic load heavy PDF/document preview UI;
- server-side pagination/search for growing tables.

## 5. Navigation/state
Represent shareable operational state in URL query params where appropriate:
- page;
- sort;
- filters;
- active tab.

Do not put sensitive values in URLs.

## 6. Async UX
- stable loading layout;
- accessible error/success messages;
- double-click/pending button protection;
- frontend optimistic UX never replaces backend idempotency/conflict checks.

## 7. Deployment UX testing
Preview deployments are for review; final security/UAT must use an isolated staging environment and the Technical Handover gate. Demo Persona Switcher remains non-production only.
