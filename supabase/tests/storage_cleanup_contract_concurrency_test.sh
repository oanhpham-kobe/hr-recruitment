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

: "${CONTAINER_NAME:?Set CONTAINER_NAME to the disposable Supabase Postgres container}"
container_name="$CONTAINER_NAME"
suffix="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c 1-12)"
tmp_dir=".tmp_concurrency_${suffix}"
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

psql_exec() {
  docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

queue_id="$(psql_exec -c 'select gen_random_uuid()')"
reservation_id="$(psql_exec -c 'select gen_random_uuid()')"
parent_id="$(psql_exec -c 'select gen_random_uuid()')"
path="temp/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-${suffix:0:12}/race.pdf"
psql_exec <<SQL
insert into private.storage_cleanup_provenance(
  bucket_name, object_path, upload_reservation_id, source_type, source_parent_id,
  reservation_expires_at, detached_at
) values (
  'candidate-quarantine', '$path', '$reservation_id', 'CANDIDATE_FORM', '$parent_id',
  clock_timestamp() - interval '2 hours', clock_timestamp()
);
insert into public.storage_cleanup_queue(
  storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before
) values (
  '$queue_id', 'CANDIDATE_FORM', '$parent_id', '$reservation_id',
  'candidate-quarantine', '$path', 'RESERVATION_EXPIRED', 'PENDING',
  clock_timestamp() - interval '1 hour'
);
SQL
psql_exec -c "delete from public.storage_cleanup_queue where status_code in ('PENDING', 'PROCESSING') and storage_cleanup_id <> '$queue_id';"

# Two independent database sessions race a single claim. Exactly one owns attempt one.
psql_exec -c "select public.claim_storage_cleanup_jobs('cleanup-a', 10, 60)" >"$tmp_dir/claim-a.json" &
claim_a_pid=$!
psql_exec -c "select public.claim_storage_cleanup_jobs('cleanup-b', 10, 60)" >"$tmp_dir/claim-b.json" &
claim_b_pid=$!
wait "$claim_a_pid"
wait "$claim_b_pid"
combined="$(jq -s --arg q "$queue_id" 'map(.data[]? | select(.storage_cleanup_id == $q)) | length' "$tmp_dir/claim-a.json" "$tmp_dir/claim-b.json")"
[[ "$combined" == "1" ]] || {
  echo 'concurrent cleanup claims must yield exactly one attempt owner' >&2
  exit 1
}

if [[ "$(jq -r --arg q "$queue_id" '.data[]? | select(.storage_cleanup_id == $q) | .attempt_id // empty' "$tmp_dir/claim-a.json")" != "" ]]; then
  claim_file="$tmp_dir/claim-a.json"
  old_worker='cleanup-a'
else
  claim_file="$tmp_dir/claim-b.json"
  old_worker='cleanup-b'
fi
old_attempt="$(jq -r --arg q "$queue_id" '.data[] | select(.storage_cleanup_id == $q) | .attempt_id' "$claim_file")"
old_token="$(jq -r --arg q "$queue_id" '.data[] | select(.storage_cleanup_id == $q) | .fencing_token' "$claim_file")"

# Reclaim invalidates both the old authorization and both old completion outcomes.
psql_exec -c "update public.storage_cleanup_queue set leased_until=clock_timestamp()-interval '1 second' where storage_cleanup_id='$queue_id'"
new_claim="$(psql_exec -c "select public.claim_storage_cleanup_jobs('cleanup-reclaimer', 10, 60)")"
new_attempt="$(printf '%s' "$new_claim" | jq -r --arg q "$queue_id" '.data[]? | select(.storage_cleanup_id == $q) | .attempt_id // empty')"
new_token="$(printf '%s' "$new_claim" | jq -r --arg q "$queue_id" '.data[]? | select(.storage_cleanup_id == $q) | .fencing_token // empty')"
[[ -n "$new_attempt" && "$new_attempt" != "$old_attempt" && "$new_token" != "$old_token" ]] || {
  echo 'reclaim must fence the prior attempt' >&2
  exit 1
}

for stale_success in true false; do
  stale="$(psql_exec -c "select public.complete_storage_cleanup_attempt('$queue_id','$old_attempt','$old_token','$old_worker',$stale_success,'WORKER_ERROR')")"
  [[ "$(printf '%s' "$stale" | jq -r '.error_code')" == "STALE_ATTEMPT" ]] || {
    echo 'stale success/error must not alter the reclaimed attempt' >&2
    exit 1
  }
done
stale_authorization="$(psql_exec -c "select public.authorize_storage_cleanup_attempt('$queue_id','$old_attempt','$old_token','$old_worker')")"
[[ "$(printf '%s' "$stale_authorization" | jq -r '.error_code')" == "STALE_ATTEMPT" ]] || {
  echo 'stale authorization must be fenced after reclaim' >&2
  exit 1
}
authorized="$(psql_exec -c "select public.authorize_storage_cleanup_attempt('$queue_id','$new_attempt','$new_token','cleanup-reclaimer')")"
[[ "$(printf '%s' "$authorized" | jq -r '.success')" == "true" ]] || {
  echo 'current worker must authorize before reporting completion' >&2
  exit 1
}
completed="$(psql_exec -c "select public.complete_storage_cleanup_attempt('$queue_id','$new_attempt','$new_token','cleanup-reclaimer',true,null)")"
[[ "$(printf '%s' "$completed" | jq -r '.data.status_code')" == "DONE" ]] || {
  echo 'current authorized attempt must complete' >&2
  exit 1
}

# A fifth expired lease settles to ERROR and cannot create a sixth attempt.
exhausted_queue="$(psql_exec -c 'select gen_random_uuid()')"
exhausted_reservation="$(psql_exec -c 'select gen_random_uuid()')"
exhausted_path="temp/00000000-0000-0000-0000-000000000002/00000000-0000-0000-0000-${suffix:0:12}/exhausted.pdf"
psql_exec <<SQL
insert into private.storage_cleanup_provenance(
  bucket_name, object_path, upload_reservation_id, source_type, source_parent_id,
  reservation_expires_at, signed_upload_expires_at, detached_at
) values (
  'candidate-quarantine', '$exhausted_path', '$exhausted_reservation', 'CANDIDATE_FORM', '$parent_id',
  clock_timestamp() - interval '10 minutes', clock_timestamp() - interval '5 minutes', null
);
insert into public.storage_cleanup_queue(
  storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before, attempts, leased_until
) values (
  '$exhausted_queue', 'CANDIDATE_FORM', '$parent_id', '$exhausted_reservation',
  'candidate-quarantine', '$exhausted_path', 'SESSION_CANCELLED', 'PENDING',
  clock_timestamp() - interval '5 minutes', 5, clock_timestamp() - interval '1 second'
);
SQL
psql_exec -c "select public.claim_storage_cleanup_jobs('cleanup-exhaustion', 10, 60)" >/dev/null
[[ "$(psql_exec -c "select status_code || ':' || attempts from public.storage_cleanup_queue where storage_cleanup_id='$exhausted_queue'")" == "ERROR:5" ]] || {
  echo 'exhausted attempts must settle to ERROR and refuse further leases' >&2
  exit 1
}

# --- RACE 1: Signed Upload vs Session Cancel ---
candidate_auth="$(psql_exec -c 'select gen_random_uuid()')"
candidate_id="$(psql_exec -c 'select gen_random_uuid()')"
notice="s07-concurrency-${suffix}"
document_type="$(psql_exec -c 'select gen_random_uuid()')"
session_id="$(psql_exec -c 'select gen_random_uuid()')"
sign_reservation="$(psql_exec -c 'select gen_random_uuid()')"
scan_reservation="$(psql_exec -c 'select gen_random_uuid()')"
psql_exec <<SQL
insert into public.candidates(candidate_id,auth_user_id,email)
values('$candidate_id','$candidate_auth','s07-$candidate_id@example.test');
insert into public.privacy_notice_versions(notice_version,content_vi,content_hash_sha256,is_current)
values('$notice','s07 concurrency',repeat('d',64),false);
insert into public.document_types(document_type_id,code,name_vi,scope_code)
values('$document_type','S07C-${suffix:0:8}','S07 concurrency','SUBMISSION');
insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,presented_privacy_notice_version,expires_at)
values('$session_id','$candidate_id','NEW_SUBMISSION','$notice',clock_timestamp()+interval '1 hour');
insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,actor_auth_user_id,idempotency_key,expires_at,status_code)
values
('$sign_reservation','$session_id','$document_type','candidate-quarantine','temp/$session_id/$sign_reservation/sign.pdf','sign.pdf','$candidate_auth',gen_random_uuid(),clock_timestamp()+interval '30 minutes','RESERVED'),
('$scan_reservation','$session_id','$document_type','candidate-quarantine','temp/$session_id/$scan_reservation/scan.pdf','scan.pdf','$candidate_auth',gen_random_uuid(),clock_timestamp()+interval '30 minutes','UPLOADED');
update public.upload_reservations
set actual_size_bytes=1, checksum_sha256=repeat('a',64), detected_mime_type='application/pdf'
where upload_reservation_id='$scan_reservation';
SQL

candidate_sql_prefix="begin; select set_config('request.jwt.claim.sub','$candidate_auth',true);"
timeout 20 bash -c "printf \"%s select public.prepare_signed_upload('$sign_reservation'); commit;\" \"$candidate_sql_prefix\" | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/sign.json" 2>&1 &
sign_pid=$!
timeout 20 bash -c "printf \"%s select public.cancel_candidate_form_session('$session_id'); commit;\" \"$candidate_sql_prefix\" | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/cancel.json" 2>&1 &
cancel_pid=$!
wait "$sign_pid"
wait "$cancel_pid"

# Strengthened Race 1 assertion: Final database state must be canonical
sign_session_status="$(psql_exec -c "select status_code from public.candidate_form_sessions where candidate_form_session_id='$session_id'")"
[[ "$sign_session_status" == "CANCELLED" ]] || {
  echo "sign vs cancel: session status must be CANCELLED, got '$sign_session_status'" >&2
  exit 1
}
sign_res_status="$(psql_exec -c "select status_code from public.upload_reservations where upload_reservation_id='$sign_reservation'")"
[[ "$sign_res_status" == "CANCELLED" ]] || {
  echo "sign vs cancel: reservation status must be CANCELLED, got '$sign_res_status'" >&2
  exit 1
}
sign_cleanup_count="$(psql_exec -c "select count(*) from public.storage_cleanup_queue where bucket_name='candidate-quarantine' and object_path='temp/$session_id/$sign_reservation/sign.pdf'")"
[[ "$sign_cleanup_count" -ge 1 ]] || {
  echo "sign vs cancel: cleanup queue row must exist for cancelled reservation" >&2
  exit 1
}

# --- RACE 2: Document Scan Request vs Cancel ---
scan_session="$(psql_exec -c 'select gen_random_uuid()')"
scan_request_reservation="$(psql_exec -c 'select gen_random_uuid()')"
psql_exec <<SQL
insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,presented_privacy_notice_version,expires_at)
values('$scan_session','$candidate_id','NEW_SUBMISSION','$notice',clock_timestamp()+interval '1 hour');
insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,actor_auth_user_id,idempotency_key,expires_at,status_code,actual_size_bytes,checksum_sha256,detected_mime_type)
values('$scan_request_reservation','$scan_session','$document_type','candidate-quarantine','temp/$scan_session/$scan_request_reservation/request.pdf','request.pdf','$candidate_auth',gen_random_uuid(),clock_timestamp()+interval '30 minutes','UPLOADED',1,repeat('b',64),'application/pdf');
SQL
timeout 20 bash -c "printf \"%s select public.request_candidate_document_scan('$scan_session','$scan_request_reservation','ADD',null); commit;\" \"$candidate_sql_prefix\" | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/scan.json" 2>&1 &
scan_pid=$!
timeout 20 bash -c "printf \"%s select public.cancel_candidate_form_session('$scan_session'); commit;\" \"$candidate_sql_prefix\" | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/scan-cancel.json" 2>&1 &
scan_cancel_pid=$!
wait "$scan_pid"
wait "$scan_cancel_pid"

# Strengthened Race 2 assertion: Final database state must be canonical
scan_final_status="$(psql_exec -c "select status_code from public.candidate_form_sessions where candidate_form_session_id='$scan_session'")"
[[ "$scan_final_status" == "CANCELLED" ]] || {
  echo "scan vs cancel: session status must be CANCELLED, got '$scan_final_status'" >&2
  exit 1
}
scan_res_final_status="$(psql_exec -c "select status_code from public.upload_reservations where upload_reservation_id='$scan_request_reservation'")"
[[ "$scan_res_final_status" == "CANCELLED" ]] || {
  echo "scan vs cancel: reservation status must be CANCELLED, got '$scan_res_final_status'" >&2
  exit 1
}
scan_cleanup_count="$(psql_exec -c "select count(*) from public.storage_cleanup_queue where bucket_name='candidate-quarantine' and object_path='temp/$scan_session/$scan_request_reservation/request.pdf'")"
[[ "$scan_cleanup_count" -ge 1 ]] || {
  echo "scan vs cancel: cleanup queue row must exist for cancelled reservation" >&2
  exit 1
}

# --- RACE 3: Interview Finalize vs Delete ---
staff_auth="$(psql_exec -c 'select gen_random_uuid()')"
staff_id="$(psql_exec -c 'select gen_random_uuid()')"
interview_candidate_auth="$(psql_exec -c 'select gen_random_uuid()')"
interview_candidate_id="$(psql_exec -c 'select gen_random_uuid()')"
interview_submission="$(psql_exec -c 'select gen_random_uuid()')"
interview_unit="$(psql_exec -c 'select gen_random_uuid()')"
interview_group="$(psql_exec -c 'select gen_random_uuid()')"
interview_position="$(psql_exec -c 'select gen_random_uuid()')"
interview_document_type="$(psql_exec -c 'select gen_random_uuid()')"
interview_id="$(psql_exec -c 'select gen_random_uuid()')"
application_id="$(psql_exec -c 'select gen_random_uuid()')"
interview_reservation="$(psql_exec -c 'select gen_random_uuid()')"
psql_exec <<SQL
insert into public.app_users(app_user_id,auth_user_id,email,full_name)
values('$staff_id','$staff_auth','s07-$staff_id@eiu.edu.vn','S07 concurrency');
insert into public.app_user_roles(app_user_id,role_code)
values('$staff_id','HR');
insert into public.permissions(permission_code,description)
values('interviews.manage','S07 test permission'),('interviews.view','S07 test permission'),('interviews.documents','S07 test permission')
on conflict(permission_code) do nothing;
insert into public.app_user_permissions(app_user_id,permission_code)
values('$staff_id','interviews.manage'),('$staff_id','interviews.view'),('$staff_id','interviews.documents');
insert into public.candidates(candidate_id,auth_user_id,email)
values('$interview_candidate_id','$interview_candidate_auth','s07-$interview_candidate_id@example.test');
insert into public.submissions(
  submission_id,candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot
) values (
  '$interview_submission','$interview_candidate_id','S07',date '2000-01-01','FEMALE',
  'test','0000000000','s07-$interview_submission@example.test'
);
insert into public.organizational_units(unit_id,code,name_vi)
values('$interview_unit','S07U-${suffix:0:8}','S07 concurrency');
insert into public.position_groups(position_group_id,code,name_vi)
values('$interview_group','S07G-${suffix:0:8}','S07 concurrency');
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi)
values('$interview_position','$interview_unit','$interview_group','S07P-${suffix:0:8}','S07 concurrency');
insert into public.document_types(document_type_id,code,name_vi,scope_code)
values('$interview_document_type','S07I-${suffix:0:8}','S07 concurrency','INTERVIEW');
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id)
values('$application_id','$interview_submission','$interview_unit','$interview_position','$staff_id');
insert into public.interviews(interview_id,application_id,round_no)
values('$interview_id','$application_id',1);
insert into public.upload_reservations(
  upload_reservation_id,interview_id,intended_document_type_id,temp_bucket,temp_path,
  original_filename,actor_auth_user_id,idempotency_key,expires_at,status_code,
  malware_scan_status,actual_size_bytes,checksum_sha256,detected_mime_type
) values (
  '$interview_reservation','$interview_id','$interview_document_type','interview-quarantine',
  'temp/interview/$interview_id/$interview_reservation','finalize.pdf','$staff_auth',
  gen_random_uuid(),clock_timestamp()+interval '30 minutes','UPLOADED','CLEAN',
  1,repeat('c',64),'application/pdf'
);
SQL
staff_sql_prefix="begin; set local request.jwt.claim.sub='$staff_auth';"
timeout 20 bash -c "printf \"%s select public.finalize_interview_upload('$interview_reservation',null,'interview-quarantine','temp/interview/$interview_id/$interview_reservation','finalize.pdf','application/pdf',1,repeat('c',64),null); commit;\" \"$staff_sql_prefix\" | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/finalize.json" 2>"$tmp_dir/finalize.err" &
finalize_pid=$!
timeout 20 bash -c "printf \"%s select public.delete_or_inactivate_interview('$interview_id',1); commit;\" \"$staff_sql_prefix\" | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/interview-delete.json" 2>"$tmp_dir/interview-delete.err" &
delete_pid=$!
wait "$finalize_pid"
wait "$delete_pid"

# Strengthened Race 3 assertion: Interview must end DELETED or INACTIVATED; cleanup queue row must exist
int_status="$(psql_exec -c "select coalesce((select case when not is_active then 'INACTIVATED' else schedule_status_code end from public.interviews where interview_id='$interview_id'), 'DELETED')")"
[[ "$int_status" == "DELETED" || "$int_status" == "INACTIVATED" || "$int_status" == "CANCELLED" ]] || {
  echo "finalize vs delete: interview must be DELETED, INACTIVATED, or CANCELLED, got '$int_status'" >&2
  exit 1
}
int_cleanup_count="$(psql_exec -c "select count(*) from public.storage_cleanup_queue where bucket_name='interview-quarantine' and object_path='temp/interview/$interview_id/$interview_reservation'")"
int_doc_exists="$(psql_exec -c "select count(*) from public.interview_documents where storage_bucket='interview-quarantine' and storage_path='temp/interview/$interview_id/$interview_reservation'")"
if [[ "$int_status" == "DELETED" ]]; then
  [[ "$int_cleanup_count" -ge 1 && "$int_doc_exists" -eq 0 ]] || {
    echo "finalize vs delete: deleted interview must enqueue cleanup and have no documents" >&2
    exit 1
  }
else
  [[ "$int_doc_exists" -ge 1 ]] || {
    echo "finalize vs delete: inactivated interview must retain finalized document" >&2
    exit 1
  }
fi

# --- RACE 4: Candidate Cleanup Authorization vs Document Materialization Race (R2) ---
# Tests the destructive authorization seam (public.authorize_storage_cleanup_attempt)
# against Candidate document materialization on the exact same storage identity.
cand_race_auth="$(psql_exec -c 'select gen_random_uuid()')"
cand_race_cand="$(psql_exec -c 'select gen_random_uuid()')"
cand_race_session="$(psql_exec -c 'select gen_random_uuid()')"
cand_race_res="$(psql_exec -c 'select gen_random_uuid()')"
cand_race_sub="$(psql_exec -c 'select gen_random_uuid()')"
cand_race_log="$(psql_exec -c 'select gen_random_uuid()')"
cand_race_queue="$(psql_exec -c 'select gen_random_uuid()')"
cand_race_path="temp/${cand_race_session}/${cand_race_res}/cand_race.pdf"

psql_exec <<SQL
insert into public.candidates(candidate_id, auth_user_id, email)
values ('$cand_race_cand', '$cand_race_auth', 'cand-race-${suffix}@example.test');

insert into public.candidate_form_sessions(
  candidate_form_session_id, candidate_id, mode_code, presented_privacy_notice_version, status_code, expires_at
) values (
  '$cand_race_session', '$cand_race_cand', 'NEW_SUBMISSION', '$notice', 'CANCELLED', clock_timestamp() - interval '1 hour'
);

insert into public.submissions(
  submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot
) values (
  '$cand_race_sub', '$cand_race_cand', 'Race Cand', date '2000-01-01', 'FEMALE',
  'address', '0000000000', 'cand-race-${suffix}@example.test'
);

insert into public.submission_document_logicals(
  logical_document_id, submission_id, document_type_id, created_by_candidate_id
) values (
  '$cand_race_log', '$cand_race_sub', '$document_type', '$cand_race_cand'
);

insert into public.upload_reservations(
  upload_reservation_id, candidate_form_session_id, intended_document_type_id,
  temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key,
  expires_at, signed_upload_expires_at, status_code
) values (
  '$cand_race_res', '$cand_race_session', '$document_type',
  'candidate-quarantine', '$cand_race_path', 'cand_race.pdf',
  '$cand_race_auth', gen_random_uuid(),
  clock_timestamp() - interval '1 hour', clock_timestamp() - interval '30 minutes',
  'CANCELLED'
);

insert into public.storage_cleanup_queue(
  storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before
) values (
  '$cand_race_queue', 'CANDIDATE_FORM', '$cand_race_session', '$cand_race_res',
  'candidate-quarantine', '$cand_race_path', 'SESSION_CANCELLED', 'PENDING',
  clock_timestamp() - interval '10 minutes'
);
SQL

# Worker claims candidate cleanup job
cand_claim="$(psql_exec -c "select public.claim_storage_cleanup_jobs('worker-cand-race', 10, 60)")"
cand_attempt="$(printf '%s' "$cand_claim" | jq -r --arg q "$cand_race_queue" '.data[]? | select(.storage_cleanup_id == $q) | .attempt_id // empty')"
cand_token="$(printf '%s' "$cand_claim" | jq -r --arg q "$cand_race_queue" '.data[]? | select(.storage_cleanup_id == $q) | .fencing_token // empty')"
[[ -n "$cand_attempt" && -n "$cand_token" ]] || {
  echo "worker-cand-race failed to claim candidate cleanup job" >&2
  exit 1
}

# Race cleanup authorization vs candidate document materialization
timeout 20 bash -c "printf 'select public.authorize_storage_cleanup_attempt(\x27$cand_race_queue\x27, \x27$cand_attempt\x27, \x27$cand_token\x27, \x27worker-cand-race\x27);' | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/cand-auth.json" 2>"$tmp_dir/cand-auth.err" &
cand_auth_pid=$!

timeout 20 bash -c "printf 'begin; set local request.jwt.claim.sub=\x27$cand_race_auth\x27; insert into public.submission_documents(logical_document_id, storage_bucket, storage_path, original_filename, mime_type, file_size_bytes, checksum_sha256, version_no, is_current, uploaded_by_candidate_id) values (\x27$cand_race_log\x27, \x27candidate-quarantine\x27, \x27$cand_race_path\x27, \x27cand_race.pdf\x27, \x27application/pdf\x27, 1024, repeat(\x27e\x27, 64), 1, true, \x27$cand_race_cand\x27); commit;' | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/cand-mat.out" 2>"$tmp_dir/cand-mat.err" &
cand_mat_pid=$!

wait "$cand_auth_pid"
wait "$cand_mat_pid"

cand_auth_res="$(cat "$tmp_dir/cand-auth.json" 2>/dev/null || echo '')"
cand_auth_success="$(printf '%s' "$cand_auth_res" | jq -r '.success // false' 2>/dev/null || echo 'false')"
cand_doc_count="$(psql_exec -c "select count(*) from public.submission_documents where storage_bucket='candidate-quarantine' and storage_path='$cand_race_path'")"
cand_tombstoned="$(psql_exec -c "select count(*) from private.storage_cleanup_provenance where bucket_name='candidate-quarantine' and object_path='$cand_race_path' and tombstoned_at is not null")"
cand_q_state="$(psql_exec -c "select status_code || '|' || coalesce(eligibility_code, 'none') from public.storage_cleanup_queue where storage_cleanup_id='$cand_race_queue'")"

# Assert no impossible dual-success state
if [[ "$cand_tombstoned" -ge 1 && "$cand_doc_count" -ge 1 ]]; then
  echo "FAIL: Impossible dual-success state: candidate document committed and cleanup tombstoned simultaneously for $cand_race_path" >&2
  exit 1
fi
if [[ "$cand_auth_success" == "true" && "$cand_doc_count" -ge 1 ]]; then
  echo "FAIL: Cleanup authorized but candidate document exists" >&2
  exit 1
fi
if [[ "$cand_auth_success" == "true" ]]; then
  [[ "$cand_tombstoned" -eq 1 && "$cand_doc_count" -eq 0 ]] || {
    echo "FAIL: Cleanup authorized but tombstone count is $cand_tombstoned and doc count is $cand_doc_count" >&2
    exit 1
  }
else
  [[ "$cand_tombstoned" -eq 0 ]] || {
    echo "FAIL: Cleanup withheld but tombstone was created" >&2
    exit 1
  }
  if [[ "$cand_doc_count" -ge 1 ]]; then
    [[ "$cand_q_state" == "ERROR|RETAINED_REFERENCE" ]] || {
      echo "FAIL: When candidate document won, queue must be ERROR|RETAINED_REFERENCE, got '$cand_q_state'" >&2
      exit 1
    }
  fi
fi

# --- RACE 5: Interview Cleanup Authorization vs Finalization Race (R2) ---
# Tests the destructive authorization seam (public.authorize_storage_cleanup_attempt)
# against public.finalize_interview_upload on the exact same Interview storage identity.
# A finalizable live Interview reservation is itself canonically sufficient to deny
# destructive cleanup authorization (mutual exclusion).
int_race_id="$(psql_exec -c 'select gen_random_uuid()')"
int_race_res="$(psql_exec -c 'select gen_random_uuid()')"
int_race_queue="$(psql_exec -c 'select gen_random_uuid()')"
int_race_path="temp/interview/${int_race_id}/${int_race_res}"
int_attempt="$(psql_exec -c 'select gen_random_uuid()')"
int_token="$(psql_exec -c 'select gen_random_uuid()')"

psql_exec <<SQL
insert into public.interviews(interview_id, application_id, round_no)
values ('$int_race_id', '$application_id', 2);

insert into public.upload_reservations(
  upload_reservation_id, interview_id, intended_document_type_id, temp_bucket, temp_path,
  original_filename, actor_auth_user_id, idempotency_key, expires_at, signed_upload_expires_at,
  status_code, malware_scan_status, actual_size_bytes, checksum_sha256, detected_mime_type
) values (
  '$int_race_res', '$int_race_id', '$interview_document_type', 'interview-quarantine',
  '$int_race_path', 'int_race.pdf', '$staff_auth',
  gen_random_uuid(), clock_timestamp() + interval '30 minutes', clock_timestamp() - interval '5 minutes',
  'UPLOADED', 'CLEAN', 1024, repeat('d', 64), 'application/pdf'
);

insert into public.storage_cleanup_queue(
  storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before,
  worker_id, attempt_id, fencing_token, attempts, leased_until
) values (
  '$int_race_queue', 'INTERVIEW_UPLOAD', '$int_race_id', '$int_race_res',
  'interview-quarantine', '$int_race_path', 'INTERVIEW_HARD_DELETE', 'PROCESSING',
  clock_timestamp() - interval '5 minutes',
  'worker-int-race', '$int_attempt', '$int_token', 1, clock_timestamp() + interval '60 seconds'
);
SQL

# Race cleanup authorization vs interview finalize upload
timeout 20 bash -c "printf 'select public.authorize_storage_cleanup_attempt(\x27$int_race_queue\x27, \x27$int_attempt\x27, \x27$int_token\x27, \x27worker-int-race\x27);' | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/int-auth.json" 2>"$tmp_dir/int-auth.err" &
int_auth_pid=$!

timeout 20 bash -c "printf 'begin; set local request.jwt.claim.sub=\x27$staff_auth\x27; select public.finalize_interview_upload(\x27$int_race_res\x27, null, \x27interview-quarantine\x27, \x27$int_race_path\x27, \x27int_race.pdf\x27, \x27application/pdf\x27, 1024, repeat(\x27d\x27, 64), null); commit;' | docker exec -i '$container_name' psql -qAt -v ON_ERROR_STOP=0 -U postgres -d postgres" >"$tmp_dir/int-finalize.json" 2>"$tmp_dir/int-finalize.err" &
int_fin_pid=$!

wait "$int_auth_pid"
wait "$int_fin_pid"

int_auth_res="$(cat "$tmp_dir/int-auth.json" 2>/dev/null || echo '')"
int_auth_success="$(printf '%s' "$int_auth_res" | jq -r '.success // false' 2>/dev/null || echo 'false')"
int_auth_err="$(printf '%s' "$int_auth_res" | jq -r '.error_code // empty' 2>/dev/null || echo '')"
int_fin_res="$(cat "$tmp_dir/int-finalize.json" 2>/dev/null || echo '')"
int_fin_success="$(printf '%s' "$int_fin_res" | jq -r '.success // false' 2>/dev/null || echo 'false')"
int_doc_count="$(psql_exec -c "select count(*) from public.interview_documents where storage_bucket='interview-quarantine' and storage_path='$int_race_path'")"
int_tombstoned="$(psql_exec -c "select count(*) from private.storage_cleanup_provenance where bucket_name='interview-quarantine' and object_path='$int_race_path' and tombstoned_at is not null")"
int_q_status="$(psql_exec -c "select status_code from public.storage_cleanup_queue where storage_cleanup_id='$int_race_queue'")"
int_q_eligibility="$(psql_exec -c "select coalesce(eligibility_code, 'none') from public.storage_cleanup_queue where storage_cleanup_id='$int_race_queue'")"

# Assertion 1: Cleanup authorization must NOT succeed against a finalizable live reservation
[[ "$int_auth_success" == "false" ]] || {
  echo "FAIL: Cleanup authorization must not succeed while a finalizable live reservation exists" >&2
  exit 1
}
[[ "$int_auth_err" == "CLEANUP_WITHHELD" ]] || {
  echo "FAIL: Expected error_code CLEANUP_WITHHELD, got '$int_auth_err'" >&2
  exit 1
}

# Assertion 2: No cleanup tombstone may be created
[[ "$int_tombstoned" -eq 0 ]] || {
  echo "FAIL: Cleanup tombstone must not be created for live finalizable reservation" >&2
  exit 1
}

# Assertion 3 & 4: Queue must settle to expected protected state with canonical eligibility reason
# (SIGNED_WINDOW because expires_at > clock_timestamp(), or LIVE_RESERVATION/RETAINED_REFERENCE)
[[ "$int_q_status" == "PENDING" || "$int_q_status" == "ERROR" ]] || {
  echo "FAIL: Queue status must settle to PENDING or ERROR, got '$int_q_status'" >&2
  exit 1
}
[[ "$int_q_eligibility" == "SIGNED_WINDOW" || "$int_q_eligibility" == "LIVE_RESERVATION" || "$int_q_eligibility" == "RETAINED_REFERENCE" ]] || {
  echo "FAIL: Expected canonical eligibility protection (SIGNED_WINDOW, LIVE_RESERVATION, or RETAINED_REFERENCE), got '$int_q_eligibility'" >&2
  exit 1
}

# Assertion 5 & 6: Finalize succeeds and exactly one interview document exists
[[ "$int_fin_success" == "true" ]] || {
  echo "FAIL: Finalize interview upload should succeed under valid business state, got '$int_fin_res'" >&2
  exit 1
}
[[ "$int_doc_count" -eq 1 ]] || {
  echo "FAIL: Exactly one interview document must exist after finalization, got '$int_doc_count'" >&2
  exit 1
}

# Assertion 7: There must be no impossible dual-success state
if [[ "$int_tombstoned" -ge 1 && "$int_doc_count" -ge 1 ]]; then
  echo "FAIL: Impossible dual-success state: interview document committed and cleanup tombstoned simultaneously" >&2
  exit 1
fi

# --- PHASE 5B: Terminal Interview Reservation Cleanup Authorization & Tombstone ---
# Proves that once an Interview reservation is legitimately terminal/detached (non-finalizable),
# cleanup authorization succeeds, records a tombstone, and prevents any subsequent resurrection.
int_term_id="$(psql_exec -c 'select gen_random_uuid()')"
int_term_res="$(psql_exec -c 'select gen_random_uuid()')"
int_term_queue="$(psql_exec -c 'select gen_random_uuid()')"
int_term_path="temp/interview/${int_term_id}/${int_term_res}"
int_term_attempt="$(psql_exec -c 'select gen_random_uuid()')"
int_term_token="$(psql_exec -c 'select gen_random_uuid()')"

psql_exec <<SQL
insert into public.interviews(interview_id, application_id, round_no)
values ('$int_term_id', '$application_id', 3);

insert into public.upload_reservations(
  upload_reservation_id, interview_id, intended_document_type_id, temp_bucket, temp_path,
  original_filename, actor_auth_user_id, idempotency_key, expires_at, signed_upload_expires_at,
  status_code, malware_scan_status, actual_size_bytes, checksum_sha256, detected_mime_type
) values (
  '$int_term_res', '$int_term_id', '$interview_document_type', 'interview-quarantine',
  '$int_term_path', 'term.pdf', '$staff_auth',
  gen_random_uuid(), clock_timestamp() - interval '20 minutes', clock_timestamp() - interval '10 minutes',
  'CANCELLED', 'CLEAN', 1024, repeat('d', 64), 'application/pdf'
);

insert into public.storage_cleanup_queue(
  storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
  bucket_name, object_path, reason_code, status_code, not_before,
  worker_id, attempt_id, fencing_token, attempts, leased_until
) values (
  '$int_term_queue', 'INTERVIEW_UPLOAD', '$int_term_id', '$int_term_res',
  'interview-quarantine', '$int_term_path', 'INTERVIEW_HARD_DELETE', 'PROCESSING',
  clock_timestamp() - interval '10 minutes',
  'worker-term-race', '$int_term_attempt', '$int_term_token', 1, clock_timestamp() + interval '60 seconds'
);
SQL

# Authorize cleanup on terminal reservation
term_auth="$(psql_exec -c "select public.authorize_storage_cleanup_attempt('$int_term_queue', '$int_term_attempt', '$int_term_token', 'worker-term-race');")"
term_auth_success="$(printf '%s' "$term_auth" | jq -r '.success // false')"
term_tombstoned="$(psql_exec -c "select count(*) from private.storage_cleanup_provenance where bucket_name='interview-quarantine' and object_path='$int_term_path' and tombstoned_at is not null")"

[[ "$term_auth_success" == "true" ]] || {
  echo "FAIL: Terminal reservation cleanup authorization must succeed, got '$term_auth'" >&2
  exit 1
}
[[ "$term_tombstoned" -eq 1 ]] || {
  echo "FAIL: Terminal reservation cleanup must record tombstone, got count '$term_tombstoned'" >&2
  exit 1
}

# Subsequent attempt to insert a document for this tombstoned identity must be rejected by trigger
term_resurrect_err="$(psql_exec -c "
do \$\$
begin
  insert into public.interview_documents(
    logical_document_id, storage_bucket, storage_path, original_filename,
    mime_type, file_size_bytes, checksum_sha256, version_no, is_current, uploaded_by
  ) values (
    (select logical_document_id from public.interview_document_logicals where interview_id='$int_term_id' limit 1),
    'interview-quarantine', '$int_term_path', 'term.pdf',
    'application/pdf', 1024, repeat('d', 64), 1, true, '$staff_auth'
  );
exception when others then
  raise notice 'RESURRECTION_REJECTED: %', sqlerrm;
end;
\$\$;
" 2>&1 || true)"
[[ "$term_resurrect_err" == *"STORAGE_CLEANUP_IDENTITY_TOMBSTONED"* ]] || {
  echo "FAIL: Document resurrection against tombstoned identity must raise STORAGE_CLEANUP_IDENTITY_TOMBSTONED, got '$term_resurrect_err'" >&2
  exit 1
}
term_doc_count="$(psql_exec -c "select count(*) from public.interview_documents where storage_bucket='interview-quarantine' and storage_path='$int_term_path'")"
[[ "$term_doc_count" -eq 0 ]] || {
  echo "FAIL: Tombstoned identity must have 0 documents, got '$term_doc_count'" >&2
  exit 1
}

echo "TASK-S07-003 concurrent cleanup, reclaim, signing/cancel, scan/cancel, Interview finalize/delete, and candidate/interview authorization races passed ($suffix)"
