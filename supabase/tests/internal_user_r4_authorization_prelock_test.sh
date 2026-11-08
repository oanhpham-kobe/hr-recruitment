#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_eiu-recruitment-dev"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
unit_id="$(new_uuid)"
root_id="$(new_uuid)"; root_auth="$(new_uuid)"
caller_id="$(new_uuid)"; caller_auth="$(new_uuid)"
target_id="$(new_uuid)"
blocked_email="r4_blocked_${suffix}@eiu.edu.vn"
final_email="r4_final_${suffix}@eiu.edu.vn"

psql_exec() { docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
run_sql() { local sql="$1" out="$2"; printf '%s ' "$sql" | docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >"$out" 2>&1; }
fail_with() { local message="$1" file="$2"; echo "$message" >&2; cat "$file" >&2 || true; exit 1; }

holder_pids=()
holder_apps=()
HOLDER_PID=""

cleanup_holders() {
  local app pid
  for app in "${holder_apps[@]}"; do
    psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$app' and pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  done
  for pid in "${holder_pids[@]}"; do
    wait "$pid" >/dev/null 2>&1 || true
  done
}

cleanup() {
  cleanup_holders
  psql_exec >/dev/null 2>&1 <<SQL || true
begin;
delete from public.app_user_permissions where app_user_id in ('$root_id'::uuid,'$caller_id'::uuid,'$target_id'::uuid);
delete from public.app_user_roles where app_user_id in ('$root_id'::uuid,'$caller_id'::uuid,'$target_id'::uuid);
delete from public.app_users where app_user_id in ('$root_id'::uuid,'$caller_id'::uuid,'$target_id'::uuid);
delete from public.organizational_units where unit_id='$unit_id'::uuid;
commit;
SQL
}
trap cleanup EXIT

# A holder transaction acquires the exact resource lock first, then acquires a
# unique readiness advisory xact lock, then sleeps. Seeing the readiness lock
# held proves the target lock was already acquired. Because both the target
# advisory lock / row lock and the readiness lock are transaction-scoped, seeing
# readiness still held after the tested RPC proves the target lock remained held
# throughout that RPC.
start_holder() {
  local app="$1" ready_key="$2" lock_sql="$3" out="$4"
  local sql
  sql="begin; set local application_name='$app'; $lock_sql select pg_advisory_xact_lock(hashtextextended('$ready_key',0)); select pg_sleep(30); rollback;"
  run_sql "$sql" "$out" &
  HOLDER_PID=$!
  holder_pids+=("$HOLDER_PID")
  holder_apps+=("$app")
}

ready_lock_is_held() {
  local ready_key="$1" held
  held="$(psql_exec -qAt -c "select not pg_try_advisory_lock(hashtextextended('$ready_key',0));")"
  [[ "$held" = "t" ]]
}

holder_backend_count() {
  local app="$1"
  psql_exec -qAt -c "select count(*) from pg_stat_activity where application_name='$app';"
}

wait_holder_ready() {
  local app="$1" ready_key="$2" shell_pid="$3" out="$4" i
  for i in $(seq 1 100); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
      fail_with "holder exited before readiness: $app" "$out"
    fi
    if [[ "$(holder_backend_count "$app")" = "1" ]] && ready_lock_is_held "$ready_key"; then
      return 0
    fi
    sleep 0.05
  done
  fail_with "holder readiness handshake timed out: $app" "$out"
}

assert_holder_still_held() {
  local app="$1" ready_key="$2" shell_pid="$3" out="$4"
  kill -0 "$shell_pid" >/dev/null 2>&1 || fail_with "holder exited before tested RPC completed: $app" "$out"
  [[ "$(holder_backend_count "$app")" = "1" ]] || fail_with "holder backend missing before release: $app" "$out"
  ready_lock_is_held "$ready_key" || fail_with "holder transaction released before tested RPC completed: $app" "$out"
}

release_holder() {
  local app="$1" shell_pid="$2" out="$3" terminated
  terminated="$(psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$app' and pid <> pg_backend_pid();")"
  [[ "$terminated" = "t" ]] || fail_with "failed to release exactly one holder backend: $app" "$out"
  wait "$shell_pid" >/dev/null 2>&1 || true
}

psql_exec <<SQL
insert into public.organizational_units(unit_id,name_vi,code,is_active)
values('$unit_id'::uuid,'R4 auth-before-lock unit','R4ABL_${suffix}',true);

insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin) values
 ('$root_id'::uuid,'$root_auth'::uuid,'root_r4_${suffix}@eiu.edu.vn','R4 Root',true,true),
 ('$caller_id'::uuid,'$caller_auth'::uuid,'caller_r4_${suffix}@eiu.edu.vn','R4 Unauthorized',true,false),
 ('$target_id'::uuid,null,'target_r4_${suffix}@eiu.edu.vn','R4 Target',true,false);
SQL

root_prefix="set local role authenticated; select set_config('request.jwt.claim.sub','$root_auth',true);"
unauthz_prefix="set local role authenticated; select set_config('request.jwt.claim.sub','$caller_auth',true);"

# 1. An authenticated principal without users.directory_manage must return
# FORBIDDEN while the exact normalized-email advisory lock is already held.
app="r4-email-unauthz-${suffix}"; ready="r4-ready-email-unauthz:${suffix}"
start_holder "$app" "$ready" "select pg_advisory_xact_lock(hashtextextended('internal-email:$blocked_email',0));" /tmp/r4-email-block
p0="$HOLDER_PID"
wait_holder_ready "$app" "$ready" "$p0" /tmp/r4-email-block
unauthz_email="begin; set local statement_timeout='700ms'; $unauthz_prefix select public.update_internal_user_directory('$target_id'::uuid,jsonb_build_object('email','$blocked_email'),1,'$(new_uuid)'::uuid); commit;"
set +e
run_sql "$unauthz_email" /tmp/r4-email-call; s1=$?
set -e
[[ $s1 -eq 0 ]] || fail_with 'unauthorized email call failed instead of returning FORBIDDEN' /tmp/r4-email-call
grep -q 'FORBIDDEN' /tmp/r4-email-call || fail_with 'unauthorized email call did not return FORBIDDEN' /tmp/r4-email-call
! grep -qi 'statement timeout' /tmp/r4-email-call || fail_with 'unauthorized email call waited on advisory lock' /tmp/r4-email-call
assert_holder_still_held "$app" "$ready" "$p0" /tmp/r4-email-block
release_holder "$app" "$p0" /tmp/r4-email-block

# 2. The same unauthorized principal must return FORBIDDEN while the exact Unit
# row is already locked FOR UPDATE, which conflicts with the wrapper's FOR KEY SHARE.
app="r4-unit-unauthz-${suffix}"; ready="r4-ready-unit-unauthz:${suffix}"
start_holder "$app" "$ready" "select 1 from public.organizational_units where unit_id='$unit_id'::uuid for update;" /tmp/r4-unit-block
p0="$HOLDER_PID"
wait_holder_ready "$app" "$ready" "$p0" /tmp/r4-unit-block
unauthz_unit="begin; set local statement_timeout='700ms'; $unauthz_prefix select public.update_internal_user_directory('$target_id'::uuid,jsonb_build_object('unit_id','$unit_id'),1,'$(new_uuid)'::uuid); commit;"
set +e
run_sql "$unauthz_unit" /tmp/r4-unit-call; s2=$?
set -e
[[ $s2 -eq 0 ]] || fail_with 'unauthorized Unit call failed instead of returning FORBIDDEN' /tmp/r4-unit-call
grep -q 'FORBIDDEN' /tmp/r4-unit-call || fail_with 'unauthorized Unit call did not return FORBIDDEN' /tmp/r4-unit-call
! grep -qi 'statement timeout' /tmp/r4-unit-call || fail_with 'unauthorized Unit call waited on row lock' /tmp/r4-unit-call
assert_holder_still_held "$app" "$ready" "$p0" /tmp/r4-unit-block
release_holder "$app" "$p0" /tmp/r4-unit-block

# 3. Missing trusted auth must return UNAUTHENTICATED while the exact email lock
# is already held. Role authenticated is retained only so the RPC is executable.
app="r4-email-noauth-${suffix}"; ready="r4-ready-email-noauth:${suffix}"
start_holder "$app" "$ready" "select pg_advisory_xact_lock(hashtextextended('internal-email:$blocked_email',0));" /tmp/r4-noauth-email-block
p0="$HOLDER_PID"
wait_holder_ready "$app" "$ready" "$p0" /tmp/r4-noauth-email-block
noauth_email="begin; set local role authenticated; set local statement_timeout='700ms'; select public.update_internal_user_directory('$target_id'::uuid,jsonb_build_object('email','$blocked_email'),1,'$(new_uuid)'::uuid); commit;"
set +e
run_sql "$noauth_email" /tmp/r4-noauth-email-call; s3=$?
set -e
[[ $s3 -eq 0 ]] || fail_with 'missing-auth email call failed instead of returning UNAUTHENTICATED' /tmp/r4-noauth-email-call
grep -q 'UNAUTHENTICATED' /tmp/r4-noauth-email-call || fail_with 'missing-auth email call did not return UNAUTHENTICATED' /tmp/r4-noauth-email-call
! grep -qi 'statement timeout' /tmp/r4-noauth-email-call || fail_with 'missing-auth email call waited on advisory lock' /tmp/r4-noauth-email-call
assert_holder_still_held "$app" "$ready" "$p0" /tmp/r4-noauth-email-block
release_holder "$app" "$p0" /tmp/r4-noauth-email-block

# 4. Missing trusted auth must also return UNAUTHENTICATED while the exact Unit
# row is already contended. This closes the R4 review's missing-auth Unit gap.
app="r4-unit-noauth-${suffix}"; ready="r4-ready-unit-noauth:${suffix}"
start_holder "$app" "$ready" "select 1 from public.organizational_units where unit_id='$unit_id'::uuid for update;" /tmp/r4-noauth-unit-block
p0="$HOLDER_PID"
wait_holder_ready "$app" "$ready" "$p0" /tmp/r4-noauth-unit-block
noauth_unit="begin; set local role authenticated; set local statement_timeout='700ms'; select public.update_internal_user_directory('$target_id'::uuid,jsonb_build_object('unit_id','$unit_id'),1,'$(new_uuid)'::uuid); commit;"
set +e
run_sql "$noauth_unit" /tmp/r4-noauth-unit-call; s4=$?
set -e
[[ $s4 -eq 0 ]] || fail_with 'missing-auth Unit call failed instead of returning UNAUTHENTICATED' /tmp/r4-noauth-unit-call
grep -q 'UNAUTHENTICATED' /tmp/r4-noauth-unit-call || fail_with 'missing-auth Unit call did not return UNAUTHENTICATED' /tmp/r4-noauth-unit-call
! grep -qi 'statement timeout' /tmp/r4-noauth-unit-call || fail_with 'missing-auth Unit call waited on row lock' /tmp/r4-noauth-unit-call
assert_holder_still_held "$app" "$ready" "$p0" /tmp/r4-noauth-unit-block
release_holder "$app" "$p0" /tmp/r4-noauth-unit-block

# 5. Authorized callers retain the accepted R3 prelock behavior and still reach
# the delegated implementation successfully after authorization. The target is
# intentionally unbound because the accepted identity contract forbids changing
# email on an already-bound Internal User.
ver="$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id='$target_id'::uuid")"
authorized="begin; set local statement_timeout='5s'; $root_prefix select public.update_internal_user_directory('$target_id'::uuid,jsonb_build_object('email','$final_email','unit_id','$unit_id'),$ver,'$(new_uuid)'::uuid); commit;"
run_sql "$authorized" /tmp/r4-authorized-call || fail_with 'authorized directory update raised an error' /tmp/r4-authorized-call
grep -q '"success": true' /tmp/r4-authorized-call || fail_with 'authorized directory update was not successful' /tmp/r4-authorized-call
actual="$(psql_exec -qAt -c "select lower(email::text)||'|'||unit_id::text from public.app_users where app_user_id='$target_id'::uuid")"
[[ "$actual" = "$final_email|$unit_id" ]] || { echo "authorized post-state mismatch: $actual" >&2; cat /tmp/r4-authorized-call >&2; exit 1; }

printf '%s\n' 'TASK-S06-002 R4 authorization-before-prelock regression: PASS'
