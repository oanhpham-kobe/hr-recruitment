-- TASK-S05-002: HR Report read/mutation security and atomicity regressions.
\set ON_ERROR_STOP on

do $$
declare
  v_suffix text := substr(gen_random_uuid()::text, 1, 8);
  v_hr_auth uuid := gen_random_uuid();
  v_hr uuid;
  v_status_auth uuid := gen_random_uuid();
  v_status_user uuid;
  v_interviewer_auth uuid := gen_random_uuid();
  v_interviewer uuid;
  v_candidate_auth uuid := gen_random_uuid();
  v_candidate uuid;
  v_unit uuid;
  v_group uuid;
  v_position_1 uuid;
  v_position_2 uuid;
  v_format uuid;
  v_submission uuid;
  v_application_1 uuid;
  v_application_2 uuid;
  v_round_1 uuid;
  v_current_1 uuid;
  v_inactive_newer uuid;
  v_current_2 uuid;
  v_participant_1 uuid;
  v_participant_2 uuid;
  v_report_1 uuid;
  v_result jsonb;
  v_v1 bigint;
  v_v2 bigint;
  v_report_version bigint;
begin
  raise notice '=== TASK-S05-002 HR Report management ===';

  assert not has_function_privilege(
    'anon',
    'public.get_hr_report_page(integer,integer,text,text,text,text)',
    'EXECUTE'
  ), 'anon must not execute HR Report read RPC';
  assert has_function_privilege(
    'authenticated',
    'public.get_hr_report_page(integer,integer,text,text,text,text)',
    'EXECUTE'
  ), 'authenticated may invoke HR Report read RPC; server authz remains authoritative';
  assert not has_function_privilege(
    'anon',
    'public.set_report_visibility(uuid,boolean,bigint)',
    'EXECUTE'
  ), 'anon must not execute report visibility command';
  assert has_function_privilege(
    'authenticated',
    'public.set_report_visibility(uuid,boolean,bigint)',
    'EXECUTE'
  ), 'authenticated may invoke visibility command subject to permission checks';
  assert not has_function_privilege(
    'anon',
    'public.bulk_change_report_status(uuid[],text,bigint[])',
    'EXECUTE'
  ), 'anon must not execute report bulk status command';

  insert into public.organizational_units(code, name_vi, name_en)
  values ('S05002_U_' || v_suffix, 'Đơn vị S05-002', 'S05-002 Unit')
  returning unit_id into v_unit;

  insert into public.position_groups(code, name_vi, name_en)
  values ('S05002_PG_' || v_suffix, 'Nhóm S05-002', 'S05-002 Group')
  returning position_group_id into v_group;

  insert into public.positions(unit_id, position_group_id, code, name_vi, name_en)
  values (v_unit, v_group, 'S05002_P1_' || v_suffix, 'Giảng viên A', 'Lecturer A')
  returning position_id into v_position_1;

  insert into public.positions(unit_id, position_group_id, code, name_vi, name_en)
  values (v_unit, v_group, 'S05002_P2_' || v_suffix, 'Giảng viên B', 'Lecturer B')
  returning position_id into v_position_2;

  insert into public.interview_formats(
    code, name_vi, name_en, requires_room, requires_meeting_link, is_active
  ) values (
    'S05002_FMT_' || v_suffix, 'Khác', 'Other', false, false, true
  ) returning interview_format_id into v_format;

  insert into public.app_users(auth_user_id, full_name, email, is_active)
  values (v_hr_auth, 'S05-002 HR', 's05002_hr_' || v_suffix || '@eiu.edu.vn', true)
  returning app_user_id into v_hr;

  -- S06-002 canonical active-Application owner eligibility requires the
  -- fixture HR owner to hold the HR role before active Applications exist.
  insert into public.app_user_roles(app_user_id, role_code)
  values (v_hr, 'HR');

  insert into public.app_users(auth_user_id, full_name, email, is_active)
  values (v_status_auth, 'S05-002 Status Only', 's05002_status_' || v_suffix || '@eiu.edu.vn', true)
  returning app_user_id into v_status_user;

  insert into public.app_users(auth_user_id, full_name, email, job_title, is_active)
  values (v_interviewer_auth, 'S05-002 Interviewer', 's05002_i_' || v_suffix || '@eiu.edu.vn', 'Lecturer', true)
  returning app_user_id into v_interviewer;

  insert into public.app_user_permissions(app_user_id, permission_code)
  select v_hr, p.permission_code
  from public.permissions p
  where p.permission_code in (
    'reports.view',
    'reports.manage_status',
    'reports.visibility',
    'reports.edit_interviewer',
    'reports.delete'
  )
  on conflict do nothing;

  insert into public.app_user_permissions(app_user_id, permission_code)
  select v_status_user, p.permission_code
  from public.permissions p
  where p.permission_code = 'reports.manage_status'
  on conflict do nothing;

  insert into public.candidates(auth_user_id, email, is_active)
  values (v_candidate_auth, 's05002_candidate_' || v_suffix || '@example.com', true)
  returning candidate_id into v_candidate;

  insert into public.submissions(
    candidate_id,
    full_name,
    date_of_birth,
    gender_code,
    current_address,
    phone,
    email_snapshot,
    status_code
  ) values (
    v_candidate,
    'S05-002 Candidate',
    date '1992-01-01',
    'FEMALE',
    'S05-002 Address',
    '0900000001',
    's05002_candidate_' || v_suffix || '@example.com',
    'PROCESSED'
  ) returning submission_id into v_submission;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_submission, v_unit, v_position_1, v_hr, true)
  returning application_id into v_application_1;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_submission, v_unit, v_position_2, v_hr, true)
  returning application_id into v_application_2;

  insert into public.interviews(
    application_id, round_no, start_at, end_at, interview_format_id,
    schedule_status_code, report_status_code,
    hr_report_note, visible_to_interviewers, is_active
  ) values (
    v_application_1, 1,
    timestamptz '2026-09-08 02:00:00+00', timestamptz '2026-09-08 03:00:00+00',
    v_format,
    'CONFIRMED', 'REPORT_SUBMITTED', 'Historical note', true, true
  ) returning interview_id into v_round_1;

  insert into public.interviews(
    application_id, round_no, start_at, end_at, interview_format_id,
    schedule_status_code, report_status_code,
    hr_report_note, visible_to_interviewers, is_active
  ) values (
    v_application_1, 2,
    timestamptz '2026-09-09 02:00:00+00', timestamptz '2026-09-09 03:00:00+00',
    v_format,
    'CONFIRMED', 'WAITING_FOR_REPORT', 'Current HR note', true, true
  ) returning interview_id into v_current_1;

  -- A numerically newer but inactive round must never become HR Report current.
  insert into public.interviews(
    application_id, round_no, schedule_status_code, report_status_code,
    hr_report_note, visible_to_interviewers, is_active
  ) values (
    v_application_1, 3, 'AVAILABLE', 'HIRED', 'Inactive note', false, false
  ) returning interview_id into v_inactive_newer;

  insert into public.interviews(
    application_id, round_no, start_at, end_at, interview_format_id,
    schedule_status_code, report_status_code,
    hr_report_note, visible_to_interviewers, is_active
  ) values (
    v_application_2, 1,
    timestamptz '2026-09-10 02:00:00+00', timestamptz '2026-09-10 03:00:00+00',
    v_format,
    'CONFIRMED', 'AWAITING_INTERVIEW', null, false, true
  ) returning interview_id into v_current_2;

  insert into public.interview_participants(
    interview_id, app_user_id, participant_order,
    snapshot_name, snapshot_job_title, snapshot_email, is_current
  ) values (
    v_current_1, v_interviewer, 1,
    'S05-002 Interviewer', 'Lecturer',
    's05002_i_' || v_suffix || '@eiu.edu.vn', true
  ) returning interview_participant_id into v_participant_1;

  insert into public.interview_participants(
    interview_id, app_user_id, participant_order,
    snapshot_name, snapshot_job_title, snapshot_email, is_current
  ) values (
    v_current_2, v_interviewer, 1,
    'S05-002 Interviewer', 'Lecturer',
    's05002_i_' || v_suffix || '@eiu.edu.vn', true
  ) returning interview_participant_id into v_participant_2;

  insert into public.interview_reports(
    interview_participant_id,
    professional_knowledge,
    conclusion,
    created_by,
    updated_by
  ) values (
    v_participant_1,
    'Strong domain knowledge',
    'Proceed',
    v_interviewer,
    v_interviewer
  ) returning interview_report_id, version_no into v_report_1, v_report_version;

  perform set_config('request.jwt.claims', '{}'::jsonb::text, true);
  v_result := public.get_hr_report_page(1, 20, null, 'ALL', null, 'CANDIDATE_ASC');
  assert v_result->>'error_code' = 'UNAUTHENTICATED',
    'HR read fails closed without auth identity';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_status_auth::text)::text,
    true
  );
  v_result := public.get_hr_report_page(1, 20, null, 'ALL', null, 'CANDIDATE_ASC');
  assert v_result->>'error_code' = 'FORBIDDEN',
    'reports.manage_status without reports.view cannot read HR Report data';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_hr_auth::text)::text,
    true
  );
  v_result := public.get_hr_report_page(
    1, 20, null, 'ALL', 'S05-002 Candidate', 'CANDIDATE_ASC'
  );
  assert (v_result->>'success')::boolean, 'authorized HR Report read succeeds';
  assert (v_result->'data'->>'total')::integer = 2,
    'one aggregate row is returned for each Application with a Current Round';
  assert jsonb_array_length(v_result->'data'->'rows') = 2,
    'page contains two Application rows';
  assert exists (
    select 1
    from jsonb_array_elements(v_result->'data'->'rows') row_value
    where row_value->>'application_id' = v_application_1::text
      and row_value->>'interview_id' = v_current_1::text
      and (row_value->>'round_no')::integer = 2
      and row_value->>'report_status_code' = 'WAITING_FOR_REPORT'
      and row_value->>'hr_report_note' = 'Current HR note'
  ), 'HR projection uses authoritative active Current Round and raw status';
  assert position(v_inactive_newer::text in v_result::text) = 0,
    'inactive historical/newer Interview is never used as Current Round fallback';
  assert position('submission_id' in v_result::text) = 0,
    'minimum-safe HR DTO does not expose Submission technical identity';
  assert position('candidate_id' in v_result::text) = 0,
    'minimum-safe HR DTO does not expose Candidate technical identity';
  assert position('email_snapshot' in v_result::text) = 0,
    'minimum-safe HR DTO does not expose Candidate email snapshot';
  assert position('Strong domain knowledge' in v_result::text) > 0,
    'authorized HR drawer projection includes participant qualitative report';
  assert position('Proceed' in v_result::text) > 0,
    'authorized HR drawer projection reuses accepted Final Decision Source';

  v_result := public.get_hr_report_page(
    1, 20, 'WAITING_FOR_REPORT', 'VISIBLE', 'S05-002 Candidate', 'CANDIDATE_ASC'
  );
  assert (v_result->'data'->>'total')::integer = 1,
    'status + visibility + search filters apply at Application-group level';

  select version_no into v_v1 from public.interviews where interview_id = v_current_1;
  v_result := public.set_report_visibility(v_current_1, false, v_v1);
  assert (v_result->>'success')::boolean,
    'reports.visibility + reports.view may change current visibility';
  assert not (select visible_to_interviewers from public.interviews where interview_id = v_current_1),
    'visibility command mutates only the visibility flag';
  assert (select report_status_code from public.interviews where interview_id = v_current_1) = 'WAITING_FOR_REPORT',
    'visibility command does not change report status';
  assert (select hr_report_note from public.interviews where interview_id = v_current_1) = 'Current HR note',
    'visibility command does not change HR note';
  assert (select professional_knowledge from public.interview_reports where interview_report_id = v_report_1) = 'Strong domain knowledge',
    'visibility command does not mutate participant report content';

  select version_no into v_v1 from public.interviews where interview_id = v_round_1;
  v_result := public.set_report_visibility(v_round_1, false, v_v1);
  assert v_result->>'error_code' = 'LATEST_ROUND_REQUIRED',
    'visibility command rejects historical Interview targets';

  select version_no into v_v1 from public.interviews where interview_id = v_current_1;
  select version_no into v_v2 from public.interviews where interview_id = v_current_2;
  v_result := public.bulk_change_report_status(
    array[v_current_2, v_current_1],
    'FOLLOW_UP',
    array[v_v2, v_v1]
  );
  assert (v_result->>'success')::boolean,
    'bulk report status accepts unsorted input and executes atomically';
  assert (select report_status_code from public.interviews where interview_id = v_current_1) = 'FOLLOW_UP',
    'bulk report status updates first target';
  assert (select report_status_code from public.interviews where interview_id = v_current_2) = 'FOLLOW_UP',
    'bulk report status updates second target';

  select version_no into v_v1 from public.interviews where interview_id = v_current_1;
  select version_no into v_v2 from public.interviews where interview_id = v_current_2;
  v_result := public.bulk_change_report_status(
    array[v_current_1, v_current_2],
    'ON_HOLD',
    array[v_v1, v_v2 - 1]
  );
  assert v_result->>'error_code' = 'STALE_VERSION',
    'one stale target rejects the full bulk command';
  assert (select report_status_code from public.interviews where interview_id = v_current_1) = 'FOLLOW_UP',
    'all-or-nothing preflight prevents partial write before stale target';
  assert (select report_status_code from public.interviews where interview_id = v_current_2) = 'FOLLOW_UP',
    'stale bulk target remains unchanged';

  v_result := public.bulk_change_report_status(
    array_fill(v_current_1, array[101]),
    'ON_HOLD',
    array_fill(v_v1, array[101])
  );
  assert v_result->>'error_code' = 'VALIDATION_ERROR',
    'bulk report status rejects input above 100 items';

  -- reports.manage_status + reports.view must no longer authorize report deletion.
  insert into public.app_user_permissions(app_user_id, permission_code)
  select v_status_user, p.permission_code
  from public.permissions p
  where p.permission_code = 'reports.view'
  on conflict do nothing;
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_status_auth::text)::text,
    true
  );
  v_result := public.delete_or_inactivate_report(v_report_1, v_report_version);
  assert v_result->>'error_code' = 'FORBIDDEN',
    'reports.manage_status + reports.view cannot delete/inactivate participant report';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_hr_auth::text)::text,
    true
  );
  select version_no into v_report_version
  from public.interview_reports where interview_report_id = v_report_1;
  v_result := public.delete_or_inactivate_report(v_report_1, v_report_version);
  assert (v_result->>'success')::boolean,
    'reports.delete + reports.view authorizes report-specific delete/inactivate';
  assert not (select is_active from public.interview_reports where interview_report_id = v_report_1),
    'used participant report is inactivated rather than hard-deleted';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_interviewer_auth::text)::text,
    true
  );
  v_result := public.get_interviewer_report_page();
  assert position('hr_report_note' in v_result::text) = 0,
    'S05-002 does not widen accepted Interviewer contextual DTO';

  raise notice 'TASK-S05-002 HR Report management assertions passed';
end;
$$;