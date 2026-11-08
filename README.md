# EIU Recruitment

Internal recruitment web app for EIU: candidates apply through an email-OTP
portal; HR manages submissions, applications, interviews and reports.

- Stack: Next.js (App Router) on Vercel, Supabase (Postgres, Auth, Storage),
  Cloudflare worker for private Drive document access.
- Product sources: `recruitment_webapp/review_pack/` (start at `00_README.md`)
  and `recruitment_webapp/design_system/`.
- Status and open items: `STATUS.md`.
- Agent rules (OMP, Codex, Claude Code, Gemini): `AGENTS.md`.

## Local development

Requirements: Node.js 24, npm 11, Docker, Supabase CLI.

```bash
supabase start
supabase db reset          # replay all migrations
cd web
npm ci
cp .env.example .env.local # fill in local Supabase values
npm run dev
```

Checks (from `web/`): `npm run lint`, `npm run typecheck`, `npm run test`,
`npm run design:check`, `npm run build`.

## Agent setup

Skills live once in `.agents/skills/`. On Windows, give Claude Code access with:

```powershell
pwsh -File scripts/link-skills.ps1
```

Validate the agent setup with `python scripts/validate_agents.py`.
