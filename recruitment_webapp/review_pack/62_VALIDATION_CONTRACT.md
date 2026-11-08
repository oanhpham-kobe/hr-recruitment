# 62. Validation Contract — v1.8

Machine-readable source: `validation_contract.yaml`.

The same limits/normalization rules must be consumed or mirrored by frontend validation, trusted backend DTO validation, database checks where appropriate, and automated acceptance tests. Frontend-only validation is never authorization.

Key rules: Candidate email comes from verified Auth; notes/report fields are plain text; raw HTML input is forbidden; HTTPS meeting links in production; max 5 MB/file and max 5 current files; approved extension/MIME/magic-byte validation; max collection sizes; DOB/date sanity; safe filename normalization; PII search is not persisted in URL.
