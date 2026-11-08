#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_eiu-recruitment-dev"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
unit_id="$(new_uuid)"
group_id="$(new_uuid)"
position_id="$(new_uuid)"
format_id="$(new_uuid)"
owner_id="$(new_uuid)"
target_id="$(new_uuid)"
candidate_id="$(new_uuid)"
candidate_auth_id="$(new_uuid)"
submission_id="$(new_uuid)"
application_id="$(new_uuid)"
interview_id="$(new_uuid)"
participant_id="$(new_uuid)"

psql_exec() {
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

cleanup() {
  psql_exec >/dev/null 2>&1 <<SQL || true
begin;
delete from public.interview_participants where interview_id='$interview_id'::uuid;
delete from public.interviews where interview_id='$interview_id'::uuid;
delete from public.applications where application_id='$application_id'::uuid;
delete from public.submissions where submission_id='$submission_id'::uuid;
delete from public.candidates where candidate_id='$candidate_id'::uuid;
delete from public.app_user_permissions where app_user_id in ('$owner_id'::uuid,'$target_id'::uuid);
delete from public.app_user_roles where app_user_id in ('$owner_id'::uuid,'$target_id'::uuid);
delete from public.app_users where app_user_id in ('$owner_id'::uuid,'$target_id'::uuid);
delete from public.positions where position_id='$position_id'::uuid;
delete from public.interview_formats where interview_format_id='$format_id'::uuid;
delete from public.position_groups where position_group_id='$group_id'::uuid;
delete from public.organizational_units where unit_id='$unit_id'::uuid;
commit;
SQL
}
trap cleanup EXIT

psql_exec <<SQL
insert into public.position_groups(position_group_id,name_vi,code,is_active)
values('$group_id'::uuid,'S06-002 concurrency group','S06002_CG_${suffix}',true);
insert into public.organizational_units(unit_id,name_vi,code,is_active)
values('$unit_id'::uuid,'S06-002 concurrency unit','S06002_CU_${suffix}',true);
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi,is_active)
values('$position_id'::uuid,'$unit_id'::uuid,'$group_id'::uuid,'S06002_CP_${suffix}','S06-002 concurrency position',true);
insert into public.interview_formats(interview_format_id,code,name_vi,requires_room,requires_meeting_link,is_active)
values('$format_id'::uuid,'S06002_CF_${suffix}','S06-002 concurrency format',false,false,true);

insert into public.app_users(app_user_id,email,full_name,is_active,is_root_admin)
values
  ('$owner_id'::uuid,'owner_${suffix}@eiu.edu.vn','S06-002 Owner',true,false),
  ('$target_id'::uuid,'target_${suffix}@eiu.edu.vn','S06-002 Target',true,false);
insert into public.app_user_roles(app_user_id,role_code)
values('$owner_id'::uuid,'HR'),('$target_id'::uuid,'HR');

insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active)
values('$candidate_id'::uuid,'$candidate_auth_id'::uuid,'candidate_${suffix}@example.test','Concurrency Candidate',true);
insert into public.submissions(
  submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,
  current_address,phone,email_snapshot,version_no
) values(
  '$submission_id'::uuid,'$candidate_id'::uuid,'READ','Concurrency Candidate','1990-01-01','MALE',
  'Address','0900000000','candidate_${suffix}@example.test',1
);
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active)
values('$application_id'::uuid,'$submission_id'::uuid,'$unit_id'::uuid,'$position_id'::uuid,'$owner_id'::uuid,true);
insert into public.interviews(
  interview_id,application_id,round_no,start_at,end_at,interview_format_id,
  schedule_status_code,report_status_code,is_active
) values(
  '$interview_id'::uuid,'$application_id'::uuid,1,
  clock_timestamp()+interval '2 days',clock_timestamp()+interval '2 days 1 hour','$format_id'::uuid,
  'AVAILABLE','FOLLOW_UP',true
);
SQL

run_sql_file() {
  local sql="$1"
  local out="$2"
  printf '%s ' "$sql" | docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >"$out" 2>&1
}

# ---------------------------------------------------------------------------
# 1. Deactivation wins the user gate; concurrent owner assignment must recheck
#    after waiting and fail instead of committing an inactive Active-App owner.
# ---------------------------------------------------------------------------
deactivate_hold="begin; update public.app_users set is_active=false where app_user_id='$target_id'::uuid; select pg_sleep(1.5); commit;"
owner_assign="begin; update public.applications set hr_owner_id='$target_id'::uuid where application_id='$application_id'::uuid; commit;"

run_sql_file "$deactivate_hold" /tmp/s06002-deactivate-owner-a.txt & pid_a=$!
sleep 0.25
set +e
run_sql_file "$owner_assign" /tmp/s06002-owner-b.txt & pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

if [[ $status_a -ne 0 || $status_b -eq 0 ]]; then
  echo "owner race (deactivation-first) did not serialize as expected" >&2
  cat /tmp/s06002-deactivate-owner-a.txt /tmp/s06002-owner-b.txt >&2 || true
  exit 1
fi
grep -q 'APPLICATION_OWNER_NOT_ELIGIBLE' /tmp/s06002-owner-b.txt
psql_exec -qAt -c "select (not is_active)::text from public.app_users where app_user_id='$target_id'::uuid;" | grep -qx 'true'
psql_exec -qAt -c "select (hr_owner_id='$owner_id'::uuid)::text from public.applications where application_id='$application_id'::uuid;" | grep -qx 'true'

# Restore eligible target.
psql_exec -qAt -c "update public.app_users set is_active=true where app_user_id='$target_id'::uuid;"

# ---------------------------------------------------------------------------
# 2. Owner assignment wins the gate; concurrent deactivation must recheck the
#    committed Active Application and fail with reassignment-required semantics.
# ---------------------------------------------------------------------------
owner_hold="begin; update public.applications set hr_owner_id='$target_id'::uuid where application_id='$application_id'::uuid; select pg_sleep(1.5); commit;"
deactivate="begin; update public.app_users set is_active=false where app_user_id='$target_id'::uuid; commit;"

run_sql_file "$owner_hold" /tmp/s06002-owner-a2.txt & pid_a=$!
sleep 0.25
set +e
run_sql_file "$deactivate" /tmp/s06002-deactivate-b2.txt & pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

if [[ $status_a -ne 0 || $status_b -eq 0 ]]; then
  echo "owner race (writer-first) did not serialize as expected" >&2
  cat /tmp/s06002-owner-a2.txt /tmp/s06002-deactivate-b2.txt >&2 || true
  exit 1
fi
grep -q 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED' /tmp/s06002-deactivate-b2.txt
psql_exec -qAt -c "select is_active::text from public.app_users where app_user_id='$target_id'::uuid;" | grep -qx 'true'
psql_exec -qAt -c "select (hr_owner_id='$target_id'::uuid)::text from public.applications where application_id='$application_id'::uuid;" | grep -qx 'true'

# Restore application owner before participant race.
psql_exec -qAt -c "update public.applications set hr_owner_id='$owner_id'::uuid where application_id='$application_id'::uuid;"

participant_insert="begin; insert into public.interview_participants(   interview_participant_id,interview_id,app_user_id,participant_order,   snapshot_name,snapshot_job_title,snapshot_email,is_current ) values(   '$participant_id'::uuid,'$interview_id'::uuid,'$target_id'::uuid,1,   'S06-002 Target','Interviewer','target_${suffix}@eiu.edu.vn',true ); commit;"

# ---------------------------------------------------------------------------
# 3. Deactivation wins; concurrent current-participant insert sees the old MVCC
#    user row initially, then the statement-level shared gate forces a fresh
#    eligibility recheck and rejects it after deactivation commits.
# ---------------------------------------------------------------------------
run_sql_file "$deactivate_hold" /tmp/s06002-deactivate-part-a.txt & pid_a=$!
sleep 0.25
set +e
run_sql_file "$participant_insert" /tmp/s06002-participant-b.txt & pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

if [[ $status_a -ne 0 || $status_b -eq 0 ]]; then
  echo "participant race (deactivation-first) did not serialize as expected" >&2
  cat /tmp/s06002-deactivate-part-a.txt /tmp/s06002-participant-b.txt >&2 || true
  exit 1
fi
grep -q 'USER_INACTIVE_NOT_SELECTABLE' /tmp/s06002-participant-b.txt
psql_exec -qAt -c "select count(*) from public.interview_participants where interview_participant_id='$participant_id'::uuid;" | grep -qx '0'
psql_exec -qAt -c "update public.app_users set is_active=true where app_user_id='$target_id'::uuid;"

# ---------------------------------------------------------------------------
# 4. Participant writer wins; deactivation waits and then fails because the
#    committed participant is current on a non-elapsed resource-blocking round.
# ---------------------------------------------------------------------------
participant_hold="begin; insert into public.interview_participants(   interview_participant_id,interview_id,app_user_id,participant_order,   snapshot_name,snapshot_job_title,snapshot_email,is_current ) values(   '$participant_id'::uuid,'$interview_id'::uuid,'$target_id'::uuid,1,   'S06-002 Target','Interviewer','target_${suffix}@eiu.edu.vn',true ); select pg_sleep(1.5); commit;"

run_sql_file "$participant_hold" /tmp/s06002-participant-a2.txt & pid_a=$!
sleep 0.25
set +e
run_sql_file "$deactivate" /tmp/s06002-deactivate-b3.txt & pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

if [[ $status_a -ne 0 || $status_b -eq 0 ]]; then
  echo "participant race (writer-first) did not serialize as expected" >&2
  cat /tmp/s06002-participant-a2.txt /tmp/s06002-deactivate-b3.txt >&2 || true
  exit 1
fi
grep -q 'FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED' /tmp/s06002-deactivate-b3.txt
psql_exec -qAt -c "select is_active::text from public.app_users where app_user_id='$target_id'::uuid;" | grep -qx 'true'
psql_exec -qAt -c "select count(*) from public.interview_participants where interview_participant_id='$participant_id'::uuid and is_current=true;" | grep -qx '1'

bash supabase/tests/internal_user_r2_command_concurrency_test.sh
bash supabase/tests/internal_user_r3_review_concurrency_test.sh
echo "TASK-S06-002 Internal User owner/participant concurrency assertions passed with fresh fixture $suffix"

# Actor/target audit lock composition, deterministic UUID orders and auth recheck.
bash supabase/tests/internal_user_actor_lock_concurrency_test.sh
