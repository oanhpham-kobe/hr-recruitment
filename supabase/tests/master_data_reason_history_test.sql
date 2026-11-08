-- TASK-S06-001 R1: ever-used cancellation/rejection reasons remain historical masters.
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_suffix text := substr(gen_random_uuid()::text, 1, 8);
  v_hr_auth uuid := gen_random_uuid();
  v_hr uuid;
  v_candidate uuid;
  v_unit uuid;
  v_group uuid;
  v_position uuid;
  v_cancel uuid;
  v_reject uuid;
  v_submission uuid;
  v_application uuid;
  v_interview uuid;
  v_version bigint;
  v_result jsonb;
begin
  insert into public.app_users(auth_user_id, email, full_name, is_active)
  values (v_hr_auth, 's06001_reason_' || v_suffix || '@eiu.edu.vn', 'S06 Reason HR', true)
  returning app_user_id into v_hr;

  -- S06-002 canonical active-Application owner eligibility requires the
  -- fixture HR owner to hold the HR role before an active Application exists.
  insert into public.app_user_roles(app_user_id, role_code)
  values (v_hr, 'HR');

  insert into public.app_user_permissions(app_user_id, permission_code)
  values
    (v_hr, 'master_data.manage'),
    (v_hr, 'interviews.view'),
    (v_hr, 'interviews.status'),
    (v_hr, 'reports.view'),
    (v_hr, 'reports.manage_status')
  on conflict do nothing;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth::text)::text, true);

  v_result := public.create_master_item(
    'organizational_units',
    jsonb_build_object('code', 'RH_UNIT_' || v_suffix, 'name_vi', 'Reason Unit'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_unit := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'position_groups',
    jsonb_build_object('code', 'RH_GROUP_' || v_suffix, 'name_vi', 'Reason Group'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_group := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'positions',
    jsonb_build_object(
      'unit_id', v_unit,
      'position_group_id', v_group,
      'code', 'RH_POS_' || v_suffix,
      'name_vi', 'Reason Position'
    ),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_position := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'cancellation_reasons',
    jsonb_build_object('code', 'RH_CANCEL_' || v_suffix, 'name_vi', 'Reason Cancel'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_cancel := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'rejection_reasons',
    jsonb_build_object('code', 'RH_REJECT_' || v_suffix, 'name_vi', 'Reason Reject'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_reject := (v_result->'data'->>'master_id')::uuid;

  insert into public.candidates(auth_user_id, email, is_active)
  values (gen_random_uuid(), 's06001_reason_candidate_' || v_suffix || '@example.com', true)
  returning candidate_id into v_candidate;

  insert into public.submissions(
    candidate_id, status_code, full_name, date_of_birth, gender_code,
    current_address, phone, email_snapshot
  ) values (
    v_candidate, 'PROCESSED', 'Reason Candidate', date '1990-01-01', 'MALE',
    'Address', '0900000000', 's06001_reason_candidate_' || v_suffix || '@example.com'
  ) returning submission_id into v_submission;

  insert into public.applications(submission_id, unit_id, position_id, hr_owner_id, is_active)
  values (v_submission, v_unit, v_position, v_hr, true)
  returning application_id into v_application;

  insert into public.interviews(
    application_id, round_no, schedule_status_code, report_status_code, is_active
  ) values (
    v_application, 1, 'AVAILABLE', 'INTERVIEW_SCHEDULING', true
  ) returning interview_id into v_interview;

  -- Cancellation reason becomes historical even after accepted lifecycle normalization clears the FK.
  update public.interviews
  set schedule_status_code = 'CANCELLED', cancellation_reason_id = v_cancel
  where interview_id = v_interview;
  assert (select cancellation_reason_id from public.interviews where interview_id = v_interview) = v_cancel;

  select version_no into v_version from public.interviews where interview_id = v_interview;
  v_result := public.change_interview_schedule_status(v_interview, 'AVAILABLE', v_version);
  assert (v_result->>'success')::boolean, 'accepted schedule lifecycle clears cancellation reason';
  assert (select cancellation_reason_id from public.interviews where interview_id = v_interview) is null,
    'cancellation FK is intentionally replaceable history state';

  select version_no into v_version from public.cancellation_reasons where cancellation_reason_id = v_cancel;
  v_result := public.update_master_item(
    'cancellation_reasons', v_cancel,
    jsonb_build_object('code', 'RH_CANCEL_REPURPOSE_' || v_suffix),
    v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY',
    'ever-used cancellation reason cannot be structurally repurposed after FK normalization';

  select version_no into v_version from public.cancellation_reasons where cancellation_reason_id = v_cancel;
  v_result := public.delete_or_inactivate_master_item(
    'cancellation_reasons', v_cancel, v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'ever-used cancellation reason is retained inactive, never hard-deleted';

  -- Rejection reason receives identical ever-used history protection.
  update public.interviews
  set report_status_code = 'REJECTED', rejection_reason_id = v_reject
  where interview_id = v_interview;
  assert (select rejection_reason_id from public.interviews where interview_id = v_interview) = v_reject;

  select version_no into v_version from public.interviews where interview_id = v_interview;
  v_result := public.change_report_status(v_interview, 'FOLLOW_UP', v_version);
  assert (v_result->>'success')::boolean, 'accepted report lifecycle clears rejection reason';
  assert (select rejection_reason_id from public.interviews where interview_id = v_interview) is null,
    'rejection FK is intentionally replaceable history state';

  select version_no into v_version from public.rejection_reasons where rejection_reason_id = v_reject;
  v_result := public.update_master_item(
    'rejection_reasons', v_reject,
    jsonb_build_object('code', 'RH_REJECT_REPURPOSE_' || v_suffix),
    v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY',
    'ever-used rejection reason cannot be structurally repurposed after FK normalization';

  select version_no into v_version from public.rejection_reasons where rejection_reason_id = v_reject;
  v_result := public.delete_or_inactivate_master_item(
    'rejection_reasons', v_reject, v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'ever-used rejection reason is retained inactive, never hard-deleted';
end;
$$;

rollback;
