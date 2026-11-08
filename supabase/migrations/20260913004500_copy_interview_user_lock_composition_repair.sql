-- SLICE-06 closing repair: compose S04 Save Copy with S06-002 Internal User
-- lifecycle/operationalization locking without moving accepted checkpoints.
--
-- Preserve the existing schedule-resource order used by Interview commands:
--   Candidate -> Room -> Interviewer resource advisories
-- and then acquire the complete Internal User row/advisory set in UUID order
-- before the first target Interview write / updated_by FK acquisition.
-- This closes both the stale active-participant drop race and the unscheduled
-- actor-FK/participant-row deadlock found by SLICE-06-CLOSING-REVIEW-001.

create or replace function public.copy_interview_schedule(
  p_source_interview_id uuid,
  p_target_application_id uuid,
  p_expected_source_version bigint,
  p_expected_target_application_version bigint,
  p_expected_target_round_id uuid,
  p_expected_target_round_version bigint,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_interview_format_id uuid,
  p_room_id uuid,
  p_meeting_link text,
  p_interview_note text,
  p_participant_app_user_ids uuid[],
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_source public.interviews%rowtype;
  v_expected_target public.interviews%rowtype;
  v_target public.interviews%rowtype;
  v_target_app public.applications%rowtype;
  v_source_app public.applications%rowtype;
  v_format jsonb;
  v_participant_ids uuid[] := coalesce(p_participant_app_user_ids, array[]::uuid[]);
  v_user_lock_ids uuid[];
  v_participant_count integer;
  v_expected_target_is_latest boolean;
  v_target_is_new boolean := false;
  v_existing jsonb;
  v_fingerprint text;
  v_result jsonb;
  v_submission_id uuid;
  v_candidate_id uuid;
  v_conflict text;
  v_next_round integer;
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;

  select u.app_user_id into v_actor
  from public.app_users u
  where u.auth_user_id = auth.uid()
    and u.is_active = true;

  if v_actor is null
     or (not private.is_root_admin()
         and (not private.has_permission('interviews.manage')
              or not private.has_permission('interviews.view'))) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;

  if p_source_interview_id is null
     or p_target_application_id is null
     or p_expected_source_version is null
     or p_expected_target_application_version is null
     or p_expected_target_round_id is null
     or p_expected_target_round_version is null
     or p_idempotency_key is null
     or p_participant_app_user_ids is null
     or (p_start_at is null) <> (p_end_at is null)
     or (p_start_at is not null and p_start_at >= p_end_at)
     or (p_start_at is not null and p_interview_format_id is null) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  select count(*), count(distinct participant_id)
  into v_participant_count, v_next_round
  from unnest(v_participant_ids) participant_id;

  if v_participant_count <> v_next_round
     or exists(select 1 from unnest(v_participant_ids) id where id is null) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'source_interview_id', p_source_interview_id,
        'target_application_id', p_target_application_id,
        'expected_source_version', p_expected_source_version,
        'expected_target_application_version', p_expected_target_application_version,
        'expected_target_round_id', p_expected_target_round_id,
        'expected_target_round_version', p_expected_target_round_version,
        'start_at', p_start_at,
        'end_at', p_end_at,
        'interview_format_id', p_interview_format_id,
        'room_id', p_room_id,
        'meeting_link', p_meeting_link,
        'interview_note', p_interview_note,
        'participant_app_user_ids', to_jsonb(v_participant_ids)
      )::text,
      'sha256'
    ),
    'hex'
  );

  v_existing := private.check_idempotency(
    'app_user:' || v_actor::text,
    'copy_interview_schedule',
    p_idempotency_key,
    v_fingerprint
  );
  if v_existing is not null then
    return v_existing;
  end if;

  -- Allocation serialization starts with the target parent.
  select * into v_target_app
  from public.applications
  where application_id = p_target_application_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_target_app.version_no <> p_expected_target_application_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;
  if not v_target_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  -- Lock both interview identities in one deterministic order, then re-read.
  perform 1
  from public.interviews
  where interview_id = any(array[p_source_interview_id, p_expected_target_round_id])
  order by interview_id
  for update;

  select * into v_source
  from public.interviews
  where interview_id = p_source_interview_id;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  select * into v_expected_target
  from public.interviews
  where interview_id = p_expected_target_round_id
    and application_id = p_target_application_id;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if v_source.version_no <> p_expected_source_version
     or v_expected_target.version_no <> p_expected_target_round_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  select not exists(
    select 1
    from public.interviews i
    where i.application_id = p_target_application_id
      and i.round_no > v_expected_target.round_no
  ) into v_expected_target_is_latest;

  if not v_expected_target_is_latest then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  select * into v_source_app
  from public.applications
  where application_id = v_source.application_id;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- Both submission rows are locked before any current-round recalculation.
  for v_submission_id in
    select submission_id
    from public.applications
    where application_id in (v_source.application_id, p_target_application_id)
    order by submission_id
  loop
    perform 1
    from public.submissions
    where submission_id = v_submission_id
    for update;
  end loop;

  if p_start_at is null then
    v_format := jsonb_build_object('room_id', null, 'meeting_link', null);
  else
    v_format := private.normalized_schedule_format(
      p_interview_format_id,
      p_room_id,
      p_meeting_link
    );
    if v_format is null or v_format ? 'error' then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;
  end if;

  if v_source.application_id <> p_target_application_id
     and private.is_structurally_empty_default_round(v_expected_target.interview_id) then
    v_target := v_expected_target;
  else
    if not v_expected_target.is_active then
      return jsonb_build_object('success', false, 'error_code', 'LATEST_INTERVIEW_INACTIVE');
    end if;
    if v_expected_target.report_status_code = 'HIRED' then
      return jsonb_build_object('success', false, 'error_code', 'APPLICATION_HIRED');
    end if;
    v_target_is_new := true;
  end if;

  -- Retain the accepted fast-fail for participants already known inactive.
  -- This is not the authoritative race check; a second check follows the full
  -- deterministic User row/advisory acquisition below.
  if exists(
    select 1
    from unnest(v_participant_ids) id
    where not exists(
      select 1
      from public.app_users u
      where u.app_user_id = id
        and u.is_active
    )
  ) then
    return jsonb_build_object(
      'success', false,
      'error_code', 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED'
    );
  end if;

  if p_start_at is not null then
    select s.candidate_id into v_candidate_id
    from public.submissions s
    where s.submission_id = v_target_app.submission_id;

    -- Preserve the existing resource order shared by scheduling commands.
    perform private.lock_interview_resources(
      v_candidate_id,
      (v_format ->> 'room_id')::uuid,
      v_participant_ids
    );

    select c.conflict_type into v_conflict
    from private.check_interview_conflicts(
      case when v_target_is_new then null else v_target.interview_id end,
      v_candidate_id,
      (v_format ->> 'room_id')::uuid,
      v_participant_ids,
      p_start_at,
      p_end_at
    ) c
    order by case c.conflict_type
      when 'CANDIDATE' then 1
      when 'ROOM' then 2
      else 3
    end
    limit 1;

    if v_conflict is not null then
      return jsonb_build_object(
        'success', false,
        'error_code', 'SCHEDULE_CONFLICT_' || v_conflict
      );
    end if;
  end if;

  -- Closing-review repair: after any schedule-resource gates, but before the
  -- first target Interview write/FK acquisition, lock actor + complete requested
  -- participant User set in deterministic UUID order. This is the same User-row
  -- ordering used by S06-002 Interview operationalization.
  select coalesce(
           array_agg(distinct q.app_user_id order by q.app_user_id),
           array[]::uuid[]
         )
  into v_user_lock_ids
  from (
    select unnest(v_participant_ids) as app_user_id
    union all
    select v_actor
  ) q
  where q.app_user_id is not null;

  perform 1
  from public.app_users u
  where u.app_user_id = any(v_user_lock_ids)
  order by u.app_user_id
  for update;

  perform private.lock_internal_user_ids(v_user_lock_ids);

  -- Authoritative post-lock exact-set revalidation. A participant that became
  -- inactive while Copy waited on Candidate/Room/Interviewer resource gates now
  -- causes atomic failure before any target Interview mutation.
  select count(*) into v_participant_count
  from public.app_users u
  where u.app_user_id = any(v_participant_ids)
    and u.is_active = true;

  if v_participant_count <> cardinality(v_participant_ids) then
    return jsonb_build_object(
      'success', false,
      'error_code', 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED'
    );
  end if;

  if v_target_is_new then
    v_next_round := v_expected_target.round_no + 1;
    insert into public.interviews(
      application_id,
      round_no,
      demo_topic,
      start_at,
      end_at,
      interview_format_id,
      room_id,
      meeting_link,
      interview_note,
      copied_from_interview_id,
      updated_by
    ) values (
      p_target_application_id,
      v_next_round,
      null,
      p_start_at,
      p_end_at,
      p_interview_format_id,
      (v_format ->> 'room_id')::uuid,
      v_format ->> 'meeting_link',
      p_interview_note,
      p_source_interview_id,
      v_actor
    ) returning * into v_target;
  else
    update public.interviews
    set start_at = p_start_at,
        end_at = p_end_at,
        interview_format_id = p_interview_format_id,
        room_id = (v_format ->> 'room_id')::uuid,
        meeting_link = v_format ->> 'meeting_link',
        interview_note = p_interview_note,
        demo_topic = null,
        copied_from_interview_id = p_source_interview_id,
        updated_by = v_actor
    where interview_id = v_target.interview_id
    returning * into v_target;
  end if;

  -- Participant identities are supplied in user-visible order. The complete set
  -- was already locked and revalidated above, so this join is identity-only; it
  -- cannot silently filter an ID based on a later activity change.
  insert into public.interview_participants(
    interview_id,
    app_user_id,
    participant_order,
    snapshot_name,
    snapshot_job_title,
    snapshot_email
  )
  select v_target.interview_id,
         x.app_user_id,
         x.ord::integer,
         case
           when source_snapshot.source_participant_id is not null
             then source_snapshot.snapshot_name
           else u.full_name
         end,
         case
           when source_snapshot.source_participant_id is not null
             then source_snapshot.snapshot_job_title
           else u.job_title
         end,
         case
           when source_snapshot.source_participant_id is not null
             then source_snapshot.snapshot_email
           else u.email
         end
  from unnest(v_participant_ids) with ordinality x(app_user_id, ord)
  join public.app_users u
    on u.app_user_id = x.app_user_id
  left join lateral (
    select ip.interview_participant_id as source_participant_id,
           ip.snapshot_name,
           ip.snapshot_job_title,
           ip.snapshot_email
    from public.interview_participants ip
    where ip.interview_id = v_source.interview_id
      and ip.app_user_id = x.app_user_id
      and ip.is_current
  ) source_snapshot on true;

  perform public.recalculate_submission_status(v_target_app.submission_id);

  perform private.audit_interview_command(
    'COPY_INTERVIEW_SCHEDULE',
    'INTERVIEW',
    v_target.interview_id,
    v_actor,
    p_idempotency_key,
    jsonb_build_object(
      'source_interview_id', p_source_interview_id,
      'target_application_id', p_target_application_id,
      'round_no', v_target.round_no,
      'filled_default_round', not v_target_is_new
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', v_target.interview_id,
      'application_id', p_target_application_id,
      'round_no', v_target.round_no,
      'copied_from_interview_id', p_source_interview_id,
      'version_no', v_target.version_no
    )
  );

  perform private.record_idempotency(
    'app_user:' || v_actor::text,
    'copy_interview_schedule',
    p_idempotency_key,
    v_fingerprint,
    v_result,
    'INTERVIEW',
    v_target.interview_id
  );

  return v_result;
end;
$$;

revoke all on function public.copy_interview_schedule(
  uuid, uuid, bigint, bigint, uuid, bigint,
  timestamptz, timestamptz, uuid, uuid, text, text, uuid[], uuid
) from public, anon;

grant execute on function public.copy_interview_schedule(
  uuid, uuid, bigint, bigint, uuid, bigint,
  timestamptz, timestamptz, uuid, uuid, text, text, uuid[], uuid
) to authenticated;
