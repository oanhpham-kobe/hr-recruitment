#!/usr/bin/env bash
# =============================================================================
# REC-04 Forward Two-Session Opposing Concurrency Test
#
# Verifies that opposing lifecycle transactions serialize cleanly along the
# canonical parent/resource lock hierarchy without deadlocks:
#   1. create_next_interview_round vs delete_or_inactivate_application
#   2. reactivate_interview vs delete_or_inactivate_application
#   3. copy_interview_schedule vs delete_or_inactivate_application
#   4. save_interview_schedule vs delete_or_inactivate_interview
#   5. concurrent schedule writers contending on shared participant resource
#   6. bulk_change_report_status vs single change_report_status (cycle-free Submission-first)
#
# Source lock ordering hierarchy enforced:
#   Submission -> Application -> Interview -> participant/report -> schedule resource -> app user
# =============================================================================
set -euo pipefail

container_name="${1:-${CONTAINER_NAME:-supabase_db_eiu-recruitment-dev}}"
database_name="${2:-${DATABASE_NAME:-postgres}}"
socket_dir="${3:-${PGHOST:-}}"
port="${4:-${PGPORT:-5432}}"

psql_exec() {
  docker exec -i "$container_name" psql -h "$socket_dir" -p "$port" -v ON_ERROR_STOP=1 -U postgres -d "$database_name" "$@"
}

new_uuid() {
  if [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\r\n'
  else
    psql_exec -qAt -c "select gen_random_uuid();" | tr -d '\r\n'
  fi
}

suffix="$(new_uuid | tr -d '-' | cut -c1-12)"

unit_id="$(new_uuid)"
group_id="$(new_uuid)"
pos_id="$(new_uuid)"
format_id="$(new_uuid)"

actor_id="$(new_uuid)"
actor_auth_id="$(new_uuid)"
interviewer_id="$(new_uuid)"
interviewer_auth_id="$(new_uuid)"

# Fixture IDs for Scenario 1
cand_1="$(new_uuid)"
sub_1="$(new_uuid)"
app_1="$(new_uuid)"
int_1_1="$(new_uuid)"

# Fixture IDs for Scenario 2
cand_2="$(new_uuid)"
sub_2="$(new_uuid)"
app_2="$(new_uuid)"
int_2_1="$(new_uuid)"
int_2_2="$(new_uuid)"

# Fixture IDs for Scenario 3
cand_3_src="$(new_uuid)"
sub_3_src="$(new_uuid)"
app_3_src="$(new_uuid)"
int_3_src="$(new_uuid)"
cand_3_tgt="$(new_uuid)"
sub_3_tgt="$(new_uuid)"
app_3_tgt="$(new_uuid)"
int_3_tgt="$(new_uuid)"

# Fixture IDs for Scenario 4
cand_4="$(new_uuid)"
sub_4="$(new_uuid)"
app_4="$(new_uuid)"
int_4_1="$(new_uuid)"

# Fixture IDs for Scenario 5
cand_5_a="$(new_uuid)"
sub_5_a="$(new_uuid)"
app_5_a="$(new_uuid)"
int_5_a="$(new_uuid)"
cand_5_b="$(new_uuid)"
sub_5_b="$(new_uuid)"
app_5_b="$(new_uuid)"
int_5_b="$(new_uuid)"

# Fixture IDs for Scenario 6 (Opposing single vs bulk report status writers)
cand_6_a="$(new_uuid)"
sub_6_a="$(new_uuid)"
app_6_a="$(new_uuid)"
int_6_a="$(new_uuid)"
cand_6_b="$(new_uuid)"
sub_6_b="$(new_uuid)"
app_6_b="$(new_uuid)"
int_6_b="$(new_uuid)"

# Fixture IDs for Scenario 7 (Post-lock target disappearance)
cand_7="$(new_uuid)"
sub_7="$(new_uuid)"
app_7="$(new_uuid)"
int_7_valid="$(new_uuid)"
int_7_target="$(new_uuid)"
run_sql_file() {
  local sql="$1"
  local out="$2"
  printf '%s\n' "$sql" | docker exec -i "$container_name" \
    psql -h "$socket_dir" -p "$port" -v ON_ERROR_STOP=1 -U postgres -d "$database_name" >"$out" 2>&1
}

registered_apps=()
registered_pids=()

setup_gate() {
  local gate_app="$1" gate_key="$2" out="$3"
  registered_apps+=("$gate_app")
  local sql="set application_name='$gate_app'; select pg_advisory_lock(hashtextextended('$gate_key',0)); select pg_sleep(3600);"
  run_sql_file "$sql" "$out" &
  GATE_PID=$!
  registered_pids+=("$GATE_PID")
  wait_for_gate_ready "$gate_app" "$gate_key" "$GATE_PID" "$out"
}

wait_for_gate_ready() {
  local gate_app="$1" gate_key="$2" shell_pid="$3" out="$4" i
  for i in $(seq 1 100); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
      echo "FAIL: Gate runner exited prematurely: $gate_app" >&2
      cat "$out" >&2 || true
      return 1
    fi
    local held
    held="$(psql_exec -qAt -c "select (not pg_try_advisory_lock(hashtextextended('$gate_key',0)))::text;" | tr -d '\r')"
    if [[ "$held" = "true" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: Timed out waiting for gate lock readiness: $gate_app" >&2
  cat "$out" >&2 || true
  return 1
}

wait_for_holder_at_gate() {
  local holder_app="$1" ready_key="$2" shell_pid="$3" out="$4" i
  for i in $(seq 1 100); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
      echo "FAIL: Holder exited before reaching gate: $holder_app" >&2
      cat "$out" >&2 || true
      return 1
    fi
    local status ready_held waiting holder_pid
    status="$(psql_exec -qAt -c "with probe as (select (not pg_try_advisory_lock(hashtextextended('$ready_key',0)))::text as ready_held), activity as (select (coalesce(bool_or(wait_event_type='Lock'),false))::text as waiting, coalesce(min(pid)::text,'') as holder_pid from pg_stat_activity where application_name='$holder_app' and pid <> pg_backend_pid()) select probe.ready_held || '|' || activity.waiting || '|' || activity.holder_pid from probe cross join activity;" | tr -d '\r')"
    IFS='|' read -r ready_held waiting holder_pid <<< "$status"
    if [[ "$ready_held" = "true" && "$waiting" = "true" && -n "$holder_pid" ]]; then
      HOLDER_BACKEND_PID="$holder_pid"
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: Timed out waiting for holder $holder_app at gate" >&2
  psql_exec -c "select pid,application_name,state,wait_event_type,wait_event,query from pg_stat_activity where application_name='$holder_app';" >&2 || true
  cat "$out" >&2 || true
  return 1
}

wait_for_blocked_by() {
  local contender_app="$1" holder_pid="$2" shell_pid="$3" out="$4" i
  for i in $(seq 1 100); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
      echo "FAIL: Contender exited prematurely before blocking: $contender_app" >&2
      cat "$out" >&2 || true
      return 1
    fi
    local is_blocked
    is_blocked="$(psql_exec -qAt -c "select coalesce(bool_or('$holder_pid' = any(pg_blocking_pids(pid))),false)::text from pg_stat_activity where application_name='$contender_app' and pid <> pg_backend_pid();" | tr -d '\r')"
    if [[ "$is_blocked" = "true" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: Timed out waiting for contender $contender_app to be blocked by holder backend $holder_pid" >&2
  psql_exec -c "select pid,application_name,state,wait_event_type,wait_event,pg_blocking_pids(pid),query from pg_stat_activity where application_name='$contender_app' or pid='$holder_pid';" >&2 || true
  cat "$out" >&2 || true
  return 1
}

release_gate() {
  local gate_app="$1" shell_pid="$2"
  psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$gate_app' and pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  wait "$shell_pid" >/dev/null 2>&1 || true
}

cleanup() {
  local exit_code=$?
  for app in "${registered_apps[@]}"; do psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$app' and pid <> pg_backend_pid();" >/dev/null 2>&1 || true; done
  for pid in "${registered_pids[@]}"; do kill -9 "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; done
  rm -f /tmp/rec04_*_${suffix}.* /tmp/*_${suffix}.* 2>/dev/null || true
  psql_exec <<SQL
begin;
delete from public.interview_participants where interview_id in (select i.interview_id from public.interviews i join public.applications a on a.application_id=i.application_id where a.unit_id='$unit_id'::uuid);
delete from public.storage_cleanup_queue where source_parent_id in (select i.interview_id from public.interviews i join public.applications a on a.application_id=i.application_id where a.unit_id='$unit_id'::uuid);
delete from public.interviews where application_id in (select application_id from public.applications where unit_id='$unit_id'::uuid);
delete from public.applications where unit_id='$unit_id'::uuid;
delete from public.submissions where candidate_id in (select candidate_id from public.candidates where email like '%_' || '$suffix' || '%');
delete from public.candidates where email like '%_' || '$suffix' || '%';
delete from public.idempotency_records where actor_scope in (select 'app_user:' || app_user_id::text from public.app_users where email like '%_' || '$suffix' || '%');
delete from public.app_user_permissions where app_user_id in (select app_user_id from public.app_users where email like '%_' || '$suffix' || '%');
delete from public.app_user_roles where app_user_id in (select app_user_id from public.app_users where email like '%_' || '$suffix' || '%');
delete from public.app_users where email like '%_' || '$suffix' || '%';
delete from public.interview_formats where code='F_$suffix';
delete from public.positions where code='P_$suffix';
delete from public.position_groups where code='G_$suffix';
delete from public.organizational_units where code='U_$suffix';
commit;
SQL
  exit "$exit_code"
}

trap cleanup EXIT

echo "=== Setting up fixtures for REC-04 Concurrency Verification ==="
psql_exec <<SQL
begin;
insert into public.organizational_units(unit_id, code, name_vi)
values ('$unit_id'::uuid, 'U_${suffix}', 'Unit ${suffix}');

insert into public.position_groups(position_group_id, code, name_vi)
values ('$group_id'::uuid, 'G_${suffix}', 'Group ${suffix}');

insert into public.positions(position_id, unit_id, position_group_id, code, name_vi)
values ('$pos_id'::uuid, '$unit_id'::uuid, '$group_id'::uuid, 'P_${suffix}', 'Pos ${suffix}');

insert into public.interview_formats(interview_format_id, code, name_vi, requires_room)
values ('$format_id'::uuid, 'F_${suffix}', 'Format ${suffix}', false);

insert into public.app_users(app_user_id, auth_user_id, full_name, email, is_active, is_root_admin)
values
  ('$actor_id'::uuid, '$actor_auth_id'::uuid, 'Actor ${suffix}', 'actor_${suffix}@eiu.edu.vn', true, false),
  ('$interviewer_id'::uuid, '$interviewer_auth_id'::uuid, 'Interviewer ${suffix}', 'interviewer_${suffix}@eiu.edu.vn', true, false);

insert into public.app_user_roles(app_user_id, role_code) values
  ('$actor_id'::uuid, 'HR');

insert into public.app_user_permissions(app_user_id, permission_code, granted_by)
select '$actor_id'::uuid, p.permission_code, '$actor_id'::uuid
from public.permissions p;

-- Scenario 1 fixtures: app_1 has round 1 with interview_note (non-empty -> inactivates)
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_1'::uuid, gen_random_uuid(), 'cand_1_${suffix}@example.invalid', true);
insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
values ('$sub_1'::uuid, '$cand_1'::uuid, 'Candidate 1', '1990-01-01', 'MALE', 'Addr 1', '0900000001', 'cand_1_${suffix}@example.invalid', 'PROCESSED');
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values ('$app_1'::uuid, '$sub_1'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no, interview_note)
values ('$int_1_1'::uuid, '$app_1'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1, 'Round 1 established');

-- Scenario 2 fixtures: app_2 has round 1 (active) and round 2 (inactive) -> inactivates
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_2'::uuid, gen_random_uuid(), 'cand_2_${suffix}@example.invalid', true);
insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
values ('$sub_2'::uuid, '$cand_2'::uuid, 'Candidate 2', '1991-01-01', 'FEMALE', 'Addr 2', '0900000002', 'cand_2_${suffix}@example.invalid', 'PROCESSED');
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values ('$app_2'::uuid, '$sub_2'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
values ('$int_2_1'::uuid, '$app_2'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
values ('$int_2_2'::uuid, '$app_2'::uuid, 2, 'AVAILABLE', 'INTERVIEW_SCHEDULING', false, 1);

-- Scenario 3 fixtures: app_3_src (source) and app_3_tgt (target)
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values
  ('$cand_3_src'::uuid, gen_random_uuid(), 'cand_3_src_${suffix}@example.invalid', true),
  ('$cand_3_tgt'::uuid, gen_random_uuid(), 'cand_3_tgt_${suffix}@example.invalid', true);
insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
values
  ('$sub_3_src'::uuid, '$cand_3_src'::uuid, 'Candidate 3 Src', '1992-01-01', 'MALE', 'Addr 3S', '0900000003', 'cand_3_src_${suffix}@example.invalid', 'PROCESSED'),
  ('$sub_3_tgt'::uuid, '$cand_3_tgt'::uuid, 'Candidate 3 Tgt', '1992-02-02', 'FEMALE', 'Addr 3T', '0900000004', 'cand_3_tgt_${suffix}@example.invalid', 'PROCESSED');
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values
  ('$app_3_src'::uuid, '$sub_3_src'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true),
  ('$app_3_tgt'::uuid, '$sub_3_tgt'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no, interview_note)
values
  ('$int_3_src'::uuid, '$app_3_src'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1, 'Source Round 1 note'),
  ('$int_3_tgt'::uuid, '$app_3_tgt'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1, 'Target Round 1 note');

-- Scenario 4 fixtures: app_4 with int_4_1 having an interview participant
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_4'::uuid, gen_random_uuid(), 'cand_4_${suffix}@example.invalid', true);
insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
values ('$sub_4'::uuid, '$cand_4'::uuid, 'Candidate 4', '1993-01-01', 'MALE', 'Addr 4', '0900000005', 'cand_4_${suffix}@example.invalid', 'PROCESSED');
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values ('$app_4'::uuid, '$sub_4'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no, interview_note)
values ('$int_4_1'::uuid, '$app_4'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1, 'Active Interview 4');
insert into public.interview_participants(interview_id, app_user_id, participant_order, snapshot_name, snapshot_job_title, snapshot_email, is_current)
values ('$int_4_1'::uuid, '$interviewer_id'::uuid, 1, 'Interviewer ${suffix}', 'Interviewer', 'interviewer_${suffix}@eiu.edu.vn', true);

-- Scenario 5 fixtures: app_5_a and app_5_b both sharing interviewer_id
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values
  ('$cand_5_a'::uuid, gen_random_uuid(), 'cand_5_a_${suffix}@example.invalid', true),
  ('$cand_5_b'::uuid, gen_random_uuid(), 'cand_5_b_${suffix}@example.invalid', true);
insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
values
  ('$sub_5_a'::uuid, '$cand_5_a'::uuid, 'Candidate 5A', '1994-01-01', 'MALE', 'Addr 5A', '0900000006', 'cand_5_a_${suffix}@example.invalid', 'PROCESSED'),
  ('$sub_5_b'::uuid, '$cand_5_b'::uuid, 'Candidate 5B', '1994-02-02', 'FEMALE', 'Addr 5B', '0900000007', 'cand_5_b_${suffix}@example.invalid', 'PROCESSED');
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values
  ('$app_5_a'::uuid, '$sub_5_a'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true),
  ('$app_5_b'::uuid, '$sub_5_b'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
values
  ('$int_5_a'::uuid, '$app_5_a'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1),
  ('$int_5_b'::uuid, '$app_5_b'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1);
insert into public.interview_participants(interview_id, app_user_id, participant_order, snapshot_name, snapshot_job_title, snapshot_email, is_current)
values
  ('$int_5_a'::uuid, '$interviewer_id'::uuid, 1, 'Interviewer ${suffix}', 'Interviewer', 'interviewer_${suffix}@eiu.edu.vn', true),
  ('$int_5_b'::uuid, '$interviewer_id'::uuid, 1, 'Interviewer ${suffix}', 'Interviewer', 'interviewer_${suffix}@eiu.edu.vn', true);

-- Scenario 6 fixtures: app_6_a and app_6_b for opposing single vs bulk report writers
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values
  ('$cand_6_a'::uuid, gen_random_uuid(), 'cand_6_a_${suffix}@example.invalid', true),
  ('$cand_6_b'::uuid, gen_random_uuid(), 'cand_6_b_${suffix}@example.invalid', true);
insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
values
  ('$sub_6_a'::uuid, '$cand_6_a'::uuid, 'Candidate 6A', '1995-01-01', 'MALE', 'Addr 6A', '0900000008', 'cand_6_a_${suffix}@example.invalid', 'PROCESSED'),
  ('$sub_6_b'::uuid, '$cand_6_b'::uuid, 'Candidate 6B', '1995-02-02', 'FEMALE', 'Addr 6B', '0900000009', 'cand_6_b_${suffix}@example.invalid', 'PROCESSED');
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values
  ('$app_6_a'::uuid, '$sub_6_a'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true),
  ('$app_6_b'::uuid, '$sub_6_b'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
values
  ('$int_6_a'::uuid, '$app_6_a'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1),
  ('$int_6_b'::uuid, '$app_6_b'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1);

-- Scenario 7 fixtures: app_7 with int_7_valid and int_7_target for post-lock disappearance
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_7'::uuid, gen_random_uuid(), 'cand_7_${suffix}@example.invalid', true);
insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
values ('$sub_7'::uuid, '$cand_7'::uuid, 'Candidate 7', '1996-01-01', 'MALE', 'Addr 7', '0900000010', 'cand_7_${suffix}@example.invalid', 'PROCESSED');
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values ('$app_7'::uuid, '$sub_7'::uuid, '$unit_id'::uuid, '$pos_id'::uuid, '$actor_id'::uuid, true);
insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
values
  ('$int_7_valid'::uuid, '$app_7'::uuid, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1),
  ('$int_7_target'::uuid, '$app_7'::uuid, 2, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1);
commit;
SQL

# ---------------------------------------------------------------------------
echo "P1-03 forward regression: participant selection and copy share sorted user composition"
actor_v="$actor_id"; actor_v_auth="$actor_auth_id"; selected_u="ffffffff-ffff-4fff-bfff-ffffffffffff"; selected_u_auth="ffffffff-ffff-4fff-bfff-fffffffffffe"
psql_exec -v ON_ERROR_STOP=1 -c "insert into public.app_users(app_user_id,auth_user_id,full_name,email,is_active,is_root_admin) values ('$selected_u'::uuid,'$selected_u_auth'::uuid,'P1-03 Selected','p103selected_${suffix}@eiu.edu.vn',true,false);"
ra="p1_03_add_${suffix}"; rb="p1_03_copy_${suffix}"; rg="p1_03_add_gate_${suffix}"; rg2="p1_03_copy_gate_${suffix}"; registered_apps+=("$ra" "$rb" "$rg" "$rg2"); ga="p1_03_add_gate:${suffix}"; gb="p1_03_copy_gate:${suffix}"; ready="p1_03_add_ready:${suffix}"; readyb="p1_03_copy_ready:${suffix}"; oa="/tmp/$ra.out"; ob="/tmp/$rb.out"; setup_gate "$rg" "$ga" "/tmp/$rg.out"; ga_pid=$GATE_PID; setup_gate "$rg2" "$gb" "/tmp/$rg2.out"; gb_pid=$GATE_PID
sqla="set application_name='$ra'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_v_auth')::text,true); select 1 from public.interviews where interview_id='$int_4_1'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready',0)); select pg_advisory_lock(hashtextextended('$ga',0)); select pg_advisory_unlock(hashtextextended('$ga',0)); set local role authenticated; select public.add_interview_participant('$int_4_1','$selected_u','$(new_uuid)'); commit;"
sqlb="set application_name='$rb'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_v_auth')::text,true); select 1 from public.app_users where app_user_id='$actor_v'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$readyb',0)); select pg_advisory_lock(hashtextextended('$gb',0)); select pg_advisory_unlock(hashtextextended('$gb',0)); set local role authenticated; select public.copy_interview_schedule('$int_3_src','$app_3_tgt',1,1,'$int_3_tgt',1,null,null,null,null,null,'p1-03',array['$selected_u'::uuid],'$(new_uuid)'); commit;"
run_sql_file "$sqla" "$oa" & pa=$!; registered_pids+=("$pa"); wait_for_holder_at_gate "$ra" "$ready" "$pa" "$oa"; run_sql_file "$sqlb" "$ob" & pb=$!; registered_pids+=("$pb"); wait_for_holder_at_gate "$rb" "$readyb" "$pb" "$ob"; release_gate "$rg" "$ga_pid"; release_gate "$rg2" "$gb_pid"; wait "$pa"; wait "$pb"; cat "$oa" "$ob"
if grep -qi "deadlock detected" "$oa" "$ob"; then echo "FAIL: P1-03 deadlocked"; exit 1; fi; grep -q "\"success\": true" "$oa"; grep -Eq "\"success\": true|\"error_code\": \"STALE_VERSION\"" "$ob"; psql_exec -qAt -c "select count(*) from public.interview_participants where interview_id='$int_4_1'::uuid and app_user_id='$selected_u'::uuid" | grep -qx 1; echo "PASS: P1-03 completed without deadlock"


echo 'P1-01 current reproduction: assignment versus copy'
ra="p1_01_copy_$suffix"; rb="p1_01_assign_$suffix"; rg="p1_01_gate_$suffix"; registered_apps+=("$ra" "$rb" "$rg")
ga="p1_01_gate:$suffix"; ready="p1_01_ready:$suffix"; oa="/tmp/$ra.out"; ob="/tmp/$rb.out"; og="/tmp/$rg.out"
setup_gate "$rg" "$ga" "$og"
p1_01_source_version="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$int_3_src'::uuid;" | tr -d '\r')"
p1_01_target_app_version="$(psql_exec -qAt -c "select version_no from public.applications where application_id='$app_3_tgt'::uuid;" | tr -d '\r')"
p1_01_target_interview="$(psql_exec -qAt -c "select interview_id from public.interviews where application_id='$app_3_tgt'::uuid and is_active order by round_no desc, interview_id desc limit 1;" | tr -d '\r')"
p1_01_target_interview_version="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$p1_01_target_interview'::uuid;" | tr -d '\r')"
sqla="set application_name='$ra'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id in ('$sub_3_src','$sub_3_tgt') order by submission_id for update; select pg_advisory_xact_lock(hashtextextended('$ready',0)); select pg_advisory_lock(hashtextextended('$ga',0)); select pg_advisory_unlock(hashtextextended('$ga',0)); set local role authenticated; select public.copy_interview_schedule('$int_3_src', '$app_3_tgt', $p1_01_source_version, $p1_01_target_app_version, '$p1_01_target_interview', $p1_01_target_interview_version, null, null, null, null, null, 'current reproduction', array[]::uuid[], '$(new_uuid)'); commit;"
sqlb="set application_name='$rb'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); set local role authenticated; select public.bulk_create_or_update_applications(array['$sub_3_tgt'::uuid], '$unit_id', null, '$pos_id', '$actor_id', '$(new_uuid)'); commit;"
run_sql_file "$sqla" "$oa" & pa=$!; registered_pids+=("$pa"); wait_for_holder_at_gate "$ra" "$ready" "$pa" "$oa"; hp="$HOLDER_BACKEND_PID"; run_sql_file "$sqlb" "$ob" & pb=$!; registered_pids+=("$pb"); wait_for_blocked_by "$rb" "$hp" "$pb" "$ob"; release_gate "$rg" "$GATE_PID"; wait "$pa"; wait "$pb"; cat "$oa" "$ob"; if grep -qi 'deadlock detected' "$oa" "$ob"; then echo 'FAIL: P1-01 deadlocked'; exit 1; fi; grep -q '"success": true' "$oa"; grep -q '"success": true' "$ob"; psql_exec -qAt -c "select count(*) from public.interviews where application_id='$app_3_tgt'::uuid and is_active;" | grep -qx 3; echo 'PASS: P1-01 completed without deadlock'


echo 'P1-02 current reproduction: application reactivation versus participant addition'
psql_exec -v ON_ERROR_STOP=1 -c "update public.applications set is_active=false where application_id='$app_2'::uuid;"
ra="p1_02_reactivate_$suffix"; rb="p1_02_add_$suffix"; rg="p1_02_gate_$suffix"; registered_apps+=("$ra" "$rb" "$rg")
ga="p1_02_gate:$suffix"; ready="p1_02_ready:$suffix"; oa="/tmp/$ra.out"; ob="/tmp/$rb.out"; og="/tmp/$rg.out"; setup_gate "$rg" "$ga" "$og"
sqla="set application_name='$ra'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id='$sub_2'::uuid for update; select 1 from public.applications where application_id='$app_2'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready',0)); select pg_advisory_lock(hashtextextended('$ga',0)); select pg_advisory_unlock(hashtextextended('$ga',0)); set local role authenticated; select public.reactivate_application('$app_2',1); commit;"
sqlb="set application_name='$rb'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); set local role authenticated; select public.add_interview_participant('$int_2_1','$actor_id','$(new_uuid)'); commit;"
run_sql_file "$sqla" "$oa" & pa=$!; registered_pids+=("$pa"); wait_for_holder_at_gate "$ra" "$ready" "$pa" "$oa"; run_sql_file "$sqlb" "$ob" & pb=$!; registered_pids+=("$pb"); wait "$pb"; release_gate "$rg" "$GATE_PID"; wait "$pa"; cat "$oa" "$ob"; if grep -qi 'deadlock detected' "$oa" "$ob"; then echo 'FAIL: P1-02 deadlocked'; exit 1; fi; grep -q '"success": true' "$oa"; grep -q '"success": true' "$ob"; echo 'PASS: P1-02 completed without deadlock'


echo 'P1-04 current reproduction: reversed candidate batch versus copy'
c1='10000000-0000-4000-8000-000000000001'; c2='20000000-0000-4000-8000-000000000002'; s1='00000000-0000-4000-8000-000000000011'; s2='ffffffff-ffff-4fff-bfff-fffffffffff2'; a1='30000000-0000-4000-8000-000000000003'; a2='40000000-0000-4000-8000-000000000004'; i1='50000000-0000-4000-8000-000000000005'; i2='60000000-0000-4000-8000-000000000006'
psql_exec -v ON_ERROR_STOP=1 -c "insert into public.candidates(candidate_id,auth_user_id,email,is_active,inactive_at,inactive_by,version_no) values('$c1',gen_random_uuid(),'p104c1_${suffix}@x.invalid',false,clock_timestamp(),'$actor_id',1),('$c2',gen_random_uuid(),'p104c2_${suffix}@x.invalid',false,clock_timestamp(),'$actor_id',1); insert into public.submissions(submission_id,candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,status_code) values('$s1','$c1','P104 1','1990-01-01','MALE','A','1','p104c1_${suffix}@x.invalid','PROCESSED'),('$s2','$c2','P104 2','1990-01-01','MALE','B','2','p104c2_${suffix}@x.invalid','PROCESSED'); insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active) values('$a1','$s1','$unit_id','$pos_id','$actor_id',true),('$a2','$s2','$unit_id','$pos_id','$actor_id',true); insert into public.interviews(interview_id,application_id,round_no,schedule_status_code,report_status_code,is_active,version_no,interview_note) values('$i1','$a1',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1,'P104 source'),('$i2','$a2',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1,'P104 target');"
ra="p1_04_batch_${suffix}"; rb="p1_04_copy_${suffix}"; rg="p1_04_bulk_gate_${suffix}"; rg2="p1_04_copy_gate_${suffix}"; registered_apps+=("$ra" "$rb" "$rg" "$rg2"); ga="p1_04_bulk_gate:${suffix}"; gb="p1_04_copy_gate:${suffix}"; ready="p1_04_bulk_ready:${suffix}"; readyb="p1_04_copy_ready:${suffix}"; oa="/tmp/$ra.out"; ob="/tmp/$rb.out"; setup_gate "$rg" "$ga" "/tmp/$rg.out"; ga_pid=$GATE_PID; setup_gate "$rg2" "$gb" "/tmp/$rg2.out"; gb_pid=$GATE_PID
sqla="set application_name='$ra'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.candidates where candidate_id in ('$c1','$c2') order by candidate_id for update; select pg_advisory_xact_lock(hashtextextended('$ready',0)); select pg_advisory_lock(hashtextextended('$ga',0)); select pg_advisory_unlock(hashtextextended('$ga',0)); set local role authenticated; select public.bulk_set_candidate_active(array['$c2'::uuid,'$c1'::uuid],true,array[1::bigint,1::bigint],'$(new_uuid)'); commit;"
sqlb="set application_name='$rb'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id='$s1'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$readyb',0)); select pg_advisory_lock(hashtextextended('$gb',0)); select pg_advisory_unlock(hashtextextended('$gb',0)); set local role authenticated; select public.copy_interview_schedule('$i1','$a2',1,1,'$i2',1,null,null,null,null,null,'p1-04',array[]::uuid[],'$(new_uuid)'); commit;"
run_sql_file "$sqla" "$oa" & pa=$!; registered_pids+=("$pa"); wait_for_holder_at_gate "$ra" "$ready" "$pa" "$oa"; hp="$HOLDER_BACKEND_PID"; run_sql_file "$sqlb" "$ob" & pb=$!; registered_pids+=("$pb"); wait_for_holder_at_gate "$rb" "$readyb" "$pb" "$ob"; release_gate "$rg" "$ga_pid"; release_gate "$rg2" "$gb_pid"; wait "$pa"; wait "$pb"; cat "$oa" "$ob"; if grep -qi 'deadlock detected' "$oa" "$ob"; then echo 'FAIL: P1-04 deadlocked'; exit 1; fi; grep -q '"success": true' "$oa"; grep -q '"success": true' "$ob"; psql_exec -qAt -c "select count(*) from public.candidates where candidate_id in ('$c1'::uuid,'$c2'::uuid) and is_active" | grep -qx 2; echo 'PASS: P1-04 completed without deadlock'


echo 'P1-05 current reproduction: bulk scheduling versus crossed single scheduler user set'
z='00000000-0000-4000-8000-0000000000a1'; z_auth='00000000-0000-4000-8000-0000000000a2'; y='10000000-0000-4000-8000-0000000000b1'; y_auth='10000000-0000-4000-8000-0000000000b2'; cb1='30000000-0000-4000-8000-0000000000c1'; cb2='40000000-0000-4000-8000-0000000000c2'; cs='50000000-0000-4000-8000-0000000000c3'; sb1='60000000-0000-4000-8000-0000000000d1'; sb2='70000000-0000-4000-8000-0000000000d2'; ss='80000000-0000-4000-8000-0000000000d3'; ab1='90000000-0000-4000-8000-0000000000e1'; ab2='a0000000-0000-4000-8000-0000000000e2'; as='b0000000-0000-4000-8000-0000000000e3'; ib1='c0000000-0000-4000-8000-0000000000f1'; ib2='d0000000-0000-4000-8000-0000000000f2'; is='e0000000-0000-4000-8000-0000000000f3'
psql_exec -v ON_ERROR_STOP=1 -c "insert into public.app_users(app_user_id,auth_user_id,full_name,email,is_active,is_root_admin) values('$z','$z_auth','P105 Z','p105z_${suffix}@eiu.edu.vn',true,false),('$y','$y_auth','P105 Y','p105y_${suffix}@eiu.edu.vn',true,false); insert into public.app_user_roles(app_user_id,role_code) values('$z','HR'); insert into public.app_user_permissions(app_user_id,permission_code,granted_by) values('$z','interviews.view','$actor_id'),('$z','interviews.manage','$actor_id'); insert into public.candidates(candidate_id,auth_user_id,email,is_active) values('$cb1',gen_random_uuid(),'p105cb1_${suffix}@x.invalid',true),('$cb2',gen_random_uuid(),'p105cb2_${suffix}@x.invalid',true),('$cs',gen_random_uuid(),'p105cs_${suffix}@x.invalid',true); insert into public.submissions(submission_id,candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,status_code) values('$sb1','$cb1','P105 b1','1990-01-01','MALE','A','1','p105cb1_${suffix}@x.invalid','PROCESSED'),('$sb2','$cb2','P105 b2','1990-01-01','MALE','B','2','p105cb2_${suffix}@x.invalid','PROCESSED'),('$ss','$cs','P105 s','1990-01-01','MALE','C','3','p105cs_${suffix}@x.invalid','PROCESSED'); insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active) values('$ab1','$sb1','$unit_id','$pos_id','$actor_id',true),('$ab2','$sb2','$unit_id','$pos_id','$actor_id',true),('$as','$ss','$unit_id','$pos_id','$actor_id',true); insert into public.interviews(interview_id,application_id,round_no,schedule_status_code,report_status_code,is_active,version_no,start_at,end_at,interview_format_id) values('$ib1','$ab1',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1,clock_timestamp()+interval '5 days',clock_timestamp()+interval '6 days','$format_id'),('$ib2','$ab2',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1,clock_timestamp()+interval '7 days',clock_timestamp()+interval '8 days','$format_id'),('$is','$as',1,'AVAILABLE','INTERVIEW_SCHEDULING',true,1,null,null,null); insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_email,is_current) values('$ib1','$y',1,'Y','p105y_${suffix}@eiu.edu.vn',true),('$ib2','$z',1,'Z','p105z_${suffix}@eiu.edu.vn',true),('$is','$actor_id',1,'Actor','actor_${suffix}@eiu.edu.vn',true);"
ra="p1_05_bulk_${suffix}"; rb="p1_05_single_${suffix}"; rg="p1_05_bulk_gate_${suffix}"; rg2="p1_05_single_gate_${suffix}"; registered_apps+=("$ra" "$rb" "$rg" "$rg2"); ga="p1_05_bulk_gate:${suffix}"; gb="p1_05_single_gate:${suffix}"; ready="p1_05_bulk_ready:${suffix}"; readyb="p1_05_single_ready:${suffix}"; oa="/tmp/$ra.out"; ob="/tmp/$rb.out"; setup_gate "$rg" "$ga" "/tmp/$rg.out"; ga_pid=$GATE_PID; setup_gate "$rg2" "$gb" "/tmp/$rg2.out"; gb_pid=$GATE_PID
sqla="set application_name='$ra'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select pg_advisory_xact_lock(hashtextextended('$ready',0)); select pg_advisory_lock(hashtextextended('$ga',0)); select pg_advisory_unlock(hashtextextended('$ga',0)); set local role authenticated; select public.bulk_change_interview_schedule_status(array['$ib1'::uuid,'$ib2'::uuid],'SCHEDULED',array[1::bigint,1::bigint]); commit;"
sqlb="set application_name='$rb'; set deadlock_timeout='500ms'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$z_auth')::text,true); select 1 from public.app_users where app_user_id='$z'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$readyb',0)); select pg_advisory_lock(hashtextextended('$gb',0)); select pg_advisory_unlock(hashtextextended('$gb',0)); set local role authenticated; select public.save_interview_schedule('$is',clock_timestamp()+interval '9 days',clock_timestamp()+interval '10 days','$format_id',null,null,'P105','P105',1,'$(new_uuid)'); commit;"
run_sql_file "$sqla" "$oa" & pa=$!; registered_pids+=("$pa"); wait_for_holder_at_gate "$ra" "$ready" "$pa" "$oa"; run_sql_file "$sqlb" "$ob" & pb=$!; registered_pids+=("$pb"); wait_for_holder_at_gate "$rb" "$readyb" "$pb" "$ob"; release_gate "$rg" "$ga_pid"; release_gate "$rg2" "$gb_pid"; wait "$pa"; wait "$pb"; cat "$oa" "$ob"; if grep -qi 'deadlock detected' "$oa" "$ob"; then echo 'FAIL: P1-05 deadlocked'; exit 1; fi; grep -q '"success": true' "$oa"; grep -q '"success": true' "$ob"; psql_exec -qAt -c "select count(*) from public.interviews where interview_id in ('$ib1'::uuid,'$ib2'::uuid) and schedule_status_code='SCHEDULED'" | grep -qx 2; psql_exec -qAt -c "select version_no = 2 and start_at is not null and end_at is not null from public.interviews where interview_id='$is'::uuid" | grep -qx t; echo 'PASS: P1-05 completed without deadlock'

echo "PASS: all REC-04 forward lock-composition regressions completed"
