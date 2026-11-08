-- TASK-S06-002 / R2 repair: consumer-safe identity projection, dormant
-- participant maintenance, and deterministic cross-writer lock order.

-- Current-user-only binding status for trusted server consumers that
-- must distinguish an inactive bound Internal User without reading the
-- raw app_users.auth_user_id column through the Data API.
create or replace function public.get_current_internal_binding_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_user record;
begin
  if v_auth_user_id is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;

  select u.app_user_id, u.is_active, u.is_root_admin
  into v_user
  from public.app_users u
  where u.auth_user_id = v_auth_user_id;

  if not found then
    return jsonb_build_object(
      'success', true,
      'data', jsonb_build_object(
        'bound', false,
        'app_user_id', null,
        'is_active', false,
        'is_root_admin', false
      )
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'bound', true,
      'app_user_id', v_user.app_user_id,
      'is_active', v_user.is_active,
      'is_root_admin', v_user.is_root_admin
    )
  );
end;
$$;

revoke all on function public.get_current_internal_binding_status() from public, anon;
grant execute on function public.get_current_internal_binding_status() to authenticated, postgres, service_role;

-- Owner writers now acquire the target Internal User row before the
-- shared advisory gate. This matches lifecycle/RBAC writers, which
-- necessarily own their target app_users row before trigger-time
-- advisory serialization. Eligibility is re-read after both locks.
create or replace function private.guard_active_application_owner_eligibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_ids uuid[] := array[]::uuid[];
  v_locked_owner_id uuid;
  v_owner_ok boolean;
begin
  if not new.is_active then
    return new;
  end if;

  if new.hr_owner_id is null then
    raise exception 'APPLICATION_OWNER_NOT_ELIGIBLE' using errcode = '23514';
  end if;

  -- Row first, advisory second. FOR UPDATE is intentional: lifecycle
  -- commands also use FOR UPDATE before the same advisory gate.
  select u.app_user_id
  into v_locked_owner_id
  from public.app_users u
  where u.app_user_id = new.hr_owner_id
  for update;

  if not found then
    raise exception 'APPLICATION_OWNER_NOT_ELIGIBLE' using errcode = '23514';
  end if;

  v_user_ids := array[new.hr_owner_id];

  if tg_op = 'UPDATE' and old.is_active = false and new.is_active = true then
    select v_user_ids || coalesce(array_agg(distinct ip.app_user_id order by ip.app_user_id), array[]::uuid[])
    into v_user_ids
    from public.interviews i
    join public.interview_participants ip
      on ip.interview_id = i.interview_id
     and ip.is_current = true
    where i.application_id = new.application_id
      and i.is_active = true
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null
      and i.end_at is not null
      and i.end_at > clock_timestamp();
  end if;

  perform private.lock_internal_user_ids(v_user_ids);

  -- Revalidate after the complete row/advisory lock set.
  select exists (
    select 1
    from public.app_users u
    where u.app_user_id = new.hr_owner_id
      and u.is_active = true
      and (
        u.is_root_admin = true
        or exists (
          select 1
          from public.app_user_roles r
          where r.app_user_id = u.app_user_id
            and r.role_code = 'HR'
        )
      )
  ) into v_owner_ok;

  if not coalesce(v_owner_ok, false) then
    raise exception 'APPLICATION_OWNER_NOT_ELIGIBLE' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.is_active = false and new.is_active = true
     and exists (
       select 1
       from public.interviews i
       join public.interview_participants ip
         on ip.interview_id = i.interview_id
        and ip.is_current = true
       left join public.app_users u on u.app_user_id = ip.app_user_id
       where i.application_id = new.application_id
         and i.is_active = true
         and i.schedule_status_code <> 'CANCELLED'
         and i.start_at is not null
         and i.end_at is not null
         and i.end_at > clock_timestamp()
         and coalesce(u.is_active, false) = false
     ) then
    raise exception 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_active_application_owner_eligibility() from public, anon, authenticated;
grant execute on function private.guard_active_application_owner_eligibility() to postgres, service_role;

-- Participant row maintenance is eligibility-sensitive only when the
-- touched current participant belongs to a canonical resource_blocking
-- Interview. CANCELLED, inactive, unscheduled, or fully elapsed history
-- may be reordered/removed without re-selecting inactive users.
create or replace function private.recheck_current_participants_after_statement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_ids uuid[];
begin
  select coalesce(array_agg(distinct n.app_user_id order by n.app_user_id), array[]::uuid[])
  into v_user_ids
  from s06_new_participants n
  join public.interviews i on i.interview_id = n.interview_id
  join public.applications a on a.application_id = i.application_id
  where n.is_current = true
    and a.is_active = true
    and i.is_active = true
    and i.schedule_status_code <> 'CANCELLED'
    and i.start_at is not null
    and i.end_at is not null
    and i.end_at > clock_timestamp();

  perform private.lock_internal_user_ids(v_user_ids);

  if exists (
    select 1
    from s06_new_participants n
    join public.interviews i on i.interview_id = n.interview_id
    join public.applications a on a.application_id = i.application_id
    left join public.app_users u on u.app_user_id = n.app_user_id
    where n.is_current = true
      and a.is_active = true
      and i.is_active = true
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null
      and i.end_at is not null
      and i.end_at > clock_timestamp()
      and coalesce(u.is_active, false) = false
  ) then
    raise exception 'USER_INACTIVE_NOT_SELECTABLE' using errcode = '23514';
  end if;

  return null;
end;
$$;

revoke all on function private.recheck_current_participants_after_statement() from public, anon, authenticated;
grant execute on function private.recheck_current_participants_after_statement() to postgres, service_role;

-- Root-only non-Root rebind now uses the same identity lock order as
-- first bind: normalized replacement-email advisory -> target row ->
-- per-user advisory -> post-lock trusted Auth evidence revalidation.
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
  v_post_lock_email text;
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

  v_replacement_email := private.verified_google_auth_email(p_replacement_auth_user_id);
  if v_replacement_email is null then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR','message','Replacement must be a verified Google EIU Auth identity');
  end if;

  -- Identity order shared with first bind: email gate before target row.
  perform pg_advisory_xact_lock(hashtextextended('internal-email:'||v_replacement_email,0));

  select * into v_target
  from public.app_users u
  where u.app_user_id=p_target_user_id
  for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_target.version_no<>p_expected_version_no then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_target.is_root_admin then return jsonb_build_object('success',false,'error_code','ROOT_ADMIN_PROTECTED'); end if;
  if v_target.auth_user_id is null then return jsonb_build_object('success',false,'error_code','IDENTITY_REBIND_FORBIDDEN'); end if;

  perform private.lock_internal_user_ids(array[p_target_user_id]);

  v_post_lock_email := private.verified_google_auth_email(p_replacement_auth_user_id);
  if v_post_lock_email is null or v_post_lock_email <> v_replacement_email then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR','message','Replacement Auth identity changed during verification');
  end if;

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

revoke all on function public.change_internal_user_identity(uuid, uuid, bigint, uuid) from public, anon;
grant execute on function public.change_internal_user_identity(uuid, uuid, bigint, uuid) to authenticated, postgres, service_role;
