-- TASK-S03-005: Submission Detail, open_submission repair, document audit, and Application creation flow

-- -----------------------------------------------------------------------------
-- 1. Repair open_submission to match actual submissions schema
-- -----------------------------------------------------------------------------
create or replace function public.open_submission(
  p_submission_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_view boolean;
  v_has_status boolean;
  v_sub record;
  v_status text;
begin
  -- 1. Authorization check
  v_has_view := private.has_permission('submissions.view') or private.is_root_admin();
  if not v_has_view then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.view required to open submission'
    );
  end if;

  v_has_status := private.has_permission('submissions.status') or private.is_root_admin();

  -- 2. Query submission
  select * into v_sub
  from public.submissions
  where submission_id = p_submission_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Submission not found'
    );
  end if;

  v_status := v_sub.status_code;

  -- 3. Conditional Mutation: NEW -> READ if caller has submissions.status
  if v_has_status and v_sub.status_code = 'NEW' then
    update public.submissions
    set
      status_code = 'READ',
      updated_at = clock_timestamp()
    where submission_id = p_submission_id
    returning * into v_sub;

    v_status := 'READ';
  end if;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', v_sub.submission_id,
      'candidate_id', v_sub.candidate_id,
      'status_code', v_status,
      'full_name', v_sub.full_name,
      'email', v_sub.email_snapshot::text,
      'phone', v_sub.phone,
      'date_of_birth', v_sub.date_of_birth,
      'gender', v_sub.gender_code,
      'address', v_sub.current_address,
      'candidate_notes', v_sub.other_info,
      'submitted_at', v_sub.submitted_at,
      'version_no', v_sub.version_no
    )
  );
end;
$$;

revoke all on function public.open_submission(uuid) from public, anon;
grant execute on function public.open_submission(uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 2. Complete Submission Detail read RPC
-- -----------------------------------------------------------------------------
create or replace function public.get_submission_detail(
  p_submission_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_view boolean;
  v_has_status boolean;
  v_sub record;
  v_status text;
  v_source_name text := null;
  v_updated_by_name text := null;
  v_education jsonb;
  v_experiences jsonb;
  v_activities jsonb;
  v_documents jsonb;
  v_applications jsonb;
begin
  -- 1. Authorization check
  v_has_view := private.has_permission('submissions.view') or private.is_root_admin();
  if not v_has_view then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.view required to view submission details'
    );
  end if;

  v_has_status := private.has_permission('submissions.status') or private.is_root_admin();

  -- 2. Query submission
  select * into v_sub
  from public.submissions
  where submission_id = p_submission_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Submission not found'
    );
  end if;

  v_status := v_sub.status_code;

  -- 3. Conditional Mutation: NEW -> READ if caller has submissions.status
  if v_has_status and v_sub.status_code = 'NEW' then
    update public.submissions
    set
      status_code = 'READ',
      updated_at = clock_timestamp()
    where submission_id = p_submission_id
    returning * into v_sub;

    v_status := 'READ';
  end if;

  -- 4. Recruitment source name
  if v_sub.recruitment_source_id is not null then
    select name_vi into v_source_name
    from public.recruitment_sources
    where recruitment_source_id = v_sub.recruitment_source_id;
  end if;

  -- 5. Updated by name
  if v_sub.updated_by_internal_user_id is not null then
    select full_name into v_updated_by_name
    from public.app_users
    where app_user_id = v_sub.updated_by_internal_user_id;
  elsif v_sub.updated_by_candidate_id is not null then
    v_updated_by_name := 'Ứng viên';
  end if;

  -- 6. Education
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'education_id', e.education_id,
      'sort_order', e.sort_order,
      'period_text', e.period_text,
      'qualification_id', e.qualification_id,
      'qualification_name', q.name_vi,
      'major', e.major,
      'institution', e.institution
    ) order by e.sort_order asc
  ), '[]'::jsonb)
  into v_education
  from public.submission_education e
  left join public.qualification_levels q on q.qualification_id = e.qualification_id
  where e.submission_id = p_submission_id;

  -- 7. Work experiences (HR only)
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'experience_id', w.experience_id,
      'sort_order', w.sort_order,
      'start_date', w.start_date,
      'end_date', w.end_date,
      'is_current', w.is_current,
      'employer', w.employer,
      'job_title', w.job_title,
      'job_description', w.job_description
    ) order by w.sort_order asc
  ), '[]'::jsonb)
  into v_experiences
  from public.submission_work_experiences w
  where w.submission_id = p_submission_id;

  -- 8. Activities (HR only)
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'activity_id', a.activity_id,
      'sort_order', a.sort_order,
      'period_text', a.period_text,
      'activity_name', a.activity_name,
      'role_name', a.role_name,
      'organizer', a.organizer,
      'description', a.description
    ) order by a.sort_order asc
  ), '[]'::jsonb)
  into v_activities
  from public.submission_activities a
  where a.submission_id = p_submission_id;

  -- 9. Documents
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'document_id', d.document_id,
      'logical_document_id', d.logical_document_id,
      'document_type_id', l.document_type_id,
      'document_type_code', dt.code,
      'document_type_name', dt.name_vi,
      'original_filename', d.original_filename,
      'mime_type', d.mime_type,
      'file_size_bytes', d.file_size_bytes,
      'uploaded_at', d.uploaded_at
    ) order by d.uploaded_at asc
  ), '[]'::jsonb)
  into v_documents
  from public.submission_document_logicals l
  join public.submission_documents d on d.logical_document_id = l.logical_document_id and d.is_current = true
  left join public.document_types dt on dt.document_type_id = l.document_type_id
  where l.submission_id = p_submission_id;

  -- 10. Existing applications for this submission
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'application_id', app.application_id,
      'unit_id', app.unit_id,
      'unit_name', u.name_vi,
      'department_team_id', app.department_team_id,
      'department_team_name', t.name_vi,
      'position_id', app.position_id,
      'position_name', pos.name_vi,
      'hr_owner_id', app.hr_owner_id,
      'hr_owner_name', hr.full_name,
      'is_active', app.is_active,
      'version_no', app.version_no,
      'created_at', app.created_at,
      'round1_interview_id', (
        select i.interview_id
        from public.interviews i
        where i.application_id = app.application_id and i.round_no = 1
        limit 1
      ),
      'round_count', (
        select count(*)
        from public.interviews i
        where i.application_id = app.application_id
      )
    ) order by app.created_at asc
  ), '[]'::jsonb)
  into v_applications
  from public.applications app
  join public.organizational_units u on u.unit_id = app.unit_id
  left join public.department_teams t on t.department_team_id = app.department_team_id
  join public.positions pos on pos.position_id = app.position_id
  join public.app_users hr on hr.app_user_id = app.hr_owner_id
  where app.submission_id = p_submission_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', v_sub.submission_id,
      'candidate_id', v_sub.candidate_id,
      'status_code', v_status,
      'full_name', v_sub.full_name,
      'date_of_birth', v_sub.date_of_birth,
      'gender_code', v_sub.gender_code,
      'current_address', v_sub.current_address,
      'phone', v_sub.phone,
      'email', v_sub.email_snapshot::text,
      'other_info', v_sub.other_info,
      'hr_note', v_sub.hr_note,
      'recruitment_source_id', v_sub.recruitment_source_id,
      'recruitment_source_name', v_source_name,
      'submitted_at', v_sub.submitted_at,
      'updated_at', v_sub.updated_at,
      'updated_by_name', v_updated_by_name,
      'version_no', v_sub.version_no,
      'education', v_education,
      'work_experiences', v_experiences,
      'activities', v_activities,
      'documents', v_documents,
      'applications', v_applications
    )
  );
end;
$$;

revoke all on function public.get_submission_detail(uuid) from public, anon;
grant execute on function public.get_submission_detail(uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. Update update_submission_by_hr with mandatory Security Audit Log
-- -----------------------------------------------------------------------------
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
  if p_expected_version is not null and v_sub.version_no <> p_expected_version then
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

-- -----------------------------------------------------------------------------
-- 4. Update create_or_update_application with mandatory Security Audit Log
-- -----------------------------------------------------------------------------
drop function if exists public.create_or_update_application(uuid, uuid, uuid, uuid, uuid, uuid);
create or replace function public.create_or_update_application(
  p_submission_id uuid,
  p_unit_id uuid,
  p_department_team_id uuid default null,
  p_position_id uuid default null,
  p_hr_owner_id uuid default null,
  p_idempotency_key uuid default gen_random_uuid(),
  p_confirm_duplicate boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_view boolean;
  v_can_manage boolean;
  v_sub record;
  v_unit record;
  v_team record;
  v_pos record;
  v_hr record;
  v_existing record;
  v_app_id uuid;
  v_round1_id uuid;
  v_version bigint;
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_existing_result jsonb;
  v_result jsonb;
begin
  -- 1. Authorization check: submissions.view AND (applications.create or applications.manage or root)
  v_has_view :=
    private.has_permission('submissions.view')
    or private.is_root_admin();

  v_can_manage :=
    private.has_permission('applications.create')
    or private.has_permission('applications.manage')
    or private.is_root_admin();

  if not v_has_view or not v_can_manage then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.view and (applications.create or applications.manage) required'
    );
  end if;

  -- 2. Actor resolution & Idempotency replay check
  v_auth_user_id := (select auth.uid());
  v_actor_app_user_id := private.current_app_user_id();
  v_actor_scope := 'app_user:' || coalesce(v_actor_app_user_id::text, coalesce(v_auth_user_id::text, 'root'));

  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_actor_scope || ':create_or_update_application:' || p_idempotency_key::text, 0));

    select r.result_payload into v_existing_result
    from public.idempotency_records r
    where r.actor_scope = v_actor_scope
      and r.command_type = 'create_or_update_application'
      and r.idempotency_key = p_idempotency_key;

    if found then
      return v_existing_result;
    end if;
  end if;

  -- 2. Hierarchy & master data validations
  select * into v_unit
  from public.organizational_units
  where unit_id = p_unit_id and is_active = true;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Organizational unit not found or inactive'
    );
  end if;

  if p_department_team_id is not null then
    select * into v_team
    from public.department_teams
    where department_team_id = p_department_team_id
      and unit_id = p_unit_id
      and is_active = true;

    if not found then
      return jsonb_build_object(
        'success', false,
        'error_code', 'INVALID_HIERARCHY',
        'message', 'Department team does not belong to organizational unit or is inactive'
      );
    end if;
  end if;

  select * into v_pos
  from public.positions
  where position_id = p_position_id
    and unit_id = p_unit_id
    and (
      (p_department_team_id is null and department_team_id is null)
      or (p_department_team_id is not null and department_team_id = p_department_team_id)
    )
    and is_active = true;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_HIERARCHY',
      'message', 'Position does not match unit/team hierarchy or is inactive'
    );
  end if;

  select * into v_hr
  from public.app_users
  where app_user_id = p_hr_owner_id and is_active = true;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'HR owner not found or inactive'
    );
  end if;

  -- Verify HR owner eligibility: must be active root admin or have HR role
  if not v_hr.is_root_admin and not exists (
    select 1 from public.app_user_roles aur
    where aur.app_user_id = p_hr_owner_id and aur.role_code = 'HR'
  ) then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_HR_OWNER',
      'message', 'Selected owner must be an active HR or root admin user'
    );
  end if;

  -- 3. Lock parent submission (Lock 1)
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

  -- 4. Check durable identity uniqueness (Lock 2)
  select * into v_existing
  from public.applications
  where submission_id = p_submission_id
    and unit_id = p_unit_id
    and coalesce(department_team_id, '00000000-0000-0000-0000-000000000000'::uuid) =
        coalesce(p_department_team_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and position_id = p_position_id
  for update;

  if found then
    if not v_existing.is_active then
      -- Inactive duplicate cannot create second row; must use reactivate
      return jsonb_build_object(
        'success', false,
        'error_code', 'ALREADY_EXISTS_INACTIVE',
        'message', 'An inactive application already exists for this position. Use reactivate instead.'
      );
    end if;

    -- Active duplicate requires explicit confirmation
    if not p_confirm_duplicate then
      return jsonb_build_object(
        'success', false,
        'error_code', 'DUPLICATE_APPLICATION',
        'message', 'An active application already exists for this position. Explicit confirmation required to update owner.',
        'data', jsonb_build_object(
          'application_id', v_existing.application_id,
          'hr_owner_id', v_existing.hr_owner_id,
          'version_no', v_existing.version_no
        )
      );
    end if;

    -- Confirmed active duplicate updates owner and version
    v_app_id := v_existing.application_id;
    v_version := v_existing.version_no + 1;

    update public.applications
    set
      hr_owner_id = p_hr_owner_id,
      version_no = v_version,
      updated_at = clock_timestamp()
    where application_id = v_app_id;

    -- Retrieve existing round 1 id
    select interview_id into v_round1_id
    from public.interviews
    where application_id = v_app_id and round_no = 1;
  else
    -- Create new Application and default Round 1
    v_app_id := gen_random_uuid();
    v_round1_id := gen_random_uuid();
    v_version := 1;

    insert into public.applications (
      application_id,
      submission_id,
      unit_id,
      department_team_id,
      position_id,
      hr_owner_id,
      is_active,
      version_no,
      created_at,
      updated_at
    ) values (
      v_app_id,
      p_submission_id,
      p_unit_id,
      p_department_team_id,
      p_position_id,
      p_hr_owner_id,
      true,
      1,
      clock_timestamp(),
      clock_timestamp()
    );

    insert into public.interviews (
      interview_id,
      application_id,
      round_no,
      schedule_status_code,
      report_status_code,
      is_active,
      version_no,
      created_at,
      updated_at
    ) values (
      v_round1_id,
      v_app_id,
      1,
      'AVAILABLE',
      'INTERVIEW_SCHEDULING',
      true,
      1,
      clock_timestamp(),
      clock_timestamp()
    );
  end if;

  -- 5. Mandatory Security Audit Log
  v_auth_user_id := (select auth.uid());
  v_actor_app_user_id := private.current_app_user_id();

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
    'APPLICATION_CREATE_OR_UPDATE',
    'APPLICATION',
    v_app_id,
    'RPC',
    'SUCCESS',
    jsonb_build_object(
      'application_id', v_app_id,
      'submission_id', p_submission_id,
      'position_id', p_position_id,
      'unit_id', p_unit_id,
      'department_team_id', p_department_team_id,
      'hr_owner_id', p_hr_owner_id,
      'is_active', true,
      'version_no', v_version
    )
  );

  -- 6. Recalculate parent submission status
  perform public.recalculate_submission_status(p_submission_id);

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'application_id', v_app_id,
      'submission_id', p_submission_id,
      'is_active', true,
      'version_no', v_version,
      'round1_interview_id', v_round1_id
    )
  );

  if p_idempotency_key is not null then
    insert into public.idempotency_records (
      actor_scope,
      command_type,
      idempotency_key,
      result_entity_type,
      result_entity_id,
      result_payload
    ) values (
      v_actor_scope,
      'create_or_update_application',
      p_idempotency_key,
      'APPLICATION',
      v_app_id,
      v_result
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.create_or_update_application(uuid, uuid, uuid, uuid, uuid, uuid, boolean) from public, anon;
grant execute on function public.create_or_update_application(uuid, uuid, uuid, uuid, uuid, uuid, boolean) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 5. Record Document Access Security Audit Log RPC
-- -----------------------------------------------------------------------------
create or replace function public.record_document_access_audit(
  p_submission_id uuid,
  p_logical_document_id uuid,
  p_document_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_view boolean;
  v_doc record;
begin
  v_has_view := private.has_permission('submissions.view') or private.is_root_admin();
  if not v_has_view then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.view required for document access'
    );
  end if;

  -- Validate document belongs to submission
  select d.document_id into v_doc
  from public.submission_documents d
  join public.submission_document_logicals l on l.logical_document_id = d.logical_document_id
  where d.document_id = p_document_id
    and l.logical_document_id = p_logical_document_id
    and l.submission_id = p_submission_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Document not found in submission'
    );
  end if;

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
    (select auth.uid()),
    private.current_app_user_id(),
    'DOCUMENT_ACCESS',
    'SUBMISSION_DOCUMENT',
    p_document_id,
    'WEB',
    'SUCCESS',
    jsonb_build_object(
      'submission_id', p_submission_id,
      'logical_document_id', p_logical_document_id,
      'document_id', p_document_id
    )
  );

  return jsonb_build_object('success', true);
end;
$$;

revoke all on function public.record_document_access_audit(uuid, uuid, uuid) from public, anon;
grant execute on function public.record_document_access_audit(uuid, uuid, uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 6. Application Assignment Options Master Data RPC
-- -----------------------------------------------------------------------------
create or replace function public.get_application_assignment_options()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_view boolean;
  v_can_manage boolean;
  v_units jsonb;
  v_teams jsonb;
  v_positions jsonb;
  v_hr_owners jsonb;
begin
  v_has_view := private.has_permission('submissions.view') or private.is_root_admin();
  v_can_manage :=
    private.has_permission('applications.create')
    or private.has_permission('applications.manage')
    or private.is_root_admin();

  if not v_has_view or not v_can_manage then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.view and (applications.create or applications.manage) required'
    );
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'unit_id', unit_id,
      'code', code,
      'name_vi', name_vi
    ) order by name_vi asc
  ), '[]'::jsonb)
  into v_units
  from public.organizational_units
  where is_active = true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'department_team_id', department_team_id,
      'unit_id', unit_id,
      'code', code,
      'name_vi', name_vi
    ) order by name_vi asc
  ), '[]'::jsonb)
  into v_teams
  from public.department_teams
  where is_active = true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'position_id', position_id,
      'unit_id', unit_id,
      'department_team_id', department_team_id,
      'code', code,
      'name_vi', name_vi
    ) order by name_vi asc
  ), '[]'::jsonb)
  into v_positions
  from public.positions
  where is_active = true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'app_user_id', u.app_user_id,
      'full_name', u.full_name,
      'email', u.email
    ) order by u.full_name asc
  ), '[]'::jsonb)
  into v_hr_owners
  from public.app_users u
  where u.is_active = true
    and (
      u.is_root_admin = true
      or exists (
        select 1 from public.app_user_roles r
        where r.app_user_id = u.app_user_id and r.role_code = 'HR'
      )
    );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'units', v_units,
      'department_teams', v_teams,
      'positions', v_positions,
      'hr_owners', v_hr_owners
    )
  );
end;
$$;

revoke all on function public.get_application_assignment_options() from public, anon;
grant execute on function public.get_application_assignment_options() to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 7. Candidate-quarantine storage select remains root-only
-- -----------------------------------------------------------------------------
drop policy if exists candidate_quarantine_select on storage.objects;
create policy candidate_quarantine_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'candidate-quarantine'
    and private.is_root_admin()
  );
