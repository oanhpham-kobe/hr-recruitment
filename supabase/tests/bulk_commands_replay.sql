-- TASK-S03-003 direct-RPC replay contract.
-- Run only against an unlinked disposable local Supabase database as postgres:
--   psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/bulk_commands_replay.sql
-- The script creates deterministic fixtures and temporary test triggers. Dispose the database after use.
\set ON_ERROR_STOP on


insert into public.organizational_units (unit_id, code, name_vi)
values ('00000000-0000-0000-0000-000000000301', 'BULK_REPLAY', 'Bulk Replay Unit');
insert into public.position_groups (position_group_id, code, name_vi)
values ('00000000-0000-0000-0000-000000000303', 'BULK_REPLAY', 'Bulk Replay Group');
insert into public.positions (position_id, unit_id, position_group_id, code, name_vi)
values ('00000000-0000-0000-0000-000000000304', '00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000303', 'BULK_REPLAY', 'Bulk Replay Position');

insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_root_admin)
values
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'bulk-root@eiu.edu.vn', 'Bulk Root', true),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000002', 'bulk-hr@eiu.edu.vn', 'Bulk HR', false),
  ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000003', 'bulk-denied@eiu.edu.vn', 'Bulk Denied', false),
  ('00000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000004', 'bulk-view@eiu.edu.vn', 'Bulk View', false),
  ('00000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000005', 'bulk-status@eiu.edu.vn', 'Bulk Status', false),
  ('00000000-0000-0000-0000-000000000016', '00000000-0000-0000-0000-000000000006', 'bulk-create@eiu.edu.vn', 'Bulk Create', false),
  ('00000000-0000-0000-0000-000000000017', '00000000-0000-0000-0000-000000000007', 'bulk-manage@eiu.edu.vn', 'Bulk Manage', false),
  ('00000000-0000-0000-0000-000000000018', '00000000-0000-0000-0000-000000000008', 'bulk-conjunction@eiu.edu.vn', 'Bulk Conjunction', false);
insert into public.app_user_roles (app_user_id, role_code)
values ('00000000-0000-0000-0000-000000000012', 'HR');
insert into public.permissions (permission_code, description)
values ('applications.create', 'Create applications')
on conflict (permission_code) do nothing;
insert into public.app_user_permissions (app_user_id, permission_code, granted_by)
values
  ('00000000-0000-0000-0000-000000000014', 'submissions.view', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000015', 'submissions.status', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000016', 'applications.create', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000017', 'applications.manage', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000018', 'applications.manage', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000018', 'submissions.view', '00000000-0000-0000-0000-000000000011');

insert into public.candidates (candidate_id, auth_user_id, email, current_full_name)
values
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000111', 'bulk-candidate-1@example.test', 'Candidate 1'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000112', 'bulk-candidate-2@example.test', 'Candidate 2'),
  ('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000113', 'bulk-candidate-3@example.test', 'Candidate 3'),
  ('00000000-0000-0000-0000-000000000104', '00000000-0000-0000-0000-000000000114', 'bulk-candidate-4@example.test', 'Candidate 4'),
  ('00000000-0000-0000-0000-000000000105', '00000000-0000-0000-0000-000000000115', 'bulk-candidate-5@example.test', 'Candidate 5'),
  ('00000000-0000-0000-0000-000000000106', '00000000-0000-0000-0000-000000000116', 'bulk-candidate-6@example.test', 'Candidate 6'),
  ('00000000-0000-0000-0000-000000000107', '00000000-0000-0000-0000-000000000117', 'bulk-candidate-7@example.test', 'Candidate 7'),
  ('00000000-0000-0000-0000-000000000108', '00000000-0000-0000-0000-000000000118', 'bulk-candidate-8@example.test', 'Candidate 8'),
  ('00000000-0000-0000-0000-000000000109', '00000000-0000-0000-0000-000000000119', 'bulk-candidate-9@example.test', 'Candidate 9'),
  ('00000000-0000-0000-0000-000000000110', '00000000-0000-0000-0000-000000000120', 'bulk-candidate-10@example.test', 'Candidate 10'),
  ('00000000-0000-0000-0000-000000000111', '00000000-0000-0000-0000-000000000121', 'bulk-candidate-11@example.test', 'Candidate 11'),
  ('00000000-0000-0000-0000-000000000113', '00000000-0000-0000-0000-000000000123', 'bulk-candidate-13@example.test', 'Candidate 13'),
  ('00000000-0000-0000-0000-000000000115', '00000000-0000-0000-0000-000000000125', 'bulk-candidate-15@example.test', 'Candidate 15'),
  ('00000000-0000-0000-0000-000000000114', '00000000-0000-0000-0000-000000000124', 'bulk-candidate-14@example.test', 'Candidate 14');
insert into public.candidates (candidate_id, auth_user_id, email, current_full_name, is_active, inactive_at, inactive_by)
values ('00000000-0000-0000-0000-000000000112', '00000000-0000-0000-0000-000000000122', 'bulk-candidate-12@example.test', 'Candidate 12', false, clock_timestamp(), '00000000-0000-0000-0000-000000000011');

insert into public.submissions (
  submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot
) values
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000101', 'Candidate 1', '2000-01-01', 'FEMALE', 'Address 1', '0900000001', 'bulk-candidate-1@example.test'),
  ('00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000102', 'Candidate 2', '2000-01-02', 'FEMALE', 'Address 2', '0900000002', 'bulk-candidate-2@example.test'),
  ('00000000-0000-0000-0000-000000000203', '00000000-0000-0000-0000-000000000103', 'Candidate 3', '2000-01-03', 'FEMALE', 'Address 3', '0900000003', 'bulk-candidate-3@example.test'),
  ('00000000-0000-0000-0000-000000000204', '00000000-0000-0000-0000-000000000104', 'Candidate 4', '2000-01-04', 'FEMALE', 'Address 4', '0900000004', 'bulk-candidate-4@example.test'),
  ('00000000-0000-0000-0000-000000000205', '00000000-0000-0000-0000-000000000105', 'Candidate 5', '2000-01-05', 'FEMALE', 'Address 5', '0900000005', 'bulk-candidate-5@example.test'),
  ('00000000-0000-0000-0000-000000000206', '00000000-0000-0000-0000-000000000106', 'Candidate 6', '2000-01-06', 'FEMALE', 'Address 6', '0900000006', 'bulk-candidate-6@example.test'),
  ('00000000-0000-0000-0000-000000000207', '00000000-0000-0000-0000-000000000107', 'Candidate 7', '2000-01-07', 'FEMALE', 'Address 7', '0900000007', 'bulk-candidate-7@example.test'),
  ('00000000-0000-0000-0000-000000000208', '00000000-0000-0000-0000-000000000108', 'Candidate 8', '2000-01-08', 'FEMALE', 'Address 8', '0900000008', 'bulk-candidate-8@example.test'),
  ('00000000-0000-0000-0000-000000000209', '00000000-0000-0000-0000-000000000109', 'Candidate 9', '2000-01-09', 'FEMALE', 'Address 9', '0900000009', 'bulk-candidate-9@example.test'),
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000110', 'Candidate 10', '2000-01-10', 'FEMALE', 'Address 10', '0900000010', 'bulk-candidate-10@example.test'),
  ('00000000-0000-0000-0000-000000000211', '00000000-0000-0000-0000-000000000111', 'Candidate 11', '2000-01-11', 'FEMALE', 'Address 11', '0900000011', 'bulk-candidate-11@example.test'),
  ('00000000-0000-0000-0000-000000000212', '00000000-0000-0000-0000-000000000112', 'Candidate 12', '2000-01-12', 'FEMALE', 'Address 12', '0900000012', 'bulk-candidate-12@example.test'),
  ('00000000-0000-0000-0000-000000000215', '00000000-0000-0000-0000-000000000115', 'Candidate 15', '2000-01-15', 'FEMALE', 'Address 15', '0900000015', 'bulk-candidate-15@example.test');
insert into public.submissions (
  submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, submitted_at
) values
  ('00000000-0000-0000-0000-000000000213', '00000000-0000-0000-0000-000000000113', 'Candidate 13 Old', '2000-01-13', 'FEMALE', 'Address 13', '0900000013', 'bulk-candidate-13@example.test', clock_timestamp() - interval '1 minute'),
  ('00000000-0000-0000-0000-000000000214', '00000000-0000-0000-0000-000000000113', 'Candidate 13 Latest', '2000-01-13', 'FEMALE', 'Address 13', '0900000013', 'bulk-candidate-13@example.test', clock_timestamp());

insert into public.applications (application_id, submission_id, unit_id, position_id, hr_owner_id, is_active)
values ('00000000-0000-0000-0000-000000000515', '00000000-0000-0000-0000-000000000215', '00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000304', '00000000-0000-0000-0000-000000000011', false);

-- Grant and direct authenticated-RPC boundary.
do $$
begin
  assert has_function_privilege('authenticated', 'public.bulk_set_latest_submission_manual_status(uuid[],text,uuid[],bigint[],uuid)', 'execute');
  assert has_function_privilege('authenticated', 'public.bulk_create_or_update_applications(uuid[],uuid,uuid,uuid,uuid,uuid)', 'execute');
  assert not has_function_privilege('anon', 'public.bulk_set_latest_submission_manual_status(uuid[],text,uuid[],bigint[],uuid)', 'execute');
  assert not has_function_privilege('public', 'public.bulk_create_or_update_applications(uuid[],uuid,uuid,uuid,uuid,uuid)', 'execute');
  assert (select relrowsecurity from pg_class where oid = 'public.activity_log'::regclass);
  assert (select relrowsecurity from pg_class where oid = 'public.security_audit_log'::regclass);
  assert (select relrowsecurity from pg_class where oid = 'public.idempotency_records'::regclass);
end;
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.bulk_set_latest_submission_manual_status(
  array['00000000-0000-0000-0000-000000000102'::uuid, '00000000-0000-0000-0000-000000000101'::uuid],
  'READ',
  array['00000000-0000-0000-0000-000000000202'::uuid, '00000000-0000-0000-0000-000000000201'::uuid],
  array[1::bigint, 1::bigint],
  '00000000-0000-0000-0000-000000000901'::uuid
);
reset role;

do $$
declare
  v_status jsonb;
  v_replay jsonb;
  v_conflict jsonb;
  v_assignment jsonb;
  v_assignment_replay jsonb;
  v_assignment_conflict jsonb;
begin
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000102'::uuid, '00000000-0000-0000-0000-000000000101'::uuid],
    'READ',
    array['00000000-0000-0000-0000-000000000202'::uuid, '00000000-0000-0000-0000-000000000201'::uuid],
    array[1::bigint, 1::bigint],
    '00000000-0000-0000-0000-000000000901'::uuid
  ) into v_replay;
  assert v_replay #>> '{data,items,0,candidate_id}' = '00000000-0000-0000-0000-000000000102';
  assert (select count(*) = 2 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000901');
  assert (select count(*) = 1 from public.security_audit_log where request_id = '00000000-0000-0000-0000-000000000901' and action_code = 'BULK_LATEST_SUBMISSION_STATUS');
  assert (select metadata ? 'request_fingerprint' and metadata ? 'selected_candidate_ids' from public.security_audit_log where request_id = '00000000-0000-0000-0000-000000000901');
  assert (select count(*) = 1 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000901' and entity_type = 'SUBMISSION' and entity_id = '00000000-0000-0000-0000-000000000202'::uuid and action_code = 'BULK_MANUAL_STATUS_SET' and actor_app_user_id = '00000000-0000-0000-0000-000000000011'::uuid and old_values = '{"status_code":"NEW","version_no":1}'::jsonb and new_values = '{"status_code":"READ","version_no":2}'::jsonb);
  assert (select count(*) = 1 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000901' and entity_type = 'SUBMISSION' and entity_id = '00000000-0000-0000-0000-000000000201'::uuid and action_code = 'BULK_MANUAL_STATUS_SET' and actor_app_user_id = '00000000-0000-0000-0000-000000000011'::uuid and old_values = '{"status_code":"NEW","version_no":1}'::jsonb and new_values = '{"status_code":"READ","version_no":2}'::jsonb);
  assert (select actor_auth_user_id = '00000000-0000-0000-0000-000000000001'::uuid and actor_app_user_id = '00000000-0000-0000-0000-000000000011'::uuid and entity_type = 'BATCH' and entity_id = '00000000-0000-0000-0000-000000000901'::uuid and metadata -> 'selected_candidate_ids' = '["00000000-0000-0000-0000-000000000102","00000000-0000-0000-0000-000000000101"]'::jsonb from public.security_audit_log where request_id = '00000000-0000-0000-0000-000000000901');

  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000102'::uuid, '00000000-0000-0000-0000-000000000101'::uuid],
    'NEW',
    array['00000000-0000-0000-0000-000000000202'::uuid, '00000000-0000-0000-0000-000000000201'::uuid],
    array[1::bigint, 1::bigint],
    '00000000-0000-0000-0000-000000000901'::uuid
  ) into v_conflict;
  assert v_conflict ->> 'error_code' = 'VALIDATION_ERROR';

  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000103'::uuid, '00000000-0000-0000-0000-000000000999'::uuid],
    'READ',
    array['00000000-0000-0000-0000-000000000203'::uuid, '00000000-0000-0000-0000-000000000999'::uuid],
    array[1::bigint, 1::bigint],
    '00000000-0000-0000-0000-000000000902'::uuid
  ) into v_status;
  assert v_status ->> 'error_code' = 'NOT_FOUND';
  assert (select status_code = 'NEW' and version_no = 1 from public.submissions where submission_id = '00000000-0000-0000-0000-000000000203');

  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000204'::uuid, '00000000-0000-0000-0000-000000000999'::uuid],
    '00000000-0000-0000-0000-000000000301'::uuid,
    null,
    '00000000-0000-0000-0000-000000000304'::uuid,
    '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000903'::uuid
  ) into v_status;
  assert v_status ->> 'error_code' = 'NOT_FOUND';
  assert (select count(*) = 0 from public.applications where submission_id = '00000000-0000-0000-0000-000000000204');

  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000205'::uuid],
    '00000000-0000-0000-0000-000000000301'::uuid,
    null,
    '00000000-0000-0000-0000-000000000304'::uuid,
    '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000904'::uuid
  ) into v_assignment;
  assert v_assignment ->> 'success' = 'true';
  assert (select count(*) = 1 from public.applications where submission_id = '00000000-0000-0000-0000-000000000205');
  assert (select count(*) = 1 from public.interviews i join public.applications a using (application_id) where a.submission_id = '00000000-0000-0000-0000-000000000205' and i.round_no = 1 and i.schedule_status_code = 'AVAILABLE' and i.report_status_code = 'INTERVIEW_SCHEDULING');

  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000205'::uuid],
    '00000000-0000-0000-0000-000000000301'::uuid,
    null,
    '00000000-0000-0000-0000-000000000304'::uuid,
    '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000904'::uuid
  ) into v_assignment_replay;
  assert v_assignment_replay = v_assignment;
  assert (select count(*) = 1 from public.applications where submission_id = '00000000-0000-0000-0000-000000000205');
  assert (select count(*) = 1 from public.activity_log l join public.applications a on a.application_id = l.entity_id where a.submission_id = '00000000-0000-0000-0000-000000000205'::uuid and l.request_id = '00000000-0000-0000-0000-000000000904'::uuid and l.entity_type = 'APPLICATION' and l.action_code = 'BULK_APPLICATION_ASSIGNMENT' and l.actor_app_user_id = '00000000-0000-0000-0000-000000000011'::uuid and l.old_values = '{"hr_owner_id":null,"version_no":null}'::jsonb and l.new_values = '{"hr_owner_id":"00000000-0000-0000-0000-000000000011","version_no":1,"action":"CREATED"}'::jsonb);
  assert (select actor_auth_user_id = '00000000-0000-0000-0000-000000000001'::uuid and actor_app_user_id = '00000000-0000-0000-0000-000000000011'::uuid and action_code = 'BULK_APPLICATION_ASSIGNMENT' and entity_type = 'BATCH' and entity_id = '00000000-0000-0000-0000-000000000904'::uuid and metadata -> 'selected_submission_ids' = '["00000000-0000-0000-0000-000000000205"]'::jsonb and metadata ->> 'request_fingerprint' = '630de6d75ff77a90e37fad37a3c5b07e81f35176fc8e671da83ad1edaf46c0d8' from public.security_audit_log where request_id = '00000000-0000-0000-0000-000000000904');

  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000205'::uuid],
    '00000000-0000-0000-0000-000000000301'::uuid,
    null,
    '00000000-0000-0000-0000-000000000304'::uuid,
    '00000000-0000-0000-0000-000000000012'::uuid,
    '00000000-0000-0000-0000-000000000904'::uuid
  ) into v_assignment_conflict;
  assert v_assignment_conflict ->> 'error_code' = 'VALIDATION_ERROR';
end;
$$;

-- Direct permission, authorization-before-validation, and input/error matrix.
set role authenticated;
do $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
  select public.bulk_set_latest_submission_manual_status(array[]::uuid[], null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'unprivileged user cannot set status';
  select public.bulk_create_or_update_applications(array[]::uuid[], null, null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'unprivileged user cannot assign';

  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);
  select public.bulk_set_latest_submission_manual_status(array[]::uuid[], null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'submissions.view alone is read-only';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
  select public.bulk_set_latest_submission_manual_status(array[]::uuid[], null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'HR role alone is insufficient';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', false);
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000110'::uuid], 'READ', array['00000000-0000-0000-0000-000000000210'::uuid], array[1::bigint], '00000000-0000-0000-0000-000000000950'::uuid) into r;
  assert r ->> 'success' = 'true', 'submissions.status permission executes directly';

  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000006', false);
  select public.bulk_create_or_update_applications(array[]::uuid[], null, null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'applications.create alone is insufficient';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000007', false);
  select public.bulk_create_or_update_applications(array[]::uuid[], null, null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'applications.manage without submissions.view is insufficient';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);
  select public.bulk_create_or_update_applications(array[]::uuid[], null, null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'submissions.view without applications.manage is insufficient';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
  select public.bulk_create_or_update_applications(array[]::uuid[], null, null, null, null, null) into r;
  assert r ->> 'error_code' = 'FORBIDDEN', 'HR role alone cannot assign';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000008', false);
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000211'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000951'::uuid) into r;
  assert r ->> 'success' = 'true', 'applications.manage plus submissions.view executes directly';

  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
  -- Root Admin wrapper: successful NEW, then the same idempotency key is actor-scoped.
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000110'::uuid], 'NEW',
    array['00000000-0000-0000-0000-000000000210'::uuid], array[2::bigint],
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'success' = 'true' and r #>> '{data,items,0,status_code}' = 'NEW', 'Root Admin can set NEW';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', false);
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000110'::uuid], 'READ',
    array['00000000-0000-0000-0000-000000000210'::uuid], array[3::bigint],
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'success' = 'true', 'idempotency key is actor-scoped';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000114'::uuid], 'READ',
    array['00000000-0000-0000-0000-000000000214'::uuid], array[1::bigint],
    '00000000-0000-0000-0000-000000000983'::uuid
  ) into r;
  assert r ->> 'error_code' = 'NOT_FOUND', 'Candidate without Submission is rejected';
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000115'::uuid, '00000000-0000-0000-0000-000000000105'::uuid], 'NEW',
    array['00000000-0000-0000-0000-000000000215'::uuid, '00000000-0000-0000-0000-000000000205'::uuid], array[1::bigint, 2::bigint],
    '00000000-0000-0000-0000-000000000984'::uuid
  ) into r;
  assert r ->> 'error_code' = 'INVALID_STATE', 'active Application rolls back multi-item status request';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000204'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null,
    '00000000-0000-0000-0000-000000000399'::uuid, '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000985'::uuid
  ) into r;
  assert r ->> 'error_code' = 'INVALID_HIERARCHY', 'mismatched Position is rejected';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000205'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null,
    '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000012'::uuid,
    '00000000-0000-0000-0000-000000000986'::uuid
  ) into r;
  assert r ->> 'success' = 'true' and r #>> '{data,items,0,action}' = 'UPDATED' and r #>> '{data,items,0,version_no}' = '2';
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000110'::uuid], 'NEW',
    array['00000000-0000-0000-0000-000000000210'::uuid], array[3::bigint],
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'expected row version fingerprint component is material';
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000110'::uuid], 'READ',
    array['00000000-0000-0000-0000-000000000210'::uuid], array[2::bigint],
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'target status fingerprint component is material';
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000101'::uuid], 'NEW',
    array['00000000-0000-0000-0000-000000000210'::uuid], array[2::bigint],
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'candidate fingerprint component is material';
  select public.bulk_set_latest_submission_manual_status(
    array['00000000-0000-0000-0000-000000000110'::uuid], 'NEW',
    array['00000000-0000-0000-0000-000000000209'::uuid], array[2::bigint],
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'expected Submission identity fingerprint component is material';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000214'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null,
    '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'success' = 'true', 'idempotency key is command-scoped';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000214'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null,
    '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000012'::uuid,
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'assignment owner fingerprint component is material';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000213'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null,
    '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'assignment selection fingerprint component is material';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000214'::uuid], '00000000-0000-0000-0000-000000000399'::uuid, null,
    '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'assignment unit fingerprint component is material';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000214'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, '00000000-0000-0000-0000-000000000302'::uuid,
    '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'assignment team fingerprint component is material';
  select public.bulk_create_or_update_applications(
    array['00000000-0000-0000-0000-000000000214'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null,
    '00000000-0000-0000-0000-000000000399'::uuid, '00000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000982'::uuid
  ) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR', 'assignment position fingerprint component is material';
  select public.bulk_set_latest_submission_manual_status(null, 'READ', null, null, '00000000-0000-0000-0000-000000000960'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array[]::uuid[], 'READ', array[]::uuid[], array[]::bigint[], '00000000-0000-0000-0000-000000000974'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], null, array['00000000-0000-0000-0000-000000000201'::uuid], array[2::bigint], '00000000-0000-0000-0000-000000000975'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], 'READ', null, array[2::bigint], '00000000-0000-0000-0000-000000000976'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], 'READ', array['00000000-0000-0000-0000-000000000201'::uuid], null, '00000000-0000-0000-0000-000000000977'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array[null::uuid], 'READ', array[null::uuid], array[null::bigint], '00000000-0000-0000-0000-000000000961'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid, '00000000-0000-0000-0000-000000000101'::uuid], 'READ', array['00000000-0000-0000-0000-000000000201'::uuid, '00000000-0000-0000-0000-000000000201'::uuid], array[2::bigint, 2::bigint], '00000000-0000-0000-0000-000000000962'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], 'READ', array['00000000-0000-0000-0000-000000000201'::uuid, '00000000-0000-0000-0000-000000000202'::uuid], array[2::bigint], '00000000-0000-0000-0000-000000000963'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], 'DONE', array['00000000-0000-0000-0000-000000000201'::uuid], array[2::bigint], '00000000-0000-0000-0000-000000000964'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], 'READ', array['00000000-0000-0000-0000-000000000201'::uuid], array[0::bigint], null) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], 'READ', array['00000000-0000-0000-0000-000000000201'::uuid], array[0::bigint], '00000000-0000-0000-0000-000000000987'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000101'::uuid], 'READ', array['00000000-0000-0000-0000-000000000201'::uuid], array[1::bigint], '00000000-0000-0000-0000-000000000965'::uuid) into r;
  assert r ->> 'error_code' = 'STALE_VERSION';
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000113'::uuid], 'READ', array['00000000-0000-0000-0000-000000000213'::uuid], array[1::bigint], '00000000-0000-0000-0000-000000000966'::uuid) into r;
  if r ->> 'error_code' <> 'STALE_VERSION' then
    raise exception 'historical Submission result: %', r;
  end if;
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000105'::uuid], 'READ', array['00000000-0000-0000-0000-000000000205'::uuid], array[2::bigint], '00000000-0000-0000-0000-000000000967'::uuid) into r;
  if r ->> 'error_code' <> 'INVALID_STATE' then
    raise exception 'active Application result: %', r;
  end if;
  select public.bulk_set_latest_submission_manual_status(array['00000000-0000-0000-0000-000000000112'::uuid], 'READ', array['00000000-0000-0000-0000-000000000212'::uuid], array[1::bigint], '00000000-0000-0000-0000-000000000968'::uuid) into r;
  if r ->> 'success' <> 'true' then
    raise exception 'inactive Candidate result: %', r;
  end if;

  select public.bulk_create_or_update_applications(null, '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000969'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array[null::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000970'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid, '00000000-0000-0000-0000-000000000204'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000971'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid], null, null, null, null, null) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array[]::uuid[], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000978'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid], null, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000979'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, null, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000980'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, null, '00000000-0000-0000-0000-000000000981'::uuid) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000204'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, null) into r;
  assert r ->> 'error_code' = 'VALIDATION_ERROR';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000999'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000972'::uuid) into r;
  assert r ->> 'error_code' = 'NOT_FOUND';
  select public.bulk_create_or_update_applications(array['00000000-0000-0000-0000-000000000215'::uuid], '00000000-0000-0000-0000-000000000301'::uuid, null, '00000000-0000-0000-0000-000000000304'::uuid, '00000000-0000-0000-0000-000000000011'::uuid, '00000000-0000-0000-0000-000000000973'::uuid) into r;
  assert r ->> 'error_code' = 'ALREADY_EXISTS_INACTIVE';
end;
$$;
reset role;
do $$
begin
  assert (select status_code = 'NEW' and version_no = 1 from public.submissions where submission_id = '00000000-0000-0000-0000-000000000215');
  assert (select status_code = 'PROCESSED' and version_no = 2 from public.submissions where submission_id = '00000000-0000-0000-0000-000000000205');
  assert (select count(*) = 0 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000984');
  assert (select count(*) = 0 from public.idempotency_records where idempotency_key = '00000000-0000-0000-0000-000000000984');
  assert (select count(*) = 1 from public.applications where submission_id = '00000000-0000-0000-0000-000000000205' and unit_id = '00000000-0000-0000-0000-000000000301'::uuid and position_id = '00000000-0000-0000-0000-000000000304'::uuid and hr_owner_id = '00000000-0000-0000-0000-000000000012'::uuid and version_no = 2);
  assert (select count(*) = 1 from public.interviews i join public.applications a using (application_id) where a.submission_id = '00000000-0000-0000-0000-000000000205' and i.round_no = 1);
end;
$$;

-- Force failure only after every durable command write, including idempotency storage.
create or replace function private.bulk_replay_fail_idempotency()
returns trigger language plpgsql as $$
begin
  if new.idempotency_key = '00000000-0000-0000-0000-000000000905'::uuid then
    raise exception 'forced bulk replay idempotency failure';
  end if;
  return new;
end;
$$;
create trigger bulk_replay_fail_idempotency
after insert on public.idempotency_records
for each row execute function private.bulk_replay_fail_idempotency();

do $$
declare v_ignored jsonb;
begin
  begin
    select public.bulk_create_or_update_applications(
      array['00000000-0000-0000-0000-000000000206'::uuid],
      '00000000-0000-0000-0000-000000000301'::uuid,
      null,
      '00000000-0000-0000-0000-000000000304'::uuid,
      '00000000-0000-0000-0000-000000000011'::uuid,
      '00000000-0000-0000-0000-000000000905'::uuid
    ) into v_ignored;
    raise exception 'forced failure was not raised';
  exception when others then
    if position('forced bulk replay idempotency failure' in sqlerrm) = 0 then raise; end if;
  end;
  assert (select count(*) = 0 from public.applications where submission_id = '00000000-0000-0000-0000-000000000206');
  assert (select count(*) = 0 from public.interviews i join public.applications a using (application_id) where a.submission_id = '00000000-0000-0000-0000-000000000206');
  assert (select status_code = 'NEW' and version_no = 1 from public.submissions where submission_id = '00000000-0000-0000-0000-000000000206');
  assert (select count(*) = 0 from public.activity_log where request_id = '00000000-0000-0000-0000-000000000905');
  assert (select count(*) = 0 from public.security_audit_log where request_id = '00000000-0000-0000-0000-000000000905');
  assert (select count(*) = 0 from public.idempotency_records where idempotency_key = '00000000-0000-0000-0000-000000000905');
end;
$$;
drop trigger bulk_replay_fail_idempotency on public.idempotency_records;
drop function private.bulk_replay_fail_idempotency();

-- Concurrency timing hook. It keeps parent/application locks held while peers arrive.
create or replace function private.bulk_replay_pause_submission()
returns trigger language plpgsql as $$
begin
  if new.submission_id in (
    '00000000-0000-0000-0000-000000000203'::uuid,
    '00000000-0000-0000-0000-000000000204'::uuid,
    '00000000-0000-0000-0000-000000000206'::uuid,
    '00000000-0000-0000-0000-000000000207'::uuid,
    '00000000-0000-0000-0000-000000000208'::uuid,
    '00000000-0000-0000-0000-000000000209'::uuid
  ) then
    perform pg_sleep(0.5);
  end if;
  return new;
end;
$$;
create trigger bulk_replay_pause_submission
before update on public.submissions
for each row execute function private.bulk_replay_pause_submission();

-- Seed direct-delete targets with structurally empty Round 1 records.
insert into public.applications (application_id, submission_id, unit_id, position_id, hr_owner_id)
values
  ('00000000-0000-0000-0000-000000000507', '00000000-0000-0000-0000-000000000207', '00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000304', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000508', '00000000-0000-0000-0000-000000000208', '00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000304', '00000000-0000-0000-0000-000000000011');
insert into public.interviews (interview_id, application_id, round_no, schedule_status_code, report_status_code)
values
  ('00000000-0000-0000-0000-000000000607', '00000000-0000-0000-0000-000000000507', 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING'),
  ('00000000-0000-0000-0000-000000000608', '00000000-0000-0000-0000-000000000508', 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING');
