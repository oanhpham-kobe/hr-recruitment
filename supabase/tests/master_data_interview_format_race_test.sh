#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_eiu-recruitment-dev"
new_uuid() { cat /proc/sys/kernel/random/uuid; }
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"

auth_id="$(new_uuid)"
user_id="$(new_uuid)"
candidate_auth="$(new_uuid)"
candidate_id="$(new_uuid)"
unit_id="$(new_uuid)"
group_id="$(new_uuid)"
position_id="$(new_uuid)"
submission_id="$(new_uuid)"
application_id="$(new_uuid)"
format_id="$(new_uuid)"
interview_id="$(new_uuid)"
request_id="$(new_uuid)"

psql_exec() {
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

psql_exec <<SQL
insert into public.app_users(app_user_id, auth_user_id, email, full_name, is_active)
values ('$user_id'::uuid, '$auth_id'::uuid, 's06001_format_race_${suffix}@eiu.edu.vn', 'S06 Format Race HR', true);
insert into public.app_user_roles(app_user_id, role_code)
values ('$user_id'::uuid, 'HR')
on conflict do nothing;
insert into public.app_user_permissions(app_user_id, permission_code)
values ('$user_id'::uuid, 'master_data.manage');

insert into public.organizational_units(unit_id, code, name_vi, is_active)
values ('$unit_id'::uuid, 'RACE_UNIT_${suffix}', 'Race Unit', true);
insert into public.position_groups(position_group_id, code, name_vi, is_active)
values ('$group_id'::uuid, 'RACE_GROUP_${suffix}', 'Race Group', true);
insert into public.positions(position_id, unit_id, position_group_id, code, name_vi, is_active)
values ('$position_id'::uuid, '$unit_id'::uuid, '$group_id'::uuid, 'RACE_POS_${suffix}', 'Race Position', true);

insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$candidate_id'::uuid, '$candidate_auth'::uuid, 's06001_format_candidate_${suffix}@example.com', true);
insert into public.submissions(
  submission_id, candidate_id, status_code, full_name, date_of_birth, gender_code,
  current_address, phone, email_snapshot
) values (
  '$submission_id'::uuid, '$candidate_id'::uuid, 'PROCESSED', 'Race Candidate', date '1990-01-01', 'MALE',
  'Address', '0900000000', 's06001_format_candidate_${suffix}@example.com'
);
insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values ('$application_id'::uuid, '$submission_id'::uuid, '$unit_id'::uuid, '$position_id'::uuid, '$user_id'::uuid, true);

insert into public.interview_formats(
  interview_format_id, code, name_vi, requires_room, requires_meeting_link, is_active
) values (
  '$format_id'::uuid, 'RACE_FMT_${suffix}', 'Race Format', false, false, true
);

create or replace function private.s06_test_pause_format_first_use()
returns trigger
language plpgsql
set search_path = ''
as \$\$
begin
  if new.interview_format_id = '$format_id'::uuid then
    perform pg_sleep(3);
  end if;
  return new;
end;
\$\$;

drop trigger if exists m_s06_test_pause_format_first_use on public.interviews;
create trigger m_s06_test_pause_format_first_use
before insert on public.interviews
for each row execute function private.s06_test_pause_format_first_use();
SQL

insert_sql="insert into public.interviews(interview_id,application_id,round_no,start_at,end_at,interview_format_id,room_id,meeting_link,schedule_status_code,report_status_code,is_active) values ('$interview_id'::uuid,'$application_id'::uuid,1,timestamptz '2026-09-25 02:00:00+00',timestamptz '2026-09-25 03:00:00+00','$format_id'::uuid,null,null,'AWAITING','AWAITING_INTERVIEW',true);"

docker exec -e PGAPPNAME=s06-format-race-insert -i "$container_name" \
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$insert_sql" \
  > /tmp/s06-format-race-insert.txt 2>&1 &
insert_pid=$!

sleeping=false
for _ in $(seq 1 60); do
  wait_event="$(docker exec -i "$container_name" psql -qAt -U postgres -d postgres -c "select coalesce(wait_event,'') from pg_stat_activity where application_name='s06-format-race-insert' and query like 'insert into public.interviews%' limit 1;" | tr -d '\r')"
  if [[ "$wait_event" == "PgSleep" ]]; then
    sleeping=true
    break
  fi
  sleep 0.1
done
if [[ "$sleeping" != "true" ]]; then
  echo "Did not observe deterministic pause between Interview format guards" >&2
  cat /tmp/s06-format-race-insert.txt >&2 || true
  kill "$insert_pid" 2>/dev/null || true
  exit 1
fi

update_sql="select set_config('request.jwt.claims',jsonb_build_object('sub','$auth_id')::text,false); select public.update_master_item('interview_formats','$format_id'::uuid,'{\"requires_meeting_link\":true}'::jsonb,1,'$request_id'::uuid)::text;"
update_result="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$update_sql" | tail -n 1)"

wait "$insert_pid"

if [[ "$update_result" != *'MASTER_STRUCTURAL_HISTORY'* ]]; then
  echo "Concurrent Format requirement update was not rejected after first Interview use" >&2
  printf 'update_result=%s\n' "$update_result" >&2
  cat /tmp/s06-format-race-insert.txt >&2 || true
  exit 1
fi

psql_exec <<SQL
do \$\$
begin
  assert exists (
    select 1 from public.interviews
    where interview_id = '$interview_id'::uuid
      and interview_format_id = '$format_id'::uuid
      and meeting_link is null
      and room_id is null
  ), 'first Interview must commit under the locked false/false Format semantics';
  assert exists (
    select 1 from public.interview_formats
    where interview_format_id = '$format_id'::uuid
      and requires_room = false
      and requires_meeting_link = false
      and version_no = 1
  ), 'concurrent metadata repurpose must not commit after first use';
end;
\$\$;

drop trigger if exists m_s06_test_pause_format_first_use on public.interviews;
drop function if exists private.s06_test_pause_format_first_use();

delete from public.interviews where interview_id = '$interview_id'::uuid;
delete from public.applications where application_id = '$application_id'::uuid;
delete from public.submissions where submission_id = '$submission_id'::uuid;
delete from public.candidates where candidate_id = '$candidate_id'::uuid;
delete from public.positions where position_id = '$position_id'::uuid;
delete from public.position_groups where position_group_id = '$group_id'::uuid;
delete from public.organizational_units where unit_id = '$unit_id'::uuid;
delete from public.interview_formats where interview_format_id = '$format_id'::uuid;
delete from public.app_user_permissions where app_user_id = '$user_id'::uuid;
delete from public.app_user_roles where app_user_id = '$user_id'::uuid;
delete from public.app_users where app_user_id = '$user_id'::uuid;
SQL

echo "TASK-S06-001 Interview Format first-use race assertions passed"
