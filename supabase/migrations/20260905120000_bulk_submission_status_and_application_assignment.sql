-- Migration: 20260905120000_bulk_submission_status_and_application_assignment.sql
-- TASK-S03-003: Atomic bulk latest-submission status and application assignment

-- -----------------------------------------------------------------------------
-- 1. Canonical audit and idempotency prerequisites
-- -----------------------------------------------------------------------------
create table if not exists public.activity_log (
  activity_id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id uuid not null,
  action_code text not null,
  actor_app_user_id uuid references public.app_users(app_user_id) on delete set null,
  actor_candidate_id uuid references public.candidates(candidate_id) on delete set null,
  old_values jsonb,
  new_values jsonb,
  request_id uuid,
  correlation_id uuid,
  source_code text not null default 'WEB' check (source_code in ('WEB', 'RPC', 'SYSTEM', 'WORKER')),
  reason text,
  created_at timestamptz not null default now(),
  constraint activity_one_human_actor_ck check ((actor_app_user_id is not null)::int + (actor_candidate_id is not null)::int <= 1)
);

create table if not exists public.security_audit_log (
  audit_id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  actor_auth_user_id uuid,
  actor_app_user_id uuid references public.app_users(app_user_id) on delete set null,
  actor_candidate_id uuid references public.candidates(candidate_id) on delete set null,
  action_code text not null,
  entity_type text,
  entity_id uuid,
  request_id uuid,
  correlation_id uuid,
  source_code text not null default 'WEB' check (source_code in ('WEB', 'RPC', 'SYSTEM', 'WORKER')),
  result_code text not null default 'SUCCESS' check (result_code in ('SUCCESS', 'DENIED', 'FAILED')),
  reason text,
  diff jsonb,
  metadata jsonb,
  constraint security_audit_one_human_actor_ck check ((actor_app_user_id is not null)::int + (actor_candidate_id is not null)::int <= 1)
);

create index if not exists security_audit_entity_idx on public.security_audit_log(entity_type, entity_id, occurred_at desc);
create index if not exists security_audit_actor_idx on public.security_audit_log(actor_app_user_id, occurred_at desc);

create table if not exists public.idempotency_records (
  idempotency_record_id uuid primary key default gen_random_uuid(),
  actor_scope text not null,
  command_type text not null,
  idempotency_key uuid not null,
  result_entity_type text,
  result_entity_id uuid,
  result_payload jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  unique(actor_scope, command_type, idempotency_key)
);

alter table public.activity_log enable row level security;
alter table public.security_audit_log enable row level security;
alter table public.idempotency_records enable row level security;

revoke all on public.activity_log, public.security_audit_log, public.idempotency_records from public, anon, authenticated;
grant all on public.activity_log, public.security_audit_log, public.idempotency_records to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 2. Candidate-level deterministic latest Submission manual-status batch
-- -----------------------------------------------------------------------------
create or replace function public.bulk_set_latest_submission_manual_status(
  p_candidate_ids uuid[],
  p_status_code text,
  p_expected_latest_submission_ids uuid[],
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
  v_selection record;
  v_latest record;
  v_item jsonb;
  v_items jsonb := '[]'::jsonb;
  v_result_items jsonb := '[]'::jsonb;
  v_result jsonb;
  v_resolved_submission_ids uuid[] := '{}'::uuid[];
  v_count integer;
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
    or not (private.has_permission('submissions.status') or private.is_root_admin()) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission submissions.status required');
  end if;

  if p_candidate_ids is null
    or cardinality(p_candidate_ids) = 0
    or p_expected_latest_submission_ids is null
    or p_expected_versions is null
    or cardinality(p_candidate_ids) <> cardinality(p_expected_latest_submission_ids)
    or cardinality(p_candidate_ids) <> cardinality(p_expected_versions)
    or array_position(p_candidate_ids, null) is not null
    or array_position(p_expected_latest_submission_ids, null) is not null
    or array_position(p_expected_versions, null) is not null
    or exists (select 1 from unnest(p_expected_versions) as v(version_no) where v.version_no <= 0)
    or exists (
      select 1
      from unnest(p_candidate_ids) as c(candidate_id)
      group by c.candidate_id
      having count(*) > 1
    )
    or p_status_code is null
    or p_status_code not in ('NEW', 'READ')
    or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid bulk latest-submission status request');
  end if;

  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'bulk_set_latest_submission_manual_status',
        'candidate_ids', to_jsonb(p_candidate_ids),
        'expected_latest_submission_ids', to_jsonb(p_expected_latest_submission_ids),
        'expected_versions', to_jsonb(p_expected_versions),
        'status_code', p_status_code
      )::text,
      'sha256'
    ),
    'hex'
  );

  perform pg_advisory_xact_lock(hashtextextended(v_actor_scope || ':bulk_set_latest_submission_manual_status:' || p_idempotency_key::text, 0));

  select r.result_payload into v_existing_result
  from public.idempotency_records r
  where r.actor_scope = v_actor_scope
    and r.command_type = 'bulk_set_latest_submission_manual_status'
    and r.idempotency_key = p_idempotency_key;

  if found then
    if v_existing_result ->> 'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key has already been used for a different request');
    end if;
    return v_existing_result -> 'result';
  end if;

  select count(*) into v_count
  from public.candidates c
  where c.candidate_id = any(p_candidate_ids);

  if v_count <> cardinality(p_candidate_ids) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'One or more Candidates were not found');
  end if;

  -- Cross-command serialization starts before Candidate row locks.
  perform pg_advisory_xact_lock(hashtextextended('bulk-candidate:' || c.candidate_id::text, 0))
  from (
    select distinct candidate_id
    from unnest(p_candidate_ids) as selected(candidate_id)
    order by candidate_id
  ) c;

  perform 1
  from public.candidates c
  where c.candidate_id = any(p_candidate_ids)
  order by c.candidate_id
  for update;

  for v_selection in
    select c.candidate_id, s.expected_submission_id, s.expected_version, s.ordinality
    from unnest(p_candidate_ids, p_expected_latest_submission_ids, p_expected_versions)
      with ordinality as s(candidate_id, expected_submission_id, expected_version, ordinality)
    join public.candidates c on c.candidate_id = s.candidate_id
    order by s.ordinality
  loop
    select s.* into v_latest
    from public.submissions s
    where s.candidate_id = v_selection.candidate_id
    order by s.submitted_at desc, s.submission_id desc
    limit 1;

    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'A selected Candidate has no Submission');
    end if;

    v_resolved_submission_ids := array_append(v_resolved_submission_ids, v_latest.submission_id);
  end loop;


  perform 1
  from public.submissions s
  where s.submission_id = any(v_resolved_submission_ids)
  order by s.submission_id
  for update;

  for v_selection in
    select *
    from unnest(p_candidate_ids, p_expected_latest_submission_ids, p_expected_versions)
      with ordinality as s(candidate_id, expected_submission_id, expected_version, ordinality)
    order by s.ordinality
  loop
    select s.* into v_latest
    from public.submissions s
    where s.candidate_id = v_selection.candidate_id
    order by s.submitted_at desc, s.submission_id desc
    limit 1;

    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'A selected Candidate has no Submission');
    end if;

    if v_latest.submission_id <> v_selection.expected_submission_id
      or v_latest.version_no <> v_selection.expected_version then
      return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Latest Submission identity or version changed');
    end if;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'ordinality', v_selection.ordinality,
      'candidate_id', v_selection.candidate_id,
      'submission_id', v_latest.submission_id,
      'old_status_code', v_latest.status_code,
      'old_version_no', v_latest.version_no
    ));
  end loop;

  perform 1
  from public.applications a
  where a.submission_id = any(v_resolved_submission_ids)
    and a.is_active = true
  order by a.submission_id, a.application_id
  for update;

  if exists (
    select 1
    from public.applications a
    where a.submission_id = any(v_resolved_submission_ids)
      and a.is_active = true
  ) then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Manual NEW or READ is blocked while any active Application exists');
  end if;

  for v_item in
    select value
    from jsonb_array_elements(v_items)
    order by (value ->> 'ordinality')::integer
  loop
    update public.submissions
    set
      status_code = p_status_code,
      version_no = (v_item ->> 'old_version_no')::bigint + 1,
      updated_at = clock_timestamp()
    where submission_id = (v_item ->> 'submission_id')::uuid;

    insert into public.activity_log (
      entity_type, entity_id, action_code, actor_app_user_id, request_id, source_code, old_values, new_values
    ) values (
      'SUBMISSION',
      (v_item ->> 'submission_id')::uuid,
      'BULK_MANUAL_STATUS_SET',
      v_actor_app_user_id,
      p_idempotency_key,
      'RPC',
      jsonb_build_object('status_code', v_item ->> 'old_status_code', 'version_no', (v_item ->> 'old_version_no')::bigint),
      jsonb_build_object('status_code', p_status_code, 'version_no', (v_item ->> 'old_version_no')::bigint + 1)
    );

    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'candidate_id', v_item ->> 'candidate_id',
      'submission_id', v_item ->> 'submission_id',
      'status_code', p_status_code,
      'version_no', (v_item ->> 'old_version_no')::bigint + 1
    ));
  end loop;

  insert into public.security_audit_log (
    actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id, request_id, source_code, metadata
  ) values (
    v_auth_user_id,
    v_actor_app_user_id,
    'BULK_LATEST_SUBMISSION_STATUS',
    'BATCH',
    p_idempotency_key,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('request_fingerprint', v_fingerprint, 'selected_candidate_ids', to_jsonb(p_candidate_ids))
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('items', v_result_items, 'count', cardinality(p_candidate_ids), 'idempotency_key', p_idempotency_key)
  );

  insert into public.idempotency_records (
    actor_scope, command_type, idempotency_key, result_entity_type, result_entity_id, result_payload
  ) values (
    v_actor_scope,
    'bulk_set_latest_submission_manual_status',
    p_idempotency_key,
    'BATCH',
    p_idempotency_key,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  );

  return v_result;
end;
$$;

revoke all on function public.bulk_set_latest_submission_manual_status(uuid[], text, uuid[], bigint[], uuid) from public, anon;
grant execute on function public.bulk_set_latest_submission_manual_status(uuid[], text, uuid[], bigint[], uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. Exact-Submission common Application-assignment batch
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 4. Cross-command lock-order correction
-- -----------------------------------------------------------------------------
-- All mutations that touch both parents now lock Submission before Application:
-- bulk status: Candidate -> Submission -> Application;
-- bulk assignment: references -> Submission -> Application;
-- delete/inactivate: Submission -> Application.
create or replace function public.delete_or_inactivate_application(
  p_application_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_can_delete boolean;
  v_submission_id uuid;
  v_app record;
  v_round_count integer;
  v_round1 record;
  v_is_empty boolean;
  v_action text;
begin
  v_can_delete :=
    private.has_permission('applications.delete')
    or private.has_permission('applications.manage')
    or private.is_root_admin();

  if not v_can_delete then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission applications.delete required'
    );
  end if;

  -- Resolve the immutable parent before taking either mutating lock.
  select a.submission_id into v_submission_id
  from public.applications a
  where a.application_id = p_application_id;

  if v_submission_id is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Application not found'
    );
  end if;

  -- Required common order: Submission, then Application.

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications a
  where a.application_id = p_application_id
    and a.submission_id = v_submission_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Application not found'
    );
  end if;

  select count(*) into v_round_count
  from public.interviews
  where application_id = p_application_id;

  select * into v_round1
  from public.interviews
  where application_id = p_application_id and round_no = 1;

  if v_round_count = 1 and v_round1.interview_id is not null then
    v_is_empty := private.is_structurally_empty_default_round(v_round1.interview_id);
  else
    v_is_empty := false;
  end if;

  if v_is_empty then
    delete from public.interviews where interview_id = v_round1.interview_id;
    delete from public.applications where application_id = p_application_id;
    v_action := 'DELETED';
  else
    update public.applications
    set
      is_active = false,
      updated_at = clock_timestamp()
    where application_id = p_application_id;

    update public.interviews
    set
      is_active = false,
      updated_at = clock_timestamp()
    where application_id = p_application_id;

    v_action := 'INACTIVATED';
  end if;

  perform public.recalculate_submission_status(v_submission_id);

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'application_id', p_application_id,
      'action', v_action,
      'submission_id', v_submission_id
    )
  );
end;
$$;

revoke all on function public.delete_or_inactivate_application(uuid) from public, anon;
grant execute on function public.delete_or_inactivate_application(uuid) to authenticated, postgres, service_role;
