#!/usr/bin/env bash
# TASK-S03-003 direct-RPC replay runner.
# Usage: bash supabase/tests/run_bulk_commands_replay.sh <disposable-postgres-container>
# The target must be an unlinked disposable local Supabase database. This script leaves no
# test trigger/function behind; dispose the runtime after the run to remove deterministic fixtures.
set -euo pipefail

container="${1:?usage: bash supabase/tests/run_bulk_commands_replay.sh <disposable-postgres-container>}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

run_sql() {
  docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1"
}

docker cp "$script_dir/bulk_commands_replay.sql" "$container:/tmp/bulk_commands_replay.sql"
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f /tmp/bulk_commands_replay.sql

status_delete_a="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000107'::uuid], 'READ', array['00000000-0000-0000-0000-000000000207'::uuid], array[1::bigint], '00000000-0000-0000-0000-000000000906'::uuid);
reset role;
"
status_delete_b="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.delete_or_inactivate_application('00000000-0000-0000-0000-000000000507'::uuid);
reset role;
"

run_sql "$status_delete_a" & status_delete_a_pid=$!
sleep 0.05
run_sql "$status_delete_b" & status_delete_b_pid=$!
wait "$status_delete_a_pid"
wait "$status_delete_b_pid"
status_order_a="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000103'::uuid, '00000000-0000-0000-0000-000000000106'::uuid], 'READ', array['00000000-0000-0000-0000-000000000203'::uuid, '00000000-0000-0000-0000-000000000206'::uuid], array[1::bigint, 1::bigint], '00000000-0000-0000-0000-000000000910'::uuid);
reset role;
"
status_order_b="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000106'::uuid, '00000000-0000-0000-0000-000000000103'::uuid], 'READ', array['00000000-0000-0000-0000-000000000206'::uuid, '00000000-0000-0000-0000-000000000203'::uuid], array[1::bigint, 1::bigint], '00000000-0000-0000-0000-000000000911'::uuid);
reset role;
"

run_sql "$status_order_a" & status_order_a_pid=$!
sleep 0.05
run_sql "$status_order_b" & status_order_b_pid=$!
wait "$status_order_a_pid"
wait "$status_order_b_pid"


assignment_delete_a="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000208'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000907'::uuid);
reset role;
"
assignment_delete_b="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.delete_or_inactivate_application('00000000-0000-0000-0000-000000000508'::uuid);
reset role;
"

run_sql "$assignment_delete_a" & assignment_delete_a_pid=$!
sleep 0.05
run_sql "$assignment_delete_b" & assignment_delete_b_pid=$!
wait "$assignment_delete_a_pid"
wait "$assignment_delete_b_pid"
status_assignment_a="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000109'::uuid], 'READ', array['00000000-0000-0000-0000-000000000209'::uuid], array[1::bigint], '00000000-0000-0000-0000-000000000912'::uuid);
reset role;
"
status_assignment_b="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000209'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000913'::uuid);
reset role;
"

run_sql "$status_assignment_a" & status_assignment_a_pid=$!
sleep 0.05
run_sql "$status_assignment_b" & status_assignment_b_pid=$!
wait "$status_assignment_a_pid"
wait "$status_assignment_b_pid"


assignment_race_a="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000908'::uuid);
reset role;
"
assignment_race_b="
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000909'::uuid);
reset role;
"

run_sql "$assignment_race_a" & assignment_race_a_pid=$!
sleep 0.05
run_sql "$assignment_race_b" & assignment_race_b_pid=$!
wait "$assignment_race_a_pid"
wait "$assignment_race_b_pid"
if run_sql "set role anon; select public.bulk_set_latest_submission_manual_status(array[]::uuid[], 'READ', array[]::uuid[], array[]::bigint[], '00000000-0000-0000-0000-000000000914'::uuid);" >/dev/null 2>&1; then
  echo "anonymous role unexpectedly executed bulk status RPC" >&2
  exit 1
fi
if run_sql "set role anon; select public.bulk_create_or_update_applications(array[]::uuid[], null, null, null, null, '00000000-0000-0000-0000-000000000915'::uuid);" >/dev/null 2>&1; then
  echo "anonymous role unexpectedly executed bulk assignment RPC" >&2
  exit 1
fi


run_sql "
do \$\$
begin
  assert (select count(*) = 1 from public.applications where submission_id = '00000000-0000-0000-0000-000000000204');
  assert (select count(*) = 1 from public.interviews i join public.applications a using (application_id) where a.submission_id = '00000000-0000-0000-0000-000000000204' and i.round_no = 1);
  assert (select status_code = 'READ' and version_no = 2 from public.submissions where submission_id = '00000000-0000-0000-0000-000000000203');
  assert (select status_code = 'READ' and version_no = 2 from public.submissions where submission_id = '00000000-0000-0000-0000-000000000206');
  assert (select count(*) = 2 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000910');
  assert (select count(*) = 0 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000911');
  assert (select count(*) = 1 from public.security_audit_log where request_id = '00000000-0000-0000-0000-000000000910');
  assert (select count(*) = 1 from public.applications where submission_id = '00000000-0000-0000-0000-000000000209');
  assert (select count(*) = 1 from public.interviews i join public.applications a using (application_id) where a.submission_id = '00000000-0000-0000-0000-000000000209' and i.round_no = 1);
  assert (select status_code = 'PROCESSED' from public.submissions where submission_id = '00000000-0000-0000-0000-000000000209');
  assert (select count(*) = 1 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000913');
  assert (select count(*) = 1 from public.security_audit_log where request_id = '00000000-0000-0000-0000-000000000913');
end;
\$\$;
drop trigger bulk_replay_pause_submission on public.submissions;
drop function private.bulk_replay_pause_submission();
"

echo "bulk direct-RPC replay passed"
