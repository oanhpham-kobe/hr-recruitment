-- ============================================================================
-- RECOVERY PACKAGE 003: REC-04 Coordinated Transaction Correctness Repair
--
-- Findings Addressed:
--   - F04: Composed parent lock cycles and deterministic lock ordering with
--          revalidation after acquisition (Submission -> Application -> Interview
--          -> Participant / Report -> Schedule Resources -> App Users).
--   - F05: Interview reactivation persisted parent outcome recalculation in the
--          same transaction.
--   - F06: SQL NULL / non-positive expected-version rejection across direct
--          lifecycle boundaries, while preserving report field-merge semantics.
--   - F07: Atomic ALL_OR_NOTHING bulk interview deletion with zero-write preflight
--          so late failures leave rows, outcomes, cleanup queue, and audits
--          completely untouched.
--
-- Preserved:
--   - All S06-002 Internal User row/advisory locking and revalidation.
--   - Schedule resource advisory locking (Candidate -> Room -> Interviewer).
--   - Idempotency key requirement, replay fingerprints, and audit trails.
--   - Disjoint field-level patch merge semantics and conflict detection.
--
-- Scope: Narrowed strictly to the 15 functions with source-backed defects.
-- ============================================================================

-- -----------------------------------------------------------------------------
-- 1. create_next_interview_round
-- Fixes: F04 (Submission -> Application -> latest Interview lock order).
-- -----------------------------------------------------------------------------
create or replace function public.create_next_interview_round(
  p_application_id uuid,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_latest_interview public.interviews%rowtype;
  v_next_round integer;
  v_new_interview_id uuid;
  v_result jsonb;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select app_user_id into v_actor_app_user_id
  from public.app_users
  where auth_user_id = v_auth_uid
    and is_active = true;

  if v_actor_app_user_id is null
    or not (private.has_permission('interviews.manage') or private.is_root_admin()) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission interviews.manage required');
  end if;

  if p_application_id is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'application_id is required');
  end if;

  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;

  if p_idempotency_key is not null then
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'command', 'create_next_interview_round',
          'application_id', p_application_id
        )::text,
        'sha256'
      ),
      'hex'
    );

    v_existing_result := private.check_idempotency(
      v_actor_scope,
      'create_next_interview_round',
      p_idempotency_key,
      v_fingerprint
    );
    if v_existing_result is not null then
      return v_existing_result;
    end if;
  end if;

  -- F04: Resolve parent hierarchy, lock parent Submission first, then Application
  select a.submission_id into v_submission_id
  from public.applications a
  where a.application_id = p_application_id;

  if not found or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Application not found');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = p_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Application not found');
  end if;

  if not v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE', 'message', 'Cannot create an interview round for an inactive application');
  end if;

  -- Lock latest interview
  select * into v_latest_interview
  from public.interviews
  where application_id = p_application_id
  order by round_no desc
  limit 1
  for update;

  if found then
    if not v_latest_interview.is_active then
      return jsonb_build_object('success', false, 'error_code', 'LATEST_INTERVIEW_INACTIVE', 'message', 'The latest interview round is inactive');
    end if;

    if v_latest_interview.report_status_code = 'HIRED' then
      return jsonb_build_object('success', false, 'error_code', 'APPLICATION_HIRED', 'message', 'Cannot create an interview round after a hired result');
    end if;
  end if;

  v_next_round := coalesce(v_latest_interview.round_no, 0) + 1;

  insert into public.interviews (
    application_id,
    round_no,
    schedule_status_code,
    report_status_code,
    is_active,
    version_no
  ) values (
    p_application_id,
    v_next_round,
    'AVAILABLE',
    'INTERVIEW_SCHEDULING',
    true,
    1
  ) returning interview_id into v_new_interview_id;

  perform public.recalculate_submission_status(v_submission_id);

  perform private.audit_interview_command(
    'CREATE_NEXT_INTERVIEW_ROUND',
    'INTERVIEW',
    v_new_interview_id,
    v_actor_app_user_id,
    p_idempotency_key,
    jsonb_build_object(
      'application_id', p_application_id,
      'round_no', v_next_round
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', v_new_interview_id,
      'application_id', p_application_id,
      'round_no', v_next_round,
      'schedule_status_code', 'AVAILABLE',
      'report_status_code', 'INTERVIEW_SCHEDULING',
      'version_no', 1
    )
  );

  if p_idempotency_key is not null then
    perform private.record_idempotency(
      v_actor_scope,
      'create_next_interview_round',
      p_idempotency_key,
      v_fingerprint,
      v_result,
      'INTERVIEW',
      v_new_interview_id
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.create_next_interview_round(uuid, uuid) from public, anon;
grant execute on function public.create_next_interview_round(uuid, uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 2. reactivate_interview
-- Fixes: F04 (Submission -> Application -> Interview lock order),
--        F05 (recalculates parent Submission outcome in same transaction),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
create or replace function public.reactivate_interview(
  p_interview_id uuid,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_application_id uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_i public.interviews%rowtype;
  v_ids uuid[];
  v_error text;
begin
  if v_actor is null then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06: Reject NULL and non-positive expected versions
  if p_interview_id is null or p_expected_version is null or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- F04: Resolve parent hierarchy, lock Submission -> Application -> Interview
  select i.application_id, a.submission_id
  into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if not v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  select * into v_i
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found or v_i.application_id <> v_app.application_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if v_i.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if exists (
    select 1
    from public.interviews
    where application_id = v_i.application_id
      and round_no > v_i.round_no
      and is_active
  ) then
    return jsonb_build_object('success', false, 'error_code', 'LATEST_ROUND_REQUIRED');
  end if;

  if v_i.schedule_status_code <> 'CANCELLED'
     and v_i.start_at is not null
     and v_i.end_at is not null then
    select coalesce(array_agg(app_user_id order by app_user_id), array[]::uuid[])
    into v_ids
    from public.interview_participants
    where interview_id = p_interview_id
      and is_current;

    v_error := private.interview_resource_error(
      v_i,
      v_i.start_at,
      v_i.end_at,
      v_i.room_id,
      v_ids
    );
    if v_error is not null then
      return jsonb_build_object('success', false, 'error_code', v_error);
    end if;
  end if;

  update public.interviews
  set is_active = true,
      updated_by = v_actor
  where interview_id = p_interview_id;

  -- F05: Recalculate parent Submission outcome in the same transaction
  perform public.recalculate_submission_status(v_submission_id);

  perform private.audit_interview_command(
    'REACTIVATE_INTERVIEW',
    'INTERVIEW',
    p_interview_id,
    v_actor,
    null,
    '{}'::jsonb
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', p_interview_id,
      'is_active', true
    )
  );
end;
$$;

revoke all on function public.reactivate_interview(uuid, bigint) from public, anon;
grant execute on function public.reactivate_interview(uuid, bigint) to authenticated;


-- -----------------------------------------------------------------------------
-- 3. delete_or_inactivate_interview_core & delete_or_inactivate_interview
-- Fixes: F04 (Submission -> Application -> Interview lock order),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
create or replace function private.delete_or_inactivate_interview_core(
  p_interview_id uuid,
  p_expected_version bigint,
  p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_application_id uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_i public.interviews%rowtype;
  v_used boolean;
  v_res public.upload_reservations%rowtype;
begin
  -- F06: Reject NULL and non-positive expected versions
  if p_interview_id is null or p_expected_version is null or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- F04: Resolve parent hierarchy, lock Submission -> Application -> Interview
  select i.application_id, a.submission_id
  into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  select * into v_i
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found or v_i.application_id <> v_app.application_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if v_i.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if v_i.round_no <> (
    select max(round_no)
    from public.interviews
    where application_id = v_i.application_id
      and is_active
  ) then
    return jsonb_build_object('success', false, 'error_code', 'LATEST_ROUND_REQUIRED');
  end if;

  select exists(select 1 from public.interview_participants where interview_id = p_interview_id)
      or exists(select 1 from public.interview_document_logicals where interview_id = p_interview_id)
      or exists(select 1 from public.email_outbox where interview_id = p_interview_id)
      or exists(select 1 from public.email_history where interview_id = p_interview_id)
      or exists(select 1 from public.interviews where copied_from_interview_id = p_interview_id)
      or v_i.copied_from_interview_id is not null
      or v_i.start_at is not null or v_i.end_at is not null or nullif(btrim(coalesce(v_i.demo_topic, '')), '') is not null
      or nullif(btrim(coalesce(v_i.interview_note, '')), '') is not null or nullif(btrim(coalesce(v_i.hr_report_note, '')), '') is not null
      or v_i.schedule_status_code <> 'AVAILABLE' or v_i.report_status_code <> 'INTERVIEW_SCHEDULING' into v_used;

  if not v_used then
    for v_res in
      select *
      from public.upload_reservations
      where interview_id = p_interview_id
      order by upload_reservation_id
      for update
    loop
      insert into public.storage_cleanup_queue(
        source_type, source_parent_id, source_upload_reservation_id,
        bucket_name, object_path, reason_code, status_code, not_before
      ) values (
        'INTERVIEW_UPLOAD', p_interview_id, v_res.upload_reservation_id,
        v_res.temp_bucket, v_res.temp_path, 'INTERVIEW_HARD_DELETE', 'PENDING',
        greatest(v_res.expires_at, coalesce(v_res.signed_upload_expires_at, v_res.expires_at))
      )
      on conflict (bucket_name, object_path)
      do update set not_before = greatest(public.storage_cleanup_queue.not_before, excluded.not_before);

      delete from public.upload_reservations where upload_reservation_id = v_res.upload_reservation_id;
    end loop;

    perform private.audit_interview_command('DELETE_INTERVIEW', 'INTERVIEW', p_interview_id, p_actor, null, '{}'::jsonb);
    delete from public.interviews where interview_id = p_interview_id;
    perform public.recalculate_submission_status(v_submission_id);
    return jsonb_build_object('success', true, 'data', jsonb_build_object('interview_id', p_interview_id, 'action', 'DELETED'));
  end if;

  update public.interviews
  set is_active = false,
      updated_by = p_actor
  where interview_id = p_interview_id;

  perform public.recalculate_submission_status(v_submission_id);
  perform private.audit_interview_command('INACTIVATE_INTERVIEW', 'INTERVIEW', p_interview_id, p_actor, null, '{}'::jsonb);
  return jsonb_build_object('success', true, 'data', jsonb_build_object('interview_id', p_interview_id, 'action', 'INACTIVATED'));
end;
$$;

revoke all on function private.delete_or_inactivate_interview_core(uuid, bigint, uuid) from public, anon, authenticated;
grant execute on function private.delete_or_inactivate_interview_core(uuid, bigint, uuid) to postgres, service_role;

create or replace function public.delete_or_inactivate_interview(
  p_interview_id uuid,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;
  if p_interview_id is null or p_expected_version is null or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;
  return private.delete_or_inactivate_interview_core(p_interview_id, p_expected_version, v_actor);
end;
$$;

revoke all on function public.delete_or_inactivate_interview(uuid, bigint) from public, anon;
grant execute on function public.delete_or_inactivate_interview(uuid, bigint) to authenticated;


-- -----------------------------------------------------------------------------
-- 4. bulk_delete_or_inactivate_interviews
-- Fixes: F04 (deterministic parent/interview locking hierarchy),
--        F06 (rejects NULL and non-positive expected versions),
--        F07 (atomic ALL_OR_NOTHING: zero writes before full preflight passes).
-- -----------------------------------------------------------------------------
create or replace function public.bulk_delete_or_inactivate_interviews(
  p_interview_ids uuid[],
  p_expected_versions bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_id uuid;
  v_version bigint;
  v_i public.interviews%rowtype;
  v_used boolean;
  v_res public.upload_reservations%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_affected_submissions uuid[];
  v_idx integer;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06 & batch bounds validation
  if p_interview_ids is null
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
     or (select count(distinct id) from unnest(p_interview_ids) id) <> cardinality(p_interview_ids) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if (
    select count(*)
    from public.interviews
    where interview_id = any(p_interview_ids)
  ) <> cardinality(p_interview_ids) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- F04: Deterministic parent/resource lock hierarchy
  -- Step 1: Lock all affected Submissions in deterministic ID order
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

  -- Step 2: Lock all affected Applications in deterministic ID order
  perform 1
  from public.applications a
  where a.application_id in (
    select distinct i.application_id
    from public.interviews i
    where i.interview_id = any(p_interview_ids)
  )
  order by a.application_id
  for update;

  -- Step 3: Lock target Interviews in deterministic ID order
  perform 1
  from public.interviews i
  where i.interview_id = any(p_interview_ids)
  order by i.interview_id
  for update;

  -- Post-lock revalidation: verify all target interviews still exist after locking
  if (
    select count(*)
    from public.interviews
    where interview_id = any(p_interview_ids)
  ) <> cardinality(p_interview_ids) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- F07: Full preflight loop with ZERO writes.
  -- A stale version or non-latest round anywhere in the batch aborts immediately
  -- leaving all rows, outcomes, audits, and cleanup queue records unchanged.
  for v_id in select id from unnest(p_interview_ids) id order by id loop
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

    if v_i.round_no <> (
      select max(round_no)
      from public.interviews
      where application_id = v_i.application_id
        and is_active
    ) then
      return jsonb_build_object('success', false, 'error_code', 'LATEST_ROUND_REQUIRED');
    end if;
  end loop;

  -- Capture affected parent Submissions before any row deletion
  select coalesce(array_agg(distinct a.submission_id order by a.submission_id), array[]::uuid[])
  into v_affected_submissions
  from public.applications a
  join public.interviews i on i.application_id = a.application_id
  where i.interview_id = any(p_interview_ids);

  -- Mutate batch in deterministic order (preflight guaranteed all items are valid)
  for v_id in select id from unnest(p_interview_ids) id order by id loop
    select * into v_i from public.interviews where interview_id = v_id;

    select exists(select 1 from public.interview_participants where interview_id = v_id)
        or exists(select 1 from public.interview_document_logicals where interview_id = v_id)
        or exists(select 1 from public.email_outbox where interview_id = v_id)
        or exists(select 1 from public.email_history where interview_id = v_id)
        or exists(select 1 from public.interviews where copied_from_interview_id = v_id)
        or v_i.copied_from_interview_id is not null
        or v_i.start_at is not null or v_i.end_at is not null or nullif(btrim(coalesce(v_i.demo_topic, '')), '') is not null
        or nullif(btrim(coalesce(v_i.interview_note, '')), '') is not null or nullif(btrim(coalesce(v_i.hr_report_note, '')), '') is not null
        or v_i.schedule_status_code <> 'AVAILABLE' or v_i.report_status_code <> 'INTERVIEW_SCHEDULING' into v_used;

    if not v_used then
      for v_res in
        select *
        from public.upload_reservations
        where interview_id = v_id
        order by upload_reservation_id
        for update
      loop
        insert into public.storage_cleanup_queue(
          source_type, source_parent_id, source_upload_reservation_id,
          bucket_name, object_path, reason_code, status_code, not_before
        ) values (
          'INTERVIEW_UPLOAD', v_id, v_res.upload_reservation_id,
          v_res.temp_bucket, v_res.temp_path, 'INTERVIEW_HARD_DELETE', 'PENDING',
          greatest(v_res.expires_at, coalesce(v_res.signed_upload_expires_at, v_res.expires_at))
        )
        on conflict (bucket_name, object_path)
        do update set not_before = greatest(public.storage_cleanup_queue.not_before, excluded.not_before);

        delete from public.upload_reservations where upload_reservation_id = v_res.upload_reservation_id;
      end loop;

      perform private.audit_interview_command('DELETE_INTERVIEW', 'INTERVIEW', v_id, v_actor, null, '{}'::jsonb);
      delete from public.interviews where interview_id = v_id;
      v_items := v_items || jsonb_build_array(jsonb_build_object('interview_id', v_id, 'action', 'DELETED'));
    else
      update public.interviews
      set is_active = false,
          updated_by = v_actor
      where interview_id = v_id;

      perform private.audit_interview_command('INACTIVATE_INTERVIEW', 'INTERVIEW', v_id, v_actor, null, '{}'::jsonb);
      v_items := v_items || jsonb_build_array(jsonb_build_object('interview_id', v_id, 'action', 'INACTIVATED'));
    end if;
  end loop;

  -- Recalculate each affected parent Submission once
  for v_idx in 1..cardinality(v_affected_submissions) loop
    perform public.recalculate_submission_status(v_affected_submissions[v_idx]);
  end loop;

  return jsonb_build_object('success', true, 'data', jsonb_build_object('items', v_items));
end;
$$;

revoke all on function public.bulk_delete_or_inactivate_interviews(uuid[], bigint[]) from public, anon;
grant execute on function public.bulk_delete_or_inactivate_interviews(uuid[], bigint[]) to authenticated;


-- -----------------------------------------------------------------------------
-- 5. copy_interview_schedule
-- Fixes: F04 (Submission -> Application -> Interview lock composition),
--        F06 (rejects non-positive expected versions).
-- Preserves: All S06-002 (20260913004500) contract:
--   - Non-null p_idempotency_key and p_participant_app_user_ids checked before idempotency.
--   - to_jsonb(v_participant_ids) in fingerprint.
--   - Resource locks (Candidate -> Room -> Interviewer).
--   - Deterministic actor + participant app_users row locks in UUID order.
--   - private.lock_internal_user_ids advisory locks and active user revalidation.
-- -----------------------------------------------------------------------------
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
  v_target_sub_id uuid;
  v_source_app_id uuid;
  v_source_sub_id uuid;
  v_app_row public.applications%rowtype;
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

  -- 20260913004500:69-80 validation contract strictly preserved before check_idempotency
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

  -- F04: Resolve parent hierarchy: Submissions -> Applications -> Interviews
  select a.submission_id into v_target_sub_id
  from public.applications a
  where a.application_id = p_target_application_id;

  if not found or v_target_sub_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  select i.application_id, a.submission_id
  into v_source_app_id, v_source_sub_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_source_interview_id;

  if not found or v_source_app_id is null or v_source_sub_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- Step 1: Lock Submissions in deterministic ID order
  for v_submission_id in
    select distinct sid
    from unnest(array[v_target_sub_id, v_source_sub_id]) sid
    order by sid
  loop
    perform 1 from public.submissions where submission_id = v_submission_id for update;
  end loop;

  -- Step 2: Lock Applications in deterministic ID order
  for v_app_row in
    select a.*
    from public.applications a
    where a.application_id in (p_target_application_id, v_source_app_id)
    order by a.application_id
    for update
  loop
    if v_app_row.application_id = p_target_application_id then
      v_target_app := v_app_row;
    end if;
    if v_app_row.application_id = v_source_app_id then
      v_source_app := v_app_row;
    end if;
  end loop;

  if v_target_app.application_id is null or v_target_app.submission_id <> v_target_sub_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_target_app.version_no <> p_expected_target_application_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;
  if not v_target_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  -- Step 3: Lock Interviews in deterministic ID order
  perform 1
  from public.interviews
  where interview_id = any(array[p_source_interview_id, p_expected_target_round_id])
  order by interview_id
  for update;

  select * into v_source
  from public.interviews
  where interview_id = p_source_interview_id;
  if not found or v_source.application_id <> v_source_app.application_id then
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


-- -----------------------------------------------------------------------------
-- 6. save_interview_schedule
-- Fixes: F04 (Submission -> Application -> Interview lock composition),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
create or replace function public.save_interview_schedule(
  p_interview_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_interview_format_id uuid,
  p_room_id uuid,
  p_meeting_link text,
  p_demo_topic text,
  p_interview_note text,
  p_expected_version bigint,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_application_id uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_i public.interviews%rowtype;
  v_format jsonb;
  v_ids uuid[];
  v_error text;
  v_result jsonb;
  v_existing jsonb;
  v_fingerprint text;
begin
  if v_actor is null then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06: Reject NULL and non-positive expected versions
  if p_interview_id is null
     or p_expected_version is null
     or p_expected_version < 1
     or (p_start_at is null) <> (p_end_at is null)
     or (p_start_at is not null and p_interview_format_id is null) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if p_start_at is not null and p_end_at is not null and p_start_at >= p_end_at then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_INTERVAL');
  end if;

  if p_idempotency_key is not null then
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'interview_id', p_interview_id,
          'start_at', p_start_at,
          'end_at', p_end_at,
          'format', p_interview_format_id,
          'room', p_room_id,
          'meeting_link', p_meeting_link,
          'demo_topic', p_demo_topic,
          'note', p_interview_note,
          'version', p_expected_version
        )::text,
        'sha256'
      ),
      'hex'
    );
    v_existing := private.check_idempotency('app_user:' || v_actor::text, 'save_interview_schedule', p_idempotency_key, v_fingerprint);
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- F04: Resolve parent hierarchy, lock Submission -> Application -> Interview
  select i.application_id, a.submission_id
  into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if not v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  select * into v_i
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found or v_i.application_id <> v_app.application_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if v_i.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if v_i.schedule_status_code = 'CONFIRMED' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE');
  end if;

  if p_start_at is not null then
    v_format := private.normalized_schedule_format(p_interview_format_id, p_room_id, p_meeting_link);
    if v_format is null or v_format ? 'error' then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
    end if;

    select coalesce(array_agg(app_user_id order by app_user_id), array[]::uuid[])
    into v_ids
    from public.interview_participants
    where interview_id = p_interview_id and is_current;

    if v_i.is_active and v_i.schedule_status_code <> 'CANCELLED' then
      v_error := private.interview_resource_error(v_i, p_start_at, p_end_at, (v_format ->> 'room_id')::uuid, v_ids);
      if v_error is not null then
        return jsonb_build_object('success', false, 'error_code', v_error);
      end if;
    end if;
  else
    v_format := jsonb_build_object('room_id', null, 'meeting_link', null);
  end if;

  update public.interviews
  set start_at = p_start_at,
      end_at = p_end_at,
      interview_format_id = p_interview_format_id,
      room_id = (v_format ->> 'room_id')::uuid,
      meeting_link = v_format ->> 'meeting_link',
      demo_topic = p_demo_topic,
      interview_note = p_interview_note,
      updated_by = v_actor
  where interview_id = p_interview_id;

  perform private.audit_interview_command(
    'SAVE_INTERVIEW_SCHEDULE',
    'INTERVIEW',
    p_interview_id,
    v_actor,
    p_idempotency_key,
    jsonb_build_object('start_at', p_start_at, 'end_at', p_end_at)
  );

  v_result := jsonb_build_object('success', true, 'data', jsonb_build_object('interview_id', p_interview_id, 'version_no', v_i.version_no + 1));

  if p_idempotency_key is not null then
    perform private.record_idempotency(
      'app_user:' || v_actor::text,
      'save_interview_schedule',
      p_idempotency_key,
      v_fingerprint,
      v_result,
      'INTERVIEW',
      p_interview_id
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.save_interview_schedule(uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, bigint, uuid) from public, anon;
grant execute on function public.save_interview_schedule(uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, bigint, uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 7. change_interview_schedule_status
-- Fixes: F04 (Submission -> Application -> Interview lock order),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
create or replace function public.change_interview_schedule_status(
  p_interview_id uuid,
  p_schedule_status_code text,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.status');
  v_application_id uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_i public.interviews%rowtype;
  v_ids uuid[];
  v_error text;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06: Reject NULL and non-positive expected versions
  if p_interview_id is null
     or p_expected_version is null
     or p_expected_version < 1
     or p_schedule_status_code not in ('AVAILABLE','SCHEDULED','AWAITING','CONFIRMED','CANCELLED') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- F04: Resolve parent hierarchy, lock Submission -> Application -> Interview
  select i.application_id, a.submission_id
  into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if not v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  select * into v_i
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found or v_i.application_id <> v_app.application_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if v_i.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if p_schedule_status_code <> 'CANCELLED'
     and v_i.is_active
     and v_i.start_at is not null
     and v_i.end_at is not null then
    select coalesce(array_agg(app_user_id order by app_user_id), array[]::uuid[])
    into v_ids
    from public.interview_participants
    where interview_id = p_interview_id and is_current;

    v_error := private.interview_resource_error(v_i, v_i.start_at, v_i.end_at, v_i.room_id, v_ids);
    if v_error is not null then
      return jsonb_build_object('success', false, 'error_code', v_error);
    end if;
  end if;

  update public.interviews
  set schedule_status_code = p_schedule_status_code,
      updated_by = v_actor
  where interview_id = p_interview_id;

  perform private.audit_interview_command(
    'CHANGE_INTERVIEW_SCHEDULE_STATUS',
    'INTERVIEW',
    p_interview_id,
    v_actor,
    null,
    jsonb_build_object('schedule_status_code', p_schedule_status_code)
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', p_interview_id,
      'schedule_status_code', p_schedule_status_code
    )
  );
end;
$$;

revoke all on function public.change_interview_schedule_status(uuid, text, bigint) from public, anon;
grant execute on function public.change_interview_schedule_status(uuid, text, bigint) to authenticated;


-- -----------------------------------------------------------------------------
-- 8. reschedule_confirmed_interview
-- Fixes: F04 (Submission -> Application -> Interview lock order),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
create or replace function public.reschedule_confirmed_interview(
  p_interview_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_interview_format_id uuid,
  p_room_id uuid,
  p_meeting_link text,
  p_expected_version bigint,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_application_id uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_i public.interviews%rowtype;
  v_format jsonb;
  v_ids uuid[];
  v_error text;
  v_result jsonb;
  v_existing jsonb;
  v_fingerprint text;
begin
  if v_actor is null then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06: Reject NULL and non-positive expected versions, and validate required IDs
  if p_interview_id is null
     or p_interview_format_id is null
     or p_expected_version is null
     or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if p_start_at is null or p_end_at is null or p_start_at >= p_end_at then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_INTERVAL');
  end if;

  if p_idempotency_key is not null then
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'interview_id', p_interview_id,
          'start_at', p_start_at,
          'end_at', p_end_at,
          'format', p_interview_format_id,
          'room', p_room_id,
          'link', p_meeting_link,
          'version', p_expected_version
        )::text,
        'sha256'
      ),
      'hex'
    );
    v_existing := private.check_idempotency('app_user:' || v_actor::text, 'reschedule_confirmed_interview', p_idempotency_key, v_fingerprint);
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- F04: Resolve parent hierarchy, lock Submission -> Application -> Interview
  select i.application_id, a.submission_id
  into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if not v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  select * into v_i
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found or v_i.application_id <> v_app.application_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if v_i.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if v_i.schedule_status_code <> 'CONFIRMED' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE');
  end if;

  v_format := private.normalized_schedule_format(p_interview_format_id, p_room_id, p_meeting_link);
  if v_format is null or v_format ? 'error' then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  select coalesce(array_agg(app_user_id order by app_user_id), array[]::uuid[])
  into v_ids
  from public.interview_participants
  where interview_id = p_interview_id and is_current;

  v_error := private.interview_resource_error(v_i, p_start_at, p_end_at, (v_format ->> 'room_id')::uuid, v_ids);
  if v_error is not null then
    return jsonb_build_object('success', false, 'error_code', v_error);
  end if;

  update public.interviews
  set start_at = p_start_at,
      end_at = p_end_at,
      interview_format_id = p_interview_format_id,
      room_id = (v_format ->> 'room_id')::uuid,
      meeting_link = v_format ->> 'meeting_link',
      schedule_status_code = 'AWAITING',
      updated_by = v_actor
  where interview_id = p_interview_id;

  perform private.audit_interview_command(
    'RESCHEDULE_CONFIRMED_INTERVIEW',
    'INTERVIEW',
    p_interview_id,
    v_actor,
    p_idempotency_key,
    jsonb_build_object('schedule_status_code', 'AWAITING')
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', p_interview_id,
      'schedule_status_code', 'AWAITING'
    )
  );

  if p_idempotency_key is not null then
    perform private.record_idempotency(
      'app_user:' || v_actor::text,
      'reschedule_confirmed_interview',
      p_idempotency_key,
      v_fingerprint,
      v_result,
      'INTERVIEW',
      p_interview_id
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.reschedule_confirmed_interview(uuid, timestamptz, timestamptz, uuid, uuid, text, bigint, uuid) from public, anon;
grant execute on function public.reschedule_confirmed_interview(uuid, timestamptz, timestamptz, uuid, uuid, text, bigint, uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 9. bulk_change_interview_schedule_status
-- Fixes: F04 (Submission -> Application -> Interview lock order),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
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


-- -----------------------------------------------------------------------------
-- 10. change_report_status
-- Fixes: F04 (Submission -> Application -> Interview lock composition),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
create or replace function public.change_report_status(
  p_interview_id uuid,
  p_report_status_code text,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('reports.manage_status');
  v_application_id uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_i public.interviews%rowtype;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('reports.view')) then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06: Reject NULL and non-positive expected versions
  if p_interview_id is null
     or p_expected_version is null
     or p_expected_version < 1
     or p_report_status_code not in ('INTERVIEW_SCHEDULING','AWAITING_INTERVIEW','WAITING_FOR_REPORT','REPORT_SUBMITTED','FOLLOW_UP','ON_HOLD','HIRED','REJECTED') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- F04: Resolve parent hierarchy, lock Submission -> Application -> Interview
  select i.application_id, a.submission_id
  into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if not v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE');
  end if;

  select * into v_i
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found or v_i.application_id <> v_app.application_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if v_i.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  if not exists (
    select 1
    from private.application_current_interview ci
    where ci.application_id = v_i.application_id
      and ci.interview_id = v_i.interview_id
  ) then
    return jsonb_build_object('success', false, 'error_code', 'LATEST_ROUND_REQUIRED');
  end if;

  update public.interviews
  set report_status_code = p_report_status_code,
      updated_by = v_actor
  where interview_id = p_interview_id;

  perform public.recalculate_submission_status(v_app.submission_id);

  perform private.audit_interview_command(
    'CHANGE_REPORT_STATUS',
    'INTERVIEW',
    p_interview_id,
    v_actor,
    null,
    jsonb_build_object('report_status_code', p_report_status_code)
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', p_interview_id,
      'report_status_code', p_report_status_code
    )
  );
end;
$$;

revoke all on function public.change_report_status(uuid, text, bigint) from public, anon;
grant execute on function public.change_report_status(uuid, text, bigint) to authenticated;


-- -----------------------------------------------------------------------------
-- 10b. bulk_change_report_status
-- Fixes: Deadlock with Submission-first single report writers.
--        Locks complete sorted Submission set before Applications/Interviews,
--        preserves permission/current-round/version/atomicity/recalculation.
--        Null-safely rejects NULL expected_versions array.
--        Revalidates target count after lock.
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
  v_count integer;
  v_interview_id uuid;
  v_expected_version bigint;
  v_interview public.interviews%rowtype;
  v_affected_submissions uuid[];
  v_idx integer;
begin
  if v_actor is null
     or (not private.is_root_admin() and not private.has_permission('reports.view')) then
    return jsonb_build_object(
      'success', false,
      'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end
    );
  end if;

  if p_interview_ids is null
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
     or (select count(distinct id) from unnest(p_interview_ids) id) <> cardinality(p_interview_ids) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  v_count := cardinality(p_interview_ids);

  if (
    select count(*)
    from public.interviews i
    where i.interview_id = any(p_interview_ids)
  ) <> v_count then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- Deterministic lock hierarchy: Submissions -> Applications -> Interviews
  -- Step 1: Lock complete sorted Submissions set first
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

  -- Step 2: Lock complete sorted Applications set
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

  -- Step 3: Lock complete sorted Interviews set
  perform 1
  from public.interviews i
  where i.interview_id = any(p_interview_ids)
  order by i.interview_id
  for update;

  -- Post-lock target revalidation
  if (
    select count(*)
    from public.interviews i
    where i.interview_id = any(p_interview_ids)
  ) <> v_count then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- Full-set lock-time Current Round + version preflight. No writes occur before
  -- every selected Interview passes this loop.
  for v_interview_id in
    select id from unnest(p_interview_ids) id order by id
  loop
    select i.* into v_interview
    from public.interviews i
    where i.interview_id = v_interview_id;

    if not found or v_interview.interview_id is null then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;

    select v.ver into v_expected_version
    from unnest(p_interview_ids) with ordinality as u(id, ord)
    join unnest(p_expected_versions) with ordinality as v(ver, ord) on u.ord = v.ord
    where u.id = v_interview_id;

    if v_expected_version is null or v_interview.version_no is distinct from v_expected_version then
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

  -- Capture affected parent Submissions before writes
  select coalesce(array_agg(distinct a.submission_id order by a.submission_id), array[]::uuid[])
  into v_affected_submissions
  from public.applications a
  join public.interviews i on i.application_id = a.application_id
  where i.interview_id = any(p_interview_ids);

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

  for v_idx in 1..cardinality(v_affected_submissions) loop
    perform public.recalculate_submission_status(v_affected_submissions[v_idx]);
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

revoke all on function public.bulk_change_report_status(uuid[], text, bigint[]) from public, anon;
grant execute on function public.bulk_change_report_status(uuid[], text, bigint[]) to authenticated;


-- -----------------------------------------------------------------------------
-- 11. update_hr_report_note
-- Fixes: F04 (Submission -> Application -> Interview lock order),
--        F06 (rejects NULL and non-positive expected versions).
-- -----------------------------------------------------------------------------
create or replace function public.update_hr_report_note(
  p_interview_id uuid,
  p_hr_report_note text,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('reports.manage_status');
  v_application_id uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_i public.interviews%rowtype;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('reports.view')) then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  -- F06: Reject NULL and non-positive expected versions
  if p_interview_id is null or p_expected_version is null or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- F04: Resolve parent hierarchy, lock Submission -> Application -> Interview
  select i.application_id, a.submission_id
  into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = p_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  select * into v_i
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found or v_i.application_id <> v_app.application_id then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  if v_i.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;

  update public.interviews
  set hr_report_note = p_hr_report_note,
      updated_by = v_actor
  where interview_id = p_interview_id;

  perform private.audit_interview_command(
    'UPDATE_HR_REPORT_NOTE',
    'INTERVIEW',
    p_interview_id,
    v_actor,
    null,
    '{}'::jsonb
  );

  return jsonb_build_object('success', true, 'data', jsonb_build_object('interview_id', p_interview_id));
end;
$$;

revoke all on function public.update_hr_report_note(uuid, text, bigint) from public, anon;
grant execute on function public.update_hr_report_note(uuid, text, bigint) to authenticated;


-- -----------------------------------------------------------------------------
-- 12. delete_or_inactivate_report
-- Fixes: F04 (Submission -> Application -> Interview -> Report lock order),
--        F06 (rejects NULL and non-positive expected versions).
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
  v_interview_id uuid;
  v_application_id uuid;
  v_submission_id uuid;
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

  -- F06: Reject NULL and non-positive expected versions
  if p_interview_report_id is null or p_expected_version is null or p_expected_version < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- F04: Resolve parent hierarchy
  select ip.interview_id, i.application_id, a.submission_id
  into v_interview_id, v_application_id, v_submission_id
  from public.interview_reports r
  join public.interview_participants ip on ip.interview_participant_id = r.interview_participant_id
  join public.interviews i on i.interview_id = ip.interview_id
  join public.applications a on a.application_id = i.application_id
  where r.interview_report_id = p_interview_report_id;

  if not found or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1 from public.submissions where submission_id = v_submission_id for update;
  perform 1 from public.applications where application_id = v_application_id for update;
  perform 1 from public.interviews where interview_id = v_interview_id for update;

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

    return jsonb_build_object('success', true, 'data', jsonb_build_object('action', 'INACTIVATED'));
  end if;

  delete from public.interview_reports where interview_report_id = p_interview_report_id;

  perform private.audit_interview_command(
    'DELETE_INTERVIEW_REPORT',
    'INTERVIEW_REPORT',
    p_interview_report_id,
    v_actor,
    null,
    '{}'::jsonb
  );

  return jsonb_build_object('success', true, 'data', jsonb_build_object('action', 'DELETED'));
end;
$$;

revoke all on function public.delete_or_inactivate_report(uuid, bigint) from public, anon;
grant execute on function public.delete_or_inactivate_report(uuid, bigint) to authenticated;


-- -----------------------------------------------------------------------------
-- 13. save_interviewer_report_core
-- Fixes: F04 (Submission -> Application -> Interview -> Participant -> Report lock order),
--        F06 (rejects NULL and non-positive expected versions).
-- Retains: Disjoint field-level merge for both owner and HR.
-- -----------------------------------------------------------------------------
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
  v_submission_id uuid;
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

  -- F06: Reject NULL and non-positive expected versions
  if p_interview_participant_id is null
     or p_expected_version_no is null
     or p_expected_version_no < 1 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
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

  -- F04: Resolve parent hierarchy: participant -> interview -> application -> submission
  select ip.interview_id
    into v_interview_id
  from public.interview_participants ip
  where ip.interview_participant_id = p_interview_participant_id;

  if not found or v_interview_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  select i.application_id, a.submission_id
    into v_application_id, v_submission_id
  from public.interviews i
  join public.applications a on a.application_id = i.application_id
  where i.interview_id = v_interview_id;

  if not found or v_application_id is null or v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  -- Lock hierarchy: Submission -> Application -> Interview -> Participant
  perform 1
  from public.submissions s
  where s.submission_id = v_submission_id
  for update;

  select * into v_app
  from public.applications
  where application_id = v_application_id
  for update;

  if not found or v_app.submission_id <> v_submission_id then
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

  -- Preserved field-level conflict detection
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
      'interview_participant_id', v_report.interview_participant_id,
      'version_no', v_report.version_no,
      'owner_merged', v_owner and v_conflict
    )
  );
end;
$$;

revoke all on function private.save_interviewer_report_core(uuid, jsonb, bigint, jsonb, boolean) from public, anon, authenticated;
grant execute on function private.save_interviewer_report_core(uuid, jsonb, bigint, jsonb, boolean) to postgres, service_role;
