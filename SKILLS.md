# SKILLS.md — EIU Recruitment OMP Skill Inventory

## Purpose

This file documents the project skill catalog and routing intent. It does **not** implement runtime loading.

OMP owns skill discovery, provider precedence, `skill://<name>` resolution, `/skill:<name>` commands, and `autoloadSkills` injection for task agents.

Project business/design authority remains the current canonical project sources.

---

## 1. Canonical project skill home

Project skills live at:

```text
.agents/skills/<skill-name>/SKILL.md
```

Each skill must be one directory below `skills/` and should contain explicit frontmatter:

```yaml
---
name: <unique-skill-name>
description: <clear trigger/use description>
---
```

Keep references/scripts/assets inside the same skill directory. Avoid duplicate skill names across project providers.

`.omp/skills/` is reserved for a genuinely OMP-native project skill only when native provider priority is specifically required. The previous `eiu-code-review` workflow skill has been removed; review behavior now belongs to OMP task-agent/reviewer primitives.

---

## 2. Runtime model

At session startup OMP discovers skill metadata. The model loads content only when needed:

```text
skill://<name>
```

or through a project agent's frontmatter:

```yaml
autoloadSkills:
  - <name>
```

Do not manually resolve an absolute filesystem path from `SKILLS_LOCK.yaml` and do not maintain a parallel `AVAILABLE / LOADED / APPLIED` runtime protocol.

`SKILLS_LOCK.yaml` is provenance/integrity metadata only.

---

## 3. Project-local domain skills

These are available directly from `.agents/skills/` and are suitable for task-specific use.
`.agents/skills/` is the single shared skill home for every agent runtime used on this repository; do not copy skills into per-runtime folders.

| Skill | Use |
|---|---|
| `supabase` | Supabase Auth/SSR/Storage/CLI/MCP/debugging |
| `supabase-postgres-best-practices` | PostgreSQL schema, RLS, locking, indexes, concurrency, performance |
| `ponytail-review` | Over-engineering/complexity review when abstraction grows |
| `verification-before-completion` | Fresh evidence before success/completion claims |

### Native agent autoload routes

`eiu-db-executor` autoloads:

```text
supabase
supabase-postgres-best-practices
verification-before-completion
```

`eiu-ui-executor`, `eiu-debugger`, and `eiu-general-executor` autoload:

```text
verification-before-completion
```

Additional skills are read on demand through `skill://<name>` after the task actually enters that domain.

---

## 4. Release skills

| Skill | Use |
|---|---|
| `deploy-to-vercel` | Explicitly authorized Vercel deployment workflow |
| `vercel-optimize` | Post-deploy Vercel performance/reliability/cost analysis |

These skills are not routine implementation requirements and must not imply deployment authorization.

---

## 5. GitNexus skills — on demand

Installed project skills:

- `gitnexus-exploring`
- `gitnexus-impact-analysis`
- `gitnexus-debugging`
- `gitnexus-refactoring`
- `gitnexus-guide`
- `gitnexus-cli`

Use GitNexus only when graph/context/impact analysis materially helps the task. Direct source and LSP remain primary code evidence. Repository SQL/migrations remain database authority.

Operational or niche GitNexus skills may remain discoverable without being autoloaded into routine workers.

---

## 6. Skills deliberately not used as project workflow primitives

Do not add project-local workflow skills that duplicate OMP's native runtime:

- `implement` — OMP task agents already perform implementation;
- `code-review` — OMP has reviewer/task-agent primitives and project `eiu-reviewer`;
- `context-budget` — OMP owns context/read/compaction behavior;
- `frontend-checklist-global` — the project design source and REVIEW.md accessibility checklist cover the required review surface;
- `karpathy-guidelines` — generic heuristic overlay, not a required capability.

Do not make project correctness depend on a skill that exists only in a developer's global OMP profile.

### Optional globally discovered skills

OMP may discover user-level skills such as:

- `vercel-react-best-practices`;
- `vercel-composition-patterns`.

They can be used on demand if present, but they are **not required project dependencies** and project agents must not autoload them until the repository vendors a complete verified project copy.

---

## 7. Next.js guidance

Do not install a stale `next-best-practices` workflow skill.

For framework-sensitive work:

1. detect the installed Next.js version;
2. read version-matched installed docs when available;
3. use the Context7 MCP for current external clarification when needed.

Do not upgrade Next.js merely to gain agent tooling.

---

## 8. MCP and tools are not skills

Project MCP definitions live in `.omp/mcp.json`.

Current intended surface:

- Context7 — documentation retrieval;
- Supabase dev — non-production, read-only, project ref supplied through `SUPABASE_PROJECT_REF`;
- GitNexus — on-demand graph/impact engine.

MCP availability does not prove a tool was used, and tool output never outranks direct source or canonical project contracts.

React Doctor remains a CLI quality aid, not another React skill.

---

## 9. Quick routing

```text
Supabase implementation
  -> eiu-db-executor

SQL / migration / RLS / concurrency
  -> eiu-db-executor

React / UI implementation
  -> eiu-ui-executor

Reported defect / failing behavior
  -> eiu-debugger
  -> load narrowed domain skill if needed

Other bounded implementation
  -> eiu-general-executor

Independent review
  -> OMP built-in reviewer or eiu-reviewer
  -> specialist skill:// reads only when materially relevant

Shared/high-impact symbol investigation
  -> GitNexus on demand + direct source/LSP confirmation

Before completion
  -> verification-before-completion
```

---

## 10. Inventory invariant

The project should be clonable and usable without machine-specific skill paths.

Validation must reject:

- duplicate discovered project skill names;
- missing `SKILL.md` for an `autoloadSkills` entry;
- project agent autoload references that resolve only from a developer's global profile;
- hardcoded user-home skill paths in project governance;
- reintroduction of a separate project runtime skill loader.
