-- TASK-S05-002: HR Report management over accepted report contracts.
-- Append-only migration: preserve S05-001 Interviewer projection and accepted
-- Current Round / Final Decision / field-aware report mutation authorities.

create schema if not exists hr_report_private;
revoke all on schema hr_report_private from public, anon, authenticated;
grant usage on schema hr_report_private to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 1. Dedicated minimum-safe HR Report read projection.
-- -----------------------------------------------------------------------------
create or replace function hr_report_private.get_hr_report_page_impl(
  p_page integer,
  p_page_size integer,
  p_status_code text,
  p_visibility text,
  p_search text,
  p_sort text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor uuid;
  v_actor_active boolean;
  v_is_root boolean;
  v_can_manage_status boolean;
  v_can_visibility boolean;
  v_can_edit_interviewer boolean;
  v_can_delete boolean;
  v_page integer := coalesce(p_page, 1);
  v_page_size integer := coalesce(p_page_size, 20);
  v_status text := nullif(upper(btrim(coalesce(p_status_code, ''))), '');
  v_visibility text := upper(btrim(coalesce(p_visibility, 'ALL')));
  v_search text := btrim(coalesce(p_search, ''));
  v_sort text := upper(btrim(coalesce(p_sort, 'CANDIDATE_ASC')));
  v_total integer := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Authenticated internal user required'
    );
  end if;

  select u.app_user_id, u.is_active
    into v_actor, v_actor_active
  from public.app_users u
  where u.auth_user_id = v_auth_uid;

  if v_actor is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Internal HR context required'
    );
  end if;

  if not coalesce(v_actor_active, false) then
    return jsonb_build_object(
      'success', false,
      'error_code', 'USER_INACTIVE',
      'message', 'Internal user is inactive'
    );
  end if;

  v_is_root := private.is_root_admin();
  if not v_is_root and not private.has_permission('reports.view') then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'reports.view is required'
    );
  end if;

  if v_page < 1
     or v_page_size < 1
     or v_page_size > 100
     or char_length(v_search) > 256
     or v_visibility not in ('ALL', 'VISIBLE', 'HIDDEN')
     or v_sort not in ('CANDIDATE_ASC', 'CANDIDATE_DESC', 'UPDATED_DESC')
     or (
       v_status is not null
       and v_status not in (
         'INTERVIEW_SCHEDULING',
         'AWAITING_INTERVIEW',
         'WAITING_FOR_REPORT',
         'REPORT_SUBMITTED',
         'FOLLOW_UP',
         'ON_HOLD',
         'HIRED',
         'REJECTED'
       )
     ) then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Invalid HR Report read request'
    );
  end if;

  v_can_manage_status := v_is_root or private.has_permission('reports.manage_status');
  v_can_visibility := v_is_root or private.has_permission('reports.visibility');
  v_can_edit_interviewer := v_is_root or private.has_permission('reports.edit_interviewer');
  v_can_delete := v_is_root or private.has_permission('reports.delete');

  with eligible as (
    select
      a.application_id,
      i.interview_id,
      i.round_no,
      i.version_no as interview_version_no,
      s.full_name as candidate_name,
      p.name_vi as position_name_vi,
      p.name_en as position_name_en,
      i.start_at,
      i.end_at,
      f.name_vi as format_name_vi,
      f.name_en as format_name_en,
      rm.display_name as room_name,
      i.meeting_link,
      i.report_status_code,
      i.hr_report_note,
      i.visible_to_interviewers,
      owner.full_name as hr_owner_name,
      greatest(i.updated_at, latest_report.updated_at) as last_updated_at,
      case
        when latest_report.updated_at is not null
          and latest_report.updated_at >= i.updated_at
          then latest_report_updater.full_name
        else interview_updater.full_name
      end as last_updated_by_name
    from private.application_current_interview ci
    join public.applications a
      on a.application_id = ci.application_id
     and a.is_active = true
    join public.interviews i
      on i.interview_id = ci.interview_id
     and i.is_active = true
    join public.submissions s
      on s.submission_id = a.submission_id
    join public.positions p
      on p.position_id = a.position_id
    left join public.interview_formats f
      on f.interview_format_id = i.interview_format_id
    left join public.rooms rm
      on rm.room_id = i.room_id
    left join public.app_users owner
      on owner.app_user_id = a.hr_owner_id
    left join public.app_users interview_updater
      on interview_updater.app_user_id = i.updated_by
    left join lateral (
      select r.updated_at, r.updated_by
      from public.interview_participants ip
      join public.interview_reports r
        on r.interview_participant_id = ip.interview_participant_id
       and r.is_active = true
       and r.is_archived = false
      where ip.interview_id = i.interview_id
        and ip.is_current = true
        and ip.removed_at is null
      order by r.updated_at desc, r.interview_report_id desc
      limit 1
    ) latest_report on true
    left join public.app_users latest_report_updater
      on latest_report_updater.app_user_id = latest_report.updated_by
  ),
  filtered as (
    select e.*
    from eligible e
    where (v_status is null or e.report_status_code = v_status)
      and (
        v_visibility = 'ALL'
        or (v_visibility = 'VISIBLE' and e.visible_to_interviewers = true)
        or (v_visibility = 'HIDDEN' and e.visible_to_interviewers = false)
      )
      and (
        v_search = ''
        or strpos(lower(e.candidate_name), lower(v_search)) > 0
        or strpos(lower(e.position_name_vi), lower(v_search)) > 0
        or strpos(lower(coalesce(e.position_name_en, '')), lower(v_search)) > 0
      )
  ),
  page_rows as (
    select f.*
    from filtered f
    order by
      case when v_sort = 'CANDIDATE_ASC' then lower(f.candidate_name) end asc,
      case when v_sort = 'CANDIDATE_DESC' then lower(f.candidate_name) end desc,
      case when v_sort = 'UPDATED_DESC' then f.last_updated_at end desc nulls last,
      f.application_id asc
    limit v_page_size
    offset (v_page - 1) * v_page_size
  )
  select
    (select count(*)::integer from filtered),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'application_id', pr.application_id,
            'interview_id', pr.interview_id,
            'round_no', pr.round_no,
            'interview_version_no', pr.interview_version_no,
            'candidate_name', pr.candidate_name,
            'position_name_vi', pr.position_name_vi,
            'position_name_en', pr.position_name_en,
            'start_at', pr.start_at,
            'end_at', pr.end_at,
            'format_name_vi', pr.format_name_vi,
            'format_name_en', pr.format_name_en,
            'room_name', pr.room_name,
            'meeting_link', pr.meeting_link,
            'report_status_code', pr.report_status_code,
            'hr_report_note', pr.hr_report_note,
            'visible_to_interviewers', pr.visible_to_interviewers,
            'last_updated_at', pr.last_updated_at,
            'last_updated_by_name', pr.last_updated_by_name,
            'drawer', jsonb_build_object(
              'hr_owner_name', pr.hr_owner_name,
              'participants', coalesce(
                (
                  select jsonb_agg(
                    jsonb_build_object(
                      'interview_participant_id', ip.interview_participant_id,
                      'participant_order', ip.participant_order,
                      'name', ip.snapshot_name,
                      'job_title', ip.snapshot_job_title,
                      'interview_report_id', r.interview_report_id,
                      'report_version_no', coalesce(r.version_no, 1),
                      'report', jsonb_build_object(
                        'professional_knowledge', r.professional_knowledge,
                        'necessary_skills', r.necessary_skills,
                        'qualities_personality', r.qualities_personality,
                        'strengths_limitations', r.strengths_limitations,
                        'other_comment', r.other_comment,
                        'conclusion', r.conclusion,
                        'expected_specific_job_assigned', r.expected_specific_job_assigned,
                        'expected_recruitment_time', r.expected_recruitment_time
                      ),
                      'updated_at', r.updated_at,
                      'updated_by_name', report_updater.full_name
                    )
                    order by ip.participant_order, ip.interview_participant_id
                  )
                  from public.interview_participants ip
                  left join lateral (
                    select active_report.*
                    from public.interview_reports active_report
                    where active_report.interview_participant_id = ip.interview_participant_id
                      and active_report.is_active = true
                      and active_report.is_archived = false
                    order by active_report.created_at desc, active_report.interview_report_id desc
                    limit 1
                  ) r on true
                  left join public.app_users report_updater
                    on report_updater.app_user_id = r.updated_by
                  where ip.interview_id = pr.interview_id
                    and ip.is_current = true
                    and ip.removed_at is null
                ),
                '[]'::jsonb
              ),
              'final_decision', coalesce(
                (
                  select jsonb_build_object(
                    'source_interview_report_id', fd.interview_report_id,
                    'source_participant_name', source_participant.snapshot_name,
                    'conclusion', fd.conclusion,
                    'expected_specific_job_assigned', fd.expected_specific_job_assigned,
                    'expected_recruitment_time', fd.expected_recruitment_time,
                    'updated_at', fd.decision_updated_at,
                    'updated_by_name', decision_updater.full_name
                  )
                  from private.interview_final_decision_source fd
                  left join public.interview_participants source_participant
                    on source_participant.interview_participant_id = fd.interview_participant_id
                  left join public.app_users decision_updater
                    on decision_updater.app_user_id = fd.decision_updated_by
                  where fd.application_id = pr.application_id
                    and fd.interview_id = pr.interview_id
                ),
                jsonb_build_object(
                  'source_interview_report_id', null,
                  'source_participant_name', null,
                  'conclusion', null,
                  'expected_specific_job_assigned', null,
                  'expected_recruitment_time', null,
                  'updated_at', null,
                  'updated_by_name', null
                )
              )
            )
          )
          order by
            case when v_sort = 'CANDIDATE_ASC' then lower(pr.candidate_name) end asc,
            case when v_sort = 'CANDIDATE_DESC' then lower(pr.candidate_name) end desc,
            case when v_sort = 'UPDATED_DESC' then pr.last_updated_at end desc nulls last,
            pr.application_id asc
        )
        from page_rows pr
      ),
      '[]'::jsonb
    )
  into v_total, v_rows;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'rows', v_rows,
      'page', v_page,
      'page_size', v_page_size,
      'total', v_total,
      'page_count', case
        when v_total = 0 then 0
        else ceil(v_total::numeric / v_page_size::numeric)::integer
      end,
      'permissions', jsonb_build_object(
        'manage_status', v_can_manage_status,
        'visibility', v_can_visibility,
        'edit_interviewer', v_can_edit_interviewer,
        'delete', v_can_delete
      )
    )
  );
end;
$$;

revoke all on function hr_report_private.get_hr_report_page_impl(integer, integer, text, text, text, text)
  from public, anon, authenticated;
grant execute on function hr_report_private.get_hr_report_page_impl(integer, integer, text, text, text, text)
  to authenticated, postgres, service_role;

create or replace function public.get_hr_report_page(
  p_page integer default 1,
  p_page_size integer default 20,
  p_status_code text default null,
  p_visibility text default 'ALL',
  p_search text default null,
  p_sort text default 'CANDIDATE_ASC'
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select hr_report_private.get_hr_report_page_impl(
    p_page,
    p_page_size,
    p_status_code,
    p_visibility,
    p_search,
    p_sort
  );
$$;

-- -----------------------------------------------------------------------------
-- 2. Canonical current-round visibility trusted command.
-- -----------------------------------------------------------------------------
create or replace function public.set_report_visibility(
  p_interview_id uuid,
  p_visible_to_interviewers boolean,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('reports.visibility');
  v_application public.applications%rowtype;
  v_interview public.interviews%rowtype;
begin
  if v_actor is null
     or (not private.is_root_admin() and not private.has_permission('reports.view')) then
    return jsonb_build_object(
      'success', false,
      'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end
    );
  end if;

  if p_interview_id is null
     or p_visible_to_interviewers is null
     or p_expected_version is null
     or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  select a.* into v_application
  from public.applications a
  join public.interviews i on i.application_id = a.application_id
  where i.interview_id = p_interview_id
  for update of a;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if not v_application.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  select * into v_interview
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_interview.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;
  if not exists (
    select 1
    from private.application_current_interview ci
    where ci.application_id = v_application.application_id
      and ci.interview_id = v_interview.interview_id
  ) then
    return jsonb_build_object('success', false, 'error_code', 'LATEST_ROUND_REQUIRED');
  end if;

  update public.interviews
  set visible_to_interviewers = p_visible_to_interviewers,
      updated_by = v_actor
  where interview_id = p_interview_id
  returning * into v_interview;

  perform private.audit_interview_command(
    'SET_REPORT_VISIBILITY',
    'INTERVIEW',
    p_interview_id,
    v_actor,
    null,
    jsonb_build_object('visible_to_interviewers', p_visible_to_interviewers)
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', p_interview_id,
      'visible_to_interviewers', v_interview.visible_to_interviewers,
      'version_no', v_interview.version_no
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Canonical all-or-nothing bulk HR Report status trusted command.
-- -----------------------------------------------------------------------------
create or replace function public.bulk_change_report_status(
  p_interview_ids uuid[],
  p_report_status_code text,
  p_expected_versions bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('reports.manage_status');
  v_count integer := cardinality(p_interview_ids);
  v_interview_id uuid;
  v_expected_version bigint;
  v_interview public.interviews%rowtype;
  v_submission_id uuid;
begin
  if v_actor is null
     or (not private.is_root_admin() and not private.has_permission('reports.view')) then
    return jsonb_build_object(
      'success', false,
      'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end
    );
  end if;

  if v_count is null
     or v_count < 1
     or v_count > 100
     or cardinality(p_expected_versions) is distinct from v_count
     or p_report_status_code not in (
       'INTERVIEW_SCHEDULING',
       'AWAITING_INTERVIEW',
       'WAITING_FOR_REPORT',
       'REPORT_SUBMITTED',
       'FOLLOW_UP',
       'ON_HOLD',
       'HIRED',
       'REJECTED'
     )
     or exists (select 1 from unnest(p_interview_ids) id where id is null)
     or exists (select 1 from unnest(p_expected_versions) version_value where version_value is null or version_value < 1)
     or (select count(distinct id) from unnest(p_interview_ids) id) <> v_count then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if (
    select count(*)
    from public.interviews i
    where i.interview_id = any(p_interview_ids)
  ) <> v_count then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- Preserve the accepted single-command hierarchy: Application -> Interview -> Submission.
  -- Multi-target acquisition is deterministic inside each level.
  perform 1
  from public.applications a
  where a.application_id in (
    select distinct i.application_id
    from public.interviews i
    where i.interview_id = any(p_interview_ids)
  )
  order by a.application_id
  for update;

  if exists (
    select 1
    from public.applications a
    join public.interviews i on i.application_id = a.application_id
    where i.interview_id = any(p_interview_ids)
      and a.is_active = false
  ) then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  perform 1
  from public.interviews i
  where i.interview_id = any(p_interview_ids)
  order by i.interview_id
  for update;

  -- Full-set lock-time Current Round + version preflight. No writes occur before
  -- every selected Interview passes this loop.
  for v_interview_id in
    select id from unnest(p_interview_ids) id order by id
  loop
    select i.* into v_interview
    from public.interviews i
    where i.interview_id = v_interview_id;

    v_expected_version := p_expected_versions[array_position(p_interview_ids, v_interview_id)];
    if v_interview.version_no <> v_expected_version then
      return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
    end if;
    if not exists (
      select 1
      from private.application_current_interview ci
      where ci.application_id = v_interview.application_id
        and ci.interview_id = v_interview.interview_id
    ) then
      return jsonb_build_object('success', false, 'error_code', 'LATEST_ROUND_REQUIRED');
    end if;
  end loop;

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

  for v_interview_id in
    select id from unnest(p_interview_ids) id order by id
  loop
    update public.interviews
    set report_status_code = p_report_status_code,
        updated_by = v_actor
    where interview_id = v_interview_id;

    perform private.audit_interview_command(
      'BULK_CHANGE_REPORT_STATUS',
      'INTERVIEW',
      v_interview_id,
      v_actor,
      null,
      jsonb_build_object(
        'report_status_code', p_report_status_code,
        'batch_size', v_count
      )
    );
  end loop;

  for v_submission_id in
    select distinct a.submission_id
    from public.applications a
    join public.interviews i on i.application_id = a.application_id
    where i.interview_id = any(p_interview_ids)
    order by a.submission_id
  loop
    perform public.recalculate_submission_status(v_submission_id);
  end loop;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'updated_count', v_count,
      'report_status_code', p_report_status_code
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Bounded canonical permission repair for report-specific delete/inactivate.
-- Lifecycle/history/version/audit semantics intentionally remain unchanged.
-- -----------------------------------------------------------------------------
create or replace function public.delete_or_inactivate_report(
  p_interview_report_id uuid,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('reports.delete');
  v_report public.interview_reports%rowtype;
  v_used boolean;
begin
  if v_actor is null
     or (not private.is_root_admin() and not private.has_permission('reports.view')) then
    return jsonb_build_object(
      'success', false,
      'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end
    );
  end if;

  select * into v_report
  from public.interview_reports
  where interview_report_id = p_interview_report_id
  for update;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_report.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  v_used :=
    nullif(btrim(coalesce(v_report.professional_knowledge, '')), '') is not null
    or nullif(btrim(coalesce(v_report.necessary_skills, '')), '') is not null
    or nullif(btrim(coalesce(v_report.qualities_personality, '')), '') is not null
    or nullif(btrim(coalesce(v_report.strengths_limitations, '')), '') is not null
    or nullif(btrim(coalesce(v_report.other_comment, '')), '') is not null
    or nullif(btrim(coalesce(v_report.conclusion, '')), '') is not null
    or nullif(btrim(coalesce(v_report.expected_specific_job_assigned, '')), '') is not null
    or nullif(btrim(coalesce(v_report.expected_recruitment_time, '')), '') is not null
    or v_report.decision_updated_at is not null;

  if v_used then
    update public.interview_reports
    set is_active = false,
        is_archived = true,
        updated_by = v_actor
    where interview_report_id = p_interview_report_id;

    perform private.audit_interview_command(
      'INACTIVATE_INTERVIEW_REPORT',
      'INTERVIEW_REPORT',
      p_interview_report_id,
      v_actor,
      null,
      '{}'::jsonb
    );

    return jsonb_build_object(
      'success', true,
      'data', jsonb_build_object('action', 'INACTIVATED')
    );
  end if;

  delete from public.interview_reports
  where interview_report_id = p_interview_report_id;

  perform private.audit_interview_command(
    'DELETE_INTERVIEW_REPORT',
    'INTERVIEW_REPORT',
    p_interview_report_id,
    v_actor,
    null,
    '{}'::jsonb
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('action', 'DELETED')
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Explicit RPC ACLs. Browser clients never receive table-write grants here.
-- -----------------------------------------------------------------------------
revoke all on function public.get_hr_report_page(integer, integer, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.get_hr_report_page(integer, integer, text, text, text, text)
  to authenticated, postgres, service_role;

revoke all on function public.set_report_visibility(uuid, boolean, bigint)
  from public, anon, authenticated;
grant execute on function public.set_report_visibility(uuid, boolean, bigint)
  to authenticated, postgres, service_role;

revoke all on function public.bulk_change_report_status(uuid[], text, bigint[])
  from public, anon, authenticated;
grant execute on function public.bulk_change_report_status(uuid[], text, bigint[])
  to authenticated, postgres, service_role;

revoke all on function public.delete_or_inactivate_report(uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.delete_or_inactivate_report(uuid, bigint)
  to authenticated, postgres, service_role;