-- TASK-S06-002 / Part 4: canonical Google first-bind and Root-only non-Root identity rebind.
-- Depends on prior TASK-S06-002 serialization/directory/RBAC migrations.

-- -----------------------------------------------------------------------------
-- 6. Canonical first-Google-login binding and Root-only non-Root rebinding
-- -----------------------------------------------------------------------------
create or replace function public.provision_internal_identity_on_first_google_login()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_email text;
  v_target public.app_users%rowtype;
  v_roles jsonb;
  v_permissions jsonb;
  v_result jsonb;
begin
  if v_auth_user_id is null then
    return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED','message','Authentication required');
  end if;

  v_email := private.verified_google_auth_email(v_auth_user_id);
  if v_email is null then
    return jsonb_build_object('success',false,'error_code','FORBIDDEN','message','Only @eiu.edu.vn Google Workspace accounts are permitted');
  end if;

  -- Same normalized email serializes competing first-login Auth identities.
  perform pg_advisory_xact_lock(hashtextextended('internal-email:' || v_email, 0));

  if exists (
    select 1
    from public.app_users u
    where u.auth_user_id = v_auth_user_id
      and lower(u.email::text) <> v_email
  ) then
    return jsonb_build_object('success',false,'error_code','IDENTITY_REBIND_FORBIDDEN','message','Account is already bound to a different identity');
  end if;

  select * into v_target
  from public.app_users u
  where lower(u.email::text) = v_email
  for update;

  if not found then
    return jsonb_build_object('success',false,'error_code','NOT_FOUND','message','User account not found in internal directory');
  end if;
  if not v_target.is_active then
    return jsonb_build_object('success',false,'error_code','USER_INACTIVE','message','User account is inactive');
  end if;

  perform private.lock_internal_user_ids(array[v_target.app_user_id]);

  if v_target.auth_user_id is not null and v_target.auth_user_id <> v_auth_user_id then
    return jsonb_build_object('success',false,'error_code','IDENTITY_REBIND_FORBIDDEN','message','Account is already bound to a different identity');
  end if;

  if exists (
    select 1
    from public.app_users u
    where u.auth_user_id = v_auth_user_id
      and u.app_user_id <> v_target.app_user_id
  ) then
    return jsonb_build_object('success',false,'error_code','IDENTITY_REBIND_FORBIDDEN','message','Account is already bound to a different identity');
  end if;

  if v_target.auth_user_id is null then
    update public.app_users
    set auth_user_id = v_auth_user_id
    where app_user_id = v_target.app_user_id
    returning * into v_target;

    insert into public.security_audit_log(
      actor_auth_user_id,actor_app_user_id,action_code,entity_type,entity_id,
      source_code,result_code,metadata
    ) values (
      v_auth_user_id,v_target.app_user_id,'INTERNAL_IDENTITY_FIRST_BIND','APP_USER',v_target.app_user_id,
      'RPC','SUCCESS',jsonb_build_object(
        'changed_fields',jsonb_build_array('auth_user_id'),
        'auth_user_id',v_auth_user_id,
        'provider','google'
      )
    );
  end if;

  select coalesce(jsonb_agg(x.role_code order by x.role_code), '[]'::jsonb)
  into v_roles
  from public.app_user_roles x
  where x.app_user_id = v_target.app_user_id;

  if v_target.is_root_admin then
    select coalesce(jsonb_agg(p.permission_code order by p.permission_code), '[]'::jsonb)
    into v_permissions
    from public.permissions p;
  else
    select coalesce(jsonb_agg(p.permission_code order by p.permission_code), '[]'::jsonb)
    into v_permissions
    from public.app_user_permissions p
    where p.app_user_id = v_target.app_user_id;
  end if;

  v_result := jsonb_build_object('success',true,'data',jsonb_build_object(
    'app_user_id',v_target.app_user_id,
    'auth_user_id',v_auth_user_id,
    'email',v_target.email::text,
    'full_name',v_target.full_name,
    'job_title',v_target.job_title,
    'unit_id',v_target.unit_id,
    'is_active',v_target.is_active,
    'is_root_admin',v_target.is_root_admin,
    'version_no',v_target.version_no,
    'roles',v_roles,
    'permissions',v_permissions
  ));
  return v_result;
end;
$$;

-- Compatibility wrapper: one canonical bind path only.
create or replace function public.provision_internal_user_identity()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.provision_internal_identity_on_first_google_login();
$$;

create or replace function public.change_internal_user_identity(
  p_target_user_id uuid,
  p_replacement_auth_user_id uuid,
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
  v_replacement_email text;
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_previous_auth_user_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED'); end if;
  v_actor := private.current_app_user_id();
  if v_actor is null or not private.is_root_admin() then
    return jsonb_build_object('success',false,'error_code','FORBIDDEN');
  end if;
  if p_target_user_id is null
     or p_replacement_auth_user_id is null
     or p_expected_version_no is null
     or p_expected_version_no <= 0
     or p_idempotency_key is null then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR');
  end if;

  v_scope := 'app_user:'||v_actor::text||':target:'||p_target_user_id::text;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'command','change_internal_user_identity',
    'target_user_id',p_target_user_id,
    'replacement_auth_user_id',p_replacement_auth_user_id,
    'expected_version_no',p_expected_version_no
  )::text,'sha256'),'hex');
  v_existing := private.check_idempotency(v_scope,'change_internal_user_identity',p_idempotency_key,v_fingerprint);
  if v_existing is not null then return v_existing; end if;

  select * into v_target
  from public.app_users u
  where u.app_user_id=p_target_user_id
  for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_target.version_no<>p_expected_version_no then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_target.is_root_admin then return jsonb_build_object('success',false,'error_code','ROOT_ADMIN_PROTECTED'); end if;
  if v_target.auth_user_id is null then return jsonb_build_object('success',false,'error_code','IDENTITY_REBIND_FORBIDDEN'); end if;

  v_replacement_email := private.verified_google_auth_email(p_replacement_auth_user_id);
  if v_replacement_email is null then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR','message','Replacement must be a verified Google EIU Auth identity');
  end if;

  perform private.lock_internal_user_ids(array[p_target_user_id]);
  perform pg_advisory_xact_lock(hashtextextended('internal-email:'||v_replacement_email,0));

  if exists (
    select 1 from public.app_users u
    where u.app_user_id<>p_target_user_id
      and (u.auth_user_id=p_replacement_auth_user_id or lower(u.email::text)=v_replacement_email)
  ) then
    return jsonb_build_object('success',false,'error_code','IDENTITY_REBIND_FORBIDDEN');
  end if;

  if v_target.auth_user_id = p_replacement_auth_user_id
     and lower(v_target.email::text) = v_replacement_email then
    v_result := jsonb_build_object('success',true,'data',jsonb_build_object(
      'app_user_id',v_target.app_user_id,
      'auth_user_id',v_target.auth_user_id,
      'email',v_target.email::text,
      'version_no',v_target.version_no
    ));
    perform private.record_idempotency(v_scope,'change_internal_user_identity',p_idempotency_key,v_fingerprint,v_result,'APP_USER',p_target_user_id);
    return v_result;
  end if;

  v_previous_auth_user_id := v_target.auth_user_id;
  begin
    update public.app_users
    set auth_user_id=p_replacement_auth_user_id,
        email=v_replacement_email
    where app_user_id=p_target_user_id
    returning * into v_target;
  exception
    when unique_violation or check_violation then
      return jsonb_build_object('success',false,'error_code','IDENTITY_REBIND_FORBIDDEN');
  end;

  insert into public.security_audit_log(
    actor_auth_user_id,actor_app_user_id,action_code,entity_type,entity_id,
    request_id,source_code,result_code,metadata
  ) values (
    auth.uid(),v_actor,'INTERNAL_IDENTITY_REBIND','APP_USER',p_target_user_id,
    p_idempotency_key,'RPC','SUCCESS',jsonb_build_object(
      'changed_fields',jsonb_build_array('auth_user_id','email'),
      'previous_auth_user_id',v_previous_auth_user_id,
      'replacement_auth_user_id',p_replacement_auth_user_id,
      'provider','google'
    )
  );

  v_result := jsonb_build_object('success',true,'data',jsonb_build_object(
    'app_user_id',v_target.app_user_id,
    'auth_user_id',v_target.auth_user_id,
    'email',v_target.email::text,
    'version_no',v_target.version_no
  ));
  perform private.record_idempotency(v_scope,'change_internal_user_identity',p_idempotency_key,v_fingerprint,v_result,'APP_USER',p_target_user_id);
  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- Explicit identity-function ACLs
-- -----------------------------------------------------------------------------
revoke all on function public.provision_internal_identity_on_first_google_login() from public, anon;
revoke all on function public.provision_internal_user_identity() from public, anon;
revoke all on function public.change_internal_user_identity(uuid, uuid, bigint, uuid) from public, anon;

grant execute on function public.provision_internal_identity_on_first_google_login() to authenticated, postgres, service_role;
grant execute on function public.provision_internal_user_identity() to authenticated, postgres, service_role;
grant execute on function public.change_internal_user_identity(uuid, uuid, bigint, uuid) to authenticated, postgres, service_role;
