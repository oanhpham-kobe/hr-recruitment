-- Migration: 20260905090000_candidate_submission_commands.sql
-- TASK-S02-004: Candidate Submission transactional commands (submit and update)

-- -----------------------------------------------------------------------------
-- 1. Candidate Profile Cache Helper
-- -----------------------------------------------------------------------------
create or replace function private.refresh_candidate_current_profile(p_candidate_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_phone text;
  v_submitted_at timestamptz;
begin
  perform 1
  from public.candidates c
  where c.candidate_id = p_candidate_id
  for update;

  if not found then
    raise exception 'CANDIDATE_NOT_FOUND' using errcode = '23503';
  end if;

  select s.full_name, s.phone, s.submitted_at
    into v_name, v_phone, v_submitted_at
  from public.submissions s
  where s.candidate_id = p_candidate_id
  order by s.submitted_at desc, s.submission_id desc
  limit 1;

  update public.candidates
  set
    current_full_name = v_name,
    current_phone = v_phone,
    last_submission_at = v_submitted_at
  where candidate_id = p_candidate_id;
end;
$$;

revoke all on function private.refresh_candidate_current_profile(uuid) from public, anon, authenticated;
grant execute on function private.refresh_candidate_current_profile(uuid) to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 2. submit_candidate_submission
-- -----------------------------------------------------------------------------
create or replace function public.submit_candidate_submission(
  p_candidate_form_session_id uuid,
  p_full_name text,
  p_phone text default null,
  p_date_of_birth date default null,
  p_gender text default null,
  p_address text default null,
  p_candidate_notes text default null,
  p_education jsonb default '[]'::jsonb,
  p_work_experiences jsonb default '[]'::jsonb,
  p_activities jsonb default '[]'::jsonb,
  p_privacy_notice_version text default null,
  p_idempotency_key uuid default gen_random_uuid()
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
  v_submission_id uuid;
  v_submitted_at timestamptz;
  v_item jsonb;
  v_chg record;
  v_res record;
  v_log_id uuid;
  v_current_cv_count integer;
  v_current_doc_count integer;
begin
  -- 1. Canonical Authentication & Active Verification
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

  -- 2. Deterministic Lock Sequence: Lock 1 - candidate identity
  perform 1
  from public.candidates
  where candidate_id = v_cand.candidate_id
  for update;

  -- 3. Lock 2: form session
  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_candidate_form_session_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Candidate form session not found or access denied'
    );
  end if;

  if v_session.status_code <> 'OPEN' then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_STATE',
      'message', 'Candidate form session is not open'
    );
  end if;

  if v_session.expires_at <= clock_timestamp() then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORM_SESSION_EXPIRED',
      'message', 'Candidate form session has expired'
    );
  end if;

  if v_session.mode_code <> 'NEW_SUBMISSION' then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_ACTION',
      'message', 'submit_candidate_submission requires a NEW_SUBMISSION form session'
    );
  end if;

  -- 4. Privacy Notice Pinning Verification
  if p_privacy_notice_version is null or p_privacy_notice_version <> v_session.presented_privacy_notice_version then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Acknowledged privacy notice version must match server-pinned notice version'
    );
  end if;

  -- 5. Field Validations
  if p_full_name is null or btrim(p_full_name) = '' or char_length(p_full_name) > 120 then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Full name is required and must not exceed 120 characters'
    );
  end if;

  if p_phone is not null and char_length(p_phone) > 30 then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Phone number must not exceed 30 characters'
    );
  end if;

  if p_gender is not null and p_gender not in ('MALE', 'FEMALE', 'OTHER') then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Gender must be MALE, FEMALE, or OTHER'
    );
  end if;

  if p_address is not null and char_length(p_address) > 255 then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Address must not exceed 255 characters'
    );
  end if;

  -- 6. Document Plan Pre-Materialization Validation (Lock 4: changes & reservations)
  begin
    perform private.validate_candidate_form_document_plan(p_candidate_form_session_id);
  exception
    when sqlstate '23514' then
      if sqlerrm like '%REQUIRED_CV_DOCUMENT_MISSING%' then
        return jsonb_build_object('success', false, 'error_code', 'REQUIRED_CV_DOCUMENT_MISSING', 'message', 'A valid current CV document is required');
      elsif sqlerrm like '%MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED%' then
        return jsonb_build_object('success', false, 'error_code', 'MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED', 'message', 'A submission cannot exceed 5 current documents');
      elsif sqlerrm like '%UPLOAD_RESERVATION_NOT_CLEAN%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_NOT_CLEAN', 'message', 'All uploaded documents must be validated and verified clean');
      elsif sqlerrm like '%UPLOAD_RESERVATION_EXPIRED%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'An upload reservation has expired');
      else
        return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', sqlerrm);
      end if;
  end;

  -- 7. Insert public.submissions
  v_submission_id := gen_random_uuid();
  v_submitted_at := clock_timestamp();

  insert into public.submissions (
    submission_id,
    candidate_id,
    status_code,
    full_name,
    email,
    phone,
    date_of_birth,
    gender,
    address,
    candidate_notes,
    submitted_at,
    version_no,
    created_at,
    updated_at
  ) values (
    v_submission_id,
    v_cand.candidate_id,
    'NEW',
    btrim(p_full_name),
    v_cand.email, -- Immutable verified email from candidate record
    nullif(btrim(p_phone), ''),
    p_date_of_birth,
    p_gender,
    nullif(btrim(p_address), ''),
    nullif(btrim(p_candidate_notes), ''),
    v_submitted_at,
    1,
    v_submitted_at,
    v_submitted_at
  );

  -- 8. Insert Child Snapshots
  if p_education is not null and jsonb_typeof(p_education) = 'array' then
    for v_item in select * from jsonb_array_elements(p_education) loop
      insert into public.submission_education (
        submission_id,
        institution_name,
        degree_name,
        major,
        start_year,
        end_year,
        gpa,
        sort_order
      ) values (
        v_submission_id,
        btrim(v_item->>'institution_name'),
        btrim(v_item->>'degree_name'),
        nullif(btrim(v_item->>'major'), ''),
        (v_item->>'start_year')::integer,
        (v_item->>'end_year')::integer,
        nullif(btrim(v_item->>'gpa'), ''),
        coalesce((v_item->>'sort_order')::integer, 0)
      );
    end loop;
  end if;

  if p_work_experiences is not null and jsonb_typeof(p_work_experiences) = 'array' then
    for v_item in select * from jsonb_array_elements(p_work_experiences) loop
      insert into public.submission_work_experiences (
        submission_id,
        company_name,
        position_title,
        start_date,
        end_date,
        is_current,
        description,
        sort_order
      ) values (
        v_submission_id,
        btrim(v_item->>'company_name'),
        btrim(v_item->>'position_title'),
        nullif(v_item->>'start_date', '')::date,
        nullif(v_item->>'end_date', '')::date,
        coalesce((v_item->>'is_current')::boolean, false),
        nullif(btrim(v_item->>'description'), ''),
        coalesce((v_item->>'sort_order')::integer, 0)
      );
    end loop;
  end if;

  if p_activities is not null and jsonb_typeof(p_activities) = 'array' then
    for v_item in select * from jsonb_array_elements(p_activities) loop
      insert into public.submission_activities (
        submission_id,
        activity_name,
        role_title,
        organization_name,
        start_date,
        end_date,
        description,
        sort_order
      ) values (
        v_submission_id,
        btrim(v_item->>'activity_name'),
        nullif(btrim(v_item->>'role_title'), ''),
        nullif(btrim(v_item->>'organization_name'), ''),
        nullif(v_item->>'start_date', '')::date,
        nullif(v_item->>'end_date', '')::date,
        nullif(btrim(v_item->>'description'), ''),
        coalesce((v_item->>'sort_order')::integer, 0)
      );
    end loop;
  end if;

  -- 9. Materialize Staged Document Changes
  for v_chg in
    select *
    from public.candidate_form_document_changes
    where candidate_form_session_id = p_candidate_form_session_id
      and status_code = 'PENDING'
    for update
  loop
    -- Lock reservation
    select * into v_res
    from public.upload_reservations
    where upload_reservation_id = v_chg.upload_reservation_id
    for update;

    -- Ensure logical header exists
    insert into public.submission_document_logicals (
      submission_id,
      document_type_id,
      created_at
    ) values (
      v_submission_id,
      v_chg.intended_document_type_id,
      v_submitted_at
    )
    on conflict (submission_id, document_type_id) do update
      set created_at = submission_document_logicals.created_at
    returning logical_document_id into v_log_id;

    -- Insert version 1
    insert into public.submission_documents (
      logical_document_id,
      storage_bucket,
      storage_path,
      original_filename,
      mime_type,
      file_size_bytes,
      checksum_sha256,
      version_no,
      is_current,
      uploaded_by,
      uploaded_at
    ) values (
      v_log_id,
      v_res.temp_bucket,
      v_res.temp_path,
      v_res.original_filename,
      coalesce(v_res.detected_mime_type, v_res.declared_mime_type, 'application/octet-stream'),
      v_res.actual_size_bytes,
      v_res.checksum_sha256,
      1,
      true,
      v_auth_uid,
      v_submitted_at
    );

    -- Finalize reservation and apply change
    update public.upload_reservations
    set status_code = 'FINALIZED'
    where upload_reservation_id = v_res.upload_reservation_id;

    update public.candidate_form_document_changes
    set status_code = 'APPLIED'
    where candidate_form_document_change_id = v_chg.candidate_form_document_change_id;
  end loop;

  -- 10. Record Privacy Acknowledgement
  insert into public.privacy_acknowledgements (
    candidate_id,
    submission_id,
    submission_version_no,
    privacy_notice_version,
    acknowledged_at
  ) values (
    v_cand.candidate_id,
    v_submission_id,
    1,
    v_session.presented_privacy_notice_version,
    v_submitted_at
  );

  -- 11. Refresh Candidate Profile Cache
  perform private.refresh_candidate_current_profile(v_cand.candidate_id);

  -- 12. Enqueue Confirmation Email in Outbox
  insert into public.email_outbox (
    submission_id,
    email_type,
    environment_code,
    recipients,
    subject,
    body_text,
    status_code,
    idempotency_key,
    actor_scope,
    created_by_candidate_id
  ) values (
    v_submission_id,
    'CANDIDATE_SUBMISSION_CONFIRMATION',
    'PRODUCTION',
    jsonb_build_array(v_cand.email),
    'Application Submission Confirmation',
    'Thank you for submitting your application to Eastern International University.',
    'QUEUED',
    p_idempotency_key,
    'CANDIDATE',
    v_cand.candidate_id
  )
  on conflict (actor_scope, email_type, idempotency_key) do nothing;

  -- 13. Transition Form Session to SUBMITTED
  update public.candidate_form_sessions
  set
    status_code = 'SUBMITTED',
    updated_at = v_submitted_at
  where candidate_form_session_id = p_candidate_form_session_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', v_submission_id,
      'status_code', 'NEW',
      'version_no', 1,
      'submitted_at', v_submitted_at
    )
  );
end;
$$;

revoke all on function public.submit_candidate_submission from public, anon;
grant execute on function public.submit_candidate_submission to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. update_candidate_submission
-- -----------------------------------------------------------------------------
create or replace function public.update_candidate_submission(
  p_candidate_form_session_id uuid,
  p_full_name text,
  p_phone text default null,
  p_date_of_birth date default null,
  p_gender text default null,
  p_address text default null,
  p_candidate_notes text default null,
  p_education jsonb default '[]'::jsonb,
  p_work_experiences jsonb default '[]'::jsonb,
  p_activities jsonb default '[]'::jsonb,
  p_privacy_notice_version text default null,
  p_idempotency_key uuid default gen_random_uuid()
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
  v_sub record;
  v_new_version_no bigint;
  v_updated_at timestamptz;
  v_item jsonb;
  v_chg record;
  v_res record;
  v_log_id uuid;
  v_doc_version integer;
begin
  -- 1. Canonical Authentication & Active Verification
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  select * into v_cand from public.candidates where auth_user_id = v_auth_uid;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  if not v_cand.is_active then
    return jsonb_build_object('success', false, 'error_code', 'USER_INACTIVE', 'message', 'Candidate account is inactive');
  end if;

  -- 2. Deterministic Lock Sequence: Lock 1 - candidate identity
  perform 1
  from public.candidates
  where candidate_id = v_cand.candidate_id
  for update;

  -- 3. Lock 2: form session
  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_candidate_form_session_id
    and candidate_id = v_cand.candidate_id
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

  if v_session.mode_code <> 'EDIT_SUBMISSION' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_ACTION', 'message', 'update_candidate_submission requires an EDIT_SUBMISSION form session');
  end if;

  -- 4. Lock 3: target submission
  select * into v_sub
  from public.submissions
  where submission_id = v_session.target_submission_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Target submission not found');
  end if;

  if v_sub.status_code <> 'NEW' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Target submission is no longer in editable NEW status');
  end if;

  if v_sub.version_no <> v_session.base_submission_version_no then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Submission version has changed since session opened');
  end if;

  -- 5. Privacy Notice Verification
  if p_privacy_notice_version is null or p_privacy_notice_version <> v_session.presented_privacy_notice_version then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Acknowledged privacy notice version must match server-pinned notice version');
  end if;

  -- 6. Field Validations
  if p_full_name is null or btrim(p_full_name) = '' or char_length(p_full_name) > 120 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Full name is required and must not exceed 120 characters');
  end if;

  if p_phone is not null and char_length(p_phone) > 30 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Phone number must not exceed 30 characters');
  end if;

  if p_gender is not null and p_gender not in ('MALE', 'FEMALE', 'OTHER') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Gender must be MALE, FEMALE, or OTHER');
  end if;

  if p_address is not null and char_length(p_address) > 255 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Address must not exceed 255 characters');
  end if;

  -- 7. Document Plan Pre-Materialization Validation (Lock 4: changes & reservations)
  begin
    perform private.validate_candidate_form_document_plan(p_candidate_form_session_id);
  exception
    when sqlstate '23514' then
      if sqlerrm like '%REQUIRED_CV_DOCUMENT_MISSING%' then
        return jsonb_build_object('success', false, 'error_code', 'REQUIRED_CV_DOCUMENT_MISSING', 'message', 'A valid current CV document is required');
      elsif sqlerrm like '%MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED%' then
        return jsonb_build_object('success', false, 'error_code', 'MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED', 'message', 'A submission cannot exceed 5 current documents');
      elsif sqlerrm like '%UPLOAD_RESERVATION_NOT_CLEAN%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_NOT_CLEAN', 'message', 'All uploaded documents must be validated and verified clean');
      elsif sqlerrm like '%UPLOAD_RESERVATION_EXPIRED%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'An upload reservation has expired');
      elsif sqlerrm like '%INVALID_DOCUMENT_TARGET%' then
        return jsonb_build_object('success', false, 'error_code', 'INVALID_DOCUMENT_TARGET', 'message', 'Target logical document must have exactly one current version');
      else
        return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', sqlerrm);
      end if;
  end;

  v_new_version_no := v_sub.version_no + 1;
  v_updated_at := clock_timestamp();

  -- 8. Update public.submissions
  update public.submissions
  set
    full_name = btrim(p_full_name),
    phone = nullif(btrim(p_phone), ''),
    date_of_birth = p_date_of_birth,
    gender = p_gender,
    address = nullif(btrim(p_address), ''),
    candidate_notes = nullif(btrim(p_candidate_notes), ''),
    version_no = v_new_version_no,
    updated_at = v_updated_at
  where submission_id = v_sub.submission_id;

  -- 9. Replace Child Snapshots Atomically
  delete from public.submission_education where submission_id = v_sub.submission_id;
  if p_education is not null and jsonb_typeof(p_education) = 'array' then
    for v_item in select * from jsonb_array_elements(p_education) loop
      insert into public.submission_education (
        submission_id,
        institution_name,
        degree_name,
        major,
        start_year,
        end_year,
        gpa,
        sort_order
      ) values (
        v_sub.submission_id,
        btrim(v_item->>'institution_name'),
        btrim(v_item->>'degree_name'),
        nullif(btrim(v_item->>'major'), ''),
        (v_item->>'start_year')::integer,
        (v_item->>'end_year')::integer,
        nullif(btrim(v_item->>'gpa'), ''),
        coalesce((v_item->>'sort_order')::integer, 0)
      );
    end loop;
  end if;

  delete from public.submission_work_experiences where submission_id = v_sub.submission_id;
  if p_work_experiences is not null and jsonb_typeof(p_work_experiences) = 'array' then
    for v_item in select * from jsonb_array_elements(p_work_experiences) loop
      insert into public.submission_work_experiences (
        submission_id,
        company_name,
        position_title,
        start_date,
        end_date,
        is_current,
        description,
        sort_order
      ) values (
        v_sub.submission_id,
        btrim(v_item->>'company_name'),
        btrim(v_item->>'position_title'),
        nullif(v_item->>'start_date', '')::date,
        nullif(v_item->>'end_date', '')::date,
        coalesce((v_item->>'is_current')::boolean, false),
        nullif(btrim(v_item->>'description'), ''),
        coalesce((v_item->>'sort_order')::integer, 0)
      );
    end loop;
  end if;

  delete from public.submission_activities where submission_id = v_sub.submission_id;
  if p_activities is not null and jsonb_typeof(p_activities) = 'array' then
    for v_item in select * from jsonb_array_elements(p_activities) loop
      insert into public.submission_activities (
        submission_id,
        activity_name,
        role_title,
        organization_name,
        start_date,
        end_date,
        description,
        sort_order
      ) values (
        v_sub.submission_id,
        btrim(v_item->>'activity_name'),
        nullif(btrim(v_item->>'role_title'), ''),
        nullif(btrim(v_item->>'organization_name'), ''),
        nullif(v_item->>'start_date', '')::date,
        nullif(v_item->>'end_date', '')::date,
        nullif(btrim(v_item->>'description'), ''),
        coalesce((v_item->>'sort_order')::integer, 0)
      );
    end loop;
  end if;

  -- 10. Materialize Staged Document Changes
  for v_chg in
    select *
    from public.candidate_form_document_changes
    where candidate_form_session_id = p_candidate_form_session_id
      and status_code = 'PENDING'
    for update
  loop
    if v_chg.action_code = 'ADD' then
      -- Lock reservation
      select * into v_res
      from public.upload_reservations
      where upload_reservation_id = v_chg.upload_reservation_id
      for update;

      insert into public.submission_document_logicals (
        submission_id,
        document_type_id,
        created_at
      ) values (
        v_sub.submission_id,
        v_chg.intended_document_type_id,
        v_updated_at
      )
      on conflict (submission_id, document_type_id) do update
        set created_at = submission_document_logicals.created_at
      returning logical_document_id into v_log_id;

      select coalesce(max(version_no), 0) + 1 into v_doc_version
      from public.submission_documents
      where logical_document_id = v_log_id;

      update public.submission_documents
      set is_current = false
      where logical_document_id = v_log_id;

      insert into public.submission_documents (
        logical_document_id,
        storage_bucket,
        storage_path,
        original_filename,
        mime_type,
        file_size_bytes,
        checksum_sha256,
        version_no,
        is_current,
        uploaded_by,
        uploaded_at
      ) values (
        v_log_id,
        v_res.temp_bucket,
        v_res.temp_path,
        v_res.original_filename,
        coalesce(v_res.detected_mime_type, v_res.declared_mime_type, 'application/octet-stream'),
        v_res.actual_size_bytes,
        v_res.checksum_sha256,
        v_doc_version,
        true,
        v_auth_uid,
        v_updated_at
      );

      update public.upload_reservations
      set status_code = 'FINALIZED'
      where upload_reservation_id = v_res.upload_reservation_id;

      update public.candidate_form_document_changes
      set status_code = 'APPLIED'
      where candidate_form_document_change_id = v_chg.candidate_form_document_change_id;

    elsif v_chg.action_code = 'REPLACE' then
      select * into v_res
      from public.upload_reservations
      where upload_reservation_id = v_chg.upload_reservation_id
      for update;

      select coalesce(max(version_no), 0) + 1 into v_doc_version
      from public.submission_documents
      where logical_document_id = v_chg.target_logical_document_id;

      update public.submission_documents
      set is_current = false
      where logical_document_id = v_chg.target_logical_document_id;

      insert into public.submission_documents (
        logical_document_id,
        storage_bucket,
        storage_path,
        original_filename,
        mime_type,
        file_size_bytes,
        checksum_sha256,
        version_no,
        is_current,
        uploaded_by,
        uploaded_at
      ) values (
        v_chg.target_logical_document_id,
        v_res.temp_bucket,
        v_res.temp_path,
        v_res.original_filename,
        coalesce(v_res.detected_mime_type, v_res.declared_mime_type, 'application/octet-stream'),
        v_res.actual_size_bytes,
        v_res.checksum_sha256,
        v_doc_version,
        true,
        v_auth_uid,
        v_updated_at
      );

      update public.upload_reservations
      set status_code = 'FINALIZED'
      where upload_reservation_id = v_res.upload_reservation_id;

      update public.candidate_form_document_changes
      set status_code = 'APPLIED'
      where candidate_form_document_change_id = v_chg.candidate_form_document_change_id;

    elsif v_chg.action_code = 'DELETE' then
      update public.submission_documents
      set is_current = false
      where logical_document_id = v_chg.target_logical_document_id;

      update public.candidate_form_document_changes
      set status_code = 'APPLIED'
      where candidate_form_document_change_id = v_chg.candidate_form_document_change_id;
    end if;
  end loop;

  -- 11. Record Privacy Acknowledgement
  insert into public.privacy_acknowledgements (
    candidate_id,
    submission_id,
    submission_version_no,
    privacy_notice_version,
    acknowledged_at
  ) values (
    v_cand.candidate_id,
    v_sub.submission_id,
    v_new_version_no,
    v_session.presented_privacy_notice_version,
    v_updated_at
  )
  on conflict (submission_id, submission_version_no) do update set
    acknowledged_at = v_updated_at;

  -- 12. Refresh Profile Cache
  perform private.refresh_candidate_current_profile(v_cand.candidate_id);

  -- 13. Enqueue HR Notification Email
  insert into public.email_outbox (
    submission_id,
    email_type,
    environment_code,
    recipients,
    subject,
    body_text,
    status_code,
    idempotency_key,
    actor_scope,
    created_by_candidate_id
  ) values (
    v_sub.submission_id,
    'SUBMISSION_UPDATE_HR_NOTIFICATION',
    'PRODUCTION',
    jsonb_build_array('hr@eiu.edu.vn'),
    'Candidate Submission Updated',
    format('Candidate %s has updated Submission %s (version %s).', v_cand.email, v_sub.submission_id, v_new_version_no),
    'QUEUED',
    p_idempotency_key,
    'CANDIDATE',
    v_cand.candidate_id
  )
  on conflict (actor_scope, email_type, idempotency_key) do nothing;

  -- 14. Transition Form Session to SUBMITTED
  update public.candidate_form_sessions
  set
    status_code = 'SUBMITTED',
    updated_at = v_updated_at
  where candidate_form_session_id = p_candidate_form_session_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', v_sub.submission_id,
      'status_code', 'NEW',
      'version_no', v_new_version_no,
      'updated_at', v_updated_at
    )
  );
end;
$$;

revoke all on function public.update_candidate_submission from public, anon;
grant execute on function public.update_candidate_submission to authenticated, postgres, service_role;
