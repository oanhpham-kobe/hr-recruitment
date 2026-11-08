This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

## Interview feedback local preview

Run `npm run preview:feedback` from this `web` directory, then open
`http://127.0.0.1:3417/interview-feedback`. This standalone preview uses the same
UI components with synthetic browser-local data. Switch trial personas to assign
forms, save/submit each evaluator's answers, then consolidate/approve/print as HR.
It sends no email and has no database credentials. Restart the preview after code
changes because it bundles at startup.

The production routes are `/interview-feedback` and
`/interview-feedback/[id]`, using the real internal session and authorized RPCs.
Apply repository migrations through the normal approved local workflow; never
use the preview persona controls as production authentication. The first template
uses the existing five optional qualitative questions. Official report layouts,
candidate dossiers and actual mail delivery remain separate follow-up work.

## Full project interactive HTML

Run `npm run preview:project`, then open `http://127.0.0.1:3427/project-preview`.
The same command creates `.preview/eiu-project-preview.html`, a self-contained
offline file with bundled JavaScript, CSS and fonts. Use
`npm run preview:project:build` to create only the file, or pass
`-- --output ABSOLUTE_PATH` for another output location. Rebuild/restart after changes.

The guide opens each workflow step with the appropriate trial role. Six personas
share browser-local synthetic state: Candidate, full HR, read-only HR, two
interviewers and Root. Existing production components cover Candidate forms,
Inbox/details/assignment, interview rounds/schedules/participants, original reports,
questionnaires/consolidation, users/permissions and all eleven master catalogs.
The service page explains the simulated email queue and document metadata.

Changes persist locally, **Reset all** resets this preview's data and Candidate
drafts, and **Export readable notes** downloads the tester's checklist/log/notes.
Use synthetic information only. Role changes simulate authentication; OAuth/OTP,
email delivery, malware scanning, private file contents and official document
exports are not connected. This tests UI interactions and local workflow examples;
database/RLS/concurrency acceptance still requires the real application test stack.
The browser fixture aliases are isolated from production routes and credentials.

## Framework references

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme) from the creators of Next.js.

Check out our [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for more details.
