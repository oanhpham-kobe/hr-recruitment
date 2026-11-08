      '70000000-0000-0000-0000-000000000003',v_version+1,
      '90000000-0000-0000-0000-000000000020'
    );
    raise exception 'expected HR assignment idempotency mismatch';
  exception when check_violation then
    assert sqlerrm like '%IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD%';
  end;

  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000003');
  v_result := public.grant_hr_permission(
    '70000000-0000-0000-0000-000000000003','candidates.identity_manage',v_version,
    '90000000-0000-0000-0000-000000000021'
  );
  assert (v_result->>'success')::boolean,'explicit delegable Candidate identity permission may be granted';
  assert exists(select 1 from public.app_user_permissions where app_user_id='70000000-0000-0000-0000-000000000003' and permission_code='candidates.identity_manage');

  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000003');
  v_result := public.grant_hr_permission(
    '70000000-0000-0000-0000-000000000003','users.identity_manage',v_version,
    '90000000-0000-0000-0000-000000000022'
  );
  assert v_result->>'error_code'='FORBIDDEN','Root-only Internal User identity permission must not be delegable';

  v_result := public.revoke_hr_permission(
    '70000000-0000-0000-0000-000000000003','applications.view',v_version,
    '90000000-0000-0000-0000-000000000023'
  );
  assert v_result->>'error_code'='INVALID_PERMISSION_DEPENDENCY','cannot revoke prerequisite while applications.manage remains';
end;
$$;
reset role;

-- Add active and historical Application ownership after the target is an HR.
do $$
begin
  insert into public.applications(
    application_id,submission_id,unit_id,position_id,hr_owner_id,is_active
  ) values(
    '80000000-0000-0000-0000-000000000010','80000000-0000-0000-0000-000000000007',
    '80000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000003',
    '70000000-0000-0000-0000-000000000003',true
  );

  insert into public.applications(
    application_id,submission_id,unit_id,position_id,hr_owner_id,is_active
  ) values(
    '80000000-0000-0000-0000-000000000011','80000000-0000-0000-0000-000000000006',
    '80000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000003',
    '70000000-0000-0000-0000-000000000003',false
  );
end;
$$;

-- Read minimization while target still owns granular HR permissions.
set local role authenticated;
do $$
declare
  v_count integer;
  v_directory_count integer;
begin
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000002',true);
  select count(*) into v_count
  from public.app_user_permissions
  where app_user_id='70000000-0000-0000-0000-000000000003';
  assert v_count=0,'non-root directory manager must not enumerate another user granular permissions';

  select count(*) into v_count from public.app_users where app_user_id='70000000-0000-0000-0000-000000000003';
  assert v_count=1,'directory manager must retain safe-column directory visibility';

  assert has_column_privilege('authenticated','public.app_users','full_name','SELECT'),
    'authenticated safe directory columns must remain selectable';
  assert not has_column_privilege('authenticated','public.app_users','auth_user_id','SELECT'),
    'authenticated must not receive raw Internal User Auth binding visibility';
  begin
    perform auth_user_id
    from public.app_users
    where app_user_id='70000000-0000-0000-0000-000000000003';
    raise exception 'raw auth_user_id unexpectedly readable by authenticated role';
  exception
    when insufficient_privilege then null;
  end;

  select count(*) into v_directory_count
  from public.list_internal_user_directory(true) d
  where d.app_user_id='70000000-0000-0000-0000-000000000014' and d.is_active=false;
  assert v_directory_count=1,'directory manager projection must include eligible inactive users';

  select count(*) into v_count
  from public.app_user_permissions
  where app_user_id='70000000-0000-0000-0000-000000000002';
  assert v_count=2,'own permission read must remain valid';

  begin
    insert into public.app_user_roles(app_user_id,role_code)
    values('70000000-0000-0000-0000-000000000004','HR');
    raise exception 'authenticated direct RBAC DML unexpectedly succeeded';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;

set local role authenticated;
do $$
declare v_count integer;
begin
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000001',true);
  select count(*) into v_count
  from public.app_user_permissions
  where app_user_id='70000000-0000-0000-0000-000000000003';
  assert v_count=24,'Root must retain full granular permission administration visibility';
end;
$$;
reset role;

-- -----------------------------------------------------------------------------
-- 4. Lifecycle blockers: active owner and non-elapsed resource participant
-- -----------------------------------------------------------------------------
set local role authenticated;
do $$
declare v_result jsonb; v_version bigint;
begin
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000001',true);

  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000003');
  v_result := public.set_internal_user_active(
    '70000000-0000-0000-0000-000000000003',false,v_version,
    '90000000-0000-0000-0000-000000000030'
  );
  assert v_result->>'error_code'='ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED','active Application owner deactivation must block';

  v_result := public.remove_hr_role(
    '70000000-0000-0000-0000-000000000003',v_version,
    '90000000-0000-0000-0000-000000000031'
  );
  assert v_result->>'error_code'='ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED','HR role removal must block while active ownership remains';

  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000004');
  v_result := public.set_internal_user_active(
    '70000000-0000-0000-0000-000000000004',false,v_version,
    '90000000-0000-0000-0000-000000000032'
  );
  assert v_result->>'error_code'='FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED','future resource-blocking current participant deactivation must block';
end;
$$;
reset role;

-- Remove the live blockers using accepted trusted-state equivalents as postgres fixture setup.
update public.applications
set hr_owner_id='70000000-0000-0000-0000-000000000001'
where application_id='80000000-0000-0000-0000-000000000010';

update public.interviews
set start_at=clock_timestamp()-interval '2 hours',
    end_at=clock_timestamp()-interval '1 hour'
where interview_id='80000000-0000-0000-0000-000000000009';

set local role authenticated;
do $$
declare v_result jsonb; v_version bigint;
begin
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000001',true);

  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000004');
  v_result := public.set_internal_user_active(
    '70000000-0000-0000-0000-000000000004',false,v_version,
    '90000000-0000-0000-0000-000000000033'
  );
  assert (v_result->>'success')::boolean,'elapsed historical participant must not permanently block deactivation';

  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000003');
  v_result := public.remove_hr_role(
    '70000000-0000-0000-0000-000000000003',v_version,
    '90000000-0000-0000-0000-000000000034'
  );
  assert (v_result->>'success')::boolean,'HR role removal succeeds after active owner reassignment';
  assert not exists(select 1 from public.app_user_roles where app_user_id='70000000-0000-0000-0000-000000000003' and role_code='HR');
  assert not exists(select 1 from public.app_user_permissions where app_user_id='70000000-0000-0000-0000-000000000003');
  assert exists(
    select 1 from public.applications
    where application_id='80000000-0000-0000-0000-000000000011'
      and hr_owner_id='70000000-0000-0000-0000-000000000003'
      and is_active=false
  ),'historical inactive ownership must be preserved';
end;
$$;
reset role;

-- -----------------------------------------------------------------------------
-- 5. First Google login and Root-only non-Root identity change
-- -----------------------------------------------------------------------------
set local role authenticated;
do $$
declare v_result jsonb; v_replay jsonb; v_audit_count integer;
begin
  perform set_config('request.jwt.claim.sub','72000000-0000-0000-0000-000000000001',true);
  v_result := public.provision_internal_identity_on_first_google_login();
  assert (v_result->>'success')::boolean,'verified Google + Active allowlist first bind must succeed';
  assert (select auth_user_id from public.app_users where app_user_id='70000000-0000-0000-0000-000000000010')='72000000-0000-0000-0000-000000000001';
  select count(*) into v_audit_count
  from public.security_audit_log
  where action_code='INTERNAL_IDENTITY_FIRST_BIND' and entity_id='70000000-0000-0000-0000-000000000010';
  assert v_audit_count=1,'first bind audit exactly once';

  v_replay := public.provision_internal_identity_on_first_google_login();
  assert v_replay=v_result,'exact first-login replay returns same safe identity result';
  assert (select count(*) from public.security_audit_log where action_code='INTERNAL_IDENTITY_FIRST_BIND' and entity_id='70000000-0000-0000-0000-000000000010')=1,'first-login replay must not duplicate audit';

  v_replay := public.provision_internal_user_identity();
  assert v_replay=v_result,'accepted Slice-01 function name must be a compatibility wrapper to canonical bind path';
  assert (select count(*) from public.security_audit_log where action_code='INTERNAL_IDENTITY_FIRST_BIND' and entity_id='70000000-0000-0000-0000-000000000010')=1,'compatibility wrapper replay must not duplicate audit';

  perform set_config('request.jwt.claim.sub','72000000-0000-0000-0000-000000000002',true);
  v_result := public.provision_internal_identity_on_first_google_login();
  assert v_result->>'error_code'='FORBIDDEN','non-Google identity must fail closed';

  perform set_config('request.jwt.claim.sub','72000000-0000-0000-0000-000000000003',true);
  v_result := public.provision_internal_identity_on_first_google_login();
  assert v_result->>'error_code'='FORBIDDEN','unverified Google email must fail closed';

  perform set_config('request.jwt.claim.sub','72000000-0000-0000-0000-000000000004',true);
  v_result := public.provision_internal_identity_on_first_google_login();
  assert v_result->>'error_code'='USER_INACTIVE','inactive allowlist must fail closed';

  perform set_config('request.jwt.claim.sub','72000000-0000-0000-0000-000000000005',true);
  v_result := public.provision_internal_identity_on_first_google_login();
  assert v_result->>'error_code'='NOT_FOUND','verified Google identity without allowlist must fail';
end;
$$;
reset role;

set local role authenticated;
do $$
declare v_result jsonb; v_version bigint;
begin
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000001',true);

  v_version := (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000005');
  v_result := public.change_internal_user_identity(
    '70000000-0000-0000-0000-000000000005','72000000-0000-0000-0000-000000000006',v_version,
    '90000000-0000-0000-0000-000000000040'
  );
  assert (v_result->>'success')::boolean,'Root non-Root identity rebind must succeed for verified Google replacement';
  assert (select auth_user_id from public.app_users where app_user_id='70000000-0000-0000-0000-000000000005')='72000000-0000-0000-0000-000000000006';
  assert (select lower(email::text) from public.app_users where app_user_id='70000000-0000-0000-0000-000000000005')='replacement_s06_002@eiu.edu.vn';
  assert not exists(select 1 from public.app_users where auth_user_id='71000000-0000-0000-0000-000000000005'),'old Auth mapping must stop resolving after rebind';

  v_result := public.change_internal_user_identity(
    '70000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000006',
    (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000001'),
    '90000000-0000-0000-0000-000000000041'
  );
  assert v_result->>'error_code'='ROOT_ADMIN_PROTECTED','Root identity ordinary rebind must be rejected';

  -- Collision target is already owned by another Internal User.
  v_result := public.change_internal_user_identity(
    '70000000-0000-0000-0000-000000000005','72000000-0000-0000-0000-000000000007',
    (select version_no from public.app_users where app_user_id='70000000-0000-0000-0000-000000000005'),
    '90000000-0000-0000-0000-000000000042'
  );
  assert v_result->>'error_code'='IDENTITY_REBIND_FORBIDDEN','cross-row replacement Auth/email collision must fail closed';
end;
$$;
reset role;

-- -----------------------------------------------------------------------------
-- 6. Static ACL / SECURITY DEFINER / search_path assertions
-- -----------------------------------------------------------------------------
do $$
declare
  v_expected text[] := array[
    'create_internal_user','update_internal_user_directory','set_internal_user_active',
    'assign_hr_role_with_defaults','remove_hr_role','grant_hr_permission','revoke_hr_permission',
    'provision_internal_identity_on_first_google_login','provision_internal_user_identity',
    'change_internal_user_identity','get_current_internal_session','list_internal_user_directory','list_internal_user_selector'
  ];
  v_name text;
begin
  foreach v_name in array v_expected loop
    assert exists(
      select 1
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=v_name and p.prosecdef=true
    ), v_name || ' must be SECURITY DEFINER';

    assert not exists(
      select 1
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=v_name
        and not exists(
          select 1 from unnest(coalesce(p.proconfig,array[]::text[])) cfg
          where cfg like 'search_path=%'
        )
    ), v_name || ' must pin search_path';

    assert not exists(
      select 1
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=v_name
        and has_function_privilege('anon',p.oid,'EXECUTE')
    ), v_name || ' must not be executable by anon';
  end loop;

  assert not has_function_privilege('authenticated','private.lock_internal_user_ids(uuid[])','EXECUTE'),
    'authenticated must not execute private Internal User lock helper';
  assert not has_function_privilege('authenticated','private.verified_google_auth_email(uuid)','EXECUTE'),
    'authenticated must not execute private Auth evidence helper';
end;
$$;

raise notice 'TASK-S06-002 focused Internal User/RBAC/identity regressions PASS';
rollback;
