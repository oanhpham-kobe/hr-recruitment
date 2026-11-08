-- TASK-S06-002 / R3 repair: complete Unit/User/Application and Interview/User
-- lock-order proof, distinguish dormant history from new participant selection,
-- and repeat trusted Auth proof after the full first-bind lock set.

-- -----------------------------------------------------------------------------
-- 1. Durable app_user Unit history: unchanged Unit is retained history, not a
--    newly-selected master reference. New/changed references still key-share
--    the Unit before the holder write commits.
-- -----------------------------------------------------------------------------
create or replace function private.capture_app_user_master_reference_history_r3()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    perform private.record_master_reference_history('organizational_units', old.unit_id, false);
  end if;

  if tg_op = 'INSERT'
     or (tg_op = 'UPDATE' and new.unit_id is distinct from old.unit_id) then
    perform private.record_master_reference_history('organizational_units', new.unit_id, true);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function private.capture_app_user_master_reference_history_r3()
  from public, anon, authenticated;
grant execute on function private.capture_app_user_master_reference_history_r3()
  to postgres, service_role;

drop trigger if exists s06_master_reference_history_capture on public.app_users;
create trigger s06_master_reference_history_capture
  before insert or update or delete on public.app_users
  for each row execute function private.capture_app_user_master_reference_history_r3();

-- Directory updates that may select a new Unit or normalized email acquire those
-- resources before the target User row. The retained R2 implementation keeps all
-- canonical validation/idempotency/audit behavior and re-acquires the same locks
-- transaction-locally without changing the order.
alter function public.update_internal_user_directory(uuid, jsonb, bigint, uuid)
  rename to update_internal_user_directory_s06_002_r2_impl;

revoke all on function public.update_internal_user_directory_s06_002_r2_impl(uuid, jsonb, bigint, uuid)
  from public, anon, authenticated;
grant execute on function public.update_internal_user_directory_s06_002_r2_impl(uuid, jsonb, bigint, uuid)
  to postgres, service_role;

create or replace function public.update_internal_user_directory(
  p_target_user_id uuid,
  p_patch jsonb,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_unit_id uuid;
begin
  if p_patch is not null and jsonb_typeof(p_patch) = 'object' then
    if p_patch ? 'email' and jsonb_typeof(p_patch -> 'email') = 'string' then
      begin
        v_email := private.normalize_internal_eiu_email(p_patch ->> 'email');
      exception
        when invalid_parameter_value then
          v_email := null;
      end;
      if v_email is not null then
        perform pg_advisory_xact_lock(hashtextextended('internal-email:' || v_email, 0));
      end if;
    end if;

    if p_patch ? 'unit_id' and jsonb_typeof(p_patch -> 'unit_id') = 'string' then
      begin
        v_unit_id := nullif(btrim(p_patch ->> 'unit_id'), '')::uuid;
      exception
        when invalid_text_representation then
          v_unit_id := null;
      end;
      if v_unit_id is not null then
        perform 1
        from public.organizational_units u
        where u.unit_id = v_unit_id
          and u.is_active = true
        for key share;
      end if;
    end if;
  end if;

  return public.update_internal_user_directory_s06_002_r2_impl(
    p_target_user_id,
    p_patch,
    p_expected_version_no,
    p_idempotency_key
  );
end;
$$;

revoke all on function public.update_internal_user_directory(uuid, jsonb, bigint, uuid)
  from public, anon;
grant execute on function public.update_internal_user_directory(uuid, jsonb, bigint, uuid)
  to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 2. Interview operationalization: lock every current participant and the actor
--    FK row before taking Internal User advisory locks, then revalidate current
--    participant activity after the complete row/advisory set.
-- -----------------------------------------------------------------------------
create or replace function private.guard_resource_blocking_interview_participants()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_application_active boolean;
  v_participant_ids uuid[];
  v_lock_ids uuid[];
begin
  if not new.is_active
     or new.schedule_status_code = 'CANCELLED'
     or new.start_at is null
     or new.end_at is null
     or new.end_at <= clock_timestamp() then
    return new;
  end if;

  select a.is_active
  into v_application_active
  from public.applications a
  where a.application_id = new.application_id;

  if not coalesce(v_application_active, false) then
    return new;
  end if;

  select coalesce(array_agg(distinct ip.app_user_id order by ip.app_user_id), array[]::uuid[])
  into v_participant_ids
  from public.interview_participants ip
  where ip.interview_id = new.interview_id
    and ip.is_current = true;

  select coalesce(array_agg(distinct q.app_user_id order by q.app_user_id), array[]::uuid[])
  into v_lock_ids
  from (
    select unnest(v_participant_ids) as app_user_id
    union all
    select new.updated_by
  ) q
  where q.app_user_id is not null;

  -- All User rows first, in deterministic UUID order. This includes updated_by
  -- so FK acquisition cannot occur after a participant advisory lock.
  perform 1
  from public.app_users u
  where u.app_user_id = any(v_lock_ids)
  order by u.app_user_id
  for update;

  perform private.lock_internal_user_ids(v_lock_ids);

  if exists (
    select 1
    from public.interview_participants ip
    left join public.app_users u on u.app_user_id = ip.app_user_id
    where ip.interview_id = new.interview_id
      and ip.is_current = true
      and coalesce(u.is_active, false) = false
  ) then
    raise exception 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_resource_blocking_interview_participants()
  from public, anon, authenticated;
grant execute on function private.guard_resource_blocking_interview_participants()
  to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. New participant selection/restoration is always lifecycle-sensitive, even
--    when the Interview itself is dormant. Historical remove/reorder operations
--    do not enter this branch and remain maintainable.
-- -----------------------------------------------------------------------------
create or replace function private.validate_participant_lifecycle_and_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_active boolean;
begin
  if not ((new.is_current = true and new.removed_at is null)
          or (new.is_current = false and new.removed_at is not null)) then
    raise exception 'PARTICIPANT_LIFECYCLE_INVALID' using errcode = '23514';
  end if;

  if new.is_current = true
     and (
       tg_op = 'INSERT'
       or old.is_current is distinct from new.is_current
       or old.app_user_id is distinct from new.app_user_id
     ) then
    -- Row -> advisory -> revalidate. A deactivation that owns the row first
    -- therefore commits before selection can continue, and selection fails shut.
    perform 1
    from public.app_users u
    where u.app_user_id = new.app_user_id
    for update;

    if not found then
      raise exception 'USER_INACTIVE_NOT_SELECTABLE' using errcode = '23514';
    end if;

    perform private.lock_internal_user_ids(array[new.app_user_id]);

    select u.is_active
    into v_user_active
    from public.app_users u
    where u.app_user_id = new.app_user_id;

    if coalesce(v_user_active, false) = false then
      raise exception 'USER_INACTIVE_NOT_SELECTABLE' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.validate_participant_lifecycle_and_user()
  from public, anon, authenticated;
grant execute on function private.validate_participant_lifecycle_and_user()
  to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 4. First Google bind: trusted Auth proof must still match the exact normalized
--    email after normalized-email, target-row, and Internal User locks are held.
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
  v_post_lock_email text;
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

  v_post_lock_email := private.verified_google_auth_email(v_auth_user_id);
  if v_post_lock_email is null or v_post_lock_email <> v_email then
    return jsonb_build_object('success',false,'error_code','FORBIDDEN','message','Google identity changed during verification');
  end if;

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

revoke all on function public.provision_internal_identity_on_first_google_login()
  from public, anon;
grant execute on function public.provision_internal_identity_on_first_google_login()
  to authenticated, postgres, service_role;
