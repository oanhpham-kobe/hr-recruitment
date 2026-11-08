#!/usr/bin/env bash
set -euo pipefail
if ! command -v jq >/dev/null 2>&1; then
  if command -v jq.exe >/dev/null 2>&1; then
    jq() { jq.exe "$@" | tr -d '\r'; }
  fi
else
  _raw_jq="$(command -v jq)"
  jq() { "$_raw_jq" "$@" | tr -d '\r'; }
fi

: "${CONTAINER_NAME:=supabase_db_eiu-recruitment-dev}"
container_name="$CONTAINER_NAME"
migration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../migrations" && pwd)"

suffix="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c 1-12)"
test_db="eiu_upgrade_${suffix}"

cleanup_test_db() {
  docker exec -i "$container_name" psql -U postgres -d postgres -c "drop database if exists \"$test_db\";" >/dev/null 2>&1 || true
}
trap cleanup_test_db EXIT

echo "=== Step 1: Creating disposable database $test_db ==="
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "create database \"$test_db\" with template template1;"

psql_cmd() {
  docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d "$test_db" "$@"
}
psql_cmd -c "create schema if not exists extensions; create schema if not exists private;"
docker exec -i "$container_name" pg_dump -U supabase_admin -d postgres -s -n auth -n storage --no-owner --no-privileges | docker exec -i "$container_name" psql -q -U supabase_admin -d "$test_db" >/dev/null 2>&1 || true
echo "=== Step 2: Applying migrations up to immediately before S07-003 ==="
for migration_file in $(ls -1 "$migration_dir"/*.sql | sort); do
  base_name="$(basename "$migration_file")"
  if [[ "$base_name" == "20260915010000_storage_cleanup_trusted_contracts.sql" ]]; then
    break
  fi
  psql_cmd < "$migration_file" >/dev/null
done

# Verify provenance table does NOT exist yet
has_provenance="$(psql_cmd -c "select to_regclass('private.storage_cleanup_provenance') is not null;")"
if [[ "$has_provenance" != "f" ]]; then
  echo "FAIL: private.storage_cleanup_provenance must not exist before S07-003" >&2
  exit 1
fi

echo "=== Step 3: Seeding pre-existing Candidate and Interview reservations before S07-003 ==="
candidate_id="$(psql_cmd -c 'select gen_random_uuid()')"
candidate_auth="$(psql_cmd -c 'select gen_random_uuid()')"
notice_version="s07-upgrade-notice-${suffix}"
doc_type_id="$(psql_cmd -c 'select gen_random_uuid()')"
session_id="$(psql_cmd -c 'select gen_random_uuid()')"
cand_res_id="$(psql_cmd -c 'select gen_random_uuid()')"
cand_path="temp/${session_id}/${cand_res_id}/candidate_test.pdf"

interview_user_auth="$(psql_cmd -c 'select gen_random_uuid()')"
interview_user_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_id="$(psql_cmd -c 'select gen_random_uuid()')"
application_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_cand_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_cand_auth="$(psql_cmd -c 'select gen_random_uuid()')"
interview_sub_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_unit_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_pos_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_group_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_doc_type="$(psql_cmd -c 'select gen_random_uuid()')"
interview_res_id="$(psql_cmd -c 'select gen_random_uuid()')"
interview_path="temp/interview/${interview_id}/${interview_res_id}"

legacy_res_id="$(psql_cmd -c 'select gen_random_uuid()')"
legacy_path="temp/${session_id}/${legacy_res_id}/legacy_expired.pdf"
legacy_queue_id="$(psql_cmd -c 'select gen_random_uuid()')"

psql_cmd <<SQL
-- Candidate parent & pre-existing reservation
insert into public.candidates(candidate_id, auth_user_id, email)
values ('$candidate_id', '$candidate_auth', 'cand-${suffix}@example.test');

insert into public.privacy_notice_versions(notice_version, content_vi, content_hash_sha256, is_current)
values ('$notice_version', 'Upgrade test notice', repeat('1', 64), false);

insert into public.document_types(document_type_id, code, name_vi, scope_code)
values ('$doc_type_id', 'UPGRADE-${suffix:0:6}', 'Upgrade Document', 'SUBMISSION');

insert into public.candidate_form_sessions(
  candidate_form_session_id, candidate_id, mode_code, presented_privacy_notice_version, status_code, expires_at
) values (
  '$session_id', '$candidate_id', 'NEW_SUBMISSION', '$notice_version', 'OPEN', clock_timestamp() + interval '2 hours'
);

insert into public.upload_reservations(
  upload_reservation_id, candidate_form_session_id, intended_document_type_id,
  temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key,
  expires_at, signed_upload_expires_at, status_code
) values (
  '$cand_res_id', '$session_id', '$doc_type_id',
  'candidate-quarantine', '$cand_path', 'candidate_test.pdf',
  '$candidate_auth', gen_random_uuid(),
  clock_timestamp() + interval '2 hours',
  clock_timestamp() + interval '3 hours',
  'RESERVED'
);

-- Pre-existing expired reservation with existing cleanup queue row
insert into public.upload_reservations(
  upload_reservation_id, candidate_form_session_id, intended_document_type_id,
  temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key,
  expires_at, signed_upload_expires_at, status_code
) values (
  '$legacy_res_id', '$session_id', '$doc_type_id',
  'candidate-quarantine', '$legacy_path', 'legacy_expired.pdf',
  '$candidate_auth', gen_random_uuid(),
  clock_timestamp() - interval '2 hours',
  clock_timestamp() - interval '1 hour',
  'EXPIRED'
);

insert into public.storage_cleanup_queue(
  storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before
) values (
  '$legacy_queue_id', 'CANDIDATE_FORM', '$session_id', '$legacy_res_id',
  'candidate-quarantine', '$legacy_path', 'RESERVATION_EXPIRED', 'PENDING',
  clock_timestamp() - interval '1 hour'
);

-- Interview ancestors & pre-existing reservation
insert into public.app_users(app_user_id, auth_user_id, email, full_name)
values ('$interview_user_id', '$interview_user_auth', 'staff-${suffix}@eiu.edu.vn', 'Upgrade Staff');

insert into public.app_user_roles(app_user_id, role_code)
values ('$interview_user_id', 'HR');

insert into public.candidates(candidate_id, auth_user_id, email)
values ('$interview_cand_id', '$interview_cand_auth', 'int-cand-${suffix}@example.test');

insert into public.submissions(
  submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot
) values (
  '$interview_sub_id', '$interview_cand_id', 'Upgrade Candidate', date '2000-01-01', 'FEMALE',
  'address', '0000000000', 'int-cand-${suffix}@example.test'
);

insert into public.organizational_units(unit_id, code, name_vi)
values ('$interview_unit_id', 'U-${suffix:0:6}', 'Upgrade Unit');

insert into public.position_groups(position_group_id, code, name_vi)
values ('$interview_group_id', 'G-${suffix:0:6}', 'Upgrade Group');

insert into public.positions(position_id, unit_id, position_group_id, code, name_vi)
values ('$interview_pos_id', '$interview_unit_id', '$interview_group_id', 'P-${suffix:0:6}', 'Upgrade Pos');

insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id)
values ('$application_id', '$interview_sub_id', '$interview_unit_id', '$interview_pos_id', '$interview_user_id');

insert into public.document_types(document_type_id, code, name_vi, scope_code)
values ('$interview_doc_type', 'INT-${suffix:0:6}', 'Interview Doc', 'INTERVIEW');

insert into public.interviews(interview_id, application_id, round_no)
values ('$interview_id', '$application_id', 1);
insert into public.upload_reservations(
  upload_reservation_id, interview_id, intended_document_type_id,
  temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key,
  expires_at, signed_upload_expires_at, status_code
) values (
  '$interview_res_id', '$interview_id', '$interview_doc_type',
  'interview-quarantine', '$interview_path', 'interview_test.pdf',
  '$interview_user_auth', gen_random_uuid(),
  clock_timestamp() + interval '1 hour',
  clock_timestamp() + interval '1 hour',
  'RESERVED'
);
SQL

echo "=== Step 4: Applying S07-003 migration (with provenance backfill) ==="
psql_cmd < "$migration_dir/20260915010000_storage_cleanup_trusted_contracts.sql" >/dev/null

echo "=== Step 5: Asserting provenance backfill results ==="
cand_prov="$(psql_cmd -c "
select source_type || '|' || source_parent_id || '|' || upload_reservation_id
from private.storage_cleanup_provenance
where bucket_name = 'candidate-quarantine' and object_path = '$cand_path';
")"
expected_cand="CANDIDATE_FORM|${session_id}|${cand_res_id}"
if [[ "$cand_prov" != "$expected_cand" ]]; then
  echo "FAIL: Candidate reservation provenance backfill mismatch: expected '$expected_cand', got '$cand_prov'" >&2
  exit 1
fi

int_prov="$(psql_cmd -c "
select source_type || '|' || source_parent_id || '|' || upload_reservation_id
from private.storage_cleanup_provenance
where bucket_name = 'interview-quarantine' and object_path = '$interview_path';
")"
expected_int="INTERVIEW_UPLOAD|${interview_id}|${interview_res_id}"
if [[ "$int_prov" != "$expected_int" ]]; then
  echo "FAIL: Interview reservation provenance backfill mismatch: expected '$expected_int', got '$int_prov'" >&2
  exit 1
fi

legacy_prov="$(psql_cmd -c "
select source_type || '|' || source_parent_id || '|' || upload_reservation_id
from private.storage_cleanup_provenance
where bucket_name = 'candidate-quarantine' and object_path = '$legacy_path';
")"
expected_legacy="CANDIDATE_FORM|${session_id}|${legacy_res_id}"
if [[ "$legacy_prov" != "$expected_legacy" ]]; then
  echo "FAIL: Legacy expired reservation provenance backfill mismatch: expected '$expected_legacy', got '$legacy_prov'" >&2
  exit 1
fi

echo "=== Step 6: Testing pre-existing reservation cleanup eligibility ==="
# Cancel candidate form session so reservation becomes CANCELLED without changing expiry timestamps
psql_cmd -c "
update public.upload_reservations set status_code = 'CANCELLED' where upload_reservation_id = '$cand_res_id';
"
# Enqueue cleanup
queue_cand_id="$(psql_cmd -c "
insert into public.storage_cleanup_queue(
  source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before
) values (
  'CANDIDATE_FORM', '$session_id', '$cand_res_id',
  'candidate-quarantine', '$cand_path', 'SESSION_CANCELLED', 'PENDING',
  clock_timestamp()
) returning storage_cleanup_id;
")"

# 1. At current time, signed-upload expiry is still in future -> SIGNED_WINDOW (NOT UNKNOWN_PROVENANCE)
eligibility_now="$(psql_cmd -c "
select private.storage_cleanup_eligibility(q, clock_timestamp())
from public.storage_cleanup_queue q
where storage_cleanup_id = '$queue_cand_id';
")"
if [[ "$eligibility_now" != "SIGNED_WINDOW" ]]; then
  echo "FAIL: Expected SIGNED_WINDOW for unelapsed signed window, got '$eligibility_now'" >&2
  exit 1
fi

# 2. At simulated future time (+4 hours), signed window has elapsed -> ELIGIBLE (NOT UNKNOWN_PROVENANCE)
eligibility_future="$(psql_cmd -c "
select private.storage_cleanup_eligibility(q, clock_timestamp() + interval '4 hours')
from public.storage_cleanup_queue q
where storage_cleanup_id = '$queue_cand_id';
")"
if [[ "$eligibility_future" != "ELIGIBLE" ]]; then
  echo "FAIL: Expected ELIGIBLE after signed window elapsed, got '$eligibility_future'" >&2
  exit 1
fi

# 3. Test pre-existing expired reservation queue row -> ELIGIBLE at current time
legacy_eligibility="$(psql_cmd -c "
select private.storage_cleanup_eligibility(q, clock_timestamp())
from public.storage_cleanup_queue q
where storage_cleanup_id = '$legacy_queue_id';
")"
if [[ "$legacy_eligibility" != "ELIGIBLE" ]]; then
  echo "FAIL: Expected ELIGIBLE for pre-existing expired queue row, got '$legacy_eligibility'" >&2
  exit 1
fi

echo "=== Step 7: Testing live reference protection on pre-existing reservation ==="
# Retained reference check: inserting submission document referencing the path must yield RETAINED_REFERENCE
psql_cmd <<SQL
do \$\$
declare
  v_log uuid;
begin
  insert into public.submission_document_logicals(submission_id, document_type_id, created_by_candidate_id)
  values ('$interview_sub_id', '$doc_type_id', '$candidate_id')
  returning logical_document_id into v_log;

  insert into public.submission_documents(
    logical_document_id, storage_bucket, storage_path, original_filename,
    mime_type, file_size_bytes, checksum_sha256, version_no, is_current, uploaded_by_candidate_id
  ) values (
    v_log, 'candidate-quarantine', '$cand_path', 'retained.pdf',
    'application/pdf', 1024, repeat('a', 64), 1, true, '$candidate_id'
  );
end;
\$\$;
SQL

eligibility_retained="$(psql_cmd -c "
select private.storage_cleanup_eligibility(q, clock_timestamp() + interval '4 hours')
from public.storage_cleanup_queue q
where storage_cleanup_id = '$queue_cand_id';
")"
if [[ "$eligibility_retained" != "RETAINED_REFERENCE" ]]; then
  echo "FAIL: Expected RETAINED_REFERENCE when document exists, got '$eligibility_retained'" >&2
  exit 1
fi

echo "=== Step 8: Testing genuinely detached legacy queue row remains fail-closed (UNKNOWN_PROVENANCE) ==="
detached_queue_id="$(psql_cmd -c "
insert into public.storage_cleanup_queue(
  source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before
) values (
  'CANDIDATE_FORM', gen_random_uuid(), null,
  'candidate-quarantine', 'temp/detached-session/detached-res/ghost.pdf',
  'ORPHANED_TEMP_OBJECT', 'PENDING',
  clock_timestamp() - interval '1 day'
) returning storage_cleanup_id;
")"

detached_eligibility="$(psql_cmd -c "
select private.storage_cleanup_eligibility(q, clock_timestamp())
from public.storage_cleanup_queue q
where storage_cleanup_id = '$detached_queue_id';
")"
if [[ "$detached_eligibility" != "UNKNOWN_PROVENANCE" ]]; then
  echo "FAIL: Genuinely detached legacy row must evaluate to UNKNOWN_PROVENANCE, got '$detached_eligibility'" >&2
  exit 1
fi

# Attempting to claim/authorize detached row must be withheld
claim_result="$(psql_cmd -c "select public.claim_storage_cleanup_jobs('test-worker', 10, 60);")"
detached_status="$(psql_cmd -c "
select status_code || '|' || coalesce(eligibility_code, 'none')
from public.storage_cleanup_queue
where storage_cleanup_id = '$detached_queue_id';
")"
if [[ "$detached_status" != "ERROR|UNKNOWN_PROVENANCE" ]]; then
  echo "FAIL: Detached legacy row must be withheld to ERROR|UNKNOWN_PROVENANCE on claim, got '$detached_status'" >&2
  exit 1
fi

echo "PASS: All R1 forward-migration provenance backfill and upgrade regression assertions succeeded."
