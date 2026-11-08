-- TASK-S03-004 production list_application_inbox RPC contract.
-- Run only against an unlinked disposable local Supabase database after all migrations:
--   psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/application_inbox_read.sql
\set ON_ERROR_STOP on

begin;
insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_root_admin)
values
  ('00000000-0000-0000-0000-000000004001', '00000000-0000-0000-0000-000000004101', 'inbox-root@eiu.edu.vn', 'Inbox Root', true),
  ('00000000-0000-0000-0000-000000004002', '00000000-0000-0000-0000-000000004102', 'inbox-viewer@eiu.edu.vn', 'Inbox Viewer', false);

insert into public.app_user_permissions (app_user_id, permission_code, granted_by)
values ('00000000-0000-0000-0000-000000004002', 'submissions.view', '00000000-0000-0000-0000-000000004001');

insert into public.candidates (candidate_id, auth_user_id, email, current_full_name)
values
  ('00000000-0000-0000-0000-000000004201', '00000000-0000-0000-0000-000000004301', 'inbox-a@example.test', 'Candidate A'),
  ('00000000-0000-0000-0000-000000004202', '00000000-0000-0000-0000-000000004302', 'inbox-b@example.test', 'Candidate B'),
  ('00000000-0000-0000-0000-000000004203', '00000000-0000-0000-0000-000000004303', 'inbox-c@example.test', 'Candidate C');

insert into public.submissions (
  submission_id, candidate_id, full_name, date_of_birth, gender_code,
  current_address, phone, email_snapshot, hr_note, submitted_at
)
values
  ('00000000-0000-0000-0000-000000004501', '00000000-0000-0000-0000-000000004201', 'Candidate A historical', '2000-01-01', 'FEMALE', 'Address A', '0900000401', 'inbox-a@example.test', 'Historical A', '2026-08-31 16:59:59+00'),
  ('00000000-0000-0000-0000-000000004502', '00000000-0000-0000-0000-000000004201', 'Candidate A latest', '2000-01-01', 'FEMALE', 'Address A', '0900000401', 'inbox-a@example.test', 'Latest A', '2026-09-01 00:30:00+00'),
  ('00000000-0000-0000-0000-000000004503', '00000000-0000-0000-0000-000000004202', 'Candidate B', '2000-01-02', 'MALE', 'Address B', '0900000402', 'inbox-b@example.test', 'Latest B', '2026-09-01 16:59:59+00'),
  ('00000000-0000-0000-0000-000000004504', '00000000-0000-0000-0000-000000004203', 'Candidate C', '2000-01-03', 'FEMALE', 'Address C', '0900000403', 'inbox-c@example.test', 'Excluded on local 2026-09-01', '2026-09-01 17:00:00+00');

do $$
begin
  assert has_function_privilege('authenticated', 'public.list_application_inbox(text,text,date,date,text,text,text,integer,integer)', 'execute');
  assert not has_function_privilege('anon', 'public.list_application_inbox(text,text,date,date,text,text,text,integer,integer)', 'execute');
  assert not has_function_privilege('public', 'public.list_application_inbox(text,text,date,date,text,text,text,integer,integer)', 'execute');
end;
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000004102', false);
set role authenticated;

do $$
declare
  v_filtered_candidate_ids uuid[];
  v_candidate_a_submission_ids uuid[];
  v_total_count bigint;
  v_invalid_size_candidate_count bigint;
begin
  select array_agg(candidate_id order by candidate_id), min(total_count)
    into v_filtered_candidate_ids, v_total_count
  from (
    select distinct candidate_id, total_count
    from public.list_application_inbox('', 'ALL', '2026-09-01', '2026-09-01', 'ALL', 'ALL', 'ALL', 1, 25)
  ) filtered;
  assert v_filtered_candidate_ids = array[
    '00000000-0000-0000-0000-000000004201'::uuid,
    '00000000-0000-0000-0000-000000004202'::uuid
  ], 'date filtering uses Asia/Ho_Chi_Minh calendar bounds';
  assert v_total_count = 2, 'date filtering counts Candidate groups, not Submission rows';

  select array_agg(submission_id order by submitted_at desc, submission_id desc)
    into v_candidate_a_submission_ids
  from public.list_application_inbox('', 'ALL', '2026-09-01', '2026-09-01', 'ALL', 'ALL', 'ALL', 1, 25)
  where candidate_id = '00000000-0000-0000-0000-000000004201'::uuid;

  assert v_candidate_a_submission_ids = array[
    '00000000-0000-0000-0000-000000004502'::uuid,
    '00000000-0000-0000-0000-000000004501'::uuid
  ], 'Candidate page returns the complete historical group in deterministic child order';

  select count(distinct candidate_id)
    into v_invalid_size_candidate_count
  from public.list_application_inbox('', 'ALL', '2026-09-01', '2026-09-01', 'ALL', 'ALL', 'ALL', 1, 1);

  assert v_invalid_size_candidate_count = 2,
    'invalid page size falls back to canonical 25 instead of weakening the RPC contract';
end;
$$;

reset role;
rollback;
