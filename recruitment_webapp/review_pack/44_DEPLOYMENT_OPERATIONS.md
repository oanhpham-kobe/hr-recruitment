# 44. Deployment & Operations — v1.8

## 1. Environments

Tối thiểu:
- Local Development;
- Staging/UAT;
- Production.

Vercel Preview có thể dùng cho PR. Supabase preview branch có thể map với Vercel preview, nhưng mỗi preview phải chạy security/invariant smoke tests.

Production data không dùng làm seed cho preview.

## 2. Recommended mapping

- Vercel Development → local Supabase hoặc dedicated dev.
- Vercel Preview/PR → Supabase preview branch/isolated non-prod data.
- Staging final UAT → persistent isolated Supabase environment.
- Vercel Production → production Supabase only.

## 3. Environment variables

Browser-safe:
- Supabase URL;
- Supabase publishable key.

Server-only:
- Supabase secret/service role;
- mail provider keys;
- Vercel deployment token;
- other secrets.

Không commit secret vào repo. Deployment/API tokens phải nằm trong secure CI/Vercel secrets hoặc sensitive environment variables; không hard-code trong source hoặc shell history.

## 4. Migrations

- schema changes qua version-controlled migrations;
- migration CI checks;
- apply staging before production;
- rollback/forward-fix runbook;
- seed only master/test data phù hợp, không production PII;
- quy tắc expand/contract: thay đổi schema trong production phải đi theo hướng additive trước, cập nhật code tương thích, backfill/validate, và sau cùng mới contract/deprecate; áp dụng statement/lock timeout phù hợp; tuyệt đối không rewrite các migration đã được accepted trong lịch sử.

## 5. Preview branch risk guard

Tại thời điểm technical review 02/09/2026 có open Supabase GitHub issue (#49426) báo cáo preview branch có thể diverge ở một số object privileges và `auth.users` triggers. Đây là **risk signal, không phải platform guarantee**.

Vì vậy không mặc định Preview = Production-equivalent. CI/UAT bắt buộc verify:
- RLS enabled;
- expected grants/revokes;
- auth triggers/functions;
- root admin protection;
- security-invoker/private views.

## 6. Backup / restore

Go-live checklist:
- DB scheduled backups/PITR phù hợp;
- Storage object recovery strategy;
- documented RPO/RTO;
- restore drill trên non-prod;
- verify document metadata ↔ object consistency sau restore.

## 7. Monitoring

Alert tối thiểu:
- auth anomaly/failure spikes;
- application/RPC error rate;
- DB resource/slow query;
- storage failures;
- email failure queue;
- backup failures;
- deployment failures.

## 8. Deployment discipline

- default preview deployment;
- production deploy qua protected branch/review;
- no direct manual production DB edits ngoài emergency runbook;
- post-deploy smoke tests.


## Database-enabled Integration CI Gate
Mỗi integration commit trên CI bắt buộc chạy qua job DB integration tự động:
1. Checkout exact pushed integration SHA;
2. Cài đặt Supabase CLI theo phiên bản pinned;
3. Khởi động local Supabase;
4. Chạy `supabase db reset` (replay sạch từ số 0);
5. Kiểm tra schema, RPC smoke, RLS persona assertions (anon, Candidate, HR, Root);
6. Test Candidate Submit/Update, quy trình document ADD/REPLACE/DELETE và outcome resolver;
7. Dọn dẹp/tắt local Supabase.

## 9. Dependency pinning / Auth regression
- Commit package lockfile.
- Pin Next.js, Supabase JS/SSR and security-sensitive dependencies to reviewed versions; do not let coding agents silently float to latest during implementation.
- Renovate/Dependabot-style updates run through CI.
- Any Supabase Auth/SSR upgrade reruns login, refresh, callback, inactive-user, Candidate OTP provisioning and RLS persona regression tests.

## 10. Capacity monitoring
No automatic business-data purge. Monitor purchased DB/Storage quota and alert Admin at configurable thresholds (recommended 70/85/95%). Capacity response is upgrade or controlled export/archive + explicit purge under approved procedure.

## Form-session, malware and recovery operations
- Deploy a scheduled cleanup for expired Candidate Form Sessions/temp uploads with metrics and alerting.
- Malware scanning service/process is a go-live dependency because legacy external Office formats are accepted.
- Root Admin break-glass procedure is documented in `61_ROOT_ADMIN_BREAK_GLASS_RECOVERY.md` and must be rehearsed in staging.
- Monitor Storage capacity and staged-upload backlog separately from final document storage.

## Dependency baseline at implementation scaffold
Before the code repository is scaffolded, follow `76_DEPENDENCY_BASELINE_POLICY.md`: select current patched supported Node/Next.js/React/Supabase packages at implementation date, pin exact reviewed versions through `package.json` + lockfile, record the baseline, and rerun Auth/security regression on upgrades. Do not copy transient version numbers from historical review notes into the long-lived product specification.

Privacy Notice publication/current-switch rehearsal follows `78_PRIVACY_NOTICE_PUBLICATION_RUNBOOK.md`; production evidence must show no unintended no-current/effective gap.
