\set ON_ERROR_STOP on
begin;

-- Worker access is capability-based: no browser, service, legacy or helper bypass.
do $$
begin
  if has_function_privilege('anon', 'public.claim_storage_cleanup_jobs(text,integer,integer)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.authorize_storage_cleanup_attempt(uuid,uuid,uuid,text)', 'EXECUTE')
    or has_function_privilege('service_role', 'public.complete_storage_cleanup_attempt(uuid,uuid,uuid,text,boolean,text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'private.storage_cleanup_audit(text,uuid,text,jsonb)', 'EXECUTE')
    or to_regprocedure('public.claim_due_storage_cleanup_jobs(integer,integer)') is not null
    or to_regprocedure('public.complete_storage_cleanup_job(uuid,boolean,text)') is not null then
    raise exception 'cleanup worker privilege cutover is incomplete';
  end if;
  if not has_function_privilege('storage_cleanup_worker', 'public.claim_storage_cleanup_jobs(text,integer,integer)', 'EXECUTE')
    or not has_function_privilege('storage_cleanup_worker', 'public.authorize_storage_cleanup_attempt(uuid,uuid,uuid,text)', 'EXECUTE')
    or not has_function_privilege('storage_cleanup_worker', 'public.complete_storage_cleanup_attempt(uuid,uuid,uuid,text,boolean,text)', 'EXECUTE') then
    raise exception 'narrow cleanup worker lacks required protocol capabilities';
  end if;
end;
$$;

-- Invalid discovery bounds and worker lease/batch inputs fail closed rather than
-- silently broadening a cleanup scan or manufacturing an unbounded lease.
do $$
begin
  if public.discover_expired_storage_cleanup(null)->>'error_code' <> 'VALIDATION_ERROR'
    or public.discover_expired_storage_cleanup(0)->>'error_code' <> 'VALIDATION_ERROR'
    or public.claim_storage_cleanup_jobs('validation-worker', null, 60)->>'error_code' <> 'VALIDATION_ERROR'
    or public.claim_storage_cleanup_jobs('validation-worker', 1, null)->>'error_code' <> 'VALIDATION_ERROR'
    or public.claim_storage_cleanup_jobs('validation-worker', null, null)->>'error_code' <> 'VALIDATION_ERROR' then
    raise exception 'cleanup batch and lease parameters must reject null or invalid values';
  end if;
end;
$$;

-- Discovery is bounded, idempotent, creates durable intent, preserves terminal sessions,
-- and does not depend on an external Storage operation.
do $$
declare
  v_candidate uuid := gen_random_uuid();
  v_notice text := 's07-cleanup-' || gen_random_uuid()::text;
  v_type uuid := gen_random_uuid();
  v_open_session uuid := gen_random_uuid();
  v_terminal_session uuid := gen_random_uuid();
  v_res_1 uuid := gen_random_uuid();
  v_res_2 uuid := gen_random_uuid();
  v_res_3 uuid := gen_random_uuid();
  v_first jsonb;
  v_second jsonb;
  v_third jsonb;
begin
  insert into public.candidates(candidate_id, auth_user_id, email)
  values(v_candidate, gen_random_uuid(), 's07-' || v_candidate::text || '@example.test');
  insert into public.privacy_notice_versions(notice_version, content_vi, content_hash_sha256, is_current)
  values(v_notice, 's07 test', repeat('a', 64), false);
  insert into public.document_types(document_type_id, code, name_vi, scope_code)
  values(v_type, 'S07-' || left(v_type::text, 8), 'S07 test', 'SUBMISSION');
  insert into public.candidate_form_sessions(
    candidate_form_session_id, candidate_id, mode_code, presented_privacy_notice_version,
    status_code, expires_at
  ) values (
    v_open_session, v_candidate, 'NEW_SUBMISSION', v_notice, 'OPEN',
    clock_timestamp() - interval '1 hour'
  ), (
    v_terminal_session, v_candidate, 'NEW_SUBMISSION', v_notice, 'CANCELLED',
    clock_timestamp() - interval '1 hour'
  );
  insert into public.upload_reservations(
    upload_reservation_id, candidate_form_session_id, intended_document_type_id,
    temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key, expires_at
  ) values (
    v_res_1, v_open_session, v_type, 'candidate-quarantine',
    'temp/' || v_open_session::text || '/' || v_res_1::text || '/one.pdf',
    'one.pdf', gen_random_uuid(), gen_random_uuid(), clock_timestamp() - interval '2 hours'
  ), (
    v_res_2, v_open_session, v_type, 'candidate-quarantine',
    'temp/' || v_open_session::text || '/' || v_res_2::text || '/two.pdf',
    'two.pdf', gen_random_uuid(), gen_random_uuid(), clock_timestamp() - interval '2 hours'
  ), (
    v_res_3, v_terminal_session, v_type, 'candidate-quarantine',
    'temp/' || v_terminal_session::text || '/' || v_res_3::text || '/terminal.pdf',
    'terminal.pdf', gen_random_uuid(), gen_random_uuid(), clock_timestamp() + interval '1 hour'
  );

  v_first := public.discover_expired_storage_cleanup(1);
  if (v_first->'data'->>'captured_count')::integer <> 1 then
    raise exception 'discovery must respect the requested bound';
  end if;
  if (select status_code from public.candidate_form_sessions where candidate_form_session_id = v_open_session) <> 'EXPIRED' then
    raise exception 'only elapsed OPEN session may become EXPIRED';
  end if;
  if (select status_code from public.candidate_form_sessions where candidate_form_session_id = v_terminal_session) <> 'CANCELLED' then
    raise exception 'terminal session must not be rewritten by discovery';
  end if;
  update public.upload_reservations
  set expires_at = clock_timestamp() - interval '2 hours'
  where upload_reservation_id = v_res_3;

  v_second := public.discover_expired_storage_cleanup(10);
  if (v_second->'data'->>'captured_count')::integer <> 2 then
    raise exception 'remaining expired reservations must be discovered once';
  end if;
  v_third := public.discover_expired_storage_cleanup(10);
  if (v_third->'data'->>'captured_count')::integer <> 0
    or (select count(*) from public.storage_cleanup_queue where source_upload_reservation_id in (v_res_1, v_res_2, v_res_3)) <> 3 then
    raise exception 'discovery replay must not duplicate logical cleanup work';
  end if;
  if not exists (
    select 1 from public.security_audit_log
    where action_code = 'STORAGE_CLEANUP_EXPIRY_DISCOVERY'
      and metadata->>'captured_count' = '0'
  ) then
    raise exception 'discovery summary audit is mandatory';
  end if;
  -- Keep the following focused cases isolated from the discovered fixture work.
  update public.storage_cleanup_queue
  set status_code = 'ERROR'
  where source_upload_reservation_id in (v_res_1, v_res_2, v_res_3);
end;
$$;

-- Audit failure rolls the complete discovery transaction back, including reservation status.
do $$
declare
  v_candidate uuid := gen_random_uuid();
  v_notice text := 's07-audit-' || gen_random_uuid()::text;
  v_type uuid := gen_random_uuid();
  v_session uuid := gen_random_uuid();
  v_reservation uuid := gen_random_uuid();
  v_failed boolean := false;
begin
  insert into public.candidates(candidate_id, auth_user_id, email)
  values(v_candidate, gen_random_uuid(), 's07-audit-' || v_candidate::text || '@example.test');
  insert into public.privacy_notice_versions(notice_version, content_vi, content_hash_sha256, is_current)
  values(v_notice, 's07 audit', repeat('b', 64), false);
  insert into public.document_types(document_type_id, code, name_vi, scope_code)
  values(v_type, 'S07A-' || left(v_type::text, 8), 'S07 audit', 'SUBMISSION');
  insert into public.candidate_form_sessions(
    candidate_form_session_id, candidate_id, mode_code, presented_privacy_notice_version, expires_at
  ) values (
    v_session, v_candidate, 'NEW_SUBMISSION', v_notice, clock_timestamp() - interval '1 hour'
  );
  insert into public.upload_reservations(
    upload_reservation_id, candidate_form_session_id, intended_document_type_id,
    temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key, expires_at
  ) values (
    v_reservation, v_session, v_type, 'candidate-quarantine',
    'temp/' || v_session::text || '/' || v_reservation::text || '/rollback.pdf',
    'rollback.pdf', gen_random_uuid(), gen_random_uuid(), clock_timestamp() - interval '2 hours'
  );
  create or replace function pg_temp.fail_cleanup_discovery_audit()
  returns trigger language plpgsql as $trigger$
  begin
    if new.action_code = 'STORAGE_CLEANUP_EXPIRY_DISCOVERY' then
      raise exception 'forced audit failure';
    end if;
    return new;
  end;
  $trigger$;
  create trigger s07_fail_cleanup_discovery_audit
  before insert on public.security_audit_log
  for each row execute function pg_temp.fail_cleanup_discovery_audit();
  begin
    perform public.discover_expired_storage_cleanup(1);
  exception when others then
    v_failed := true;
  end;
  drop trigger s07_fail_cleanup_discovery_audit on public.security_audit_log;
  if not v_failed
    or (select status_code from public.upload_reservations where upload_reservation_id = v_reservation) <> 'RESERVED'
    or exists(select 1 from public.storage_cleanup_queue where source_upload_reservation_id = v_reservation) then
    raise exception 'audit failure must roll back discovery state and durable intent together';
  end if;
end;
$$;

-- Known detached identity is eligible only after every signed/reservation bound has elapsed.
do $$
declare
  v_queue uuid := gen_random_uuid();
  v_reservation uuid := gen_random_uuid();
  v_parent uuid := gen_random_uuid();
  v_path text := 'temp/' || gen_random_uuid()::text || '/' || v_reservation::text || '/eligible.pdf';
  v_claim jsonb;
  v_authorized jsonb;
  v_done jsonb;
begin
  insert into private.storage_cleanup_provenance(
    bucket_name, object_path, upload_reservation_id, source_type, source_parent_id,
    reservation_expires_at, signed_upload_expires_at, detached_at
  ) values (
    'candidate-quarantine', v_path, v_reservation, 'CANDIDATE_FORM', v_parent,
    clock_timestamp() - interval '2 hours', clock_timestamp() - interval '1 hour', clock_timestamp()
  );
  insert into public.storage_cleanup_queue(
    storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
    bucket_name, object_path, reason_code, status_code, not_before
  ) values (
    v_queue, 'CANDIDATE_FORM', v_parent, v_reservation, 'candidate-quarantine',
    v_path, 'RESERVATION_EXPIRED', 'PENDING', clock_timestamp() - interval '1 hour'
  );
  v_claim := public.claim_storage_cleanup_jobs('sql-test-worker', 1, 60);
  if jsonb_array_length(v_claim->'data') <> 1 then
    raise exception 'eligible detached identity must be claimed';
  end if;
  v_authorized := public.authorize_storage_cleanup_attempt(
    v_queue,
    (v_claim->'data'->0->>'attempt_id')::uuid,
    (v_claim->'data'->0->>'fencing_token')::uuid,
    'sql-test-worker'
  );
  if v_authorized->>'success' <> 'true'
    or (select tombstoned_at is not null from private.storage_cleanup_provenance where bucket_name = 'candidate-quarantine' and object_path = v_path) is not true then
    raise exception 'current worker/attempt/token must obtain the durable authorization tombstone';
  end if;
  v_done := public.complete_storage_cleanup_attempt(
    v_queue,
    (v_claim->'data'->0->>'attempt_id')::uuid,
    (v_claim->'data'->0->>'fencing_token')::uuid,
    'sql-test-worker',
    true,
    null
  );
  if v_done->>'success' <> 'true'
    or public.complete_storage_cleanup_attempt(
      v_queue,
      (v_claim->'data'->0->>'attempt_id')::uuid,
      (v_claim->'data'->0->>'fencing_token')::uuid,
      'sql-test-worker',
      true,
      null
    )->'data'->>'replay' <> 'true' then
    raise exception 'only same fenced successful completion may replay as DONE';
  end if;
end;
$$;

-- Tombstoning occurs only at the authorization seam: normal uploads remain possible
-- before it, while a later document/reference or reservation reuse is rejected.
do $$
declare
  v_candidate uuid := gen_random_uuid();
  v_submission uuid := gen_random_uuid();
  v_session uuid := gen_random_uuid();
  v_notice text := 's07-tombstone-' || gen_random_uuid()::text;
  v_type uuid := gen_random_uuid();
  v_logical uuid := gen_random_uuid();
  v_normal_logical uuid := gen_random_uuid();
  v_reservation uuid := gen_random_uuid();
  v_normal_reservation uuid := gen_random_uuid();
  v_path text := 'temp/' || v_session::text || '/' || v_reservation::text || '/tombstoned.pdf';
  v_normal_path text := 'temp/' || v_session::text || '/' || v_normal_reservation::text || '/normal.pdf';
  v_document_denied boolean := false;
  v_reservation_denied boolean := false;
begin
  insert into public.candidates(candidate_id, auth_user_id, email)
  values(v_candidate, gen_random_uuid(), 's07-tombstone-' || v_candidate::text || '@example.test');
  insert into public.privacy_notice_versions(notice_version, content_vi, content_hash_sha256, is_current)
  values(v_notice, 's07 tombstone', repeat('c', 64), false);
  insert into public.document_types(document_type_id, code, name_vi, scope_code)
  values(v_type, 'S07T-' || left(v_type::text, 8), 'S07 tombstone', 'SUBMISSION');
  insert into public.submissions(
    submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot
  ) values (
    v_submission, v_candidate, 'S07', date '2000-01-01', 'FEMALE', 'test', '0000000000',
    's07-tombstone-submission-' || v_candidate::text || '@example.test'
  );
  insert into public.candidate_form_sessions(
    candidate_form_session_id, candidate_id, mode_code, presented_privacy_notice_version, expires_at
  ) values (
    v_session, v_candidate, 'NEW_SUBMISSION', v_notice, clock_timestamp() + interval '1 hour'
  );
  insert into public.submission_document_logicals(
    logical_document_id, submission_id, document_type_id, created_by_candidate_id
  ) values
    (v_normal_logical, v_submission, v_type, v_candidate),
    (v_logical, v_submission, v_type, v_candidate);
  insert into private.storage_cleanup_provenance(
    bucket_name, object_path, upload_reservation_id, source_type, source_parent_id,
    reservation_expires_at, detached_at
  ) values (
    'candidate-quarantine', v_normal_path, v_normal_reservation, 'CANDIDATE_FORM', v_session,
    clock_timestamp() - interval '2 hours', clock_timestamp()
  );
  insert into public.submission_documents(
    logical_document_id, storage_bucket, storage_path, original_filename, mime_type,
    file_size_bytes, version_no, is_current, uploaded_by_candidate_id
  ) values (
    v_normal_logical, 'candidate-quarantine', v_normal_path, 'normal.pdf', 'application/pdf',
    1, 1, true, v_candidate
  );
  insert into private.storage_cleanup_provenance(
    bucket_name, object_path, upload_reservation_id, source_type, source_parent_id,
    reservation_expires_at, detached_at, tombstoned_at, tombstone_cleanup_id
  ) values (
    'candidate-quarantine', v_path, v_reservation, 'CANDIDATE_FORM', v_session,
    clock_timestamp() - interval '2 hours', clock_timestamp(), clock_timestamp(), gen_random_uuid()
  );
  begin
    insert into public.submission_documents(
      logical_document_id, storage_bucket, storage_path, original_filename, mime_type,
      file_size_bytes, version_no, is_current, uploaded_by_candidate_id
    ) values (
      v_logical, 'candidate-quarantine', v_path, 'tombstoned.pdf', 'application/pdf',
      1, 1, true, v_candidate
    );
  exception when check_violation then
    v_document_denied := true;
  end;
  begin
    insert into public.upload_reservations(
      upload_reservation_id, candidate_form_session_id, intended_document_type_id,
      temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key, expires_at
    ) values (
      v_reservation, v_session, v_type, 'candidate-quarantine', v_path,
      'tombstoned.pdf', gen_random_uuid(), gen_random_uuid(), clock_timestamp() + interval '30 minutes'
    );
  exception when check_violation then
    v_reservation_denied := true;
  end;
  if not v_document_denied or not v_reservation_denied then
    raise exception 'authorized tombstone must prevent future document and reservation resurrection';
  end if;
end;
$$;

-- Deferred/live/unknown/replacement cases are never executable cleanup authority.
do $$
declare
  v_signed_queue uuid := gen_random_uuid();
  v_live_queue uuid := gen_random_uuid();
  v_unknown_queue uuid := gen_random_uuid();
  v_replaced_queue uuid := gen_random_uuid();
  v_signed_res uuid := gen_random_uuid();
  v_live_res uuid := gen_random_uuid();
  v_replaced_res uuid := gen_random_uuid();
  v_candidate uuid := gen_random_uuid();
  v_notice text := 's07-live-' || gen_random_uuid()::text;
  v_type uuid := gen_random_uuid();
  v_session uuid := gen_random_uuid();
  v_parent uuid;
  v_signed_path text := 'temp/' || gen_random_uuid()::text || '/' || v_signed_res::text || '/signed.pdf';
  v_live_path text := 'temp/' || gen_random_uuid()::text || '/' || v_live_res::text || '/live.pdf';
  v_replaced_path text := 'temp/' || gen_random_uuid()::text || '/' || v_replaced_res::text || '/replaced.pdf';
  v_claim jsonb;
begin
  insert into public.candidates(candidate_id, auth_user_id, email)
  values(v_candidate, gen_random_uuid(), 's07-live-' || v_candidate::text || '@example.test');
  insert into public.privacy_notice_versions(notice_version, content_vi, content_hash_sha256, is_current)
  values(v_notice, 's07 live', repeat('e', 64), false);
  insert into public.document_types(document_type_id, code, name_vi, scope_code)
  values(v_type, 'S07L-' || left(v_type::text, 8), 'S07 live', 'SUBMISSION');
  insert into public.candidate_form_sessions(
    candidate_form_session_id, candidate_id, mode_code, presented_privacy_notice_version, expires_at
  ) values (
    v_session, v_candidate, 'NEW_SUBMISSION', v_notice, clock_timestamp() + interval '1 hour'
  );
  v_parent := v_session;
  insert into public.upload_reservations(
    upload_reservation_id, candidate_form_session_id, intended_document_type_id, temp_bucket,
    temp_path, original_filename, actor_auth_user_id, idempotency_key, expires_at, status_code
  ) values (
    v_live_res, v_session, v_type, 'candidate-quarantine',
    v_live_path, 'live.pdf', gen_random_uuid(), gen_random_uuid(), clock_timestamp() - interval '1 hour', 'RESERVED'
  );
  insert into private.storage_cleanup_provenance(bucket_name, object_path, upload_reservation_id, source_type, source_parent_id, reservation_expires_at, signed_upload_expires_at, detached_at)
  values
    ('candidate-quarantine', v_signed_path, v_signed_res, 'CANDIDATE_FORM', v_parent, clock_timestamp() - interval '1 hour', clock_timestamp() + interval '1 hour', clock_timestamp()),
    ('candidate-quarantine', v_replaced_path, v_replaced_res, 'CANDIDATE_FORM', v_parent, clock_timestamp() - interval '1 hour', null, clock_timestamp());
  insert into public.storage_cleanup_queue(storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id, bucket_name, object_path, reason_code, status_code, not_before)
  values
    (v_signed_queue, 'CANDIDATE_FORM', v_parent, v_signed_res, 'candidate-quarantine', v_signed_path, 'RESERVATION_EXPIRED', 'PENDING', clock_timestamp() - interval '1 hour'),
    (v_live_queue, 'CANDIDATE_FORM', v_parent, v_live_res, 'candidate-quarantine', v_live_path, 'RESERVATION_EXPIRED', 'PENDING', clock_timestamp() - interval '1 hour'),
    (v_unknown_queue, 'CANDIDATE_FORM', gen_random_uuid(), gen_random_uuid(), 'candidate-quarantine', 'temp/not-a-managed-identity', 'RESERVATION_EXPIRED', 'PENDING', clock_timestamp() - interval '1 hour'),
    (v_replaced_queue, 'CANDIDATE_FORM', v_parent, v_replaced_res, 'candidate-quarantine', v_replaced_path, 'DOCUMENT_REPLACED', 'PENDING', clock_timestamp() - interval '1 hour');
  v_claim := public.claim_storage_cleanup_jobs('withhold-worker', 10, 60);
  if jsonb_array_length(v_claim->'data') <> 0
    or (select status_code from public.storage_cleanup_queue where storage_cleanup_id = v_signed_queue) <> 'PENDING'
    or (select eligibility_code from public.storage_cleanup_queue where storage_cleanup_id = v_signed_queue) <> 'SIGNED_WINDOW'
    or (select status_code from public.storage_cleanup_queue where storage_cleanup_id = v_live_queue) <> 'PENDING'
    or (select eligibility_code from public.storage_cleanup_queue where storage_cleanup_id = v_live_queue) <> 'LIVE_RESERVATION'
    or (select status_code from public.storage_cleanup_queue where storage_cleanup_id = v_unknown_queue) <> 'ERROR'
    or (select status_code from public.storage_cleanup_queue where storage_cleanup_id = v_replaced_queue) <> 'ERROR' then
    raise exception 'deferred and protected identities must not yield executable work';
  end if;
end;
$$;

-- Both current and historical Candidate/Interview version references block cleanup.
do $$
declare
  v_candidate uuid := gen_random_uuid();
  v_submission uuid := gen_random_uuid();
  v_type uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_unit uuid := gen_random_uuid();
  v_group uuid := gen_random_uuid();
  v_position uuid := gen_random_uuid();
  v_application uuid := gen_random_uuid();
  v_interview uuid := gen_random_uuid();
  v_paths text[] := array[
    'temp/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '/candidate-current.pdf',
    'temp/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '/candidate-history.pdf',
    'temp/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '/interview-current.pdf',
    'temp/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '/interview-history.pdf'
  ];
  v_path text;
  v_index integer := 0;
  v_queue uuid;
  v_reservation uuid;
  v_parent uuid := gen_random_uuid();
  v_logical uuid;
  v_claim jsonb;
begin
  insert into public.candidates(candidate_id, auth_user_id, email)
  values(v_candidate, gen_random_uuid(), 's07-reference-' || v_candidate::text || '@example.test');
  insert into public.app_users(app_user_id, auth_user_id, email, full_name)
  values(v_staff, gen_random_uuid(), 's07-reference-' || v_staff::text || '@eiu.edu.vn', 'S07 reference');
  insert into public.app_user_roles(app_user_id, role_code)
  values(v_staff, 'HR');
  insert into public.document_types(document_type_id, code, name_vi, scope_code)
  values(v_type, 'S07R-' || left(v_type::text, 8), 'S07 ref', 'BOTH');
  insert into public.organizational_units(unit_id, code, name_vi)
  values(v_unit, 'S07R-' || left(v_unit::text, 8), 'S07 reference');
  insert into public.position_groups(position_group_id, code, name_vi)
  values(v_group, 'S07R-' || left(v_group::text, 8), 'S07 reference');
  insert into public.positions(position_id, unit_id, position_group_id, code, name_vi)
  values(v_position, v_unit, v_group, 'S07R-' || left(v_position::text, 8), 'S07 reference');
  insert into public.submissions(
    submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot
  ) values (
    v_submission, v_candidate, 'S07', date '2000-01-01', 'FEMALE', 'test', '0000000000',
    's07-reference-submission-' || v_candidate::text || '@example.test'
  );
  insert into public.applications(application_id, submission_id, unit_id, position_id, hr_owner_id)
  values(v_application, v_submission, v_unit, v_position, v_staff);
  insert into public.interviews(interview_id, application_id, round_no)
  values(v_interview, v_application, 1);

  foreach v_path in array v_paths loop
    v_index := v_index + 1;
    v_queue := gen_random_uuid();
    v_reservation := gen_random_uuid();
    insert into private.storage_cleanup_provenance(bucket_name, object_path, upload_reservation_id, source_type, source_parent_id, reservation_expires_at, detached_at)
    values('candidate-quarantine', v_path, v_reservation, 'CANDIDATE_FORM', v_parent, clock_timestamp() - interval '2 hours', clock_timestamp());
    insert into public.storage_cleanup_queue(storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id, bucket_name, object_path, reason_code, status_code, not_before)
    values(v_queue, 'CANDIDATE_FORM', v_parent, v_reservation, 'candidate-quarantine', v_path, 'RESERVATION_EXPIRED', 'PENDING', clock_timestamp() - interval '1 hour');
    v_logical := gen_random_uuid();
    if v_index <= 2 then
      insert into public.submission_document_logicals(logical_document_id, submission_id, document_type_id, created_by_candidate_id)
      values(v_logical, v_submission, v_type, v_candidate);
      insert into public.submission_documents(
        logical_document_id, storage_bucket, storage_path, original_filename, mime_type,
        file_size_bytes, version_no, is_current, uploaded_by_candidate_id
      ) values (
        v_logical, 'candidate-quarantine', v_path, 'ref.pdf', 'application/pdf',
        1, 1, v_index = 1, v_candidate
      );
    else
      insert into public.interview_document_logicals(logical_document_id, interview_id, document_type_id, created_by)
      values(v_logical, v_interview, v_type, v_staff);
      insert into public.interview_documents(
        logical_document_id, storage_bucket, storage_path, original_filename, mime_type,
        file_size_bytes, version_no, is_current, uploaded_by
      ) values (
        v_logical, 'candidate-quarantine', v_path, 'ref.pdf', 'application/pdf',
        1, 1, v_index = 3, v_staff
      );
    end if;
  end loop;
  v_claim := public.claim_storage_cleanup_jobs('reference-worker', 10, 60);
  if jsonb_array_length(v_claim->'data') <> 0
    or (select count(*) from public.storage_cleanup_queue where eligibility_code = 'RETAINED_REFERENCE' and source_parent_id = v_parent) <> 4 then
    raise exception 'all current and historical document references must retain their object identity';
  end if;
end;
$$;

rollback;
