-- TASK-S06-001 R2: inactive historical Document Types remain usable for trusted REPLACE/DELETE, never ADD.
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_suffix text := substr(gen_random_uuid()::text, 1, 8);
  v_hr_auth uuid := gen_random_uuid();
  v_hr uuid;
  v_candidate_auth uuid := gen_random_uuid();
  v_candidate uuid;
  v_submission uuid;
  v_doc_type uuid;
  v_cv_type uuid;
  v_target_logical uuid;
  v_cv_logical uuid;
  v_session uuid;
  v_reservation uuid;
  v_notice text;
  v_version bigint;
  v_result jsonb;
begin
  insert into public.app_users(auth_user_id, email, full_name, is_active)
  values (v_hr_auth, 's06001_doc_history_' || v_suffix || '@eiu.edu.vn', 'S06 Document HR', true)
  returning app_user_id into v_hr;
  insert into public.app_user_permissions(app_user_id, permission_code)
  values (v_hr, 'master_data.manage') on conflict do nothing;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth::text)::text, true);
  v_result := public.create_master_item(
    'document_types',
    jsonb_build_object(
      'code', 'S06001_HIST_DOC_' || v_suffix,
      'name_vi', 'Historical document type',
      'scope_code', 'SUBMISSION'
    ),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_doc_type := (v_result->'data'->>'master_id')::uuid;

  select document_type_id into v_cv_type
  from public.document_types
  where code = 'CV_RESUME' and is_active = true;
  assert v_cv_type is not null, 'canonical active CV type must exist';

  insert into public.candidates(auth_user_id, email, is_active)
  values (v_candidate_auth, 's06001_doc_candidate_' || v_suffix || '@example.com', true)
  returning candidate_id into v_candidate;

  -- Candidate edit sessions require one current effective Privacy Notice.
  update public.privacy_notice_versions set is_current = false where is_current = true;
  insert into public.privacy_notice_versions(
    notice_version, content_vi, content_en, content_hash_sha256,
    published_at, effective_from, is_current, created_by
  ) values (
    'S06001_DOC_' || v_suffix,
    'S06 document history notice',
    'S06 document history notice',
    repeat('a', 64),
    clock_timestamp() - interval '1 minute',
    clock_timestamp() - interval '1 minute',
    true,
    v_hr
  );

  insert into public.submissions(
    candidate_id, status_code, full_name, date_of_birth, gender_code,
    current_address, phone, email_snapshot
  ) values (
    v_candidate, 'NEW', 'Document Candidate', date '1990-01-01', 'MALE',
    'Address', '0900000000', 's06001_doc_candidate_' || v_suffix || '@example.com'
  ) returning submission_id into v_submission;

  insert into public.submission_document_logicals(submission_id, document_type_id, created_by_candidate_id)
  values (v_submission, v_doc_type, v_candidate)
  returning logical_document_id into v_target_logical;
  insert into public.submission_documents(
    logical_document_id, storage_bucket, storage_path, original_filename,
    mime_type, file_size_bytes, version_no, is_current, uploaded_by_candidate_id
  ) values (
    v_target_logical, 'candidate-documents', 's06/history/' || v_suffix || '/target-v1.pdf',
    'target-v1.pdf', 'application/pdf', 512, 1, true, v_candidate
  );

  -- Keep a valid current CV so deleting/replacing the historical target does not violate plan requirements.
  insert into public.submission_document_logicals(submission_id, document_type_id, created_by_candidate_id)
  values (v_submission, v_cv_type, v_candidate)
  returning logical_document_id into v_cv_logical;
  insert into public.submission_documents(
    logical_document_id, storage_bucket, storage_path, original_filename,
    mime_type, file_size_bytes, version_no, is_current, uploaded_by_candidate_id
  ) values (
    v_cv_logical, 'candidate-documents', 's06/history/' || v_suffix || '/cv.pdf',
    'cv.pdf', 'application/pdf', 512, 1, true, v_candidate
  );

  select version_no into v_version from public.document_types where document_type_id = v_doc_type;
  v_result := public.delete_or_inactivate_master_item('document_types', v_doc_type, v_version, gen_random_uuid());
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED';
  assert not (select is_active from public.document_types where document_type_id = v_doc_type);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_candidate_auth::text)::text, true);

  -- REPLACE: reservation and staged change preserve the existing logical type even though it is inactive.
  v_result := public.start_candidate_form_session('EDIT_SUBMISSION', v_submission);
  assert (v_result->>'success')::boolean, 'fixture must open candidate EDIT session';
  v_session := (v_result->'data'->>'candidate_form_session_id')::uuid;
  v_notice := v_result->'data'->>'presented_privacy_notice_version';

  v_result := public.reserve_candidate_form_upload(
    v_session, v_doc_type, 'target-v2.pdf', 'application/pdf', 1024, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean,
    'EDIT reservation for an inactive historical type must remain available for REPLACE';
  v_reservation := (v_result->'data'->>'upload_reservation_id')::uuid;

  v_result := public.validate_and_scan_upload_reservation(
    v_reservation, 'application/pdf', 512, 'CLEAN', true,
    repeat('b', 64)
  );
  assert (v_result->>'success')::boolean;

  v_result := public.stage_candidate_document_change(
    v_session, 'REPLACE', v_doc_type, v_reservation, v_target_logical
  );
  assert (v_result->>'success')::boolean,
    'trusted REPLACE must accept the unchanged inactive historical type';

  v_result := public.update_candidate_submission(
    v_session, 'Document Candidate', '0900000000', date '1990-01-01',
    'MALE', 'Address', '[]'::jsonb, v_notice, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'trusted candidate update materializes historical-type REPLACE';
  assert (
    select count(*) = 1 and max(version_no) = 2
    from public.submission_documents
    where logical_document_id = v_target_logical and is_current = true
  ), 'REPLACE creates exactly one current version 2';
  assert (select document_type_id from public.submission_document_logicals where logical_document_id = v_target_logical) = v_doc_type;

  -- DELETE: no new type selection occurs, so the inactive historical logical remains deletable.
  v_result := public.start_candidate_form_session('EDIT_SUBMISSION', v_submission);
  assert (v_result->>'success')::boolean;
  v_session := (v_result->'data'->>'candidate_form_session_id')::uuid;
  v_notice := v_result->'data'->>'presented_privacy_notice_version';

  v_result := public.stage_candidate_document_change(
    v_session, 'DELETE', v_doc_type, null, v_target_logical
  );
  assert (v_result->>'success')::boolean,
    'trusted DELETE must accept the unchanged inactive historical type';

  v_result := public.update_candidate_submission(
    v_session, 'Document Candidate', '0900000000', date '1990-01-01',
    'MALE', 'Address', '[]'::jsonb, v_notice, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'trusted candidate update materializes historical-type DELETE';
  assert not exists (
    select 1 from public.submission_documents
    where logical_document_id = v_target_logical and is_current = true
  ), 'DELETE removes the current target version without destroying logical history';
  assert exists (
    select 1 from public.submission_documents
    where logical_document_id = v_cv_logical and is_current = true
  ), 'required CV history remains current';

  -- ADD: an inactive type is a new selection and must still fail closed.
  v_result := public.start_candidate_form_session('EDIT_SUBMISSION', v_submission);
  assert (v_result->>'success')::boolean;
  v_session := (v_result->'data'->>'candidate_form_session_id')::uuid;

  v_result := public.reserve_candidate_form_upload(
    v_session, v_doc_type, 'new-add.pdf', 'application/pdf', 1024, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean,
    'EDIT reservation alone is not a type-selection decision';
  v_reservation := (v_result->'data'->>'upload_reservation_id')::uuid;

  v_result := public.validate_and_scan_upload_reservation(
    v_reservation, 'application/pdf', 512, 'CLEAN', true,
    repeat('c', 64)
  );
  assert (v_result->>'success')::boolean;

  v_result := null;
  begin
    v_result := public.stage_candidate_document_change(
      v_session, 'ADD', v_doc_type, v_reservation, null
    );
  exception
    when others then
      if sqlstate = '23514'
         and (
           sqlerrm like '%inactive document type cannot be selected for a new document%'
           or sqlerrm like '%MASTER_INACTIVE_NOT_SELECTABLE:document_types%'
         ) then
        v_result := jsonb_build_object('success', false, 'error_code', 'INACTIVE_DOCUMENT_TYPE');
      else
        raise;
      end if;
  end;

  assert v_result is not null and not coalesce((v_result->>'success')::boolean, false),
    'inactive historical type ADD must be denied';
  assert not exists (
    select 1
    from public.candidate_form_document_changes
    where candidate_form_session_id = v_session
      and action_code = 'ADD'
      and status_code = 'PENDING'
  ), 'failed inactive ADD leaves no staged mutation';
end;
$$;

rollback;