-- TASK-S06-001 R4: master_data.manage can read active and inactive managed lookup rows.
\set ON_ERROR_STOP on

begin;

select 'S06001_READ_' || substr(gen_random_uuid()::text,1,8) as suffix \gset
select set_config('s06.test_suffix', :'suffix', true);

insert into public.app_users(auth_user_id, email, full_name, is_active)
values (gen_random_uuid(), 's06001_read_manager_' || substr(gen_random_uuid()::text,1,8) || '@eiu.edu.vn', 'S06 Read Manager', true)
returning app_user_id as manager_id, auth_user_id as manager_auth \gset

insert into public.app_user_permissions(app_user_id, permission_code)
values (:'manager_id'::uuid, 'master_data.manage');

insert into public.app_users(auth_user_id, email, full_name, is_active)
values (gen_random_uuid(), 's06001_read_none_' || substr(gen_random_uuid()::text,1,8) || '@eiu.edu.vn', 'S06 Read No Permission', true)
returning app_user_id as no_perm_id, auth_user_id as no_perm_auth \gset

insert into public.recruitment_sources(code, name_vi, is_active)
values
  ('SRC_ACTIVE_' || :'suffix', 'Active source', true),
  ('SRC_INACTIVE_' || :'suffix', 'Inactive source', false);

insert into public.document_types(code, name_vi, scope_code, is_active)
values
  ('DOC_ACTIVE_' || :'suffix', 'Active document', 'SUBMISSION', true),
  ('DOC_INACTIVE_' || :'suffix', 'Inactive document', 'SUBMISSION', false);

insert into public.qualification_levels(code, name_vi, is_active)
values
  ('QUAL_ACTIVE_' || :'suffix', 'Active qualification', true),
  ('QUAL_INACTIVE_' || :'suffix', 'Inactive qualification', false);

select set_config('request.jwt.claims', jsonb_build_object('sub', :'manager_auth')::text, true);
set local role authenticated;

do $$
declare
  v_suffix text := current_setting('s06.test_suffix');
begin
  assert (select count(*) from public.recruitment_sources where code in ('SRC_ACTIVE_' || v_suffix, 'SRC_INACTIVE_' || v_suffix)) = 2,
    'manage-only actor must read active and inactive Recruitment Sources';
  assert (select count(*) from public.document_types where code in ('DOC_ACTIVE_' || v_suffix, 'DOC_INACTIVE_' || v_suffix)) = 2,
    'manage-only actor must read active and inactive Document Types';
  assert (select count(*) from public.qualification_levels where code in ('QUAL_ACTIVE_' || v_suffix, 'QUAL_INACTIVE_' || v_suffix)) = 2,
    'manage-only actor must read active and inactive Qualification Levels';
end;
$$;

reset role;
select set_config('request.jwt.claims', jsonb_build_object('sub', :'no_perm_auth')::text, true);
set local role authenticated;

do $$
declare
  v_suffix text := current_setting('s06.test_suffix');
begin
  assert (select count(*) from public.recruitment_sources where code = 'SRC_ACTIVE_' || v_suffix) = 1;
  assert (select count(*) from public.recruitment_sources where code = 'SRC_INACTIVE_' || v_suffix) = 0,
    'authenticated actor without permission must not read inactive Recruitment Source';
  assert (select count(*) from public.document_types where code = 'DOC_ACTIVE_' || v_suffix) = 1;
  assert (select count(*) from public.document_types where code = 'DOC_INACTIVE_' || v_suffix) = 0,
    'authenticated actor without permission must not read inactive Document Type';
  assert (select count(*) from public.qualification_levels where code = 'QUAL_ACTIVE_' || v_suffix) = 1;
  assert (select count(*) from public.qualification_levels where code = 'QUAL_INACTIVE_' || v_suffix) = 0,
    'authenticated actor without permission must not read inactive Qualification Level';
end;
$$;

reset role;
select set_config('request.jwt.claims', '{}'::jsonb::text, true);
set local role anon;

do $$
declare
  v_suffix text := current_setting('s06.test_suffix');
begin
  assert (select count(*) from public.recruitment_sources where code = 'SRC_ACTIVE_' || v_suffix) = 1;
  assert (select count(*) from public.recruitment_sources where code = 'SRC_INACTIVE_' || v_suffix) = 0,
    'anon lookup remains active-only for Recruitment Sources';
  assert (select count(*) from public.document_types where code = 'DOC_ACTIVE_' || v_suffix) = 1;
  assert (select count(*) from public.document_types where code = 'DOC_INACTIVE_' || v_suffix) = 0,
    'anon lookup remains active-only for Document Types';
  assert (select count(*) from public.qualification_levels where code = 'QUAL_ACTIVE_' || v_suffix) = 1;
  assert (select count(*) from public.qualification_levels where code = 'QUAL_INACTIVE_' || v_suffix) = 0,
    'anon lookup remains active-only for Qualification Levels';
end;
$$;

reset role;
rollback;
