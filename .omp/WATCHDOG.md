# EIU Recruitment — OMP Advisor Priorities

Use the project review contract as the primary reviewer checklist:

@../REVIEW.md

Pay particular attention to:

- implementation based on stale source versions;
- authentication confused with authorization;
- Google OAuth callback/session mistakes;
- RLS or grant bypass;
- `SECURITY DEFINER` misuse;
- service-role leakage or overuse;
- stale writes, missing version checks, lock-order races, TOCTOU;
- missing idempotency;
- browser-orchestrated multi-write business commands;
- private document/Storage exposure;
- unsafe signed URLs or PII/token logging;
- Supabase MCP connected to production or writable by default;
- unrelated scope creep and speculative abstraction;
- risky shared/cross-module changes performed without adequate GitNexus impact/dependency evidence when blast radius is not obvious;
- GitNexus index assumed current without checking freshness;
- multiple agents writing the same worktree;
- completion claims unsupported by fresh tests/checks.

Prefer one concrete high-confidence concern over many speculative nits.

Treat current canonical project sources as authoritative.

Advisor guidance is review input, not permission to redesign the product.
