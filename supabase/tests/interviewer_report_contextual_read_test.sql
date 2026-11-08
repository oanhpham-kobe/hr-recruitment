-- TASK-S05-001: contextual report read + owner-only mutation regressions.
\set ON_ERROR_STOP on

do $$
declare
  v_suffix text := substr(gen_random_uuid()::text, 1, 8);
  v_hr_auth uuid := gen_random_uuid();
  v_hr uuid;
  v_i1_auth uuid := gen_random_uuid();
  v_i1 uuid;
  v_i2_auth uuid := gen_random_uuid();
  v_i2 uuid;
  v_inactive_auth uuid := gen_random_uuid();
  v_inactive_user uuid;
  v_candidate_auth uuid := gen_random_uuid();
  v_candidate_id uuid;
  v_unit_id uuid;
  v_position_group_id uuid;
  v_position_id uuid;
  v_submission_id uuid;
  v_application_id uuid;
  v_old_interview_id uuid;
  v_current_interview_id uuid;
  v_old_p1 uuid;
  v_current_p1 uuid;
  v_current_p2 uuid;
  v_report1 uuid := gen_random_uuid();
  v_report2 uuid := gen_random_uuid();
  v_swap_report uuid;
  v_report_version bigint;
  v_result jsonb;
  v_visible_status text;
  v_status_code text;
  v_expected_status text;
  v_decision_timestamp timestamptz;
begin
  raise notice '=== TASK-S05-001 interviewer report contextual read ===';

  if v_report1 > v_report2 then
    v_swap_report := v_report1;
    v_report1 := v_report2;
    v_report2 := v_swap_report;
  end if;

  assert not has_function_privilege(
    'anon',
    'public.get_interviewer_report_page()',
    'EXECUTE'
  ), 'anon must not execute interviewer report read RPC';
  assert has_function_privilege(
    'authenticated',
    'public.get_interviewer_report_page()',
    'EXECUTE'
  ), 'authenticated may invoke contextual read RPC';
  assert not has_function_privilege(
    'anon',
    'public.save_own_interviewer_report(uuid,jsonb,bigint,jsonb)',
    'EXECUTE'
  ), 'anon must not execute owner-only report command';
  assert has_function_privilege(
    'authenticated',
    'public.save_own_interviewer_report(uuid,jsonb,bigint,jsonb)',
    'EXECUTE'
  ), 'authenticated may invoke owner-only report command';

  assert not has_schema_privilege(
    'anon',
    'interviewer_report_private',
    'USAGE'
  ), 'anon must not resolve privileged read helper schema';
  assert has_schema_privilege(
    'authenticated',
    'interviewer_report_private',
    'USAGE'
  ), 'authenticated wrapper may resolve bounded read helper schema';

  insert into public.organizational_units(code, name_vi, name_en)
  values ('S05001_U_' || v_suffix, 'Đơn vị S05', 'S05 Unit')
  returning public.organizational_units.unit_id into v_unit_id;

  insert into public.position_groups(code, name_vi, name_en)
  values ('S05001_PG_' || v_suffix, 'Nhóm S05', 'S05 Group')
  returning public.position_groups.position_group_id into v_position_group_id;

  insert into public.positions(
    unit_id,
    position_group_id,
    code,
    name_vi,
    name_en
  )
  values (
    v_unit_id,
    v_position_group_id,
    'S05001_P_' || v_suffix,
    'Giảng viên S05',
    'S05 Lecturer'
  )
  returning public.positions.position_id into v_position_id;

  insert into public.app_users(auth_user_id, full_name, email, is_active)
  values (
    v_hr_auth,
    'S05 HR',
    's05_hr_' || v_suffix || '@eiu.edu.vn',
    true
  )
  returning public.app_users.app_user_id into v_hr;

  -- S06-002 canonical active-Application owner eligibility requires the
  -- fixture HR owner to hold the HR role before the Application is inserted.
  insert into public.app_user_roles(app_user_id, role_code)
  values (v_hr, 'HR');

  insert into public.app_users(
    auth_user_id,
    full_name,
    email,
    job_title,
    is_active
  )
  values (
    v_i1_auth,
    'S05 Interviewer One',
    's05_i1_' || v_suffix || '@eiu.edu.vn',
    'Lecturer',
    true
  )
  returning public.app_users.app_user_id into v_i1;

  insert into public.app_users(
    auth_user_id,
    full_name,
    email,
    job_title,
    is_active
  )
  values (
    v_i2_auth,
    'S05 Interviewer Two',
    's05_i2_' || v_suffix || '@eiu.edu.vn',
    'Professor',
    true
  )
  returning public.app_users.app_user_id into v_i2;

  insert into public.app_users(auth_user_id, full_name, email, is_active)
  values (
    v_inactive_auth,
    'S05 Inactive',
    's05_inactive_' || v_suffix || '@eiu.edu.vn',
    true
  )
  returning public.app_users.app_user_id into v_inactive_user;

  insert into public.candidates(auth_user_id, email, is_active)
  values (
    v_candidate_auth,
    's05_candidate_' || v_suffix || '@example.com',
    true
  )
  returning public.candidates.candidate_id into v_candidate_id;

  insert into public.submissions(
    candidate_id,
    full_name,
    date_of_birth,
    gender_code,
    current_address,
    phone,
    email_snapshot,
    status_code
  )
  values (
    v_candidate_id,
    'S05 Candidate',
    '1990-01-01',
    'FEMALE',
    'S05 Address',
    '0900000000',
    's05_candidate_' || v_suffix || '@example.com',
    'PROCESSED'
  )
  returning public.submissions.submission_id into v_submission_id;

  insert into public.applications(
    submission_id,
    unit_id,
    position_id,
    hr_owner_id,
    is_active
  )
  values (
    v_submission_id,
    v_unit_id,
    v_position_id,
    v_hr,
    true
  )
  returning public.applications.application_id into v_application_id;

  insert into public.interviews(
    application_id,
    round_no,
    schedule_status_code,
    report_status_code,
    visible_to_interviewers,
    is_active
  )
  values (
    v_application_id,
    1,
    'AVAILABLE',
    'REPORT_SUBMITTED',
    true,
    true
  )
  returning public.interviews.interview_id into v_old_interview_id;

  insert into public.interviews(
    application_id,
    round_no,
    schedule_status_code,
    report_status_code,
    visible_to_interviewers,
    is_active
  )
  values (
    v_application_id,
    2,
    'AVAILABLE',
    'WAITING_FOR_REPORT',
    true,
    true
  )
  returning public.interviews.interview_id into v_current_interview_id;

  insert into public.interview_participants(
    interview_id,
    app_user_id,
    participant_order,
    snapshot_name,
    snapshot_job_title,
    snapshot_email,
    is_current
  )
  values (
    v_old_interview_id,
    v_i1,
    1,
    'S05 Interviewer One',
    'Lecturer',
    's05_i1_' || v_suffix || '@eiu.edu.vn',
    true
  )
  returning public.interview_participants.interview_participant_id into v_old_p1;

  insert into public.interview_participants(
    interview_id,
    app_user_id,
    participant_order,
    snapshot_name,
    snapshot_job_title,
    snapshot_email,
    is_current
  )
  values (
    v_current_interview_id,
    v_i1,
    1,
    'S05 Interviewer One',
    'Lecturer',
    's05_i1_' || v_suffix || '@eiu.edu.vn',
    true
  )
  returning public.interview_participants.interview_participant_id into v_current_p1;

  insert into public.interview_participants(
    interview_id,
    app_user_id,
    participant_order,
    snapshot_name,
    snapshot_job_title,
    snapshot_email,
    is_current
  )
  values (
    v_current_interview_id,
    v_i2,
    2,
    'S05 Interviewer Two',
    'Professor',
    's05_i2_' || v_suffix || '@eiu.edu.vn',
    true
  )
  returning public.interview_participants.interview_participant_id into v_current_p2;

  insert into public.interview_reports(
    interview_report_id,
    interview_participant_id,
    professional_knowledge,
    conclusion,
    created_by,
    updated_by
  )
  values (
    v_report1,
    v_current_p1,
    'Strong domain knowledge',
    'Primary decision',
    v_i1,
    v_i1
  );

  insert into public.interview_reports(
    interview_report_id,
    interview_participant_id,
    necessary_skills,
    expected_specific_job_assigned,
    created_by,
    updated_by
  )
  values (
    v_report2,
    v_current_p2,
    'Strong communication',
    'Newest decision job',
    v_i2,
    v_i2
  );

  insert into public.app_user_permissions(app_user_id, permission_code)
  select v_hr, p.permission_code
  from public.permissions p
  where p.permission_code in ('reports.view', 'reports.edit_interviewer')
  on conflict do nothing;

  perform set_config('request.jwt.claims', '{}'::jsonb::text, true);
  v_result := public.get_interviewer_report_page();
  assert v_result->>'error_code' = 'UNAUTHENTICATED',
    'missing auth identity fails closed';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_candidate_auth::text)::text,
    true
  );
  v_result := public.get_interviewer_report_page();
  assert v_result->>'error_code' = 'FORBIDDEN',
    'candidate identity cannot consume Interviewer report projection';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_i2_auth::text)::text,
    true
  );
  v_result := public.get_interviewer_report_page();
  assert (v_result->>'success')::boolean,
    'authorized participant request succeeds';
  assert jsonb_array_length(v_result->'data'->'rounds') = 1,
    'participant has no transitive historical-round access';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_i1_auth::text)::text,
    true
  );
  v_result := public.get_interviewer_report_page();
  assert (v_result->>'success')::boolean, 'Interviewer read succeeds';
  assert jsonb_array_length(v_result->'data'->'rounds') = 2,
    'new Current Round preserves direct historical participation read';
  assert (v_result->'data'->'rounds'->0->>'is_current_round')::boolean,
    'Current Round is server-derived and sorted first';
  assert not (v_result->'data'->'rounds'->1->>'can_edit')::boolean,
    'historical round remains read-only';

  assert position('hr_report_note' in v_result::text) = 0,
    'HR report note is absent from DTO';
  assert position('hr_owner' in v_result::text) = 0,
    'HR owner identity is absent from DTO';
  assert position('decision_updated_by' in v_result::text) = 0,
    'technical decision actor is absent from DTO';
  assert position('decision_updated_at' in v_result::text) = 0,
    'technical decision ordering metadata is absent from DTO';
  assert position('submission_id' in v_result::text) = 0,
    'Submission identity is absent from DTO';
  assert position('candidate_id' in v_result::text) = 0,
    'Candidate identity is absent from DTO';
  assert position('email_snapshot' in v_result::text) = 0,
    'Candidate email is absent from DTO';

  foreach v_status_code in array array[
    'INTERVIEW_SCHEDULING',
    'AWAITING_INTERVIEW',
    'WAITING_FOR_REPORT',
    'REPORT_SUBMITTED',
    'FOLLOW_UP',
    'ON_HOLD',
    'HIRED',
    'REJECTED'
  ]
  loop
    update public.interviews
    set report_status_code = v_status_code
    where public.interviews.interview_id = v_current_interview_id;

    v_result := public.get_interviewer_report_page();
    v_visible_status :=
      v_result->'data'->'rounds'->0->>'display_report_status';
    v_expected_status := case
      when v_status_code in ('FOLLOW_UP', 'ON_HOLD', 'HIRED')
        then 'REPORT_SUBMITTED'
      else v_status_code
    end;

    assert v_visible_status = v_expected_status,
      'Interviewer status projection matches canonical mapping';

    if v_status_code in ('HIRED', 'REJECTED') then
      assert not (v_result->'data'->'rounds'->0->>'can_edit')::boolean,
        'raw final status remains non-writable';
    else
      assert (v_result->'data'->'rounds'->0->>'can_edit')::boolean,
        'current non-final status remains writable';
    end if;
  end loop;

  update public.interviews
  set report_status_code = 'WAITING_FOR_REPORT'
  where public.interviews.interview_id = v_current_interview_id;

  assert (
    select r1.decision_updated_at = r2.decision_updated_at
    from public.interview_reports r1
    join public.interview_reports r2
      on r2.interview_report_id = v_report2
    where r1.interview_report_id = v_report1
  ), 'fixture starts with equal transaction-stable decision timestamps';

  v_result := public.get_interviewer_report_page();
  assert (
    v_result->'data'->'rounds'->0->'preview'->'final_decision'
      ->>'expected_specific_job_assigned'
  ) = 'Newest decision job',
    'equal-timestamp tie-break uses interview_report_id DESC';

  -- Test-only fixture setup bypasses only the decision-metadata trigger.
  -- Production trigger/function semantics are never modified.
  execute 'alter table public.interview_reports disable trigger a_report_decision_metadata_guard';
  update public.interview_reports
  set decision_updated_at = timestamptz '2099-01-02 00:00:00+00',
      decision_updated_by = v_i1
  where public.interview_reports.interview_report_id = v_report1;
  update public.interview_reports
  set decision_updated_at = timestamptz '2099-01-01 00:00:00+00',
      decision_updated_by = v_i2
  where public.interview_reports.interview_report_id = v_report2;
  execute 'alter table public.interview_reports enable trigger a_report_decision_metadata_guard';

  v_result := public.get_interviewer_report_page();
  assert (
    v_result->'data'->'rounds'->0->'preview'->'final_decision'
      ->>'conclusion'
  ) = 'Primary decision',
    'newer decision timestamp outranks larger report UUID';

  execute 'alter table public.interview_reports disable trigger a_report_decision_metadata_guard';
  update public.interview_reports
  set decision_updated_at = timestamptz '2099-01-03 00:00:00+00',
      decision_updated_by = v_i2
  where public.interview_reports.interview_report_id = v_report2;
  execute 'alter table public.interview_reports enable trigger a_report_decision_metadata_guard';

  select ir.decision_updated_at into v_decision_timestamp
  from public.interview_reports ir
  where ir.interview_report_id = v_report2;

  update public.interview_reports
  set necessary_skills = 'Qualitative edit only',
      updated_by = v_i2
  where public.interview_reports.interview_report_id = v_report2;

  assert (
    select ir.decision_updated_at = v_decision_timestamp
    from public.interview_reports ir
    where ir.interview_report_id = v_report2
  ), 'qualitative-only edit does not move decision timestamp';

  update public.interview_reports
  set expected_specific_job_assigned = null,
      updated_by = v_i2
  where public.interview_reports.interview_report_id = v_report2;

  v_result := public.get_interviewer_report_page();
  assert (
    v_result->'data'->'rounds'->0->'preview'->'final_decision'
      ->>'conclusion'
  ) = 'Primary decision',
    'clearing source decision fields falls back to next eligible report';

  update public.interview_reports
  set conclusion = null,
      expected_specific_job_assigned = null,
      expected_recruitment_time = null,
      updated_by = v_i1
  where public.interview_reports.interview_report_id = v_report1;

  v_result := public.get_interviewer_report_page();
  assert (
    v_result->'data'->'rounds'->0->'preview'->'final_decision'
      ->>'conclusion'
  ) is null
  and (
    v_result->'data'->'rounds'->0->'preview'->'final_decision'
      ->>'expected_specific_job_assigned'
  ) is null
  and (
    v_result->'data'->'rounds'->0->'preview'->'final_decision'
      ->>'expected_recruitment_time'
  ) is null,
    'no eligible source yields blank final decision block';

  -- HR edit-other authority remains on the accepted general command only.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_hr_auth::text)::text,
    true
  );
  select ir.version_no into v_report_version
  from public.interview_reports ir
  where ir.interview_report_id = v_report1;

  v_result := public.save_own_interviewer_report(
    v_current_p1,
    jsonb_build_object(
      'other_comment',
      'HR must not edit through owner command'
    ),
    v_report_version,
    jsonb_build_object('other_comment', null)
  );
  assert v_result->>'error_code' = 'FORBIDDEN',
    'HR edit-other authority cannot cross owner-only boundary';

  -- Successful pre-read followed by a state change must be rejected by the
  -- mutation-time owner-only command, not by a stale UI/server precheck.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_i1_auth::text)::text,
    true
  );
  v_result := public.get_interviewer_report_page();
  assert (v_result->'data'->'rounds'->0->>'can_edit')::boolean,
    'owner pre-read starts writable';

  update public.interviews
  set report_status_code = 'HIRED'
  where public.interviews.interview_id = v_current_interview_id;

  select ir.version_no into v_report_version
  from public.interview_reports ir
  where ir.interview_report_id = v_report1;

  v_result := public.save_own_interviewer_report(
    v_current_p1,
    jsonb_build_object(
      'strengths_limitations',
      'must not save after final state'
    ),
    v_report_version,
    jsonb_build_object('strengths_limitations', null)
  );
  assert v_result->>'error_code' = 'FORBIDDEN',
    'mutation-time owner guard rejects newly final target';

  update public.interviews
  set report_status_code = 'WAITING_FOR_REPORT'
  where public.interviews.interview_id = v_current_interview_id;

  v_result := public.save_own_interviewer_report(
    v_old_p1,
    jsonb_build_object('other_comment', 'historical write denied'),
    1,
    jsonb_build_object('other_comment', null)
  );
  assert v_result->>'error_code' = 'FORBIDDEN',
    'historical participant is not writable';

  select ir.version_no into v_report_version
  from public.interview_reports ir
  where ir.interview_report_id = v_report1;

  v_result := public.save_own_interviewer_report(
    v_current_p1,
    jsonb_build_object('strengths_limitations', 'Owner save succeeds'),
    v_report_version,
    jsonb_build_object('strengths_limitations', null)
  );
  assert (v_result->>'success')::boolean,
    'current contextual owner may save';

  update public.interview_participants
  set is_current = false,
      removed_at = clock_timestamp()
  where public.interview_participants.interview_participant_id = v_old_p1;
  v_result := public.get_interviewer_report_page();
  assert jsonb_array_length(v_result->'data'->'rounds') = 1,
    'removed participant loses exact historical access';

  update public.interviews
  set visible_to_interviewers = false
  where public.interviews.interview_id = v_current_interview_id;
  v_result := public.get_interviewer_report_page();
  assert jsonb_array_length(v_result->'data'->'rounds') = 0,
    'hidden current session fails closed';

  update public.interviews
  set visible_to_interviewers = true
  where public.interviews.interview_id = v_current_interview_id;
  update public.applications
  set is_active = false
  where public.applications.application_id = v_application_id;
  v_result := public.get_interviewer_report_page();
  assert jsonb_array_length(v_result->'data'->'rounds') = 0,
    'inactive Application is inaccessible';

  update public.applications
  set is_active = true
  where public.applications.application_id = v_application_id;
  update public.interviews
  set is_active = false
  where public.interviews.interview_id = v_current_interview_id;
  v_result := public.get_interviewer_report_page();
  assert jsonb_array_length(v_result->'data'->'rounds') = 0,
    'inactive Interview is inaccessible';

  update public.interviews
  set is_active = true
  where public.interviews.interview_id = v_current_interview_id;

  insert into public.interview_participants(
    interview_id,
    app_user_id,
    participant_order,
    snapshot_name,
    snapshot_email,
    is_current
  )
  values (
    v_current_interview_id,
    v_inactive_user,
    3,
    'S05 Inactive',
    's05_inactive_' || v_suffix || '@eiu.edu.vn',
    true
  );

  update public.app_users
  set is_active = false
  where public.app_users.app_user_id = v_inactive_user;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_inactive_auth::text)::text,
    true
  );
  v_result := public.get_interviewer_report_page();
  assert v_result->>'error_code' = 'USER_INACTIVE',
    'inactive internal caller fails closed';

  raise notice '=== TASK-S05-001 interviewer report regressions PASS ===';
end;
$$;
