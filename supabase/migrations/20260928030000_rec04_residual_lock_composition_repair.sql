-- RECOVERY PACKAGE 009: REC-04 residual global lock-composition repair
--
-- Canonical mutation order for the routines replaced here:
-- Candidate -> Submission -> Application -> Interview -> resource advisory ->
-- complete sorted app_user rows -> matching internal-user advisories -> writes/audit.
-- Implicit audit foreign-key locks are accounted for by prelocking the actor
-- whenever the command otherwise acquires an app_user row.

create or replace function public.bulk_create_or_update_applications(
  p_submission_ids uuid[],
  p_unit_id uuid,
  p_department_team_id uuid,
  p_position_id uuid,
  p_hr_owner_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_unit record;
  v_team record;
  v_position record;
  v_actor record;
  v_hr_owner record;
  v_application record;
  v_submission record;
  v_result_items jsonb := '[]'::jsonb;
  v_result jsonb;
  v_count integer;
  v_application_id uuid;
  v_round1_interview_id uuid;
  v_version_no bigint;
  v_action text;
  v_old_owner_id uuid;
  v_old_version_no bigint;
  v_user_lock_ids uuid[];
begin
  v_auth_user_id := auth.uid();
  if v_auth_user_id is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select u.app_user_id into v_actor_app_user_id
  from public.app_users u
  where u.auth_user_id = v_auth_user_id
    and u.is_active = true;

  if v_actor_app_user_id is null
    or not (
      (private.has_permission('applications.manage') and private.has_permission('submissions.view'))
      or private.is_root_admin()
    ) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permissions applications.manage and submissions.view required');
  end if;

  if p_submission_ids is null
    or cardinality(p_submission_ids) = 0
    or array_position(p_submission_ids, null) is not null
    or exists (
      select 1
      from unnest(p_submission_ids) as s(submission_id)
      group by s.submission_id
      having count(*) > 1
    )
    or p_unit_id is null
    or p_position_id is null
    or p_hr_owner_id is null
    or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid bulk Application assignment request');
  end if;

  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'bulk_create_or_update_applications',
        'submission_ids', to_jsonb(p_submission_ids),
        'unit_id', p_unit_id,
        'department_team_id', p_department_team_id,
        'position_id', p_position_id,
        'hr_owner_id', p_hr_owner_id
      )::text,
      'sha256'
    ),
    'hex'
  );

  perform pg_advisory_xact_lock(hashtextextended(v_actor_scope || ':bulk_create_or_update_applications:' || p_idempotency_key::text, 0));

  select r.result_payload into v_existing_result
  from public.idempotency_records r
  where r.actor_scope = v_actor_scope
    and r.command_type = 'bulk_create_or_update_applications'
    and r.idempotency_key = p_idempotency_key;

  if found then
    if v_existing_result ->> 'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key has already been used for a different request');
    end if;
    return v_existing_result -> 'result';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('bulk-candidate:' || c.candidate_id::text, 0))
  from (
    select distinct s.candidate_id
    from public.submissions s
    where s.submission_id = any(p_submission_ids)
    order by s.candidate_id
  ) c;

  select * into v_unit
  from public.organizational_units u
  where u.unit_id = p_unit_id
    and u.is_active = true
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Organizational unit not found or inactive');
  end if;

  if p_department_team_id is not null then
    select * into v_team
    from public.department_teams t
    where t.department_team_id = p_department_team_id
      and t.unit_id = p_unit_id
      and t.is_active = true
    for update;

    if not found then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_HIERARCHY', 'message', 'Department team does not belong to organizational unit or is inactive');
    end if;
  end if;

  select * into v_position
  from public.positions p
  where p.position_id = p_position_id
    and p.unit_id = p_unit_id
    and p.department_team_id is not distinct from p_department_team_id
    and p.is_active = true
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_HIERARCHY', 'message', 'Position does not match unit/team hierarchy or is inactive');
  end if;

  if not exists (
    select 1 from public.app_users u
    where u.app_user_id = p_hr_owner_id
      and u.is_active = true
      and (u.is_root_admin or exists (
        select 1 from public.app_user_roles r
        where r.app_user_id = u.app_user_id and r.role_code = 'HR'
      ))
  ) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Active HR owner not found');
  end if;

  select count(*) into v_count
  from public.submissions s
  where s.submission_id = any(p_submission_ids);

  if v_count <> cardinality(p_submission_ids) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'One or more Submissions were not found');
  end if;

  perform 1
  from public.candidates c
  where c.candidate_id in (
    select s.candidate_id
    from public.submissions s
    where s.submission_id = any(p_submission_ids)
  )
  order by c.candidate_id
  for update;

  perform 1
  from public.submissions s
  where s.submission_id = any(p_submission_ids)
  order by s.submission_id
  for update;

  perform 1
  from public.applications a
  where a.submission_id = any(p_submission_ids)
    and a.unit_id = p_unit_id
    and a.department_team_id is not distinct from p_department_team_id
    and a.position_id = p_position_id
  order by a.submission_id, a.application_id
  for update;

  -- Complete the actor/owner union before either audit FK can acquire an
  -- implicit actor lock. This preserves the parent-before-User hierarchy and
  -- matches Copy and participant commands' sorted row/advisory composition.
  select array_agg(distinct app_user_id order by app_user_id)
  into v_user_lock_ids
  from unnest(array[v_actor_app_user_id, p_hr_owner_id]) as q(app_user_id);

  if v_actor_app_user_id < p_hr_owner_id then
    select u.* into v_actor from public.app_users u where u.app_user_id = v_actor_app_user_id for update;
    if p_hr_owner_id <> v_actor_app_user_id then
      select u.* into v_hr_owner from public.app_users u where u.app_user_id = p_hr_owner_id for update;
    end if;
  else
    select u.* into v_hr_owner from public.app_users u where u.app_user_id = p_hr_owner_id for update;
    if p_hr_owner_id <> v_actor_app_user_id then
      select u.* into v_actor from public.app_users u where u.app_user_id = v_actor_app_user_id for update;
    end if;
  end if;
  perform private.lock_internal_user_ids(v_user_lock_ids);

  select u.* into v_hr_owner
  from public.app_users u
  where u.app_user_id = p_hr_owner_id
    and u.is_active = true
    and (
      u.is_root_admin
      or exists (
        select 1
        from public.app_user_roles r
        where r.app_user_id = u.app_user_id
          and r.role_code = 'HR'
      )
    );

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Active HR owner not found');
  end if;

  if exists (
    select 1
    from public.applications a
    where a.submission_id = any(p_submission_ids)
      and a.unit_id = p_unit_id
      and a.department_team_id is not distinct from p_department_team_id
      and a.position_id = p_position_id
      and not a.is_active
  ) then
    return jsonb_build_object('success', false, 'error_code', 'ALREADY_EXISTS_INACTIVE', 'message', 'An inactive Application already exists for a selected durable identity');
  end if;

  for v_submission in
    select s.submission_id, s.ordinality
    from unnest(p_submission_ids) with ordinality as s(submission_id, ordinality)
    order by s.ordinality
  loop
    select a.* into v_application
    from public.applications a
    where a.submission_id = v_submission.submission_id
      and a.unit_id = p_unit_id
      and a.department_team_id is not distinct from p_department_team_id
      and a.position_id = p_position_id;

    if found then
      v_application_id := v_application.application_id;
      v_round1_interview_id := null;
      v_old_owner_id := v_application.hr_owner_id;
      v_old_version_no := v_application.version_no;
      v_version_no := v_application.version_no + 1;
      v_action := 'UPDATED';

      update public.applications
      set
        hr_owner_id = p_hr_owner_id,
        version_no = v_version_no,
        updated_at = clock_timestamp()
      where application_id = v_application_id;

      select i.interview_id into v_round1_interview_id
      from public.interviews i
      where i.application_id = v_application_id
        and i.round_no = 1;
    else
      v_application_id := gen_random_uuid();
      v_round1_interview_id := gen_random_uuid();
      v_old_owner_id := null;
      v_old_version_no := null;
      v_version_no := 1;
      v_action := 'CREATED';

      insert into public.applications (
        application_id, submission_id, unit_id, department_team_id, position_id, hr_owner_id, is_active, version_no, created_at, updated_at
      ) values (
        v_application_id, v_submission.submission_id, p_unit_id, p_department_team_id, p_position_id, p_hr_owner_id, true, 1, clock_timestamp(), clock_timestamp()
      );

      insert into public.interviews (
        interview_id, application_id, round_no, demo_topic, schedule_status_code, report_status_code, is_active, version_no, created_at, updated_at
      ) values (
        v_round1_interview_id, v_application_id, 1, null, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1, clock_timestamp(), clock_timestamp()
      );
    end if;

    insert into public.activity_log (
      entity_type, entity_id, action_code, actor_app_user_id, request_id, source_code, old_values, new_values
    ) values (
      'APPLICATION',
      v_application_id,
      'BULK_APPLICATION_ASSIGNMENT',
      v_actor_app_user_id,
      p_idempotency_key,
      'RPC',
      jsonb_build_object('hr_owner_id', v_old_owner_id, 'version_no', v_old_version_no),
      jsonb_build_object('hr_owner_id', p_hr_owner_id, 'version_no', v_version_no, 'action', v_action)
    );

    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'submission_id', v_submission.submission_id,
      'application_id', v_application_id,
      'action', v_action,
      'version_no', v_version_no,
      'round1_interview_id', v_round1_interview_id
    ));
  end loop;

  perform public.recalculate_submission_status(s.submission_id)
  from (
    select submission_id
    from unnest(p_submission_ids) as s(submission_id)
    order by submission_id
  ) s;

  insert into public.security_audit_log (
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id, request_id, source_code, metadata
  ) values (
    v_auth_user_id,
    v_actor_app_user_id,
    'BULK_APPLICATION_ASSIGNMENT',
    'BATCH',
    p_idempotency_key,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('request_fingerprint', v_fingerprint, 'selected_submission_ids', to_jsonb(p_submission_ids))
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('items', v_result_items, 'count', cardinality(p_submission_ids), 'idempotency_key', p_idempotency_key)
  );

  insert into public.idempotency_records (
    actor_scope, command_type, idempotency_key, result_entity_type, result_entity_id, result_payload
  ) values (
    v_actor_scope,
    'bulk_create_or_update_applications',
    p_idempotency_key,
    'BATCH',
    p_idempotency_key,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  );

  return v_result;
end;
$$;

revoke all on function public.bulk_create_or_update_applications(uuid[], uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.bulk_create_or_update_applications(uuid[], uuid, uuid, uuid, uuid, uuid) to authenticated, postgres, service_role;

create or replace function public.update_submission_by_hr(
  p_submission_id uuid,
  p_hr_note text default null,
  p_expected_version bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_can_edit boolean;
  v_sub public.submissions%rowtype;
  v_candidate_id uuid;
  v_new_version bigint;
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
begin
  if p_submission_id is null or p_expected_version is null or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'submission_id and positive expected_version are required');
  end if;

  v_can_edit := private.has_permission('submissions.edit') or private.is_root_admin();
  if not v_can_edit then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission submissions.edit required');
  end if;

  -- Resolve identity without retaining a Submission lock, then take the
  -- canonical Candidate -> Submission order used by assignment/reactivation.
  select s.candidate_id into v_candidate_id
  from public.submissions s
  where s.submission_id = p_submission_id;

  if not found or v_candidate_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Submission not found');
  end if;

  perform 1
  from public.candidates c
  where c.candidate_id = v_candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Submission candidate not found');
  end if;

  select * into v_sub
  from public.submissions
  where submission_id = p_submission_id
  for update;

  if not found or v_sub.candidate_id is distinct from v_candidate_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Submission not found');
  end if;

  -- Revalidate active/current authorization and the optimistic token after the
  -- authoritative target relationship is locked.
  v_can_edit := private.has_permission('submissions.edit') or private.is_root_admin();
  if not v_can_edit then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission submissions.edit required');
  end if;

  if v_sub.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Submission version mismatch');
  end if;

  v_new_version := v_sub.version_no + 1;
  v_auth_user_id := auth.uid();
  v_actor_app_user_id := private.current_app_user_id();

  update public.submissions
  set
    hr_note = nullif(btrim(p_hr_note), ''),
    version_no = v_new_version,
    updated_at = clock_timestamp(),
    updated_by_internal_user_id = v_actor_app_user_id
  where submission_id = p_submission_id;

  insert into public.security_audit_log (
    actor_auth_user_id,
    actor_app_user_id,
    action_code,
    entity_type,
    entity_id,
    source_code,
    result_code,
    metadata
  ) values (
    v_auth_user_id,
    v_actor_app_user_id,
    'SUBMISSION_HR_NOTE_UPDATE',
    'SUBMISSION',
    p_submission_id,
    'RPC',
    'SUCCESS',
    jsonb_build_object(
      'submission_id', p_submission_id,
      'candidate_id', v_sub.candidate_id,
      'old_version_no', v_sub.version_no,
      'new_version_no', v_new_version
    )
  );

  perform private.refresh_candidate_current_profile(v_candidate_id);

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', p_submission_id,
      'hr_note', p_hr_note,
      'version_no', v_new_version
    )
  );
end;
$$;

revoke all on function public.update_submission_by_hr(uuid, text, bigint) from public, anon;
grant execute on function public.update_submission_by_hr(uuid, text, bigint) to authenticated, postgres, service_role;

-- PostgreSQL applies LockRows before a top-level ORDER BY in a set-based
-- SELECT ... FOR UPDATE plan. Rebuild Copy's established definition with an
-- explicit loop so its actor/participant union is physically acquired in the
-- UUID order represented by v_user_lock_ids.
do $$
declare
  v_definition text;
  v_old_lock_block text := E'  perform 1\n  from public.app_users u\n  where u.app_user_id = any(v_user_lock_ids)\n  order by u.app_user_id\n  for update;\n\n  perform private.lock_internal_user_ids(v_user_lock_ids);';
  v_new_lock_block text := E'  foreach v_user_lock_id in array v_user_lock_ids loop\n    perform 1\n    from public.app_users u\n    where u.app_user_id = v_user_lock_id\n    for update;\n  end loop;\n\n  perform private.lock_internal_user_ids(v_user_lock_ids);';
begin
  select pg_get_functiondef(
    'public.copy_interview_schedule(uuid,uuid,bigint,bigint,uuid,bigint,timestamptz,timestamptz,uuid,uuid,text,text,uuid[],uuid)'::regprocedure
  ) into v_definition;

  if position(E'  v_user_lock_ids uuid[];\n' in v_definition) = 0
     or position(v_old_lock_block in v_definition) = 0 then
    raise exception 'REC04_COPY_LOCK_DEFINITION_DRIFT';
  end if;

  v_definition := replace(
    v_definition,
    E'  v_user_lock_ids uuid[];\n',
    E'  v_user_lock_ids uuid[];\n  v_user_lock_id uuid;\n'
  );
  v_definition := replace(v_definition, v_old_lock_block, v_new_lock_block);
  execute v_definition;
end;
$$;
