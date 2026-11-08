-- TASK-S03-006 direct-RPC test replay contract.
-- Run only against an unlinked disposable local Supabase database as postgres:
--   psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/candidate_lifecycle_and_inbox_bulk_tokens.sql
\set ON_ERROR_STOP on

begin;

-- 1. Master data setup
insert into public.organizational_units (unit_id, code, name_vi)
values ('00000000-0000-0000-0000-000000006301', 'S06_UNIT', 'S06 Test Unit')
on conflict (unit_id) do nothing;

insert into public.position_groups (position_group_id, code, name_vi)
values ('00000000-0000-0000-0000-000000006302', 'S06_GROUP', 'S06 Position Group')
on conflict (position_group_id) do nothing;

insert into public.department_teams (department_team_id, unit_id, code, name_vi)
values ('00000000-0000-0000-0000-000000006303', '00000000-0000-0000-0000-000000006301', 'S06_TEAM', 'S06 Test Team')
on conflict (department_team_id) do nothing;

insert into public.positions (position_id, unit_id, department_team_id, position_group_id, code, name_vi)
values ('00000000-0000-0000-0000-000000006304', '00000000-0000-0000-0000-000000006301', '00000000-0000-0000-0000-000000006303', '00000000-0000-0000-0000-000000006302', 'S06_POS', 'S06 Test Position')
on conflict (position_id) do nothing;

-- 2. Setup users & permissions
insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_root_admin)
values
  ('00000000-0000-0000-0000-000000006001', '00000000-0000-0000-0000-000000006101', 's06-root@eiu.edu.vn', 'S06 Root', true),
  ('00000000-0000-0000-0000-000000006002', '00000000-0000-0000-0000-000000006102', 's06-hr@eiu.edu.vn', 'S06 HR User', false),
  ('00000000-0000-0000-0000-000000006003', '00000000-0000-0000-0000-000000006103', 's06-unauthorized@eiu.edu.vn', 'S06 Unauthorized', false)
on conflict (app_user_id) do nothing;

insert into public.app_user_roles (app_user_id, role_code)
values ('00000000-0000-0000-0000-000000006002', 'HR')
on conflict (app_user_id, role_code) do nothing;

insert into public.permissions (permission_code, description)
values
  ('candidates.active_manage', 'Manage candidate active/inactive lifecycle'),
  ('submissions.status', 'Manage submission status')
on conflict (permission_code) do nothing;

insert into public.app_user_permissions (app_user_id, permission_code, granted_by)
values
  ('00000000-0000-0000-0000-000000006002', 'candidates.active_manage', '00000000-0000-0000-0000-000000006001'),
  ('00000000-0000-0000-0000-000000006002', 'submissions.status', '00000000-0000-0000-0000-000000006001')
on conflict (app_user_id, permission_code) do nothing;

-- 3. Candidates and submissions setup
insert into public.candidates (candidate_id, auth_user_id, email, current_full_name, is_active, version_no)
values
  ('00000000-0000-0000-0000-000000006201', '00000000-0000-0000-0000-000000006211', 's06-cand1@example.test', 'Candidate S06 One', true, 1),
  ('00000000-0000-0000-0000-000000006202', '00000000-0000-0000-0000-000000006212', 's06-cand2@example.test', 'Candidate S06 Two', true, 1)
on conflict (candidate_id) do nothing;

insert into public.submissions (
  submission_id, candidate_id, full_name, date_of_birth, gender_code,
  current_address, phone, email_snapshot, status_code, submitted_at, version_no
)
values
  (
    '00000000-0000-0000-0000-000000006501',
    '00000000-0000-0000-0000-000000006201',
    'Candidate S06 One',
    '1995-01-01',
    'FEMALE',
    'Binh Duong',
    '0901000001',
    's06-cand1@example.test',
    'NEW',
    '2026-09-01T08:00:00Z',
    1
  ),
  (
    '00000000-0000-0000-0000-000000006502',
    '00000000-0000-0000-0000-000000006202',
    'Candidate S06 Two',
    '1996-02-02',
    'MALE',
    'Ho Chi Minh',
    '0901000002',
    's06-cand2@example.test',
    'NEW',
    '2026-09-02T08:00:00Z',
    1
  )
on conflict (submission_id) do nothing;

-- 4. Test unauthorized caller
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000006103', true);

do $$
declare
  v_res jsonb;
begin
  v_res := public.set_candidate_active(
    '00000000-0000-0000-0000-000000006201'::uuid,
    false,
    1::bigint
  );
  if (v_res->>'success')::boolean is not false or v_res->>'error_code' <> 'FORBIDDEN' then
    raise exception 'Expected FORBIDDEN for unauthorized caller, got %', v_res;
  end if;
end;
$$;

-- 5. Test set_candidate_active (Inactivate with optimistic concurrency)
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000006102', true);

do $$
declare
  v_res jsonb;
  v_cand public.candidates%rowtype;
begin
  -- Stale version test
  v_res := public.set_candidate_active(
    '00000000-0000-0000-0000-000000006201'::uuid,
    false,
    999::bigint
  );
  if (v_res->>'success')::boolean is not false or v_res->>'error_code' <> 'STALE_VERSION' then
    raise exception 'Expected STALE_VERSION for invalid expected version, got %', v_res;
  end if;

  -- Correct version test: inactivate
  v_res := public.set_candidate_active(
    '00000000-0000-0000-0000-000000006201'::uuid,
    false,
    1::bigint
  );
  if (v_res->>'success')::boolean is not true then
    raise exception 'Expected success for set_candidate_active, got %', v_res;
  end if;

  select * into v_cand from public.candidates where candidate_id = '00000000-0000-0000-0000-000000006201';
  if v_cand.is_active is not false or v_cand.inactive_at is null or v_cand.inactive_by is null then
    raise exception 'Candidate inactive metadata not set correctly: %', row_to_json(v_cand);
  end if;
  if v_cand.version_no <> 2 then
    raise exception 'Expected candidate version_no 2 after update, got %', v_cand.version_no;
  end if;
end;
$$;

-- 6. Test bulk_set_candidate_active with all-or-nothing rollback
do $$
declare
  v_res jsonb;
begin
  -- Batch with one stale version should fail completely
  v_res := public.bulk_set_candidate_active(
    array['00000000-0000-0000-0000-000000006201'::uuid, '00000000-0000-0000-0000-000000006202'::uuid],
    false,
    array[2::bigint, 999::bigint],
    gen_random_uuid()
  );
  if (v_res->>'success')::boolean is not false or v_res->>'error_code' <> 'STALE_VERSION' then
    raise exception 'Expected STALE_VERSION for bulk_set_candidate_active, got %', v_res;
  end if;

  -- Batch with correct expected versions: inactivate candidate 2
  v_res := public.bulk_set_candidate_active(
    array['00000000-0000-0000-0000-000000006202'::uuid],
    false,
    array[1::bigint],
    gen_random_uuid()
  );
  if (v_res->>'success')::boolean is not true then
    raise exception 'Expected success for bulk_set_candidate_active, got %', v_res;
  end if;
end;
$$;

-- 7. Test bulk_set_latest_submission_manual_status with row-bound token
do $$
declare
  v_res jsonb;
  v_sub public.submissions%rowtype;
begin
  -- Stale version should fail
  v_res := public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000006202'::uuid],
    'READ',
    array['00000000-0000-0000-0000-000000006502'::uuid],
    array[999::bigint],
    gen_random_uuid()
  );
  if (v_res->>'success')::boolean is not false or v_res->>'error_code' <> 'STALE_VERSION' then
    raise exception 'Expected STALE_VERSION for bulk status update with stale version, got %', v_res;
  end if;

  -- Fresh version should succeed
  v_res := public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000006202'::uuid],
    'READ',
    array['00000000-0000-0000-0000-000000006502'::uuid],
    array[1::bigint],
    gen_random_uuid()
  );
  if (v_res->>'success')::boolean is not true then
    raise exception 'Expected success for bulk status update, got %', v_res;
  end if;

  select * into v_sub from public.submissions where submission_id = '00000000-0000-0000-0000-000000006502';
  if v_sub.status_code <> 'READ' or v_sub.version_no <> 2 then
    raise exception 'Expected submission status READ and version_no 2, got % / %', v_sub.status_code, v_sub.version_no;
  end if;
end;
$$;

reset role;

rollback;
