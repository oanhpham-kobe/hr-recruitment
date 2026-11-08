-- Migration: 20260905080000_storage_reservation_and_upload_protocol.sql
-- TASK-S02-003: Private Storage reservation and upload signing protocol

-- -----------------------------------------------------------------------------
-- 1. Schema Enhancements
-- -----------------------------------------------------------------------------

-- Track cryptographic expiration timestamp of issued signed upload URL token (~2 hours)
alter table public.upload_reservations
  add column if not exists signed_upload_expires_at timestamptz;

create index if not exists upload_reservations_signed_expires_idx
  on public.upload_reservations(signed_upload_expires_at)
  where signed_upload_expires_at is not null;

-- Add not_before and leased_until for deferred cleanup and safe worker claims
alter table public.storage_cleanup_queue
  add column if not exists not_before timestamptz not null default now(),
  add column if not exists leased_until timestamptz;

create index if not exists storage_cleanup_queue_claim_idx
  on public.storage_cleanup_queue(not_before, leased_until)
  where status_code in ('PENDING', 'PROCESSING');

-- -----------------------------------------------------------------------------
-- 2. Storage Defense-in-Depth RLS Policies
-- Note: Per 49_TECHNICAL_REVIEW_VERCEL_SUPABASE.md:116, storage.buckets is configured
-- declaratively in config.toml and/or Storage API; SQL defines storage.objects policies.
-- -----------------------------------------------------------------------------

drop policy if exists candidate_quarantine_select on storage.objects;
create policy candidate_quarantine_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'candidate-quarantine'
    and private.is_root_admin()
  );

drop policy if exists candidate_quarantine_insert on storage.objects;
create policy candidate_quarantine_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'candidate-quarantine'
    and exists (
      select 1 from public.upload_reservations r
      join public.candidate_form_sessions fs on fs.candidate_form_session_id = r.candidate_form_session_id
      left join public.submissions s on s.submission_id = fs.target_submission_id
      where r.temp_bucket = 'candidate-quarantine'
        and r.temp_path = storage.objects.name
        and r.actor_auth_user_id = (select auth.uid())
        and r.status_code = 'RESERVED'
        and r.expires_at > clock_timestamp()
        and fs.status_code = 'OPEN'
        and fs.expires_at > clock_timestamp()
        and (
          fs.mode_code <> 'EDIT_SUBMISSION'
          or (s.submission_id is not null and s.status_code = 'NEW' and s.candidate_id = fs.candidate_id)
        )
    )
  );

-- No UPDATE or DELETE policies on storage.objects for authenticated role
-- strictly prevents client overwrites (upsert) and client-driven deletion.

-- -----------------------------------------------------------------------------
-- 3. reserve_candidate_form_upload
-- -----------------------------------------------------------------------------
create or replace function public.reserve_candidate_form_upload(
  p_candidate_form_session_id uuid,
  p_intended_document_type_id uuid,
  p_original_filename text,
  p_declared_mime_type text default null,
  p_expected_max_size_bytes bigint default 5242880,
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
  v_existing record;
  v_session record;
  v_submission record;
  v_doc_type record;
  v_filename text;
  v_ext text;
  v_reservation_id uuid;
  v_temp_bucket text := 'candidate-quarantine';
  v_temp_path text;
  v_expires_at timestamptz;
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

  -- 2. Idempotency Check
  select * into v_existing
  from public.upload_reservations
  where actor_auth_user_id = v_auth_uid
    and idempotency_key = p_idempotency_key;

  if found then
    return jsonb_build_object(
      'success', true,
      'data', jsonb_build_object(
        'upload_reservation_id', v_existing.upload_reservation_id,
        'candidate_form_session_id', v_existing.candidate_form_session_id,
        'intended_document_type_id', v_existing.intended_document_type_id,
        'temp_bucket', v_existing.temp_bucket,
        'temp_path', v_existing.temp_path,
        'original_filename', v_existing.original_filename,
        'declared_mime_type', v_existing.declared_mime_type,
        'expected_max_size_bytes', v_existing.expected_max_size_bytes,
        'status_code', v_existing.status_code,
        'expires_at', v_existing.expires_at
      )
    );
  end if;

  -- 3. Deterministic Lock Hierarchy: Lock 1 - candidate_form_sessions
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

  -- 4. Deterministic Lock Hierarchy: Lock 2 - target submission if EDIT_SUBMISSION
  if v_session.mode_code = 'EDIT_SUBMISSION' then
    select * into v_submission
    from public.submissions
    where submission_id = v_session.target_submission_id
      and candidate_id = v_cand.candidate_id
    for update;

    if not found or v_submission.status_code <> 'NEW' then
      return jsonb_build_object(
        'success', false,
        'error_code', 'INVALID_STATE',
        'message', 'Target submission is no longer in editable NEW status'
      );
    end if;
  end if;

  -- 5. Document Type Validation
  select * into v_doc_type
  from public.document_types
  where document_type_id = p_intended_document_type_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Document type not found'
    );
  end if;

  if v_doc_type.scope_code not in ('SUBMISSION', 'BOTH') then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_DOCUMENT_TYPE',
      'message', 'Document type not permitted for submissions'
    );
  end if;

  if v_session.mode_code = 'NEW_SUBMISSION' and not v_doc_type.is_active then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INACTIVE_DOCUMENT_TYPE',
      'message', 'Inactive document type cannot be added to a new submission'
    );
  end if;

  -- 6. Filename, Extension & Size Validation
  v_filename := btrim(p_original_filename);
  if v_filename is null or v_filename = '' or char_length(v_filename) > 255 then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Original filename must be between 1 and 255 characters'
    );
  end if;

  -- Extract extension
  v_ext := lower(substring(v_filename from '\.([^\.]+)$'));
  if v_ext is null or v_ext not in ('pdf', 'doc', 'docx', 'ppt', 'pptx', 'png', 'jpg', 'jpeg') then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_FILE_TYPE',
      'message', 'File format is not allowed. Approved formats: PDF, DOC, DOCX, PPT, PPTX, PNG, JPG, JPEG'
    );
  end if;

  if p_expected_max_size_bytes is null or p_expected_max_size_bytes <= 0 or p_expected_max_size_bytes > 5242880 then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FILE_SIZE_EXCEEDED',
      'message', 'Expected file size limit is 5 MB'
    );
  end if;

  -- 7. Reservation Insertion
  v_reservation_id := gen_random_uuid();
  v_temp_path := format('temp/%s/%s/%s', p_candidate_form_session_id, v_reservation_id, regexp_replace(v_filename, '[^a-zA-Z0-9._-]', '_', 'g'));
  v_expires_at := least(clock_timestamp() + interval '30 minutes', v_session.expires_at);

  insert into public.upload_reservations (
    upload_reservation_id,
    candidate_form_session_id,
    intended_document_type_id,
    temp_bucket,
    temp_path,
    original_filename,
    declared_mime_type,
    expected_max_size_bytes,
    malware_scan_status,
    status_code,
    actor_auth_user_id,
    idempotency_key,
    created_at,
    expires_at
  ) values (
    v_reservation_id,
    p_candidate_form_session_id,
    p_intended_document_type_id,
    v_temp_bucket,
    v_temp_path,
    v_filename,
    p_declared_mime_type,
    p_expected_max_size_bytes,
    'PENDING',
    'RESERVED',
    v_auth_uid,
    p_idempotency_key,
    clock_timestamp(),
    v_expires_at
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'upload_reservation_id', v_reservation_id,
      'candidate_form_session_id', p_candidate_form_session_id,
      'intended_document_type_id', p_intended_document_type_id,
      'temp_bucket', v_temp_bucket,
      'temp_path', v_temp_path,
      'original_filename', v_filename,
      'declared_mime_type', p_declared_mime_type,
      'expected_max_size_bytes', p_expected_max_size_bytes,
      'status_code', 'RESERVED',
      'expires_at', v_expires_at
    )
  );
end;
$$;

revoke all on function public.reserve_candidate_form_upload from public, anon;
grant execute on function public.reserve_candidate_form_upload to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 4. prepare_signed_upload
-- Pre-call durable token expiry registration with deterministic lock hierarchy
-- -----------------------------------------------------------------------------
create or replace function public.prepare_signed_upload(
  p_upload_reservation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_cand record;
  v_session_id uuid;
  v_session record;
  v_submission record;
  v_res record;
  v_signed_expires_at timestamptz;
begin
  -- 1. Authentication
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

  -- 2. Peek session ID from reservation
  select candidate_form_session_id into v_session_id
  from public.upload_reservations
  where upload_reservation_id = p_upload_reservation_id;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Upload reservation not found');
  end if;

  -- 3. Lock 1: candidate_form_sessions
  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = v_session_id
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

  -- 4. Lock 2: target submission if EDIT_SUBMISSION
  if v_session.mode_code = 'EDIT_SUBMISSION' then
    select * into v_submission
    from public.submissions
    where submission_id = v_session.target_submission_id
      and candidate_id = v_cand.candidate_id
    for update;

    if not found or v_submission.status_code <> 'NEW' then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Target submission is no longer in editable NEW status');
    end if;
  end if;

  -- 5. Lock 3: upload_reservations
  select * into v_res
  from public.upload_reservations
  where upload_reservation_id = p_upload_reservation_id
    and actor_auth_user_id = v_auth_uid
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Upload reservation not found');
  end if;

  if v_res.status_code <> 'RESERVED' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Upload reservation is not in reserved status');
  end if;

  if v_res.expires_at <= clock_timestamp() then
    return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'Upload reservation has expired');
  end if;

  -- 6. Durable Pre-Storage Registration with Latency Buffer (2h 5m)
  v_signed_expires_at := clock_timestamp() + interval '2 hours 5 minutes';

  update public.upload_reservations
  set signed_upload_expires_at = v_signed_expires_at
  where upload_reservation_id = p_upload_reservation_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'upload_reservation_id', v_res.upload_reservation_id,
      'temp_bucket', v_res.temp_bucket,
      'temp_path', v_res.temp_path,
      'expires_at', v_res.expires_at,
      'signed_upload_expires_at', v_signed_expires_at
    )
  );
end;
$$;

revoke all on function public.prepare_signed_upload from public, anon;
grant execute on function public.prepare_signed_upload to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 5. record_candidate_upload_completed
-- Candidate upload completion notification (leaves malware_scan_status = 'PENDING')
-- -----------------------------------------------------------------------------
create or replace function public.record_candidate_upload_completed(
  p_upload_reservation_id uuid,
  p_actual_size_bytes bigint,
  p_checksum_sha256 text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_cand record;
  v_session_id uuid;
  v_session record;
  v_submission record;
  v_res record;
begin
  -- 1. Authentication
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

  -- 2. Peek session ID
  select candidate_form_session_id into v_session_id
  from public.upload_reservations
  where upload_reservation_id = p_upload_reservation_id;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Upload reservation not found');
  end if;

  -- 3. Lock 1: candidate_form_sessions
  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = v_session_id
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

  -- 4. Lock 2: target submission if EDIT_SUBMISSION
  if v_session.mode_code = 'EDIT_SUBMISSION' then
    select * into v_submission
    from public.submissions
    where submission_id = v_session.target_submission_id
      and candidate_id = v_cand.candidate_id
    for update;

    if not found or v_submission.status_code <> 'NEW' then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Target submission is no longer in editable NEW status');
    end if;
  end if;

  -- 5. Lock 3: upload_reservations
  select * into v_res
  from public.upload_reservations
  where upload_reservation_id = p_upload_reservation_id
    and actor_auth_user_id = v_auth_uid
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Upload reservation not found');
  end if;

  if v_res.status_code <> 'RESERVED' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Upload reservation is not in reserved status');
  end if;

  if v_res.expires_at <= clock_timestamp() then
    return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'Upload reservation has expired');
  end if;

  if p_actual_size_bytes is null or p_actual_size_bytes <= 0 or p_actual_size_bytes > v_res.expected_max_size_bytes or p_actual_size_bytes > 5242880 then
    return jsonb_build_object('success', false, 'error_code', 'FILE_SIZE_EXCEEDED', 'message', 'Uploaded file size exceeds reservation limit');
  end if;

  -- 6. Update reservation to UPLOADED with malware_scan_status strictly PENDING
  update public.upload_reservations
  set
    status_code = 'UPLOADED',
    actual_size_bytes = p_actual_size_bytes,
    checksum_sha256 = coalesce(p_checksum_sha256, checksum_sha256)
  where upload_reservation_id = p_upload_reservation_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'upload_reservation_id', p_upload_reservation_id,
      'status_code', 'UPLOADED',
      'malware_scan_status', 'PENDING'
    )
  );
end;
$$;

revoke all on function public.record_candidate_upload_completed from public, anon;
grant execute on function public.record_candidate_upload_completed to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 6. validate_and_scan_upload_reservation
-- Trusted Worker Scan & Validation Procedure (ROUTED VIA public, WORKER-ONLY GRANTS)
-- -----------------------------------------------------------------------------
create or replace function public.validate_and_scan_upload_reservation(
  p_upload_reservation_id uuid,
  p_detected_mime_type text,
  p_actual_size_bytes bigint,
  p_malware_scan_status text,
  p_magic_bytes_verified boolean,
  p_checksum_sha256 text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res record;
  v_ext text;
  v_new_status text;
  v_not_before timestamptz;
begin
  -- 1. Explicit Parameter Validation (NO defaults)
  if p_malware_scan_status is null or p_malware_scan_status not in ('CLEAN', 'INFECTED', 'ERROR') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Explicit malware scan status (CLEAN, INFECTED, ERROR) is required');
  end if;

  if p_detected_mime_type is null or btrim(p_detected_mime_type) = '' then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Detected MIME type is required');
  end if;

  if p_actual_size_bytes is null or p_actual_size_bytes <= 0 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Actual size must be positive');
  end if;

  -- 2. Lock reservation
  select * into v_res
  from public.upload_reservations
  where upload_reservation_id = p_upload_reservation_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Upload reservation not found');
  end if;

  if v_res.status_code not in ('RESERVED', 'UPLOADED') then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Reservation is not in a scannable status');
  end if;

  -- Size check against reservation expected max and 5 MB
  if p_actual_size_bytes > v_res.expected_max_size_bytes or p_actual_size_bytes > 5242880 then
    return jsonb_build_object('success', false, 'error_code', 'FILE_SIZE_EXCEEDED', 'message', 'Actual size exceeds reservation max allowed bytes');
  end if;

  -- 3. Extension & MIME Whitelist Verification
  v_ext := lower(substring(v_res.original_filename from '\.([^\.]+)$'));
  if v_ext = 'pdf' and lower(p_detected_mime_type) <> 'application/pdf' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Detected MIME type does not match PDF');
  elsif v_ext = 'doc' and lower(p_detected_mime_type) <> 'application/msword' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Detected MIME type does not match DOC');
  elsif v_ext = 'docx' and lower(p_detected_mime_type) <> 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Detected MIME type does not match DOCX');
  elsif v_ext = 'ppt' and lower(p_detected_mime_type) <> 'application/vnd.ms-powerpoint' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Detected MIME type does not match PPT');
  elsif v_ext = 'pptx' and lower(p_detected_mime_type) <> 'application/vnd.openxmlformats-officedocument.presentationml.presentation' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Detected MIME type does not match PPTX');
  elsif v_ext = 'png' and lower(p_detected_mime_type) <> 'image/png' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Detected MIME type does not match PNG');
  elsif v_ext in ('jpg', 'jpeg') and lower(p_detected_mime_type) <> 'image/jpeg' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Detected MIME type does not match JPEG');
  end if;

  -- Check declared MIME compatibility if provided
  if v_res.declared_mime_type is not null and lower(v_res.declared_mime_type) not in (
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'image/png',
    'image/jpeg'
  ) then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_MIME_TYPE', 'message', 'Declared MIME type is unapproved');
  end if;

  -- 4. Magic Bytes Verification
  if not coalesce(p_magic_bytes_verified, false) then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_CONTENT_SIGNATURE', 'message', 'File magic bytes do not match expected signature');
  end if;

  -- 5. Status Transition
  if p_malware_scan_status = 'CLEAN' then
    v_new_status := 'VALIDATED';
    update public.upload_reservations
    set
      status_code = v_new_status,
      detected_mime_type = p_detected_mime_type,
      actual_size_bytes = p_actual_size_bytes,
      checksum_sha256 = coalesce(p_checksum_sha256, checksum_sha256),
      malware_scan_status = 'CLEAN'
    where upload_reservation_id = p_upload_reservation_id;
  else
    v_new_status := 'REJECTED';
    update public.upload_reservations
    set
      status_code = v_new_status,
      malware_scan_status = p_malware_scan_status,
      actual_size_bytes = p_actual_size_bytes,
      detected_mime_type = p_detected_mime_type
    where upload_reservation_id = p_upload_reservation_id;

    -- Enqueue deferred cleanup
    v_not_before := greatest(v_res.expires_at, coalesce(v_res.signed_upload_expires_at, v_res.expires_at));
    insert into public.storage_cleanup_queue (
      source_type,
      source_parent_id,
      source_upload_reservation_id,
      bucket_name,
      object_path,
      reason_code,
      status_code,
      not_before
    ) values (
      'CANDIDATE_FORM',
      v_res.candidate_form_session_id,
      v_res.upload_reservation_id,
      v_res.temp_bucket,
      v_res.temp_path,
      'MALWARE_REJECTED',
      'PENDING',
      v_not_before
    )
    on conflict (bucket_name, object_path) do update set
      not_before = greatest(storage_cleanup_queue.not_before, excluded.not_before);
  end if;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'upload_reservation_id', p_upload_reservation_id,
      'status_code', v_new_status,
      'malware_scan_status', p_malware_scan_status
    )
  );
end;
$$;

revoke all on function public.validate_and_scan_upload_reservation from public, anon, authenticated;
grant execute on function public.validate_and_scan_upload_reservation to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 7. stage_candidate_document_change
-- Records ADD/REPLACE/DELETE with deterministic lock hierarchy
-- -----------------------------------------------------------------------------
create or replace function public.stage_candidate_document_change(
  p_candidate_form_session_id uuid,
  p_action_code text,
  p_intended_document_type_id uuid,
  p_upload_reservation_id uuid default null,
  p_target_logical_document_id uuid default null
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
  v_submission record;
  v_res record;
  v_current_version_count integer;
  v_logical record;
  v_change_id uuid;
begin
  -- 1. Authentication
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

  -- 2. Lock 1: candidate_form_sessions
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

  -- 3. Lock 2: target submission if EDIT_SUBMISSION
  if v_session.mode_code = 'EDIT_SUBMISSION' then
    select * into v_submission
    from public.submissions
    where submission_id = v_session.target_submission_id
      and candidate_id = v_cand.candidate_id
    for update;

    if not found or v_submission.status_code <> 'NEW' then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Target submission is no longer in editable NEW status');
    end if;
  end if;

  -- 4. Action code guards
  if p_action_code not in ('ADD', 'REPLACE', 'DELETE') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Action code must be ADD, REPLACE, or DELETE');
  end if;

  if v_session.mode_code = 'NEW_SUBMISSION' and p_action_code <> 'ADD' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_ACTION', 'message', 'New submission form only supports staged ADD document actions');
  end if;

  if p_action_code = 'ADD' then
    if p_upload_reservation_id is null then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'ADD action requires an upload reservation');
    end if;
    if p_target_logical_document_id is not null then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'ADD action cannot specify a target logical document');
    end if;
  elsif p_action_code = 'REPLACE' then
    if p_upload_reservation_id is null or p_target_logical_document_id is null then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'REPLACE action requires both upload reservation and target logical document');
    end if;
  elsif p_action_code = 'DELETE' then
    if p_upload_reservation_id is not null then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'DELETE action cannot specify an upload reservation');
    end if;
    if p_target_logical_document_id is null then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'DELETE action requires a target logical document');
    end if;
  end if;

  -- Target logical document validation for REPLACE and DELETE
  if p_target_logical_document_id is not null then
    select * into v_logical
    from public.submission_document_logicals
    where logical_document_id = p_target_logical_document_id
      and submission_id = v_session.target_submission_id;

    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Target logical document not found in target submission');
    end if;

    if v_logical.document_type_id <> p_intended_document_type_id then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Replace/delete document type must match logical header type');
    end if;

    select count(*) into v_current_version_count
    from public.submission_documents
    where logical_document_id = p_target_logical_document_id
      and is_current = true;

    if v_current_version_count <> 1 then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_DOCUMENT_TARGET', 'message', 'Target logical document must have exactly one current version');
    end if;
  end if;

  -- 5. Lock 3: upload_reservations if provided
  if p_upload_reservation_id is not null then
    select * into v_res
    from public.upload_reservations
    where upload_reservation_id = p_upload_reservation_id
      and candidate_form_session_id = p_candidate_form_session_id
    for update;

    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Upload reservation does not belong to candidate form session');
    end if;

    if v_res.intended_document_type_id <> p_intended_document_type_id then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Upload reservation document type mismatch');
    end if;

    if v_res.status_code not in ('UPLOADED', 'VALIDATED') then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Upload reservation is not in a stageable status (UPLOADED or VALIDATED)');
    end if;

    if v_res.expires_at <= clock_timestamp() then
      return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'Upload reservation has expired');
    end if;
  end if;

  -- 6. Insert into candidate_form_document_changes
  v_change_id := gen_random_uuid();
  insert into public.candidate_form_document_changes (
    candidate_form_document_change_id,
    candidate_form_session_id,
    action_code,
    intended_document_type_id,
    document_type_id,
    upload_reservation_id,
    target_logical_document_id,
    status_code,
    created_at
  ) values (
    v_change_id,
    p_candidate_form_session_id,
    p_action_code,
    p_intended_document_type_id,
    p_intended_document_type_id,
    p_upload_reservation_id,
    p_target_logical_document_id,
    'PENDING',
    clock_timestamp()
  );

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_form_document_change_id', v_change_id,
      'candidate_form_session_id', p_candidate_form_session_id,
      'action_code', p_action_code,
      'intended_document_type_id', p_intended_document_type_id,
      'upload_reservation_id', p_upload_reservation_id,
      'target_logical_document_id', p_target_logical_document_id,
      'status_code', 'PENDING'
    )
  );
end;
$$;

revoke all on function public.stage_candidate_document_change from public, anon;
grant execute on function public.stage_candidate_document_change to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 8. Update cancel_candidate_form_session with not_before deferral
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

  -- 2. Lock session row
  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_session_id
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
      'message', 'Only OPEN candidate form sessions may be cancelled'
    );
  end if;

  -- 3. Transition session status to CANCELLED
  update public.candidate_form_sessions
  set status_code = 'CANCELLED'
  where candidate_form_session_id = p_session_id;

  -- 4. Cancel pending document changes
  update public.candidate_form_document_changes
  set status_code = 'CANCELLED'
  where candidate_form_session_id = p_session_id
    and status_code = 'PENDING';

  -- 5. Cancel active upload reservations
  update public.upload_reservations
  set status_code = 'CANCELLED'
  where candidate_form_session_id = p_session_id
    and status_code not in ('FINALIZED', 'CANCELLED');

  -- 6. Enqueue temporary objects for deferred cleanup with not_before
  insert into public.storage_cleanup_queue (
    source_type,
    source_parent_id,
    source_upload_reservation_id,
    bucket_name,
    object_path,
    reason_code,
    status_code,
    not_before
  )
  select
    'CANDIDATE_FORM',
    p_session_id,
    r.upload_reservation_id,
    r.temp_bucket,
    r.temp_path,
    'SESSION_CANCELLED',
    'PENDING',
    greatest(r.expires_at, coalesce(r.signed_upload_expires_at, r.expires_at))
  from public.upload_reservations r
  where r.candidate_form_session_id = p_session_id
  on conflict (bucket_name, object_path) do update set
    not_before = greatest(storage_cleanup_queue.not_before, excluded.not_before);

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_form_session_id', p_session_id,
      'status_code', 'CANCELLED'
    )
  );
end;
$$;

revoke all on function public.cancel_candidate_form_session from public, anon;
grant execute on function public.cancel_candidate_form_session to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 9. Atomic Exclusive Worker Cleanup Claim & Completion RPCs
-- -----------------------------------------------------------------------------
create or replace function public.claim_due_storage_cleanup_jobs(
  p_limit integer default 10,
  p_lease_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claimed jsonb;
begin
  with due_rows as (
    select storage_cleanup_id
    from public.storage_cleanup_queue
    where (
      (status_code = 'PENDING' and not_before <= clock_timestamp())
      or (status_code = 'PROCESSING' and leased_until <= clock_timestamp() and attempts < 5)
    )
    order by not_before asc
    limit greatest(1, least(p_limit, 100))
    for update skip locked
  ),
  updated_rows as (
    update public.storage_cleanup_queue q
    set
      status_code = 'PROCESSING',
      leased_until = clock_timestamp() + (greatest(30, least(p_lease_seconds, 3600)) || ' seconds')::interval,
      attempts = q.attempts + 1,
      updated_at = clock_timestamp()
    from due_rows d
    where q.storage_cleanup_id = d.storage_cleanup_id
    returning
      q.storage_cleanup_id,
      q.source_type,
      q.bucket_name,
      q.object_path,
      q.reason_code,
      q.attempts,
      q.not_before,
      q.leased_until
  )
  select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb)
  into v_claimed
  from updated_rows u;

  return jsonb_build_object(
    'success', true,
    'data', v_claimed
  );
end;
$$;

revoke all on function public.claim_due_storage_cleanup_jobs from public, anon, authenticated;
grant execute on function public.claim_due_storage_cleanup_jobs to postgres, service_role;

create or replace function public.complete_storage_cleanup_job(
  p_storage_cleanup_id uuid,
  p_success boolean,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_success then
    update public.storage_cleanup_queue
    set
      status_code = 'DONE',
      leased_until = null,
      last_error = null,
      updated_at = clock_timestamp()
    where storage_cleanup_id = p_storage_cleanup_id;
  else
    update public.storage_cleanup_queue
    set
      last_error = p_error,
      status_code = case when attempts >= 5 then 'ERROR' else 'PENDING' end,
      not_before = case when attempts < 5 then clock_timestamp() + interval '5 minutes' else not_before end,
      leased_until = null,
      updated_at = clock_timestamp()
    where storage_cleanup_id = p_storage_cleanup_id;
  end if;

  return jsonb_build_object('success', true);
end;
$$;

revoke all on function public.complete_storage_cleanup_job from public, anon, authenticated;
grant execute on function public.complete_storage_cleanup_job to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 10. Canonical Plan Validation Trigger and Function (database_schema.sql lines 799-1017)
-- -----------------------------------------------------------------------------
create or replace function private.validate_candidate_form_document_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  form_mode text;
  form_status text;
  form_expires_at timestamptz;
  target_submission uuid;
  logical_submission uuid;
  logical_type uuid;
  current_version_count integer;
  reservation_session uuid;
  reservation_type uuid;
  reservation_status text;
  reservation_expires_at timestamptz;
  doc_scope text;
  doc_active boolean;
begin
  select fs.mode_code, fs.status_code, fs.expires_at, fs.target_submission_id
    into form_mode, form_status, form_expires_at, target_submission
  from public.candidate_form_sessions fs
  where fs.candidate_form_session_id = new.candidate_form_session_id;
  if not found then raise exception 'candidate form session not found' using errcode = '23503'; end if;
  if form_status <> 'OPEN' then
    raise exception 'document changes require an OPEN candidate form session' using errcode = '23514';
  end if;
  if form_expires_at <= transaction_timestamp() then
    raise exception 'FORM_SESSION_EXPIRED' using errcode = '23514';
  end if;

  if form_mode = 'NEW_SUBMISSION' and new.action_code <> 'ADD' then
    raise exception 'new Submission form only supports staged ADD document actions' using errcode = '23514';
  end if;

  select d.scope_code, d.is_active into doc_scope, doc_active
  from public.document_types d where d.document_type_id = new.intended_document_type_id;
  if not found then raise exception 'document type not found' using errcode = '23503'; end if;
  if doc_scope not in ('SUBMISSION','BOTH') then
    raise exception 'document type is not valid for Submission documents' using errcode = '23514';
  end if;
  if new.action_code = 'ADD' and not doc_active then
    raise exception 'inactive document type cannot be selected for a new document' using errcode = '23514';
  end if;

  if new.target_logical_document_id is not null then
    select l.submission_id, l.document_type_id into logical_submission, logical_type
    from public.submission_document_logicals l where l.logical_document_id = new.target_logical_document_id;
    if not found or target_submission is null or logical_submission is distinct from target_submission then
      raise exception 'target logical document does not belong to edit Submission' using errcode = '23514';
    end if;
    if logical_type is distinct from new.intended_document_type_id then
      raise exception 'replace/delete document type must match logical header type' using errcode = '23514';
    end if;
    if new.action_code in ('REPLACE','DELETE') then
      select count(*) into current_version_count
      from public.submission_documents v
      where v.logical_document_id = new.target_logical_document_id and v.is_current = true;
      if current_version_count <> 1 then
        raise exception 'INVALID_DOCUMENT_TARGET: replace/delete requires exactly one current version' using errcode = '23514';
      end if;
    end if;
  end if;

  if new.upload_reservation_id is not null then
    select u.candidate_form_session_id, u.intended_document_type_id, u.status_code, u.expires_at
      into reservation_session, reservation_type, reservation_status, reservation_expires_at
    from public.upload_reservations u where u.upload_reservation_id = new.upload_reservation_id;
    if not found or reservation_session is distinct from new.candidate_form_session_id then
      raise exception 'upload reservation does not belong to candidate form session' using errcode = '23514';
    end if;
    if reservation_type is distinct from new.intended_document_type_id then
      raise exception 'upload reservation document type mismatch' using errcode = '23514';
    end if;
    if reservation_status not in ('UPLOADED','VALIDATED') then
      raise exception 'upload reservation is not stageable' using errcode = '23514';
    end if;
    if reservation_expires_at <= transaction_timestamp() then
      raise exception 'UPLOAD_RESERVATION_EXPIRED' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.validate_candidate_form_document_change() from public, anon, authenticated;
grant execute on function private.validate_candidate_form_document_change() to postgres, service_role;

drop trigger if exists candidate_form_document_change_guard on public.candidate_form_document_changes;
create trigger candidate_form_document_change_guard
  before insert or update on public.candidate_form_document_changes
  for each row execute function private.validate_candidate_form_document_change();

create or replace function private.validate_candidate_form_document_plan(p_candidate_form_session_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  form_mode text;
  form_status text;
  form_expires_at timestamptz;
  target_submission uuid;
  effective_count integer;
  cv_count integer;
  unready_count integer;
  expired_reservation_count integer;
  invalid_target_count integer;
begin
  select fs.mode_code, fs.status_code, fs.expires_at, fs.target_submission_id
    into form_mode, form_status, form_expires_at, target_submission
  from public.candidate_form_sessions fs
  where fs.candidate_form_session_id = p_candidate_form_session_id
  for update;
  if not found then raise exception 'candidate form session not found' using errcode = '23503'; end if;
  if form_status <> 'OPEN' then raise exception 'candidate form session is not OPEN' using errcode = '23514'; end if;
  if form_expires_at <= transaction_timestamp() then raise exception 'FORM_SESSION_EXPIRED' using errcode = '23514'; end if;

  if form_mode = 'EDIT_SUBMISSION' then
    perform 1
    from public.submission_document_logicals l
    join public.candidate_form_document_changes c on c.target_logical_document_id = l.logical_document_id
    where c.candidate_form_session_id = p_candidate_form_session_id
      and c.status_code = 'PENDING' and c.action_code in ('REPLACE','DELETE')
    for update of l;

    perform 1
    from public.submission_documents v
    join public.candidate_form_document_changes c on c.target_logical_document_id = v.logical_document_id
    where c.candidate_form_session_id = p_candidate_form_session_id
      and c.status_code = 'PENDING' and c.action_code in ('REPLACE','DELETE')
      and v.is_current = true
    for update of v;

    select count(*) into invalid_target_count
    from public.candidate_form_document_changes c
    where c.candidate_form_session_id = p_candidate_form_session_id
      and c.status_code = 'PENDING' and c.action_code in ('REPLACE','DELETE')
      and (select count(*) from public.submission_documents v
           where v.logical_document_id = c.target_logical_document_id and v.is_current = true) <> 1;
    if invalid_target_count > 0 then
      raise exception 'INVALID_DOCUMENT_TARGET' using errcode = '23514';
    end if;
  end if;

  select count(*) into expired_reservation_count
  from public.candidate_form_document_changes c
  join public.upload_reservations u on u.upload_reservation_id = c.upload_reservation_id
  where c.candidate_form_session_id = p_candidate_form_session_id
    and c.status_code = 'PENDING'
    and c.action_code in ('ADD','REPLACE')
    and u.expires_at <= transaction_timestamp();
  if expired_reservation_count > 0 then
    raise exception 'UPLOAD_RESERVATION_EXPIRED' using errcode = '23514';
  end if;

  select count(*) into unready_count
  from public.candidate_form_document_changes c
  join public.upload_reservations u on u.upload_reservation_id = c.upload_reservation_id
  where c.candidate_form_session_id = p_candidate_form_session_id
    and c.status_code = 'PENDING'
    and c.action_code in ('ADD','REPLACE')
    and (u.status_code <> 'VALIDATED' or u.malware_scan_status <> 'CLEAN');
  if unready_count > 0 then
    raise exception 'UPLOAD_RESERVATION_NOT_CLEAN' using errcode = '23514';
  end if;

  if form_mode = 'NEW_SUBMISSION' then
    select count(*) into effective_count
    from public.candidate_form_document_changes c
    where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING' and c.action_code = 'ADD';

    select count(*) into cv_count
    from public.candidate_form_document_changes c
    join public.document_types d on d.document_type_id = c.intended_document_type_id
    where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
      and c.action_code = 'ADD' and d.code = 'CV_RESUME';
  else
    select
      count(*)
      - count(*) filter (where exists (
          select 1 from public.candidate_form_document_changes c
          where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
            and c.action_code = 'DELETE' and c.target_logical_document_id = l.logical_document_id
        ))
      + (select count(*) from public.candidate_form_document_changes c
         where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING' and c.action_code = 'ADD')
      into effective_count
    from public.submission_document_logicals l
    where l.submission_id = target_submission;

    select count(*) into cv_count
    from (
      select l.logical_document_id
      from public.submission_document_logicals l
      join public.document_types d on d.document_type_id = l.document_type_id
      where l.submission_id = target_submission and d.code = 'CV_RESUME'
      and not exists (
        select 1 from public.candidate_form_document_changes c
        where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
          and c.action_code = 'DELETE' and c.target_logical_document_id = l.logical_document_id
      )
      union all
      select c.candidate_form_document_change_id
      from public.candidate_form_document_changes c
      join public.document_types d on d.document_type_id = c.intended_document_type_id
      where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
        and c.action_code = 'ADD' and d.code = 'CV_RESUME'
    ) effective_cvs;
  end if;

  if effective_count > 5 then
    raise exception 'MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED' using errcode = '23514';
  end if;

  if cv_count < 1 then
    raise exception 'REQUIRED_CV_DOCUMENT_MISSING' using errcode = '23514';
  end if;
end;
$$;

revoke all on function private.validate_candidate_form_document_plan(uuid) from public, anon, authenticated;
grant execute on function private.validate_candidate_form_document_plan(uuid) to postgres, service_role;
