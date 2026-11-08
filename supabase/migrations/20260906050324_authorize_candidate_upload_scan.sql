-- Authorize a candidate-owned reservation before service-role inspection.
create function public.authorize_candidate_upload_scan(
  p_candidate_form_session_id uuid,
  p_upload_reservation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_candidate_id uuid;
  v_session record;
  v_submission record;
  v_reservation record;
begin
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  select candidate_id into v_candidate_id
  from public.candidates
  where auth_user_id = v_auth_uid
    and is_active = true;

  if v_candidate_id is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_candidate_form_session_id
    and candidate_id = v_candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate form session not found or access denied');
  end if;

  if v_session.status_code <> 'OPEN' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Candidate form session is not open');
  end if;

  if v_session.expires_at <= clock_timestamp() then
    return jsonb_build_object('success', false, 'error_code', 'FORM_SESSION_EXPIRED', 'message', 'Candidate form session has expired');
  end if;

  if v_session.mode_code = 'EDIT_SUBMISSION' then
    select * into v_submission
    from public.submissions
    where submission_id = v_session.target_submission_id
      and candidate_id = v_candidate_id
    for update;

    if not found or v_submission.status_code <> 'NEW' then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Target submission is no longer in editable NEW status');
    end if;
  end if;

  select * into v_reservation
  from public.upload_reservations
  where upload_reservation_id = p_upload_reservation_id
    and candidate_form_session_id = p_candidate_form_session_id
    and actor_auth_user_id = v_auth_uid
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Upload reservation not found or access denied');
  end if;

  if v_reservation.status_code <> 'RESERVED' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Upload reservation is not in reserved status');
  end if;

  if v_reservation.expires_at <= clock_timestamp() then
    return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'Upload reservation has expired');
  end if;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_form_session_id', p_candidate_form_session_id,
      'upload_reservation_id', p_upload_reservation_id
    )
  );
end;
$$;

revoke all on function public.authorize_candidate_upload_scan(uuid, uuid) from public, anon;
grant execute on function public.authorize_candidate_upload_scan(uuid, uuid) to authenticated;