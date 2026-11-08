#!/usr/bin/env bash
# REC-04 Package 009 authenticated, deterministic residual lock-composition tests.
# Privileged fixture/gate setup is separate from public RPCs, which run as the
# non-superuser authenticated role with HR permissions and a real JWT subject.
set -euo pipefail

container_name="${1:-${CONTAINER_NAME:-supabase_db_eiu-recruitment-dev}}"
database_name="${2:-${DATABASE_NAME:-postgres}}"
socket_dir="${3:-${PGHOST:-}}"
port="${4:-${PGPORT:-5432}}"

psql_exec() {
  docker exec -i "$container_name" psql -h "$socket_dir" -p "$port" -v ON_ERROR_STOP=1 -U postgres -d "$database_name" "$@"
}

run_sql_file() {
  local sql="$1" out="$2"
  printf '%s\n' "$sql" | docker exec -i "$container_name" \
    psql -h "$socket_dir" -p "$port" -v ON_ERROR_STOP=1 -U postgres -d "$database_name" >"$out" 2>&1
}

new_uuid() {
  if [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    psql_exec -qAt -c 'select gen_random_uuid();' | tr -d '\r\n'
  fi
}

suffix="$(new_uuid | tr -d '-' | cut -c1-12)"
registered_apps=()
registered_pids=()

wait_for_gate_ready() {
  local app="$1" ready_key="$2" shell_pid="$3" out="$4" i
  for i in $(seq 1 100); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
      cat "$out" >&2 || true
      return 1
    fi
    if psql_exec -qAt -c "select (not pg_try_advisory_lock(hashtextextended('$ready_key',0)))::text;" | tr -d '\r' | grep -qx true; then
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: gate $app did not become ready" >&2
  cat "$out" >&2 || true
  return 1
}

wait_for_blocked_by() {
  local contender_app="$1" holder_pid="$2" shell_pid="$3" out="$4" i
  for i in $(seq 1 100); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
      cat "$out" >&2 || true
      return 1
    fi
    if psql_exec -qAt -c "select coalesce(bool_or('$holder_pid'=any(pg_blocking_pids(pid))),false)::text from pg_stat_activity where application_name='$contender_app' and pid <> pg_backend_pid();" | tr -d '\r' | grep -qx true; then
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: $contender_app did not block on backend $holder_pid" >&2
  psql_exec -c "select pid,application_name,state,wait_event_type,wait_event,pg_blocking_pids(pid),query from pg_stat_activity where application_name='$contender_app' or pid='$holder_pid';" >&2 || true
  cat "$out" >&2 || true
  return 1
}

release_gate() {
  local app="$1" shell_pid="$2"
  psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$app' and pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  wait "$shell_pid" >/dev/null 2>&1 || true
}

cleanup() {
  local exit_code=$?
  for app in "${registered_apps[@]}"; do
    psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$app' and pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  done
  for pid in "${registered_pids[@]}"; do
    kill -9 "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  psql_exec <<SQL >/dev/null
begin;
delete from public.security_audit_log where actor_app_user_id in (select app_user_id from public.app_users where email like '%_${suffix}@eiu.edu.vn');
delete from public.activity_log where actor_app_user_id in (select app_user_id from public.app_users where email like '%_${suffix}@eiu.edu.vn');
delete from public.interview_participants where interview_id in (select i.interview_id from public.interviews i join public.applications a on a.application_id=i.application_id where a.unit_id='$unit_id'::uuid);
delete from public.interviews where application_id in (select application_id from public.applications where unit_id='$unit_id'::uuid);
delete from public.applications where unit_id='$unit_id'::uuid;
delete from public.submissions where candidate_id in (select candidate_id from public.candidates where email like '%_${suffix}@example.invalid');
delete from public.candidates where email like '%_${suffix}@example.invalid';
delete from public.idempotency_records where actor_scope in (select 'app_user:' || app_user_id::text from public.app_users where email like '%_${suffix}@eiu.edu.vn');
delete from public.app_user_permissions where app_user_id in (select app_user_id from public.app_users where email like '%_${suffix}@eiu.edu.vn');
delete from public.app_user_roles where app_user_id in (select app_user_id from public.app_users where email like '%_${suffix}@eiu.edu.vn');
delete from public.app_users where email like '%_${suffix}@eiu.edu.vn';
delete from public.positions where position_id='$position_id'::uuid;
delete from public.position_groups where position_group_id='$group_id'::uuid;
delete from public.organizational_units where unit_id='$unit_id'::uuid;
commit;
SQL
  if [[ "$exit_code" -ne 0 ]]; then
    cat "/tmp/rec04_p009_${suffix}"*.out >&2 || true
  fi
  rm -f "/tmp/rec04_p009_${suffix}"* 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT

unit_id="$(new_uuid)"; group_id="$(new_uuid)"; position_id="$(new_uuid)"
actor_id='10000000-0000-4000-8000-000000000001'
owner_id='20000000-0000-4000-8000-000000000002'
actor_auth_id="$(new_uuid)"; owner_auth_id="$(new_uuid)"
copy_source_candidate="$(new_uuid)"; copy_source_submission="$(new_uuid)"; copy_source_application="$(new_uuid)"; copy_source_interview="$(new_uuid)"
copy_target_candidate="$(new_uuid)"; copy_target_submission="$(new_uuid)"; copy_target_application="$(new_uuid)"; copy_target_interview="$(new_uuid)"
assignment_candidate="$(new_uuid)"; assignment_submission="$(new_uuid)"
note_candidate="$(new_uuid)"; note_submission="$(new_uuid)"; note_application="$(new_uuid)"; note_interview="$(new_uuid)"

echo '=== Setting up Package 009 residual deadlock fixtures ==='
psql_exec <<SQL
begin;
insert into public.organizational_units(unit_id,code,name_vi) values('$unit_id','U_$suffix','Unit $suffix');
insert into public.position_groups(position_group_id,code,name_vi) values('$group_id','G_$suffix','Group $suffix');
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi) values('$position_id','$unit_id','$group_id','P_$suffix','Position $suffix');
insert into public.app_users(app_user_id,auth_user_id,full_name,email,is_active,is_root_admin) values
  ('$actor_id','$actor_auth_id','Actor $suffix','actor_${suffix}@eiu.edu.vn',true,false),
  ('$owner_id','$owner_auth_id','Owner $suffix','owner_${suffix}@eiu.edu.vn',true,false);
insert into public.app_user_roles(app_user_id,role_code) values('$actor_id','HR'),('$owner_id','HR');
insert into public.app_user_permissions(app_user_id,permission_code,granted_by)
select '$actor_id',permission_code,'$actor_id' from public.permissions;
insert into public.candidates(candidate_id,auth_user_id,email,is_active) values
  ('$copy_source_candidate',gen_random_uuid(),'copy_source_${suffix}@example.invalid',true),
  ('$copy_target_candidate',gen_random_uuid(),'copy_target_${suffix}@example.invalid',true),
  ('$assignment_candidate',gen_random_uuid(),'assignment_${suffix}@example.invalid',true),
  ('$note_candidate',gen_random_uuid(),'note_${suffix}@example.invalid',true);
insert into public.submissions(submission_id,candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,status_code) values
  ('$copy_source_submission','$copy_source_candidate','Copy source','1990-01-01','MALE','Address','0900000001','copy_source_${suffix}@example.invalid','PROCESSED'),
  ('$copy_target_submission','$copy_target_candidate','Copy target','1990-01-01','MALE','Address','0900000002','copy_target_${suffix}@example.invalid','PROCESSED'),
  ('$assignment_submission','$assignment_candidate','Assignment','1990-01-01','MALE','Address','0900000003','assignment_${suffix}@example.invalid','PROCESSED'),
  ('$note_submission','$note_candidate','Note','1990-01-01','MALE','Address','0900000004','note_${suffix}@example.invalid','PROCESSED');
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active,version_no) values
  ('$copy_source_application','$copy_source_submission','$unit_id','$position_id','$owner_id',true,1),
  ('$copy_target_application','$copy_target_submission','$unit_id','$position_id','$owner_id',true,1),
  ('$note_application','$note_submission','$unit_id','$position_id','$owner_id',true,1);
insert into public.interviews(interview_id,application_id,round_no,schedule_status_code,report_status_code,is_active,version_no) values
  ('$copy_source_interview','$copy_source_application',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1),
  ('$copy_target_interview','$copy_target_application',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1),
  ('$note_interview','$note_application',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1);
commit;
SQL

# ---------------------------------------------------------------------------
# Scenario A: explicit prelocked actor regression for assignment. The prefix
# follows Copy's parent-before-User order, then stages its actor lock before
# the assignment begins. Package 009 must wait at its own actor row lock.
echo '--- Scenario A: assignment actor/owner set vs Copy ---'
copy_app="p009_copy_${suffix}"; assignment_app="p009_assignment_${suffix}"; copy_gate_app="p009_copy_gate_${suffix}"
registered_apps+=("$copy_app" "$assignment_app" "$copy_gate_app")
copy_gate="p009_copy_gate:$suffix"
copy_ready="p009_copy_ready:$suffix"
copy_gate_sql="set application_name='$copy_gate_app'; select pg_advisory_lock(hashtextextended('$copy_gate',0)); select pg_sleep(3600);"
run_sql_file "$copy_gate_sql" "/tmp/rec04_p009_${suffix}_copy_gate.out" & copy_gate_pid=$!
registered_pids+=("$copy_gate_pid")
wait_for_gate_ready "$copy_gate_app" "$copy_gate" "$copy_gate_pid" "/tmp/rec04_p009_${suffix}_copy_gate.out"

copy_sql="set application_name='$copy_app'; set statement_timeout='15s'; set deadlock_timeout='500ms'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id in ('$copy_source_submission'::uuid,'$copy_target_submission'::uuid) order by submission_id for update; select 1 from public.applications where application_id in ('$copy_source_application'::uuid,'$copy_target_application'::uuid) order by application_id for update; select 1 from public.interviews where interview_id in ('$copy_source_interview'::uuid,'$copy_target_interview'::uuid) order by interview_id for update; select 1 from public.app_users where app_user_id='$actor_id'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$copy_ready',0)); select pg_advisory_lock(hashtextextended('$copy_gate',0)); select pg_advisory_unlock(hashtextextended('$copy_gate',0)); set local role authenticated; select public.copy_interview_schedule('$copy_source_interview','$copy_target_application',1,1,'$copy_target_interview',1,null,null,null,null,null,'P009 copy',array['$owner_id'::uuid],'$(new_uuid)'); commit;"
assignment_sql="set application_name='$assignment_app'; set statement_timeout='15s'; set deadlock_timeout='500ms'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); set local role authenticated; select public.bulk_create_or_update_applications(array['$assignment_submission'::uuid],'$unit_id',null,'$position_id','$owner_id','$(new_uuid)'); commit;"
run_sql_file "$copy_sql" "/tmp/rec04_p009_${suffix}_copy.out" & copy_pid=$!; registered_pids+=("$copy_pid")
for i in $(seq 1 100); do
  if psql_exec -qAt -c "select exists(select 1 from pg_stat_activity where application_name='$copy_app' and wait_event_type='Lock')::text;" | tr -d '\r' | grep -qx true; then break; fi
  sleep 0.05
done
copy_backend_pid="$(psql_exec -qAt -c "select pid from pg_stat_activity where application_name='$copy_app' order by pid limit 1;" | tr -d '\r')"
[[ -n "$copy_backend_pid" ]]
run_sql_file "$assignment_sql" "/tmp/rec04_p009_${suffix}_assignment.out" & assignment_pid=$!; registered_pids+=("$assignment_pid")
wait_for_blocked_by "$assignment_app" "$copy_backend_pid" "$assignment_pid" "/tmp/rec04_p009_${suffix}_assignment.out"
release_gate "$copy_gate_app" "$copy_gate_pid"
wait "$copy_pid"; wait "$assignment_pid"
if grep -qi 'deadlock detected' "/tmp/rec04_p009_${suffix}_copy.out" "/tmp/rec04_p009_${suffix}_assignment.out"; then
  echo 'FAIL: Scenario A deadlocked' >&2; exit 1
fi
grep -q '"success": true' "/tmp/rec04_p009_${suffix}_copy.out"
grep -q '"success": true' "/tmp/rec04_p009_${suffix}_assignment.out"
psql_exec -qAt -c "select count(*) from public.applications where submission_id='$assignment_submission'::uuid and hr_owner_id='$owner_id'::uuid;" | grep -qx 1
echo 'PASS: Scenario A observed assignment waiting on its explicit actor lock; the authenticated Copy RPC then completed successfully.'

# ---------------------------------------------------------------------------
# Scenario B: an external Submission holder makes the actual HR-note command
# take Candidate first and wait on Submission. Assignment must then wait on the
# note backend's Candidate lock. The old S -> C note order instead lets
# assignment acquire Candidate and block on the external Submission holder.
# ---------------------------------------------------------------------------
echo '--- Scenario B: HR note Candidate->Submission vs assignment ---'
note_gate_app="p009_note_gate_${suffix}"; note_app="p009_note_${suffix}"; note_assignment_app="p009_note_assignment_${suffix}"
registered_apps+=("$note_gate_app" "$note_app" "$note_assignment_app")
note_ready="p009_note_ready:$suffix"
note_gate_sql="set application_name='$note_gate_app'; begin; select 1 from public.submissions where submission_id='$note_submission'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$note_ready',0)); select pg_sleep(3600);"
run_sql_file "$note_gate_sql" "/tmp/rec04_p009_${suffix}_note_gate.out" & note_gate_pid=$!; registered_pids+=("$note_gate_pid")
wait_for_gate_ready "$note_gate_app" "$note_ready" "$note_gate_pid" "/tmp/rec04_p009_${suffix}_note_gate.out"
note_gate_backend_pid="$(psql_exec -qAt -c "select pid from pg_stat_activity where application_name='$note_gate_app' order by pid limit 1;" | tr -d '\r')"
[[ -n "$note_gate_backend_pid" ]]
note_sql="set application_name='$note_app'; set statement_timeout='15s'; set deadlock_timeout='500ms'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); set local role authenticated; select public.update_submission_by_hr('$note_submission','Package 009 note',1); commit;"
note_assignment_sql="set application_name='$note_assignment_app'; set statement_timeout='15s'; set deadlock_timeout='500ms'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); set local role authenticated; select public.bulk_create_or_update_applications(array['$note_submission'::uuid],'$unit_id',null,'$position_id','$owner_id','$(new_uuid)'); commit;"
run_sql_file "$note_sql" "/tmp/rec04_p009_${suffix}_note.out" & note_pid=$!; registered_pids+=("$note_pid")
wait_for_blocked_by "$note_app" "$note_gate_backend_pid" "$note_pid" "/tmp/rec04_p009_${suffix}_note.out"
note_backend_pid="$(psql_exec -qAt -c "select pid from pg_stat_activity where application_name='$note_app' order by pid limit 1;" | tr -d '\r')"
[[ -n "$note_backend_pid" ]]
run_sql_file "$note_assignment_sql" "/tmp/rec04_p009_${suffix}_note_assignment.out" & note_assignment_pid=$!; registered_pids+=("$note_assignment_pid")
wait_for_blocked_by "$note_assignment_app" "$note_backend_pid" "$note_assignment_pid" "/tmp/rec04_p009_${suffix}_note_assignment.out"
release_gate "$note_gate_app" "$note_gate_pid"
wait "$note_pid"; wait "$note_assignment_pid"
if grep -qi 'deadlock detected' "/tmp/rec04_p009_${suffix}_note.out" "/tmp/rec04_p009_${suffix}_note_assignment.out"; then
  echo 'FAIL: Scenario B deadlocked' >&2; exit 1
fi
grep -q '"success": true' "/tmp/rec04_p009_${suffix}_note.out"
grep -q '"success": true' "/tmp/rec04_p009_${suffix}_note_assignment.out"
psql_exec -qAt -c "select (hr_note='Package 009 note' and version_no=2)::text from public.submissions where submission_id='$note_submission'::uuid;" | grep -qx true
psql_exec -qAt -c "select count(*) from public.applications where application_id='$note_application'::uuid and hr_owner_id='$owner_id'::uuid and version_no=2;" | grep -qx 1
echo 'PASS: Scenario B observed assignment waiting on HR-note Candidate lock; version and durable state are valid.'

echo 'PASS: all Package 009 residual authenticated deadlock regressions completed'
