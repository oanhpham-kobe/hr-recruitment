#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_eiu-recruitment-dev"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
unit_id="$(new_uuid)"
group_id="$(new_uuid)"
position_id="$(new_uuid)"
root_id="$(new_uuid)"
root_auth_id="$(new_uuid)"
target_id="$(new_uuid)"
identity_target_id="$(new_uuid)"
old_identity_auth_id="$(new_uuid)"
replacement_auth_id="$(new_uuid)"
candidate_id="$(new_uuid)"
candidate_auth_id="$(new_uuid)"
submission_id="$(new_uuid)"
application_id="$(new_uuid)"
identity_email="identity_race_${suffix}@eiu.edu.vn"

psql_exec() {
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}
run_sql_file() {
  local sql="$1" out="$2"
  printf '%s ' "$sql" | docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >"$out" 2>&1
}

root_owned=true
root_record="$(psql_exec -qAt -F '|' -c "select app_user_id::text, coalesce(auth_user_id::text,'') from public.app_users where is_root_admin=true order by app_user_id" | tr -d '\r')"
root_count="$(printf '%s\n' "$root_record" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$root_count" -gt 1 ]]; then
  echo "R2 concurrency fixture requires at most one pre-existing Root; found $root_count" >&2
  exit 1
fi
if [[ "$root_count" -eq 1 ]]; then
  IFS='|' read -r root_id root_auth_id <<< "$root_record"
  if [[ -z "$root_id" || -z "$root_auth_id" ]]; then
    echo "R2 concurrency fixture cannot reuse an unbound pre-existing Root" >&2
    exit 1
  fi
  root_owned=false
fi

root_values=""
root_cleanup_sql=""
if [[ "$root_owned" == true ]]; then
  root_values="('$root_id'::uuid,'$root_auth_id'::uuid,'root_r2_${suffix}@eiu.edu.vn','R2 Root',true,true),"
  root_cleanup_sql="delete from public.app_users where app_user_id='$root_id'::uuid;"
fi

cleanup() {
  psql_exec >/dev/null 2>&1 <<SQL || true
begin;
delete from public.interviews where application_id='$application_id'::uuid;
delete from public.applications where application_id='$application_id'::uuid;
delete from public.submissions where submission_id='$submission_id'::uuid;
delete from public.candidates where candidate_id='$candidate_id'::uuid;
delete from public.app_user_permissions where app_user_id in ('$target_id'::uuid,'$identity_target_id'::uuid);
delete from public.app_user_roles where app_user_id in ('$target_id'::uuid,'$identity_target_id'::uuid);
delete from public.app_users where app_user_id in ('$target_id'::uuid,'$identity_target_id'::uuid);
$root_cleanup_sql
delete from auth.identities where user_id='$replacement_auth_id'::uuid;
delete from auth.users where id='$replacement_auth_id'::uuid;
delete from public.positions where position_id='$position_id'::uuid;
delete from public.position_groups where position_group_id='$group_id'::uuid;
delete from public.organizational_units where unit_id='$unit_id'::uuid;
commit;
SQL
}
trap cleanup EXIT

psql_exec <<SQL
insert into public.position_groups(position_group_id,name_vi,code,is_active)
values('$group_id'::uuid,'R2 concurrency group','R2CG_${suffix}',true);
insert into public.organizational_units(unit_id,name_vi,code,is_active)
values('$unit_id'::uuid,'R2 concurrency unit','R2CU_${suffix}',true);
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi,is_active)
values('$position_id'::uuid,'$unit_id'::uuid,'$group_id'::uuid,'R2CP_${suffix}','R2 concurrency position',true);

insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin)
values
  $root_values
  ('$target_id'::uuid,null,'target_r2_${suffix}@eiu.edu.vn','R2 Target',true,false),
  ('$identity_target_id'::uuid,'$old_identity_auth_id'::uuid,'$identity_email','R2 Identity Target',true,false);
insert into public.app_user_roles(app_user_id,role_code)
values('$target_id'::uuid,'HR');

insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active)
values('$candidate_id'::uuid,'$candidate_auth_id'::uuid,'candidate_r2_${suffix}@example.test','R2 Candidate',true);
insert into public.submissions(
  submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,version_no
) values(
  '$submission_id'::uuid,'$candidate_id'::uuid,'READ','R2 Candidate','1990-01-01','MALE','Address','0900000000','candidate_r2_${suffix}@example.test',1
);
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active)
values('$application_id'::uuid,'$submission_id'::uuid,'$unit_id'::uuid,'$position_id'::uuid,'$root_id'::uuid,true);

insert into auth.users(
  id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values(
  '$replacement_auth_id'::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','$identity_email','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp()
);
insert into auth.identities(provider_id,user_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
values(
  'google-r2-${suffix}','$replacement_auth_id'::uuid,jsonb_build_object('sub','google-r2-${suffix}','email','$identity_email'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp()
);
SQL

target_version="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target_id'::uuid")"
lifecycle_key="$(new_uuid)"
app_key="$(new_uuid)"
blocker="begin; select 1 from public.app_users where app_user_id='$target_id'::uuid for update; select pg_sleep(3); commit;"
lifecycle="begin; set local statement_timeout='10s'; set local role authenticated; select set_config('request.jwt.claim.sub','$root_auth_id',true); select public.set_internal_user_active('$target_id'::uuid,false,$target_version,'$lifecycle_key'::uuid); commit;"
owner_write="begin; set local statement_timeout='10s'; set local role authenticated; select set_config('request.jwt.claim.sub','$root_auth_id',true); select public.create_or_update_application('$submission_id'::uuid,'$unit_id'::uuid,null::uuid,'$position_id'::uuid,'$target_id'::uuid,'$app_key'::uuid,true); commit;"

run_sql_file "$blocker" /tmp/s06002-r2-row-blocker.txt & p0=$!
sleep 0.25
run_sql_file "$lifecycle" /tmp/s06002-r2-lifecycle.txt & p1=$!
sleep 0.25
set +e
run_sql_file "$owner_write" /tmp/s06002-r2-owner-write.txt & p2=$!
wait "$p0"; s0=$?
wait "$p1"; s1=$?
wait "$p2"; s2=$?
set -e

if [[ $s0 -ne 0 || $s1 -ne 0 || $s2 -eq 0 ]]; then
  echo "R2 public owner/lifecycle race did not fail closed as expected" >&2
  cat /tmp/s06002-r2-row-blocker.txt /tmp/s06002-r2-lifecycle.txt /tmp/s06002-r2-owner-write.txt >&2 || true
  exit 1
fi
! grep -qi 'deadlock detected' /tmp/s06002-r2-lifecycle.txt /tmp/s06002-r2-owner-write.txt
grep -q '"success": true' /tmp/s06002-r2-lifecycle.txt
grep -q 'APPLICATION_OWNER_NOT_ELIGIBLE' /tmp/s06002-r2-owner-write.txt
psql_exec -qAt -c "select (not is_active)::text from public.app_users where app_user_id='$target_id'::uuid" | grep -qx true
psql_exec -qAt -c "select (hr_owner_id='$root_id'::uuid)::text from public.applications where application_id='$application_id'::uuid" | grep -qx true
psql_exec -qAt -c "update public.app_users set is_active=true where app_user_id='$target_id'::uuid"

identity_version="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$identity_target_id'::uuid")"
rebind_key="$(new_uuid)"
email_blocker="begin; select pg_advisory_xact_lock(hashtextextended('internal-email:$identity_email',0)); select pg_sleep(3); commit;"
first_bind="begin; set local statement_timeout='10s'; set local role authenticated; select set_config('request.jwt.claim.sub','$replacement_auth_id',true); select public.provision_internal_identity_on_first_google_login(); commit;"
rebind="begin; set local statement_timeout='10s'; set local role authenticated; select set_config('request.jwt.claim.sub','$root_auth_id',true); select public.change_internal_user_identity('$identity_target_id'::uuid,'$replacement_auth_id'::uuid,$identity_version,'$rebind_key'::uuid); commit;"

run_sql_file "$email_blocker" /tmp/s06002-r2-email-blocker.txt & p0=$!
sleep 0.25
run_sql_file "$first_bind" /tmp/s06002-r2-first-bind.txt & p1=$!
sleep 0.25
run_sql_file "$rebind" /tmp/s06002-r2-rebind.txt & p2=$!
set +e
wait "$p0"; s0=$?
wait "$p1"; s1=$?
wait "$p2"; s2=$?
set -e

if [[ $s0 -ne 0 || $s1 -ne 0 || $s2 -ne 0 ]]; then
  echo "R2 public identity lock-order race did not serialize cleanly" >&2
  cat /tmp/s06002-r2-email-blocker.txt /tmp/s06002-r2-first-bind.txt /tmp/s06002-r2-rebind.txt >&2 || true
  exit 1
fi
! grep -qi 'deadlock detected' /tmp/s06002-r2-first-bind.txt /tmp/s06002-r2-rebind.txt
grep -q 'IDENTITY_REBIND_FORBIDDEN' /tmp/s06002-r2-first-bind.txt
grep -q '"success": true' /tmp/s06002-r2-rebind.txt
psql_exec -qAt -c "select (auth_user_id='$replacement_auth_id'::uuid)::text from public.app_users where app_user_id='$identity_target_id'::uuid" | grep -qx true

echo "TASK-S06-002 R2 public-command lock-order concurrency regressions PASS ($suffix)"
