-- TASK-S05-001: atomic own-only Interviewer report mutation boundary.
-- Preserve the accepted four-argument save_interviewer_report contract while
-- routing both HR/owner and owner-only surfaces through one mutation core.

create or replace function private.save_interviewer_report_core(
  p_interview_participant_id uuid,
  p_field_patches jsonb,
  p_expected_version_no bigint,
  p_base_values jsonb,
  p_owner_only boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.current_app_user_id();
  v_part public.interview_participants%rowtype;
  v_i public.interviews%rowtype;
  v_app public.applications%rowtype;
  v_report public.interview_reports%rowtype;
  v_interview_id uuid;
  v_application_id uuid;
  v_hr boolean;
  v_owner boolean;
  v_key text;
  v_current text;
  v_base text;
  v_conflict boolean := false;
  v_updates jsonb := coalesce(p_field_patches, '{}'::jsonb);
  v_allowed text[] := array[
    'professional_knowledge',
    'necessary_skills',
    'qualities_personality',
    'strengths_limitations',
    'other_comment',
    'conclusion',
    'expected_specific_job_assigned',
    'expected_recruitment_time'
  ];
begin
  if v_actor is null then
    return jsonb_build_object(
      'success', false,
      'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end
    );
  end if;

  if jsonb_typeof(v_updates) <> 'object'
     or exists(
       select 1 from jsonb_object_keys(v_updates) k where not k = any(v_allowed)
     )
     or exists(
       select 1
       from jsonb_object_keys(v_updates) k
       where not (coalesce(p_base_values, '{}'::jsonb) ? k)
     ) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if p_owner_only then
    -- Resolve identities without trusting them, then lock in the same parent-first
    -- order used by current-round allocation/status commands. Re-read all rows
    -- after the locks so mutation-time authorization cannot use stale state.
    select ip.interview_id
      into v_interview_id
    from public.interview_participants ip
    where ip.interview_participant_id = p_interview_participant_id;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;

    select i.application_id
      into v_application_id
    from public.interviews i
    where i.interview_id = v_interview_id;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;

    select * into v_app
    from public.applications
    where application_id = v_application_id
    for update;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;

    select * into v_i
    from public.interviews
    where interview_id = v_interview_id
      and application_id = v_app.application_id
    for update;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;

    select * into v_part
    from public.interview_participants
    where interview_participant_id = p_interview_participant_id
      and interview_id = v_i.interview_id
    for update;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;
  else
    -- Accepted Slice-04 behavior for the existing HR/owner command.
    select * into v_part
    from public.interview_participants
    where interview_participant_id = p_interview_participant_id;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;

    select * into v_i
    from public.interviews
    where interview_id = v_part.interview_id;
  end if;

  v_hr := private.is_root_admin()
    or (
      private.has_permission('reports.view')
      and private.has_permission('reports.edit_interviewer')
    );

  if p_owner_only then
    v_owner := v_part.app_user_id = v_actor
      and v_part.is_current
      and v_app.is_active
      and v_i.is_active
      and v_i.visible_to_interviewers
      and v_i.report_status_code not in ('HIRED', 'REJECTED')
      and exists(
        select 1
        from private.application_current_interview ci
        where ci.application_id = v_i.application_id
          and ci.interview_id = v_i.interview_id
      );

    if not v_owner then
      return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
    end if;

    -- An HR/Root user who is also the actual participant still uses owner
    -- conflict semantics through this owner-only command.
    v_hr := false;
  else
    v_owner := v_part.app_user_id = v_actor
      and v_part.is_current
      and v_i.is_active
      and v_i.visible_to_interviewers
      and v_i.report_status_code not in ('HIRED', 'REJECTED')
      and exists(
        select 1
        from private.application_current_interview ci
        where ci.application_id = v_i.application_id
          and ci.interview_id = v_i.interview_id
      );

    if not v_hr and not v_owner then
      return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
    end if;
  end if;

  select * into v_report
  from public.interview_reports
  where interview_participant_id = p_interview_participant_id
    and is_active
    and not is_archived
  for update;

  if not found then
    insert into public.interview_reports(
      interview_participant_id,
      created_by,
      updated_by
    )
    values (
      p_interview_participant_id,
      v_actor,
      v_actor
    )
    returning * into v_report;

    select * into v_report
    from public.interview_reports
    where interview_report_id = v_report.interview_report_id
    for update;
  end if;

  for v_key in select jsonb_object_keys(v_updates)
  loop
    execute format(
      'select %I from public.interview_reports where interview_report_id=$1',
      v_key
    )
    into v_current
    using v_report.interview_report_id;

    v_base := p_base_values ->> v_key;
    if v_current is distinct from v_base then
      v_conflict := true;
    end if;
  end loop;

  if v_hr and v_conflict then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if v_owner
     and v_report.version_no <> p_expected_version_no
     and v_report.updated_by = v_actor then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  update public.interview_reports
  set
    professional_knowledge = case
      when v_updates ? 'professional_knowledge'
        then v_updates ->> 'professional_knowledge'
      else professional_knowledge
    end,
    necessary_skills = case
      when v_updates ? 'necessary_skills'
        then v_updates ->> 'necessary_skills'
      else necessary_skills
    end,
    qualities_personality = case
      when v_updates ? 'qualities_personality'
        then v_updates ->> 'qualities_personality'
      else qualities_personality
    end,
    strengths_limitations = case
      when v_updates ? 'strengths_limitations'
        then v_updates ->> 'strengths_limitations'
      else strengths_limitations
    end,
    other_comment = case
      when v_updates ? 'other_comment'
        then v_updates ->> 'other_comment'
      else other_comment
    end,
    conclusion = case
      when v_updates ? 'conclusion'
        then v_updates ->> 'conclusion'
      else conclusion
    end,
    expected_specific_job_assigned = case
      when v_updates ? 'expected_specific_job_assigned'
        then v_updates ->> 'expected_specific_job_assigned'
      else expected_specific_job_assigned
    end,
    expected_recruitment_time = case
      when v_updates ? 'expected_recruitment_time'
        then v_updates ->> 'expected_recruitment_time'
      else expected_recruitment_time
    end,
    updated_by = v_actor
  where interview_report_id = v_report.interview_report_id
  returning * into v_report;

  perform private.audit_interview_command(
    'SAVE_INTERVIEWER_REPORT',
    'INTERVIEW_REPORT',
    v_report.interview_report_id,
    v_actor,
    null,
    jsonb_build_object('patched_fields', v_updates)
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_report_id', v_report.interview_report_id,
      'version_no', v_report.version_no
    )
  );
end;
$$;

revoke all on function private.save_interviewer_report_core(
  uuid, jsonb, bigint, jsonb, boolean
) from public, anon, authenticated;
grant execute on function private.save_interviewer_report_core(
  uuid, jsonb, bigint, jsonb, boolean
) to postgres, service_role;

create or replace function public.save_interviewer_report(
  p_interview_participant_id uuid,
  p_field_patches jsonb,
  p_expected_version_no bigint,
  p_base_values jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.save_interviewer_report_core(
    p_interview_participant_id,
    p_field_patches,
    p_expected_version_no,
    p_base_values,
    false
  );
$$;

revoke all on function public.save_interviewer_report(
  uuid, jsonb, bigint, jsonb
) from public, anon;
grant execute on function public.save_interviewer_report(
  uuid, jsonb, bigint, jsonb
) to authenticated;

create or replace function public.save_own_interviewer_report(
  p_interview_participant_id uuid,
  p_field_patches jsonb,
  p_expected_version_no bigint,
  p_base_values jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.save_interviewer_report_core(
    p_interview_participant_id,
    p_field_patches,
    p_expected_version_no,
    p_base_values,
    true
  );
$$;

revoke all on function public.save_own_interviewer_report(
  uuid, jsonb, bigint, jsonb
) from public, anon;
grant execute on function public.save_own_interviewer_report(
  uuid, jsonb, bigint, jsonb
) to authenticated;
