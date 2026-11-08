# REVIEW.md — EIU Recruitment Review Contract

## Purpose

This file defines project-specific review priorities and reject conditions. It complements OMP's native reviewer; it does not implement a separate review runtime.

Always review against the **current canonical project sources** and the exact implementation diff. If this file conflicts with a current canonical source, the canonical source wins and this file should be corrected.

---

## 1. Review order

Review in this order:

1. current-source conformance;
2. security and authorization;
3. data integrity, concurrency, and idempotency;
4. privacy and private-document handling;
5. database/migration safety;
6. functional correctness and boundary safety;
7. accessibility and UI contract;
8. performance/reliability;
9. maintainability and unnecessary complexity;
10. workflow/tooling safety.

A lower-priority improvement must never introduce a higher-priority regression.

---

## 2. Reviewer execution contract

Use OMP's built-in reviewer or `.omp/agents/eiu-reviewer.md`.

The reviewer is read-only. It must:

- start from the exact diff/SHA under review;
- read the affected implementation and relevant consumers;
- read the canonical source sections governing the behavior;
- inspect affected tests, migrations, schema, and trust boundaries where relevant;
- use OMP-discovered specialist skills on demand through `skill://<name>` when they materially help;
- confirm material graph/tool findings against direct source;
- report only evidence-backed, actionable findings.

Do not require a synthetic skill-usage receipt. The review target is the resulting behavior, code, tests, and evidence.

A subagent's `completed` status or self-reported success is not acceptance evidence.

The candidate producer's self-review (including ChatGPT self-review) is a useful first quality gate but is not the independent OMP acceptance review. The OMP reviewer must remain a separate read-only reviewer bound to the exact candidate SHA.

If a repair creates a new SHA, re-review the new SHA; do not carry a PASS forward from the previous candidate. Previously passed areas remain closed unless changed code, a changed dependency/shared invariant, or concrete regression evidence justifies reopening them.

A review wave may cover at most two independent task candidates, but the reviewer must return a separate exact-SHA verdict and findings set for each. A PASS on one candidate never masks blockers in the other.

The reviewer must not create or move Git refs or mutate implementation. Review results are recorded on the pull request for the exact reviewed SHA.

When serialized integration produces a different SHA from the reviewed candidate, perform a targeted exact-SHA acceptance re-review/equivalence check on the integration SHA before acceptance CI. That re-review confirms the reviewed implementation delta is preserved, no unauthorized integration drift was introduced, and all blocking findings remain closed. If integration preserves the exact candidate SHA, the candidate review can serve as the final acceptance review.

---

## 3. Finding dispositions

Every material finding should resolve to one of:

- `BLOCKING_REPAIR` — a current defect is proven and the repair is knowable;
- `NEEDS_SOURCE_DISCOVERY` — current source/runtime evidence is genuinely insufficient;
- `OWNER_DECISION_REQUIRED` — a real business/product/policy/privacy/scope/production authorization decision is required;
- `CLOSED_AS_DESIGNED` — behavior matches an explicit current decision;
- `DEFER_UNTIL_FEATURE` — valid concern whose triggering feature does not exist yet;
- `DEFER_UNTIL_PREPROD` — valid release/operational concern with a later exit condition;
- `STALE_OR_NOT_APPLICABLE` — current evidence proves the finding is superseded or irrelevant.

Do not bounce a knowable repair back as vague investigation. Do not escalate ordinary technical choices that current source and implementation evidence can resolve.

---

## 4. Current-source conformance — BLOCKER

Reject when implementation:

- invents behavior without source support;
- follows stale plans/prompts instead of current source;
- reopens settled product/business rules without authorization;
- changes entity ownership, status semantics, permissions, deletion/inactive behavior, or derived-state rules contrary to current source;
- lets a generic skill or framework pattern override project-specific behavior;
- contradicts the current design/accessibility source.

---

## 5. Security and authorization — BLOCKER

Reject if:

- authorization exists only in the UI;
- hidden/disabled controls are treated as security;
- a mutation endpoint/Server Action/RPC path fails to authenticate and authorize server-side;
- client-supplied role, permission, ownership, actor, or status is trusted when it must be server-derived;
- service-role or secret credentials reach browser code;
- RLS or grants are broadened merely to make a feature work;
- privileged functions expose more execute privilege than required;
- `SECURITY DEFINER` usage lacks controlled search path and authorization reasoning;
- sensitive output/logging exposes secrets, tokens, signed URLs, PII, or private-document content.

For mutation paths verify the effective sequence where applicable:

```text
authenticate
→ authorize
→ validate
→ transactional command/RPC
→ stable safe result/error
```

---

## 6. Supabase / PostgreSQL — BLOCKER or HIGH

For affected database work verify:

- migration order remains valid from a clean database;
- declarative schema and ordered migrations agree where both are maintained;
- constraints encode durable invariants where appropriate;
- RLS and grants are both reviewed;
- indexes support required operational/query paths;
- locking order is deterministic where concurrency requires it;
- state is re-read/revalidated after required locks;
- optimistic version checks and idempotency are enforced where specified;
- rollback cannot leave partial business state;
- privileged routines revoke public/anonymous execution as required;
- database findings are grounded in repository SQL, not graph absence or remote MCP state.

Use the `supabase` and `supabase-postgres-best-practices` skills when the review scope needs their specialist guidance.

Supabase MCP is supporting inspection only. Repository migrations/schema remain authority.

---

## 7. Authentication / OAuth — BLOCKER

Verify where relevant:

- Google/Supabase authentication is separated from application authorization;
- OAuth Client Secret and provider/session tokens remain server-side;
- callback/redirect targets are allowlisted and cannot become open redirects;
- SSR/PKCE session exchange follows the installed/current Supabase guidance;
- access predicates such as active state, account binding, permissions, and contextual authorization are enforced server-side;
- provider access/refresh tokens are not persisted unless an approved feature actually needs Google APIs beyond login.

---

## 8. Concurrency and business integrity — BLOCKER

Reject if:

- required validation and write are separated without required lock/recheck;
- conflict detection occurs outside the authoritative transaction;
- stale whole-row writes can overwrite newer state;
- duplicate prevention exists only in UI;
- sequence/round/resource allocation omits required locking;
- aggregate/derived state is recalculated outside its authoritative transaction;
- retry-prone operations omit required idempotency;
- historical/current-row selection rules can race with the mutation.

Concurrency tests should exercise meaningful competing operations, not only happy-path serial execution.

---

## 9. Privacy and private documents — BLOCKER

Reject if:

- private documents are made public for convenience;
- one user/context can access another unauthorized user's files;
- long-lived signed URLs are persisted or logged;
- required upload validation/finalization/scanning state is bypassed;
- sensitive content or credentials are logged;
- retention/purge semantics are invented outside current source.

Verify authorization before issuing preview/download access and keep signed access short-lived.

---

## 10. TypeScript and trust boundaries — HIGH

Reject:

- unjustified `any` across trust-sensitive boundaries;
- unvalidated untrusted payloads;
- direct casts from client/network data into trusted domain types;
- client control of server-derived security fields;
- swallowed errors that hide a failed business/security operation;
- unsafe serialization of sensitive server data into Client Components.

Prefer explicit types, `unknown` plus validation at trust boundaries, and stable machine-readable error codes.

---

## 11. React / Next.js / UI — HIGH

When framework behavior matters, use installed-version Next.js documentation rather than stale memory.

Verify where relevant:

- Server Components remain default unless interactivity/browser state requires a Client Component;
- mutation-capable Server Actions/Route Handlers are authenticated and authorized like public endpoints;
- avoidable server/client fetch waterfalls are not introduced;
- state is not duplicated when it can be derived;
- effects are not used to maintain derivable state;
- stale closures or update ordering cannot corrupt meaningful form/workflow state;
- composition is introduced only when it removes real complexity;
- current canonical design behavior is preserved.

---

## 12. Accessibility — HIGH

Verify where relevant:

- semantic interactive elements;
- keyboard operation;
- visible focus;
- accessible names and labels;
- programmatic form-error relationships;
- status meaning not conveyed only by color;
- semantic tables/headers;
- responsive reflow without essential clipping;
- reduced motion where motion exists;
- locale/bilingual behavior preserves required state.

Major UI/pre-release review should use the canonical design source and the accessibility checklist above; run React Doctor when useful for a material React diff.

---

## 13. Performance and reliability — HIGH/MEDIUM

Verify where relevant:

- server-side pagination/search for operational data sets;
- deterministic stable sorting;
- required database indexes;
- no avoidable React/Next.js waterfalls;
- justified client bundle growth;
- retryable/after-commit external delivery where required;
- stateless/serverless runtime assumptions remain valid;
- expensive shared logic is not duplicated unnecessarily.

Use GitNexus only when symbol/impact tracing materially improves confidence, and confirm conclusions against direct source.

---

## 14. Maintainability — MEDIUM

Flag:

- speculative abstraction;
- wrappers without policy;
- generalized APIs with only one real use;
- broad unrelated refactors;
- unnecessary dependencies;
- duplicate business/security semantics that should share one authoritative helper.

Use `ponytail-review` when the diff materially increases abstraction/indirection.

Never simplify away authorization, RLS/grants, validation, concurrency, idempotency, privacy, accessibility, audit requirements, or explicit canonical-source behavior.

---

## 15. Workflow and agent safety — HIGH

Reject the workflow if:

- multiple writing agents concurrently mutate the same worktree;
- overlapping migrations/schema objects are assigned concurrently without an explicit merge boundary;
- a subagent is allowed to treat itself as owner of the parent Todo or autonomous frontier;
- worker success is accepted without parent diff inspection and fresh verification;
- machine-specific global skill paths are required for project correctness;
- a runtime skill loader is implemented in project governance instead of using OMP discovery/autoload;
- production/deploy/destructive actions occur without explicit authorization.

---

## 16. Completion gate

Before PASS/ACCEPTED:

- inspect exact diff/result;
- verify all blocking findings are closed;
- run fresh focused tests/checks for the changed behavior;
- run broader lint/typecheck/build/test only when lifecycle/risk requires them;
- confirm the evidence belongs to the exact reviewed SHA when SHA-specific acceptance is required;
- confirm the reviewed SHA is the SHA that CI passed and that will be merged;
- state any residual non-blocking risk explicitly.

`verification-before-completion` is the project-local completion-evidence skill. It reinforces this gate; it does not replace reviewer judgment.
