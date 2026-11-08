-- TASK-S05-002 independent-review regression: reports.view alone must not
-- receive the raw Interview meeting URL through the HR Report projection.
\set ON_ERROR_STOP on

do $$
declare
  v_auth uuid := gen_random_uuid();
  v_user uuid;
  v_target_interview uuid;
  v_result jsonb;
begin
  select i.interview_id
    into v_target_interview
  from public.interviews i
  where i.hr_report_note = 'Current HR note'
  order by i.interview_id
  limit 1;

  assert v_target_interview is not null,
    'HR management regression fixture must run before DTO privacy regression';

  update public.interviews
  set meeting_link = 'https://meet.example.test/reports-view-must-not-see-this'
  where interview_id = v_target_interview;

  insert into public.app_users(auth_user_id, full_name, email, is_active)
  values (
    v_auth,
    'S05-002 Reports View Only',
    's05002_view_only_' || substr(gen_random_uuid()::text, 1, 8) || '@eiu.edu.vn',
    true
  )
  returning app_user_id into v_user;

  insert into public.app_user_permissions(app_user_id, permission_code)
  values (v_user, 'reports.view');

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth::text)::text,
    true
  );

  v_result := public.get_hr_report_page(
    1,
    20,
    null,
    'ALL',
    'S05-002 Candidate',
    'CANDIDATE_ASC'
  );

  assert (v_result->>'success')::boolean,
    'reports.view-only actor may read the minimum-safe HR Report projection';
  assert position('meeting_link' in v_result::text) = 0,
    'HR Report DTO must omit the raw meeting_link field';
  assert position('reports-view-must-not-see-this' in v_result::text) = 0,
    'HR Report DTO must not disclose raw Interview meeting URL content';

  raise notice 'TASK-S05-002 reports.view-only DTO privacy assertions passed';
end;
$$;
