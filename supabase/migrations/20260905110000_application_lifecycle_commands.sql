-- Migration: 20260905110000_application_lifecycle_commands.sql
-- TASK-S03-002: Application creation, assignment, and lifecycle commands

-- -----------------------------------------------------------------------------
-- 1. Structurally Empty Default Round Predicate
-- -----------------------------------------------------------------------------
create or replace function private.is_structurally_empty_default_round(
  p_interview_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_int record;
  v_part_count integer := 0;
  v_rep_count integer := 0;
  v_doc_count integer := 0;
  v_res_count integer := 0;
  v_copy_ref_count integer := 0;
begin
  select * into v_int
  from public.interviews
  where interview_id = p_interview_id;

  if not found then
    return false;
  end if;

  -- Must be round 1 with default status
  if v_int.round_no <> 1
    or v_int.schedule_status_code <> 'AVAILABLE'
    or v_int.report_status_code <> 'INTERVIEW_SCHEDULING'
    or v_int.start_at is not null
    or v_int.end_at is not null
    or nullif(btrim(v_int.notes), '') is not null
    or nullif(btrim(v_int.hr_report_note), '') is not null
    or v_int.copied_from_interview_id is not null
  then
    return false;
  end if;

  -- Check if referenced by another interview via copied_from_interview_id
  select count(*) into v_copy_ref_count
  from public.interviews
  where copied_from_interview_id = p_interview_id;

  if v_copy_ref_count > 0 then
    return false;
  end if;

  -- Check pending upload reservations
  select count(*) into v_res_count
  from public.upload_reservations
  where interview_id = p_interview_id
    and status_code not in ('CANCELLED', 'EXPIRED');

  if v_res_count > 0 then
    return false;
  end if;

  -- If interview_participants table exists, check participants
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'interview_participants'
  ) then
    execute 'select count(*) from public.interview_participants where interview_id = $1'
      into v_part_count using p_interview_id;
    if v_part_count > 0 then
      return false;
    end if;
  end if;

  -- If interview_reports table exists, check reports
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'interview_reports'
  ) then
    execute 'select count(*) from public.interview_reports where interview_id = $1'
      into v_rep_count using p_interview_id;
    if v_rep_count > 0 then
      return false;
    end if;
  end if;

  -- If interview_document_logicals table exists, check documents
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'interview_document_logicals'
  ) then
    execute 'select count(*) from public.interview_document_logicals where interview_id = $1'
      into v_doc_count using p_interview_id;
    if v_doc_count > 0 then
      return false;
    end if;
  end if;

  return true;
end;
$$;

revoke all on function private.is_structurally_empty_default_round(uuid) from public, anon, authenticated;
grant execute on function private.is_structurally_empty_default_round(uuid) to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 2. create_or_update_application
-- -----------------------------------------------------------------------------
create or replace function public.create_or_update_application(
  p_submission_id uuid,
  p_unit_id uuid,
  p_department_team_id uuid default null,
  p_position_id uuid default null,
  p_hr_owner_id uuid default null,
  p_idempotency_key uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
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
begin
  -- 1. Authorization check
  v_can_manage :=
    private.has_permission('applications.create')
    or private.has_permission('applications.manage')
    or private.is_root_admin();

  if not v_can_manage then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission applications.create or applications.manage required'
    );
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

    -- Active duplicate updates owner and version
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

  -- 5. Recalculate parent submission status
  perform public.recalculate_submission_status(p_submission_id);

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'application_id', v_app_id,
      'submission_id', p_submission_id,
      'is_active', true,
      'version_no', v_version,
      'round1_interview_id', v_round1_id
    )
  );
end;
$$;

revoke all on function public.create_or_update_application(uuid, uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.create_or_update_application(uuid, uuid, uuid, uuid, uuid, uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. delete_or_inactivate_application
-- -----------------------------------------------------------------------------
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
  v_app record;
  v_round_count integer;
  v_round1 record;
  v_is_empty boolean;
  v_action text;
begin
  -- 1. Authorization check
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

  -- 2. Lock application (Lock 1)
  select * into v_app
  from public.applications
  where application_id = p_application_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Application not found'
    );
  end if;

  -- 3. Lock parent submission (Lock 2)
  perform 1
  from public.submissions
  where submission_id = v_app.submission_id
  for update;

  -- 4. Inspect child interviews
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
    -- Truly unused default Round 1: hard delete round 1 and application
    delete from public.interviews where interview_id = v_round1.interview_id;
    delete from public.applications where application_id = p_application_id;
    v_action := 'DELETED';
  else
    -- Has business usage or multiple rounds: soft inactivate
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

  -- 5. Recalculate parent submission status
  perform public.recalculate_submission_status(v_app.submission_id);

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'application_id', p_application_id,
      'action', v_action,
      'submission_id', v_app.submission_id
    )
  );
end;
$$;

revoke all on function public.delete_or_inactivate_application(uuid) from public, anon;
grant execute on function public.delete_or_inactivate_application(uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 4. update_submission_by_hr
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

  update public.submissions
  set
    hr_note = nullif(btrim(p_hr_note), ''),
    version_no = v_new_version,
    updated_at = clock_timestamp()
  where submission_id = p_submission_id;

  -- 5. Refresh candidate profile cache
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
