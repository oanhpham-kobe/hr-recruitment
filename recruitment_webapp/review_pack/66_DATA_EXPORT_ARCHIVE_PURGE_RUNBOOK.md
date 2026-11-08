# 66. Data Export / Archive / Purge Runbook — v1.8

## Purpose
Operational procedure for the owner-approved capacity policy: retain recruitment data online until EIU decides to expand capacity or export/archive selected data to controlled local storage and explicitly purge selected online copies. This is not an automatic retention scheduler.

## Authorization and approval
- Execution: Root Admin + designated IT/database operator.
- Business approval: HR owner/authorized EIU approver.
- Legal/privacy approval when required by current policy.
- No single operator may silently export then purge without recorded approval.

## Export scope manifest
Before export freeze a manifest: entity/date scope, Candidates, Submissions, Applications, Interviews, Reports, Email History, documents, row counts, object counts, schema/app version, UTC timestamp and operator IDs.

## Archive format/security
- Structured data: documented machine-readable export (CSV/JSON/SQL dump as appropriate).
- Files: original immutable object versions + metadata manifest.
- Encrypt archive at rest and in transit; keys stored separately under EIU-controlled custody.
- Destination must be EIU-controlled access-restricted local/archive storage.
- Generate SHA-256 manifest for every archive bundle/object set.

## Verification before purge
1. Compare source vs archive row/object counts.
2. Verify checksums.
3. Restore a representative sample into isolated environment and prove records/files readable.
4. Reconcile orphan/missing Storage objects.
5. Record approval to proceed.

## Purge
Purge only the exact approved scope through trusted maintenance command/migration. Preserve immutable security audit required by policy. Delete Storage objects and relational rows in a documented order. Never purge a partially verified archive.

## Failure / rollback
If export, checksum, restore or reconciliation fails: stop; do not purge. If purge partially fails, retain failure manifest and resume only with idempotent scope tracking.

## Evidence
Store approval IDs, manifest, checksums, counts, restore-test evidence, purge result, operator IDs, timestamps and audit references.
