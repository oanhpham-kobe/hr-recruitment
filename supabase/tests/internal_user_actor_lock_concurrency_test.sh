#!/usr/bin/env bash
set -euo pipefail
container_name="${EIU_TEST_DB_CONTAINER:-supabase_db_eiu-recruitment-dev}"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
psql_exec() { docker exec -i "$container_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
run_sql() { printf '%s\n' "$1" | psql_exec >"$2" 2>&1; }
tmp="$(mktemp -d)"
cleanup() {
  # All child commands have bounded sleeps/timeouts. Reap them before cleanup
  # on failed synchronization as well as on success.
  wait || true
  rm -f -- "$tmp/block" "$tmp/life" "$tmp/bulk" "$tmp/replay" "$tmp/revoke"
  rmdir -- "$tmp"
}
trap cleanup EXIT
suffix="$(new_uuid)"
unit="$(new_uuid)"; group="$(new_uuid)"; pos="$(new_uuid)"
actor="$(new_uuid)"; actor_auth="$(new_uuid)"
root="$(psql_exec -qAt -F '|' -c "select app_user_id,auth_user_id from public.app_users where is_root_admin")"
if [[ -n "$root" ]]; then IFS='|' read -r actor actor_auth <<< "$root"; fi
[[ -n "$actor_auth" ]] || { echo 'Bound Root required' >&2; exit 1; }
# Extremes make both actor/target sort orders deterministic even in cumulative CI.
low="00000000-0000-0000-0000-${suffix:24:12}"
high="ffffffff-ffff-ffff-ffff-${suffix:24:12}"
psql_exec >/dev/null <<SQL
insert into public.organizational_units(unit_id,name_vi,code,is_active) values('$unit','Actor lock unit','AU-$suffix',true);
insert into public.position_groups(position_group_id,name_vi,code,is_active) values('$group','Actor lock group','AG-$suffix',true);
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi,is_active) values('$pos','$unit','$group','AP-$suffix','Actor lock position',true);
insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin)
select '$actor','$actor_auth','actor-$suffix@eiu.edu.vn','Actor lock Root',true,true where not exists(select 1 from public.app_users where is_root_admin);
SQL
# Fixtures are synthetic and uniquely named. Keep them for diagnostic evidence,
# like the cumulative SQL suite; no shared Root or immutable audit is deleted.
for target in "$low" "$high"; do
  candidate="$(new_uuid)"; submission="$(new_uuid)"; application="$(new_uuid)"
  key="$(new_uuid)"; bulk_key="$(new_uuid)"
  psql_exec >/dev/null <<SQL
insert into public.app_users(app_user_id,email,full_name,unit_id,is_active,is_root_admin) values('$target','target-$target@eiu.edu.vn','Actor lock target','$unit',true,false);
insert into public.app_user_roles(app_user_id,role_code) values('$target','HR');
insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active) values('$candidate','$(new_uuid)','candidate-$candidate@example.test','Actor lock Candidate',true);
insert into public.submissions(submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,version_no) values('$submission','$candidate','READ','Actor lock Candidate','1990-01-01','MALE','Address','0900000000','candidate-$candidate@example.test',1);
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active) values('$application','$submission','$unit','$pos','$actor',true);
SQL
  version="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target'")"
  prefix="set local role authenticated; select set_config('request.jwt.claim.sub','$actor_auth',true);"
  block_name="actor-block-$target"; life_name="actor-life-$target"; bulk_name="actor-bulk-$target"
  # Poll actual backend wait state before dispatching the opposing public RPC.
  # The sleep only holds a synthetic test blocker; it is not a product retry.
  run_sql "set application_name='$block_name'; begin; select 1 from public.app_users where app_user_id='$target' for update; select pg_sleep(5); commit;" "$tmp/block" & p0=$!
  wait_state() {
    local name="$1" event="$2"
    for _ in $(seq 1 100); do
      if [[ "$(psql_exec -qAt -c "select count(*) from pg_stat_activity where application_name='$name' and $event")" == 1 ]]; then return; fi
      sleep .02
    done
    echo "Missing synchronization: $name $event" >&2; cat "$tmp/"* >&2; return 1
  }
  wait_state "$block_name" "wait_event='PgSleep'"
  run_sql "set application_name='$life_name'; begin; set local statement_timeout='15s'; $prefix select public.set_internal_user_active('$target',false,$version,'$key'); commit;" "$tmp/life" & p1=$!
  wait_state "$life_name" "wait_event_type='Lock'"
  run_sql "set application_name='$bulk_name'; begin; set local statement_timeout='15s'; $prefix select public.bulk_create_or_update_applications(array['$submission'::uuid],'$unit',null,'$pos','$target','$bulk_key'); commit;" "$tmp/bulk" & p2=$!
  wait_state "$bulk_name" "wait_event_type='Lock'"
  s=0; wait "$p0" || s=1; wait "$p1" || s=1; wait "$p2" || s=1
  [[ "$s" == 0 ]] || { cat "$tmp/"* >&2; exit 1; }
  grep -q '"success": true' "$tmp/life"
  grep -q 'NOT_FOUND' "$tmp/bulk"
  # Verify committed business state, version, immutable audit, and replay through
  # the public command. A deadlock/retry or a swallowed failed write cannot pass.
  psql_exec -qAt -c "select (not is_active and version_no=$version+1)::text from public.app_users where app_user_id='$target'" | grep -qx true
  psql_exec -qAt -c "select (hr_owner_id='$actor'::uuid and version_no=1)::text from public.applications where application_id='$application'" | grep -qx true
  psql_exec -qAt -c "select count(*) from public.security_audit_log where request_id='$key' and actor_app_user_id='$actor' and entity_id='$target' and action_code='INTERNAL_USER_INACTIVATE'" | grep -qx 1
  run_sql "begin; $prefix select public.set_internal_user_active('$target',false,$version,'$key'); commit;" "$tmp/replay"
  grep -q '"success": true' "$tmp/replay"
  psql_exec -qAt -c "select count(*) from public.security_audit_log where request_id='$key'" | grep -qx 1
  echo "Actor/target lock order PASS: $actor / $target"
done
# A delegated directory manager loses permission while waiting before its own
# row is acquired. The post-lock authorization check must reject the stale actor.
manager="fffffffe-ffff-ffff-ffff-${suffix:24:12}"
manager_auth="$(new_uuid)"; target="00000001-0000-0000-0000-${suffix:24:12}"
auth_key="$(new_uuid)"; revoke_key="$(new_uuid)"
psql_exec >/dev/null <<SQL
insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin) values
('$manager','$manager_auth','manager-$suffix@eiu.edu.vn','Actor lock manager',true,false),
('$target',null,'directory-$suffix@eiu.edu.vn','Before authorization wait',true,false);
insert into public.app_user_roles(app_user_id,role_code) values('$manager','HR');
insert into public.app_user_permissions(app_user_id,permission_code) values('$manager','users.directory_read'),('$manager','users.directory_manage');
SQL
manager_version="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$manager'")"
target_version="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target'")"
block_name="auth-block-$suffix"; life_name="auth-directory-$suffix"
run_sql "set application_name='$block_name'; begin; select 1 from public.app_users where app_user_id='$target' for update; select pg_sleep(5); commit;" "$tmp/block" & p0=$!
wait_state "$block_name" "wait_event='PgSleep'"
run_sql "set application_name='$life_name'; begin; set local statement_timeout='15s'; set local role authenticated; select set_config('request.jwt.claim.sub','$manager_auth',true); select public.update_internal_user_directory('$target','{\"full_name\":\"Unauthorized change\"}'::jsonb,$target_version,'$auth_key'); commit;" "$tmp/life" & p1=$!
wait_state "$life_name" "wait_event_type='Lock'"
run_sql "begin; $prefix select public.revoke_hr_permission('$manager','users.directory_manage',$manager_version,'$revoke_key'); commit;" "$tmp/revoke"
grep -q '"success": true' "$tmp/revoke"
s=0; wait "$p0" || s=1; wait "$p1" || s=1
[[ "$s" == 0 ]] || { cat "$tmp/"* >&2; exit 1; }
grep -q 'FORBIDDEN' "$tmp/life"
psql_exec -qAt -c "select (full_name='Before authorization wait' and version_no=$target_version)::text from public.app_users where app_user_id='$target'" | grep -qx true
psql_exec -qAt -c "select count(*) from public.security_audit_log where request_id='$auth_key'" | grep -qx 0
echo 'Post-wait directory authorization PASS'
