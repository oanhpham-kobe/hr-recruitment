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

container_name="${CONTAINER_NAME:-supabase_db_eiu-recruitment-dev}"
psql_exec() { docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
suffix="$(uuidgen | tr -d '-')"
ids="$(psql_exec -c "select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()")"
read -r candidate session reservation request <<<"${ids//|/ }"
doc_type="$(psql_exec -c "select document_type_id from public.document_types where code='CV_RESUME' limit 1")"
psql_exec <<SQL
insert into public.privacy_notice_versions(notice_version,content_vi,content_en,content_hash_sha256,published_at,effective_from,is_current)
values('scan-race-${suffix}','S07 scan race','S07 scan race',repeat('f',64),clock_timestamp(),clock_timestamp(),false);
insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active)
values('$candidate'::uuid,gen_random_uuid(),'scan-race-${suffix}@example.invalid','Scan Race',true);
insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,status_code,presented_privacy_notice_version,expires_at)
values('$session'::uuid,'$candidate'::uuid,'NEW_SUBMISSION','OPEN','scan-race-${suffix}',clock_timestamp()+interval '1 hour');
insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,declared_mime_type,expected_max_size_bytes,actual_size_bytes,detected_mime_type,checksum_sha256,status_code,malware_scan_status,actor_auth_user_id,idempotency_key,expires_at)
values('$reservation'::uuid,'$session'::uuid,'$doc_type'::uuid,'candidate-quarantine','scan-race/${suffix}.pdf','cv.pdf','application/pdf',5242880,10,'application/pdf',repeat('c',64),'UPLOADED','PENDING',gen_random_uuid(),gen_random_uuid(),clock_timestamp()+interval '1 hour');
insert into public.document_scan_requests(document_scan_request_id,upload_reservation_id,candidate_form_session_id,action_code,intended_document_type_id,bucket_name,object_path,checksum_sha256,object_fingerprint,detected_mime_type,actual_size_bytes)
values('$request'::uuid,'$reservation'::uuid,'$session'::uuid,'ADD','$doc_type'::uuid,'candidate-quarantine','scan-race/${suffix}.pdf',repeat('c',64),repeat('d',64),'application/pdf',10);
SQL
psql_exec -c "delete from public.document_scan_requests where status_code in ('PENDING', 'PROCESSING') and document_scan_request_id <> '$request'::uuid;"
claim="begin; select public.claim_document_scan_requests('race-worker',1,60); commit"
tmp_scan_a=".tmp_scan_a_${suffix}.txt"
tmp_scan_b=".tmp_scan_b_${suffix}.txt"
trap 'rm -f "$tmp_scan_a" "$tmp_scan_b"' EXIT
psql_exec -c "$claim" >"$tmp_scan_a" & a=$!
psql_exec -c "$claim" >"$tmp_scan_b" & b=$!
wait "$a"; wait "$b"
combined="$(cat "$tmp_scan_a" "$tmp_scan_b" | tr -d '\r')"
if [[ "$(jq -s 'map(.data|length)|add' <<<"$combined")" != "1" ]]; then echo 'concurrent claims must yield one live owner' >&2; exit 1; fi
attempt="$(jq -r 'select(.data|length==1).data[0].attempt_id' <<<"$combined")"
token="$(jq -r 'select(.data|length==1).data[0].fencing_token' <<<"$combined")"
psql_exec -c "update public.document_scan_requests set leased_until=clock_timestamp()-interval '1 second' where document_scan_request_id='$request'::uuid"
reclaim="$(psql_exec -c "begin; select public.claim_document_scan_requests('reclaim-worker',1,60); commit")"
new_attempt="$(jq -r '.data[0].attempt_id' <<<"$reclaim")"; new_token="$(jq -r '.data[0].fencing_token' <<<"$reclaim")"
if [[ "$new_attempt" == "$attempt" || "$new_token" == "$token" ]]; then echo 'expired lease must receive a new fenced attempt' >&2; exit 1; fi
stale="$(psql_exec -c "begin; select public.complete_document_scan_attempt('$request'::uuid,'$attempt'::uuid,'$token'::uuid,'race-worker','CLEAN',null); commit")"
if [[ "$(jq -r '.error_code' <<<"$stale")" != "STALE_ATTEMPT" ]]; then echo 'late completion after reclaim must be stale' >&2; exit 1; fi
echo "TASK-S07-002 scan claim/fencing concurrency assertions passed (${suffix})"
