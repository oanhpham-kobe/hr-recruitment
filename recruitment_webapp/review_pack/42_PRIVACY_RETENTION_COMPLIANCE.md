# 42. Privacy, Retention & Compliance Capability — v1.8

## Current business retention decision
**No automatic expiry/purge under current EIU business policy.** Recruitment records are retained until EIU explicitly decides otherwise. When capacity approaches limits, system warns Admin; EIU may purchase more capacity or export/archive selected data to local controlled storage and then explicitly delete selected online records. This is a business storage policy, not a legal conclusion.

## Required technical capabilities
- immutable published Privacy Notice versions;
- acknowledgement per Submission and notice version;
- data export and authorized explicit purge/archive with audit;
- capacity monitoring/alerts;
- candidate correction workflow;
- sensitive file access/download audit;
- no silent automatic purge.

Acknowledgement stores `submission_id`, `notice_version`, `acknowledged_at`, `source_code`; Candidate derives through Submission. Normal production submitted Submissions are retention-managed because retained production email trace is business history. MAINTENANCE_ONLY repair-delete of non-production/legacy unused data may cascade acknowledgement while immutable Security Audit preserves the deletion event.

## Privacy Notice authority
`privacy_notice_versions` is server-authoritative. Once published, `notice_version`, localized content, content hash, `published_at`, `effective_from` and creator metadata are immutable. New wording creates a new version; only the current-pointer lifecycle may change.

Every NEW/EDIT Candidate Form Session pins exactly one current/effective notice (`is_current=true AND effective_from<=now()`). None available → fail closed `PRIVACY_NOTICE_UNAVAILABLE`. Client arbitrary/unpublished version is rejected. EDIT Save acknowledges the pinned version; same-version acknowledgement is idempotent and a newly pinned version appends another historical acknowledgement.

## Publication/current switch
Phase 1 publication is maintenance/deployment-only and follows `78_PRIVACY_NOTICE_PUBLICATION_RUNBOOK.md`. A future-effective version is inserted non-current; pointer switch occurs only at/after `effective_from` in one transaction, preserving an effective current notice until the switch commits.

## Retention operations
Operational export/archive/purge follows `66_DATA_EXPORT_ARCHIVE_PURGE_RUNBOOK.md`. Current business policy remains no automatic expiry/purge.

## Deferred legal inputs
Exact notice wording and legally mandated retention/deletion rules are confirmed by EIU Legal/DPO-equivalent before production go-live. System capability must not assume indefinite retention is legally required or always permitted.
