-- TASK-S06-001: Phase-1 business Master Data lifecycle/history trusted contracts.
-- Append-only over the accepted Slice-01..05 schema.

-- -----------------------------------------------------------------------------
-- 1. Consistent optimistic versioning for all 11 Phase-1 business masters.
-- -----------------------------------------------------------------------------
drop trigger if exists organizational_units_touch_version on public.organizational_units;
create trigger organizational_units_touch_version
  before update on public.organizational_units
  for each row execute function private.touch_version();

drop trigger if exists department_teams_touch_version on public.department_teams;
create trigger department_teams_touch_version
  before update on public.department_teams
  for each row execute function private.touch_version();

drop trigger if exists positions_touch_version on public.positions;
create trigger positions_touch_version
  before update on public.positions
  for each row execute function private.touch_version();

drop trigger if exists position_groups_touch_version on public.position_groups;
create trigger position_groups_touch_version
  before update on public.position_groups
  for each row execute function private.touch_version();

drop trigger if exists qualification_levels_touch_version on public.qualification_levels;
create trigger qualification_levels_touch_version
  before update on public.qualification_levels
  for each row execute function private.touch_version();

drop trigger if exists rooms_touch_version on public.rooms;
create trigger rooms_touch_version
  before update on public.rooms
  for each row execute function private.touch_version();

drop trigger if exists interview_formats_touch_version on public.interview_formats;
create trigger interview_formats_touch_version
  before update on public.interview_formats
  for each row execute function private.touch_version();

drop trigger if exists recruitment_sources_touch_version on public.recruitment_sources;
create trigger recruitment_sources_touch_version
  before update on public.recruitment_sources
  for each row execute function private.touch_version();

drop trigger if exists document_types_touch_version on public.document_types;
create trigger document_types_touch_version
  before update on public.document_types
  for each row execute function private.touch_version();

drop trigger if exists cancellation_reasons_touch_version on public.cancellation_reasons;
create trigger cancellation_reasons_touch_version
  before update on public.cancellation_reasons
  for each row execute function private.touch_version();

drop trigger if exists rejection_reasons_touch_version on public.rejection_reasons;
create trigger rejection_reasons_touch_version
  before update on public.rejection_reasons
  for each row execute function private.touch_version();

-- -----------------------------------------------------------------------------
-- 2. Private helpers. No arbitrary table or column routing is accepted.
-- -----------------------------------------------------------------------------
create or replace function private.master_command_actor()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.app_user_id
  from public.app_users u
  where u.auth_user_id = (select auth.uid())
    and u.is_active = true
    and (private.is_root_admin() or private.has_permission('master_data.manage'))
  limit 1;
$$;

create or replace function private.master_usage_exists(
  p_master_type text,
  p_master_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  case p_master_type
    when 'organizational_units' then
      return exists (select 1 from public.department_teams x where x.unit_id = p_master_id)
        or exists (select 1 from public.positions x where x.unit_id = p_master_id)
        or exists (select 1 from public.applications x where x.unit_id = p_master_id)
        or exists (select 1 from public.app_users x where x.unit_id = p_master_id);
    when 'department_teams' then
      return exists (select 1 from public.positions x where x.department_team_id = p_master_id)
        or exists (select 1 from public.applications x where x.department_team_id = p_master_id);
    when 'positions' then
      return exists (select 1 from public.applications x where x.position_id = p_master_id);
    when 'position_groups' then
      return exists (select 1 from public.positions x where x.position_group_id = p_master_id);
    when 'qualification_levels' then
      return exists (select 1 from public.submission_education x where x.qualification_id = p_master_id);
    when 'rooms' then
      return exists (select 1 from public.interviews x where x.room_id = p_master_id);
    when 'interview_formats' then
      return exists (select 1 from public.interviews x where x.interview_format_id = p_master_id);
    when 'recruitment_sources' then
      return exists (select 1 from public.submissions x where x.recruitment_source_id = p_master_id);
    when 'document_types' then
      return exists (select 1 from public.submission_document_logicals x where x.document_type_id = p_master_id)
        or exists (select 1 from public.interview_document_logicals x where x.document_type_id = p_master_id)
        or exists (select 1 from public.upload_reservations x where x.intended_document_type_id = p_master_id)
        or exists (
          select 1
          from public.candidate_form_document_changes x
          where x.document_type_id = p_master_id
             or x.intended_document_type_id = p_master_id
        );
    when 'cancellation_reasons' then
      return exists (select 1 from public.interviews x where x.cancellation_reason_id = p_master_id);
    when 'rejection_reasons' then
      return exists (select 1 from public.interviews x where x.rejection_reason_id = p_master_id);
    else
      return false;
  end case;
end;
$$;

create or replace function private.normalize_master_payload(
  p_master_type text,
  p_payload jsonb,
  p_mode text
)
returns jsonb
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_allowed text[];
  v_required text[];
  v_key text;
  v_norm jsonb := '{}'::jsonb;
  v_value text;
  v_uuid uuid;
  v_bool boolean;
begin
  if p_mode not in ('CREATE', 'UPDATE') then
    raise exception 'invalid master payload mode' using errcode = '22023';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'master payload must be an object' using errcode = '22023';
  end if;
  if p_mode = 'UPDATE' and p_payload = '{}'::jsonb then
    raise exception 'update payload must not be empty' using errcode = '22023';
  end if;

  case p_master_type
    when 'organizational_units' then
      v_allowed := array['code','name_vi','name_en'];
      v_required := array['name_vi'];
    when 'department_teams' then
      v_allowed := array['unit_id','code','name_vi','name_en'];
      v_required := array['unit_id','name_vi'];
    when 'positions' then
      v_allowed := array['unit_id','department_team_id','position_group_id','code','name_vi','name_en'];
      v_required := array['unit_id','position_group_id','name_vi'];
    when 'position_groups' then
      v_allowed := array['code','name_vi','name_en','requires_demo_topic'];
      v_required := array['code','name_vi'];
    when 'qualification_levels' then
      v_allowed := array['code','name_vi','name_en'];
      v_required := array['code','name_vi'];
    when 'rooms' then
      v_allowed := array['code','display_name','building'];
      v_required := array['display_name'];
    when 'interview_formats' then
      v_allowed := array['code','name_vi','name_en','requires_room','requires_meeting_link'];
      v_required := array['code','name_vi'];
    when 'recruitment_sources' then
      v_allowed := array['code','name_vi','name_en'];
      v_required := array['code','name_vi'];
    when 'document_types' then
      v_allowed := array['code','name_vi','name_en','scope_code'];
      v_required := array['code','name_vi','scope_code'];
    when 'cancellation_reasons', 'rejection_reasons' then
      v_allowed := array['code','name_vi','name_en'];
      v_required := array['code','name_vi'];
    else
      raise exception 'unknown master type' using errcode = '22023';
  end case;

  if exists (
    select 1
    from jsonb_object_keys(p_payload) k(key_name)
    where not (k.key_name = any(v_allowed))
  ) then
    raise exception 'unknown master payload field' using errcode = '22023';
  end if;

  if p_mode = 'CREATE' and exists (
    select 1
    from unnest(v_required) required_key
    where not (p_payload ? required_key)
  ) then
    raise exception 'required master payload field missing' using errcode = '22023';
  end if;

  for v_key in select jsonb_object_keys(p_payload)
  loop
    if v_key in ('code','name_vi','name_en','display_name','building','scope_code') then
      if jsonb_typeof(p_payload -> v_key) not in ('string','null') then
        raise exception 'master text field has invalid type' using errcode = '22023';
      end if;
      v_value := nullif(btrim(p_payload ->> v_key), '');
      if v_key = any(v_required) and v_value is null then
        raise exception 'required master text field is blank' using errcode = '22023';
      end if;
      if v_key = 'scope_code' then
        v_value := upper(v_value);
        if v_value not in ('SUBMISSION','INTERVIEW','BOTH') then
          raise exception 'invalid document scope' using errcode = '22023';
        end if;
      end if;
      v_norm := v_norm || jsonb_build_object(v_key, v_value);
    elsif v_key in ('unit_id','department_team_id','position_group_id') then
      if jsonb_typeof(p_payload -> v_key) not in ('string','null') then
        raise exception 'master uuid field has invalid type' using errcode = '22023';
      end if;
      v_value := nullif(btrim(p_payload ->> v_key), '');
      if v_key = any(v_required) and v_value is null then
        raise exception 'required master uuid field missing' using errcode = '22023';
      end if;
      v_uuid := case when v_value is null then null else v_value::uuid end;
      v_norm := v_norm || jsonb_build_object(v_key, v_uuid);
    elsif v_key in ('requires_demo_topic','requires_room','requires_meeting_link') then
      if jsonb_typeof(p_payload -> v_key) <> 'boolean' then
        raise exception 'master boolean field has invalid type' using errcode = '22023';
      end if;
      v_bool := (p_payload ->> v_key)::boolean;
      v_norm := v_norm || jsonb_build_object(v_key, v_bool);
    else
      raise exception 'unhandled master payload field' using errcode = '22023';
    end if;
  end loop;

  -- CREATE fingerprints canonicalize omitted nullable/default fields so transport
  -- representation does not change command meaning.
  if p_mode = 'CREATE' then
    case p_master_type
      when 'organizational_units' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en'
        );
      when 'department_teams' then
        v_norm := jsonb_build_object(
          'unit_id', v_norm->'unit_id', 'code', v_norm->'code',
          'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en'
        );
      when 'positions' then
        v_norm := jsonb_build_object(
          'unit_id', v_norm->'unit_id', 'department_team_id', v_norm->'department_team_id',
          'position_group_id', v_norm->'position_group_id', 'code', v_norm->'code',
          'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en'
        );
      when 'position_groups' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en',
          'requires_demo_topic', coalesce((v_norm->>'requires_demo_topic')::boolean, false)
        );
      when 'qualification_levels' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en'
        );
      when 'rooms' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'display_name', v_norm->'display_name', 'building', v_norm->'building'
        );
      when 'interview_formats' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en',
          'requires_room', coalesce((v_norm->>'requires_room')::boolean, false),
          'requires_meeting_link', coalesce((v_norm->>'requires_meeting_link')::boolean, false)
        );
      when 'recruitment_sources' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en'
        );
      when 'document_types' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en',
          'scope_code', v_norm->'scope_code'
        );
      when 'cancellation_reasons', 'rejection_reasons' then
        v_norm := jsonb_build_object(
          'code', v_norm->'code', 'name_vi', v_norm->'name_vi', 'name_en', v_norm->'name_en'
        );
    end case;
  end if;

  return v_norm;
end;
$$;

revoke all on function private.master_command_actor() from public, anon, authenticated;
revoke all on function private.master_usage_exists(text, uuid) from public, anon, authenticated;
revoke all on function private.normalize_master_payload(text, jsonb, text) from public, anon, authenticated;
grant execute on function private.master_command_actor() to postgres, service_role;
grant execute on function private.master_usage_exists(text, uuid) to postgres, service_role;
grant execute on function private.normalize_master_payload(text, jsonb, text) to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. create_master_item
-- -----------------------------------------------------------------------------
create or replace function public.create_master_item(
  p_master_type text,
  p_payload jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor uuid;
  v_type text := lower(btrim(coalesce(p_master_type, '')));
  v_norm jsonb;
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_id uuid;
  v_version bigint;
  v_result jsonb;
  v_unit uuid;
  v_team uuid;
  v_group uuid;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;
  v_actor := private.master_command_actor();
  if v_actor is null then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;
  if p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;
  if v_type not in (
    'organizational_units','department_teams','positions','position_groups',
    'qualification_levels','rooms','interview_formats','recruitment_sources',
    'document_types','cancellation_reasons','rejection_reasons'
  ) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  begin
    v_norm := private.normalize_master_payload(v_type, p_payload, 'CREATE');
  exception
    when invalid_parameter_value or invalid_text_representation then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end;

  v_scope := 'app_user:' || v_actor::text || ':master:' || v_type;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'create_master_item',
        'master_type', v_type,
        'payload', v_norm
      )::text,
      'sha256'
    ),
    'hex'
  );

  perform pg_advisory_xact_lock(
    hashtextextended(v_scope || ':create_master_item:' || p_idempotency_key::text, 0)
  );

  select r.result_payload into v_existing
  from public.idempotency_records r
  where r.actor_scope = v_scope
    and r.command_type = 'create_master_item'
    and r.idempotency_key = p_idempotency_key;
  if found then
    if v_existing->>'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
    return v_existing->'result';
  end if;

  -- Parent/hierarchy validation occurs only for a new logical execution, not replay.
  if v_type = 'department_teams' then
    v_unit := (v_norm->>'unit_id')::uuid;
    if not exists (
      select 1 from public.organizational_units u where u.unit_id = v_unit and u.is_active = true
    ) then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
  elsif v_type = 'positions' then
    v_unit := (v_norm->>'unit_id')::uuid;
    v_team := nullif(v_norm->>'department_team_id', '')::uuid;
    v_group := (v_norm->>'position_group_id')::uuid;
    if not exists (
      select 1 from public.organizational_units u where u.unit_id = v_unit and u.is_active = true
    ) or not exists (
      select 1 from public.position_groups g where g.position_group_id = v_group and g.is_active = true
    ) or (
      v_team is not null and not exists (
        select 1 from public.department_teams t
        where t.department_team_id = v_team and t.unit_id = v_unit and t.is_active = true
      )
    ) then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
  end if;

  begin
    case v_type
      when 'organizational_units' then
        insert into public.organizational_units(code, name_vi, name_en, is_active)
        values (nullif(v_norm->>'code',''), v_norm->>'name_vi', nullif(v_norm->>'name_en',''), true)
        returning unit_id, version_no into v_id, v_version;
      when 'department_teams' then
        insert into public.department_teams(unit_id, code, name_vi, name_en, is_active)
        values ((v_norm->>'unit_id')::uuid, nullif(v_norm->>'code',''), v_norm->>'name_vi', nullif(v_norm->>'name_en',''), true)
        returning department_team_id, version_no into v_id, v_version;
      when 'positions' then
        insert into public.positions(unit_id, department_team_id, position_group_id, code, name_vi, name_en, is_active)
        values (
          (v_norm->>'unit_id')::uuid,
          nullif(v_norm->>'department_team_id','')::uuid,
          (v_norm->>'position_group_id')::uuid,
          nullif(v_norm->>'code',''), v_norm->>'name_vi', nullif(v_norm->>'name_en',''), true
        ) returning position_id, version_no into v_id, v_version;
      when 'position_groups' then
        insert into public.position_groups(code, name_vi, name_en, requires_demo_topic, is_active)
        values (
          v_norm->>'code', v_norm->>'name_vi', nullif(v_norm->>'name_en',''),
          (v_norm->>'requires_demo_topic')::boolean, true
        ) returning position_group_id, version_no into v_id, v_version;
      when 'qualification_levels' then
        insert into public.qualification_levels(code, name_vi, name_en, is_active)
        values (v_norm->>'code', v_norm->>'name_vi', nullif(v_norm->>'name_en',''), true)
        returning qualification_id, version_no into v_id, v_version;
      when 'rooms' then
        insert into public.rooms(code, display_name, building, is_active)
        values (nullif(v_norm->>'code',''), v_norm->>'display_name', nullif(v_norm->>'building',''), true)
        returning room_id, version_no into v_id, v_version;
      when 'interview_formats' then
        insert into public.interview_formats(code, name_vi, name_en, requires_room, requires_meeting_link, is_active)
        values (
          v_norm->>'code', v_norm->>'name_vi', nullif(v_norm->>'name_en',''),
          (v_norm->>'requires_room')::boolean, (v_norm->>'requires_meeting_link')::boolean, true
        ) returning interview_format_id, version_no into v_id, v_version;
      when 'recruitment_sources' then
        insert into public.recruitment_sources(code, name_vi, name_en, is_active)
        values (v_norm->>'code', v_norm->>'name_vi', nullif(v_norm->>'name_en',''), true)
        returning recruitment_source_id, version_no into v_id, v_version;
      when 'document_types' then
        insert into public.document_types(code, name_vi, name_en, scope_code, is_active)
        values (v_norm->>'code', v_norm->>'name_vi', nullif(v_norm->>'name_en',''), v_norm->>'scope_code', true)
        returning document_type_id, version_no into v_id, v_version;
      when 'cancellation_reasons' then
        insert into public.cancellation_reasons(code, name_vi, name_en, is_active)
        values (v_norm->>'code', v_norm->>'name_vi', nullif(v_norm->>'name_en',''), true)
        returning cancellation_reason_id, version_no into v_id, v_version;
      when 'rejection_reasons' then
        insert into public.rejection_reasons(code, name_vi, name_en, is_active)
        values (v_norm->>'code', v_norm->>'name_vi', nullif(v_norm->>'name_en',''), true)
        returning rejection_reason_id, version_no into v_id, v_version;
    end case;
  exception
    when unique_violation or foreign_key_violation or check_violation or not_null_violation then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end;

  insert into public.security_audit_log(
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
    request_id, source_code, result_code, diff, metadata
  ) values (
    v_auth_uid, v_actor, 'MASTER_DATA_CREATE', upper(v_type), v_id,
    p_idempotency_key, 'RPC', 'SUCCESS', jsonb_build_object('after', v_norm),
    jsonb_build_object('master_type', v_type, 'version_no', v_version)
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'master_type', v_type,
      'master_id', v_id,
      'is_active', true,
      'version_no', v_version
    )
  );

  insert into public.idempotency_records(
    actor_scope, command_type, idempotency_key,
    result_entity_type, result_entity_id, result_payload
  ) values (
    v_scope, 'create_master_item', p_idempotency_key,
    upper(v_type), v_id,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  );

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. update_master_item
-- -----------------------------------------------------------------------------
create or replace function public.update_master_item(
  p_master_type text,
  p_master_id uuid,
  p_payload jsonb,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor uuid;
  v_type text := lower(btrim(coalesce(p_master_type, '')));
  v_norm jsonb;
  v_present_keys jsonb;
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_row record;
  v_used boolean;
  v_id uuid;
  v_version bigint;
  v_active boolean;
  v_result jsonb;
  v_unit uuid;
  v_team uuid;
  v_group uuid;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;
  v_actor := private.master_command_actor();
  if v_actor is null then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;
  if p_master_id is null or p_expected_version_no is null or p_expected_version_no < 1 or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;
  if v_type not in (
    'organizational_units','department_teams','positions','position_groups',
    'qualification_levels','rooms','interview_formats','recruitment_sources',
    'document_types','cancellation_reasons','rejection_reasons'
  ) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  begin
    v_norm := private.normalize_master_payload(v_type, p_payload, 'UPDATE');
  exception
    when invalid_parameter_value or invalid_text_representation then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end;

  select coalesce(jsonb_agg(k.key_name order by k.key_name), '[]'::jsonb)
  into v_present_keys
  from jsonb_object_keys(p_payload) k(key_name);

  v_scope := 'app_user:' || v_actor::text || ':master:' || v_type || ':target:' || p_master_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'update_master_item', 'master_type', v_type,
        'master_id', p_master_id, 'expected_version_no', p_expected_version_no,
        'payload', v_norm, 'present_keys', v_present_keys
      )::text,
      'sha256'
    ),
    'hex'
  );

  perform pg_advisory_xact_lock(
    hashtextextended(v_scope || ':update_master_item:' || p_idempotency_key::text, 0)
  );
  select r.result_payload into v_existing
  from public.idempotency_records r
  where r.actor_scope = v_scope
    and r.command_type = 'update_master_item'
    and r.idempotency_key = p_idempotency_key;
  if found then
    if v_existing->>'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
    return v_existing->'result';
  end if;

  -- Lock and re-resolve exact target before version or history checks.
  case v_type
    when 'organizational_units' then select * into v_row from public.organizational_units where unit_id = p_master_id for update;
    when 'department_teams' then select * into v_row from public.department_teams where department_team_id = p_master_id for update;
    when 'positions' then select * into v_row from public.positions where position_id = p_master_id for update;
    when 'position_groups' then select * into v_row from public.position_groups where position_group_id = p_master_id for update;
    when 'qualification_levels' then select * into v_row from public.qualification_levels where qualification_id = p_master_id for update;
    when 'rooms' then select * into v_row from public.rooms where room_id = p_master_id for update;
    when 'interview_formats' then select * into v_row from public.interview_formats where interview_format_id = p_master_id for update;
    when 'recruitment_sources' then select * into v_row from public.recruitment_sources where recruitment_source_id = p_master_id for update;
    when 'document_types' then select * into v_row from public.document_types where document_type_id = p_master_id for update;
    when 'cancellation_reasons' then select * into v_row from public.cancellation_reasons where cancellation_reason_id = p_master_id for update;
    when 'rejection_reasons' then select * into v_row from public.rejection_reasons where rejection_reason_id = p_master_id for update;
  end case;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_row.version_no <> p_expected_version_no then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  v_used := private.master_usage_exists(v_type, p_master_id);

  -- Referenced structural business meaning is immutable. Label corrections stay allowed.
  if v_used then
    case v_type
      when 'organizational_units' then
        if p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'department_teams' then
        if (p_payload ? 'unit_id' and (v_norm->>'unit_id')::uuid is distinct from v_row.unit_id)
           or (p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code) then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'positions' then
        if (p_payload ? 'unit_id' and (v_norm->>'unit_id')::uuid is distinct from v_row.unit_id)
           or (p_payload ? 'department_team_id' and nullif(v_norm->>'department_team_id','')::uuid is distinct from v_row.department_team_id)
           or (p_payload ? 'position_group_id' and (v_norm->>'position_group_id')::uuid is distinct from v_row.position_group_id)
           or (p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code) then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'position_groups' then
        if p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'qualification_levels' then
        if p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'rooms' then
        if (p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code)
           or (p_payload ? 'building' and (v_norm->>'building') is distinct from v_row.building) then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'interview_formats' then
        if (p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code)
           or (p_payload ? 'requires_room' and (v_norm->>'requires_room')::boolean is distinct from v_row.requires_room)
           or (p_payload ? 'requires_meeting_link' and (v_norm->>'requires_meeting_link')::boolean is distinct from v_row.requires_meeting_link) then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'recruitment_sources' then
        if p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'document_types' then
        if (p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code)
           or (p_payload ? 'scope_code' and (v_norm->>'scope_code') is distinct from v_row.scope_code) then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
      when 'cancellation_reasons', 'rejection_reasons' then
        if p_payload ? 'code' and (v_norm->>'code') is distinct from v_row.code then
          return jsonb_build_object('success', false, 'error_code', 'MASTER_STRUCTURAL_HISTORY');
        end if;
    end case;
  end if;

  -- New structural parent selections must still resolve to active, consistent masters.
  if v_type = 'department_teams' and p_payload ? 'unit_id' then
    v_unit := (v_norm->>'unit_id')::uuid;
    if not exists (select 1 from public.organizational_units u where u.unit_id = v_unit and u.is_active = true) then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
  elsif v_type = 'positions' and (
    p_payload ? 'unit_id' or p_payload ? 'department_team_id' or p_payload ? 'position_group_id'
  ) then
    v_unit := case when p_payload ? 'unit_id' then (v_norm->>'unit_id')::uuid else v_row.unit_id end;
    v_team := case when p_payload ? 'department_team_id' then nullif(v_norm->>'department_team_id','')::uuid else v_row.department_team_id end;
    v_group := case when p_payload ? 'position_group_id' then (v_norm->>'position_group_id')::uuid else v_row.position_group_id end;
    if not exists (select 1 from public.organizational_units u where u.unit_id = v_unit and u.is_active = true)
       or not exists (select 1 from public.position_groups g where g.position_group_id = v_group and g.is_active = true)
       or (v_team is not null and not exists (
         select 1 from public.department_teams t
         where t.department_team_id = v_team and t.unit_id = v_unit and t.is_active = true
       )) then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
  end if;

  begin
    case v_type
      when 'organizational_units' then
        update public.organizational_units set
          code = case when p_payload ? 'code' then nullif(v_norm->>'code','') else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end
        where unit_id = p_master_id returning unit_id, version_no, is_active into v_id, v_version, v_active;
      when 'department_teams' then
        update public.department_teams set
          unit_id = case when p_payload ? 'unit_id' then (v_norm->>'unit_id')::uuid else unit_id end,
          code = case when p_payload ? 'code' then nullif(v_norm->>'code','') else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end
        where department_team_id = p_master_id returning department_team_id, version_no, is_active into v_id, v_version, v_active;
      when 'positions' then
        update public.positions set
          unit_id = case when p_payload ? 'unit_id' then (v_norm->>'unit_id')::uuid else unit_id end,
          department_team_id = case when p_payload ? 'department_team_id' then nullif(v_norm->>'department_team_id','')::uuid else department_team_id end,
          position_group_id = case when p_payload ? 'position_group_id' then (v_norm->>'position_group_id')::uuid else position_group_id end,
          code = case when p_payload ? 'code' then nullif(v_norm->>'code','') else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end
        where position_id = p_master_id returning position_id, version_no, is_active into v_id, v_version, v_active;
      when 'position_groups' then
        update public.position_groups set
          code = case when p_payload ? 'code' then v_norm->>'code' else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end,
          requires_demo_topic = case when p_payload ? 'requires_demo_topic' then (v_norm->>'requires_demo_topic')::boolean else requires_demo_topic end
        where position_group_id = p_master_id returning position_group_id, version_no, is_active into v_id, v_version, v_active;
      when 'qualification_levels' then
        update public.qualification_levels set
          code = case when p_payload ? 'code' then v_norm->>'code' else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end
        where qualification_id = p_master_id returning qualification_id, version_no, is_active into v_id, v_version, v_active;
      when 'rooms' then
        update public.rooms set
          code = case when p_payload ? 'code' then nullif(v_norm->>'code','') else code end,
          display_name = case when p_payload ? 'display_name' then v_norm->>'display_name' else display_name end,
          building = case when p_payload ? 'building' then nullif(v_norm->>'building','') else building end
        where room_id = p_master_id returning room_id, version_no, is_active into v_id, v_version, v_active;
      when 'interview_formats' then
        update public.interview_formats set
          code = case when p_payload ? 'code' then v_norm->>'code' else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end,
          requires_room = case when p_payload ? 'requires_room' then (v_norm->>'requires_room')::boolean else requires_room end,
          requires_meeting_link = case when p_payload ? 'requires_meeting_link' then (v_norm->>'requires_meeting_link')::boolean else requires_meeting_link end
        where interview_format_id = p_master_id returning interview_format_id, version_no, is_active into v_id, v_version, v_active;
      when 'recruitment_sources' then
        update public.recruitment_sources set
          code = case when p_payload ? 'code' then v_norm->>'code' else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end
        where recruitment_source_id = p_master_id returning recruitment_source_id, version_no, is_active into v_id, v_version, v_active;
      when 'document_types' then
        update public.document_types set
          code = case when p_payload ? 'code' then v_norm->>'code' else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end,
          scope_code = case when p_payload ? 'scope_code' then v_norm->>'scope_code' else scope_code end
        where document_type_id = p_master_id returning document_type_id, version_no, is_active into v_id, v_version, v_active;
      when 'cancellation_reasons' then
        update public.cancellation_reasons set
          code = case when p_payload ? 'code' then v_norm->>'code' else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end
        where cancellation_reason_id = p_master_id returning cancellation_reason_id, version_no, is_active into v_id, v_version, v_active;
      when 'rejection_reasons' then
        update public.rejection_reasons set
          code = case when p_payload ? 'code' then v_norm->>'code' else code end,
          name_vi = case when p_payload ? 'name_vi' then v_norm->>'name_vi' else name_vi end,
          name_en = case when p_payload ? 'name_en' then nullif(v_norm->>'name_en','') else name_en end
        where rejection_reason_id = p_master_id returning rejection_reason_id, version_no, is_active into v_id, v_version, v_active;
    end case;
  exception
    when unique_violation or foreign_key_violation or check_violation or not_null_violation then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end;

  insert into public.security_audit_log(
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
    request_id, source_code, result_code, diff, metadata
  ) values (
    v_auth_uid, v_actor, 'MASTER_DATA_UPDATE', upper(v_type), v_id,
    p_idempotency_key, 'RPC', 'SUCCESS', jsonb_build_object('requested_changes', v_norm),
    jsonb_build_object('master_type', v_type, 'version_no', v_version, 'referenced', v_used, 'changed_fields', v_present_keys)
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'master_type', v_type, 'master_id', v_id,
      'is_active', v_active, 'version_no', v_version
    )
  );

  insert into public.idempotency_records(
    actor_scope, command_type, idempotency_key,
    result_entity_type, result_entity_id, result_payload
  ) values (
    v_scope, 'update_master_item', p_idempotency_key,
    upper(v_type), v_id,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  );

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. delete_or_inactivate_master_item
-- -----------------------------------------------------------------------------
create or replace function public.delete_or_inactivate_master_item(
  p_master_type text,
  p_master_id uuid,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor uuid;
  v_type text := lower(btrim(coalesce(p_master_type, '')));
  v_scope text;
  v_fingerprint text;
  v_existing jsonb;
  v_row record;
  v_used boolean;
  v_version bigint;
  v_result jsonb;
  v_outcome text;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;
  v_actor := private.master_command_actor();
  if v_actor is null then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;
  if p_master_id is null or p_expected_version_no is null or p_expected_version_no < 1 or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;
  if v_type not in (
    'organizational_units','department_teams','positions','position_groups',
    'qualification_levels','rooms','interview_formats','recruitment_sources',
    'document_types','cancellation_reasons','rejection_reasons'
  ) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  v_scope := 'app_user:' || v_actor::text || ':master:' || v_type || ':target:' || p_master_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'delete_or_inactivate_master_item',
        'master_type', v_type, 'master_id', p_master_id,
        'expected_version_no', p_expected_version_no
      )::text,
      'sha256'
    ),
    'hex'
  );

  perform pg_advisory_xact_lock(
    hashtextextended(v_scope || ':delete_or_inactivate_master_item:' || p_idempotency_key::text, 0)
  );
  select r.result_payload into v_existing
  from public.idempotency_records r
  where r.actor_scope = v_scope
    and r.command_type = 'delete_or_inactivate_master_item'
    and r.idempotency_key = p_idempotency_key;
  if found then
    if v_existing->>'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
    return v_existing->'result';
  end if;

  -- Required ordering: exact target lock -> locked version check -> usage/lifecycle decision.
  case v_type
    when 'organizational_units' then select * into v_row from public.organizational_units where unit_id = p_master_id for update;
    when 'department_teams' then select * into v_row from public.department_teams where department_team_id = p_master_id for update;
    when 'positions' then select * into v_row from public.positions where position_id = p_master_id for update;
    when 'position_groups' then select * into v_row from public.position_groups where position_group_id = p_master_id for update;
    when 'qualification_levels' then select * into v_row from public.qualification_levels where qualification_id = p_master_id for update;
    when 'rooms' then select * into v_row from public.rooms where room_id = p_master_id for update;
    when 'interview_formats' then select * into v_row from public.interview_formats where interview_format_id = p_master_id for update;
    when 'recruitment_sources' then select * into v_row from public.recruitment_sources where recruitment_source_id = p_master_id for update;
    when 'document_types' then select * into v_row from public.document_types where document_type_id = p_master_id for update;
    when 'cancellation_reasons' then select * into v_row from public.cancellation_reasons where cancellation_reason_id = p_master_id for update;
    when 'rejection_reasons' then select * into v_row from public.rejection_reasons where rejection_reason_id = p_master_id for update;
  end case;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_row.version_no <> p_expected_version_no then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  v_used := private.master_usage_exists(v_type, p_master_id);
  v_version := v_row.version_no;

  if not v_used then
    begin
      case v_type
        when 'organizational_units' then delete from public.organizational_units where unit_id = p_master_id;
        when 'department_teams' then delete from public.department_teams where department_team_id = p_master_id;
        when 'positions' then delete from public.positions where position_id = p_master_id;
        when 'position_groups' then delete from public.position_groups where position_group_id = p_master_id;
        when 'qualification_levels' then delete from public.qualification_levels where qualification_id = p_master_id;
        when 'rooms' then delete from public.rooms where room_id = p_master_id;
        when 'interview_formats' then delete from public.interview_formats where interview_format_id = p_master_id;
        when 'recruitment_sources' then delete from public.recruitment_sources where recruitment_source_id = p_master_id;
        when 'document_types' then delete from public.document_types where document_type_id = p_master_id;
        when 'cancellation_reasons' then delete from public.cancellation_reasons where cancellation_reason_id = p_master_id;
        when 'rejection_reasons' then delete from public.rejection_reasons where rejection_reason_id = p_master_id;
      end case;
      v_outcome := 'DELETED';
    exception
      when foreign_key_violation then
        -- A reference committed before our target lock was acquired: preserve history.
        v_used := true;
    end;
  end if;

  if v_used then
    case v_type
      when 'organizational_units' then update public.organizational_units set is_active = false where unit_id = p_master_id returning version_no into v_version;
      when 'department_teams' then update public.department_teams set is_active = false where department_team_id = p_master_id returning version_no into v_version;
      when 'positions' then update public.positions set is_active = false where position_id = p_master_id returning version_no into v_version;
      when 'position_groups' then update public.position_groups set is_active = false where position_group_id = p_master_id returning version_no into v_version;
      when 'qualification_levels' then update public.qualification_levels set is_active = false where qualification_id = p_master_id returning version_no into v_version;
      when 'rooms' then update public.rooms set is_active = false where room_id = p_master_id returning version_no into v_version;
      when 'interview_formats' then update public.interview_formats set is_active = false where interview_format_id = p_master_id returning version_no into v_version;
      when 'recruitment_sources' then update public.recruitment_sources set is_active = false where recruitment_source_id = p_master_id returning version_no into v_version;
      when 'document_types' then update public.document_types set is_active = false where document_type_id = p_master_id returning version_no into v_version;
      when 'cancellation_reasons' then update public.cancellation_reasons set is_active = false where cancellation_reason_id = p_master_id returning version_no into v_version;
      when 'rejection_reasons' then update public.rejection_reasons set is_active = false where rejection_reason_id = p_master_id returning version_no into v_version;
    end case;
    v_outcome := 'INACTIVATED';
  end if;

  insert into public.security_audit_log(
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id,
    request_id, source_code, result_code, metadata
  ) values (
    v_auth_uid, v_actor,
    case when v_outcome = 'DELETED' then 'MASTER_DATA_DELETE' else 'MASTER_DATA_INACTIVATE' end,
    upper(v_type), p_master_id, p_idempotency_key, 'RPC', 'SUCCESS',
    jsonb_build_object('master_type', v_type, 'outcome', v_outcome, 'version_no', v_version)
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'master_type', v_type,
      'master_id', p_master_id,
      'outcome', v_outcome,
      'is_active', case when v_outcome = 'DELETED' then null else false end,
      'version_no', v_version
    )
  );

  insert into public.idempotency_records(
    actor_scope, command_type, idempotency_key,
    result_entity_type, result_entity_id, result_payload
  ) values (
    v_scope, 'delete_or_inactivate_master_item', p_idempotency_key,
    upper(v_type), p_master_id,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  );

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Explicit command ACLs and deny-by-default direct DML.
-- Existing SELECT/anonymous lookup grants are intentionally left unchanged.
-- -----------------------------------------------------------------------------
revoke insert, update, delete on
  public.organizational_units,
  public.department_teams,
  public.positions,
  public.position_groups,
  public.qualification_levels,
  public.rooms,
  public.interview_formats,
  public.recruitment_sources,
  public.document_types,
  public.cancellation_reasons,
  public.rejection_reasons
from public, anon, authenticated;

grant all on
  public.organizational_units,
  public.department_teams,
  public.positions,
  public.position_groups,
  public.qualification_levels,
  public.rooms,
  public.interview_formats,
  public.recruitment_sources,
  public.document_types,
  public.cancellation_reasons,
  public.rejection_reasons
  to postgres, service_role;

revoke all on function public.create_master_item(text, jsonb, uuid) from public, anon;
revoke all on function public.update_master_item(text, uuid, jsonb, bigint, uuid) from public, anon;
revoke all on function public.delete_or_inactivate_master_item(text, uuid, bigint, uuid) from public, anon;
grant execute on function public.create_master_item(text, jsonb, uuid) to authenticated, postgres, service_role;
grant execute on function public.update_master_item(text, uuid, jsonb, bigint, uuid) to authenticated, postgres, service_role;
grant execute on function public.delete_or_inactivate_master_item(text, uuid, bigint, uuid) to authenticated, postgres, service_role;
