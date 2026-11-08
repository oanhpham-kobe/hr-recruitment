-- RECOVERY PACKAGE 001: F02 Confidentiality Post-Repair Verification
-- Pre-condition: recovery_confidentiality_fixture.sql committed,
--                20260927010000_f02_interview_confidentiality_repair.sql applied.
-- Proves: Interviewer contextual arms removed; confidential fields no longer
-- leak via raw table SELECT; safe RPCs still work; HR/Root retain full access.

\set ON_ERROR_STOP on

begin;

do $$
declare
  -- Stable synthetic UUIDs seeded by recovery_confidentiality_fixture.sql
  c_hr_auth constant uuid := 'f0200000-0000-0000-0000-000000000101'::uuid;
  c_assigned_auth constant uuid := 'f0200000-0000-0000-0000-000000000201'::uuid;
  c_unassigned_auth constant uuid := 'f0200000-0000-0000-0000-000000000301'::uuid;
  c_removed_auth constant uuid := 'f0200000-0000-0000-0000-000000000401'::uuid;
  c_hidden_auth constant uuid := 'f0200000-0000-0000-0000-000000000501'::uuid;
  c_inactive_auth constant uuid := 'f0200000-0000-0000-0000-000000000601'::uuid;
  c_candidate_auth constant uuid := 'f0200000-0000-0000-0000-000000000701'::uuid;

  c_vis_r1 constant uuid := 'f0200000-0000-0000-0000-000000000901'::uuid;
  c_vis_r2 constant uuid := 'f0200000-0000-0000-0000-000000000902'::uuid;
  c_hid_r1 constant uuid := 'f0200000-0000-0000-0000-000000000903'::uuid;
  c_report constant uuid := 'f0200000-0000-0000-0000-000000000b01'::uuid;

  v_count integer;
  v_rpc_res jsonb;
  v_cur_user text;
  v_is_super boolean;
  v_bypass boolean;
begin
  raise notice '====================================================================';
  raise notice '=== POST-REPAIR VERIFICATION: F02 Confidentiality Closed         ===';
  raise notice '====================================================================';

  -- CHECK 1: Catalog audit (unchanged)
  assert (select count(*) = 2 from pg_roles where rolname in ('authenticated', 'anon') and rolsuper = false and rolbypassrls = false),
    'FAIL: authenticated and anon must have rolsuper=false and rolbypassrls=false';
  raise notice 'PASS: Catalog privilege audit.';

  -- ====================================================================
  -- CHECK 2: Assigned Interviewer — raw table access DENIED
  -- ====================================================================
  raise notice '--- Check 2: Assigned Interviewer raw table access (must be 0) ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_assigned_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_assigned_auth::text, true);
  execute 'set local role authenticated';

  select current_user into v_cur_user;
  select rolsuper, rolbypassrls into v_is_super, v_bypass from pg_roles where rolname = v_cur_user;
  assert v_cur_user = 'authenticated' and v_is_super = false and v_bypass = false,
    'FAIL: Must be non-privileged authenticated';

  -- REPAIR PROOF 1: No raw interview rows
  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2);
  assert v_count = 0,
    'FAIL: [F02 NOT FIXED] Assigned Interviewer can still SELECT raw interviews!';
  raise notice 'PASS: Assigned Interviewer sees 0 raw interview rows (confidentiality closed).';

  -- REPAIR PROOF 2: No raw report rows
  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 0,
    'FAIL: [F02 NOT FIXED] Assigned Interviewer can still SELECT raw interview_reports!';
  raise notice 'PASS: Assigned Interviewer sees 0 raw report rows (confidentiality closed).';

  -- REPAIR PROOF 3: Safe RPC still works
  v_rpc_res := public.get_interviewer_report_page();
  assert (v_rpc_res->>'success')::boolean = true,
    'FAIL: Safe RPC must still succeed for assigned Interviewer';
  assert jsonb_array_length(v_rpc_res->'data'->'rounds') = 2,
    'FAIL: Safe RPC must return both participated rounds (historical + current)';
  assert position('CONFIDENTIAL_HR_NOTE' in v_rpc_res::text) = 0,
    'FAIL: Safe RPC must omit hr_report_note';
  assert position('decision_updated_by' in v_rpc_res::text) = 0,
    'FAIL: Safe RPC must omit decision_updated_by';
  raise notice 'PASS: Safe RPC (get_interviewer_report_page) still serves correct Interviewer data.';

  execute 'reset role';

  -- ====================================================================
  -- CHECK 3: Removed Interviewer — still denied
  -- ====================================================================
  raise notice '--- Check 3: Removed Interviewer ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_removed_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_removed_auth::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.interviews where interview_id = c_vis_r2;
  assert v_count = 0, 'FAIL: Removed must see 0 interviews';
  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 0, 'FAIL: Removed must see 0 reports';
  raise notice 'PASS: Removed Interviewer denied.';
  execute 'reset role';

  -- ====================================================================
  -- CHECK 4: Hidden Session Interviewer — still denied
  -- ====================================================================
  raise notice '--- Check 4: Hidden Session Interviewer ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_hidden_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_hidden_auth::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.interviews where interview_id = c_hid_r1;
  assert v_count = 0, 'FAIL: Hidden must see 0 interviews';
  raise notice 'PASS: Hidden session Interviewer denied.';
  execute 'reset role';

  -- ====================================================================
  -- CHECK 5: Unassigned Interviewer — still denied
  -- ====================================================================
  raise notice '--- Check 5: Unassigned Interviewer ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_unassigned_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_unassigned_auth::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2, c_hid_r1);
  assert v_count = 0, 'FAIL: Unassigned must see 0 interviews';
  raise notice 'PASS: Unassigned Interviewer denied.';
  execute 'reset role';

  -- ====================================================================
  -- CHECK 6: Inactive Internal User — still denied
  -- ====================================================================
  raise notice '--- Check 6: Inactive Internal User ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_inactive_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_inactive_auth::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2);
  assert v_count = 0, 'FAIL: Inactive must see 0 interviews';
  raise notice 'PASS: Inactive user denied.';
  execute 'reset role';

  -- ====================================================================
  -- CHECK 7: Candidate — still denied
  -- ====================================================================
  raise notice '--- Check 7: Candidate ---';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_candidate_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_candidate_auth::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2);
  assert v_count = 0, 'FAIL: Candidate must see 0 interviews';
  raise notice 'PASS: Candidate denied.';
  execute 'reset role';

  -- ====================================================================
  -- CHECK 8: HR Positive Control — full access preserved
  -- ====================================================================
  raise notice '====================================================================';
  raise notice '=== CHECK 8: Legitimate HR User (must retain full access)        ===';
  raise notice '====================================================================';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', c_hr_auth::text)::text, true);
  perform set_config('request.jwt.claim.sub', c_hr_auth::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from public.interviews where interview_id in (c_vis_r1, c_vis_r2);
  assert v_count = 2, 'FAIL: HR must see both interviews via interviews.view';

  select count(*) into v_count from public.interview_reports where interview_report_id = c_report;
  assert v_count = 1, 'FAIL: HR must see report via reports.view';

  v_rpc_res := public.get_hr_report_page(1, 20, null, 'ALL', 'Nguyễn Văn Ứng Viên F02', 'CANDIDATE_ASC');
  assert (v_rpc_res->>'success')::boolean = true, 'FAIL: HR RPC must succeed';
  assert position('CONFIDENTIAL_HR_NOTE_ROUND_2_CURRENT_LEAK' in v_rpc_res::text) > 0,
    'FAIL: HR must see hr_report_note through RPC';
  raise notice 'PASS: HR retains full raw table and RPC access.';

  execute 'reset role';

  raise notice '====================================================================';
  raise notice '=== POST-REPAIR VERIFICATION COMPLETE: F02 CONFIDENTIALITY CLOSED===';
  raise notice '====================================================================';
end $$;

rollback;
