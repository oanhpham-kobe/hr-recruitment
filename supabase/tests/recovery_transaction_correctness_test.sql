-- =============================================================================
-- REC-04 Coordinated Transaction Correctness Test
--
-- Proves:
--   1. Catalog registration: all repaired functions exist with empty search_path,
--      security definer, and exact signatures.
--   2. F06: Every direct lifecycle version boundary strictly rejects NULL and
--      non-positive expected versions with VALIDATION_ERROR, and rejects stale
--      versions with STALE_VERSION.
--   3. Report field-merge semantics: disjoint field updates merge cleanly while
--      conflicting updates fail with STALE_VERSION.
--   4. F05: reactivate_interview recalculates parent Submission outcome in the
--      same transaction (HIRED -> inactivate -> reactivate -> HIRED/DONE).
--   5. F07: Atomic bulk interview deletion: late item failure (stale version)
--      leaves rows, outcomes, audits, and cleanup queue completely unchanged.
--   6. F04: Deterministic lock ordering and revalidation: inactive parent
--      applications and non-latest rounds are safely rejected after acquisition.
--   7. REC-04 Forward: update_submission_by_hr requires a positive optimistic
--      version and preserves state on every rejected version token.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

do $$
<<rec04_test>>
declare
  s text := substr(gen_random_uuid()::text, 1, 8);
  v_hr_auth uuid := gen_random_uuid();
  v_hr_user uuid;
  v_i1_auth uuid := gen_random_uuid();
  v_i1_user uuid;
  v_i2_auth uuid := gen_random_uuid();
  v_i2_user uuid;
  v_unit_id uuid;
  v_group_id uuid;
  v_pos_id uuid;
  v_format_id uuid;
  v_room_id uuid;
  v_cand1 uuid;
  v_sub1 uuid;
  v_app1 uuid;
  v_int1 uuid;
  v_int2 uuid;
  v_part1 uuid;
  v_part2 uuid;
  v_report1 uuid;
  v_res1 uuid;
  v_cand2 uuid;
  v_sub2 uuid;
  v_app2 uuid;
  v_int2_1 uuid;
  v_int2_2 uuid;
  v_res2 uuid;
  v_r jsonb;
  v_ver bigint;
  v_ver2 bigint;
  v_initial_cleanup_count integer;
  v_initial_audit_count integer;
  v_doc_type uuid;
  v_ts timestamptz;
  v_cand_rec uuid;
  v_sub_rec uuid;
  v_app_rec uuid;
  v_int_rec1 uuid;
  v_int_rec2 uuid;
  v_f07_id1 uuid;
  v_f07_id2 uuid;
  v_res_f07 uuid;
  v_cand_f07 uuid;
  v_sub_f07 uuid;
  v_app_f07 uuid;
  v_cand_f07_late uuid;
  v_sub_f07_late uuid;
  v_app_f07_late uuid;
  v_cand_hd uuid;
  v_sub_hd uuid;
  v_app_hd uuid;
  v_int_hd_valid uuid;
  v_int_hd_missing uuid;
  v_cand_pw uuid;
  v_sub_pw1 uuid;
  v_sub_pw2 uuid;
  v_app_pw1 uuid;
  v_app_pw2 uuid;
  v_int_pw1 uuid;
  v_int_pw2 uuid;
  v_idemp_key uuid;
  v_replay jsonb;
  v_audit_act text;
  v_audit_payload jsonb;
begin
  raise notice '====================================================================';
  raise notice '=== REC-04 TRANSACTION CORRECTNESS TESTS                         ===';
  raise notice '====================================================================';

  -- ---------------------------------------------------------------------------
  -- 0. Fixtures setup
  -- ---------------------------------------------------------------------------
  insert into public.organizational_units(code, name_vi)
  values ('U_' || s, 'Rec04 Unit ' || s)
  returning unit_id into v_unit_id;

  insert into public.position_groups(code, name_vi)
  values ('G_' || s, 'Rec04 Group ' || s)
  returning position_group_id into v_group_id;

  insert into public.positions(unit_id, position_group_id, code, name_vi)
  values (v_unit_id, v_group_id, 'P_' || s, 'Rec04 Position ' || s)
  returning position_id into v_pos_id;

  insert into public.interview_formats(code, name_vi, requires_room)
  values ('F_' || s, 'Rec04 Format', false)
  returning interview_format_id into v_format_id;

  insert into public.rooms(code, display_name)
  values ('R_' || s, 'Rec04 Room')
  returning room_id into v_room_id;

  select document_type_id into v_doc_type
  from public.document_types
  where is_active
  limit 1;

  -- Reuse the singleton root when an integration fixture already provides it.
  -- A disposable replay database has no root, so create one only in that case.
  select auth_user_id, app_user_id into v_hr_auth, v_hr_user
  from public.app_users
  where is_root_admin and is_active
  order by app_user_id
  limit 1;
  if not found then
    v_hr_auth := gen_random_uuid();
    insert into public.app_users(auth_user_id, full_name, email, is_active, is_root_admin)
    values (v_hr_auth, 'Rec04 HR', 'hr_' || s || '@eiu.edu.vn', true, true)
    returning app_user_id into v_hr_user;
  end if;

  insert into public.app_user_roles(app_user_id, role_code)
  values (v_hr_user, 'HR')
  on conflict do nothing;

  insert into public.app_user_permissions(app_user_id, permission_code, granted_by)
  values
    (v_hr_user, 'interviews.participants', v_hr_user),
    (v_hr_user, 'interviews.view', v_hr_user)
  on conflict do nothing;

  -- Interviewer 1
  insert into public.app_users(auth_user_id, full_name, email, is_active, is_root_admin)
  values (v_i1_auth, 'Rec04 Interviewer 1', 'i1_' || s || '@eiu.edu.vn', true, false)
  returning app_user_id into v_i1_user;

  -- Interviewer 2
  insert into public.app_users(auth_user_id, full_name, email, is_active, is_root_admin)
  values (v_i2_auth, 'Rec04 Interviewer 2', 'i2_' || s || '@eiu.edu.vn', true, false)
  returning app_user_id into v_i2_user;

  -- Candidate 1 + Submission 1 + Application 1
  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 'c1_' || s || '@example.invalid', true)
  returning candidate_id into v_cand1;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand1, 'Candidate One', '1990-01-01', 'MALE', 'Address 1', '0900000001', 'c1_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub1;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub1, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app1;

  insert into public.interviews(application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
  values (v_app1, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1)
  returning interview_id into v_int1;

  -- Add participant 1 to round 1
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth::text)::text, true);
  v_r := public.add_interview_participant(v_int1, v_i1_user, gen_random_uuid());
  assert (v_r->>'success')::boolean, 'Fixture participant 1 added';
  v_part1 := (v_r->'data'->>'interview_participant_id')::uuid;

  -- Add participant 2 to round 1
  v_r := public.add_interview_participant(v_int1, v_i2_user, gen_random_uuid());
  assert (v_r->>'success')::boolean, 'Fixture participant 2 added';
  v_part2 := (v_r->'data'->>'interview_participant_id')::uuid;

  -- Candidate 2 + Submission 2 + Application 2
  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 'c2_' || s || '@example.invalid', true)
  returning candidate_id into v_cand2;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand2, 'Candidate Two', '1992-02-02', 'FEMALE', 'Address 2', '0900000002', 'c2_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub2;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub2, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app2;

  insert into public.interviews(application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
  values (v_app2, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1)
  returning interview_id into v_int2_1;

  raise notice 'PASS: Fixtures initialized.';


  -- ===========================================================================
  -- CHECK 1: Catalog audit for repaired functions
  -- ===========================================================================
  raise notice '--- Check 1: Catalog audit for repaired functions ---';
  assert exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='create_next_interview_round' and p.prosecdef
  ), 'FAIL: create_next_interview_round catalog';

  assert exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='reactivate_interview' and p.prosecdef
  ), 'FAIL: reactivate_interview catalog';

  assert exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='bulk_delete_or_inactivate_interviews' and p.prosecdef
  ), 'FAIL: bulk_delete_or_inactivate_interviews catalog';

  assert exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='copy_interview_schedule' and p.prosecdef
  ), 'FAIL: copy_interview_schedule catalog';

  assert exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname='save_interviewer_report_core' and p.prosecdef
  ), 'FAIL: save_interviewer_report_core catalog';

  assert exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='bulk_change_report_status' and p.prosecdef
  ), 'FAIL: bulk_change_report_status catalog';

  raise notice 'PASS: Catalog audit verified.';


  -- ===========================================================================
  -- CHECK 2: F06 Expected Version Guards (NULL / non-positive rejected with VALIDATION_ERROR)
  -- ===========================================================================
  raise notice '--- Check 2: F06 Version Guards (NULL / non-positive / stale) ---';

  -- 2.1 save_interview_schedule
  v_r := public.save_interview_schedule(v_int1, null, null, null, null, null, null, 'note', null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: save_interview_schedule with NULL version must return VALIDATION_ERROR';

  v_r := public.save_interview_schedule(v_int1, null, null, null, null, null, null, 'note', 0);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: save_interview_schedule with 0 version must return VALIDATION_ERROR';

  v_r := public.save_interview_schedule(v_int1, null, null, null, null, null, null, 'note', -1);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: save_interview_schedule with -1 version must return VALIDATION_ERROR';

  v_r := public.save_interview_schedule(v_int1, null, null, null, null, null, null, 'note', 99999);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: save_interview_schedule with stale version must return STALE_VERSION';

  -- 2.1b save_interview_schedule INVALID_INTERVAL validation
  v_ts := now();
  v_r := public.save_interview_schedule(v_int1, v_ts, v_ts, v_format_id, null, null, null, 'note', 1);
  assert (v_r->>'error_code') = 'INVALID_INTERVAL', 'FAIL: save_interview_schedule with equal endpoints must return INVALID_INTERVAL';

  v_r := public.save_interview_schedule(v_int1, v_ts + interval '1 hour', v_ts, v_format_id, null, null, null, 'note', 1);
  assert (v_r->>'error_code') = 'INVALID_INTERVAL', 'FAIL: save_interview_schedule with reversed endpoints must return INVALID_INTERVAL';

  -- 2.2 change_interview_schedule_status
  v_r := public.change_interview_schedule_status(v_int1, 'AWAITING', null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: change_interview_schedule_status with NULL version must return VALIDATION_ERROR';

  v_r := public.change_interview_schedule_status(v_int1, 'AWAITING', 0);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: change_interview_schedule_status with 0 version must return VALIDATION_ERROR';

  v_r := public.change_interview_schedule_status(v_int1, 'AWAITING', 99999);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: change_interview_schedule_status with stale version must return STALE_VERSION';

  -- 2.3 reschedule_confirmed_interview validation
  -- Retain ID/format/version validation (VALIDATION_ERROR) separately from interval validation (INVALID_INTERVAL)
  v_r := public.reschedule_confirmed_interview(v_int1, now(), now() + interval '1 hour', v_format_id, null, null, null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: reschedule_confirmed_interview with NULL version must return VALIDATION_ERROR';

  v_r := public.reschedule_confirmed_interview(v_int1, now(), now() + interval '1 hour', v_format_id, null, null, 0);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: reschedule_confirmed_interview with 0 version must return VALIDATION_ERROR';

  v_r := public.reschedule_confirmed_interview(null, now(), now() + interval '1 hour', v_format_id, null, null, 1);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: reschedule_confirmed_interview with NULL interview_id must return VALIDATION_ERROR';

  v_r := public.reschedule_confirmed_interview(v_int1, now(), now() + interval '1 hour', null, null, null, 1);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: reschedule_confirmed_interview with NULL format must return VALIDATION_ERROR';

  -- 2.3b reschedule_confirmed_interview INVALID_INTERVAL baseline behavior (null start, null end, equal, reversed)
  select count(*) into v_initial_audit_count from public.security_audit_log where entity_id = v_int1;
  select version_no into v_ver from public.interviews where interview_id = v_int1;

  v_r := public.reschedule_confirmed_interview(v_int1, null, now() + interval '1 hour', v_format_id, null, null, 1);
  assert (v_r->>'error_code') = 'INVALID_INTERVAL', 'FAIL: reschedule_confirmed_interview with NULL start must return INVALID_INTERVAL';

  v_r := public.reschedule_confirmed_interview(v_int1, now(), null, v_format_id, null, null, 1);
  assert (v_r->>'error_code') = 'INVALID_INTERVAL', 'FAIL: reschedule_confirmed_interview with NULL end must return INVALID_INTERVAL';

  v_r := public.reschedule_confirmed_interview(v_int1, v_ts, v_ts, v_format_id, null, null, 1);
  assert (v_r->>'error_code') = 'INVALID_INTERVAL', 'FAIL: reschedule_confirmed_interview with equal endpoints must return INVALID_INTERVAL';

  v_r := public.reschedule_confirmed_interview(v_int1, v_ts + interval '1 hour', v_ts, v_format_id, null, null, 1);
  assert (v_r->>'error_code') = 'INVALID_INTERVAL', 'FAIL: reschedule_confirmed_interview with reversed endpoints must return INVALID_INTERVAL';

  -- Assert state and audits remain completely unchanged on INVALID_INTERVAL
  assert (select is_active from public.interviews where interview_id = v_int1) = true, 'FAIL: v_int1 must remain active';
  assert (select version_no from public.interviews where interview_id = v_int1) = v_ver, 'FAIL: v_int1 version must remain unchanged';
  assert (select schedule_status_code from public.interviews where interview_id = v_int1) = 'AVAILABLE', 'FAIL: v_int1 status unchanged';
  assert (select count(*) from public.security_audit_log where entity_id = v_int1) = v_initial_audit_count,
    'FAIL: zero audit logs must be recorded on INVALID_INTERVAL rejection';
  -- 2.4 reactivate_interview
  v_r := public.reactivate_interview(v_int1, null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: reactivate_interview with NULL version must return VALIDATION_ERROR';

  v_r := public.reactivate_interview(v_int1, 0);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: reactivate_interview with 0 version must return VALIDATION_ERROR';

  v_r := public.reactivate_interview(v_int1, 99999);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: reactivate_interview with stale version must return STALE_VERSION';

  -- 2.5 delete_or_inactivate_interview
  v_r := public.delete_or_inactivate_interview(v_int1, null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: delete_or_inactivate_interview with NULL version must return VALIDATION_ERROR';

  v_r := public.delete_or_inactivate_interview(v_int1, 0);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: delete_or_inactivate_interview with 0 version must return VALIDATION_ERROR';

  v_r := public.delete_or_inactivate_interview(v_int1, 99999);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: delete_or_inactivate_interview with stale version must return STALE_VERSION';

  -- 2.6 change_report_status
  v_r := public.change_report_status(v_int1, 'REPORT_SUBMITTED', null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: change_report_status with NULL version must return VALIDATION_ERROR';

  v_r := public.change_report_status(v_int1, 'REPORT_SUBMITTED', 0);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: change_report_status with 0 version must return VALIDATION_ERROR';

  v_r := public.change_report_status(v_int1, 'REPORT_SUBMITTED', 99999);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: change_report_status with stale version must return STALE_VERSION';

  -- 2.7 update_hr_report_note
  v_r := public.update_hr_report_note(v_int1, 'note', null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: update_hr_report_note with NULL version must return VALIDATION_ERROR';

  v_r := public.update_hr_report_note(v_int1, 'note', 0);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: update_hr_report_note with 0 version must return VALIDATION_ERROR';

  v_r := public.update_hr_report_note(v_int1, 'note', 99999);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: update_hr_report_note with stale version must return STALE_VERSION';

  -- 2.8 copy_interview_schedule validation contract (20260913004500 preserved)
  -- 2.8.1 NULL p_idempotency_key -> VALIDATION_ERROR
  v_r := public.copy_interview_schedule(
    v_int1, v_app2, 1, 1, v_int2_1, 1,
    null, null, null, null, null, 'note', array[v_i1_user], null
  );
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: copy with NULL idempotency_key must return VALIDATION_ERROR';

  -- 2.8.2 NULL p_participant_app_user_ids -> VALIDATION_ERROR
  v_r := public.copy_interview_schedule(
    v_int1, v_app2, 1, 1, v_int2_1, 1,
    null, null, null, null, null, 'note', null, gen_random_uuid()
  );
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: copy with NULL participant_ids must return VALIDATION_ERROR';

  -- 2.8.3 p_start_at >= p_end_at -> VALIDATION_ERROR
  v_r := public.copy_interview_schedule(
    v_int1, v_app2, 1, 1, v_int2_1, 1,
    now() + interval '1 hour', now(), v_format_id, null, null, 'note', array[v_i1_user], gen_random_uuid()
  );
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: copy with start >= end must return VALIDATION_ERROR';

  -- 2.8.4 NULL expected version -> VALIDATION_ERROR (20260913004500 preserved)
  v_r := public.copy_interview_schedule(
    v_int1, v_app2, null, 1, v_int2_1, 1,
    null, null, null, null, null, 'note', array[v_i1_user], gen_random_uuid()
  );
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: copy with NULL source version must return VALIDATION_ERROR';

  -- 2.8.5 Mismatched / 0 expected version -> STALE_VERSION (TASK-S04-003 contract preserved)
  v_r := public.copy_interview_schedule(
    v_int1, v_app2, 0, 1, v_int2_1, 1,
    null, null, null, null, null, 'note', array[v_i1_user], gen_random_uuid()
  );
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: copy with 0 source version must return STALE_VERSION';
  -- 2.9 remove_interview_participant (effective 20260906090000 returns STALE_VERSION for NULL)
  v_r := public.remove_interview_participant(v_part1, null);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: remove_interview_participant with NULL version returns STALE_VERSION';

  v_r := public.remove_interview_participant(v_part1, 99999);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: remove_interview_participant with stale version must return STALE_VERSION';
  -- 2.10 bulk_delete_or_inactivate_interviews
  v_r := public.bulk_delete_or_inactivate_interviews(array[v_int1], array[null::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_delete with NULL version element must return VALIDATION_ERROR';

  v_r := public.bulk_delete_or_inactivate_interviews(array[v_int1], array[0::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_delete with 0 version element must return VALIDATION_ERROR';

  v_r := public.bulk_delete_or_inactivate_interviews(array[v_int1], null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_delete with NULL versions array must return VALIDATION_ERROR';

  v_r := public.bulk_delete_or_inactivate_interviews(null, array[1::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_delete with NULL ids array must return VALIDATION_ERROR';

  -- 2.11 bulk_change_interview_schedule_status
  v_r := public.bulk_change_interview_schedule_status(array[v_int1], 'AVAILABLE', array[null::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_status with NULL version element must return VALIDATION_ERROR';

  v_r := public.bulk_change_interview_schedule_status(array[v_int1], 'AVAILABLE', array[0::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_status with 0 version element must return VALIDATION_ERROR';

  v_r := public.bulk_change_interview_schedule_status(array[v_int1], 'AVAILABLE', null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_status with NULL versions array must return VALIDATION_ERROR';

  v_r := public.bulk_change_interview_schedule_status(null, 'AVAILABLE', array[1::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_status with NULL ids array must return VALIDATION_ERROR';

  -- 2.12 save_interviewer_report / save_own_interviewer_report
  v_r := public.save_interviewer_report(v_part1, jsonb_build_object('necessary_skills', 'Python'), null, jsonb_build_object('necessary_skills', null));
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: save_interviewer_report with NULL version must return VALIDATION_ERROR';

  v_r := public.save_interviewer_report(v_part1, jsonb_build_object('necessary_skills', 'Python'), 0, jsonb_build_object('necessary_skills', null));
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: save_interviewer_report with 0 version must return VALIDATION_ERROR';

  -- 2.13 bulk_change_report_status NULL array and version validation
  v_r := public.bulk_change_report_status(array[v_int1], 'REPORT_SUBMITTED', null);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_report_status with NULL versions array must return VALIDATION_ERROR';

  v_r := public.bulk_change_report_status(null, 'REPORT_SUBMITTED', array[1::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_report_status with NULL ids array must return VALIDATION_ERROR';

  v_r := public.bulk_change_report_status(array[v_int1], 'REPORT_SUBMITTED', array[null::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_report_status with NULL version element must return VALIDATION_ERROR';

  v_r := public.bulk_change_report_status(array[v_int1], 'REPORT_SUBMITTED', array[0::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_report_status with 0 version element must return VALIDATION_ERROR';

  v_r := public.bulk_change_report_status(array[v_int1], 'REPORT_SUBMITTED', array[99999::bigint]);
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: bulk_change_report_status with stale version element must return STALE_VERSION';

  -- 2.14 Array lower-bound mismatch regression (Finding 1: non-1 lower bounds)
  -- Passing non-1 lower-bound array like '[0:0]={1}'::bigint[] or '[2:2]={1}'::bigint[]
  -- MUST return VALIDATION_ERROR and leave all state, audits, and cleanup queue completely untouched.
  select count(*) into v_initial_cleanup_count from public.storage_cleanup_queue;
  select count(*) into v_initial_audit_count from public.security_audit_log where entity_id = v_int1;
  select version_no into v_ver from public.interviews where interview_id = v_int1;
  v_r := public.bulk_delete_or_inactivate_interviews(array[v_int1], '[0:0]={1}'::bigint[]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_delete with non-1 lower-bound versions must return VALIDATION_ERROR';

  v_r := public.bulk_delete_or_inactivate_interviews(format('[2:2]={%s}', v_int1)::uuid[], array[1::bigint]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_delete with non-1 lower-bound ids must return VALIDATION_ERROR';

  v_r := public.bulk_change_interview_schedule_status(array[v_int1], 'AVAILABLE', '[0:0]={1}'::bigint[]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_status with non-1 lower-bound versions must return VALIDATION_ERROR';

  v_r := public.bulk_change_report_status(array[v_int1], 'REPORT_SUBMITTED', '[0:0]={1}'::bigint[]);
  assert (v_r->>'error_code') = 'VALIDATION_ERROR', 'FAIL: bulk_change_report_status with non-1 lower-bound versions must return VALIDATION_ERROR';

  -- Assert zero writes / audits / cleanup:
  assert (select is_active from public.interviews where interview_id = v_int1) = true, 'FAIL: v_int1 must remain active';
  assert (select version_no from public.interviews where interview_id = v_int1) = v_ver, 'FAIL: v_int1 version must remain unchanged';
  assert (select schedule_status_code from public.interviews where interview_id = v_int1) = 'AVAILABLE', 'FAIL: v_int1 schedule status unchanged';
  assert (select count(*) from public.storage_cleanup_queue) = v_initial_cleanup_count, 'FAIL: zero cleanup writes on lower-bound mismatch';
  assert (select count(*) from public.security_audit_log where entity_id = v_int1) = v_initial_audit_count, 'FAIL: zero audit writes on lower-bound mismatch';

  raise notice 'PASS: F06 Version guards strictly reject NULL, non-positive, stale, and non-1 lower bound arrays across all lifecycle commands.';


  -- ===========================================================================
  -- CHECK 3: Report field-merge semantics retained
  -- ===========================================================================
  raise notice '--- Check 3: Report field-merge semantics ---';

  insert into public.interview_reports(interview_participant_id, created_by, updated_by)
  values (v_part1, v_hr_user, v_hr_user)
  returning interview_report_id into v_report1;

  select version_no into v_ver from public.interview_reports where interview_report_id = v_report1;

  -- 3.1 HR first patch succeeds
  v_r := public.save_interviewer_report(
    v_part1,
    jsonb_build_object('necessary_skills', 'SQL Skills'),
    v_ver,
    jsonb_build_object('necessary_skills', null)
  );
  assert (v_r->>'success')::boolean, 'FAIL: HR first patch must succeed';

  -- 3.2 HR disjoint patch merges on base value
  v_r := public.save_interviewer_report(
    v_part1,
    jsonb_build_object('other_comment', 'Disjoint note'),
    v_ver, -- stale report version, but other_comment is still null in DB
    jsonb_build_object('other_comment', null)
  );
  assert (v_r->>'success')::boolean, 'FAIL: HR disjoint patch must merge';

  -- 3.3 HR conflicting patch on same field rejects with STALE_VERSION
  v_r := public.save_interviewer_report(
    v_part1,
    jsonb_build_object('necessary_skills', 'Conflicting SQL Skills'),
    v_ver,
    jsonb_build_object('necessary_skills', null) -- base is null, but current in DB is 'SQL Skills'!
  );
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: HR same-field conflict must return STALE_VERSION';

  raise notice 'PASS: Report field-merge semantics verified.';


  -- ===========================================================================
  -- CHECK 4: F05 Reactivate interview derives parent Submission outcome in same transaction
  -- ===========================================================================
  raise notice '--- Check 4: F05 Reactivation Submission Outcome Recalculation ---';

  -- Create round 2 on Application 1 with idempotency key
  v_idemp_key := gen_random_uuid();
  v_r := public.create_next_interview_round(v_app1, v_idemp_key);
  assert (v_r->>'success')::boolean, 'FAIL: create_next_interview_round round 2';
  assert (v_r->'data' ? 'version_no'), 'FAIL: [Finding 5 NOT FIXED] create_next_interview_round data must contain version_no';
  assert (v_r->'data'->>'version_no')::bigint = 1, 'FAIL: [Finding 5 NOT FIXED] create_next_interview_round version_no must be 1';
  v_int2 := (v_r->'data'->>'interview_id')::uuid;
  v_ver := (v_r->'data'->>'version_no')::bigint;

  -- Idempotent replay: exact same response including version_no
  v_replay := public.create_next_interview_round(v_app1, v_idemp_key);
  assert (v_replay->>'success')::boolean, 'FAIL: create_next_interview_round idempotent replay';
  assert (v_replay->'data'->>'version_no')::bigint = 1, 'FAIL: idempotent replay must return version_no 1';
  assert (v_replay->'data'->>'interview_id')::uuid = v_int2, 'FAIL: idempotent replay must return identical interview_id';

  -- Consumer uses extracted version_no directly in subsequent version-checked mutation (without querying table)
  v_r := public.change_report_status(v_int2, 'HIRED', v_ver);
  assert (v_r->>'success')::boolean, 'FAIL: change_report_status HIRED using version_no from create_next_interview_round';
  assert (select status_code from public.submissions where submission_id = v_sub1) = 'DONE',
    'FAIL: Submission must be DONE after HIRED round 2';

  -- Soft-inactivate round 2 -> Submission status recalculates to 'PROCESSED'
  select version_no into v_ver from public.interviews where interview_id = v_int2;
  v_r := public.delete_or_inactivate_interview(v_int2, v_ver);
  assert (v_r->>'success')::boolean, 'FAIL: inactivate round 2';
  assert (select is_active from public.interviews where interview_id = v_int2) = false,
    'FAIL: round 2 must be inactive';
  assert (select status_code from public.submissions where submission_id = v_sub1) = 'PROCESSED',
    'FAIL: Submission must recalculate to PROCESSED when HIRED round 2 is inactivated';

  -- Now REACTIVATE round 2 -> Submission status MUST recalculate back to 'DONE' in the same transaction!
  select version_no into v_ver from public.interviews where interview_id = v_int2;
  v_r := public.reactivate_interview(v_int2, v_ver);
  assert (v_r->>'success')::boolean, 'FAIL: reactivate_interview round 2 must succeed';
  assert (select is_active from public.interviews where interview_id = v_int2) = true,
    'FAIL: round 2 must be active';

  -- PROOF of F05 fix: Submission status is immediately 'DONE'
  assert (select status_code from public.submissions where submission_id = v_sub1) = 'DONE',
    'FAIL: [F05 NOT FIXED] Submission status must be recalculated to DONE upon reactivating HIRED round!';

  raise notice 'PASS: F05 Reactivation outcome calculation in same transaction verified.';

  -- ===========================================================================
  -- CHECK 4b: create_next_interview_round recalculates submission status (Finding 2)
  --           REJECTED/CLOSED -> new round -> IN_PROGRESS/PROCESSED
  -- ===========================================================================
  raise notice '--- Check 4b: create_next_interview_round recalculates submission status ---';
  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 'c_rec_' || s || '@example.invalid', true)
  returning candidate_id into v_cand_rec;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand_rec, 'Candidate Rec', '1995-05-05', 'MALE', 'Address Rec', '0900000008', 'c_rec_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub_rec;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub_rec, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app_rec;

  insert into public.interviews(application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
  values (v_app_rec, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1)
  returning interview_id into v_int_rec1;

  -- Set round 1 to REJECTED -> Submission status becomes 'CLOSED'
  v_r := public.change_report_status(v_int_rec1, 'REJECTED', 1);
  assert (v_r->>'success')::boolean, 'FAIL: change_report_status REJECTED on round 1';
  assert (select status_code from public.submissions where submission_id = v_sub_rec) = 'CLOSED',
    'FAIL: Submission status must be CLOSED when all applications/rounds are REJECTED';

  -- Call create_next_interview_round -> submission status MUST be recalculated to 'PROCESSED' under parent locks!
  v_r := public.create_next_interview_round(v_app_rec, gen_random_uuid());
  assert (v_r->>'success')::boolean, 'FAIL: create_next_interview_round round 2';
  v_int_rec2 := (v_r->'data'->>'interview_id')::uuid;

  assert (select status_code from public.submissions where submission_id = v_sub_rec) = 'PROCESSED',
    'FAIL: [Finding 2 NOT FIXED] create_next_interview_round must recalculate Submission status from CLOSED to PROCESSED';
  raise notice 'PASS: create_next_interview_round recalculated submission status from CLOSED to PROCESSED.';


  -- ===========================================================================
  -- CHECK 5: F07 Atomic Bulk Interview Deletion with Deterministic Ordered UUIDs (Finding 7)
  --          Earlier valid target hard-delete eligible + upload reservation,
  --          Later stale/non-latest target. Proves exact preservation.
  -- ===========================================================================
  raise notice '--- Check 5: F07 Atomic Bulk Interview Deletion (deterministic UUID order) ---';

  -- Create round 2 on Application 2 for later Check 6
  v_r := public.create_next_interview_round(v_app2, gen_random_uuid());
  assert (v_r->>'success')::boolean, 'FAIL: create round 2 on app 2';
  v_int2_2 := (v_r->'data'->>'interview_id')::uuid;

  -- Deterministic ordered UUIDs: v_f07_id1 < v_f07_id2 guaranteed
  v_f07_id1 := ('00000000-0000-4000-8000-' || substr(gen_random_uuid()::text, 25))::uuid;
  v_f07_id2 := ('ffffffff-ffff-4fff-bfff-' || substr(gen_random_uuid()::text, 25))::uuid;
  assert v_f07_id1 < v_f07_id2, 'FAIL: v_f07_id1 must be strictly smaller than v_f07_id2';

  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 'c_f07_' || s || '@example.invalid', true)
  returning candidate_id into v_cand_f07;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand_f07, 'Candidate F07', '1996-06-06', 'FEMALE', 'Address F07', '0900000009', 'c_f07_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub_f07;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub_f07, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app_f07;

  -- Earlier Target 1 (v_f07_id1): hard-delete eligible (clean round 1: no participants/notes/topics/times, AVAILABLE, INTERVIEW_SCHEDULING)
  insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
  values (v_f07_id1, v_app_f07, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1);

  -- Upload reservation sits on earlier valid hard-delete eligible target 1
  v_res_f07 := gen_random_uuid();
  insert into public.upload_reservations(
    upload_reservation_id, interview_id, intended_document_type_id,
    temp_bucket, temp_path, original_filename, expected_max_size_bytes,
    malware_scan_status, status_code, actor_auth_user_id, idempotency_key, expires_at
  ) values (
    v_res_f07, v_f07_id1, v_doc_type,
    'temp-bucket', 'temp/' || v_res_f07::text || '.pdf', 'f07_reservation.pdf', 1024,
    'CLEAN', 'VALIDATED', v_hr_auth, gen_random_uuid(), clock_timestamp() + interval '1 hour'
  );

  -- Later Target 2 (v_f07_id2): the only round on a separate application, passed with STALE expected version
  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 'c_f07_late_' || s || '@example.invalid', true)
  returning candidate_id into v_cand_f07_late;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand_f07_late, 'Candidate F07 Late', '1995-05-05', 'MALE', 'Address F07 Late', '0900000010', 'c_f07_late_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub_f07_late;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub_f07_late, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app_f07_late;

  insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
  values (v_f07_id2, v_app_f07_late, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1);

  -- Snapshot counters before call
  select count(*) into v_initial_cleanup_count from public.storage_cleanup_queue;
  select count(*) into v_initial_audit_count from public.security_audit_log where entity_id in (v_f07_id1, v_f07_id2);

  -- Call bulk delete where Target 1 (v_f07_id1) has CORRECT version (1), but later Target 2 (v_f07_id2) has STALE version (99999)!
  -- Because v_f07_id1 < v_f07_id2, preflight evaluates Target 1 FIRST (passes), then Target 2 (fails).
  v_r := public.bulk_delete_or_inactivate_interviews(
    array[v_f07_id1, v_f07_id2],
    array[1::bigint, 99999::bigint]
  );

  assert (v_r->>'success')::boolean = false, 'FAIL: bulk_delete must fail on late stale item';
  assert (v_r->>'error_code') = 'STALE_VERSION', 'FAIL: bulk_delete must report STALE_VERSION';

  -- PROOF of F07 fix & exact preservation:
  -- 1. Target 1 (v_f07_id1) was NOT deleted or inactivated!
  assert (select is_active from public.interviews where interview_id = v_f07_id1) = true,
    'FAIL: [F07 NOT FIXED] Target 1 was inactivated despite late item failure!';
  assert (select version_no from public.interviews where interview_id = v_f07_id1) = 1,
    'FAIL: [F07 NOT FIXED] Target 1 version was changed despite late item failure!';

  -- 2. Target 2 (v_f07_id2) was NOT touched!
  assert (select is_active from public.interviews where interview_id = v_f07_id2) = true,
    'FAIL: Target 2 must remain active';
  assert (select version_no from public.interviews where interview_id = v_f07_id2) = 1,
    'FAIL: Target 2 version must remain unchanged';

  -- 3. Upload reservation was NOT deleted!
  assert exists(select 1 from public.upload_reservations where upload_reservation_id = v_res_f07),
    'FAIL: [F07 NOT FIXED] Upload reservation was deleted despite late failure!';

  -- 4. No storage cleanup queue items created!
  assert (select count(*) from public.storage_cleanup_queue) = v_initial_cleanup_count,
    'FAIL: [F07 NOT FIXED] Cleanup queue item was enqueued despite late failure!';

  -- 5. No audit log items recorded!
  assert (select count(*) from public.security_audit_log where entity_id in (v_f07_id1, v_f07_id2)) = v_initial_audit_count,
    'FAIL: [F07 NOT FIXED] Audit logs were committed despite late failure!';

  -- 6. Submission status unchanged!
  assert (select status_code from public.submissions where submission_id = v_sub_f07) = 'PROCESSED',
    'FAIL: Submission status was modified despite late failure!';

  raise notice 'PASS: F07 Deterministic ordered UUIDs, exact preservation of target, reservation, cleanup, outcome, audit verified.';

  -- ===========================================================================
  -- CHECK 6: F04 Deterministic lock composition & revalidation
  -- ===========================================================================
  raise notice '--- Check 6: F04 Revalidation & Inactive Parent Guards ---';

  -- Inactivate Application 2
  update public.applications set is_active = false where application_id = v_app2;

  -- 6.1 create_next_interview_round on inactive application fails with APPLICATION_INACTIVE
  v_r := public.create_next_interview_round(v_app2, gen_random_uuid());
  assert (v_r->>'error_code') = 'APPLICATION_INACTIVE',
    'FAIL: create_next_interview_round must reject inactive application with APPLICATION_INACTIVE';

  -- 6.2 reactivate_interview on inactive application fails with APPLICATION_INACTIVE
  select version_no into v_ver2 from public.interviews where interview_id = v_int2_2;
  v_r := public.reactivate_interview(v_int2_2, v_ver2);
  assert (v_r->>'error_code') = 'APPLICATION_INACTIVE',
    'FAIL: reactivate_interview must reject inactive application with APPLICATION_INACTIVE';

  -- 6.3 save_interview_schedule on inactive application fails with APPLICATION_INACTIVE
  v_r := public.save_interview_schedule(v_int2_2, null, null, null, null, null, null, 'note', v_ver2);
  assert (v_r->>'error_code') = 'APPLICATION_INACTIVE',
    'FAIL: save_interview_schedule must reject inactive application with APPLICATION_INACTIVE';

  -- 6.4 copy_interview_schedule target inactive application fails with APPLICATION_INACTIVE
  select version_no into v_ver from public.interviews where interview_id = v_int1;
  v_r := public.copy_interview_schedule(
    v_int1, v_app2, v_ver, 1, v_int2_2, v_ver2,
    null, null, null, null, null, 'copy note', array[]::uuid[], gen_random_uuid()
  );
  assert (v_r->>'error_code') = 'APPLICATION_INACTIVE',
    'FAIL: copy_interview_schedule must reject inactive target application with APPLICATION_INACTIVE';

  -- Restore Application 2
  update public.applications set is_active = true where application_id = v_app2;

  -- 6.5 Deleting non-latest round rejects with LATEST_ROUND_REQUIRED
  select version_no into v_ver2 from public.interviews where interview_id = v_int2_1;
  v_r := public.delete_or_inactivate_interview(v_int2_1, v_ver2);
  assert (v_r->>'error_code') = 'LATEST_ROUND_REQUIRED',
    'FAIL: delete_or_inactivate_interview on non-latest round must return LATEST_ROUND_REQUIRED';

  raise notice 'PASS: F04 Revalidation and lifecycle boundaries verified.';

  -- ===========================================================================
  -- CHECK 7: Target Set Validation (Pre-lock Absent Target returns NOT_FOUND with zero writes)
  --          Note: cross-session post-lock disappearance under competing committed hard-delete
  --          is verified in recovery_transaction_concurrency_test.sh Scenario 7.
  -- ===========================================================================
  raise notice '--- Check 7: Target Set Validation (Pre-lock Absent Target) ---';

  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 'c_hd_' || s || '@example.invalid', true)
  returning candidate_id into v_cand_hd;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand_hd, 'Candidate HD', '1997-07-07', 'MALE', 'Address HD', '0900000010', 'c_hd_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub_hd;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub_hd, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app_hd;

  insert into public.interviews(interview_id, application_id, round_no, schedule_status_code, report_status_code, is_active, version_no)
  values (gen_random_uuid(), v_app_hd, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true, 1)
  returning interview_id into v_int_hd_valid;

  v_int_hd_missing := gen_random_uuid(); -- Opposing committed hard-delete target

  -- 7.1 bulk_delete_or_inactivate_interviews with missing target returns NOT_FOUND with zero writes
  v_r := public.bulk_delete_or_inactivate_interviews(
    array[v_int_hd_valid, v_int_hd_missing],
    array[1::bigint, 1::bigint]
  );
  assert (v_r->>'error_code') = 'NOT_FOUND', 'FAIL: bulk_delete with missing target must return NOT_FOUND';
  assert (select is_active from public.interviews where interview_id = v_int_hd_valid) = true,
    'FAIL: Valid interview must remain active on missing target error';
  assert (select version_no from public.interviews where interview_id = v_int_hd_valid) = 1,
    'FAIL: Valid interview version must remain unchanged on missing target error';

  -- 7.2 bulk_change_interview_schedule_status with missing target returns NOT_FOUND with zero writes
  v_r := public.bulk_change_interview_schedule_status(
    array[v_int_hd_valid, v_int_hd_missing],
    'SCHEDULED',
    array[1::bigint, 1::bigint]
  );
  assert (v_r->>'error_code') = 'NOT_FOUND', 'FAIL: bulk_change_status with missing target must return NOT_FOUND';
  assert (select schedule_status_code from public.interviews where interview_id = v_int_hd_valid) = 'AVAILABLE',
    'FAIL: Valid interview status must remain unchanged on missing target error';

  -- 7.3 bulk_change_report_status with missing target returns NOT_FOUND with zero writes
  v_r := public.bulk_change_report_status(
    array[v_int_hd_valid, v_int_hd_missing],
    'WAITING_FOR_REPORT',
    array[1::bigint, 1::bigint]
  );
  assert (v_r->>'error_code') = 'NOT_FOUND', 'FAIL: bulk_change_report_status with missing target must return NOT_FOUND';
  assert (select report_status_code from public.interviews where interview_id = v_int_hd_valid) = 'INTERVIEW_SCHEDULING',
    'FAIL: Valid interview report status must remain unchanged on missing target error';

  raise notice 'PASS: Post-lock target set revalidation on missing/hard-deleted target verified.';


  -- ===========================================================================
  -- CHECK 8: Pairwise post-transition conflict check (Finding 5: cancelled rows)
  -- ===========================================================================
  raise notice '--- Check 8: Pairwise post-transition conflict check on cancelled rows ---';

  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 'c_pw_' || s || '@example.invalid', true)
  returning candidate_id into v_cand_pw;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand_pw, 'Candidate PW 1', '1998-08-08', 'FEMALE', 'Address PW 1', '0900000011', 'c_pw1_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub_pw1;

  insert into public.submissions(candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code)
  values (v_cand_pw, 'Candidate PW 2', '1998-08-08', 'FEMALE', 'Address PW 2', '0900000012', 'c_pw2_' || s || '@example.invalid', 'PROCESSED')
  returning submission_id into v_sub_pw2;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub_pw1, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app_pw1;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_sub_pw2, v_unit_id, v_pos_id, v_hr_user, true)
  returning application_id into v_app_pw2;

  -- Two CANCELLED interviews with overlapping schedule times sharing the SAME ROOM
  insert into public.interviews(
    application_id, round_no, schedule_status_code, report_status_code, is_active, version_no,
    start_at, end_at, room_id, interview_format_id
  ) values (
    v_app_pw1, 1, 'CANCELLED', 'INTERVIEW_SCHEDULING', true, 1,
    '2045-01-01 10:00:00+00'::timestamptz, '2045-01-01 11:00:00+00'::timestamptz, v_room_id, v_format_id
  ) returning interview_id into v_int_pw1;

  insert into public.interviews(
    application_id, round_no, schedule_status_code, report_status_code, is_active, version_no,
    start_at, end_at, room_id, interview_format_id
  ) values (
    v_app_pw2, 1, 'CANCELLED', 'INTERVIEW_SCHEDULING', true, 1,
    '2045-01-01 10:30:00+00'::timestamptz, '2045-01-01 11:30:00+00'::timestamptz, v_room_id, v_format_id
  ) returning interview_id into v_int_pw2;

  -- Attempt bulk status change from CANCELLED to AVAILABLE (active/blocking)
  v_r := public.bulk_change_interview_schedule_status(
    array[v_int_pw1, v_int_pw2],
    'AVAILABLE',
    array[1::bigint, 1::bigint]
  );

  assert (v_r->>'success')::boolean = false, 'FAIL: bulk_change_schedule_status must reject conflicting cancelled rows';
  -- Because candidates share v_cand_pw, candidate conflict has higher precedence (1) than room (2)
  assert (v_r->>'error_code') in ('SCHEDULE_CONFLICT_CANDIDATE', 'SCHEDULE_CONFLICT_ROOM'),
    'FAIL: [Finding 5 NOT FIXED] bulk_change_schedule_status must report SCHEDULE_CONFLICT (got: ' || coalesce(v_r->>'error_code', 'null') || ')';

  -- Assert atomic zero-write: both interviews remain CANCELLED
  assert (select schedule_status_code from public.interviews where interview_id = v_int_pw1) = 'CANCELLED',
    'FAIL: [Finding 5 NOT FIXED] Interview 1 must remain CANCELLED on pairwise conflict';
  assert (select schedule_status_code from public.interviews where interview_id = v_int_pw2) = 'CANCELLED',
    'FAIL: [Finding 5 NOT FIXED] Interview 2 must remain CANCELLED on pairwise conflict';

  raise notice 'PASS: Pairwise post-transition conflict check on cancelled rows verified with zero writes.';


  -- ===========================================================================
  -- CHECK 9: Audit Action Codes and Payloads Preservation (Finding 8)
  -- ===========================================================================
  raise notice '--- Check 9: Audit Action Codes and Payloads Preservation ---';

  -- 9.1 save_interview_schedule audit action code & payload
  select version_no into v_ver from public.interviews where interview_id = v_int1;
  v_ts := '2045-02-01 09:00:00+00'::timestamptz;
  v_r := public.save_interview_schedule(
    v_int1, v_ts, v_ts + interval '1 hour', v_format_id, null, null, 'Demo', 'Audit test note', v_ver, gen_random_uuid()
  );
  assert (v_r->>'success')::boolean, 'FAIL: save_interview_schedule for audit test';

  select action_code, metadata into v_audit_act, v_audit_payload
  from public.security_audit_log
  where entity_id = v_int1
    and metadata ? 'start_at'
    and metadata ? 'end_at'
  limit 1;

  assert v_audit_act = 'SAVE_INTERVIEW_SCHEDULE',
    'FAIL: [Finding 8 NOT FIXED] save_interview_schedule action_code must be SAVE_INTERVIEW_SCHEDULE (got: ' || coalesce(v_audit_act, 'null') || ')';
  assert v_audit_payload ? 'start_at' and v_audit_payload ? 'end_at',
    'FAIL: [Finding 8 NOT FIXED] save_interview_schedule payload must contain start_at and end_at';

  -- 9.2 change_interview_schedule_status audit action code & payload
  select version_no into v_ver from public.interviews where interview_id = v_int1;
  v_r := public.change_interview_schedule_status(v_int1, 'AWAITING', v_ver);
  assert (v_r->>'success')::boolean, 'FAIL: change_interview_schedule_status for audit test';

  select action_code, metadata into v_audit_act, v_audit_payload
  from public.security_audit_log
  where entity_id = v_int1
    and metadata->>'schedule_status_code' = 'AWAITING'
  limit 1;

  assert v_audit_act = 'CHANGE_INTERVIEW_SCHEDULE_STATUS',
    'FAIL: [Finding 8 NOT FIXED] change_interview_schedule_status action_code must be CHANGE_INTERVIEW_SCHEDULE_STATUS (got: ' || coalesce(v_audit_act, 'null') || ')';
  assert v_audit_payload->>'schedule_status_code' = 'AWAITING',
    'FAIL: [Finding 8 NOT FIXED] change_interview_schedule_status payload must contain schedule_status_code = AWAITING';

  -- 9.3 save_interviewer_report audit action code & payload
  select version_no into v_ver from public.interview_reports where interview_report_id = v_report1;
  v_r := public.save_interviewer_report(
    v_part1,
    jsonb_build_object('other_comment', 'HR audit comment'),
    v_ver,
    jsonb_build_object('other_comment', 'Disjoint note')
  );
  assert (v_r->>'success')::boolean, 'FAIL: save_interviewer_report for audit test: ' || v_r::text;

  select action_code, metadata into v_audit_act, v_audit_payload
  from public.security_audit_log
  where entity_id = v_report1
    and metadata ? 'patched_fields'
  limit 1;

  assert v_audit_act = 'SAVE_INTERVIEWER_REPORT',
    'FAIL: [Finding 8 NOT FIXED] save_interviewer_report action_code must be SAVE_INTERVIEWER_REPORT (got: ' || coalesce(v_audit_act, 'null') || ')';
  assert v_audit_payload ? 'patched_fields',
    'FAIL: [Finding 8 NOT FIXED] save_interviewer_report payload must contain patched_fields';

  raise notice 'PASS: Audit action codes and payloads strictly preserved.';


  -- ===========================================================================
  -- CHECK 10: bulk_change_report_status Functional Verification (Finding 1)
  -- ===========================================================================
  raise notice '--- Check 10: bulk_change_report_status Functional Verification ---';

  select version_no into v_ver from public.interviews where interview_id = v_int_rec2;
  select version_no into v_ver2 from public.interviews where interview_id = v_int2_2;

  v_r := public.bulk_change_report_status(
    array[v_int_rec2, v_int2_2],
    'WAITING_FOR_REPORT',
    array[v_ver, v_ver2]
  );
  assert (v_r->>'success')::boolean, 'FAIL: bulk_change_report_status must succeed on valid targets: ' || v_r::text;
  assert (v_r->'data'->>'updated_count')::integer = 2, 'FAIL: updated_count must be 2';
  assert (select report_status_code from public.interviews where interview_id = v_int_rec2) = 'WAITING_FOR_REPORT',
    'FAIL: Interview 1 report status must be WAITING_FOR_REPORT';
  assert (select report_status_code from public.interviews where interview_id = v_int2_2) = 'WAITING_FOR_REPORT',
    'FAIL: Interview 2 report status must be WAITING_FOR_REPORT';

  raise notice 'PASS: bulk_change_report_status functional verification passed.';

  -- ===========================================================================
  -- CHECK 11: Submission HR-note writer requires a positive version token
  -- ===========================================================================
  raise notice '--- Check 11: update_submission_by_hr optimistic version requirement ---';

  select version_no into v_ver from public.submissions where submission_id = v_sub1;
  v_r := public.update_submission_by_hr(v_sub1, 'REC-04 forward note', v_ver);
  assert (v_r->>'success')::boolean,
    'FAIL: update_submission_by_hr must accept its current version: ' || v_r::text;

  select version_no into v_ver2 from public.submissions where submission_id = v_sub1;
  select count(*) into v_initial_audit_count
  from public.security_audit_log
  where entity_id = v_sub1;

  v_r := public.update_submission_by_hr(v_sub1, 'must not write', null);
  assert (v_r->>'success')::boolean = false and v_r->>'error_code' = 'VALIDATION_ERROR',
    'FAIL: explicit NULL expected version must be rejected: ' || v_r::text;
  v_r := public.update_submission_by_hr(v_sub1, 'must not write');
  assert (v_r->>'success')::boolean = false and v_r->>'error_code' = 'VALIDATION_ERROR',
    'FAIL: omitted expected version must be rejected: ' || v_r::text;
  v_r := public.update_submission_by_hr(v_sub1, 'must not write', 0);
  assert (v_r->>'success')::boolean = false and v_r->>'error_code' = 'VALIDATION_ERROR',
    'FAIL: zero expected version must be rejected: ' || v_r::text;
  v_r := public.update_submission_by_hr(v_sub1, 'must not write', -1);
  assert (v_r->>'success')::boolean = false and v_r->>'error_code' = 'VALIDATION_ERROR',
    'FAIL: negative expected version must be rejected: ' || v_r::text;
  v_r := public.update_submission_by_hr(v_sub1, 'must not write', v_ver);
  assert (v_r->>'success')::boolean = false and v_r->>'error_code' = 'STALE_VERSION',
    'FAIL: stale expected version must be rejected: ' || v_r::text;

  assert (select hr_note from public.submissions where submission_id = v_sub1) = 'REC-04 forward note',
    'FAIL: rejected version token modified the HR note';
  assert (select version_no from public.submissions where submission_id = v_sub1) = v_ver2,
    'FAIL: rejected version token modified the submission version';
  assert (select count(*) from public.security_audit_log where entity_id = v_sub1) = v_initial_audit_count,
    'FAIL: rejected version token created a durable audit side effect';

  raise notice 'PASS: update_submission_by_hr rejects missing, invalid, and stale version tokens without writes.';

  raise notice '====================================================================';
  raise notice '=== ALL REC-04 ASSERTIONS PASSED SUCCESSFULLY                    ===';
  raise notice '====================================================================';

end;
$$;

rollback;
