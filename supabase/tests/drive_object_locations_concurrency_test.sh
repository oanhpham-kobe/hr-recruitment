#!/usr/bin/env bash
set -euo pipefail
: "${CONTAINER_NAME:?Explicit disposable container required}"
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then
  expected_project='eiu-recruitment-dev'
else
  : "${DISPOSABLE_PROJECT_ID:?Explicit disposable test project required}"
  [[ "$DISPOSABLE_PROJECT_ID" =~ ^eiu-workflow-check-[A-Za-z0-9_-]+$ ]] || {
    echo 'Refusing a project outside the disposable test namespace' >&2; exit 1;
  }
  expected_project="$DISPOSABLE_PROJECT_ID"
fi
[[ "$CONTAINER_NAME" == "supabase_db_$expected_project" ]] || {
  echo 'Disposable project and container identities differ' >&2; exit 1;
}
actual_project="$(docker inspect --format '{{index .Config.Labels "com.supabase.cli.project"}}' "$CONTAINER_NAME" | tr -d '\r')"
[[ "$actual_project" == "$expected_project" ]] || {
  echo 'Container is not the designated Supabase test project' >&2; exit 1;
}
sql() { docker exec -i "$CONTAINER_NAME" psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres "$@" | tr -d '\r'; }
suffix="$(sql -c "select left(replace(gen_random_uuid()::text,'-',''),12)")"
scratch="$(mktemp -d)"
trap 'rm -f "$scratch"/*.log; rmdir "$scratch"' EXIT
c="$(sql -c 'select gen_random_uuid()')"
a="$(sql -c 'select gen_random_uuid()')"
s="$(sql -c 'select gen_random_uuid()')"
r="$(sql -c 'select gen_random_uuid()')"
t="$(sql -c 'select gen_random_uuid()')"
sql <<SQL
insert into public.candidates(candidate_id,auth_user_id,email,is_active) values('$c','$a','$c@example.invalid',true);
insert into public.privacy_notice_versions(notice_version,content_vi,content_hash_sha256,is_current)
values('$suffix','Drive race',repeat('a',64),false);
insert into public.document_types(document_type_id,code,name_vi,scope_code) values('$t','DR-$suffix','Drive','SUBMISSION');
insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,presented_privacy_notice_version,expires_at)
values('$s','$c','NEW_SUBMISSION','$suffix',clock_timestamp()+interval '1 hour');
insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,actor_auth_user_id,idempotency_key,expires_at)
values('$r','$s','$t','candidate-quarantine','temp/$s/$r/cv.pdf','cv.pdf','$a',gen_random_uuid(),clock_timestamp()+interval '1 hour');
SQL

wait_query() {
  local query="$1"
  for i in $(seq 1 120); do
    [[ "$(sql -c "$query")" == t ]] && return 0
    sleep 0.05
  done
  cat "$scratch"/*.log >&2
  echo 'Synchronization condition not reached' >&2; exit 1
}

run_race() {
  local label="$1" holder_sql="$2" contender_sql="$3" expected="$4"
  local gate="drive-gate-$suffix-$label" holder="drive-holder-$suffix-$label" contender="drive-contender-$suffix-$label"
  sql -c "set application_name='$gate'; select pg_advisory_lock(hashtextextended('$gate',0)); select pg_sleep(30);" >"$scratch/gate.log" 2>&1 &
  local gp=$!
  wait_query "select exists(select 1 from pg_stat_activity where application_name='$gate' and wait_event='PgSleep');"
  sql -c "set application_name='$holder'; begin; $holder_sql; select pg_advisory_lock(hashtextextended('$gate',0)); commit;" >"$scratch/holder.log" 2>&1 &
  local hp=$!
  wait_query "select exists(select 1 from pg_stat_activity where application_name='$holder' and wait_event='advisory');"
  sql -c "set application_name='$contender'; set role drive_storage_worker; $contender_sql;" >"$scratch/contender.log" 2>&1 &
  local cp=$!
  wait_query "select exists(select 1 from pg_stat_activity h join pg_stat_activity c on h.pid=any(pg_blocking_pids(c.pid)) where h.application_name='$holder' and c.application_name='$contender');"
  sql -c "select pg_cancel_backend(pid) from pg_stat_activity where application_name='$gate';" >/dev/null
  wait "$gp" || true
  wait "$hp"
  if wait "$cp"; then echo 'Contender unexpectedly succeeded' >&2; exit 1; fi
  grep -q "$expected" "$scratch/contender.log"
  echo "PASS synchronized $label: $expected"
}

run_race bind \
  "set local role drive_storage_worker; select public.bind_candidate_drive_object('$r','$a','drive_$suffix')" \
  "select public.bind_candidate_drive_object('$r','$a','other_$suffix')" \
  IDEMPOTENCY_CONFLICT

# Cancel takes the exact session lock used by real cancellation. The waiting
# public worker operation must recheck the committed terminal state after wait.
run_race cancel \
  "update public.candidate_form_sessions set status_code='CANCELLED' where candidate_form_session_id='$s'" \
  "select public.claim_drive_upload_attempt('$r','$a','race-worker',120)" \
  INVALID_STATE

fresh_reservation() {
  s="$(sql -c 'select gen_random_uuid()')"
  r="$(sql -c 'select gen_random_uuid()')"
  sql <<SQL
insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,presented_privacy_notice_version,expires_at)
values('$s','$c','NEW_SUBMISSION','$suffix',clock_timestamp()+interval '1 hour');
insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,actor_auth_user_id,idempotency_key,expires_at)
values('$r','$s','$t','candidate-quarantine','temp/$s/$r/cv.pdf','cv.pdf','$a',gen_random_uuid(),clock_timestamp()+interval '1 hour');
SQL
}
fresh_reservation
sql -c "set role drive_storage_worker; select public.bind_candidate_drive_object('$r','$a','expiry_$suffix');" >/dev/null
run_race expiry \
  "update public.candidate_form_sessions set expires_at=clock_timestamp()-interval '1 second' where candidate_form_session_id='$s'" \
  "select public.claim_drive_upload_attempt('$r','$a','race-worker',120)" \
  INVALID_STATE

fresh_reservation
run_race signed_issuance \
  "set local role authenticated; select set_config('request.jwt.claim.sub','$a',true); select public.prepare_signed_upload('$r')" \
  "select public.bind_candidate_drive_object('$r','$a','signed_$suffix')" \
  STORAGE_PROVIDER_CONFLICT

fresh_reservation
sql -c "insert into storage.buckets(id,name,public) values('candidate-quarantine','candidate-quarantine',false) on conflict do nothing;"
run_race storage_insert \
  "set local role service_role; insert into storage.objects(bucket_id,name) values('candidate-quarantine','temp/$s/$r/cv.pdf')" \
  "select public.bind_candidate_drive_object('$r','$a','storage_$suffix')" \
  STORAGE_PROVIDER_CONFLICT
echo 'Drive synchronized bind/cancel/expiry/signed-issuance/Storage races passed'

# Audit writes carry an actor_app_user_id FK. Pause the real public read RPC
# immediately before that FK check, then run the real User lifecycle command.
# Both commands must complete without a User-row/User-advisory lock inversion.
reader="$(sql -c 'select gen_random_uuid()')"
reader_auth="$(sql -c 'select gen_random_uuid()')"
submission="$(sql -c 'select gen_random_uuid()')"
logical="$(sql -c 'select gen_random_uuid()')"
document="$(sql -c 'select gen_random_uuid()')"
read_app="drive-read-$suffix"
mutate_app="drive-user-$suffix"
audit_gate="drive-audit-$suffix"
sql <<SQL
insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin)
select gen_random_uuid(),gen_random_uuid(),'drive-root-$suffix@eiu.edu.vn','Drive race Root',true,true
where not exists(select 1 from public.app_users where is_root_admin);
insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active)
values('$reader','$reader_auth','drive-reader-$suffix@eiu.edu.vn','Drive race reader',true);
insert into public.app_user_roles(app_user_id,role_code) values('$reader','HR');
insert into public.app_user_permissions(app_user_id,permission_code) values('$reader','submissions.view');
insert into public.submissions(submission_id,candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot)
values('$submission','$c','Drive race',date '2000-01-01','FEMALE','test','0000000000','$c@example.invalid');
insert into public.submission_document_logicals(logical_document_id,submission_id,document_type_id,created_by_candidate_id)
values('$logical','$submission','$t','$c');
-- Trusted synthetic CLEAN/SEALED fixture; no production scanner is implied.
insert into private.storage_object_locations(bucket_name,object_path,upload_reservation_id,provider_file_id,state_code,checksum_sha256,actual_size_bytes,detected_mime_type,sealed_at)
values('candidate-quarantine','read/$document',gen_random_uuid(),'read_$suffix','SEALED',repeat('a',64),10,'application/pdf',clock_timestamp());
insert into public.submission_documents(document_id,logical_document_id,storage_bucket,storage_path,original_filename,mime_type,file_size_bytes,checksum_sha256,version_no,is_current,uploaded_by_candidate_id)
values('$document','$logical','candidate-quarantine','read/$document','cv.pdf','application/pdf',10,repeat('a',64),1,true,'$c');
create function private.drive_audit_gate_$suffix() returns trigger language plpgsql security definer set search_path='' as \$\$
begin
  if new.entity_id='$document'::uuid and current_setting('application_name')='$read_app' then
    perform pg_advisory_xact_lock(hashtextextended('$audit_gate',0));
  end if;
  return new;
end \$\$;
create trigger drive_audit_gate_$suffix before insert on public.security_audit_log
for each row execute function private.drive_audit_gate_$suffix();
SQL
root_auth="$(sql -c 'select auth_user_id from public.app_users where is_root_admin and is_active')"
reader_version="$(sql -c "select version_no from public.app_users where app_user_id='$reader'")"
sql -c "set application_name='$audit_gate'; select pg_advisory_lock(hashtextextended('$audit_gate',0)); select pg_sleep(30);" >"$scratch/audit-gate.log" 2>&1 &
gate_pid=$!
wait_query "select exists(select 1 from pg_stat_activity where application_name='$audit_gate' and wait_event='PgSleep');"
sql -c "set application_name='$read_app'; set role drive_storage_worker; select public.authorize_drive_document_read('$reader_auth','$submission','$logical','$document','download');" >"$scratch/read.log" 2>&1 &
read_pid=$!
wait_query "select exists(select 1 from pg_stat_activity where application_name='$read_app' and wait_event='advisory');"
sql -c "set application_name='$mutate_app'; set role authenticated; select set_config('request.jwt.claim.sub','$root_auth',false); select public.set_internal_user_active('$reader',false,$reader_version,gen_random_uuid());" >"$scratch/mutate.log" 2>&1 &
mutate_pid=$!
wait_query "select exists(select 1 from pg_stat_activity r join pg_stat_activity m on r.pid=any(pg_blocking_pids(m.pid)) where r.application_name='$read_app' and m.application_name='$mutate_app');"
sql -c "select pg_cancel_backend(pid) from pg_stat_activity where application_name='$audit_gate';" >/dev/null
wait "$gate_pid" || true
read_exit=0; wait "$read_pid" || read_exit=$?
mutate_exit=0; wait "$mutate_pid" || mutate_exit=$?
sql -c "drop trigger drive_audit_gate_$suffix on public.security_audit_log; drop function private.drive_audit_gate_$suffix();"
if [[ "$read_exit" != 0 || "$mutate_exit" != 0 ]]; then
  cat "$scratch/read.log" "$scratch/mutate.log" >&2
  echo 'FAIL synchronized document read/audit versus User lifecycle' >&2
  exit 1
fi
[[ "$(sql -c "select not is_active from public.app_users where app_user_id='$reader'")" == t ]]
[[ "$(sql -c "select count(*)=1 from public.security_audit_log where entity_id='$document' and action_code='DOCUMENT_ACCESS' and actor_app_user_id='$reader'")" == t ]]
echo 'PASS synchronized document read/audit versus User lifecycle: both committed'
