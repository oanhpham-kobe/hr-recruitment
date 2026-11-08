-- App Tuyển dụng EIU — Candidate Form Session Lifecycle & Privacy Notice Pinning Commands
-- Slice 02 / TASK-S02-002: start_candidate_form_session, cancel_candidate_form_session, and transition guards
-- Source authority:
--   recruitment_webapp/review_pack/37_BACKEND_COMMAND_CONTRACTS.md (§2 Core error codes, §3 start_candidate_form_session, cancel_candidate_form_session, authoritative lifecycle)
--   recruitment_webapp/review_pack/40_DATABASE_INVARIANTS.md (§Candidate Form Session invariants, §Privacy notice pinning invariants)
--   recruitment_webapp/review_pack/39_SECURITY_RLS_MATRIX.md
--   recruitment_webapp/review_pack/59_RLS_POLICY_BLUEPRINT.md

-- -----------------------------------------------------------------------------
-- 1. Candidate Form Session Transition Guard
-- -----------------------------------------------------------------------------
create or replace function private.validate_candidate_form_session_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status_code is distinct from new.status_code then
    if old.status_code <> 'OPEN' or new.status_code not in ('SUBMITTED','CANCELLED','EXPIRED') then
      raise exception 'CANDIDATE_FORM_SESSION_INVALID_TRANSITION' using errcode = '23514';
    end if;
    new.updated_at := transaction_timestamp();
  end if;
  return new;
end;
$$;

revoke all on function private.validate_candidate_form_session_transition() from public, anon, authenticated;
grant execute on function private.validate_candidate_form_session_transition() to postgres, service_role;

drop trigger if exists candidate_form_session_transition_guard on public.candidate_form_sessions;
create trigger candidate_form_session_transition_guard
  before update of status_code on public.candidate_form_sessions
  for each row execute function private.validate_candidate_form_session_transition();

-- -----------------------------------------------------------------------------
-- 2. start_candidate_form_session
-- -----------------------------------------------------------------------------
create or replace function public.start_candidate_form_session(
  p_mode text,
  p_submission_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_cand record;
  v_notice_version text;
  v_submission record;
  v_target_submission_id uuid := null;
  v_base_submission_version_no bigint := null;
  v_session record;
begin
  -- 1. Authentication
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Candidate authentication required'
    );
  end if;

  select * into v_cand
  from public.candidates
  where auth_user_id = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Candidate authentication required'
    );
  end if;

  if not v_cand.is_active then
    return jsonb_build_object(
      'success', false,
      'error_code', 'USER_INACTIVE',
      'message', 'Candidate account is inactive'
    );
  end if;

  -- 2. Privacy Notice Pinning
  select notice_version into v_notice_version
  from public.privacy_notice_versions
  where is_current = true
    and effective_from <= now();

  if not found or v_notice_version is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'PRIVACY_NOTICE_UNAVAILABLE',
      'message', 'No active privacy notice is available'
    );
  end if;

  -- 3. Mode Validation
  if p_mode = 'NEW_SUBMISSION' then
    if p_submission_id is not null then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'p_submission_id must be null for NEW_SUBMISSION'
      );
    end if;
    v_target_submission_id := null;
    v_base_submission_version_no := null;

  elsif p_mode = 'EDIT_SUBMISSION' then
    if p_submission_id is null then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'p_submission_id is required for EDIT_SUBMISSION'
      );
    end if;

    select * into v_submission
    from public.submissions
    where submission_id = p_submission_id
      and candidate_id = v_cand.candidate_id;

    if not found then
      return jsonb_build_object(
        'success', false,
        'error_code', 'NOT_FOUND',
        'message', 'Submission not found'
      );
    end if;

    if v_submission.status_code <> 'NEW' then
      return jsonb_build_object(
        'success', false,
        'error_code', 'INVALID_STATE',
        'message', 'Only submissions with status NEW can be edited'
      );
    end if;

    v_target_submission_id := p_submission_id;
    v_base_submission_version_no := v_submission.version_no;

  else
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Invalid form session mode'
    );
  end if;

  -- 4. Session Creation
  insert into public.candidate_form_sessions (
    candidate_id,
    mode_code,
    target_submission_id,
    base_submission_version_no,
    presented_privacy_notice_version,
    status_code,
    expires_at
  ) values (
    v_cand.candidate_id,
    p_mode,
    v_target_submission_id,
    v_base_submission_version_no,
    v_notice_version,
    'OPEN',
    now() + interval '4 hours'
  )
  returning * into v_session;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_form_session_id', v_session.candidate_form_session_id,
      'mode_code', v_session.mode_code,
      'presented_privacy_notice_version', v_session.presented_privacy_notice_version,
      'status_code', v_session.status_code,
      'expires_at', v_session.expires_at
    )
  );
end;
$$;

revoke all on function public.start_candidate_form_session(text, uuid) from public, anon;
grant execute on function public.start_candidate_form_session(text, uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. cancel_candidate_form_session
-- -----------------------------------------------------------------------------
create or replace function public.cancel_candidate_form_session(
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
begin
  -- 1. Authentication & Ownership
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Candidate authentication required'
    );
  end if;

  select * into v_cand
  from public.candidates
  where auth_user_id = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Candidate authentication required'
    );
  end if;

  if not v_cand.is_active then
    return jsonb_build_object(
      'success', false,
      'error_code', 'USER_INACTIVE',
      'message', 'Candidate account is inactive'
    );
  end if;

  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_session_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Form session not found'
    );
  end if;

  -- 2. Terminal State Check
  if v_session.status_code in ('SUBMITTED', 'CANCELLED', 'EXPIRED') then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_STATE',
      'message', 'Session is in terminal state and cannot be cancelled'
    );
  end if;

  -- 3. Wall-Clock Expiry Check
  if v_session.expires_at <= now() then
    update public.candidate_form_sessions
    set status_code = 'EXPIRED',
        updated_at = now()
    where candidate_form_session_id = p_session_id;

    return jsonb_build_object(
      'success', false,
      'error_code', 'FORM_SESSION_EXPIRED',
      'message', 'Form session has expired'
    );
  end if;

  -- 4. Cancellation & Cleanup
  update public.candidate_form_sessions
  set status_code = 'CANCELLED',
      updated_at = now()
  where candidate_form_session_id = p_session_id;

  update public.upload_reservations
  set status_code = 'CANCELLED'
  where candidate_form_session_id = p_session_id
    and status_code not in ('FINALIZED', 'CANCELLED');

  update public.candidate_form_document_changes
  set status_code = 'CANCELLED'
  where candidate_form_session_id = p_session_id
    and status_code = 'PENDING';

  insert into public.storage_cleanup_queue (
    source_type,
    source_parent_id,
    source_upload_reservation_id,
    bucket_name,
    object_path,
    reason_code,
    status_code
  )
  select
    'CANDIDATE_FORM',
    p_session_id,
    r.upload_reservation_id,
    r.temp_bucket,
    r.temp_path,
    'SESSION_CANCELLED',
    'PENDING'
  from public.upload_reservations r
  where r.candidate_form_session_id = p_session_id
  on conflict (bucket_name, object_path) do nothing;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_form_session_id', p_session_id,
      'status_code', 'CANCELLED'
    )
  );
end;
$$;

revoke all on function public.cancel_candidate_form_session(uuid) from public, anon;
grant execute on function public.cancel_candidate_form_session(uuid) to authenticated, postgres, service_role;
