#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_eiu-recruitment-dev"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
auth_id="$(new_uuid)"
user_id="$(new_uuid)"
request_id="$(new_uuid)"
master_code="S06001_CONCURRENT_${suffix}"

psql_exec() {
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

psql_exec <<SQL
insert into public.app_users(app_user_id, auth_user_id, email, full_name, is_active)
values (
  '$user_id'::uuid,
  '$auth_id'::uuid,
  's06001_concurrency_${suffix}@eiu.edu.vn',
  'S06-001 Concurrency HR',
  true
);

insert into public.app_user_permissions(app_user_id, permission_code)
values ('$user_id'::uuid, 'master_data.manage');

create or replace function private.s06_test_slow_master_insert()
returns trigger
language plpgsql
set search_path = ''
as \$\$
begin
  if new.code = '$master_code' then
    perform pg_sleep(1.5);
  end if;
  return new;
end;
\$\$;

drop trigger if exists s06_test_slow_master_insert on public.organizational_units;
create trigger s06_test_slow_master_insert
before insert on public.organizational_units
for each row execute function private.s06_test_slow_master_insert();
SQL

call_sql="select set_config('request.jwt.claims', jsonb_build_object('sub','$auth_id')::text, false); select public.create_master_item('organizational_units', '{\"code\":\"$master_code\",\"name_vi\":\"Concurrent Unit\"}'::jsonb, '$request_id'::uuid)::text;"

run_call() {
  docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$call_sql" | tail -n 1
}

run_call > /tmp/s06-concurrent-1.txt &
pid1=$!
run_call > /tmp/s06-concurrent-2.txt &
pid2=$!
wait "$pid1"
wait "$pid2"

result1="$(cat /tmp/s06-concurrent-1.txt)"
result2="$(cat /tmp/s06-concurrent-2.txt)"

if [[ -z "$result1" || -z "$result2" ]]; then
  echo "Concurrent calls must both return a typed result" >&2
  exit 1
fi
if [[ "$result1" != "$result2" ]]; then
  echo "Concurrent duplicate calls returned different results" >&2
  printf 'result1=%s\nresult2=%s\n' "$result1" "$result2" >&2
  exit 1
fi
if [[ "$result1" != *'"success": true'* ]]; then
  echo "Concurrent duplicate result was not successful: $result1" >&2
  exit 1
fi

psql_exec <<SQL
do \$\$
begin
  assert (select count(*) from public.organizational_units where code = '$master_code') = 1,
    'concurrent duplicate create must commit exactly one business row';
  assert (
    select count(*) from public.security_audit_log
    where request_id = '$request_id'::uuid and action_code = 'MASTER_DATA_CREATE'
  ) = 1, 'concurrent duplicate create must commit exactly one audit event';
  assert (
    select count(*) from public.idempotency_records
    where idempotency_key = '$request_id'::uuid and command_type = 'create_master_item'
  ) = 1, 'concurrent duplicate create must commit exactly one idempotency record';
end;
\$\$;

drop trigger if exists s06_test_slow_master_insert on public.organizational_units;
drop function if exists private.s06_test_slow_master_insert();
SQL

echo "TASK-S06-001 concurrent idempotency assertions passed with fresh fixture $suffix"
