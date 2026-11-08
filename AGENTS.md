# AGENTS.md — EIU Recruitment

Shared contract for every coding agent used on this repository: OMP, Codex,
Claude Code and Gemini. Runtime-specific entry files (`CLAUDE.md`, `GEMINI.md`,
`.omp/AGENTS.md`) only import this file.

## 1. Authority

When instructions conflict, use this order:

1. non-bypassable security, authorization, privacy, data-integrity,
   concurrency, accessibility, secret, production and destructive-action
   boundaries;
2. the canonical product sources in `recruitment_webapp/` (business, design,
   security, architecture);
3. the Owner's explicit instruction for the current work, when compatible with
   the boundaries above;
4. this file and `REVIEW.md`;
5. task-specific skills;
6. generic framework or community guidance.

Before non-trivial work, read the canonical source sections that govern the
behavior, then the current implementation, tests and migrations. Old plans,
old prompts and model memory are not authoritative. If an Owner-approved change
reopens a canonical contract, update that source document in the same change
instead of silently diverging in code.

Skills are advisory. They never become a second business or design source.

## 2. Repository map

```text
web/                 Next.js app (App Router), tests in web/src/__tests__
supabase/            migrations (append-only), SQL tests, local config
workers/             Cloudflare workers (Drive gateway)
recruitment_webapp/  canonical specs: review_pack/ and design_system/
.agents/skills/      the single shared skill home for every agent runtime
.omp/                OMP config, project task agents, MCP servers
scripts/             agent setup and validation
STATUS.md            feature map, open items, pending Owner decisions
```

Start with `STATUS.md` for what exists and what is unfinished.

## 3. Skills

Skills live at `.agents/skills/<name>/SKILL.md`; `SKILLS.md` says when to use
each one and `SKILLS_LOCK.yaml` records provenance only. Do not copy skills
into per-runtime folders. Claude Code reads them through a local link created
by `scripts/link-skills.ps1`.

Load a skill only when the task enters its domain.

## 4. Working rules

- Keep diffs surgical and in scope. Prefer the smallest change that meets the
  canonical contract.
- Never let two writing agents modify the same worktree at the same time.
  Local linked worktrees live under the gitignored `.worktrees/`.
- A delegated task must be self-contained: target files and non-goals, the
  required change, and observable acceptance checks.
- A worker's success claim is never acceptance evidence by itself.

OMP specifics: the main session owns the native Todo, task dispatch and
acceptance. Project task agents in `.omp/agents/` are bounded workers;
`eiu-db-executor` autoloads the Supabase skills.

## 5. Supabase, security and privacy invariants

Authentication is not authorization. Mutation paths follow:

```text
authenticate → authorize server-side → validate untrusted input
→ execute the approved transactional command/RPC → return a stable safe result
```

Never weaken RLS, grants, locking, optimistic concurrency, idempotency, audit,
private Storage or authorization to make a feature pass.

Migrations are append-only: never edit, squash or reorder an existing file in
`supabase/migrations/`; the hosted project depends on that history.

Never expose service-role keys, OAuth client secrets, session or refresh
tokens, OTPs, signed private URLs or other secrets, and never commit `.env`
files or real candidate data.

Supabase MCP is developer tooling only: non-production project, read-only.
Repository migrations and SQL tests remain the database authority.

## 6. Graph and documentation tools

GitNexus is an optional impact and navigation aid for shared or high-risk
code. Use it when graph evidence materially helps; confirm every material graph
conclusion against direct source. Database definitions are never inferred from
graph absence.

Use the Context7 MCP for current library documentation. For Next.js behavior,
read the version-matched docs in `web/node_modules/next/dist/docs/` first.

## 7. Verification

Before claiming work is fixed or complete:

1. inspect the actual diff;
2. run fresh focused checks that prove the claim and read their output;
3. run broader checks when the scope or risk requires it;
4. report the actual state, including failures and skipped checks.

Commands (from `web/`): `npm run lint`, `npm run typecheck`, `npm run test`,
`npm run design:check`, `npm run build`. Database tests run in CI against a
fresh local Supabase (`supabase db reset`). Agent setup:
`python scripts/validate_agents.py`.

A CI result for another SHA is not evidence for this one.

## 8. External actions

Do not push to `main`, deploy to production, apply hosted migrations, delete
production data or cross any other external boundary unless the Owner has
authorized that action. Work on feature branches and open pull requests.
