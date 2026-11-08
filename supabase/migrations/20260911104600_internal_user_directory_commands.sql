-- TASK-S06-002 / Part 2: Internal User directory lifecycle trusted commands.
-- Depends on 20260911104530_internal_user_read_contracts.sql.

-- -----------------------------------------------------------------------------
-- 4. Directory lifecycle trusted commands
-- -----------------------------------------------------------------------------
create or replace function public.create_internal_user(
  p_payload jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_email text;
  v_full_name text;
  v_job_title text;
  v_unit_id uuid;
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_user public.app_users%rowtype;
  v_result jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;

  v_actor := private.current_app_user_id();
  if v_actor is null
     or not (private.is_root_admin() or private.has_permission('users.directory_manage')) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;

  if p_idempotency_key is null
     or p_payload is null
     or jsonb_typeof(p_payload) <> 'object'
     or p_payload = '{}'::jsonb
     or exists (
       select 1
       from jsonb_object_keys(p_payload) k(key_name)
       where k.key_name not in ('email', 'full_name', 'job_title', 'unit_id')
     )
     or not (p_payload ? 'email')
     or not (p_payload ? 'full_name') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if jsonb_typeof(p_payload -> 'email') <> 'string'
     or jsonb_typeof(p_payload -> 'full_name') <> 'string'
     or (p_payload ? 'job_title' and jsonb_typeof(p_payload -> 'job_title') not in ('string', 'null'))
     or (p_payload ? 'unit_id' and jsonb_typeof(p_payload -> 'unit_id') not in ('string', 'null')) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  begin
    v_email := private.normalize_internal_eiu_email(p_payload ->> 'email');
    v_full_name := btrim(p_payload ->> 'full_name');
    if v_full_name = '' or char_length(v_full_name) > 200 then
      raise exception 'invalid full name' using errcode = '22023';
    end if;
    v_job_title := case
      when p_payload ? 'job_title' then nullif(btrim(p_payload ->> 'job_title'), '')
      else null
    end;
    if v_job_title is not null and char_length(v_job_title) > 255 then
      raise exception 'invalid job title' using errcode = '22023';
    end if;
    if p_payload ? 'unit_id' and jsonb_typeof(p_payload -> 'unit_id') <> 'null' then
      v_unit_id := nullif(btrim(p_payload ->> 'unit_id'), '')::uuid;
    else
      v_unit_id := null;
    end if;
  exception
    when invalid_parameter_value or invalid_text_representation then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end;

  v_scope := 'app_user:' || v_actor::text || ':new-internal-email:' || v_email;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'create_internal_user',
        'email', v_email,
        'full_name', v_full_name,
        'job_title', v_job_title,
        'unit_id', v_unit_id
      )::text,
      'sha256'
    ),
    'hex'
  );

  v_existing := private.check_idempotency(
    v_scope, 'create_internal_user', p_idempotency_key, v_fingerprint
  );
  if v_existing is not null then
    return v_existing;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('internal-email:' || v_email, 0));

  if exists (
    select 1 from public.app_users u where lower(u.email::text) = v_email
  ) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Internal User email already exists');
  end if;

  if v_unit_id is not null then
    perform 1
    from public.organizational_units u
    where u.unit_id = v_unit_id
      and u.is_active = true
    for key share;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Active Unit required');
    end if;
  end if;

  begin
    insert into public.app_users (
      auth_user_id, email, full_name, job_title, unit_id, is_active, is_root_admin
    ) values (
      null, v_email, v_full_name, v_job_title, v_unit_id, true, false
    ) returning * into v_user;
  exception
    when unique_violation or check_violation or foreign_key_violation then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end;

  insert into public.security_audit_log (
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
    request_id, source_code, result_code, metadata
  ) values (
    auth.uid(), v_actor, 'INTERNAL_USER_CREATE', 'APP_USER', v_user.app_user_id,
    p_idempotency_key, 'RPC', 'SUCCESS',
    jsonb_build_object(
      'changed_fields', jsonb_build_array('email','full_name','job_title','unit_id','is_active'),
      'identity_bound', false,
      'is_root_admin', false,
      'is_hr', false
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'app_user_id', v_user.app_user_id,
      'email', v_user.email::text,
      'full_name', v_user.full_name,
      'job_title', v_user.job_title,
      'unit_id', v_user.unit_id,
      'is_active', v_user.is_active,
      'is_root_admin', false,
      'is_hr', false,
      'identity_bound', false,
      'version_no', v_user.version_no
    )
  );

  perform private.record_idempotency(
    v_scope, 'create_internal_user', p_idempotency_key, v_fingerprint,
    v_result, 'APP_USER', v_user.app_user_id
  );
  return v_result;
end;
$$;

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
  v_actor uuid;
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_target public.app_users%rowtype;
  v_email text;
  v_full_name text;
  v_job_title text;
  v_unit_id uuid;
  v_changed_fields text[] := array[]::text[];
  v_result jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;

  v_actor := private.current_app_user_id();
  if v_actor is null
     or not (private.is_root_admin() or private.has_permission('users.directory_manage')) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;

  if p_target_user_id is null
     or p_expected_version_no is null
     or p_expected_version_no <= 0
     or p_idempotency_key is null
     or p_patch is null
     or jsonb_typeof(p_patch) <> 'object'
     or p_patch = '{}'::jsonb
     or exists (
       select 1
       from jsonb_object_keys(p_patch) k(key_name)
       where k.key_name not in ('email', 'full_name', 'job_title', 'unit_id')
     ) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  begin
    if p_patch ? 'email' then
      if jsonb_typeof(p_patch -> 'email') <> 'string' then
        raise exception 'invalid email type' using errcode = '22023';
      end if;
      v_email := private.normalize_internal_eiu_email(p_patch ->> 'email');
    end if;

    if p_patch ? 'full_name' then
      if jsonb_typeof(p_patch -> 'full_name') <> 'string' then
        raise exception 'invalid full name type' using errcode = '22023';
      end if;
      v_full_name := btrim(p_patch ->> 'full_name');
      if v_full_name = '' or char_length(v_full_name) > 200 then
        raise exception 'invalid full name' using errcode = '22023';
      end if;
    end if;

    if p_patch ? 'job_title' then
      if jsonb_typeof(p_patch -> 'job_title') not in ('string','null') then
        raise exception 'invalid job title type' using errcode = '22023';
      end if;
      v_job_title := nullif(btrim(p_patch ->> 'job_title'), '');
      if v_job_title is not null and char_length(v_job_title) > 255 then
        raise exception 'invalid job title' using errcode = '22023';
      end if;
    end if;

    if p_patch ? 'unit_id' then
      if jsonb_typeof(p_patch -> 'unit_id') not in ('string','null') then
        raise exception 'invalid unit type' using errcode = '22023';
      end if;
      if jsonb_typeof(p_patch -> 'unit_id') = 'null' then
        v_unit_id := null;
      else
        v_unit_id := nullif(btrim(p_patch ->> 'unit_id'), '')::uuid;
      end if;
    end if;
  exception
    when invalid_parameter_value or invalid_text_representation then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end;

  v_scope := 'app_user:' || v_actor::text || ':target:' || p_target_user_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'update_internal_user_directory',
        'target_user_id', p_target_user_id,
        'expected_version_no', p_expected_version_no,
        'email_present', p_patch ? 'email',
        'email', v_email,
        'full_name_present', p_patch ? 'full_name',
        'full_name', v_full_name,
        'job_title_present', p_patch ? 'job_title',
        'job_title', v_job_title,
        'unit_id_present', p_patch ? 'unit_id',
        'unit_id', v_unit_id
      )::text,
      'sha256'
    ),
    'hex'
  );

  v_existing := private.check_idempotency(
    v_scope, 'update_internal_user_directory', p_idempotency_key, v_fingerprint
  );
  if v_existing is not null then
    return v_existing;
  end if;

  select * into v_target
  from public.app_users u
  where u.app_user_id = p_target_user_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_target.version_no <> p_expected_version_no then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if p_patch ? 'email' and v_email is distinct from lower(v_target.email::text) then
    if v_target.auth_user_id is not null then
      return jsonb_build_object('success', false, 'error_code', 'IDENTITY_REBIND_FORBIDDEN');
    end if;
    perform pg_advisory_xact_lock(hashtextextended('internal-email:' || v_email, 0));
    if exists (
      select 1
      from public.app_users u
      where lower(u.email::text) = v_email
        and u.app_user_id <> p_target_user_id
    ) then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Internal User email already exists');
    end if;
    v_changed_fields := array_append(v_changed_fields, 'email');
  else
    v_email := lower(v_target.email::text);
  end if;

  if p_patch ? 'full_name' and v_full_name is distinct from v_target.full_name then
    v_changed_fields := array_append(v_changed_fields, 'full_name');
  else
    v_full_name := v_target.full_name;
  end if;

  if p_patch ? 'job_title' and v_job_title is distinct from v_target.job_title then
    v_changed_fields := array_append(v_changed_fields, 'job_title');
  else
    v_job_title := v_target.job_title;
  end if;

  if p_patch ? 'unit_id' and v_unit_id is distinct from v_target.unit_id then
    if v_unit_id is not null then
      perform 1
      from public.organizational_units u
      where u.unit_id = v_unit_id
        and u.is_active = true
      for key share;
      if not found then
        return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Active Unit required');
      end if;
    end if;
    v_changed_fields := array_append(v_changed_fields, 'unit_id');
  else
    v_unit_id := v_target.unit_id;
  end if;

  if cardinality(v_changed_fields) > 0 then
    begin
      update public.app_users
      set email = v_email,
          full_name = v_full_name,
          job_title = v_job_title,
          unit_id = v_unit_id
      where app_user_id = p_target_user_id
      returning * into v_target;
    exception
      when unique_violation or check_violation or foreign_key_violation then
        return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end;

    insert into public.security_audit_log (
      actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
      request_id, source_code, result_code, metadata
    ) values (
      auth.uid(), v_actor, 'INTERNAL_USER_DIRECTORY_UPDATE', 'APP_USER', p_target_user_id,
      p_idempotency_key, 'RPC', 'SUCCESS',
      jsonb_build_object('changed_fields', to_jsonb(v_changed_fields))
    );
  end if;

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'app_user_id', v_target.app_user_id,
      'email', v_target.email::text,
      'full_name', v_target.full_name,
      'job_title', v_target.job_title,
      'unit_id', v_target.unit_id,
      'is_active', v_target.is_active,
      'is_root_admin', v_target.is_root_admin,
      'identity_bound', v_target.auth_user_id is not null,
      'version_no', v_target.version_no
    )
  );

  perform private.record_idempotency(
    v_scope, 'update_internal_user_directory', p_idempotency_key, v_fingerprint,
    v_result, 'APP_USER', p_target_user_id
  );
  return v_result;
end;
$$;

create or replace function public.set_internal_user_active(
  p_target_user_id uuid,
  p_active boolean,
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
  v_actor_is_root boolean;
  v_target public.app_users%rowtype;
  v_target_is_hr boolean;
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_result jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;

  v_actor := private.current_app_user_id();
  v_actor_is_root := private.is_root_admin();
  if v_actor is null
     or not (v_actor_is_root or private.has_permission('users.directory_manage')) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;

  if p_target_user_id is null
     or p_active is null
     or p_expected_version_no is null
     or p_expected_version_no <= 0
     or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  v_scope := 'app_user:' || v_actor::text || ':target:' || p_target_user_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'set_internal_user_active',
        'target_user_id', p_target_user_id,
        'active', p_active,
        'expected_version_no', p_expected_version_no
      )::text,
      'sha256'
    ),
    'hex'
  );

  v_existing := private.check_idempotency(
    v_scope, 'set_internal_user_active', p_idempotency_key, v_fingerprint
  );
  if v_existing is not null then
    return v_existing;
  end if;

  select * into v_target
  from public.app_users u
  where u.app_user_id = p_target_user_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_target.version_no <> p_expected_version_no then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  perform private.lock_internal_user_ids(array[p_target_user_id]);

  if v_target.is_root_admin then
    return jsonb_build_object('success', false, 'error_code', 'ROOT_ADMIN_PROTECTED');
  end if;

  select exists (
    select 1 from public.app_user_roles r
    where r.app_user_id = p_target_user_id and r.role_code = 'HR'
  ) into v_target_is_hr;

  if v_target_is_hr and not v_actor_is_root then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;
  if v_target_is_hr and p_active = false and v_actor = p_target_user_id then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;

  if v_target.is_active = p_active then
    v_result := jsonb_build_object(
      'success', true,
      'data', jsonb_build_object(
        'app_user_id', v_target.app_user_id,
        'is_active', v_target.is_active,
        'version_no', v_target.version_no
      )
    );
    perform private.record_idempotency(
      v_scope, 'set_internal_user_active', p_idempotency_key, v_fingerprint,
      v_result, 'APP_USER', p_target_user_id
    );
    return v_result;
  end if;

  if p_active = false then
    if exists (
      select 1
      from public.applications a
      where a.hr_owner_id = p_target_user_id
        and a.is_active = true
    ) then
      return jsonb_build_object('success', false, 'error_code', 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
    end if;

    if exists (
      select 1
      from public.interview_participants ip
      join public.interviews i on i.interview_id = ip.interview_id
      join public.applications a on a.application_id = i.application_id
      where ip.app_user_id = p_target_user_id
        and ip.is_current = true
        and a.is_active = true
        and i.is_active = true
        and i.schedule_status_code <> 'CANCELLED'
        and i.start_at is not null
        and i.end_at is not null
        and i.end_at > clock_timestamp()
    ) then
      return jsonb_build_object('success', false, 'error_code', 'FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED');
    end if;
  end if;

  begin
    update public.app_users
    set is_active = p_active
    where app_user_id = p_target_user_id
    returning * into v_target;
  exception
    when check_violation then
      if sqlerrm like '%ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED%' then
        return jsonb_build_object('success', false, 'error_code', 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
      elsif sqlerrm like '%FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED%' then
        return jsonb_build_object('success', false, 'error_code', 'FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED');
      end if;
      raise;
  end;

  insert into public.security_audit_log (
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
    request_id, source_code, result_code, metadata
  ) values (
    auth.uid(), v_actor,
    case when p_active then 'INTERNAL_USER_ACTIVATE' else 'INTERNAL_USER_INACTIVATE' end,
    'APP_USER', p_target_user_id, p_idempotency_key, 'RPC', 'SUCCESS',
    jsonb_build_object(
      'changed_fields', jsonb_build_array('is_active'),
      'is_active', p_active
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'app_user_id', v_target.app_user_id,
      'is_active', v_target.is_active,
      'version_no', v_target.version_no
    )
  );

  perform private.record_idempotency(
    v_scope, 'set_internal_user_active', p_idempotency_key, v_fingerprint,
    v_result, 'APP_USER', p_target_user_id
  );
  return v_result;
end;
$$;

-- Explicit command ACLs: do not leave SECURITY DEFINER functions on default PUBLIC execute.
revoke all on function public.create_internal_user(jsonb, uuid) from public, anon;
revoke all on function public.update_internal_user_directory(uuid, jsonb, bigint, uuid) from public, anon;
revoke all on function public.set_internal_user_active(uuid, boolean, bigint, uuid) from public, anon;
grant execute on function public.create_internal_user(jsonb, uuid) to authenticated, postgres, service_role;
grant execute on function public.update_internal_user_directory(uuid, jsonb, bigint, uuid) to authenticated, postgres, service_role;
grant execute on function public.set_internal_user_active(uuid, boolean, bigint, uuid) to authenticated, postgres, service_role;
