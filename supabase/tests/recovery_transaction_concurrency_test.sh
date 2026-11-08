#!/usr/bin/env bash
# =============================================================================
# RECOVERY PACKAGE 003: REC-04 Two-Session Opposing Concurrency Test
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
  sql="${sql/; select public./; set local role authenticated; select public.}"
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
  # Terminate any lingering test backends
  for app in "${registered_apps[@]}"; do
    psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$app' and pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  done
  # Terminate any lingering background shell processes
  for pid in "${registered_pids[@]}"; do
    kill -9 "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done

  rm -f /tmp/rec04_*_${suffix}.* /tmp/*_${suffix}.* 2>/dev/null || true

  echo "=== Running REC-04 Fixture Cleanup ==="
  psql_exec <<SQL
begin;
delete from public.interview_participants
where interview_id in (
  select interview_id from public.interviews
  where application_id in (
    '$app_1'::uuid, '$app_2'::uuid, '$app_3_src'::uuid, '$app_3_tgt'::uuid,
    '$app_4'::uuid, '$app_5_a'::uuid, '$app_5_b'::uuid,
    '$app_6_a'::uuid, '$app_6_b'::uuid, '$app_7'::uuid
  )
);

delete from public.storage_cleanup_queue
where source_parent_id in (
  select interview_id from public.interviews
  where application_id in (
    '$app_1'::uuid, '$app_2'::uuid, '$app_3_src'::uuid, '$app_3_tgt'::uuid,
    '$app_4'::uuid, '$app_5_a'::uuid, '$app_5_b'::uuid,
    '$app_6_a'::uuid, '$app_6_b'::uuid, '$app_7'::uuid
  )
) or source_parent_id in ('$int_7_valid'::uuid, '$int_7_target'::uuid);

delete from public.idempotency_records
where actor_scope in ('app_user:$actor_id', 'app_user:$interviewer_id');

delete from public.interviews
where application_id in (
  '$app_1'::uuid, '$app_2'::uuid, '$app_3_src'::uuid, '$app_3_tgt'::uuid,
  '$app_4'::uuid, '$app_5_a'::uuid, '$app_5_b'::uuid,
  '$app_6_a'::uuid, '$app_6_b'::uuid, '$app_7'::uuid
) or interview_id in ('$int_7_valid'::uuid, '$int_7_target'::uuid);

delete from public.applications
where application_id in (
  '$app_1'::uuid, '$app_2'::uuid, '$app_3_src'::uuid, '$app_3_tgt'::uuid,
  '$app_4'::uuid, '$app_5_a'::uuid, '$app_5_b'::uuid,
  '$app_6_a'::uuid, '$app_6_b'::uuid, '$app_7'::uuid
);

delete from public.submissions
where submission_id in (
  '$sub_1'::uuid, '$sub_2'::uuid, '$sub_3_src'::uuid, '$sub_3_tgt'::uuid,
  '$sub_4'::uuid, '$sub_5_a'::uuid, '$sub_5_b'::uuid,
  '$sub_6_a'::uuid, '$sub_6_b'::uuid, '$sub_7'::uuid
);

delete from public.candidates
where candidate_id in (
  '$cand_1'::uuid, '$cand_2'::uuid, '$cand_3_src'::uuid, '$cand_3_tgt'::uuid,
  '$cand_4'::uuid, '$cand_5_a'::uuid, '$cand_5_b'::uuid,
  '$cand_6_a'::uuid, '$cand_6_b'::uuid, '$cand_7'::uuid
);
delete from public.app_user_permissions
where app_user_id in ('$actor_id'::uuid, '$interviewer_id'::uuid);

delete from public.app_user_roles
where app_user_id in ('$actor_id'::uuid, '$interviewer_id'::uuid);

delete from public.app_users
where app_user_id in ('$actor_id'::uuid, '$interviewer_id'::uuid);

delete from public.interview_formats
where interview_format_id = '$format_id'::uuid;

delete from public.positions
where position_id = '$pos_id'::uuid;

delete from public.position_groups
where position_group_id = '$group_id'::uuid;

delete from public.organizational_units
where unit_id = '$unit_id'::uuid;
commit;
SQL

  local remaining_count
  remaining_count=$(psql_exec -qAt -c "select count(*) from (
    select candidate_id from public.candidates where candidate_id in ('$cand_1'::uuid, '$cand_2'::uuid, '$cand_3_src'::uuid, '$cand_3_tgt'::uuid, '$cand_4'::uuid, '$cand_5_a'::uuid, '$cand_5_b'::uuid, '$cand_6_a'::uuid, '$cand_6_b'::uuid, '$cand_7'::uuid)
    union all
    select app_user_id from public.app_users where app_user_id in ('$actor_id'::uuid, '$interviewer_id'::uuid)
    union all
    select unit_id from public.organizational_units where unit_id = '$unit_id'::uuid
  ) r;" | tr -d '\r')

  if [[ "$remaining_count" -ne 0 ]]; then
    echo "FAIL: Post-cleanup verification failed: $remaining_count fixture records survived" >&2
    exit 1
  fi
  echo "PASS: Cleanup verified zero surviving fixture records."
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
# Test 1: Opposing create_next_interview_round vs delete_or_inactivate_application
# ---------------------------------------------------------------------------
echo "--- Scenario 1: create_next_interview_round vs delete_or_inactivate_application ---"
s1_gate_app="rec04_s1_gate_${suffix}"
s1_del_app="rec04_s1_del_${suffix}"
s1_create_app="rec04_s1_create_${suffix}"
registered_apps+=("$s1_gate_app" "$s1_del_app" "$s1_create_app")
out_s1_gate="/tmp/${s1_gate_app}.out"
out_s1_del="/tmp/${s1_del_app}.out"
out_s1_create="/tmp/${s1_create_app}.out"

gate_1="rec04_s1_gate:${suffix}"
ready_1="rec04_s1_ready:${suffix}"

setup_gate "$s1_gate_app" "$gate_1" "$out_s1_gate"

# Holder stages lock acquisition: holds parent Submission before contrasting application lock
s1_del_sql="set application_name='$s1_del_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id='$sub_1'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready_1',0)); select pg_advisory_lock(hashtextextended('$gate_1',0)); select pg_advisory_unlock(hashtextextended('$gate_1',0)); select public.delete_or_inactivate_application('$app_1'::uuid); commit;"
s1_create_sql="set application_name='$s1_create_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.create_next_interview_round('$app_1'::uuid, '$(new_uuid)'::uuid); commit;"

run_sql_file "$s1_del_sql" "$out_s1_del" &
pid_del_1=$!
registered_pids+=("$pid_del_1")
wait_for_holder_at_gate "$s1_del_app" "$ready_1" "$pid_del_1" "$out_s1_del"
holder_pid_1="$HOLDER_BACKEND_PID"

run_sql_file "$s1_create_sql" "$out_s1_create" &
pid_create_1=$!
registered_pids+=("$pid_create_1")

wait_for_blocked_by "$s1_create_app" "$holder_pid_1" "$pid_create_1" "$out_s1_create"
echo "PASS: create_next_interview_round cleanly waited on opposing delete_or_inactivate_application lock."

release_gate "$s1_gate_app" "$GATE_PID"

wait "$pid_del_1"
wait "$pid_create_1"

if grep -qi 'deadlock detected' "$out_s1_del" "$out_s1_create"; then
  echo "FAIL: Deadlock detected in Scenario 1:" >&2
  cat "$out_s1_del" "$out_s1_create" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s1_del" || ! grep -q '"action": "INACTIVATED"' "$out_s1_del"; then
  echo "FAIL: Scenario 1 delete_or_inactivate_application did not succeed as expected:" >&2
  cat "$out_s1_del" >&2
  exit 1
fi

if ! grep -q '"success": false' "$out_s1_create" || ! grep -q 'APPLICATION_INACTIVE' "$out_s1_create"; then
  echo "FAIL: Scenario 1 create_next_interview_round did not reject with APPLICATION_INACTIVE:" >&2
  cat "$out_s1_create" >&2
  exit 1
fi

psql_exec -qAt -c "select (not is_active)::text from public.applications where application_id='$app_1'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select count(*)::text from public.interviews where application_id='$app_1'::uuid;" | tr -d '\r' | grep -qx '1'
echo "PASS: Scenario 1 opposing writers resolved cleanly and maintained lifecycle invariants without deadlock."

# ---------------------------------------------------------------------------
# Test 2: Opposing reactivate_interview vs delete_or_inactivate_application
# ---------------------------------------------------------------------------
echo "--- Scenario 2: reactivate_interview vs delete_or_inactivate_application ---"
s2_gate_app="rec04_s2_gate_${suffix}"
s2_del_app="rec04_s2_del_${suffix}"
s2_react_app="rec04_s2_react_${suffix}"
registered_apps+=("$s2_gate_app" "$s2_del_app" "$s2_react_app")
out_s2_gate="/tmp/${s2_gate_app}.out"
out_s2_del="/tmp/${s2_del_app}.out"
out_s2_react="/tmp/${s2_react_app}.out"

gate_2="rec04_s2_gate:${suffix}"
ready_2="rec04_s2_ready:${suffix}"

setup_gate "$s2_gate_app" "$gate_2" "$out_s2_gate"

# Holder stages parent-vs-Interview lock composition: locks parent Submission and Application first, signals ready, waits at gate, then takes the target Interview before application inactivation. This makes the pre-REC04 Interview-first contender form a lock cycle.
s2_del_sql="set application_name='$s2_del_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id='$sub_2'::uuid for update; select 1 from public.applications where application_id='$app_2'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready_2',0)); select pg_advisory_lock(hashtextextended('$gate_2',0)); select pg_advisory_unlock(hashtextextended('$gate_2',0)); select 1 from public.interviews where interview_id='$int_2_2'::uuid for update; select public.delete_or_inactivate_application('$app_2'::uuid); commit;"
s2_react_sql="set application_name='$s2_react_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.reactivate_interview('$int_2_2'::uuid, 1); commit;"

run_sql_file "$s2_del_sql" "$out_s2_del" &
pid_del_2=$!
registered_pids+=("$pid_del_2")
wait_for_holder_at_gate "$s2_del_app" "$ready_2" "$pid_del_2" "$out_s2_del"
holder_pid_2="$HOLDER_BACKEND_PID"

run_sql_file "$s2_react_sql" "$out_s2_react" &
pid_react_2=$!
registered_pids+=("$pid_react_2")

wait_for_blocked_by "$s2_react_app" "$holder_pid_2" "$pid_react_2" "$out_s2_react"
echo "PASS: reactivate_interview cleanly waited on opposing delete_or_inactivate_application lock."

release_gate "$s2_gate_app" "$GATE_PID"

wait "$pid_del_2"
wait "$pid_react_2"

if grep -qi 'deadlock detected' "$out_s2_del" "$out_s2_react"; then
  echo "FAIL: Deadlock detected in Scenario 2:" >&2
  cat "$out_s2_del" "$out_s2_react" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s2_del" || ! grep -q '"action": "INACTIVATED"' "$out_s2_del"; then
  echo "FAIL: Scenario 2 delete_or_inactivate_application did not succeed as expected:" >&2
  cat "$out_s2_del" >&2
  exit 1
fi

if ! grep -q '"success": false' "$out_s2_react" || ! grep -q 'APPLICATION_INACTIVE' "$out_s2_react"; then
  echo "FAIL: Scenario 2 reactivate_interview did not reject with APPLICATION_INACTIVE:" >&2
  cat "$out_s2_react" >&2
  exit 1
fi

psql_exec -qAt -c "select (not is_active)::text from public.applications where application_id='$app_2'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select (not is_active)::text from public.interviews where interview_id='$int_2_2'::uuid;" | tr -d '\r' | grep -qx 'true'
echo "PASS: Scenario 2 opposing writers resolved cleanly and maintained lifecycle invariants without deadlock."

# ---------------------------------------------------------------------------
# Test 3: Opposing copy_interview_schedule vs delete_or_inactivate_application
# ---------------------------------------------------------------------------
echo "--- Scenario 3: copy_interview_schedule vs delete_or_inactivate_application ---"
s3_gate_app="rec04_s3_gate_${suffix}"
s3_del_app="rec04_s3_del_${suffix}"
s3_copy_app="rec04_s3_copy_${suffix}"
registered_apps+=("$s3_gate_app" "$s3_del_app" "$s3_copy_app")
out_s3_gate="/tmp/${s3_gate_app}.out"
out_s3_del="/tmp/${s3_del_app}.out"
out_s3_copy="/tmp/${s3_copy_app}.out"

gate_3="rec04_s3_gate:${suffix}"
ready_3="rec04_s3_ready:${suffix}"

setup_gate "$s3_gate_app" "$gate_3" "$out_s3_gate"

# Holder stages lock acquisition: holds target Submission before contrasting Application lock
s3_del_sql="set application_name='$s3_del_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id='$sub_3_tgt'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready_3',0)); select pg_advisory_lock(hashtextextended('$gate_3',0)); select pg_advisory_unlock(hashtextextended('$gate_3',0)); select public.delete_or_inactivate_application('$app_3_tgt'::uuid); commit;"
s3_copy_sql="set application_name='$s3_copy_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.copy_interview_schedule('$int_3_src'::uuid, '$app_3_tgt'::uuid, 1, 1, '$int_3_tgt'::uuid, 1, null, null, null, null, null, 'racing copy schedule note', array[]::uuid[], '$(new_uuid)'::uuid); commit;"

run_sql_file "$s3_del_sql" "$out_s3_del" &
pid_del_3=$!
registered_pids+=("$pid_del_3")
wait_for_holder_at_gate "$s3_del_app" "$ready_3" "$pid_del_3" "$out_s3_del"
holder_pid_3="$HOLDER_BACKEND_PID"

run_sql_file "$s3_copy_sql" "$out_s3_copy" &
pid_copy_3=$!
registered_pids+=("$pid_copy_3")

wait_for_blocked_by "$s3_copy_app" "$holder_pid_3" "$pid_copy_3" "$out_s3_copy"
echo "PASS: copy_interview_schedule cleanly waited on opposing delete_or_inactivate_application lock."

release_gate "$s3_gate_app" "$GATE_PID"

wait "$pid_del_3"
wait "$pid_copy_3"

if grep -qi 'deadlock detected' "$out_s3_del" "$out_s3_copy"; then
  echo "FAIL: Deadlock detected in Scenario 3:" >&2
  cat "$out_s3_del" "$out_s3_copy" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s3_del" || ! grep -q '"action": "INACTIVATED"' "$out_s3_del"; then
  echo "FAIL: Scenario 3 delete_or_inactivate_application did not succeed as expected:" >&2
  cat "$out_s3_del" >&2
  exit 1
fi

if ! grep -q '"success": false' "$out_s3_copy" || ! grep -q 'STALE_VERSION' "$out_s3_copy"; then
  echo "FAIL: Scenario 3 copy_interview_schedule did not reject stale target state:" >&2
  cat "$out_s3_copy" >&2
  exit 1
fi

psql_exec -qAt -c "select (not is_active)::text from public.applications where application_id='$app_3_tgt'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select count(*)::text from public.interviews where application_id='$app_3_tgt'::uuid and copied_from_interview_id is not null;" | tr -d '\r' | grep -qx '0'
psql_exec -qAt -c "select (start_at is null)::text from public.interviews where interview_id='$int_3_tgt'::uuid;" | tr -d '\r' | grep -qx 'true'
echo "PASS: Scenario 3 opposing writers resolved cleanly and maintained lifecycle invariants without deadlock."

# ---------------------------------------------------------------------------
# Test 4: Opposing save_interview_schedule vs delete_or_inactivate_interview
# ---------------------------------------------------------------------------
echo "--- Scenario 4: save_interview_schedule vs delete_or_inactivate_interview ---"
s4_gate_app="rec04_s4_gate_${suffix}"
s4_inact_app="rec04_s4_inact_${suffix}"
s4_sched_app="rec04_s4_sched_${suffix}"
registered_apps+=("$s4_gate_app" "$s4_inact_app" "$s4_sched_app")
out_s4_gate="/tmp/${s4_gate_app}.out"
out_s4_inact="/tmp/${s4_inact_app}.out"
out_s4_sched="/tmp/${s4_sched_app}.out"

gate_4="rec04_s4_gate:${suffix}"
ready_4="rec04_s4_ready:${suffix}"

setup_gate "$s4_gate_app" "$gate_4" "$out_s4_gate"

# Holder stages parent-vs-Interview lock composition: locks parent Submission and Application first, signals ready, waits at gate, then completes delete_or_inactivate_interview
s4_inact_sql="set application_name='$s4_inact_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id='$sub_4'::uuid for update; select 1 from public.applications where application_id='$app_4'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready_4',0)); select pg_advisory_lock(hashtextextended('$gate_4',0)); select pg_advisory_unlock(hashtextextended('$gate_4',0)); select public.delete_or_inactivate_interview('$int_4_1'::uuid, 1); commit;"
s4_sched_sql="set application_name='$s4_sched_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.save_interview_schedule('$int_4_1'::uuid, '2042-06-01 09:00:00+07'::timestamptz, '2042-06-01 10:00:00+07'::timestamptz, '$format_id'::uuid, null, null, 'Demo Topic', 'Scheduled Note', 1, '$(new_uuid)'::uuid); commit;"

run_sql_file "$s4_inact_sql" "$out_s4_inact" &
pid_inact_4=$!
registered_pids+=("$pid_inact_4")
wait_for_holder_at_gate "$s4_inact_app" "$ready_4" "$pid_inact_4" "$out_s4_inact"
holder_pid_4="$HOLDER_BACKEND_PID"

run_sql_file "$s4_sched_sql" "$out_s4_sched" &
pid_sched_4=$!
registered_pids+=("$pid_sched_4")

wait_for_blocked_by "$s4_sched_app" "$holder_pid_4" "$pid_sched_4" "$out_s4_sched"
echo "PASS: save_interview_schedule cleanly waited on opposing delete_or_inactivate_interview lock."

release_gate "$s4_gate_app" "$GATE_PID"

wait "$pid_inact_4"
wait "$pid_sched_4"

if grep -qi 'deadlock detected' "$out_s4_inact" "$out_s4_sched"; then
  echo "FAIL: Deadlock detected in Scenario 4:" >&2
  cat "$out_s4_inact" "$out_s4_sched" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s4_inact" || ! grep -q '"action": "INACTIVATED"' "$out_s4_inact"; then
  echo "FAIL: Scenario 4 delete_or_inactivate_interview did not succeed as expected:" >&2
  cat "$out_s4_inact" >&2
  exit 1
fi

if ! grep -q '"success": false' "$out_s4_sched" || ! grep -q 'STALE_VERSION' "$out_s4_sched"; then
  echo "FAIL: Scenario 4 save_interview_schedule did not reject with STALE_VERSION:" >&2
  cat "$out_s4_sched" >&2
  exit 1
fi

psql_exec -qAt -c "select (not is_active)::text from public.interviews where interview_id='$int_4_1'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select (start_at is null)::text from public.interviews where interview_id='$int_4_1'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select version_no::text from public.interviews where interview_id='$int_4_1'::uuid;" | tr -d '\r' | grep -qx '2'
echo "PASS: Scenario 4 schedule vs lifecycle writer contention resolved cleanly without deadlock."

# ---------------------------------------------------------------------------
# Test 5: Concurrent schedule writers contending on shared participant resource
# ---------------------------------------------------------------------------
echo "--- Scenario 5: Concurrent schedule writers contending on shared participant resource ---"
s5_gate_app="rec04_s5_gate_${suffix}"
s5_sched_a_app="rec04_s5_sched_a_${suffix}"
s5_sched_b_app="rec04_s5_sched_b_${suffix}"
registered_apps+=("$s5_gate_app" "$s5_sched_a_app" "$s5_sched_b_app")
out_s5_gate="/tmp/${s5_gate_app}.out"
out_s5_a="/tmp/${s5_sched_a_app}.out"
out_s5_b="/tmp/${s5_sched_b_app}.out"

gate_5="rec04_s5_gate:${suffix}"
ready_5="rec04_s5_ready:${suffix}"

setup_gate "$s5_gate_app" "$gate_5" "$out_s5_gate"

# Writer A runs save_interview_schedule (acquiring participant advisory lock), signals ready, waits at gate before commit
s5_a_sql="set application_name='$s5_sched_a_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.save_interview_schedule('$int_5_a'::uuid, '2042-07-01 09:00:00+07'::timestamptz, '2042-07-01 10:00:00+07'::timestamptz, '$format_id'::uuid, null, null, 'Demo A', 'Note A', 1, '$(new_uuid)'::uuid); select pg_advisory_xact_lock(hashtextextended('$ready_5',0)); select pg_advisory_lock(hashtextextended('$gate_5',0)); select pg_advisory_unlock(hashtextextended('$gate_5',0)); commit;"
s5_b_sql="set application_name='$s5_sched_b_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.save_interview_schedule('$int_5_b'::uuid, '2042-07-01 09:30:00+07'::timestamptz, '2042-07-01 10:30:00+07'::timestamptz, '$format_id'::uuid, null, null, 'Demo B', 'Note B', 1, '$(new_uuid)'::uuid); commit;"

run_sql_file "$s5_a_sql" "$out_s5_a" &
pid_5_a=$!
registered_pids+=("$pid_5_a")
wait_for_holder_at_gate "$s5_sched_a_app" "$ready_5" "$pid_5_a" "$out_s5_a"
holder_pid_5="$HOLDER_BACKEND_PID"

run_sql_file "$s5_b_sql" "$out_s5_b" &
pid_5_b=$!
registered_pids+=("$pid_5_b")

wait_for_blocked_by "$s5_sched_b_app" "$holder_pid_5" "$pid_5_b" "$out_s5_b"
echo "PASS: Concurrent schedule writer B cleanly waited on participant resource advisory lock."

release_gate "$s5_gate_app" "$GATE_PID"

wait "$pid_5_a"
wait "$pid_5_b"

if grep -qi 'deadlock detected' "$out_s5_a" "$out_s5_b"; then
  echo "FAIL: Deadlock detected in Scenario 5:" >&2
  cat "$out_s5_a" "$out_s5_b" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s5_a"; then
  echo "FAIL: Scenario 5 schedule writer A did not succeed:" >&2
  cat "$out_s5_a" >&2
  exit 1
fi

if ! grep -q '"success": false' "$out_s5_b" || ! grep -q 'SCHEDULE_CONFLICT_INTERVIEWER' "$out_s5_b"; then
  echo "FAIL: Scenario 5 schedule writer B did not reject with SCHEDULE_CONFLICT_INTERVIEWER:" >&2
  cat "$out_s5_b" >&2
  exit 1
fi

psql_exec -qAt -c "select (start_at is not null)::text from public.interviews where interview_id='$int_5_a'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select (start_at is null)::text from public.interviews where interview_id='$int_5_b'::uuid;" | tr -d '\r' | grep -qx 'true'
echo "PASS: Scenario 5 participant resource contention serialized cleanly and prevented double-booking without deadlock."

# ---------------------------------------------------------------------------
# Test 6: Opposing bulk_change_report_status vs change_report_status
# Proves cycle-free hierarchical lock ordering: Submission -> Application -> Interview
# ---------------------------------------------------------------------------
echo "--- Scenario 6: bulk_change_report_status vs single change_report_status ---"
s6_gate_app="rec04_s6_gate_${suffix}"
s6_bulk_app="rec04_s6_bulk_${suffix}"
s6_single_app="rec04_s6_single_${suffix}"
registered_apps+=("$s6_gate_app" "$s6_bulk_app" "$s6_single_app")
out_s6_gate="/tmp/${s6_gate_app}.out"
out_s6_bulk="/tmp/${s6_bulk_app}.out"
out_s6_single="/tmp/${s6_single_app}.out"

gate_6="rec04_s6_gate:${suffix}"
ready_6="rec04_s6_ready:${suffix}"

setup_gate "$s6_gate_app" "$gate_6" "$out_s6_gate"

# Single writer acquires Submission lock first, signals ready, waits at gate, then performs change_report_status.
# Bulk writer starts concurrently and must wait on the Submission lock (Submission-first hierarchy).
# An old Application-first bulk writer would instead lock Applications first, causing a deadlock or inversion.
s6_single_sql="set application_name='$s6_single_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.submissions where submission_id='$sub_6_b'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready_6',0)); select pg_advisory_lock(hashtextextended('$gate_6',0)); select pg_advisory_unlock(hashtextextended('$gate_6',0)); select public.change_report_status('$int_6_b'::uuid, 'AWAITING_INTERVIEW', 1); commit;"
s6_bulk_sql="set application_name='$s6_bulk_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.bulk_change_report_status(array['$int_6_a'::uuid, '$int_6_b'::uuid], 'WAITING_FOR_REPORT', array[1::bigint, 1::bigint]); commit;"

run_sql_file "$s6_single_sql" "$out_s6_single" &
pid_single_6=$!
registered_pids+=("$pid_single_6")
wait_for_holder_at_gate "$s6_single_app" "$ready_6" "$pid_single_6" "$out_s6_single"
holder_pid_6="$HOLDER_BACKEND_PID"

run_sql_file "$s6_bulk_sql" "$out_s6_bulk" &
pid_bulk_6=$!
registered_pids+=("$pid_bulk_6")

wait_for_blocked_by "$s6_bulk_app" "$holder_pid_6" "$pid_bulk_6" "$out_s6_bulk"
echo "PASS: Single/bulk synchronized while bulk waits on the parent hierarchy."

release_gate "$s6_gate_app" "$GATE_PID"

if ! wait "$pid_single_6"; then
  echo "FAIL: Scenario 6 single writer process failed:" >&2
  cat "$out_s6_single" >&2
  exit 1
fi
if ! wait "$pid_bulk_6"; then
  echo "FAIL: Scenario 6 bulk writer process failed:" >&2
  cat "$out_s6_bulk" >&2
  exit 1
fi

if grep -qi 'deadlock detected' "$out_s6_bulk" "$out_s6_single"; then
  echo "FAIL: Deadlock detected in Scenario 6 opposing report status writers:" >&2
  cat "$out_s6_bulk" >&2
  cat "$out_s6_single" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s6_single"; then
  echo "FAIL: Scenario 6 single report status writer did not succeed:" >&2
  cat "$out_s6_single" >&2
  exit 1
fi

if ! grep -q '"success": false' "$out_s6_bulk" || ! grep -q 'STALE_VERSION' "$out_s6_bulk"; then
  echo "FAIL: Scenario 6 bulk report writer did not report STALE_VERSION after opposing single update:" >&2
  cat "$out_s6_bulk" >&2
  exit 1
fi

psql_exec -qAt -c "select report_status_code from public.interviews where interview_id='$int_6_a'::uuid;" | tr -d '\r' | grep -qx 'INTERVIEW_SCHEDULING'
psql_exec -qAt -c "select report_status_code from public.interviews where interview_id='$int_6_b'::uuid;" | tr -d '\r' | grep -qx 'AWAITING_INTERVIEW'
psql_exec -qAt -c "select version_no::text from public.interviews where interview_id='$int_6_b'::uuid;" | tr -d '\r' | grep -qx '2'
echo "PASS: Scenario 6 opposing single/bulk report writers serialized cleanly along Submission-first hierarchy without deadlock."

# ---------------------------------------------------------------------------
# Test 7: Post-lock target disappearance (opposing committed hard-delete)
# Proves that when target exists at bulk precheck, command blocks on target,
# competing transaction hard-deletes target and commits, bulk revalidation
# aborts with NOT_FOUND and zero writes / audits / cleanup entries.
# ---------------------------------------------------------------------------
echo "--- Scenario 7: Post-lock target disappearance (opposing committed hard-delete) ---"
s7_gate_app="rec04_s7_gate_${suffix}"
s7_block_app="rec04_s7_block_${suffix}"
s7_bulk_app="rec04_s7_bulk_${suffix}"
registered_apps+=("$s7_gate_app" "$s7_block_app" "$s7_bulk_app")
out_s7_gate="/tmp/${s7_gate_app}.out"
out_s7_block="/tmp/${s7_block_app}.out"
out_s7_bulk="/tmp/${s7_bulk_app}.out"

gate_7="rec04_s7_gate:${suffix}"
ready_7="rec04_s7_ready:${suffix}"

setup_gate "$s7_gate_app" "$gate_7" "$out_s7_gate"

# Holder locks target interview for update, signals ready, waits at gate, then hard-deletes target interview and commits
s7_block_sql="set application_name='$s7_block_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select 1 from public.interviews where interview_id='$int_7_target'::uuid for update; select pg_advisory_xact_lock(hashtextextended('$ready_7',0)); select pg_advisory_lock(hashtextextended('$gate_7',0)); select pg_advisory_unlock(hashtextextended('$gate_7',0)); delete from public.interviews where interview_id='$int_7_target'::uuid; commit;"
s7_bulk_sql="set application_name='$s7_bulk_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.bulk_delete_or_inactivate_interviews(array['$int_7_valid'::uuid, '$int_7_target'::uuid], array[1::bigint, 1::bigint]); commit;"

run_sql_file "$s7_block_sql" "$out_s7_block" &
pid_block_7=$!
registered_pids+=("$pid_block_7")
wait_for_holder_at_gate "$s7_block_app" "$ready_7" "$pid_block_7" "$out_s7_block"
holder_pid_7="$HOLDER_BACKEND_PID"

run_sql_file "$s7_bulk_sql" "$out_s7_bulk" &
pid_bulk_7=$!
registered_pids+=("$pid_bulk_7")

wait_for_blocked_by "$s7_bulk_app" "$holder_pid_7" "$pid_bulk_7" "$out_s7_bulk"
echo "PASS: Bulk delete command cleanly blocked on target interview lock after passing precheck."

release_gate "$s7_gate_app" "$GATE_PID"

wait "$pid_block_7"
wait "$pid_bulk_7"

if grep -qi 'deadlock detected' "$out_s7_block" "$out_s7_bulk"; then
  echo "FAIL: Deadlock detected in Scenario 7:" >&2
  cat "$out_s7_block" "$out_s7_bulk" >&2
  exit 1
fi

if ! grep -q 'DELETE 1' "$out_s7_block" && ! grep -q 'COMMIT' "$out_s7_block"; then
  echo "FAIL: Scenario 7 blocking hard-delete transaction did not commit:" >&2
  cat "$out_s7_block" >&2
  exit 1
fi

if ! grep -q '"success": false' "$out_s7_bulk" || ! grep -q 'NOT_FOUND' "$out_s7_bulk"; then
  echo "FAIL: Scenario 7 bulk command did not return NOT_FOUND on post-lock disappearance:" >&2
  cat "$out_s7_bulk" >&2
  exit 1
fi

# Assert zero surviving item writes: valid interview remains intact
psql_exec -qAt -c "select is_active::text from public.interviews where interview_id='$int_7_valid'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select version_no::text from public.interviews where interview_id='$int_7_valid'::uuid;" | tr -d '\r' | grep -qx '1'

# Assert zero audit logs written for bulk delete on int_7_valid
audit_count_7=$(psql_exec -qAt -c "select count(*) from public.security_audit_log where entity_id='$int_7_valid'::uuid and action_code in ('DELETE_INTERVIEW','INACTIVATE_INTERVIEW');" | tr -d '\r')
if [[ "$audit_count_7" -ne 0 ]]; then
  echo "FAIL: Scenario 7 wrote $audit_count_7 audit log entries on aborted bulk command" >&2
  exit 1
fi

# Assert zero cleanup queue writes
cleanup_count_7=$(psql_exec -qAt -c "select count(*) from public.storage_cleanup_queue where source_parent_id in ('$int_7_valid'::uuid, '$int_7_target'::uuid);" | tr -d '\r')
if [[ "$cleanup_count_7" -ne 0 ]]; then
  echo "FAIL: Scenario 7 wrote $cleanup_count_7 cleanup queue entries on aborted bulk command" >&2
  exit 1
fi

echo "PASS: Scenario 7 post-lock disappearance aborted with NOT_FOUND and zero surviving item/audit/cleanup writes."
echo "====================================================================="
echo "=== ALL REC-04 CONCURRENCY OPPOSING TESTS COMPLETED CLEANLY       ==="
echo "====================================================================="
