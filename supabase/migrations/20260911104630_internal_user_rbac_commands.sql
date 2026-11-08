-- TASK-S06-002 / Part 3: Root-only HR role and granular permission administration.
-- Depends on prior TASK-S06-002 serialization/directory migrations.

-- -----------------------------------------------------------------------------
-- 5. Canonical HR permission classification and Root-only RBAC commands
-- -----------------------------------------------------------------------------
create or replace function private.default_hr_permission_codes()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'submissions.view','submissions.edit','submissions.status',
    'candidates.active_manage','candidates.delete_unused',
    'applications.view','applications.manage',
    'interviews.view','interviews.manage','interviews.status','interviews.participants','interviews.documents','interviews.email',
    'emails.history_view','emails.history_delete',
    'reports.view','reports.manage_status','reports.visibility','reports.edit_interviewer','reports.delete',
    'master_data.manage','users.directory_read','users.directory_manage'
  ]::text[];
$$;

create or replace function private.is_delegable_hr_permission(p_permission_code text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_permission_code = any(
    private.default_hr_permission_codes()
    || array['candidates.identity_manage']::text[]
  );
$$;

revoke all on function private.default_hr_permission_codes() from public, anon, authenticated;
revoke all on function private.is_delegable_hr_permission(text) from public, anon, authenticated;
grant execute on function private.default_hr_permission_codes() to postgres, service_role;
grant execute on function private.is_delegable_hr_permission(text) to postgres, service_role;

create or replace function public.assign_hr_role_with_defaults(
  p_target_user_id uuid,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_target public.app_users%rowtype;
  v_defaults text[] := private.default_hr_permission_codes();
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_result jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;
  v_actor := private.current_app_user_id();
  if v_actor is null or not private.is_root_admin() then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;
  if p_target_user_id is null
     or p_expected_version_no is null
     or p_expected_version_no <= 0
     or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  v_scope := 'app_user:' || v_actor::text || ':target:' || p_target_user_id::text;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'command','assign_hr_role_with_defaults',
    'target_user_id',p_target_user_id,
    'expected_version_no',p_expected_version_no,
    'default_permissions',to_jsonb(v_defaults)
  )::text,'sha256'),'hex');
  v_existing := private.check_idempotency(v_scope, 'assign_hr_role_with_defaults', p_idempotency_key, v_fingerprint);
  if v_existing is not null then return v_existing; end if;

  select * into v_target
  from public.app_users u
  where u.app_user_id = p_target_user_id
  for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_target.version_no <> p_expected_version_no then
    return jsonb_build_object('success',false,'error_code','STALE_VERSION');
  end if;
  if v_target.is_root_admin then
    return jsonb_build_object('success',false,'error_code','ROOT_ADMIN_PROTECTED');
  end if;
  if not v_target.is_active then
    return jsonb_build_object('success',false,'error_code','USER_INACTIVE');
  end if;

  perform private.lock_internal_user_ids(array[p_target_user_id]);

  if exists (
    select 1 from public.app_user_roles r
    where r.app_user_id = p_target_user_id and r.role_code = 'HR'
  ) then
    return jsonb_build_object('success',false,'error_code','INVALID_STATE');
  end if;

  if exists (
    select 1
    from unnest(v_defaults) x(permission_code)
    where not exists (
      select 1 from public.permissions p where p.permission_code = x.permission_code
    )
  ) then
    return jsonb_build_object('success',false,'error_code','INVALID_STATE','message','Canonical HR permission catalog is incomplete');
  end if;

  if exists (
    select 1
    from public.permission_dependencies d
    where d.permission_code = any(v_defaults)
      and not (d.requires_permission_code = any(v_defaults))
  ) then
    return jsonb_build_object('success',false,'error_code','INVALID_PERMISSION_DEPENDENCY');
  end if;

  insert into public.app_user_roles(app_user_id, role_code)
  values (p_target_user_id, 'HR');

  insert into public.app_user_permissions(app_user_id, permission_code, granted_by, granted_at)
  select p_target_user_id, p.permission_code, v_actor, clock_timestamp()
  from public.permissions p
  where p.permission_code = any(v_defaults)
  order by p.permission_code
  on conflict (app_user_id, permission_code) do nothing;

  update public.app_users
  set updated_at = clock_timestamp()
  where app_user_id = p_target_user_id
  returning * into v_target;

  insert into public.security_audit_log(
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
    request_id, source_code, result_code, metadata
  ) values (
    auth.uid(), v_actor, 'HR_ROLE_ASSIGN_WITH_DEFAULTS', 'APP_USER', p_target_user_id,
    p_idempotency_key, 'RPC', 'SUCCESS',
    jsonb_build_object(
      'role_code','HR',
      'default_permission_count',cardinality(v_defaults),
      'excluded_permissions',jsonb_build_array('candidates.identity_manage','users.identity_manage','users.permissions_manage')
    )
  );

  v_result := jsonb_build_object('success',true,'data',jsonb_build_object(
    'app_user_id',p_target_user_id,
    'is_hr',true,
    'default_permission_count',cardinality(v_defaults),
    'version_no',v_target.version_no
  ));
  perform private.record_idempotency(
    v_scope, 'assign_hr_role_with_defaults', p_idempotency_key, v_fingerprint,
    v_result, 'APP_USER', p_target_user_id
  );
  return v_result;
end;
$$;

create or replace function public.remove_hr_role(
  p_target_user_id uuid,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_target public.app_users%rowtype;
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_revoked_count integer;
  v_result jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED');
  end if;
  v_actor := private.current_app_user_id();
  if v_actor is null or not private.is_root_admin() then
    return jsonb_build_object('success',false,'error_code','FORBIDDEN');
  end if;
  if p_target_user_id is null or p_expected_version_no is null or p_expected_version_no <= 0 or p_idempotency_key is null then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR');
  end if;

  v_scope := 'app_user:' || v_actor::text || ':target:' || p_target_user_id::text;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'command','remove_hr_role','target_user_id',p_target_user_id,'expected_version_no',p_expected_version_no
  )::text,'sha256'),'hex');
  v_existing := private.check_idempotency(v_scope, 'remove_hr_role', p_idempotency_key, v_fingerprint);
  if v_existing is not null then return v_existing; end if;

  select * into v_target from public.app_users u where u.app_user_id=p_target_user_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_target.version_no <> p_expected_version_no then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_target.is_root_admin then return jsonb_build_object('success',false,'error_code','ROOT_ADMIN_PROTECTED'); end if;

  perform private.lock_internal_user_ids(array[p_target_user_id]);

  if not exists (
    select 1 from public.app_user_roles r where r.app_user_id=p_target_user_id and r.role_code='HR'
  ) then
    return jsonb_build_object('success',false,'error_code','INVALID_STATE');
  end if;

  if exists (
    select 1 from public.applications a where a.hr_owner_id=p_target_user_id and a.is_active=true
  ) then
    return jsonb_build_object('success',false,'error_code','ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
  end if;

  delete from public.app_user_permissions p where p.app_user_id=p_target_user_id;
  get diagnostics v_revoked_count = row_count;

  begin
    delete from public.app_user_roles r
    where r.app_user_id=p_target_user_id and r.role_code='HR';
  exception
    when check_violation then
      if sqlerrm like '%ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED%' then
        return jsonb_build_object('success',false,'error_code','ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
      end if;
      raise;
  end;

  update public.app_users
  set updated_at=clock_timestamp()
  where app_user_id=p_target_user_id
  returning * into v_target;

  insert into public.security_audit_log(
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
    request_id, source_code, result_code, metadata
  ) values (
    auth.uid(),v_actor,'HR_ROLE_REMOVE','APP_USER',p_target_user_id,
    p_idempotency_key,'RPC','SUCCESS',jsonb_build_object(
      'role_code','HR','revoked_permission_count',v_revoked_count
    )
  );

  v_result := jsonb_build_object('success',true,'data',jsonb_build_object(
    'app_user_id',p_target_user_id,'is_hr',false,'revoked_permission_count',v_revoked_count,'version_no',v_target.version_no
  ));
  perform private.record_idempotency(v_scope,'remove_hr_role',p_idempotency_key,v_fingerprint,v_result,'APP_USER',p_target_user_id);
  return v_result;
end;
$$;

create or replace function public.grant_hr_permission(
  p_target_user_id uuid,
  p_permission_code text,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_target public.app_users%rowtype;
  v_permission text := lower(btrim(coalesce(p_permission_code,'')));
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_inserted integer;
  v_result jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED'); end if;
  v_actor := private.current_app_user_id();
  if v_actor is null or not private.is_root_admin() then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
  if p_target_user_id is null or v_permission='' or p_expected_version_no is null or p_expected_version_no<=0 or p_idempotency_key is null then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR');
  end if;
  if not private.is_delegable_hr_permission(v_permission)
     or not exists(select 1 from public.permissions p where p.permission_code=v_permission) then
    return jsonb_build_object('success',false,'error_code','FORBIDDEN');
  end if;

  v_scope := 'app_user:'||v_actor::text||':target:'||p_target_user_id::text;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'command','grant_hr_permission','target_user_id',p_target_user_id,'permission_code',v_permission,'expected_version_no',p_expected_version_no
  )::text,'sha256'),'hex');
  v_existing := private.check_idempotency(v_scope,'grant_hr_permission',p_idempotency_key,v_fingerprint);
  if v_existing is not null then return v_existing; end if;

  select * into v_target from public.app_users u where u.app_user_id=p_target_user_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_target.version_no<>p_expected_version_no then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_target.is_root_admin then return jsonb_build_object('success',false,'error_code','ROOT_ADMIN_PROTECTED'); end if;
  if not v_target.is_active then return jsonb_build_object('success',false,'error_code','USER_INACTIVE'); end if;
  perform private.lock_internal_user_ids(array[p_target_user_id]);
  if not exists(select 1 from public.app_user_roles r where r.app_user_id=p_target_user_id and r.role_code='HR') then
    return jsonb_build_object('success',false,'error_code','INVALID_STATE');
  end if;

  if exists (
    with recursive requirements(permission_code) as (
      select d.requires_permission_code
      from public.permission_dependencies d
      where d.permission_code=v_permission
      union
      select d.requires_permission_code
      from public.permission_dependencies d
      join requirements r on d.permission_code=r.permission_code
    )
    select 1 from requirements r
    where not exists(
      select 1 from public.app_user_permissions p
      where p.app_user_id=p_target_user_id and p.permission_code=r.permission_code
    )
  ) then
    return jsonb_build_object('success',false,'error_code','INVALID_PERMISSION_DEPENDENCY');
  end if;

  insert into public.app_user_permissions(app_user_id,permission_code,granted_by,granted_at)
  values(p_target_user_id,v_permission,v_actor,clock_timestamp())
  on conflict(app_user_id,permission_code) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted > 0 then
    update public.app_users set updated_at=clock_timestamp()
    where app_user_id=p_target_user_id returning * into v_target;
    insert into public.security_audit_log(
      actor_auth_user_id,actor_app_user_id,action_code,entity_type,entity_id,request_id,source_code,result_code,metadata
    ) values (
      auth.uid(),v_actor,'HR_PERMISSION_GRANT','APP_USER',p_target_user_id,p_idempotency_key,'RPC','SUCCESS',
      jsonb_build_object('permission_code',v_permission)
    );
  end if;

  v_result := jsonb_build_object('success',true,'data',jsonb_build_object(
    'app_user_id',p_target_user_id,'permission_code',v_permission,'granted',true,'version_no',v_target.version_no
  ));
  perform private.record_idempotency(v_scope,'grant_hr_permission',p_idempotency_key,v_fingerprint,v_result,'APP_USER',p_target_user_id);
  return v_result;
end;
$$;

create or replace function public.revoke_hr_permission(
  p_target_user_id uuid,
  p_permission_code text,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_target public.app_users%rowtype;
  v_permission text := lower(btrim(coalesce(p_permission_code,'')));
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_deleted integer;
  v_result jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED'); end if;
  v_actor := private.current_app_user_id();
  if v_actor is null or not private.is_root_admin() then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
  if p_target_user_id is null or v_permission='' or p_expected_version_no is null or p_expected_version_no<=0 or p_idempotency_key is null then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR');
  end if;
  if not private.is_delegable_hr_permission(v_permission)
     or not exists(select 1 from public.permissions p where p.permission_code=v_permission) then
    return jsonb_build_object('success',false,'error_code','FORBIDDEN');
  end if;

  v_scope := 'app_user:'||v_actor::text||':target:'||p_target_user_id::text;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'command','revoke_hr_permission','target_user_id',p_target_user_id,'permission_code',v_permission,'expected_version_no',p_expected_version_no
  )::text,'sha256'),'hex');
  v_existing := private.check_idempotency(v_scope,'revoke_hr_permission',p_idempotency_key,v_fingerprint);
  if v_existing is not null then return v_existing; end if;

  select * into v_target from public.app_users u where u.app_user_id=p_target_user_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_target.version_no<>p_expected_version_no then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_target.is_root_admin then return jsonb_build_object('success',false,'error_code','ROOT_ADMIN_PROTECTED'); end if;
  if not v_target.is_active then return jsonb_build_object('success',false,'error_code','USER_INACTIVE'); end if;
  perform private.lock_internal_user_ids(array[p_target_user_id]);
  if not exists(select 1 from public.app_user_roles r where r.app_user_id=p_target_user_id and r.role_code='HR') then
    return jsonb_build_object('success',false,'error_code','INVALID_STATE');
  end if;

  if exists (
    with recursive dependents(permission_code) as (
      select d.permission_code
      from public.permission_dependencies d
      where d.requires_permission_code=v_permission
      union
      select d.permission_code
      from public.permission_dependencies d
      join dependents x on d.requires_permission_code=x.permission_code
    )
    select 1
    from dependents d
    join public.app_user_permissions p
      on p.app_user_id=p_target_user_id
     and p.permission_code=d.permission_code
  ) then
    return jsonb_build_object('success',false,'error_code','INVALID_PERMISSION_DEPENDENCY');
  end if;

  delete from public.app_user_permissions p
  where p.app_user_id=p_target_user_id and p.permission_code=v_permission;
  get diagnostics v_deleted = row_count;

  if v_deleted > 0 then
    update public.app_users set updated_at=clock_timestamp()
    where app_user_id=p_target_user_id returning * into v_target;
    insert into public.security_audit_log(
      actor_auth_user_id,actor_app_user_id,action_code,entity_type,entity_id,request_id,source_code,result_code,metadata
    ) values (
      auth.uid(),v_actor,'HR_PERMISSION_REVOKE','APP_USER',p_target_user_id,p_idempotency_key,'RPC','SUCCESS',
      jsonb_build_object('permission_code',v_permission)
    );
  end if;

  v_result := jsonb_build_object('success',true,'data',jsonb_build_object(
    'app_user_id',p_target_user_id,'permission_code',v_permission,'granted',false,'version_no',v_target.version_no
  ));
  perform private.record_idempotency(v_scope,'revoke_hr_permission',p_idempotency_key,v_fingerprint,v_result,'APP_USER',p_target_user_id);
  return v_result;
end;
$$;

-- Explicit command ACLs: do not leave SECURITY DEFINER functions on default PUBLIC execute.
revoke all on function public.assign_hr_role_with_defaults(uuid, bigint, uuid) from public, anon;
revoke all on function public.remove_hr_role(uuid, bigint, uuid) from public, anon;
revoke all on function public.grant_hr_permission(uuid, text, bigint, uuid) from public, anon;
revoke all on function public.revoke_hr_permission(uuid, text, bigint, uuid) from public, anon;
grant execute on function public.assign_hr_role_with_defaults(uuid, bigint, uuid) to authenticated, postgres, service_role;
grant execute on function public.remove_hr_role(uuid, bigint, uuid) to authenticated, postgres, service_role;
grant execute on function public.grant_hr_permission(uuid, text, bigint, uuid) to authenticated, postgres, service_role;
grant execute on function public.revoke_hr_permission(uuid, text, bigint, uuid) to authenticated, postgres, service_role;
