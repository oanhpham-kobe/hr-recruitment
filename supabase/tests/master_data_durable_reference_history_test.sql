-- TASK-S06-001 R3: durable ever-reference history across replaceable semantic FK paths.
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_suffix text := substr(gen_random_uuid()::text, 1, 8);
  v_hr_auth uuid := gen_random_uuid();
  v_hr uuid;
  v_candidate_auth uuid := gen_random_uuid();
  v_candidate uuid;
  v_unit uuid;
  v_unit2 uuid;
  v_group uuid;
  v_group2 uuid;
  v_position uuid;
  v_position_unreferenced uuid;
  v_qualification uuid;
  v_qualification_rollback uuid;
  v_room_a uuid;
  v_room_b uuid;
  v_format_a uuid;
  v_format_b uuid;
  v_source uuid;
  v_submission uuid;
  v_submission2 uuid;
  v_application uuid;
  v_interview uuid;
  v_cv_type uuid;
  v_cv_logical uuid;
  v_session uuid;
  v_notice text;
  v_version bigint;
  v_result jsonb;
begin
  raise notice '=== TASK-S06-001 durable semantic reference history ===';

  insert into public.app_users(auth_user_id, email, full_name, is_active)
  values (v_hr_auth, 's06001_hist_' || v_suffix || '@eiu.edu.vn', 'S06 History HR', true)
  returning app_user_id into v_hr;

  insert into public.app_user_roles(app_user_id, role_code)
  values (v_hr, 'HR')
  on conflict do nothing;

  insert into public.app_user_permissions(app_user_id, permission_code)
  values
    (v_hr, 'master_data.manage'),
    (v_hr, 'interviews.manage'),
    (v_hr, 'interviews.view'),
    (v_hr, 'interviews.status')
  on conflict do nothing;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth::text)::text, true);

  v_result := public.create_master_item(
    'organizational_units',
    jsonb_build_object('code','HIST_UNIT_' || v_suffix,'name_vi','History Unit'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_unit := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'organizational_units',
    jsonb_build_object('code','HIST_UNIT2_' || v_suffix,'name_vi','History Unit 2'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_unit2 := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'position_groups',
    jsonb_build_object('code','HIST_GROUP_' || v_suffix,'name_vi','History Group'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_group := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'position_groups',
    jsonb_build_object('code','HIST_GROUP2_' || v_suffix,'name_vi','History Group 2'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_group2 := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'positions',
    jsonb_build_object(
      'unit_id',v_unit,
      'position_group_id',v_group,
      'code','HIST_POS_' || v_suffix,
      'name_vi','History Position'
    ),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_position := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'qualification_levels',
    jsonb_build_object('code','HIST_QUAL_' || v_suffix,'name_vi','History Qualification'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_qualification := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'rooms',
    jsonb_build_object('code','HIST_ROOM_A_' || v_suffix,'display_name','History Room A','building','A'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_room_a := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'rooms',
    jsonb_build_object('code','HIST_ROOM_B_' || v_suffix,'display_name','History Room B','building','B'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_room_b := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'interview_formats',
    jsonb_build_object(
      'code','HIST_FMT_A_' || v_suffix,'name_vi','History Format A',
      'requires_room',true,'requires_meeting_link',false
    ),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_format_a := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'interview_formats',
    jsonb_build_object(
      'code','HIST_FMT_B_' || v_suffix,'name_vi','History Format B',
      'requires_room',true,'requires_meeting_link',false
    ),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_format_b := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'recruitment_sources',
    jsonb_build_object('code','HIST_SRC_' || v_suffix,'name_vi','History Source'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_source := (v_result->'data'->>'master_id')::uuid;

  insert into public.candidates(auth_user_id, email, is_active)
  values (v_candidate_auth, 's06001_hist_candidate_' || v_suffix || '@example.com', true)
  returning candidate_id into v_candidate;

  -- Candidate EDIT requires a current effective privacy notice.
  update public.privacy_notice_versions set is_current = false where is_current = true;
  insert into public.privacy_notice_versions(
    notice_version, content_vi, content_en, content_hash_sha256,
    published_at, effective_from, is_current, created_by
  ) values (
    'S06001_HIST_' || v_suffix,
    'S06 durable history notice',
    'S06 durable history notice',
    repeat('d',64),
    clock_timestamp() - interval '1 minute',
    clock_timestamp() - interval '1 minute',
    true,
    v_hr
  );

  insert into public.submissions(
    candidate_id, status_code, full_name, date_of_birth, gender_code,
    current_address, phone, email_snapshot, recruitment_source_id
  ) values (
    v_candidate, 'NEW', 'History Candidate', date '1990-01-01', 'MALE',
    'Address', '0900000000', 's06001_hist_candidate_' || v_suffix || '@example.com', v_source
  ) returning submission_id into v_submission;

  insert into public.submission_education(
    submission_id, sort_order, period_text, qualification_id, major, institution
  ) values (
    v_submission, 1, '2008-2012', v_qualification, 'Testing', 'EIU'
  );

  select document_type_id into v_cv_type
  from public.document_types
  where code = 'CV_RESUME' and is_active = true;
  assert v_cv_type is not null;

  insert into public.submission_document_logicals(submission_id, document_type_id, created_by_candidate_id)
  values (v_submission, v_cv_type, v_candidate)
  returning logical_document_id into v_cv_logical;
  insert into public.submission_documents(
    logical_document_id, storage_bucket, storage_path, original_filename,
    mime_type, file_size_bytes, version_no, is_current, uploaded_by_candidate_id
  ) values (
    v_cv_logical, 'candidate-documents', 's06/durable/' || v_suffix || '/cv.pdf',
    'cv.pdf', 'application/pdf', 512, 1, true, v_candidate
  );

  -- Proven reviewer blocker: trusted Candidate edit deletes/rebuilds education.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_candidate_auth::text)::text, true);
  v_result := public.start_candidate_form_session('EDIT_SUBMISSION', v_submission);
  assert (v_result->>'success')::boolean, 'candidate EDIT session opens';
  v_session := (v_result->'data'->>'candidate_form_session_id')::uuid;
  v_notice := v_result->'data'->>'presented_privacy_notice_version';

  v_result := public.update_candidate_submission(
    v_session,
    'History Candidate',
    '0900000000',
    date '1990-01-01',
    'MALE',
    'Address',
    '[]'::jsonb,
    v_notice,
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'trusted Candidate edit removes education row';
  assert not exists (
    select 1 from public.submission_education
    where submission_id = v_submission and qualification_id = v_qualification
  ), 'old qualification FK evidence is gone from current child rows';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth::text)::text, true);
  assert exists (
    select 1 from private.master_reference_history
    where master_type = 'qualification_levels' and master_id = v_qualification
  ), 'qualification first-use survives Candidate education rebuild';

  select version_no into v_version
  from public.qualification_levels where qualification_id = v_qualification;
  v_result := public.update_master_item(
    'qualification_levels', v_qualification,
    jsonb_build_object('code','HIST_QUAL_REPURPOSE_' || v_suffix),
    v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY',
    'formerly selected Qualification cannot be structurally repurposed';

  select version_no into v_version
  from public.qualification_levels where qualification_id = v_qualification;
  v_result := public.delete_or_inactivate_master_item(
    'qualification_levels', v_qualification, v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'formerly selected Qualification is retained inactive rather than hard-deleted';

  -- Recruitment Source is another replaceable semantic Submission reference.
  update public.submissions set recruitment_source_id = null where submission_id = v_submission;
  assert exists (
    select 1 from private.master_reference_history
    where master_type = 'recruitment_sources' and master_id = v_source
  ), 'replaced Recruitment Source remains durable history';
  select version_no into v_version from public.recruitment_sources where recruitment_source_id = v_source;
  v_result := public.delete_or_inactivate_master_item(
    'recruitment_sources', v_source, v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'formerly selected Recruitment Source cannot hard-delete';

  -- Accepted Interview schedule/reschedule replacement must retain prior Format/Room identity.
  insert into public.submissions(
    candidate_id, status_code, full_name, date_of_birth, gender_code,
    current_address, phone, email_snapshot
  ) values (
    v_candidate, 'PROCESSED', 'History Interview Candidate', date '1990-01-01', 'MALE',
    'Address', '0900000001', 's06001_hist_interview_' || v_suffix || '@example.com'
  ) returning submission_id into v_submission2;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_submission2, v_unit, v_position, v_hr, true)
  returning application_id into v_application;

  insert into public.interviews(
    application_id, round_no, schedule_status_code, report_status_code, is_active
  ) values (
    v_application, 1, 'CANCELLED', 'INTERVIEW_SCHEDULING', true
  ) returning interview_id into v_interview;

  select version_no into v_version from public.interviews where interview_id = v_interview;
  v_result := public.save_interview_schedule(
    v_interview,
    timestamptz '2026-09-25 02:00:00+00',
    timestamptz '2026-09-25 03:00:00+00',
    v_format_a,
    v_room_a,
    null,
    null,
    'first schedule',
    v_version,
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'first trusted schedule uses Format/Room A';

  select version_no into v_version from public.interviews where interview_id = v_interview;
  v_result := public.save_interview_schedule(
    v_interview,
    timestamptz '2026-09-26 02:00:00+00',
    timestamptz '2026-09-26 03:00:00+00',
    v_format_b,
    v_room_b,
    null,
    null,
    'replacement schedule',
    v_version,
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'trusted reschedule replaces Format/Room A with B';
  assert (select interview_format_id from public.interviews where interview_id = v_interview) = v_format_b;
  assert (select room_id from public.interviews where interview_id = v_interview) = v_room_b;

  assert exists (
    select 1 from private.master_reference_history
    where master_type = 'interview_formats' and master_id = v_format_a
  ), 'prior Interview Format A remains durable history after reschedule';
  assert exists (
    select 1 from private.master_reference_history
    where master_type = 'rooms' and master_id = v_room_a
  ), 'prior Room A remains durable history after reschedule';

  select version_no into v_version from public.interview_formats where interview_format_id = v_format_a;
  v_result := public.update_master_item(
    'interview_formats', v_format_a,
    jsonb_build_object('code','HIST_FMT_REPURPOSE_' || v_suffix),
    v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY',
    'prior Interview Format cannot be structurally repurposed after reschedule';
  select version_no into v_version from public.interview_formats where interview_format_id = v_format_a;
  v_result := public.delete_or_inactivate_master_item(
    'interview_formats', v_format_a, v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'prior Interview Format is retained inactive';

  select version_no into v_version from public.rooms where room_id = v_room_a;
  v_result := public.update_master_item(
    'rooms', v_room_a,
    jsonb_build_object('code','HIST_ROOM_REPURPOSE_' || v_suffix),
    v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY',
    'prior Room cannot be structurally repurposed after reschedule';
  select version_no into v_version from public.rooms where room_id = v_room_a;
  v_result := public.delete_or_inactivate_master_item(
    'rooms', v_room_a, v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'prior Room is retained inactive';

  -- Master-to-master replacement is durable too: old Position Group history is
  -- preserved even when an otherwise-unused Position is structurally moved.
  v_result := public.create_master_item(
    'positions',
    jsonb_build_object(
      'unit_id',v_unit2,
      'position_group_id',v_group,
      'code','HIST_POS_UNUSED_' || v_suffix,
      'name_vi','Unused Position'
    ),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_position_unreferenced := (v_result->'data'->>'master_id')::uuid;
  select version_no into v_version from public.positions where position_id = v_position_unreferenced;
  v_result := public.update_master_item(
    'positions', v_position_unreferenced,
    jsonb_build_object('position_group_id',v_group2),
    v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'unreferenced Position may move to another active Position Group';
  assert exists (
    select 1 from private.master_reference_history
    where master_type = 'position_groups' and master_id = v_group
  ), 'prior master-to-master Position Group reference remains durable';

  -- Atomic rollback: history written by a semantic-holder trigger must roll back
  -- with the holder mutation and must not create a false ever-used marker.
  v_result := public.create_master_item(
    'qualification_levels',
    jsonb_build_object('code','HIST_ROLLBACK_' || v_suffix,'name_vi','Rollback Qualification'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_qualification_rollback := (v_result->'data'->>'master_id')::uuid;

  begin
    insert into public.submission_education(
      submission_id, sort_order, period_text, qualification_id, major, institution
    ) values (
      v_submission, 99, 'rollback', v_qualification_rollback, 'Rollback', 'Rollback'
    );
    raise exception 'FORCE_HISTORY_ROLLBACK';
  exception when others then
    null;
  end;

  assert not exists (
    select 1 from private.master_reference_history
    where master_type = 'qualification_levels' and master_id = v_qualification_rollback
  ), 'rolled-back holder write leaves no false durable history marker';
  assert not exists (
    select 1 from public.submission_education
    where submission_id = v_submission and qualification_id = v_qualification_rollback
  ), 'rolled-back holder row is absent';
  select version_no into v_version
  from public.qualification_levels where qualification_id = v_qualification_rollback;
  v_result := public.delete_or_inactivate_master_item(
    'qualification_levels', v_qualification_rollback, v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'DELETED',
    'rollback-only reference does not falsely block legitimate hard delete';

  -- Audit coverage: every durable semantic holder inventoried by the repair has
  -- the closed trigger installed; temporary upload/staging tables are excluded.
  assert (
    select count(distinct c.relname) = 9
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and t.tgname = 's06_master_reference_history_capture'
      and not t.tgisinternal
      and c.relname in (
        'department_teams','positions','applications','app_users',
        'submission_education','submissions','interviews',
        'submission_document_logicals','interview_document_logicals'
      )
  ), 'all nine durable semantic-holder tables have history capture triggers';

  assert not has_table_privilege('authenticated', 'private.master_reference_history', 'SELECT'),
    'authenticated cannot inspect private durable history directly';
  assert not has_function_privilege('authenticated', 'private.record_master_reference_history(text,uuid,boolean)', 'EXECUTE'),
    'authenticated cannot execute private durable history recorder';
end;
$$;

rollback;
