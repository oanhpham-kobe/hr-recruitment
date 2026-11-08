-- RECOVERY PACKAGE 001: F02 Confidentiality Baseline Reproduction Assertions
-- Pre-condition: supabase/tests/recovery_confidentiality_fixture.sql has been committed.
-- Probes effective RLS and grants using genuine SET LOCAL ROLE authenticated
-- with explicit assertions that rolsuper=false and rolbypassrls=false.
-- Demonstrates the F02 defect on raw tables before repair, while proving that
-- the safe RPC (get_interviewer_report_page) already enforces confidentiality.

\set ON_ERROR_STOP on

begin;

do $$
declare
  -- Stable synthetic UUIDs seeded by recovery_confidentiality_fixture.sql
  c_hr_auth constant uuid := 'f0200000-0000-0000-0000-000000000101'::uuid;
  c_hr_user constant uuid := 'f0200000-0000-0000-0000-000000000102'::uuid;
  c_assigned_auth constant uuid := 'f0200000-0000-0000-0000-000000000201'::uuid;
  c_assigned_user constant uuid := 'f0200000-0000-0000-0000-000000000202'::uuid;
  c_unassigned_auth constant uuid := 'f0200000-0000-0000-0000-000000000301'::uuid;
  c_removed_auth constant uuid := 'f0200000-0000-0000-0000-000000000401'::uuid;
  c_hidden_auth constant uuid := 'f0200000-0000-0000-0000-000000000501'::uuid;
  c_inactive_auth constant uuid := 'f0200000-0000-0000-0000-000000000601'::uuid;
  c_candidate_auth constant uuid := 'f0200000-0000-0000-0000-000000000701'::uuid;

  c_app1 constant uuid := 'f0200000-0000-0000-0000-000000000802'::uuid;
  c_app2 constant uuid := 'f0200000-0000-0000-0000-000000000803'::uuid;
  c_vis_r1 constant uuid := 'f0200000-0000-0000-0000-000000000901'::uuid;
  c_vis_r2 constant uuid := 'f0200000-0000-0000-0000-000000000902'::uuid;
  c_hid_r1 constant uuid := 'f0200000-0000-0000-0000-000000000903'::uuid;
  c_report constant uuid := 'f0200000-0000-0000-0000-000000000b01'::uuid;

  v_count integer;
  v_leaked_hr_note text;
  v_leaked_decision_by uuid;
  v_leaked_decision_at timestamptz;
  v_leaked_created_by uuid;
  v_leaked_updated_by uuid;
  v_rpc_res jsonb;
  v_cur_user text;
  v_is_super boolean;
  v_bypass boolean;
begin
  raise notice '====================================================================';
  raise notice '=== CHECK 1: Catalog privilege audit for authenticated & anon    ===';
  raise notice '====================================================================';
  assert (select count(*) = 2 from pg_roles where rolname in ('authenticated', 'anon') and rolsuper = false and rolbypassrls = false),
    'FAIL: authenticated and anon roles must exist and have rolsuper=false and rolbypassrls=false';

  assert not has_table_privilege('anon', 'public.interviews', 'SELECT'),
    'FAIL: anon must not have SELECT privilege on public.interviews';
  assert not has_table_privilege('anon', 'public.interview_reports', 'SELECT'),
    'FAIL: anon must not have SELECT privilege on public.interview_reports';
  assert not has_table_privilege('anon', 'public.applications', 'SELECT'),
    'FAIL: anon must not have SELECT privilege on public.applications';
  assert not has_function_privilege('anon', 'public.get_interviewer_report_page()', 'EXECUTE'),
    'FAIL: anon must not execute public.get_interviewer_report_page';
  assert not has_function_privilege('anon', 'public.get_hr_report_page(integer,integer,text,text,text,text)', 'EXECUTE'),
    'FAIL: anon must not execute public.get_hr_report_page';
  raise notice 'PASS: Anonymous role is completely denied from raw tables and safe RPCs.';

  -- ====================================================================
  -- CHECK 2: Assigned Interviewer Baseline Probes (The Defect Demonstration)
  -- ====================================================================
  raise notice '====================================================================';
  raise notice '=== CHECK 2: Assigned Interviewer (SET LOCAL ROLE authenticated) ===';
  raise notice '====================================================================';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_assigned_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_assigned_auth::text, true);
  execute 'set local role authenticated';

  -- Verify active security context
  select current_user into v_cur_user;
  select rolsuper, rolbypassrls into v_is_super, v_bypass from pg_roles where rolname = v_cur_user;
  assert v_cur_user = 'authenticated' and v_is_super = false and v_bypass = false,
    'FAIL: Active execution context must be authenticated with rolsuper=false and rolbypassrls=false';

  -- 2.1 DEFECT PROBE 1: interviews.hr_report_note leakage via direct SELECT
  select hr_report_note into v_leaked_hr_note
  from public.interviews
  where interview_id = c_vis_r2;

  assert v_leaked_hr_note is not null and v_leaked_hr_note = 'CONFIDENTIAL_HR_NOTE_ROUND_2_CURRENT_LEAK',
    'FAIL: Expected baseline defect not observed: interviews.hr_report_note was not returned to assigned interviewer';
  raise notice '[BASELINE DEFECT OBSERVED] interviews.hr_report_note leaked to Assigned Interviewer via direct table SELECT: "%"', v_leaked_hr_note;

  -- 2.2 DEFECT PROBE 2: interview_reports technical source/audit metadata leakage via direct SELECT
  select decision_updated_by, decision_updated_at, created_by, updated_by
  into v_leaked_decision_by, v_leaked_decision_at, v_leaked_created_by, v_leaked_updated_by
  from public.interview_reports
  where interview_report_id = c_report;

  assert v_leaked_decision_by is not null and v_leaked_decision_by = c_assigned_user,
    'FAIL: Expected baseline defect not observed: interview_reports.decision_updated_by was not returned';
  assert v_leaked_decision_at is not null,
    'FAIL: Expected baseline defect not observed: interview_reports.decision_updated_at was not returned';
  raise notice '[BASELINE DEFECT OBSERVED] interview_reports technical source metadata leaked via direct SELECT: decision_updated_by=%, decision_updated_at=%, created_by=%',
    v_leaked_decision_by, v_leaked_decision_at, v_leaked_created_by;

  -- 2.3 CONTRACT PROBE: get_interviewer_report_page() satisfies Review Pack 06/39/59
  v_rpc_res := public.get_interviewer_report_page();
  assert (v_rpc_res->>'success')::boolean = true,
    'FAIL: Assigned interviewer must execute get_interviewer_report_page() successfully';
  assert jsonb_array_length(v_rpc_res->'data'->'rounds') = 2,
    'FAIL: get_interviewer_report_page() must return both participated rounds (historical Round 1 and current Round 2)';
  assert position('CONFIDENTIAL_HR_NOTE' in v_rpc_res::text) = 0,
    'FAIL: Safe RPC must omit hr_report_note';
  assert position('decision_updated_by' in v_rpc_res::text) = 0,
    'FAIL: Safe RPC must omit decision_updated_by';
  assert position('decision_updated_at' in v_rpc_res::text) = 0,
    'FAIL: Safe RPC must omit decision_updated_at';
  assert position('f02_candidate@example.com' in v_rpc_res::text) = 0,
    'FAIL: Safe RPC must omit candidate email';
  raise notice 'PASS: Safe RPC (get_interviewer_report_page) correctly satisfies canonical historical read and confidentiality.';

  execute 'reset role';

  -- ====================================================================
  -- CHECK 3: Removed Interviewer Probes
  -- ====================================================================
  raise notice '--- Check 3: Removed Interviewer Context ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_removed_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_removed_auth::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from public.interviews where interview_id = c_vis_r2;
  assert v_count = 0, 'FAIL: Removed participant must NOT select from public.interviews';
  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 0, 'FAIL: Removed participant must NOT select from public.interview_reports';

  v_rpc_res := public.get_interviewer_report_page();
  assert jsonb_array_length(v_rpc_res->'data'->'rounds') = 0,
    'FAIL: Removed participant must see 0 rounds in safe RPC';
  raise notice 'PASS: Removed Interviewer correctly denied from interviews and reports.';

  execute 'reset role';

  -- ====================================================================
  -- CHECK 4: Hidden Session Interviewer Probes
  -- ====================================================================
  raise notice '--- Check 4: Hidden Session Interviewer Context ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_hidden_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_hidden_auth::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from public.interviews where interview_id = c_hid_r1;
  assert v_count = 0, 'FAIL: Hidden session must return 0 rows to Interviewer from public.interviews';

  v_rpc_res := public.get_interviewer_report_page();
  assert jsonb_array_length(v_rpc_res->'data'->'rounds') = 0,
    'FAIL: Hidden session must not appear in safe RPC';
  raise notice 'PASS: Hidden session correctly denied from interviews and safe RPC.';

  execute 'reset role';

  -- ====================================================================
  -- CHECK 5: Unassigned Interviewer Probes
  -- ====================================================================
  raise notice '--- Check 5: Unassigned Interviewer Context ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_unassigned_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_unassigned_auth::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2, c_hid_r1);
  assert v_count = 0, 'FAIL: Unassigned Interviewer must see 0 interviews';
  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 0, 'FAIL: Unassigned Interviewer must see 0 reports';

  v_rpc_res := public.get_interviewer_report_page();
  assert jsonb_array_length(v_rpc_res->'data'->'rounds') = 0,
    'FAIL: Unassigned Interviewer must see 0 rounds in safe RPC';
  raise notice 'PASS: Unassigned Interviewer correctly sees 0 records.';

  execute 'reset role';

  -- ====================================================================
  -- CHECK 6: Inactive Internal User Probes
  -- ====================================================================
  raise notice '--- Check 6: Inactive Internal User Context ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_inactive_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_inactive_auth::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2);
  assert v_count = 0, 'FAIL: Inactive user must see 0 interviews';
  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 0, 'FAIL: Inactive user must see 0 reports';

  v_rpc_res := public.get_interviewer_report_page();
  assert v_rpc_res->>'error_code' = 'USER_INACTIVE',
    'FAIL: Inactive internal user must fail closed with USER_INACTIVE';
  raise notice 'PASS: Inactive internal user fails closed.';

  execute 'reset role';

  -- ====================================================================
  -- CHECK 7: Candidate Persona Probes
  -- ====================================================================
  raise notice '--- Check 7: Candidate Persona Context ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_candidate_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_candidate_auth::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2);
  assert v_count = 0, 'FAIL: Candidate must see 0 interviews';
  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 0, 'FAIL: Candidate must see 0 reports';
  select count(*) into v_count from public.applications where application_id in (c_app1, c_app2);
  assert v_count = 0, 'FAIL: Candidate must see 0 applications';

  v_rpc_res := public.get_interviewer_report_page();
  assert v_rpc_res->>'error_code' = 'FORBIDDEN',
    'FAIL: Candidate identity must be rejected by safe RPC with FORBIDDEN';
  raise notice 'PASS: Candidate identity has zero internal access.';

  execute 'reset role';

  -- ====================================================================
  -- CHECK 8: Legitimate HR User (Positive Control)
  -- ====================================================================
  raise notice '====================================================================';
  raise notice '=== CHECK 8: Legitimate HR User (interviews.view + reports.view) ===';
  raise notice '====================================================================';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_hr_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_hr_auth::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2);
  assert v_count = 2, 'FAIL: HR must see both interviews for Application 1 via interviews.view';
  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 1, 'FAIL: HR must see the participant report via reports.view';

  v_rpc_res := public.get_hr_report_page(1, 20, null, 'ALL', 'Nguyễn Văn Ứng Viên F02', 'CANDIDATE_ASC');
  assert (v_rpc_res->>'success')::boolean = true, 'FAIL: HR report RPC must succeed for reports.view';
  assert position('CONFIDENTIAL_HR_NOTE_ROUND_2_CURRENT_LEAK' in v_rpc_res::text) > 0,
    'FAIL: Legitimate HR must see hr_report_note through get_hr_report_page';
  assert position('HIRE_RECOMMENDED_CONFIDENTIAL_DECISION' in v_rpc_res::text) > 0,
    'FAIL: Legitimate HR must see conclusion through get_hr_report_page';
  raise notice 'PASS: Legitimate HR retains full direct and projection-based report management access.';

  execute 'reset role';

  raise notice '====================================================================';
  raise notice '=== BASELINE REPRODUCTION SUITE COMPLETE: LEAKS CONFIRMED        ===';
  raise notice '====================================================================';
end $$;

rollback;
