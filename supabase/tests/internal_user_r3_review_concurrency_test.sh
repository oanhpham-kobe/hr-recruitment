#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_eiu-recruitment-dev"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
unit1="$(new_uuid)"; unit2="$(new_uuid)"; group_id="$(new_uuid)"; pos1="$(new_uuid)"; pos2="$(new_uuid)"; format_id="$(new_uuid)"
root_id="$(new_uuid)"; root_auth="$(new_uuid)"; target_id="$(new_uuid)"; target_auth="$(new_uuid)"; dormant_id="$(new_uuid)"
candidate_id="$(new_uuid)"; candidate_auth="$(new_uuid)"; submission_id="$(new_uuid)"; application_id="$(new_uuid)"
int_cancel="$(new_uuid)"; int_unsched="$(new_uuid)"; int_add="$(new_uuid)"; int_readd="$(new_uuid)"
part_cancel="$(new_uuid)"; part_unsched="$(new_uuid)"; historical_part="$(new_uuid)"
bind_user="$(new_uuid)"; bind_auth="$(new_uuid)"; bind_email="bind_r3_${suffix}@eiu.edu.vn"

psql_exec() { docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
run_sql() { local sql="$1" out="$2"; printf '%s ' "$sql" | docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >"$out" 2>&1; }

# Preserve the singleton-Root production invariant in cumulative integration.
# A clean producer database still gets this script's original synthetic Root;
# when an earlier regression already established the protected Root, reuse its
# bound actor identity and never include it in this script's cleanup set.
root_owned=true
root_record="$(psql_exec -qAt -F '|' -c "select app_user_id::text, coalesce(auth_user_id::text,'') from public.app_users where is_root_admin=true order by app_user_id" | tr -d '\r')"
root_count="$(printf '%s\n' "$root_record" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$root_count" -gt 1 ]]; then
  echo "R3 concurrency fixture requires at most one pre-existing Root; found $root_count" >&2
  exit 1
fi
if [[ "$root_count" -eq 1 ]]; then
  IFS='|' read -r root_id root_auth <<< "$root_record"
  if [[ -z "$root_id" || -z "$root_auth" ]]; then
    echo "R3 concurrency fixture cannot reuse an unbound pre-existing Root" >&2
    exit 1
  fi
  root_owned=false
fi

root_values=""
root_cleanup_sql=""
if [[ "$root_owned" == true ]]; then
  root_values="('$root_id'::uuid,'$root_auth'::uuid,'root_r3_${suffix}@eiu.edu.vn','R3 Root','$unit1'::uuid,true,true),"
  root_cleanup_sql="
delete from public.app_user_permissions where app_user_id='$root_id'::uuid;
delete from public.app_user_roles where app_user_id='$root_id'::uuid;
delete from public.app_users where app_user_id='$root_id'::uuid;"
fi

cleanup() {
  psql_exec >/dev/null 2>&1 <<SQL || true
begin;
delete from public.interview_reports where interview_participant_id in ('$part_cancel'::uuid,'$part_unsched'::uuid,'$historical_part'::uuid);
delete from public.interview_participants where interview_id in ('$int_cancel'::uuid,'$int_unsched'::uuid,'$int_add'::uuid,'$int_readd'::uuid);
delete from public.interviews where interview_id in ('$int_cancel'::uuid,'$int_unsched'::uuid,'$int_add'::uuid,'$int_readd'::uuid);
delete from public.applications where submission_id='$submission_id'::uuid;
delete from public.submissions where submission_id='$submission_id'::uuid;
delete from public.candidates where candidate_id='$candidate_id'::uuid;
delete from public.app_user_permissions where app_user_id in ('$target_id'::uuid,'$dormant_id'::uuid,'$bind_user'::uuid);
delete from public.app_user_roles where app_user_id in ('$target_id'::uuid,'$dormant_id'::uuid,'$bind_user'::uuid);
delete from public.app_users where app_user_id in ('$target_id'::uuid,'$dormant_id'::uuid,'$bind_user'::uuid);
$root_cleanup_sql
delete from auth.identities where user_id='$bind_auth'::uuid;
delete from auth.users where id='$bind_auth'::uuid;
delete from public.positions where position_id in ('$pos1'::uuid,'$pos2'::uuid);
delete from public.interview_formats where interview_format_id='$format_id'::uuid;
delete from public.position_groups where position_group_id='$group_id'::uuid;
delete from public.organizational_units where unit_id in ('$unit1'::uuid,'$unit2'::uuid);
commit;
SQL
}
trap cleanup EXIT

psql_exec <<SQL
insert into public.position_groups(position_group_id,name_vi,code,is_active) values('$group_id'::uuid,'R3 group','R3G_${suffix}',true);
insert into public.organizational_units(unit_id,name_vi,code,is_active) values
 ('$unit1'::uuid,'R3 unit 1','R3U1_${suffix}',true),('$unit2'::uuid,'R3 unit 2','R3U2_${suffix}',true);
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi,is_active) values
 ('$pos1'::uuid,'$unit1'::uuid,'$group_id'::uuid,'R3P1_${suffix}','R3 pos 1',true),
 ('$pos2'::uuid,'$unit2'::uuid,'$group_id'::uuid,'R3P2_${suffix}','R3 pos 2',true);
insert into public.interview_formats(interview_format_id,code,name_vi,requires_room,requires_meeting_link,is_active)
 values('$format_id'::uuid,'R3F_${suffix}','R3 format',false,false,true);
insert into public.app_users(app_user_id,auth_user_id,email,full_name,unit_id,is_active,is_root_admin) values
 $root_values
 ('$target_id'::uuid,'$target_auth'::uuid,'target_r3_${suffix}@eiu.edu.vn','R3 Target','$unit1'::uuid,true,false),
 ('$dormant_id'::uuid,null,'dormant_r3_${suffix}@eiu.edu.vn','R3 Dormant','$unit1'::uuid,true,false),
 ('$bind_user'::uuid,null,'$bind_email','R3 Bind','$unit1'::uuid,true,false);
insert into public.app_user_roles(app_user_id,role_code) values('$target_id'::uuid,'HR');
insert into public.app_user_permissions(app_user_id,permission_code)
select '$target_id'::uuid,p.permission_code from public.permissions p
where p.permission_code in ('interviews.view','interviews.status','interviews.manage','interviews.participants');
insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active)
 values('$candidate_id'::uuid,'$candidate_auth'::uuid,'candidate_r3_${suffix}@example.test','R3 Candidate',true);
insert into public.submissions(submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,version_no)
 values('$submission_id'::uuid,'$candidate_id'::uuid,'READ','R3 Candidate','1990-01-01','MALE','Address','0900000000','candidate_r3_${suffix}@example.test',1);
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active)
 values('$application_id'::uuid,'$submission_id'::uuid,'$unit1'::uuid,'$pos1'::uuid,'$root_id'::uuid,true);
insert into public.interviews(interview_id,application_id,round_no,start_at,end_at,interview_format_id,schedule_status_code,report_status_code,is_active) values
 ('$int_cancel'::uuid,'$application_id'::uuid,1,clock_timestamp()+interval '2 days',clock_timestamp()+interval '2 days 1 hour','$format_id'::uuid,'CANCELLED','FOLLOW_UP',true),
 ('$int_unsched'::uuid,'$application_id'::uuid,2,null,null,null,'AVAILABLE','FOLLOW_UP',true),
 ('$int_add'::uuid,'$application_id'::uuid,3,clock_timestamp()+interval '3 days',clock_timestamp()+interval '3 days 1 hour','$format_id'::uuid,'CANCELLED','FOLLOW_UP',true),
 ('$int_readd'::uuid,'$application_id'::uuid,4,null,null,null,'AVAILABLE','FOLLOW_UP',true);
insert into public.interview_participants(interview_participant_id,interview_id,app_user_id,participant_order,snapshot_name,snapshot_email,is_current,removed_at) values
 ('$part_cancel'::uuid,'$int_cancel'::uuid,'$target_id'::uuid,1,'R3 Target','target_r3_${suffix}@eiu.edu.vn',true,null),
 ('$part_unsched'::uuid,'$int_unsched'::uuid,'$target_id'::uuid,1,'R3 Target','target_r3_${suffix}@eiu.edu.vn',true,null),
 ('$historical_part'::uuid,'$int_readd'::uuid,'$dormant_id'::uuid,1,'R3 Dormant','dormant_r3_${suffix}@eiu.edu.vn',false,clock_timestamp());
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
 values('$bind_auth'::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','$bind_email','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp());
insert into auth.identities(provider_id,user_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
 values('google-r3-${suffix}','$bind_auth'::uuid,jsonb_build_object('sub','google-r3-${suffix}','email','$bind_email'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp());
SQL

root_prefix="set local role authenticated; select set_config('request.jwt.claim.sub','$root_auth',true);"
target_prefix="set local role authenticated; select set_config('request.jwt.claim.sub','$target_auth',true);"

# 1A. Non-null Unit: public lifecycle queued before bulk owner assignment.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target_id'::uuid")"; k1="$(new_uuid)"; bk="$(new_uuid)"
block="begin; select 1 from public.app_users where app_user_id='$target_id'::uuid for update; select pg_sleep(3); commit;"
life="begin; set local statement_timeout='10s'; $root_prefix select public.set_internal_user_active('$target_id'::uuid,false,$ver,'$k1'::uuid); commit;"
bulk="begin; set local statement_timeout='10s'; $root_prefix select public.bulk_create_or_update_applications(array['$submission_id'::uuid],'$unit1'::uuid,null::uuid,'$pos1'::uuid,'$target_id'::uuid,'$bk'::uuid); commit;"
run_sql "$block" /tmp/r3-u-block & p0=$!; sleep .25; run_sql "$life" /tmp/r3-u-life & p1=$!; sleep .25; run_sql "$bulk" /tmp/r3-u-bulk & p2=$!; set +e; wait $p0; s0=$?; wait $p1; s1=$?; wait $p2; s2=$?; set -e
[[ $s0 -eq 0 && $s1 -eq 0 && $s2 -eq 0 ]] || { cat /tmp/r3-u-* >&2; exit 1; }
! grep -qi 'deadlock detected' /tmp/r3-u-life /tmp/r3-u-bulk
grep -q '"success": true' /tmp/r3-u-life
grep -q 'NOT_FOUND' /tmp/r3-u-bulk
psql_exec -qAt -c "update public.app_users set is_active=true where app_user_id='$target_id'::uuid"

# 1B. Non-null Unit: HR-role removal queued before bulk owner assignment.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target_id'::uuid")"; k2="$(new_uuid)"; bk2="$(new_uuid)"
remove="begin; set local statement_timeout='10s'; $root_prefix select public.remove_hr_role('$target_id'::uuid,$ver,'$k2'::uuid); commit;"
bulk2="begin; set local statement_timeout='10s'; $root_prefix select public.bulk_create_or_update_applications(array['$submission_id'::uuid],'$unit1'::uuid,null::uuid,'$pos1'::uuid,'$target_id'::uuid,'$bk2'::uuid); commit;"
run_sql "$block" /tmp/r3-r-block & p0=$!; sleep .25; run_sql "$remove" /tmp/r3-r-remove & p1=$!; sleep .25; run_sql "$bulk2" /tmp/r3-r-bulk & p2=$!; set +e; wait $p0; s0=$?; wait $p1; s1=$?; wait $p2; s2=$?; set -e
[[ $s0 -eq 0 && $s1 -eq 0 && $s2 -eq 0 ]] || { cat /tmp/r3-r-* >&2; exit 1; }
! grep -qi 'deadlock detected' /tmp/r3-r-remove /tmp/r3-r-bulk
grep -q '"success": true' /tmp/r3-r-remove
# The complete actor/target lock set makes the command's post-lock owner
# eligibility recheck observe the removed HR role before any Application write.
# Assert that exact public rejection, not a late trigger exception or any error.
grep -q '"success": false' /tmp/r3-r-bulk
grep -q '"error_code": "NOT_FOUND"' /tmp/r3-r-bulk
grep -q 'Active HR owner not found' /tmp/r3-r-bulk
psql_exec -qAt -c "select count(*) from public.app_user_roles where app_user_id='$target_id'::uuid and role_code='HR'" | grep -qx 0
psql_exec -qAt -c "select (hr_owner_id='$root_id'::uuid)::text from public.applications where application_id='$application_id'::uuid" | grep -qx true
psql_exec -qAt -c "select count(*) from public.security_audit_log where request_id='$bk2'::uuid" | grep -qx 0
psql_exec -qAt -c "insert into public.app_user_roles(app_user_id,role_code) values('$target_id'::uuid,'HR') on conflict do nothing"
psql_exec -qAt -c "insert into public.app_user_permissions(app_user_id,permission_code) select '$target_id'::uuid,p.permission_code from public.permissions p where p.permission_code in ('interviews.view','interviews.status','interviews.manage','interviews.participants') on conflict do nothing"

# 1C. Directory Unit selection locks Unit before target User; bulk shares Unit->User.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target_id'::uuid")"; dk="$(new_uuid)"; bk3="$(new_uuid)"
dir="begin; set local statement_timeout='10s'; $root_prefix select public.update_internal_user_directory('$target_id'::uuid,jsonb_build_object('unit_id','$unit2'),$ver,'$dk'::uuid); commit;"
bulk3="begin; set local statement_timeout='10s'; $root_prefix select public.bulk_create_or_update_applications(array['$submission_id'::uuid],'$unit2'::uuid,null::uuid,'$pos2'::uuid,'$target_id'::uuid,'$bk3'::uuid); commit;"
run_sql "$block" /tmp/r3-d-block & p0=$!; sleep .25; run_sql "$dir" /tmp/r3-d-dir & p1=$!; sleep .25; run_sql "$bulk3" /tmp/r3-d-bulk & p2=$!; set +e; wait $p0; s0=$?; wait $p1; s1=$?; wait $p2; s2=$?; set -e
[[ $s0 -eq 0 && $s1 -eq 0 && $s2 -eq 0 ]] || { cat /tmp/r3-d-* >&2; exit 1; }
! grep -qi 'deadlock detected' /tmp/r3-d-dir /tmp/r3-d-bulk
grep -q '"success": true' /tmp/r3-d-dir
grep -q '"success": true' /tmp/r3-d-bulk
psql_exec -qAt -c "update public.applications set unit_id='$unit1'::uuid,position_id='$pos1'::uuid,hr_owner_id='$root_id'::uuid where application_id='$application_id'::uuid"
# Scenario 1C may create a second Application for the same Submission because the
# bulk contract keys an existing Application by Unit/team/Position. Interview
# races must not be pre-empted by the independent Active-Application-owner guard.
psql_exec -qAt -c "update public.applications set hr_owner_id='$root_id'::uuid where hr_owner_id='$target_id'::uuid and is_active=true"
psql_exec -qAt -c "select count(*) from public.applications where hr_owner_id='$target_id'::uuid and is_active=true" | grep -qx 0

# 2A. HR is current participant: uncancel vs Root lifecycle must row-lock before advisory.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target_id'::uuid")"; ik="$(new_uuid)"; iv="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$int_cancel'::uuid")"
life2="begin; set local statement_timeout='10s'; $root_prefix select public.set_internal_user_active('$target_id'::uuid,false,$ver,'$ik'::uuid); commit;"
uncancel="begin; set local statement_timeout='10s'; $target_prefix select public.change_interview_schedule_status('$int_cancel'::uuid,'AVAILABLE',$iv); commit;"
run_sql "$block" /tmp/r3-i-block & p0=$!; sleep .25; run_sql "$life2" /tmp/r3-i-life & p1=$!; sleep .25; set +e; run_sql "$uncancel" /tmp/r3-i-uncancel & p2=$!; wait $p0; s0=$?; wait $p1; s1=$?; wait $p2; s2=$?; set -e
[[ $s0 -eq 0 && $s1 -eq 0 && $s2 -ne 0 ]] || { cat /tmp/r3-i-* >&2; exit 1; }
! grep -qi 'deadlock detected' /tmp/r3-i-life /tmp/r3-i-uncancel
grep -q 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED' /tmp/r3-i-uncancel
psql_exec -qAt -c "update public.app_users set is_active=true where app_user_id='$target_id'::uuid"

# 2B. Same actor/participant scheduling an unscheduled Interview vs lifecycle.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target_id'::uuid")"; ik2="$(new_uuid)"; iv2="$(psql_exec -qAt -c "select version_no from public.interviews where interview_id='$int_unsched'::uuid")"; sk="$(new_uuid)"
life3="begin; set local statement_timeout='10s'; $root_prefix select public.set_internal_user_active('$target_id'::uuid,false,$ver,'$ik2'::uuid); commit;"
schedule="begin; set local statement_timeout='10s'; $target_prefix select public.save_interview_schedule('$int_unsched'::uuid,clock_timestamp()+interval '4 days',clock_timestamp()+interval '4 days 1 hour','$format_id'::uuid,null::uuid,null::text,null::text,null::text,$iv2,'$sk'::uuid); commit;"
run_sql "$block" /tmp/r3-s-block & p0=$!; sleep .25; run_sql "$life3" /tmp/r3-s-life & p1=$!; sleep .25; set +e; run_sql "$schedule" /tmp/r3-s-schedule & p2=$!; wait $p0; s0=$?; wait $p1; s1=$?; wait $p2; s2=$?; set -e
[[ $s0 -eq 0 && $s1 -eq 0 && $s2 -ne 0 ]] || { cat /tmp/r3-s-* >&2; exit 1; }
! grep -qi 'deadlock detected' /tmp/r3-s-life /tmp/r3-s-schedule
grep -q 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED' /tmp/r3-s-schedule
psql_exec -qAt -c "update public.app_users set is_active=true where app_user_id='$target_id'::uuid"

# 3A. Deactivation owns dormant target row first; CANCELLED add must wait/revalidate and fail.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$dormant_id'::uuid")"; dk1="$(new_uuid)"; ak="$(new_uuid)"
deact_hold="begin; set local statement_timeout='10s'; $root_prefix select public.set_internal_user_active('$dormant_id'::uuid,false,$ver,'$dk1'::uuid); select pg_sleep(2); commit;"
add="begin; set local statement_timeout='10s'; $root_prefix select public.add_interview_participant('$int_add'::uuid,'$dormant_id'::uuid,'$ak'::uuid); commit;"
run_sql "$deact_hold" /tmp/r3-a-deact & p1=$!; sleep .25; set +e; run_sql "$add" /tmp/r3-a-add & p2=$!; wait $p1; s1=$?; wait $p2; s2=$?; set -e
[[ $s1 -eq 0 && $s2 -ne 0 ]] || { cat /tmp/r3-a-* >&2; exit 1; }
grep -q 'USER_INACTIVE_NOT_SELECTABLE' /tmp/r3-a-add
psql_exec -qAt -c "select count(*) from public.interview_participants where interview_id='$int_add'::uuid and app_user_id='$dormant_id'::uuid and is_current" | grep -qx 0
psql_exec -qAt -c "update public.app_users set is_active=true where app_user_id='$dormant_id'::uuid"

# 3B. Deactivation owns row first; unscheduled re-add/restoration must wait/revalidate and fail.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$dormant_id'::uuid")"; dk2="$(new_uuid)"; rk="$(new_uuid)"
deact_hold2="begin; set local statement_timeout='10s'; $root_prefix select public.set_internal_user_active('$dormant_id'::uuid,false,$ver,'$dk2'::uuid); select pg_sleep(2); commit;"
readd="begin; set local statement_timeout='10s'; $root_prefix select public.readd_interview_participant('$historical_part'::uuid,'RESTORE_OLD_REPORT','$rk'::uuid); commit;"
run_sql "$deact_hold2" /tmp/r3-ra-deact & p1=$!; sleep .25; set +e; run_sql "$readd" /tmp/r3-ra-readd & p2=$!; wait $p1; s1=$?; wait $p2; s2=$?; set -e
[[ $s1 -eq 0 && $s2 -ne 0 ]] || { cat /tmp/r3-ra-* >&2; exit 1; }
grep -q 'USER_INACTIVE_NOT_SELECTABLE' /tmp/r3-ra-readd
psql_exec -qAt -c "select is_current::text from public.interview_participants where interview_participant_id='$historical_part'::uuid" | grep -qx false

# 4. Trusted Google evidence changes while first-bind waits on target row.
bind_block="begin; select 1 from public.app_users where app_user_id='$bind_user'::uuid for update; select pg_sleep(3); commit;"
bind="begin; set local statement_timeout='10s'; set local role authenticated; select set_config('request.jwt.claim.sub','$bind_auth',true); select public.provision_internal_identity_on_first_google_login(); commit;"
run_sql "$bind_block" /tmp/r3-b-block & p0=$!; sleep .25; run_sql "$bind" /tmp/r3-b-bind & p1=$!; sleep .5
psql_exec -qAt -c "update auth.users set email_confirmed_at=null where id='$bind_auth'::uuid"
set +e; wait $p0; s0=$?; wait $p1; s1=$?; set -e
[[ $s0 -eq 0 && $s1 -eq 0 ]] || { cat /tmp/r3-b-* >&2; exit 1; }
grep -q 'FORBIDDEN' /tmp/r3-b-bind
psql_exec -qAt -c "select (auth_user_id is null)::text from public.app_users where app_user_id='$bind_user'::uuid" | grep -qx true
psql_exec -qAt -c "select count(*) from public.security_audit_log where entity_id='$bind_user'::uuid and action_code='INTERNAL_IDENTITY_FIRST_BIND'" | grep -qx 0

echo "TASK-S06-002 R3 lock/evidence concurrency regressions PASS ($suffix)"
