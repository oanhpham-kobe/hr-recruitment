-- =============================================================================
-- PRE-S04 Contract Repairs Comprehensive Integration & Regression Assertions
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_cand_id uuid := '00000000-0000-0000-0000-000000000001';
  v_auth_id uuid := '00000000-0000-0000-0000-000000000001';
  v_hr_id uuid := '00000000-0000-0000-0000-000000000002';
  v_hr_auth_id uuid := '00000000-0000-0000-0000-000000000002';
  v_view_only_hr_id uuid := '00000000-0000-0000-0000-000000000003';
  v_view_only_auth_id uuid := '00000000-0000-0000-0000-000000000003';
  v_root_id uuid := '00000000-0000-0000-0000-000000000004';
  v_root_auth_id uuid := '00000000-0000-0000-0000-000000000004';
  v_unit_id uuid;
  v_pos_id uuid;
  v_sub_id uuid;
  v_app_id uuid;
  v_int1_id uuid;
  v_int2_id uuid;
  v_session_id uuid;
  v_qual_id uuid;
  v_doc_type_cert uuid;
  v_doc_type_cv uuid;
  v_res1 uuid;
  v_res2 uuid;
  v_res3 uuid;
  v_pg_id uuid;
  v_outcome text;
  v_result jsonb;
  v_count integer;
begin
  raise notice '=== Running PRE-S04 Contract Repairs Test Suite ===';

  -- ---------------------------------------------------------------------------
  -- 1. Verify Overload Ambiguity: exactly one submit & update candidate submission
  select count(*) into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'submit_candidate_submission';
  assert v_count = 1, 'submit_candidate_submission must have exactly one overload';

  select count(*) into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'update_candidate_submission';
  assert v_count = 1, 'update_candidate_submission must have exactly one overload';

  -- ---------------------------------------------------------------------------
  -- 2. Verify ACL: recalculate_submission_status denied to public/anon/authenticated
  -- ---------------------------------------------------------------------------
  assert (
    select count(*) = 0
    from information_schema.routine_privileges
    where routine_schema = 'public'
      and routine_name = 'recalculate_submission_status'
      and grantee in ('PUBLIC', 'anon', 'authenticated')
  ), 'recalculate_submission_status must NOT be granted to PUBLIC, anon, or authenticated';

  -- ---------------------------------------------------------------------------
  -- 3. Setup Test Fixtures: Unit, Position Group, Position, Masters
  -- ---------------------------------------------------------------------------
  insert into public.position_groups (name_vi, code)
  values ('Giảng viên Group Test', 'PG_TEST_' || gen_random_uuid())
  returning position_group_id into v_pg_id;

  insert into public.organizational_units (name_vi, code)
  values ('Khoa CNTT Test', 'FIT_TEST_' || gen_random_uuid())
  returning unit_id into v_unit_id;

  insert into public.positions (unit_id, position_group_id, code, name_vi)
  values (v_unit_id, v_pg_id, 'LECT_TEST_' || gen_random_uuid(), 'Giảng viên Test')
  returning position_id into v_pos_id;
  insert into public.privacy_notice_versions (notice_version, content_vi, content_hash_sha256, is_current, effective_from)
  values ('2026-09-01-v1', 'Nội dung thông báo...', repeat('a', 64), true, clock_timestamp() - interval '1 day')
  on conflict (notice_version) do update set is_current = true;

  insert into public.qualification_levels (code, name_vi, is_active)
  values ('BACHELOR_' || substr(gen_random_uuid()::text, 1, 8), 'Cử nhân', true)
  returning qualification_id into v_qual_id;
  insert into public.document_types (code, name_vi, scope_code, is_active)
  values ('CV_RESUME', 'CV / Sơ yếu lý lịch', 'SUBMISSION', true)
  on conflict (code) do update set is_active = true
  returning document_type_id into v_doc_type_cv;

  insert into public.document_types (code, name_vi, scope_code, is_active)
  values ('CERTIFICATE', 'Chứng chỉ', 'SUBMISSION', true)
  on conflict (code) do update set is_active = true
  returning document_type_id into v_doc_type_cert;

  -- Create internal users
  insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_active, is_root_admin)
  values
    (v_hr_id, v_hr_auth_id, 'hr_test@eiu.edu.vn', 'HR Test Full', true, false),
    (v_view_only_hr_id, v_view_only_auth_id, 'viewonly_test@eiu.edu.vn', 'HR View Only Submissions', true, false),
    (v_root_id, v_root_auth_id, 'root_test@eiu.edu.vn', 'Root Admin Test', true, true)
  on conflict (app_user_id) do update set is_root_admin = excluded.is_root_admin;

  -- Roles & permissions
  insert into public.app_user_roles (app_user_id, role_code)
  values (v_hr_id, 'HR'), (v_view_only_hr_id, 'HR')
  on conflict do nothing;

  -- v_view_only_hr_id has ONLY submissions.view (no applications.view, no applications.manage, no interviews.view)
  delete from public.app_user_permissions where app_user_id = v_view_only_hr_id;
  insert into public.app_user_permissions (app_user_id, permission_code)
  values (v_view_only_hr_id, 'submissions.view');

  -- v_hr_id has applications.view, applications.manage, interviews.view, interviews.manage, submissions.view, submissions.edit, submissions.status
  delete from public.app_user_permissions where app_user_id = v_hr_id;
  insert into public.app_user_permissions (app_user_id, permission_code)
  values
    (v_hr_id, 'submissions.view'),
    (v_hr_id, 'submissions.edit'),
    (v_hr_id, 'submissions.status'),
    (v_hr_id, 'applications.view'),
    (v_hr_id, 'applications.manage'),
    (v_hr_id, 'interviews.view'),
    (v_hr_id, 'interviews.manage');

  -- Candidate
  insert into public.candidates (candidate_id, auth_user_id, email, current_full_name, is_active)
  values (v_cand_id, v_auth_id, 'candidate_test@example.com', 'Candidate Test', true)
  on conflict do nothing;

  -- Submission
  v_sub_id := gen_random_uuid();
  insert into public.submissions (
    submission_id, candidate_id, status_code, full_name, date_of_birth,
    gender_code, current_address, phone, email_snapshot, other_info, hr_note, version_no
  ) values (
    v_sub_id, v_cand_id, 'NEW', 'Candidate Test', '1995-01-01',
    'MALE', '123 Binh Duong', '0901234567', 'candidate_test@example.com',
    'Original Other Info HR Only', 'Original HR Note', 1
  );

  insert into public.submission_document_logicals (
    logical_document_id, submission_id, document_type_id, created_by_candidate_id, created_at
  ) values (
    '00000000-0000-0000-0000-000000000010', v_sub_id, v_doc_type_cv, v_cand_id, now()
  );
  insert into public.submission_documents (
    logical_document_id, storage_bucket, storage_path, original_filename, mime_type, file_size_bytes, is_current, version_no, uploaded_by_candidate_id
  ) values (
    '00000000-0000-0000-0000-000000000010', 'candidate-documents', 'docs/initial_cv.pdf', 'initial_cv.pdf', 'application/pdf', 2048, true, 1, v_cand_id
  );

  insert into public.submission_work_experiences (submission_id, employer, job_title, sort_order)
  values (v_sub_id, 'Old Employer HR Only', 'Engineer', 1);

  insert into public.submission_activities (submission_id, activity_name, sort_order)
  values (v_sub_id, 'Old Activity HR Only', 1);

  -- Application & Interviews
  v_app_id := gen_random_uuid();
  insert into public.applications (
    application_id, submission_id, unit_id, position_id, hr_owner_id, is_active
  ) values (
    v_app_id, v_sub_id, v_unit_id, v_pos_id, v_hr_id, true
  );

  v_int1_id := gen_random_uuid();
  insert into public.interviews (
    interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active
  ) values (
    v_int1_id, v_app_id, 1, 'AVAILABLE', 'FOLLOW_UP', true
  );

  v_int2_id := gen_random_uuid();
  insert into public.interviews (
    interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active
  ) values (
    v_int2_id, v_app_id, 2, 'AVAILABLE', 'FOLLOW_UP', true
  );

  raise notice 'Fixtures created successfully';

  -- ---------------------------------------------------------------------------
  -- 4. Authoritative Current-Round Effective Outcome Resolver Tests
  -- ---------------------------------------------------------------------------
  -- Case 1: Round 1 REJECTED, Round 2 FOLLOW_UP(active) => Application IN_PROGRESS
  update public.interviews set report_status_code = 'REJECTED' where interview_id = v_int1_id;
  update public.interviews set report_status_code = 'FOLLOW_UP', is_active = true where interview_id = v_int2_id;
  v_outcome := private.application_effective_outcome(v_app_id);
  assert v_outcome = 'IN_PROGRESS', 'Case 1 failed: Expected IN_PROGRESS, got ' || v_outcome;

  -- Case 2: Round 1 HIRED, Round 2 FOLLOW_UP(active legacy row) => Application IN_PROGRESS
  update public.interviews set report_status_code = 'HIRED' where interview_id = v_int1_id;
  update public.interviews set report_status_code = 'FOLLOW_UP', is_active = true where interview_id = v_int2_id;
  v_outcome := private.application_effective_outcome(v_app_id);
  assert v_outcome = 'IN_PROGRESS', 'Case 2 failed: Expected IN_PROGRESS, got ' || v_outcome;

  -- Case 3: Round 1 FOLLOW_UP, Round 2 REJECTED => REJECTED
  update public.interviews set report_status_code = 'FOLLOW_UP' where interview_id = v_int1_id;
  update public.interviews set report_status_code = 'REJECTED', is_active = true where interview_id = v_int2_id;
  v_outcome := private.application_effective_outcome(v_app_id);
  assert v_outcome = 'REJECTED', 'Case 3 failed: Expected REJECTED, got ' || v_outcome;

  -- Case 4: Round 1 REJECTED (inactive), Round 2 HIRED (active) => HIRED
  update public.interviews set report_status_code = 'REJECTED', is_active = false where interview_id = v_int1_id;
  update public.interviews set report_status_code = 'HIRED', is_active = true where interview_id = v_int2_id;
  v_outcome := private.application_effective_outcome(v_app_id);
  assert v_outcome = 'HIRED', 'Case 4 failed: Expected HIRED, got ' || v_outcome;

  raise notice 'Authoritative Outcome Resolver regression tests PASS (4/4)';

  -- ---------------------------------------------------------------------------
  -- 5. recalculate_submission_status integration test
  -- Round 2 is HIRED => Submission becomes DONE
  -- ---------------------------------------------------------------------------
  v_result := public.recalculate_submission_status(v_sub_id);
  assert (v_result->>'new_status') = 'DONE', 'Submission status should recalculate to DONE when Application outcome is HIRED';
  assert (select status_code from public.submissions where submission_id = v_sub_id) = 'DONE';

  -- When Round 2 is REJECTED => Submission becomes CLOSED
  update public.interviews set report_status_code = 'REJECTED', is_active = true where interview_id = v_int2_id;
  v_result := public.recalculate_submission_status(v_sub_id);
  assert (v_result->>'new_status') = 'CLOSED', 'Submission status should recalculate to CLOSED when all Applications are REJECTED';

  -- When Application is inactivated => Submission returns to READ (Owner Decision B/D)
  update public.applications set is_active = false where application_id = v_app_id;
  v_result := public.recalculate_submission_status(v_sub_id);
  assert (v_result->>'new_status') = 'READ', 'Submission should return to READ after last Application is inactivated';

  raise notice 'recalculate_submission_status tests PASS';

  -- ---------------------------------------------------------------------------
  -- 6. get_submission_detail Pure Read vs open_submission Explicit Intent
  -- ---------------------------------------------------------------------------
  -- Put submission back in NEW
  update public.submissions set status_code = 'NEW' where submission_id = v_sub_id;

  -- Set auth context to HR with submissions.view + submissions.status
  perform set_config('request.jwt.claim.sub', v_hr_auth_id::text, true);

  -- Calling get_submission_detail MUST leave status as NEW!
  v_result := public.get_submission_detail(v_sub_id);
  assert (v_result->>'success')::boolean = true, 'get_submission_detail should succeed';
  assert (v_result->'data'->>'status_code') = 'NEW', 'Returned status_code must be NEW';
  assert (select status_code from public.submissions where submission_id = v_sub_id) = 'NEW', 'DB status MUST remain NEW after get_submission_detail';

  -- Calling open_submission with submissions.status MUST transition NEW -> READ
  v_result := public.open_submission(v_sub_id);
  assert (v_result->>'success')::boolean = true, 'open_submission should succeed';
  assert (v_result->'data'->>'status_code') = 'READ', 'Returned status_code must be READ';
  assert (select status_code from public.submissions where submission_id = v_sub_id) = 'READ', 'DB status must be READ after explicit open_submission';

  raise notice 'get_submission_detail pure read & open_submission PASS';

  -- ---------------------------------------------------------------------------
  -- 7. HR Candidate-Data Correction Command (correct_submission_candidate_fields_by_hr)
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_hr_auth_id::text, true);

  v_result := public.correct_submission_candidate_fields_by_hr(
    v_sub_id,
    'Candidate Test Corrected by HR',
    '0909999999',
    '1995-02-02'::date,
    'FEMALE',
    '456 Thu Dau Mot Corrected',
    (select version_no from public.submissions where submission_id = v_sub_id), -- expected version
    'Correcting typo upon candidate call'
  );

  assert (v_result->>'success')::boolean = true, 'Correction should succeed: ' || coalesce(v_result->>'message', '');
  assert (select full_name from public.submissions where submission_id = v_sub_id) = 'Candidate Test Corrected by HR';
  assert (select phone from public.submissions where submission_id = v_sub_id) = '0909999999';
  assert (select gender_code from public.submissions where submission_id = v_sub_id) = 'FEMALE';
  assert (select current_address from public.submissions where submission_id = v_sub_id) = '456 Thu Dau Mot Corrected';
  assert (select version_no from public.submissions where submission_id = v_sub_id) = (v_result->>'version_no')::bigint;

  -- Verify Security Audit was written with changed field names only (no full PII dump)
  assert exists (
    select 1 from public.security_audit_log
    where action_code = 'CORRECT_SUBMISSION_CANDIDATE_FIELDS_BY_HR'
      and entity_id = v_sub_id
      and (metadata->'changed_fields') is not null
  ), 'Security audit must be written with changed_fields metadata';

  raise notice 'correct_submission_candidate_fields_by_hr PASS';

  -- ---------------------------------------------------------------------------
  -- 8. Candidate Document ADD/REPLACE/DELETE & Non-Unique Document Type Support
  -- ---------------------------------------------------------------------------
  -- Create form session for candidate
  v_session_id := gen_random_uuid();
  insert into public.candidate_form_sessions (
    candidate_form_session_id, candidate_id, mode_code, status_code,
    presented_privacy_notice_version, expires_at
  ) values (
    v_session_id, v_cand_id, 'NEW_SUBMISSION', 'OPEN',
    '2026-09-01-v1', clock_timestamp() + interval '4 hours'
  );

  -- Upload 1: CV
  v_res1 := gen_random_uuid();
  insert into public.upload_reservations (
    upload_reservation_id, candidate_form_session_id, intended_document_type_id,
    temp_bucket, temp_path, original_filename, declared_mime_type, expected_max_size_bytes, actual_size_bytes,
    status_code, malware_scan_status, actor_auth_user_id, idempotency_key, expires_at
  ) values (
    v_res1, v_session_id, v_doc_type_cv,
    'candidate-quarantine', 'temp/cv1.pdf', 'my_cv.pdf', 'application/pdf', 5242880, 1024,
    'VALIDATED', 'CLEAN', v_auth_id, gen_random_uuid(), clock_timestamp() + interval '4 hours'
  );

  -- Authorize the caller-owned reservation before any privileged scan reads it.
  update public.upload_reservations
  set status_code = 'RESERVED', malware_scan_status = 'PENDING'
  where upload_reservation_id = v_res1;


  perform set_config('request.jwt.claim.sub', v_auth_id::text, true);
  v_result := public.authorize_candidate_upload_scan(v_session_id, v_res1);
  assert (v_result->>'success')::boolean = true,
    'Candidate-owned OPEN session must authorize its RESERVED reservation before scanning';

  update public.upload_reservations
  set status_code = 'VALIDATED', malware_scan_status = 'CLEAN'
  where upload_reservation_id = v_res1;

  insert into public.candidate_form_document_changes (
    candidate_form_session_id, upload_reservation_id, action_code, intended_document_type_id, status_code
  ) values (v_session_id, v_res1, 'ADD', v_doc_type_cv, 'PENDING');

  -- Upload 2: Certificate A (first certificate)
  v_res2 := gen_random_uuid();
  insert into public.upload_reservations (
    upload_reservation_id, candidate_form_session_id, intended_document_type_id,
    temp_bucket, temp_path, original_filename, declared_mime_type, expected_max_size_bytes, actual_size_bytes,
    status_code, malware_scan_status, actor_auth_user_id, idempotency_key, expires_at
  ) values (
    v_res2, v_session_id, v_doc_type_cert,
    'candidate-quarantine', 'temp/cert1.pdf', 'ielts.pdf', 'application/pdf', 5242880, 2048,
    'VALIDATED', 'CLEAN', v_auth_id, gen_random_uuid(), clock_timestamp() + interval '4 hours'
  );

  insert into public.candidate_form_document_changes (
    candidate_form_session_id, upload_reservation_id, action_code, intended_document_type_id, status_code
  ) values (v_session_id, v_res2, 'ADD', v_doc_type_cert, 'PENDING');

  -- Upload 3: Certificate B (second certificate - SAME document_type_id!)
  v_res3 := gen_random_uuid();
  insert into public.upload_reservations (
    upload_reservation_id, candidate_form_session_id, intended_document_type_id,
    temp_bucket, temp_path, original_filename, declared_mime_type, expected_max_size_bytes, actual_size_bytes,
    status_code, malware_scan_status, actor_auth_user_id, idempotency_key, expires_at
  ) values (
    v_res3, v_session_id, v_doc_type_cert,
    'candidate-quarantine', 'temp/cert2.pdf', 'toeic.pdf', 'application/pdf', 5242880, 3072,
    'VALIDATED', 'CLEAN', v_auth_id, gen_random_uuid(), clock_timestamp() + interval '4 hours'
  );

  insert into public.candidate_form_document_changes (
    candidate_form_session_id, upload_reservation_id, action_code, intended_document_type_id, status_code
  ) values (v_session_id, v_res3, 'ADD', v_doc_type_cert, 'PENDING');

  -- Execute submit_candidate_submission as candidate
  perform set_config('request.jwt.claim.sub', v_auth_id::text, true);

  v_result := public.submit_candidate_submission(
    v_session_id,
    'Candidate Multi Cert Test',
    '0901111222',
    '1992-05-20'::date,
    'FEMALE',
    '789 Binh Duong Blvd',
    jsonb_build_array(
      jsonb_build_object(
        'period_text', '2010 - 2014',
        'qualification_id', v_qual_id,
        'major', 'Computer Science',
        'institution', 'EIU'
      )
    ),
    '2026-09-01-v1'
  );

  assert (v_result->>'success')::boolean = true, 'submit_candidate_submission should succeed with multiple CERTIFICATEs: ' || coalesce(v_result->>'message', '');

  -- Assert two different logical document headers exist for CERTIFICATE under the new submission!
  select count(*) into v_count
  from public.submission_document_logicals
  where submission_id = (v_result->>'submission_id')::uuid
    and document_type_id = v_doc_type_cert;

  assert v_count = 2, 'Two CERTIFICATE logical document headers must coexist under the submission! Got count = ' || v_count;

  -- Assert creator metadata set to Candidate and NULL for app_user
  assert exists (
    select 1 from public.submission_document_logicals
    where submission_id = (v_result->>'submission_id')::uuid
      and created_by_candidate_id = v_cand_id
      and created_by_app_user_id is null
  ), 'Logical headers must have created_by_candidate_id set and created_by_app_user_id NULL';

  assert exists (
    select 1 from public.submission_documents
    where uploaded_by_candidate_id = v_cand_id
      and uploaded_by_app_user_id is null
  ), 'Document versions must have uploaded_by_candidate_id set and uploaded_by_app_user_id NULL';

  -- Assert privacy acknowledgement row exists with physical columns
  assert exists (
    select 1 from public.privacy_acknowledgements
    where submission_id = (v_result->>'submission_id')::uuid
      and notice_version = '2026-09-01-v1'
      and source_code = 'CANDIDATE_PORTAL'
  ), 'privacy_acknowledgements row must exist with physical schema';

  raise notice 'Candidate document materialization & non-unique logicals PASS';

  -- ---------------------------------------------------------------------------
  -- 9. Candidate Edit Preserving HR-Only Child Data
  -- ---------------------------------------------------------------------------
  -- Create an EDIT session targeting v_sub_id
  v_session_id := gen_random_uuid();
  update public.submissions set status_code = 'NEW' where submission_id = v_sub_id;

  insert into public.candidate_form_sessions (
    candidate_form_session_id, candidate_id, mode_code, target_submission_id,
    base_submission_version_no, status_code, presented_privacy_notice_version, expires_at
  ) values (
    v_session_id, v_cand_id, 'EDIT_SUBMISSION', v_sub_id,
    (select version_no from public.submissions where submission_id = v_sub_id),
    'OPEN', '2026-09-01-v1', clock_timestamp() + interval '4 hours'
  );

  v_result := public.update_candidate_submission(
    v_session_id,
    'Candidate Test Updated By Candidate',
    '0908888777',
    '1995-01-01'::date,
    'MALE',
    'Updated Address 999',
    jsonb_build_array(
      jsonb_build_object(
        'period_text', '2014 - 2018',
        'qualification_id', v_qual_id,
        'major', 'Software Engineering',
        'institution', 'EIU'
      )
    ),
    '2026-09-01-v1'
  );

  assert (v_result->>'success')::boolean = true, 'update_candidate_submission should succeed: ' || coalesce(v_result->>'message', '');

  -- Assert Candidate updated fields changed
  assert (select full_name from public.submissions where submission_id = v_sub_id) = 'Candidate Test Updated By Candidate';

  -- Assert HR-only fields and children SURVIVED UNTOUCHED!
  assert (select other_info from public.submissions where submission_id = v_sub_id) = 'Original Other Info HR Only', 'other_info must NOT be cleared by candidate edit';
  assert (select hr_note from public.submissions where submission_id = v_sub_id) = 'Original HR Note', 'hr_note must NOT be cleared by candidate edit';
  assert (select count(*) from public.submission_work_experiences where submission_id = v_sub_id) = 1, 'HR-only work experiences must survive candidate edit';
  assert (select count(*) from public.submission_activities where submission_id = v_sub_id) = 1, 'HR-only activities must survive candidate edit';

  raise notice 'Candidate Edit preserving HR-only data PASS';
  insert into public.privacy_notice_versions (notice_version, content_vi, content_hash_sha256, is_current, effective_from)
  values ('OLD_VERSION_PINNED', 'Nội dung cũ...', repeat('b', 64), false, clock_timestamp() - interval '2 days')
  on conflict do nothing;


  -- ---------------------------------------------------------------------------
  -- 10. Privacy Notice Strong-Current Rejection (PRIVACY_NOTICE_CHANGED)
  -- ---------------------------------------------------------------------------
  v_session_id := gen_random_uuid();
  insert into public.candidate_form_sessions (
    candidate_form_session_id, candidate_id, mode_code, status_code,
    presented_privacy_notice_version, expires_at
  ) values (
    v_session_id, v_cand_id, 'NEW_SUBMISSION', 'OPEN',
    'OLD_VERSION_PINNED', clock_timestamp() + interval '4 hours'
  );

  -- Attempt to submit with notice version that is NOT currently effective
  v_result := public.submit_candidate_submission(
    v_session_id,
    'Candidate Stale Privacy Test',
    '0901234567',
    '1995-01-01'::date,
    'MALE',
    '123 Stale St',
    '[]'::jsonb,
    'OLD_VERSION_PINNED'
  );

  assert (v_result->>'success')::boolean = false, 'Submit must fail when privacy notice is not current';
  assert (v_result->>'error_code') = 'PRIVACY_NOTICE_CHANGED', 'Expected error_code PRIVACY_NOTICE_CHANGED, got ' || coalesce(v_result->>'error_code', '');

  raise notice 'Privacy strong-current PRIVACY_NOTICE_CHANGED test PASS';

  -- ---------------------------------------------------------------------------
  -- 11. Candidate Verified Email Immutability vs Trusted Recovery Context
  -- ---------------------------------------------------------------------------
  -- Direct update without setting must FAIL with CANDIDATE_VERIFIED_EMAIL_IMMUTABLE
  begin
    update public.candidates set email = 'hacked@example.com' where candidate_id = v_cand_id;
    assert false, 'Direct update to candidates.email must be blocked by trigger!';
  exception when sqlstate '23514' then
    assert sqlerrm like '%CANDIDATE_VERIFIED_EMAIL_IMMUTABLE%', 'Expected CANDIDATE_VERIFIED_EMAIL_IMMUTABLE error';
  end;

  -- Trusted recovery context with recruitment.candidate_email_recovery_active = 'on' succeeds!
  perform set_config('recruitment.candidate_email_recovery_active', 'on', true);
  update public.candidates set email = 'recovered_email@example.com' where candidate_id = v_cand_id;
  assert (select email::text from public.candidates where candidate_id = v_cand_id) = 'recovered_email@example.com', 'Email update must succeed under trusted recovery setting';

  -- Reset setting back to off
  perform set_config('recruitment.candidate_email_recovery_active', 'off', true);

  -- Direct update again must FAIL
  begin
    update public.candidates set email = 'another_unauthorized@example.com' where candidate_id = v_cand_id;
    assert false, 'Direct update after resetting recovery flag must fail!';
  exception when sqlstate '23514' then
    assert sqlerrm like '%CANDIDATE_VERIFIED_EMAIL_IMMUTABLE%';
  end;

  raise notice 'Candidate email immutability and trusted recovery bypass PASS';

  raise notice '=== ALL PRE-S04 DATABASE INTEGRATION ASSERTIONS PASSED ===';
end;
$$;

-- -----------------------------------------------------------------------------
-- 12. Adversarial RLS Policy Tests
-- -----------------------------------------------------------------------------
-- Test A: Authenticated user with ONLY submissions.view CANNOT select Applications or Interviews
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);

do $$
declare
  v_app_count integer;
  v_int_count integer;
begin
  select count(*) into v_app_count from public.applications;
  assert v_app_count = 0, 'User with ONLY submissions.view must NOT see any rows in public.applications under RLS! Saw: ' || v_app_count;

  select count(*) into v_int_count from public.interviews;
  assert v_int_count = 0, 'User with ONLY submissions.view must NOT see any rows in public.interviews under RLS! Saw: ' || v_int_count;
end;
$$;
reset role;

-- Test B: User with applications.view CAN select Applications
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);

do $$
declare
  v_app_count integer;
  v_int_count integer;
begin
  select count(*) into v_app_count from public.applications;
  assert v_app_count > 0, 'User with applications.view must be able to select from public.applications! Saw: ' || v_app_count;

  select count(*) into v_int_count from public.interviews;
  assert v_int_count > 0, 'User with interviews.view must be able to select from public.interviews! Saw: ' || v_int_count;
end;
$$;
reset role;

-- Test C: Root Admin CAN select both
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);

do $$
declare
  v_app_count integer;
  v_int_count integer;
begin
  select count(*) into v_app_count from public.applications;
  assert v_app_count > 0, 'Root Admin must be able to select from public.applications! Saw: ' || v_app_count;

  select count(*) into v_int_count from public.interviews;
  assert v_int_count > 0, 'Root Admin must be able to select from public.interviews! Saw: ' || v_int_count;
end;
$$;
reset role;

select 'ALL PRE-S04 RLS AND INTEGRATION TESTS PASSED' as test_summary;
