-- TASK-S05-001: Interviewer-safe contextual report read projection.
-- This migration adds one read-only RPC. It does not replace or alter the
-- accepted Slice-04 report mutation contracts. The repository uses imperative
-- ordered migrations; the filename follows the existing UTC timestamp format.

create schema if not exists interviewer_report_private;
revoke all on schema interviewer_report_private from public, anon, authenticated;
grant usage on schema interviewer_report_private to authenticated, postgres, service_role;

create or replace function interviewer_report_private.get_interviewer_report_page_impl()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor_app_user_id uuid;
  v_actor_active boolean;
  v_rounds jsonb;
begin
  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Authenticated internal user required'
    );
  end if;

  select u.app_user_id, u.is_active
    into v_actor_app_user_id, v_actor_active
  from public.app_users u
  where u.auth_user_id = v_auth_uid;

  if v_actor_app_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Interviewer context required'
    );
  end if;

  if not coalesce(v_actor_active, false) then
    return jsonb_build_object(
      'success', false,
      'error_code', 'USER_INACTIVE',
      'message', 'Internal user is inactive'
    );
  end if;

  -- Reuse the accepted Slice-04 authorities for Current Round and Final
  -- Decision Source rather than re-deriving those contracts in Slice-05.
  with accessible_rounds as (
    select
      a.application_id,
      i.interview_id,
      i.round_no,
      i.start_at,
      i.end_at,
      i.meeting_link,
      actor_ip.interview_participant_id,
      s.full_name as candidate_name,
      p.name_vi as position_name_vi,
      p.name_en as position_name_en,
      f.name_vi as format_name_vi,
      f.name_en as format_name_en,
      rm.display_name as room_name,
      exists (
        select 1
        from private.application_current_interview ci
        where ci.application_id = a.application_id
          and ci.interview_id = i.interview_id
      ) as is_current_round,
      case i.report_status_code
        when 'FOLLOW_UP' then 'REPORT_SUBMITTED'
        when 'ON_HOLD' then 'REPORT_SUBMITTED'
        when 'HIRED' then 'REPORT_SUBMITTED'
        else i.report_status_code
      end as display_report_status,
      (
        exists (
          select 1
          from private.application_current_interview ci
          where ci.application_id = a.application_id
            and ci.interview_id = i.interview_id
        )
        and i.report_status_code not in ('HIRED', 'REJECTED')
      ) as can_edit,
      own_report.interview_report_id,
      own_report.version_no as own_version_no,
      own_report.professional_knowledge,
      own_report.necessary_skills,
      own_report.qualities_personality,
      own_report.strengths_limitations,
      own_report.other_comment,
      own_report.conclusion,
      own_report.expected_specific_job_assigned,
      own_report.expected_recruitment_time
    from public.interview_participants actor_ip
    join public.interviews i
      on i.interview_id = actor_ip.interview_id
    join public.applications a
      on a.application_id = i.application_id
    join public.submissions s
      on s.submission_id = a.submission_id
    join public.positions p
      on p.position_id = a.position_id
    left join public.interview_formats f
      on f.interview_format_id = i.interview_format_id
    left join public.rooms rm
      on rm.room_id = i.room_id
    left join lateral (
      select r.*
      from public.interview_reports r
      where r.interview_participant_id = actor_ip.interview_participant_id
        and r.is_active = true
        and r.is_archived = false
      order by r.created_at desc, r.interview_report_id desc
      limit 1
    ) own_report on true
    where actor_ip.app_user_id = v_actor_app_user_id
      and actor_ip.is_current = true
      and actor_ip.removed_at is null
      and a.is_active = true
      and i.is_active = true
      and i.visible_to_interviewers = true
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'application_id', ar.application_id,
        'interview_id', ar.interview_id,
        'round_no', ar.round_no,
        'is_current_round', ar.is_current_round,
        'candidate_name', ar.candidate_name,
        'position_name_vi', ar.position_name_vi,
        'position_name_en', ar.position_name_en,
        'start_at', ar.start_at,
        'end_at', ar.end_at,
        'format_name_vi', ar.format_name_vi,
        'format_name_en', ar.format_name_en,
        'room_name', ar.room_name,
        'meeting_link', ar.meeting_link,
        'display_report_status', ar.display_report_status,
        'can_edit', ar.can_edit,
        'interview_participant_id', ar.interview_participant_id,
        'has_own_report', ar.interview_report_id is not null,
        -- save_interviewer_report creates a version-1 row before applying the
        -- first patch, so an absent report starts with expected version 1.
        'own_version_no', coalesce(ar.own_version_no, 1),
        'own_report', jsonb_build_object(
          'professional_knowledge', ar.professional_knowledge,
          'necessary_skills', ar.necessary_skills,
          'qualities_personality', ar.qualities_personality,
          'strengths_limitations', ar.strengths_limitations,
          'other_comment', ar.other_comment,
          'conclusion', ar.conclusion,
          'expected_specific_job_assigned', ar.expected_specific_job_assigned,
          'expected_recruitment_time', ar.expected_recruitment_time
        ),
        'preview',
          case
            when ar.is_current_round then jsonb_build_object(
              'participants',
                coalesce(
                  (
                    select jsonb_agg(
                      jsonb_build_object(
                        'participant_order', ip.participant_order,
                        'name', ip.snapshot_name,
                        'job_title', ip.snapshot_job_title,
                        'report', jsonb_build_object(
                          'professional_knowledge', pr.professional_knowledge,
                          'necessary_skills', pr.necessary_skills,
                          'qualities_personality', pr.qualities_personality,
                          'strengths_limitations', pr.strengths_limitations,
                          'other_comment', pr.other_comment,
                          'conclusion', pr.conclusion,
                          'expected_specific_job_assigned', pr.expected_specific_job_assigned,
                          'expected_recruitment_time', pr.expected_recruitment_time
                        )
                      )
                      order by ip.participant_order, ip.interview_participant_id
                    )
                    from public.interview_participants ip
                    left join lateral (
                      select r.*
                      from public.interview_reports r
                      where r.interview_participant_id = ip.interview_participant_id
                        and r.is_active = true
                        and r.is_archived = false
                      order by r.created_at desc, r.interview_report_id desc
                      limit 1
                    ) pr on true
                    where ip.interview_id = ar.interview_id
                      and ip.is_current = true
                      and ip.removed_at is null
                  ),
                  '[]'::jsonb
                ),
              'final_decision',
                coalesce(
                  (
                    select jsonb_build_object(
                      'conclusion', fd.conclusion,
                      'expected_specific_job_assigned', fd.expected_specific_job_assigned,
                      'expected_recruitment_time', fd.expected_recruitment_time
                    )
                    from private.interview_final_decision_source fd
                    where fd.application_id = ar.application_id
                      and fd.interview_id = ar.interview_id
                  ),
                  jsonb_build_object(
                    'conclusion', null,
                    'expected_specific_job_assigned', null,
                    'expected_recruitment_time', null
                  )
                )
            )
            else null
          end
      )
      order by
        ar.candidate_name,
        ar.application_id,
        ar.round_no desc
    ),
    '[]'::jsonb
  )
  into v_rounds
  from accessible_rounds ar;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('rounds', v_rounds)
  );
end;
$$;

-- Keep the privileged implementation outside Supabase's exposed schemas.
-- Authenticated users receive schema USAGE plus EXECUTE on this single helper;
-- the helper still authenticates with auth.uid(), resolves an active app_user,
-- applies the exact contextual predicates, and emits a strict allowlisted DTO.
revoke all on function interviewer_report_private.get_interviewer_report_page_impl()
  from public, anon, authenticated;
grant execute on function interviewer_report_private.get_interviewer_report_page_impl()
  to authenticated, postgres, service_role;

-- Exposed API wrapper stays SECURITY INVOKER. It cannot bypass RLS itself and
-- delegates only to the bounded helper above; the private schema is not listed
-- in Supabase's exposed schemas.
create or replace function public.get_interviewer_report_page()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select interviewer_report_private.get_interviewer_report_page_impl();
$$;

revoke all on function public.get_interviewer_report_page()
  from public, anon, authenticated;
grant execute on function public.get_interviewer_report_page()
  to authenticated, postgres, service_role;
