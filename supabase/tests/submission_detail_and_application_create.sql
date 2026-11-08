-- TASK-S03-005 direct-RPC test replay contract.
-- Run only against an unlinked disposable local Supabase database as postgres:
--   psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/submission_detail_and_application_create.sql
\set ON_ERROR_STOP on

begin;

-- 1. Setup master data
insert into public.organizational_units (unit_id, code, name_vi)
values ('00000000-0000-0000-0000-000000005301', 'S05_UNIT', 'S05 Test Unit')
on conflict (unit_id) do nothing;

insert into public.position_groups (position_group_id, code, name_vi)
values ('00000000-0000-0000-0000-000000005302', 'S05_GROUP', 'S05 Position Group')
on conflict (position_group_id) do nothing;

insert into public.department_teams (department_team_id, unit_id, code, name_vi)
values ('00000000-0000-0000-0000-000000005303', '00000000-0000-0000-0000-000000005301', 'S05_TEAM', 'S05 Test Team')
on conflict (department_team_id) do nothing;

insert into public.positions (position_id, unit_id, department_team_id, position_group_id, code, name_vi)
values ('00000000-0000-0000-0000-000000005304', '00000000-0000-0000-0000-000000005301', '00000000-0000-0000-0000-000000005303', '00000000-0000-0000-0000-000000005302', 'S05_POS', 'S05 Test Position')
on conflict (position_id) do nothing;

-- 2. Setup users & permissions
insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_root_admin)
values
  ('00000000-0000-0000-0000-000000005001', '00000000-0000-0000-0000-000000005101', 's05-root@eiu.edu.vn', 'S05 Root', true),
  ('00000000-0000-0000-0000-000000005002', '00000000-0000-0000-0000-000000005102', 's05-hr@eiu.edu.vn', 'S05 HR User', false),
  ('00000000-0000-0000-0000-000000005003', '00000000-0000-0000-0000-000000005103', 's05-view-only@eiu.edu.vn', 'S05 View Only', false),
  ('00000000-0000-0000-0000-000000005004', '00000000-0000-0000-0000-000000005104', 's05-unauthorized@eiu.edu.vn', 'S05 Unauthorized', false)
on conflict (app_user_id) do nothing;

insert into public.app_user_roles (app_user_id, role_code)
values ('00000000-0000-0000-0000-000000005002', 'HR')
on conflict (app_user_id, role_code) do nothing;

insert into public.app_user_permissions (app_user_id, permission_code, granted_by)
values
  ('00000000-0000-0000-0000-000000005002', 'submissions.view', '00000000-0000-0000-0000-000000005001'),
  ('00000000-0000-0000-0000-000000005002', 'submissions.status', '00000000-0000-0000-0000-000000005001'),
  ('00000000-0000-0000-0000-000000005002', 'submissions.edit', '00000000-0000-0000-0000-000000005001'),
  ('00000000-0000-0000-0000-000000005002', 'applications.create', '00000000-0000-0000-0000-000000005001'),
  ('00000000-0000-0000-0000-000000005002', 'applications.manage', '00000000-0000-0000-0000-000000005001'),
  ('00000000-0000-0000-0000-000000005003', 'submissions.view', '00000000-0000-0000-0000-000000005001')
on conflict (app_user_id, permission_code) do nothing;

-- 3. Setup candidate & submission
insert into public.candidates (candidate_id, auth_user_id, email, current_full_name)
values ('00000000-0000-0000-0000-000000005201', '00000000-0000-0000-0000-000000005211', 's05-cand@example.test', 'Candidate S05')
on conflict (candidate_id) do nothing;

insert into public.submissions (
  submission_id, candidate_id, full_name, date_of_birth, gender_code,
  current_address, phone, email_snapshot, status_code, submitted_at, version_no
)
values (
  '00000000-0000-0000-0000-000000005501',
  '00000000-0000-0000-0000-000000005201',
  'Candidate S05',
  '1995-05-15',
  'FEMALE',
  '123 Test Street, Binh Duong',
  '0912345678',
  's05-cand@example.test',
  'NEW',
  '2026-09-01 08:00:00+00',
  1
)
on conflict (submission_id) do nothing;

-- Test assertions
do $$
declare
  v_res jsonb;
  v_status text;
  v_audit_count bigint;
  v_idempotency_key uuid;
begin
  -- 1. Unauthorized actor rejected from open_submission
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000005104', true);
  v_res := public.open_submission('00000000-0000-0000-0000-000000005501'::uuid);
  assert (v_res ->> 'success')::boolean = false, 'Unauthorized actor must fail open_submission';
  assert (v_res ->> 'error_code') = 'FORBIDDEN', 'Error code must be FORBIDDEN';

  -- 2. View-only actor reads without mutating NEW status
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000005103', true);
  v_res := public.open_submission('00000000-0000-0000-0000-000000005501'::uuid);
  assert (v_res ->> 'success')::boolean = true, 'View-only actor can open submission';
  assert (v_res -> 'data' ->> 'status_code') = 'NEW', 'View-only actor does not mutate NEW status';

  select status_code into v_status from public.submissions where submission_id = '00000000-0000-0000-0000-000000005501'::uuid;
  assert v_status = 'NEW', 'Status in database remains NEW after view-only open';

  -- 3. Status-authorized actor opens submission and mutates NEW -> READ
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000005102', true);
  v_res := public.open_submission('00000000-0000-0000-0000-000000005501'::uuid);
  assert (v_res ->> 'success')::boolean = true, 'HR actor can open submission';
  assert (v_res -> 'data' ->> 'status_code') = 'READ', 'HR actor with submissions.status mutates NEW to READ';
  assert (v_res -> 'data' ->> 'version_no')::int = 2, 'open_submission returns fresh version_no after touch_version';

  select status_code into v_status from public.submissions where submission_id = '00000000-0000-0000-0000-000000005501'::uuid;
  assert v_status = 'READ', 'Status in database updated to READ';

  -- 4. get_submission_detail returns complete detail
  v_res := public.get_submission_detail('00000000-0000-0000-0000-000000005501'::uuid);
  assert (v_res ->> 'success')::boolean = true, 'get_submission_detail succeeds';
  assert (v_res -> 'data' ->> 'email') = 's05-cand@example.test', 'Email matches';
  assert (v_res -> 'data' ->> 'full_name') = 'Candidate S05', 'Full name matches';

  -- 5. update_submission_by_hr records SUBMISSION_HR_NOTE_UPDATE in security_audit_log
  v_res := public.update_submission_by_hr(
    '00000000-0000-0000-0000-000000005501'::uuid,
    'Updated HR note for candidate',
    2
  );
  assert (v_res ->> 'success')::boolean = true, 'update_submission_by_hr succeeds';
  assert (v_res -> 'data' ->> 'hr_note') = 'Updated HR note for candidate', 'HR note saved';

  select count(*) into v_audit_count
  from public.security_audit_log
  where action_code = 'SUBMISSION_HR_NOTE_UPDATE'
    and entity_id = '00000000-0000-0000-0000-000000005501'::uuid;
  assert v_audit_count = 1, 'Exactly one security_audit_log entry created for SUBMISSION_HR_NOTE_UPDATE';

  -- 6. create_or_update_application creates Round 1 and records APPLICATION_CREATE_OR_UPDATE
  v_res := public.create_or_update_application(
    '00000000-0000-0000-0000-000000005501'::uuid,
    '00000000-0000-0000-0000-000000005301'::uuid,
    '00000000-0000-0000-0000-000000005303'::uuid,
    '00000000-0000-0000-0000-000000005304'::uuid,
    '00000000-0000-0000-0000-000000005002'::uuid
  );
  assert (v_res ->> 'success')::boolean = true, 'create_or_update_application succeeds';
  assert (v_res -> 'data' ->> 'round1_interview_id') is not null, 'Round 1 interview id returned';

  select count(*) into v_audit_count
  from public.security_audit_log
  where action_code = 'APPLICATION_CREATE_OR_UPDATE'
    and (metadata ->> 'submission_id') = '00000000-0000-0000-0000-000000005501';
  assert v_audit_count = 1, 'Exactly one security_audit_log entry created for APPLICATION_CREATE_OR_UPDATE';

  -- 7. Unconfirmed duplicate application creation returns DUPLICATE_APPLICATION
  v_res := public.create_or_update_application(
    '00000000-0000-0000-0000-000000005501'::uuid,
    '00000000-0000-0000-0000-000000005301'::uuid,
    '00000000-0000-0000-0000-000000005303'::uuid,
    '00000000-0000-0000-0000-000000005304'::uuid,
    '00000000-0000-0000-0000-000000005001'::uuid,
    gen_random_uuid(),
    false
  );
  assert (v_res ->> 'success')::boolean = false, 'Unconfirmed duplicate must fail';
  assert (v_res ->> 'error_code') = 'DUPLICATE_APPLICATION', 'Error code must be DUPLICATE_APPLICATION';

  -- 8. Confirmed duplicate application updates HR owner with idempotency key
  v_idempotency_key := gen_random_uuid();
  v_res := public.create_or_update_application(
    '00000000-0000-0000-0000-000000005501'::uuid,
    '00000000-0000-0000-0000-000000005301'::uuid,
    '00000000-0000-0000-0000-000000005303'::uuid,
    '00000000-0000-0000-0000-000000005304'::uuid,
    '00000000-0000-0000-0000-000000005001'::uuid,
    v_idempotency_key,
    true
  );
  assert (v_res ->> 'success')::boolean = true, 'Confirmed duplicate update succeeds';
  assert (v_res -> 'data' ->> 'version_no')::int = 2, 'Version incremented to 2';

  -- 9. Idempotent replay with same idempotency key returns stored result
  v_res := public.create_or_update_application(
    '00000000-0000-0000-0000-000000005501'::uuid,
    '00000000-0000-0000-0000-000000005301'::uuid,
    '00000000-0000-0000-0000-000000005303'::uuid,
    '00000000-0000-0000-0000-000000005304'::uuid,
    '00000000-0000-0000-0000-000000005001'::uuid,
    v_idempotency_key,
    true
  );
  assert (v_res ->> 'success')::boolean = true, 'Idempotent replay succeeds';
  assert (v_res -> 'data' ->> 'version_no')::int = 2, 'Idempotent replay returns stored version';

  select count(*) into v_audit_count
  from public.idempotency_records
  where command_type = 'create_or_update_application'
    and idempotency_key = v_idempotency_key;
  assert v_audit_count = 1, 'Exactly one idempotency record stored';
end;
$$;

rollback;
