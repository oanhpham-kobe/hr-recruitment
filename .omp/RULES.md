# EIU Recruitment — OMP Sticky Rules

1. Canonical project sources in `recruitment_webapp/` outrank memory, old plans, generic skills and examples.
2. Authentication is not authorization. Preserve server-side authorization, RLS/grants, validation, locking/concurrency, idempotency, privacy, private Storage, accessibility and secret boundaries.
3. Supabase MCP defaults to non-production and read-only. Production writes, destructive live operations, deploys, `main` pushes and hosted migrations require explicit Owner authorization.
4. Never let multiple writing agents concurrently modify the same worktree.
5. The main OMP session owns the visible Todo and task lifecycle. Subagents must not own or recreate the parent Todo.
6. Skills use OMP-native discovery from `.agents/skills/<name>/SKILL.md`; use `autoloadSkills` on project agents and `skill://<name>` for on-demand reads. Do not resolve runtime skill paths through `SKILLS_LOCK.yaml`.
7. A skill is guidance, not project authority. Apply only skills relevant to the delegated work.
8. Subagents are bounded workers: they implement, investigate or review the assigned scope and return evidence to the parent.
9. Do not trust a subagent success claim by itself. The parent verifies the diff and obtains fresh evidence before accepting, committing or claiming completion.
10. GitNexus is on-demand graph/impact assistance. Direct source, LSP, migrations, SQL and tests remain authoritative.
11. Repair verification is impact-selected: rerun failed and directly affected checks; reopen unrelated passed areas only on changed-code or shared-contract evidence.
12. Producer self-review is not independent review. `eiu-reviewer` is read-only and reviews an exact SHA; a repair SHA needs fresh re-review.
