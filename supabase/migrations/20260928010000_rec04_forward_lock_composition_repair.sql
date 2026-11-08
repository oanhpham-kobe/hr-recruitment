-- RECOVERY PACKAGE 008: REC-04 forward lock-composition and version-boundary repair
-- After command-specific idempotency, reference, and candidate fences, crossed commands take
-- aggregate parents (Submission -> Application -> Interview), resource advisories, then the
-- complete sorted app_user row set followed by its user advisories.
-- Earlier accepted migrations remain immutable; this file only replaces effective routines forward.

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
  v_hr_owner record;
  v_application record;
  v_submission record;
  v_item jsonb;
  v_result_items jsonb := '[]'::jsonb;
  v_result jsonb;
  v_count integer;
  v_application_id uuid;
  v_round1_interview_id uuid;
  v_version_no bigint;
  v_action text;
  v_old_owner_id uuid;
  v_old_version_no bigint;
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
  -- Use the same candidate-scoped serialization as manual status before reference locks.
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

  -- Reference prevalidation only. The authoritative owner row lock follows the
  -- complete Submission/Application parent set, avoiding Copy's S -> User order.
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
  -- Match bulk status's Candidate -> Submission mutation-lock order.
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

  -- Composed REC-04 order: candidate/reference fences -> Submission -> Application -> User.
  -- Revalidate the owner after the parent hierarchy is locked.
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
    )
  for update;

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

create or replace function public.reactivate_application(
  p_application_id uuid,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_owner public.app_users%rowtype;
  v_interview public.interviews%rowtype;
  v_candidate_id uuid;
  v_room_id uuid;
  v_user_id uuid;
  v_interviewer_ids uuid[];
  v_user_lock_ids uuid[];
  v_conflict text;
  v_now timestamptz := transaction_timestamp();
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;
  select u.app_user_id into v_actor
  from public.app_users u
  where u.auth_user_id = auth.uid() and u.is_active;
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('applications.manage')) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;
  if p_application_id is null or p_expected_version is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- Resolve immutable identity, lock Submission first, then re-read and lock Application.
  select a.submission_id into v_submission_id
  from public.applications a where a.application_id = p_application_id;
  if v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  perform 1 from public.submissions s where s.submission_id = v_submission_id for update;
  select * into v_app from public.applications a
  where a.application_id = p_application_id and a.submission_id = v_submission_id
  for update;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_app.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;
  if v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE');
  end if;
  -- Lock every child before snapshotting participant/resource state. Only
  -- preserved-active, non-CANCELLED complete future intervals become operational.
  perform 1 from public.interviews i
  where i.application_id = p_application_id
  order by i.interview_id
  for update;
  select s.candidate_id into v_candidate_id
  from public.submissions s where s.submission_id = v_submission_id;

  for v_interview in
    select * from public.interviews i
    where i.application_id = p_application_id
      and i.is_active
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null
      and i.end_at > v_now
    order by i.interview_id
  loop
    if not private.all_current_participants_selectable(v_interview.interview_id) then
      return jsonb_build_object('success', false, 'error_code', 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED');
    end if;
  end loop;

  -- Deterministic global lock order: candidate, every room, every interviewer.
  if v_candidate_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('candidate:' || v_candidate_id::text, 0));
  end if;
  for v_room_id in
    select distinct i.room_id from public.interviews i
    where i.application_id = p_application_id and i.is_active
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null and i.end_at > v_now
      and i.room_id is not null
    order by i.room_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('room:' || v_room_id::text, 0));
  end loop;
  for v_user_id in
    select distinct ip.app_user_id
    from public.interview_participants ip
    join public.interviews i on i.interview_id = ip.interview_id
    where i.application_id = p_application_id and i.is_active and ip.is_current
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null and i.end_at > v_now
    order by ip.app_user_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('interviewer:' || v_user_id::text, 0));
  end loop;

  -- Global REC-04 composition: parents and schedule resources are acquired
  -- before one complete sorted User row/advisory set. This includes the owner,
  -- actor, and every operational participant so no later FK or trigger lock
  -- can invert a concurrent Copy or participant command.
  select coalesce(array_agg(distinct q.app_user_id order by q.app_user_id), array[]::uuid[])
  into v_user_lock_ids
  from (
    select v_app.hr_owner_id as app_user_id
    union all select v_actor
    union all
    select ip.app_user_id
    from public.interview_participants ip
    join public.interviews i on i.interview_id = ip.interview_id
    where i.application_id = p_application_id
      and i.is_active and ip.is_current
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null and i.end_at > v_now
  ) q where q.app_user_id is not null;

  perform 1 from public.app_users u
  where u.app_user_id = any(v_user_lock_ids)
  order by u.app_user_id for update;
  perform private.lock_internal_user_ids(v_user_lock_ids);

  select * into v_owner from public.app_users owner_user
  where owner_user.app_user_id = v_app.hr_owner_id;
  if not found or not v_owner.is_active then
    return jsonb_build_object('success', false, 'error_code', 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
  end if;
  if not v_owner.is_root_admin then
    perform 1 from public.app_user_roles r
    where r.app_user_id = v_owner.app_user_id and r.role_code = 'HR'
    for update;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
    end if;
  end if;

  -- A target parent remains inactive during preflight, so the shared external
  -- conflict view excludes these rows. Check target siblings explicitly first.
  if exists (
    select 1
    from public.interviews a
    join public.interviews b on b.application_id = a.application_id
      and b.interview_id > a.interview_id
      and b.is_active and b.schedule_status_code <> 'CANCELLED'
      and b.start_at is not null and b.end_at is not null and b.end_at > v_now
    where a.application_id = p_application_id
      and a.is_active and a.schedule_status_code <> 'CANCELLED'
      and a.start_at is not null and a.end_at is not null and a.end_at > v_now
      and a.start_at < b.end_at and a.end_at > b.start_at
  ) then
    return jsonb_build_object('success', false, 'error_code', 'SCHEDULE_CONFLICT_CANDIDATE');
  end if;

  -- Child rows and their users remain locked, so this is the authoritative
  -- post-lock snapshot and external conflict check.
  for v_interview in
    select * from public.interviews i
    where i.application_id = p_application_id
      and i.is_active
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null
      and i.end_at > v_now
    order by i.interview_id
  loop
    if not private.all_current_participants_selectable(v_interview.interview_id) then
      return jsonb_build_object('success', false, 'error_code', 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED');
    end if;
    select coalesce(array_agg(ip.app_user_id order by ip.app_user_id), array[]::uuid[])
    into v_interviewer_ids
    from public.interview_participants ip
    where ip.interview_id = v_interview.interview_id and ip.is_current;
    select c.conflict_type into v_conflict
    from private.check_interview_conflicts(
      v_interview.interview_id, v_candidate_id, v_interview.room_id,
      v_interviewer_ids, v_interview.start_at, v_interview.end_at
    ) c
    order by case c.conflict_type when 'CANDIDATE' then 1 when 'ROOM' then 2 else 3 end
    limit 1;
    if v_conflict is not null then
      return jsonb_build_object('success', false, 'error_code', 'SCHEDULE_CONFLICT_' || v_conflict);
    end if;
  end loop;
  update public.applications
  set is_active = true, version_no = version_no + 1, updated_at = clock_timestamp(), updated_by = v_actor
  where application_id = p_application_id;

  perform public.recalculate_submission_status(v_submission_id);
  perform private.audit_interview_command(
    'REACTIVATE_APPLICATION', 'APPLICATION', p_application_id, v_actor, null,
    jsonb_build_object('submission_id', v_submission_id, 'expected_version', p_expected_version)
  );
  return jsonb_build_object('success', true, 'data', jsonb_build_object(
    'application_id', p_application_id, 'is_active', true,
    'version_no', (select version_no from public.applications where application_id = p_application_id)
  ));
end;
$$;
revoke all on function public.reactivate_application(uuid,bigint) from public, anon;
grant execute on function public.reactivate_application(uuid,bigint) to authenticated;

create or replace function public.bulk_set_candidate_active(
  p_candidate_ids uuid[],
  p_active boolean,
  p_expected_versions bigint[],
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
  v_count integer;
  v_selection record;
  v_cand record;
  v_previous_is_active boolean;
  v_sub record;
  v_sub_active_apps integer;
  v_has_hired boolean;
  v_all_rejected boolean;
  v_new_sub_status text;
  v_result_items jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  -- 1. Authentication & Permission Check
  v_auth_user_id := auth.uid();
  if v_auth_user_id is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select u.app_user_id into v_actor_app_user_id
  from public.app_users u
  where u.auth_user_id = v_auth_user_id
    and u.is_active = true;

  if v_actor_app_user_id is null
    or not (private.has_permission('candidates.active_manage') or private.is_root_admin()) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission candidates.active_manage required');
  end if;

  -- 2. Strict Batch Validation (ALL_OR_NOTHING)
  if p_candidate_ids is null
    or cardinality(p_candidate_ids) = 0
    or p_expected_versions is null
    or cardinality(p_candidate_ids) <> cardinality(p_expected_versions)
    or array_position(p_candidate_ids, null) is not null
    or array_position(p_expected_versions, null) is not null
    or exists (select 1 from unnest(p_expected_versions) as v(version_no) where v.version_no <= 0)
    or exists (
      select 1
      from unnest(p_candidate_ids) as c(candidate_id)
      group by c.candidate_id
      having count(*) > 1
    )
    or p_active is null
    or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid bulk candidate active request');
  end if;

  v_count := cardinality(p_candidate_ids);
  if v_count > 100 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Batch size exceeds maximum limit of 100');
  end if;

  -- 3. Idempotency Check
  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'bulk_set_candidate_active',
        'candidate_ids', to_jsonb(p_candidate_ids),
        'expected_versions', to_jsonb(p_expected_versions),
        'active', p_active
      )::text,
      'sha256'
    ),
    'hex'
  );

  v_existing_result := private.check_idempotency(v_actor_scope, 'bulk_set_candidate_active', p_idempotency_key, v_fingerprint);
  if v_existing_result is not null then
    return v_existing_result;
  end if;

  -- 4. Prevalidate & Lock Candidates in deterministic order
  for v_selection in
    select t.candidate_id, t.expected_version
    from unnest(p_candidate_ids, p_expected_versions) with ordinality as t(candidate_id, expected_version, ord)
    order by t.candidate_id
  loop
    select * into v_cand
    from public.candidates
    where candidate_id = v_selection.candidate_id
    for update;

    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate not found in batch', 'details', jsonb_build_object('candidate_id', v_selection.candidate_id));
    end if;

    if v_cand.version_no <> v_selection.expected_version then
      return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Candidate version mismatch in batch', 'details', jsonb_build_object('candidate_id', v_selection.candidate_id, 'expected_version', v_selection.expected_version, 'current_version', v_cand.version_no));
    end if;
  end loop;

  -- REC-04 composed order: after the full Candidate fence, acquire the complete
  -- Submission/Application hierarchy globally. Per-candidate loops below only
  -- re-enter these locks and cannot form S2 -> S1 against Copy's S1 -> S2.
  if p_active then
    perform 1 from public.submissions s
    where s.candidate_id = any(p_candidate_ids)
    order by s.submission_id for update;
    perform 1 from public.applications a
    join public.submissions s on s.submission_id = a.submission_id
    where s.candidate_id = any(p_candidate_ids)
      and a.is_active
    order by s.submission_id, a.application_id for update;
  end if;

  -- 5. Mutate Candidates & recalculate
  for v_selection in
    select t.candidate_id
    from unnest(p_candidate_ids) with ordinality as t(candidate_id, ord)
    order by t.ord
  loop
    select * into v_cand
    from public.candidates
    where candidate_id = v_selection.candidate_id;

    v_previous_is_active := v_cand.is_active;

    if p_active = false then
      update public.candidates
      set
        is_active = false,
        inactive_at = clock_timestamp(),
        inactive_by = v_actor_app_user_id,
        updated_at = clock_timestamp()
      where candidate_id = v_selection.candidate_id
      returning * into v_cand;
    else
      update public.candidates
      set
        is_active = true,
        inactive_at = null,
        inactive_by = null,
        updated_at = clock_timestamp()
      where candidate_id = v_selection.candidate_id
      returning * into v_cand;

      -- Lock Submissions and Applications
      perform 1
      from public.submissions s
      where s.candidate_id = v_selection.candidate_id
      order by s.submission_id
      for update;

      perform 1
      from public.applications a
      join public.submissions s on s.submission_id = a.submission_id
      where s.candidate_id = v_selection.candidate_id
        and a.is_active = true
      order by a.submission_id, a.application_id
      for update;

      for v_sub in
        select s.submission_id, s.status_code
        from public.submissions s
        where s.candidate_id = v_selection.candidate_id
        order by s.submission_id
      loop
        select count(*) into v_sub_active_apps
        from public.applications
        where submission_id = v_sub.submission_id
          and is_active = true;

        if v_sub_active_apps = 0 then
          v_new_sub_status := 'READ';
        else
          select exists (
            select 1
            from public.applications a
            where a.submission_id = v_sub.submission_id
              and a.is_active = true
              and private.application_effective_outcome(a.application_id) = 'HIRED'
          ) into v_has_hired;

          if v_has_hired then
            v_new_sub_status := 'DONE';
          else
            select (
              v_sub_active_apps > 0
              and not exists (
                select 1
                from public.applications a
                where a.submission_id = v_sub.submission_id
                  and a.is_active = true
                  and private.application_effective_outcome(a.application_id) <> 'REJECTED'
              )
            ) into v_all_rejected;

            if v_all_rejected then
              v_new_sub_status := 'CLOSED';
            else
              v_new_sub_status := 'PROCESSED';
            end if;
          end if;
        end if;

        if v_new_sub_status is distinct from v_sub.status_code then
          update public.submissions
          set
            status_code = v_new_sub_status,
            updated_at = clock_timestamp()
          where submission_id = v_sub.submission_id;
        end if;
      end loop;
    end if;

    -- Per-item audit
    insert into public.security_audit_log (
      action_code,
      actor_app_user_id,
      entity_type,
      entity_id,
      metadata,
      source_code,
      result_code
    ) values (
      'BULK_SET_CANDIDATE_ACTIVE_ITEM',
      v_actor_app_user_id,
      'CANDIDATE',
      v_selection.candidate_id,
      jsonb_build_object(
        'candidate_id', v_selection.candidate_id,
        'is_active', p_active,
        'previous_is_active', v_previous_is_active,
        'version_no', v_cand.version_no
      ),
      'RPC',
      'SUCCESS'
    );

    v_result_items := v_result_items || jsonb_build_object(
      'candidate_id', v_cand.candidate_id,
      'is_active', v_cand.is_active,
      'version_no', v_cand.version_no,
      'inactive_at', v_cand.inactive_at,
      'inactive_by', v_cand.inactive_by
    );
  end loop;

  -- Batch audit event
  insert into public.security_audit_log (
    action_code,
    actor_app_user_id,
    entity_type,
    entity_id,
    metadata,
    source_code,
    result_code
  ) values (
    'BULK_SET_CANDIDATE_ACTIVE_BATCH',
    v_actor_app_user_id,
    'BATCH',
    p_idempotency_key,
    jsonb_build_object(
      'candidate_ids', to_jsonb(p_candidate_ids),
      'active', p_active,
      'count', v_count
    ),
    'RPC',
    'SUCCESS'
  );
  v_result := jsonb_build_object(
    'success', true,
    'active', p_active,
    'count', v_count,
    'items', v_result_items
  );

  perform private.record_idempotency(v_actor_scope, 'bulk_set_candidate_active', p_idempotency_key, v_fingerprint, v_result);
  return v_result;
end;
$$;

revoke all on function public.bulk_set_candidate_active(uuid[], boolean, bigint[], uuid) from public, anon;
grant execute on function public.bulk_set_candidate_active(uuid[], boolean, bigint[], uuid) to authenticated;

create or replace function public.bulk_change_interview_schedule_status(
  p_interview_ids uuid[],
  p_target_status text,
  p_expected_versions bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.status');
  v_id uuid;
  v_i public.interviews%rowtype;
  v_version bigint;
  v_cand uuid;
  v_lock_id uuid;
  v_ids uuid[];
  v_conflict text;
  v_user_lock_ids uuid[];
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06: Reject NULL and non-positive expected versions
  if p_target_status not in ('AVAILABLE','SCHEDULED','AWAITING','CONFIRMED','CANCELLED')
     or p_interview_ids is null
     or p_expected_versions is null
     or cardinality(p_interview_ids) is null
     or cardinality(p_expected_versions) is null
     or cardinality(p_interview_ids) < 1
     or cardinality(p_interview_ids) > 100
     or cardinality(p_interview_ids) is distinct from cardinality(p_expected_versions)
     or array_ndims(p_interview_ids) is distinct from 1
     or array_ndims(p_expected_versions) is distinct from 1
     or array_lower(p_interview_ids, 1) is distinct from 1
     or array_lower(p_expected_versions, 1) is distinct from 1
     or exists (select 1 from unnest(p_interview_ids) id where id is null)
     or exists (select 1 from unnest(p_expected_versions) v where v is null or v < 1)
     or (select count(distinct x) from unnest(p_interview_ids) x) <> cardinality(p_interview_ids) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if (
    select count(*)
    from public.interviews
    where interview_id = any(p_interview_ids)
  ) <> cardinality(p_interview_ids) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- F04: Lock hierarchy: Submissions -> Applications -> Interviews
  perform 1
  from public.submissions s
  where s.submission_id in (
    select distinct a.submission_id
    from public.applications a
    join public.interviews i on i.application_id = a.application_id
    where i.interview_id = any(p_interview_ids)
  )
  order by s.submission_id
  for update;

  perform 1
  from public.applications a
  where a.application_id in (
    select distinct i.application_id
    from public.interviews i
    where i.interview_id = any(p_interview_ids)
  )
  order by a.application_id
  for update;

  perform 1
  from public.interviews
  where interview_id = any(p_interview_ids)
  order by interview_id
  for update;

  -- Post-lock revalidation: verify all target interviews still exist after locking
  if (
    select count(*)
    from public.interviews
    where interview_id = any(p_interview_ids)
  ) <> cardinality(p_interview_ids) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if p_target_status <> 'CANCELLED' then
    for v_lock_id in
      select distinct s.candidate_id
      from public.interviews i
      join public.applications a on a.application_id = i.application_id
      join public.submissions s on s.submission_id = a.submission_id
      where i.interview_id = any(p_interview_ids)
        and i.is_active and i.start_at is not null and i.end_at is not null
        and s.candidate_id is not null
      order by s.candidate_id
    loop
      perform pg_advisory_xact_lock(hashtextextended('candidate:' || v_lock_id::text, 0));
    end loop;

    for v_lock_id in
      select distinct i.room_id
      from public.interviews i
      where i.interview_id = any(p_interview_ids)
        and i.is_active and i.start_at is not null and i.end_at is not null
        and i.room_id is not null
      order by i.room_id
    loop
      perform pg_advisory_xact_lock(hashtextextended('room:' || v_lock_id::text, 0));
    end loop;

    for v_lock_id in
      select distinct ip.app_user_id
      from public.interview_participants ip
      join public.interviews i on i.interview_id = ip.interview_id
      where i.interview_id = any(p_interview_ids)
        and i.is_active and i.start_at is not null and i.end_at is not null
        and ip.is_current and ip.app_user_id is not null
      order by ip.app_user_id
    loop
      perform pg_advisory_xact_lock(hashtextextended('interviewer:' || v_lock_id::text, 0));
    end loop;
  end if;

  -- The trigger also protects each row, but a bulk update must acquire its
  -- complete User set before any row trigger runs; per-row sets can otherwise
  -- invert a concurrent single scheduler's actor/participant ordering.
  select coalesce(array_agg(distinct q.app_user_id order by q.app_user_id), array[]::uuid[])
  into v_user_lock_ids
  from (
    select v_actor as app_user_id
    union all
    select ip.app_user_id
    from public.interview_participants ip
    where ip.interview_id = any(p_interview_ids) and ip.is_current
  ) q where q.app_user_id is not null;
  perform 1 from public.app_users u
  where u.app_user_id = any(v_user_lock_ids)
  order by u.app_user_id for update;
  perform private.lock_internal_user_ids(v_user_lock_ids);

  -- Preflight version & resource checks
  for v_id in select x from unnest(p_interview_ids) x order by x loop
    select * into v_i from public.interviews where interview_id = v_id;
    if not found or v_i.interview_id is null then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;
    select v.ver into v_version
    from unnest(p_interview_ids) with ordinality as u(id, ord)
    join unnest(p_expected_versions) with ordinality as v(ver, ord) on u.ord = v.ord
    where u.id = v_id;

    if v_version is null or v_i.version_no is distinct from v_version then
      return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
    end if;

    if p_target_status <> 'CANCELLED' and v_i.is_active and v_i.start_at is not null and v_i.end_at is not null then
      if not private.all_current_participants_selectable(v_id) then
        return jsonb_build_object('success', false, 'error_code', 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED');
      end if;

      select s.candidate_id into v_cand
      from public.applications a
      join public.submissions s on s.submission_id = a.submission_id
      where a.application_id = v_i.application_id;

      select coalesce(array_agg(app_user_id order by app_user_id), array[]::uuid[])
      into v_ids
      from public.interview_participants
      where interview_id = v_id and is_current;

      select c.conflict_type into v_conflict
      from private.check_interview_conflicts(v_id, v_cand, v_i.room_id, v_ids, v_i.start_at, v_i.end_at) c
      order by case c.conflict_type when 'CANDIDATE' then 1 when 'ROOM' then 2 else 3 end limit 1;

      if v_conflict is not null then
        return jsonb_build_object('success', false, 'error_code', 'SCHEDULE_CONFLICT_' || v_conflict);
      end if;
    end if;
  end loop;

  if p_target_status <> 'CANCELLED' then
    select conflict_type into v_conflict
    from (
      select
        case
          when s1.candidate_id is not null and s1.candidate_id = s2.candidate_id then 'CANDIDATE'
          when i1.room_id is not null and i1.room_id = i2.room_id then 'ROOM'
          when exists (
            select 1
            from public.interview_participants ip1
            join public.interview_participants ip2 on ip2.app_user_id = ip1.app_user_id
            where ip1.interview_id = i1.interview_id
              and ip2.interview_id = i2.interview_id
              and ip1.is_current
              and ip2.is_current
              and ip1.app_user_id is not null
          ) then 'INTERVIEWER'
          else null
        end as conflict_type
      from public.interviews i1
      join public.applications a1 on a1.application_id = i1.application_id
      join public.submissions s1 on s1.submission_id = a1.submission_id
      join public.interviews i2 on i2.interview_id = any(p_interview_ids) and i2.interview_id > i1.interview_id
      join public.applications a2 on a2.application_id = i2.application_id
      join public.submissions s2 on s2.submission_id = a2.submission_id
      where i1.interview_id = any(p_interview_ids)
        and i1.is_active and i2.is_active
        and i1.start_at is not null and i1.end_at is not null
        and i2.start_at is not null and i2.end_at is not null
        and i1.start_at < i2.end_at and i1.end_at > i2.start_at
    ) sub
    where conflict_type is not null
    order by case conflict_type when 'CANDIDATE' then 1 when 'ROOM' then 2 else 3 end
    limit 1;

    if v_conflict is not null then
      return jsonb_build_object('success', false, 'error_code', 'SCHEDULE_CONFLICT_' || v_conflict);
    end if;
  end if;

  update public.interviews
  set schedule_status_code = p_target_status,
      updated_by = v_actor
  where interview_id = any(p_interview_ids);

  for v_id in select x from unnest(p_interview_ids) x order by x loop
    perform private.audit_interview_command(
      'BULK_CHANGE_INTERVIEW_SCHEDULE_STATUS',
      'INTERVIEW',
      v_id,
      v_actor,
      null,
      jsonb_build_object('schedule_status_code', p_target_status)
    );
  end loop;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'count', cardinality(p_interview_ids),
      'schedule_status_code', p_target_status
    )
  );
end;
$$;

revoke all on function public.bulk_change_interview_schedule_status(uuid[], text, bigint[]) from public, anon;
grant execute on function public.bulk_change_interview_schedule_status(uuid[], text, bigint[]) to authenticated;

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
  v_sub record;
  v_new_version bigint;
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
begin
  if p_submission_id is null or p_expected_version is null or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'submission_id and positive expected_version are required');
  end if;

  -- 1. Authorization check
  v_can_edit :=
    private.has_permission('submissions.edit')
    or private.is_root_admin();

  if not v_can_edit then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.edit required'
    );
  end if;

  -- 2. Lock submission
  select * into v_sub
  from public.submissions
  where submission_id = p_submission_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Submission not found'
    );
  end if;

  -- 3. Optimistic version check
  if v_sub.version_no <> p_expected_version then
    return jsonb_build_object(
      'success', false,
      'error_code', 'STALE_VERSION',
      'message', 'Submission version mismatch'
    );
  end if;

  -- 4. Update HR note; candidate email and verified identity are immutable
  v_new_version := v_sub.version_no + 1;
  v_auth_user_id := (select auth.uid());
  v_actor_app_user_id := private.current_app_user_id();

  update public.submissions
  set
    hr_note = nullif(btrim(p_hr_note), ''),
    version_no = v_new_version,
    updated_at = clock_timestamp(),
    updated_by_internal_user_id = v_actor_app_user_id
  where submission_id = p_submission_id;

  -- 5. Mandatory Audit Logging
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

  -- 6. Refresh candidate profile cache
  perform private.refresh_candidate_current_profile(v_sub.candidate_id);

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

create or replace function private.validate_participant_lifecycle_and_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_active boolean;
  v_lock_ids uuid[];
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
    -- The actor is included before the selection row. Commands later write
    -- updated_by, whose FK also locks the actor; locking the complete sorted
    -- set prevents selected-user -> actor inversions against Copy.
    select coalesce(array_agg(distinct q.app_user_id order by q.app_user_id), array[]::uuid[])
    into v_lock_ids
    from (select new.app_user_id as app_user_id union all select private.current_app_user_id()) q
    where q.app_user_id is not null;
    perform 1 from public.app_users u where u.app_user_id = any(v_lock_ids)
    order by u.app_user_id for update;

    if not found then
      raise exception 'USER_INACTIVE_NOT_SELECTABLE' using errcode = '23514';
    end if;
    perform private.lock_internal_user_ids(v_lock_ids);

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

create or replace function private.recheck_current_participants_after_statement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_ids uuid[];
  v_lock_ids uuid[];
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

  -- A statement that makes every participant non-current has no selected-user
  -- set. Its command locks the complete before/after composition before that
  -- first write; never acquire the actor alone here ahead of a later reorder.
  if cardinality(v_user_ids) > 0 then
    select coalesce(array_agg(distinct q.app_user_id order by q.app_user_id), array[]::uuid[])
    into v_lock_ids
    from (select unnest(v_user_ids) as app_user_id union all select private.current_app_user_id()) q
    where q.app_user_id is not null;
    perform 1 from public.app_users u where u.app_user_id = any(v_lock_ids)
    order by u.app_user_id for update;
    perform private.lock_internal_user_ids(v_lock_ids);
  end if;

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
