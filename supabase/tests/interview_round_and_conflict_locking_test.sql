-- =============================================================================
-- TASK-S04-001: Interview Round, Schedule Schema, Conflict Locking & Participants Test
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_unit_id uuid;
  v_pg_id uuid;
  v_pos_id uuid;
  v_cand_id uuid;
  v_cand_auth_id uuid := gen_random_uuid();
  v_hr_id uuid;
  v_hr_auth_id uuid := gen_random_uuid();
  v_interviewer1_id uuid;
  v_interviewer1_auth_id uuid := gen_random_uuid();
  v_interviewer2_id uuid;
  v_interviewer2_auth_id uuid := gen_random_uuid();
  v_inactive_user_id uuid;
  v_sub_id uuid;
  v_app_id uuid;
  v_int1_id uuid;
  v_int2_id uuid;
  v_format_room_id uuid;
  v_room_id uuid;
  v_part1_id uuid;
  v_part2_id uuid;
  v_round_idempotency_key uuid := gen_random_uuid();
  v_fixture_suffix text := substr(gen_random_uuid()::text, 1, 8);
  v_rpc_res jsonb;
  v_conflicts_res jsonb;
  v_count integer;
  v_version bigint;
  v_versions bigint[];
  v_err_thrown boolean;
begin
  raise notice '=== Running TASK-S04-001 Test Suite ===';

  -- ---------------------------------------------------------------------------
  -- 1. Setup Test Fixtures: Master Data & Users
  -- ---------------------------------------------------------------------------
  insert into public.organizational_units (name_vi, code)
  values ('S04 Test Unit', 'S04_UNIT_' || substr(gen_random_uuid()::text, 1, 8))
  returning unit_id into v_unit_id;

  insert into public.position_groups (name_vi, code)
  values ('S04 Test PG', 'S04_PG_' || substr(gen_random_uuid()::text, 1, 8))
  returning position_group_id into v_pg_id;

  insert into public.positions (unit_id, position_group_id, code, name_vi)
  values (v_unit_id, v_pg_id, 'S04_POS_' || substr(gen_random_uuid()::text, 1, 8), 'S04 Test Position')
  returning position_id into v_pos_id;

  insert into public.rooms (code, display_name, building, is_active)
  values ('ROOM_S04_' || substr(gen_random_uuid()::text, 1, 8), 'Phòng Test S04', 'Building S04', true)
  returning room_id into v_room_id;
  insert into public.interview_formats (code, name_vi, requires_room, requires_meeting_link, is_active)
  values ('IN_PERSON_S04_' || substr(gen_random_uuid()::text, 1, 8), 'In Person S04', true, false, true)
  returning interview_format_id into v_format_room_id;

  -- Create HR User
  insert into public.app_users (auth_user_id, full_name, email, is_active, is_root_admin)
  values (v_hr_auth_id, 'S04 HR Manager', 's04_hr_' || v_fixture_suffix || '@eiu.edu.vn', true, false)
  returning app_user_id into v_hr_id;

  insert into public.app_user_roles (app_user_id, role_code)
  values (v_hr_id, 'HR');

  -- Grant required permissions to HR
  insert into public.app_user_permissions (app_user_id, permission_code)
  values
    (v_hr_id, 'interviews.view'),
    (v_hr_id, 'interviews.manage'),
    (v_hr_id, 'interviews.participants'),
    (v_hr_id, 'interviews.status'),
    (v_hr_id, 'applications.view'),
    (v_hr_id, 'submissions.view')
  on conflict do nothing;

  -- Create Interviewers
  insert into public.app_users (auth_user_id, full_name, email, job_title, is_active, is_root_admin)
  values (v_interviewer1_auth_id, 'Prof Alpha', 'alpha_' || v_fixture_suffix || '@eiu.edu.vn', 'Senior Lecturer', true, false)
  returning app_user_id into v_interviewer1_id;

  insert into public.app_users (auth_user_id, full_name, email, job_title, is_active, is_root_admin)
  values (v_interviewer2_auth_id, 'Prof Beta', 'beta_' || v_fixture_suffix || '@eiu.edu.vn', 'Associate Professor', true, false)
  returning app_user_id into v_interviewer2_id;

  insert into public.app_users (auth_user_id, full_name, email, is_active, is_root_admin)
  values (gen_random_uuid(), 'Inactive User', 'inactive_' || v_fixture_suffix || '@eiu.edu.vn', false, false)
  returning app_user_id into v_inactive_user_id;

  -- Create Candidate, Submission, Application
  insert into public.candidates (auth_user_id, current_full_name, email, is_active)
  values (v_cand_auth_id, 'Candidate Nguyen S04', 'nguyen_s04_' || v_fixture_suffix || '@example.com', true)
  returning candidate_id into v_cand_id;

  insert into public.submissions (
    candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code
  ) values (
    v_cand_id, 'Candidate Nguyen S04', '1995-05-15', 'MALE', '123 EIU Street', '0901234567', 'nguyen_s04_' || v_fixture_suffix || '@example.com', 'PROCESSED'
  )
  returning submission_id into v_sub_id;

  insert into public.applications (submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub_id, v_unit_id, v_pos_id, v_hr_id, true)
  returning application_id into v_app_id;

  -- ---------------------------------------------------------------------------
  -- 2. Test Round Creation via RPC (create_next_interview_round)
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth_id::text)::text, true);

  v_rpc_res := public.create_next_interview_round(v_app_id, v_round_idempotency_key);
  assert (v_rpc_res ->> 'success')::boolean = true, 'create_next_interview_round should succeed for round 1';
  v_int1_id := (v_rpc_res -> 'data' ->> 'interview_id')::uuid;
  assert (v_rpc_res -> 'data' ->> 'round_no')::integer = 1, 'first round should be 1';
  assert (v_rpc_res -> 'data' ->> 'schedule_status_code') = 'AVAILABLE', 'initial status should be AVAILABLE';
  assert (v_rpc_res -> 'data' ->> 'report_status_code') = 'INTERVIEW_SCHEDULING', 'initial report status should be INTERVIEW_SCHEDULING';

  v_rpc_res := public.create_next_interview_round(v_app_id, v_round_idempotency_key);
  assert (v_rpc_res ->> 'success')::boolean = true, 'same idempotency key should return the original round';
  assert (v_rpc_res -> 'data' ->> 'interview_id')::uuid = v_int1_id, 'same idempotency key must not create a second round';

  -- Create Round 2
  v_rpc_res := public.create_next_interview_round(v_app_id, gen_random_uuid());
  assert (v_rpc_res ->> 'success')::boolean = true, 'create_next_interview_round should succeed for round 2';
  v_int2_id := (v_rpc_res -> 'data' ->> 'interview_id')::uuid;
  assert (v_rpc_res -> 'data' ->> 'round_no')::integer = 2, 'second round should be 2';

  -- Check is_interview_clean helper
  assert private.is_interview_clean(v_int1_id) = true, 'newly created round 1 should be clean';
  assert private.is_interview_clean(v_int2_id) = false, 'round 2 is not clean because round 1 exists and clean requires round 1';

  -- ---------------------------------------------------------------------------
  -- 3. Test Time Range Check Constraint (interview_time_range_ck)
  -- ---------------------------------------------------------------------------
  v_err_thrown := false;
  begin
    update public.interviews
    set
      start_at = '2026-10-10 10:00:00+07',
      end_at = '2026-10-10 09:00:00+07'
    where interview_id = v_int1_id;
  exception when check_violation then
    v_err_thrown := true;
  end;
  assert v_err_thrown = true, 'interview_time_range_ck must reject start_at >= end_at';

  v_err_thrown := false;
  begin
    update public.interviews
    set
      start_at = '2026-10-10 10:00:00+07',
      end_at = '2026-10-10 10:00:00+07'
    where interview_id = v_int1_id;
  exception when check_violation then
    v_err_thrown := true;
  end;
  assert v_err_thrown = true, 'interview_time_range_ck must reject start_at = end_at';

  -- ---------------------------------------------------------------------------
  -- 4. Test Participant Management RPCs (add, reorder, remove)
  -- ---------------------------------------------------------------------------
  -- 4.1 Inactive participant should be rejected
  v_rpc_res := public.add_interview_participant(v_int1_id, v_inactive_user_id, gen_random_uuid());
  assert (v_rpc_res ->> 'success')::boolean = false, 'add_interview_participant must reject inactive user';
  assert (v_rpc_res ->> 'error_code') = 'USER_INACTIVE_NOT_SELECTABLE', 'expected USER_INACTIVE_NOT_SELECTABLE';

  -- 4.2 Add interviewer 1
  v_rpc_res := public.add_interview_participant(v_int1_id, v_interviewer1_id, gen_random_uuid());
  assert (v_rpc_res ->> 'success')::boolean = true, 'add interviewer 1 should succeed';
  v_part1_id := (v_rpc_res -> 'data' ->> 'interview_participant_id')::uuid;
  assert (v_rpc_res -> 'data' ->> 'participant_order')::integer = 1, 'order should be 1';
  assert (v_rpc_res -> 'data' ->> 'snapshot_name') = 'Prof Alpha', 'snapshot_name should match user';

  -- 4.3 Add interviewer 2
  v_rpc_res := public.add_interview_participant(v_int1_id, v_interviewer2_id, gen_random_uuid());
  assert (v_rpc_res ->> 'success')::boolean = true, 'add interviewer 2 should succeed';
  v_part2_id := (v_rpc_res -> 'data' ->> 'interview_participant_id')::uuid;
  assert (v_rpc_res -> 'data' ->> 'participant_order')::integer = 2, 'order should be 2';

  -- 4.4 Duplicate active participant should be rejected
  v_rpc_res := public.add_interview_participant(v_int1_id, v_interviewer1_id, gen_random_uuid());
  assert (v_rpc_res ->> 'success')::boolean = false, 'duplicate participant should be rejected';
  assert (v_rpc_res ->> 'error_code') = 'DUPLICATE_PARTICIPANT', 'expected DUPLICATE_PARTICIPANT';

  -- 4.5 all_current_participants_selectable should return true
  assert private.all_current_participants_selectable(v_int1_id) = true, 'all current participants should be selectable';

  -- 4.6 Reorder participants
  select array_agg(ip.version_no order by array_position(array[v_part2_id,v_part1_id],ip.interview_participant_id))
  into v_versions
  from public.interview_participants ip
  where ip.interview_participant_id = any(array[v_part2_id,v_part1_id]);
  v_rpc_res := public.reorder_interview_participants(v_int1_id, array[v_part2_id, v_part1_id], v_versions);
  assert (v_rpc_res ->> 'success')::boolean = true, 'reorder should succeed';

  select participant_order into v_count from public.interview_participants where interview_participant_id = v_part2_id;
  assert v_count = 1, 'part2 should now have order 1';
  select participant_order into v_count from public.interview_participants where interview_participant_id = v_part1_id;
  assert v_count = 2, 'part1 should now have order 2';

  -- Use the persisted token after reorder; participant version changes on each
  -- ordered-row update, while the public command guards the current token.
  select version_no into v_version
  from public.interview_participants
  where interview_participant_id = v_part2_id;
  v_rpc_res := public.remove_interview_participant(v_part2_id, v_version);
  assert (v_rpc_res ->> 'success')::boolean = true, 'remove participant should succeed';

  -- Verify remaining participant compacted to order 1
  select participant_order into v_count from public.interview_participants where interview_participant_id = v_part1_id;
  assert v_count = 1, 'remaining part1 should be compacted to order 1';

  select version_no into v_version
  from public.interviews
  where interview_id = v_int1_id;
  v_rpc_res := public.add_interview_participant(v_int1_id, v_interviewer2_id, gen_random_uuid());
  assert (v_rpc_res ->> 'success')::boolean = true, 're-adding participant 2 should succeed';
  v_part2_id := (v_rpc_res -> 'data' ->> 'interview_participant_id')::uuid;

  -- ---------------------------------------------------------------------------
  -- 5. Test Schedule Conflict Detection & Locking
  -- ---------------------------------------------------------------------------
  -- Set Interview 1 as resource-blocking: 2026-10-15 09:00 to 10:00 in v_room_id
  update public.interviews
  set
    start_at = '2026-10-15 09:00:00+07',
    end_at = '2026-10-15 10:00:00+07',
    interview_format_id = v_format_room_id,
    room_id = v_room_id,
    schedule_status_code = 'SCHEDULED'
  where interview_id = v_int1_id;

  -- 5.1 Adjacent Interval: [10:00, 11:00) should NOT conflict with [09:00, 10:00)
  v_conflicts_res := public.check_interview_schedule_conflicts(
    v_int2_id,
    '2026-10-15 10:00:00+07',
    '2026-10-15 11:00:00+07',
    v_room_id,
    array[v_interviewer1_id]
  );
  assert (v_conflicts_res ->> 'success')::boolean = true, 'conflict check should succeed';
  assert (v_conflicts_res -> 'data' ->> 'has_conflict')::boolean = false, 'adjacent interval [10:00, 11:00) must NOT conflict with [09:00, 10:00)';

  -- 5.2 Adjacent Interval: [08:00, 09:00) should NOT conflict with [09:00, 10:00)
  v_conflicts_res := public.check_interview_schedule_conflicts(
    v_int2_id,
    '2026-10-15 08:00:00+07',
    '2026-10-15 09:00:00+07',
    v_room_id,
    array[v_interviewer1_id]
  );
  assert (v_conflicts_res -> 'data' ->> 'has_conflict')::boolean = false, 'adjacent interval [08:00, 09:00) must NOT conflict with [09:00, 10:00)';

  -- 5.3 Overlapping Interval: [09:30, 10:30) conflicts on Candidate, Room, and Interviewer
  v_conflicts_res := public.check_interview_schedule_conflicts(
    v_int2_id,
    '2026-10-15 09:30:00+07',
    '2026-10-15 10:30:00+07',
    v_room_id,
    array[v_interviewer1_id]
  );
  assert (v_conflicts_res -> 'data' ->> 'has_conflict')::boolean = true, 'overlapping interval [09:30, 10:30) must flag conflict';
  assert (v_conflicts_res -> 'data' ->> 'conflict_count')::integer >= 3, 'should detect candidate, room, and interviewer conflicts';

  -- 5.4 Cancelled interview should NOT block
  update public.interviews
  set schedule_status_code = 'CANCELLED'
  where interview_id = v_int1_id;

  v_conflicts_res := public.check_interview_schedule_conflicts(
    v_int2_id,
    '2026-10-15 09:30:00+07',
    '2026-10-15 10:30:00+07',
    v_room_id,
    array[v_interviewer1_id]
  );
  assert (v_conflicts_res -> 'data' ->> 'has_conflict')::boolean = false, 'CANCELLED interview must NOT cause conflict';

  -- Restore to SCHEDULED
  update public.interviews
  set schedule_status_code = 'SCHEDULED'
  where interview_id = v_int1_id;

  -- ---------------------------------------------------------------------------
  -- 6. Test RLS: Interviewer raw table access DENIED (F02 confidentiality repair)
  -- ---------------------------------------------------------------------------
  -- After the F02 repair, Interviewers no longer have raw table SELECT on
  -- public.interviews. They use the safe RPC get_interviewer_report_page instead.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_interviewer1_auth_id::text)::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count
  from public.interviews
  where interview_id = v_int1_id;
  assert v_count = 0, 'Interviewer must NOT have raw table SELECT on interviews (F02 repair)';

  select count(*) into v_count
  from public.interviews
  where interview_id = v_int2_id;
  assert v_count = 0, 'Interviewer 1 must NOT be able to view unassigned interview 2';

  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth_id::text)::text, true);
  update public.interviews set visible_to_interviewers = false where interview_id = v_int1_id;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_interviewer1_auth_id::text)::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count
  from public.interviews
  where interview_id = v_int1_id;
  assert v_count = 0, 'Interviewer must NOT be able to view interview regardless of visible_to_interviewers';
  execute 'reset role';

  -- ---------------------------------------------------------------------------
  -- 7. Test current-round gates for creating a subsequent round
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth_id::text)::text, true);
  update public.interviews
  set report_status_code = 'HIRED'
  where interview_id = v_int2_id;
  v_rpc_res := public.create_next_interview_round(v_app_id, gen_random_uuid());
  assert (v_rpc_res ->> 'error_code') = 'APPLICATION_HIRED', 'HIRED latest round must block a new round';

  update public.interviews
  set report_status_code = 'FOLLOW_UP', is_active = false
  where interview_id = v_int2_id;
  v_rpc_res := public.create_next_interview_round(v_app_id, gen_random_uuid());
  assert (v_rpc_res ->> 'error_code') = 'LATEST_INTERVIEW_INACTIVE', 'inactive latest round must block a new round';

  update public.interviews set visible_to_interviewers = true where interview_id = v_int1_id;
  update public.applications set is_active = false where application_id = v_app_id;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_interviewer1_auth_id::text)::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.interviews where interview_id = v_int1_id;
  assert v_count = 0, 'inactive parent application must revoke interviewer interview access';
  execute 'reset role';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth_id::text)::text, true);
  v_rpc_res := public.create_next_interview_round(v_app_id, gen_random_uuid());
  assert (v_rpc_res ->> 'error_code') = 'APPLICATION_INACTIVE', 'inactive application must block a new round';

  raise notice '=== TASK-S04-001 Test Suite PASSED ===';
end $$;
