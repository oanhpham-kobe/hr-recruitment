#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_eiu-recruitment-dev"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"

# Deterministic User UUID order for the actor/participant crossing proof.
deactivate_user_id="10000000-0000-0000-0000-${suffix}"
participant_id="20000000-0000-0000-0000-${suffix}"
actor_id="f0000000-0000-0000-0000-${suffix}"
actor_auth_id="$(new_uuid)"

unit_id="$(new_uuid)"
group_id="$(new_uuid)"
position_id="$(new_uuid)"
format_id="$(new_uuid)"

candidate_a_source_id="$(new_uuid)"
candidate_a_target_id="$(new_uuid)"
candidate_b_copy_id="$(new_uuid)"
candidate_b_schedule_id="$(new_uuid)"

submission_a_source_id="$(new_uuid)"
submission_a_target_id="$(new_uuid)"
submission_b_copy_id="$(new_uuid)"
submission_b_schedule_id="$(new_uuid)"

application_a_source_id="$(new_uuid)"
application_a_target_id="$(new_uuid)"
application_b_copy_id="$(new_uuid)"
application_b_schedule_id="$(new_uuid)"

source_a_id="$(new_uuid)"
target_a_r1_id="$(new_uuid)"
source_b_r1_id="$(new_uuid)"
schedule_b_r1_id="$(new_uuid)"

copy_a_key="$(new_uuid)"
deactivate_key="$(new_uuid)"
copy_b_key="$(new_uuid)"

psql_exec() {
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

run_sql_file() {
  local sql="$1"
  local out="$2"
  printf '%s\n' "$sql" | docker exec -i "$container_name" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres >"$out" 2>&1
}

wait_for_lock_wait() {
  local app_name="$1"
  local i
  for i in $(seq 1 80); do
    if psql_exec -qAt -c "select coalesce(bool_or(wait_event_type='Lock'),false)::text from pg_stat_activity where application_name='${app_name}';" | tr -d '\r' | grep -qx 'true'; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for ${app_name} to reach a lock wait" >&2
  psql_exec -c "select pid,application_name,state,wait_event_type,wait_event,query from pg_stat_activity where application_name='${app_name}';" >&2 || true
  return 1
}

cleanup() {
  psql_exec >/dev/null 2>&1 <<SQL || true
begin;
drop trigger if exists s06_copy_concurrency_gate on public.interviews;
drop function if exists private.s06_copy_concurrency_gate();

delete from public.interview_participants
where interview_id in (
  select interview_id from public.interviews
  where application_id in (
    '$application_a_source_id'::uuid,
    '$application_a_target_id'::uuid,
    '$application_b_copy_id'::uuid,
    '$application_b_schedule_id'::uuid
  )
);

delete from public.idempotency_records
where actor_scope = 'app_user:$actor_id';

delete from public.interviews
where application_id in ('$application_a_target_id'::uuid,'$application_b_copy_id'::uuid)
  and copied_from_interview_id is not null;

delete from public.interviews
where application_id in (
  '$application_a_source_id'::uuid,
  '$application_a_target_id'::uuid,
  '$application_b_copy_id'::uuid,
  '$application_b_schedule_id'::uuid
);

delete from public.applications
where application_id in (
  '$application_a_source_id'::uuid,
  '$application_a_target_id'::uuid,
  '$application_b_copy_id'::uuid,
  '$application_b_schedule_id'::uuid
);

delete from public.submissions
where submission_id in (
  '$submission_a_source_id'::uuid,
  '$submission_a_target_id'::uuid,
  '$submission_b_copy_id'::uuid,
  '$submission_b_schedule_id'::uuid
);

delete from public.candidates
where candidate_id in (
  '$candidate_a_source_id'::uuid,
  '$candidate_a_target_id'::uuid,
  '$candidate_b_copy_id'::uuid,
  '$candidate_b_schedule_id'::uuid
);

delete from public.app_user_permissions
where app_user_id in ('$actor_id'::uuid,'$participant_id'::uuid,'$deactivate_user_id'::uuid);
delete from public.app_user_roles
where app_user_id in ('$actor_id'::uuid,'$participant_id'::uuid,'$deactivate_user_id'::uuid);
delete from public.app_users
where app_user_id in ('$actor_id'::uuid,'$participant_id'::uuid,'$deactivate_user_id'::uuid);
delete from public.positions where position_id='$position_id'::uuid;
delete from public.interview_formats where interview_format_id='$format_id'::uuid;
delete from public.position_groups where position_group_id='$group_id'::uuid;
delete from public.organizational_units where unit_id='$unit_id'::uuid;
commit;
SQL
}
trap cleanup EXIT

# Actor UUID must sort after participant UUID for the reviewer-specified R -> P / P -> R crossing.
if [[ "$participant_id" > "$actor_id" || "$participant_id" == "$actor_id" ]]; then
  echo "Fixture UUID ordering invalid: participant must sort before actor" >&2
  exit 1
fi

psql_exec <<SQL
insert into public.position_groups(position_group_id,name_vi,code,is_active)
values('$group_id'::uuid,'Slice-06 Copy concurrency group','S06COPY_G_${suffix}',true);
insert into public.organizational_units(unit_id,name_vi,code,is_active)
values('$unit_id'::uuid,'Slice-06 Copy concurrency unit','S06COPY_U_${suffix}',true);
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi,is_active)
values('$position_id'::uuid,'$unit_id'::uuid,'$group_id'::uuid,'S06COPY_P_${suffix}','Slice-06 Copy position',true);
insert into public.interview_formats(interview_format_id,code,name_vi,requires_room,requires_meeting_link,is_active)
values('$format_id'::uuid,'S06COPY_F_${suffix}','Slice-06 Copy format',false,false,true);

insert into public.app_users(app_user_id,auth_user_id,email,full_name,job_title,is_active,is_root_admin)
values
  ('$deactivate_user_id'::uuid,null,'copy_deactivate_${suffix}@eiu.edu.vn','Copy Deactivation Target','Interviewer',true,false),
  ('$participant_id'::uuid,null,'copy_participant_${suffix}@eiu.edu.vn','Copy Ordered Participant','Interviewer',true,false),
  ('$actor_id'::uuid,'$actor_auth_id'::uuid,'copy_actor_${suffix}@eiu.edu.vn','Copy HR Actor','HR',true,false);
insert into public.app_user_roles(app_user_id,role_code) values('$actor_id'::uuid,'HR');
insert into public.app_user_permissions(app_user_id,permission_code) values
  ('$actor_id'::uuid,'interviews.view'),
  ('$actor_id'::uuid,'interviews.manage'),
  ('$actor_id'::uuid,'interviews.status'),
  ('$actor_id'::uuid,'users.directory_manage')
on conflict do nothing;

insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active) values
  ('$candidate_a_source_id'::uuid,'$(new_uuid)'::uuid,'copy_a_source_${suffix}@example.test','Copy A Source',true),
  ('$candidate_a_target_id'::uuid,'$(new_uuid)'::uuid,'copy_a_target_${suffix}@example.test','Copy A Target',true),
  ('$candidate_b_copy_id'::uuid,'$(new_uuid)'::uuid,'copy_b_${suffix}@example.test','Copy B',true),
  ('$candidate_b_schedule_id'::uuid,'$(new_uuid)'::uuid,'schedule_b_${suffix}@example.test','Schedule B',true);

insert into public.submissions(
  submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,version_no
) values
  ('$submission_a_source_id'::uuid,'$candidate_a_source_id'::uuid,'READ','Copy A Source','1990-01-01','MALE','Address','0900000001','copy_a_source_${suffix}@example.test',1),
  ('$submission_a_target_id'::uuid,'$candidate_a_target_id'::uuid,'READ','Copy A Target','1990-01-01','MALE','Address','0900000002','copy_a_target_${suffix}@example.test',1),
  ('$submission_b_copy_id'::uuid,'$candidate_b_copy_id'::uuid,'READ','Copy B','1990-01-01','MALE','Address','0900000003','copy_b_${suffix}@example.test',1),
  ('$submission_b_schedule_id'::uuid,'$candidate_b_schedule_id'::uuid,'READ','Schedule B','1990-01-01','MALE','Address','0900000004','schedule_b_${suffix}@example.test',1);

insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active) values
  ('$application_a_source_id'::uuid,'$submission_a_source_id'::uuid,'$unit_id'::uuid,'$position_id'::uuid,'$actor_id'::uuid,true),
  ('$application_a_target_id'::uuid,'$submission_a_target_id'::uuid,'$unit_id'::uuid,'$position_id'::uuid,'$actor_id'::uuid,true),
  ('$application_b_copy_id'::uuid,'$submission_b_copy_id'::uuid,'$unit_id'::uuid,'$position_id'::uuid,'$actor_id'::uuid,true),
  ('$application_b_schedule_id'::uuid,'$submission_b_schedule_id'::uuid,'$unit_id'::uuid,'$position_id'::uuid,'$actor_id'::uuid,true);

insert into public.interviews(interview_id,application_id,round_no,is_active) values
  ('$source_a_id'::uuid,'$application_a_source_id'::uuid,1,true),
  ('$target_a_r1_id'::uuid,'$application_a_target_id'::uuid,1,true),
  ('$source_b_r1_id'::uuid,'$application_b_copy_id'::uuid,1,true),
  ('$schedule_b_r1_id'::uuid,'$application_b_schedule_id'::uuid,1,true);

insert into public.interview_participants(
  interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email,is_current
) values(
  '$schedule_b_r1_id'::uuid,'$participant_id'::uuid,1,
  'Copy Ordered Participant','Interviewer','copy_participant_${suffix}@eiu.edu.vn',true
);
SQL

# ---------------------------------------------------------------------------
# A. Scheduled Copy waits on the target Candidate resource gate. Deactivation
# commits while it waits. Copy must post-lock revalidate and fail atomically;
# the exact requested participant may never be silently omitted.
# ---------------------------------------------------------------------------
copy_a_app_name="s06-copy-deactivation-${suffix}"
holder_a_app_name="s06-copy-candidate-holder-${suffix}"

source_a_version="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$source_a_id'::uuid;" | tr -d '\r')"
target_a_app_version="$(psql_exec -qAt -c "select version_no from public.applications where application_id='$application_a_target_id'::uuid;" | tr -d '\r')"
target_a_r1_version="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$target_a_r1_id'::uuid;" | tr -d '\r')"
deactivate_version="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$deactivate_user_id'::uuid;" | tr -d '\r')"

holder_a_sql="set application_name='$holder_a_app_name'; begin; select pg_advisory_xact_lock(hashtextextended('candidate:$candidate_a_target_id',0)); select pg_sleep(4); commit;"
copy_a_sql="set application_name='$copy_a_app_name'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.copy_interview_schedule('$source_a_id'::uuid,'$application_a_target_id'::uuid,$source_a_version,$target_a_app_version,'$target_a_r1_id'::uuid,$target_a_r1_version,'2042-01-10 09:00+07'::timestamptz,'2042-01-10 10:00+07'::timestamptz,'$format_id'::uuid,null,null,'copy/deactivation race',array['$deactivate_user_id'::uuid],'$copy_a_key'::uuid); commit;"
deactivate_sql="begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.set_internal_user_active('$deactivate_user_id'::uuid,false,$deactivate_version,'$deactivate_key'::uuid); commit;"

run_sql_file "$holder_a_sql" /tmp/s06-copy-holder-a.txt & holder_a_pid=$!
sleep 0.2
run_sql_file "$copy_a_sql" /tmp/s06-copy-a.txt & copy_a_pid=$!
wait_for_lock_wait "$copy_a_app_name"

run_sql_file "$deactivate_sql" /tmp/s06-copy-deactivate.txt
if ! grep -q '"success": true' /tmp/s06-copy-deactivate.txt; then
  echo "Concurrent deactivation did not commit while Copy waited on Candidate gate" >&2
  cat /tmp/s06-copy-deactivate.txt >&2
  exit 1
fi

set +e
wait "$holder_a_pid"; holder_a_status=$?
wait "$copy_a_pid"; copy_a_status=$?
set -e

if [[ $holder_a_status -ne 0 || $copy_a_status -ne 0 ]]; then
  echo "Copy/deactivation staged race process failed unexpectedly" >&2
  cat /tmp/s06-copy-holder-a.txt /tmp/s06-copy-a.txt /tmp/s06-copy-deactivate.txt >&2 || true
  exit 1
fi

grep -q '"success": false' /tmp/s06-copy-a.txt
grep -q 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED' /tmp/s06-copy-a.txt
psql_exec -qAt -c "select (not is_active)::text from public.app_users where app_user_id='$deactivate_user_id'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select private.is_structurally_empty_default_round('$target_a_r1_id'::uuid)::text;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select count(*) from public.interview_participants where interview_id='$target_a_r1_id'::uuid;" | tr -d '\r' | grep -qx '0'
psql_exec -qAt -c "select count(*) from public.interviews where application_id='$application_a_target_id'::uuid and copied_from_interview_id is not null;" | tr -d '\r' | grep -qx '0'

# ---------------------------------------------------------------------------
# B. Unscheduled same-Application Copy allocates Round 2. A test-only AFTER
# INSERT gate pauses it after the first Interview write. With the repair, Copy
# already owns sorted participant P + actor R User rows. Independent scheduling
# therefore waits on P; releasing the test gate cannot form R -> P / P -> R.
# Both public commands must complete successfully without deadlock.
# ---------------------------------------------------------------------------
psql_exec <<'SQL'
create or replace function private.s06_copy_concurrency_gate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('s06.copy_gate_enabled', true) = 'on' then
    perform pg_advisory_xact_lock(
      hashtextextended('s06-copy-test-gate:' || new.application_id::text, 0)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists s06_copy_concurrency_gate on public.interviews;
create trigger s06_copy_concurrency_gate
after insert on public.interviews
for each row execute function private.s06_copy_concurrency_gate();
SQL

copy_b_app_name="s06-copy-unscheduled-${suffix}"
schedule_b_app_name="s06-schedule-crossing-${suffix}"
holder_b_app_name="s06-copy-insert-holder-${suffix}"

source_b_version="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$source_b_r1_id'::uuid;" | tr -d '\r')"
copy_b_app_version="$(psql_exec -qAt -c "select version_no from public.applications where application_id='$application_b_copy_id'::uuid;" | tr -d '\r')"
schedule_b_version="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$schedule_b_r1_id'::uuid;" | tr -d '\r')"

holder_b_sql="set application_name='$holder_b_app_name'; begin; select pg_advisory_xact_lock(hashtextextended('s06-copy-test-gate:$application_b_copy_id',0)); select pg_sleep(4); commit;"
copy_b_sql="set application_name='$copy_b_app_name'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select set_config('s06.copy_gate_enabled','on',true); select public.copy_interview_schedule('$source_b_r1_id'::uuid,'$application_b_copy_id'::uuid,$source_b_version,$copy_b_app_version,'$source_b_r1_id'::uuid,$source_b_version,null,null,null,null,null,'unscheduled copy crossing',array['$participant_id'::uuid],'$copy_b_key'::uuid); commit;"
schedule_b_sql="set application_name='$schedule_b_app_name'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth_id')::text,true); select public.save_interview_schedule('$schedule_b_r1_id'::uuid,'2042-01-11 09:00+07'::timestamptz,'2042-01-11 10:00+07'::timestamptz,'$format_id'::uuid,null,null,null,'scheduled crossing',${schedule_b_version},'$(new_uuid)'::uuid); commit;"

run_sql_file "$holder_b_sql" /tmp/s06-copy-holder-b.txt & holder_b_pid=$!
sleep 0.2
run_sql_file "$copy_b_sql" /tmp/s06-copy-b.txt & copy_b_pid=$!
wait_for_lock_wait "$copy_b_app_name"

run_sql_file "$schedule_b_sql" /tmp/s06-schedule-b.txt & schedule_b_pid=$!
wait_for_lock_wait "$schedule_b_app_name"

set +e
wait "$holder_b_pid"; holder_b_status=$?
wait "$copy_b_pid"; copy_b_status=$?
wait "$schedule_b_pid"; schedule_b_status=$?
set -e

if [[ $holder_b_status -ne 0 || $copy_b_status -ne 0 || $schedule_b_status -ne 0 ]]; then
  echo "Unscheduled Copy/schedule crossing did not complete cleanly" >&2
  cat /tmp/s06-copy-holder-b.txt /tmp/s06-copy-b.txt /tmp/s06-schedule-b.txt >&2 || true
  exit 1
fi

if grep -qi 'deadlock detected' /tmp/s06-copy-b.txt /tmp/s06-schedule-b.txt; then
  echo "Deadlock detected in repaired Copy/schedule crossing" >&2
  cat /tmp/s06-copy-b.txt /tmp/s06-schedule-b.txt >&2
  exit 1
fi

grep -q '"success": true' /tmp/s06-copy-b.txt
grep -q '"success": true' /tmp/s06-schedule-b.txt

copy_b_round2_id="$(psql_exec -qAt -c "select interview_id from public.interviews where application_id='$application_b_copy_id'::uuid and round_no=2;" | tr -d '\r')"
if [[ -z "$copy_b_round2_id" ]]; then
  echo "Unscheduled Copy did not allocate Round 2" >&2
  exit 1
fi

psql_exec -qAt -c "select (copied_from_interview_id='$source_b_r1_id'::uuid and start_at is null and end_at is null)::text from public.interviews where interview_id='$copy_b_round2_id'::uuid;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select count(*) from public.interview_participants where interview_id='$copy_b_round2_id'::uuid and is_current=true;" | tr -d '\r' | grep -qx '1'
psql_exec -qAt -c "select (app_user_id='$participant_id'::uuid and participant_order=1)::text from public.interview_participants where interview_id='$copy_b_round2_id'::uuid and is_current=true;" | tr -d '\r' | grep -qx 'true'
psql_exec -qAt -c "select (start_at='2042-01-11 09:00+07'::timestamptz and end_at='2042-01-11 10:00+07'::timestamptz)::text from public.interviews where interview_id='$schedule_b_r1_id'::uuid;" | tr -d '\r' | grep -qx 'true'

echo "SLICE-06 Copy/User concurrency composition assertions passed with fixture $suffix"
