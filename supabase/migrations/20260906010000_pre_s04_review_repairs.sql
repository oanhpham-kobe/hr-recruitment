-- Migration: 20260906010000_pre_s04_review_repairs.sql
-- PRE-S04 independent implementation-review repairs.

-- -----------------------------------------------------------------------------
-- 1. Candidate privacy-notice recovery without losing the open draft/session
-- -----------------------------------------------------------------------------
create or replace function public.refresh_candidate_form_privacy_notice(
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_cand record;
  v_session record;
  v_notice record;
begin
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  select * into v_cand
  from public.candidates
  where auth_user_id = v_auth_uid;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  if not v_cand.is_active then
    return jsonb_build_object('success', false, 'error_code', 'USER_INACTIVE', 'message', 'Candidate account is inactive');
  end if;

  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_session_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate form session not found or access denied');
  end if;

  if v_session.status_code <> 'OPEN' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Candidate form session is not open');
  end if;

  if v_session.expires_at <= clock_timestamp() then
    update public.candidate_form_sessions
    set status_code = 'EXPIRED', updated_at = clock_timestamp()
    where candidate_form_session_id = p_session_id;
    return jsonb_build_object('success', false, 'error_code', 'FORM_SESSION_EXPIRED', 'message', 'Candidate form session has expired');
  end if;

  select notice_version, content_vi, content_en
  into v_notice
  from public.privacy_notice_versions
  where is_current = true
    and effective_from <= clock_timestamp()
  order by effective_from desc
  limit 1;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'PRIVACY_NOTICE_UNAVAILABLE', 'message', 'Current privacy notice is unavailable');
  end if;

  update public.candidate_form_sessions
  set presented_privacy_notice_version = v_notice.notice_version,
      updated_at = clock_timestamp()
  where candidate_form_session_id = p_session_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_form_session_id', p_session_id,
      'mode_code', v_session.mode_code,
      'target_submission_id', v_session.target_submission_id,
      'base_submission_version_no', v_session.base_submission_version_no,
      'presented_privacy_notice_version', v_notice.notice_version,
      'expires_at', v_session.expires_at,
      'privacy_notice', jsonb_build_object(
        'notice_version', v_notice.notice_version,
        'content_vi', v_notice.content_vi,
        'content_en', v_notice.content_en
      )
    )
  );
end;
$$;

revoke all on function public.refresh_candidate_form_privacy_notice(uuid) from public, anon;
grant execute on function public.refresh_candidate_form_privacy_notice(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Cancel one staged document change while retaining the form session
-- -----------------------------------------------------------------------------
create or replace function public.cancel_candidate_form_document_change(
  p_session_id uuid,
  p_change_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_cand record;
  v_session record;
  v_change record;
  v_reservation record;
begin
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  select * into v_cand
  from public.candidates
  where auth_user_id = v_auth_uid;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  if not v_cand.is_active then
    return jsonb_build_object('success', false, 'error_code', 'USER_INACTIVE', 'message', 'Candidate account is inactive');
  end if;

  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_session_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate form session not found or access denied');
  end if;

  if v_session.status_code <> 'OPEN' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Candidate form session is not open');
  end if;

  if v_session.expires_at <= clock_timestamp() then
    update public.candidate_form_sessions
    set status_code = 'EXPIRED', updated_at = clock_timestamp()
    where candidate_form_session_id = p_session_id;
    return jsonb_build_object('success', false, 'error_code', 'FORM_SESSION_EXPIRED', 'message', 'Candidate form session has expired');
  end if;

  select * into v_change
  from public.candidate_form_document_changes
  where candidate_form_document_change_id = p_change_id
    and candidate_form_session_id = p_session_id
    and status_code = 'PENDING'
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Pending document change not found');
  end if;

  if v_change.upload_reservation_id is not null then
    select * into v_reservation
    from public.upload_reservations
    where upload_reservation_id = v_change.upload_reservation_id
    for update;

    if found then
      update public.upload_reservations
      set status_code = 'CANCELLED'
      where upload_reservation_id = v_reservation.upload_reservation_id
        and status_code not in ('FINALIZED', 'CANCELLED');

      insert into public.storage_cleanup_queue (
        source_type,
        source_parent_id,
        source_upload_reservation_id,
        bucket_name,
        object_path,
        reason_code,
        status_code
      ) values (
        'CANDIDATE_FORM',
        p_session_id,
        v_reservation.upload_reservation_id,
        v_reservation.temp_bucket,
        v_reservation.temp_path,
        'DOCUMENT_CHANGE_CANCELLED',
        'PENDING'
      ) on conflict (bucket_name, object_path) do nothing;
    end if;
  end if;

  update public.candidate_form_document_changes
  set status_code = 'CANCELLED'
  where candidate_form_document_change_id = p_change_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_form_session_id', p_session_id,
      'candidate_form_document_change_id', p_change_id,
      'status_code', 'CANCELLED'
    )
  );
end;
$$;

revoke all on function public.cancel_candidate_form_document_change(uuid, uuid) from public, anon;
grant execute on function public.cancel_candidate_form_document_change(uuid, uuid) to authenticated;
