-- =============================================================================
-- TASK-S06-002 Internal User / RBAC / Identity focused regression assertions
-- =============================================================================
\set ON_ERROR_STOP on
begin;

-- -----------------------------------------------------------------------------
-- 1. Canonical fixtures
-- -----------------------------------------------------------------------------
do $$
declare
  v_unit uuid := '80000000-0000-0000-0000-000000000001';
  v_group uuid := '80000000-0000-0000-0000-000000000002';
  v_position uuid := '80000000-0000-0000-0000-000000000003';
  v_format uuid := '80000000-0000-0000-0000-000000000004';
  v_candidate uuid := '80000000-0000-0000-0000-000000000005';
  v_submission uuid := '80000000-0000-0000-0000-000000000006';
  v_submission2 uuid := '80000000-0000-0000-0000-000000000007';
  v_app uuid := '80000000-0000-0000-0000-000000000008';
  v_interview uuid := '80000000-0000-0000-0000-000000000009';
begin
  insert into public.position_groups(position_group_id,name_vi,code,is_active)
  values(v_group,'S06-002 Group','S06_002_GROUP',true);

  insert into public.organizational_units(unit_id,name_vi,code,is_active)
  values(v_unit,'S06-002 Unit','S06_002_UNIT',true);

  insert into public.positions(position_id,unit_id,position_group_id,code,name_vi,is_active)
  values(v_position,v_unit,v_group,'S06_002_POSITION','S06-002 Position',true);

  insert into public.interview_formats(interview_format_id,code,name_vi,requires_room,requires_meeting_link,is_active)
  values(v_format,'S06_002_FORMAT','S06-002 Format',false,false,true);

  insert into public.app_users(app_user_id,auth_user_id,email,full_name,job_title,unit_id,is_active,is_root_admin)
  values
    ('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000001','root_s06_002@eiu.edu.vn','Root S06-002',null,v_unit,true,true),
    ('70000000-0000-0000-0000-000000000002','71000000-0000-0000-0000-000000000002','manager_s06_002@eiu.edu.vn','Manager S06-002','HR Manager',v_unit,true,false),
    ('70000000-0000-0000-0000-000000000003',null,'hrtarget_s06_002@eiu.edu.vn','HR Target S06-002',null,v_unit,true,false),
    ('70000000-0000-0000-0000-000000000004',null,'participant_s06_002@eiu.edu.vn','Participant S06-002','Interviewer',v_unit,true,false),
    ('70000000-0000-0000-0000-000000000005','71000000-0000-0000-0000-000000000005','bound_s06_002@eiu.edu.vn','Bound Directory Target',null,v_unit,true,false),
    ('70000000-0000-0000-0000-000000000010',null,'firstbind_s06_002@eiu.edu.vn','First Bind Target',null,v_unit,true,false),
    ('70000000-0000-0000-0000-000000000012',null,'nongoogle_s06_002@eiu.edu.vn','Non Google Target',null,v_unit,true,false),
    ('70000000-0000-0000-0000-000000000013',null,'unverified_s06_002@eiu.edu.vn','Unverified Target',null,v_unit,true,false),
    ('70000000-0000-0000-0000-000000000014',null,'inactivebind_s06_002@eiu.edu.vn','Inactive Bind Target',null,v_unit,false,false),
    ('70000000-0000-0000-0000-000000000015','72000000-0000-0000-0000-000000000007','collision_s06_002@eiu.edu.vn','Collision Owner',null,v_unit,true,false);

  insert into public.app_user_roles(app_user_id,role_code)
  values('70000000-0000-0000-0000-000000000002','HR');

  insert into public.app_user_permissions(app_user_id,permission_code,granted_by)
  values
    ('70000000-0000-0000-0000-000000000002','users.directory_read','70000000-0000-0000-0000-000000000001'),
    ('70000000-0000-0000-0000-000000000002','users.directory_manage','70000000-0000-0000-0000-000000000001');

  insert into public.candidates(candidate_id,email,current_full_name,is_active)
  values(v_candidate,'candidate_s06_002@example.com','Candidate S06-002',true);

  insert into public.submissions(
    submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,
    current_address,phone,email_snapshot,version_no
  ) values
    (v_submission,v_candidate,'READ','Candidate S06-002','1990-01-01','MALE','Address','0900000000','candidate_s06_002@example.com',1),
    (v_submission2,v_candidate,'READ','Candidate S06-002','1990-01-01','MALE','Address','0900000000','candidate_s06_002@example.com',1);

  insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active)
  values(v_app,v_submission,v_unit,v_position,'70000000-0000-0000-0000-000000000001',true);

  insert into public.interviews(
    interview_id,application_id,round_no,start_at,end_at,interview_format_id,
    schedule_status_code,report_status_code,is_active
  ) values(
    v_interview,v_app,1,clock_timestamp()+interval '1 day',clock_timestamp()+interval '1 day 1 hour',v_format,
    'AVAILABLE','FOLLOW_UP',true
  );

  insert into public.interview_participants(
    interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email,is_current
  ) values(
    v_interview,'70000000-0000-0000-0000-000000000004',1,
    'Participant S06-002','Interviewer','participant_s06_002@eiu.edu.vn',true
  );

  -- Auth fixtures used only for deterministic provider/confirmed-email checks.
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    ('72000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','firstbind_s06_002@eiu.edu.vn','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp()),
    ('72000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','nongoogle_s06_002@eiu.edu.vn','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp()),
    ('72000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated','unverified_s06_002@eiu.edu.vn','',null,'{}','{}',clock_timestamp(),clock_timestamp()),
    ('72000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000000','authenticated','authenticated','inactivebind_s06_002@eiu.edu.vn','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp()),
    ('72000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000000','authenticated','authenticated','notallowlisted_s06_002@eiu.edu.vn','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp()),
    ('72000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000000','authenticated','authenticated','replacement_s06_002@eiu.edu.vn','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp()),
    ('72000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000000','authenticated','authenticated','collision_s06_002@eiu.edu.vn','',clock_timestamp(),'{}','{}',clock_timestamp(),clock_timestamp());

  insert into auth.identities(provider_id,user_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values
    ('google-s06-002-001','72000000-0000-0000-0000-000000000001',jsonb_build_object('sub','google-s06-002-001','email','firstbind_s06_002@eiu.edu.vn'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp()),
    ('email-s06-002-002','72000000-0000-0000-0000-000000000002',jsonb_build_object('sub','email-s06-002-002','email','nongoogle_s06_002@eiu.edu.vn'),'email',clock_timestamp(),clock_timestamp(),clock_timestamp()),
    ('google-s06-002-003','72000000-0000-0000-0000-000000000003',jsonb_build_object('sub','google-s06-002-003','email','unverified_s06_002@eiu.edu.vn'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp()),
    ('google-s06-002-004','72000000-0000-0000-0000-000000000004',jsonb_build_object('sub','google-s06-002-004','email','inactivebind_s06_002@eiu.edu.vn'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp()),
    ('google-s06-002-005','72000000-0000-0000-0000-000000000005',jsonb_build_object('sub','google-s06-002-005','email','notallowlisted_s06_002@eiu.edu.vn'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp()),
    ('google-s06-002-006','72000000-0000-0000-0000-000000000006',jsonb_build_object('sub','google-s06-002-006','email','replacement_s06_002@eiu.edu.vn'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp()),
    ('google-s06-002-007','72000000-0000-0000-0000-000000000007',jsonb_build_object('sub','google-s06-002-007','email','collision_s06_002@eiu.edu.vn'),'google',clock_timestamp(),clock_timestamp(),clock_timestamp());
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Authentication / directory lifecycle / idempotency
-- -----------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_result jsonb;
  v_replay jsonb;
  v_created_id uuid;
  v_version bigint;
  v_audit_before integer;
  v_failed_key uuid := '90000000-0000-0000-0000-000000000003';
begin
  perform set_config('request.jwt.claim.sub','79999999-0000-0000-0000-000000000001',true);
  v_result := public.create_internal_user(
    jsonb_build_object('email','denied_s06_002@eiu.edu.vn','full_name','Denied'),
    '90000000-0000-0000-0000-000000000001'
  );
  assert v_result->>'error_code'='FORBIDDEN','missing Internal User actor must be denied';

  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000002',true);

  select count(*) into v_audit_before from public.security_audit_log where action_code='INTERNAL_USER_CREATE';
  v_result := public.create_internal_user(
    jsonb_build_object(
      'email','  New.Directory_S06_002@EIU.EDU.VN  ',
      'full_name',' New Directory User ',
      'job_title','Staff',
      'unit_id','80000000-0000-0000-0000-000000000001'
    ),
    '90000000-0000-0000-0000-000000000002'
  );
  assert (v_result->>'success')::boolean,'directory manager create must succeed';
  v_created_id := (v_result->'data'->>'app_user_id')::uuid;
  v_version := (v_result->'data'->>'version_no')::bigint;
  assert v_result->'data'->>'email'='new.directory_s06_002@eiu.edu.vn','email must normalize';
  assert (v_result->'data'->>'identity_bound')::boolean=false,'new directory user must be unbound';
  assert not exists(select 1 from public.app_user_roles r where r.app_user_id=v_created_id),'create must not add HR role';
  assert not exists(select 1 from public.app_user_permissions p where p.app_user_id=v_created_id),'create must not add permissions';
  assert (select count(*) from public.security_audit_log where action_code='INTERNAL_USER_CREATE')=v_audit_before+1,'create audit required';

  v_replay := public.create_internal_user(
    jsonb_build_object(
      'email','new.directory_s06_002@eiu.edu.vn','full_name','New Directory User','job_title','Staff',
      'unit_id','80000000-0000-0000-0000-000000000001'
    ),
    '90000000-0000-0000-0000-000000000002'
  );
  assert v_replay=v_result,'exact create replay must return stored safe result';
  assert (select count(*) from public.security_audit_log where action_code='INTERNAL_USER_CREATE')=v_audit_before+1,'create replay must not duplicate audit';

  begin
    perform public.create_internal_user(
      jsonb_build_object('email','new.directory_s06_002@eiu.edu.vn','full_name','DIFFERENT'),
      '90000000-0000-0000-0000-000000000002'
    );
    raise exception 'expected idempotency payload mismatch';
  exception
    when check_violation then
      assert sqlerrm like '%IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD%';
  end;

  v_result := public.create_internal_user(
    jsonb_build_object('email','external@example.com','full_name','External'),
    v_failed_key
  );
  assert v_result->>'error_code'='VALIDATION_ERROR','non-EIU create must fail';
  assert not exists(select 1 from public.idempotency_records r where r.idempotency_key=v_failed_key),'failed create must not record success replay';

  v_result := public.create_internal_user(
    jsonb_build_object('email','protected_s06_002@eiu.edu.vn','full_name','Protected','is_root_admin',true),
    '90000000-0000-0000-0000-000000000004'
  );
  assert v_result->>'error_code'='VALIDATION_ERROR','protected/unknown create field must fail';
  assert not exists(select 1 from public.app_users u where lower(u.email::text)='protected_s06_002@eiu.edu.vn'),'protected create must have no partial row';

  v_result := public.create_internal_user(
    jsonb_build_object('email','new.directory_s06_002@eiu.edu.vn','full_name','Duplicate'),
    '90000000-0000-0000-0000-000000000005'
  );
  assert v_result->>'error_code'='VALIDATION_ERROR','duplicate email create must fail';

  v_result := public.update_internal_user_directory(
    v_created_id,
    jsonb_build_object('email','corrected.directory_s06_002@eiu.edu.vn','job_title','Updated Staff'),
    v_version,
    '90000000-0000-0000-0000-000000000006'
  );
  assert (v_result->>'success')::boolean,'unbound email correction must succeed';
  v_version := (v_result->'data'->>'version_no')::bigint;
  assert v_result->'data'->>'email'='corrected.directory_s06_002@eiu.edu.vn';

  v_result := public.update_internal_user_directory(
    v_created_id,jsonb_build_object('full_name','Stale Attempt'),1,
    '90000000-0000-0000-0000-000000000007'
  );
  assert v_result->>'error_code'='STALE_VERSION','stale directory update must fail';

  v_result := public.update_internal_user_directory(
    '70000000-0000-0000-0000-000000000005',
    jsonb_build_object('email','bound_changed_s06_002@eiu.edu.vn'),
    1,
    '90000000-0000-0000-0000-000000000008'
  );
  assert v_result->>'error_code'='IDENTITY_REBIND_FORBIDDEN','bound email must be identity-protected';

  v_result := public.update_internal_user_directory(
    v_created_id,jsonb_build_object('is_active',false),v_version,
    '90000000-0000-0000-0000-000000000009'
  );
  assert v_result->>'error_code'='VALIDATION_ERROR','directory profile command must not mutate lifecycle';

  v_result := public.set_internal_user_active(
    v_created_id,false,v_version,'90000000-0000-0000-0000-000000000010'
  );
  assert (v_result->>'success')::boolean and (v_result->'data'->>'is_active')::boolean=false,'eligible ordinary user deactivation must succeed';
  v_version := (v_result->'data'->>'version_no')::bigint;

  v_replay := public.set_internal_user_active(
    v_created_id,false,(v_result->'data'->>'version_no')::bigint - 1,'90000000-0000-0000-0000-000000000010'
  );
  assert v_replay=v_result,'lifecycle exact replay returns committed result before stale check';

  v_result := public.set_internal_user_active(
    v_created_id,true,v_version,'90000000-0000-0000-0000-000000000011'
  );
  assert (v_result->>'success')::boolean and (v_result->'data'->>'is_active')::boolean=true,'eligible ordinary user reactivation must succeed';

  v_result := public.set_internal_user_active(
    '70000000-0000-0000-0000-000000000002',false,
    (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000002'),
    '90000000-0000-0000-0000-000000000012'
  );
  assert v_result->>'error_code'='FORBIDDEN','non-root may not deactivate HR/self HR target';

  v_result := public.set_internal_user_active(
    '70000000-0000-0000-0000-000000000001',false,
    (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000001'),
    '90000000-0000-0000-0000-000000000013'
  );
  assert v_result->>'error_code'='ROOT_ADMIN_PROTECTED','Root must remain protected';
end;
$$;
reset role;

-- anon cannot execute mutation RPCs at all.
set local role anon;
do $$
begin
  begin
    perform public.create_internal_user(
      jsonb_build_object('email','anon_s06_002@eiu.edu.vn','full_name','Anon'),
      '90000000-0000-0000-0000-000000000014'
    );
    raise exception 'anon unexpectedly executed directory mutation';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;

-- -----------------------------------------------------------------------------
-- 3. Root-only HR role / granular permission administration
-- -----------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_result jsonb;
  v_replay jsonb;
  v_version bigint;
  v_audit_count integer;
begin
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000001',true);
  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000003');
  v_result := public.assign_hr_role_with_defaults(
    '70000000-0000-0000-0000-000000000003',v_version,
    '90000000-0000-0000-0000-000000000020'
  );
  assert (v_result->>'success')::boolean,'Root HR assignment must succeed';
  assert (select count(*) from public.app_user_permissions where app_user_id='70000000-0000-0000-0000-000000000003')=23,'Full HR defaults must contain 23 canonical codes';
  assert exists(select 1 from public.app_user_permissions where app_user_id='70000000-0000-0000-0000-000000000003' and permission_code='applications.view'),'Full HR defaults must include applications.view';
  assert not exists(select 1 from public.app_user_permissions where app_user_id='70000000-0000-0000-0000-000000000003' and permission_code in ('candidates.identity_manage','users.identity_manage','users.permissions_manage')),'default HR set must exclude security/recovery codes';
  select count(*) into v_audit_count from public.security_audit_log where action_code='HR_ROLE_ASSIGN_WITH_DEFAULTS' and entity_id='70000000-0000-0000-0000-000000000003';

  v_replay := public.assign_hr_role_with_defaults(
    '70000000-0000-0000-0000-000000000003',v_version,
    '90000000-0000-0000-0000-000000000020'
  );
  assert v_replay=v_result,'HR assignment replay must return stored result';
  assert (select count(*) from public.security_audit_log where action_code='HR_ROLE_ASSIGN_WITH_DEFAULTS' and entity_id='70000000-0000-0000-0000-000000000003')=v_audit_count,'HR assignment replay must not duplicate audit';

  begin
    perform public.assign_hr_role_with_defaults(
