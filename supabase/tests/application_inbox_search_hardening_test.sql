-- TASK-S08-001 focused Application Inbox search/index regression.
-- Run against an unlinked disposable local Supabase database after all migrations.
\set ON_ERROR_STOP on

begin;

insert into public.app_users (
  app_user_id, auth_user_id, email, full_name, is_root_admin
) values
  (
    '00000000-0000-0000-0000-000000008001',
    '00000000-0000-0000-0000-000000008101',
    's08-root@eiu.edu.vn',
    'S08 Root',
    true
  ),
  (
    '00000000-0000-0000-0000-000000008002',
    '00000000-0000-0000-0000-000000008102',
    's08-viewer@eiu.edu.vn',
    'S08 Viewer',
    false
  ),
  (
    '00000000-0000-0000-0000-000000008003',
    '00000000-0000-0000-0000-000000008103',
    's08-denied@eiu.edu.vn',
    'S08 Denied',
    false
  );

insert into public.app_user_permissions (
  app_user_id, permission_code, granted_by
) values (
  '00000000-0000-0000-0000-000000008002',
  'submissions.view',
  '00000000-0000-0000-0000-000000008001'
);

insert into public.candidates (
  candidate_id, auth_user_id, email, current_full_name
) values
  (
    '00000000-0000-0000-0000-000000008201',
    '00000000-0000-0000-0000-000000008301',
    'Search.Alpha@example.test',
    'Nguyễn Thị Ánh'
  ),
  (
    '00000000-0000-0000-0000-000000008202',
    '00000000-0000-0000-0000-000000008302',
    'search.beta@example.test',
    'Trần Minh Bình'
  );

insert into public.submissions (
  submission_id,
  candidate_id,
  status_code,
  full_name,
  date_of_birth,
  gender_code,
  current_address,
  phone,
  email_snapshot,
  submitted_at
) values
  (
    '00000000-0000-0000-0000-000000008401',
    '00000000-0000-0000-0000-000000008201',
    'READ',
    'Nguyễn Thị Ánh historical',
    '1995-01-01',
    'FEMALE',
    'Address A',
    '0901 234 567',
    'old.alpha@example.test',
    '2026-09-18 01:00:00+00'
  ),
  (
    '00000000-0000-0000-0000-000000008402',
    '00000000-0000-0000-0000-000000008201',
    'READ',
    'Nguyễn Thị Ánh',
    '1995-01-01',
    'FEMALE',
    'Address A',
    '0901 234 567',
    'snapshot.alpha@example.test',
    '2026-09-19 01:00:00+00'
  ),
  (
    '00000000-0000-0000-0000-000000008404',
    '00000000-0000-0000-0000-000000008202',
    'READ',
    'Legacy Search Match',
    '1994-01-01',
    'MALE',
    'Address B old',
    '0912-000-000',
    'old.beta@example.test',
    '2026-09-19 12:00:00+00'
  ),
  (
    '00000000-0000-0000-0000-000000008403',
    '00000000-0000-0000-0000-000000008202',
    'NEW',
    'Trần Minh Bình',
    '1994-01-01',
    'MALE',
    'Address B',
    '0987-654-321',
    'snapshot.beta@example.test',
    '2026-09-20 01:00:00+00'
  );

-- Search helpers must be genuinely immutable and the intended predicate indexes
-- must exist on the actual authoritative columns/expressions.
do $$
declare
  v_volatility "char";
begin
  select p.provolatile
    into v_volatility
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private'
    and p.proname = 'normalize_vietnamese_search_text'
    and pg_get_function_identity_arguments(p.oid) = 'p_value text';

  assert v_volatility = 'i',
    'Vietnamese search normalization must be IMMUTABLE';

  assert to_regclass('public.submissions_full_name_vi_search_trgm_idx') is not null,
    'accent-normalized Name trigram index must exist';
  assert to_regclass('public.candidates_email_lower_prefix_idx') is not null,
    'Candidate email prefix index must exist on authoritative Candidate email';
  assert to_regclass('public.submissions_phone_digits_prefix_idx') is not null,
    'digit-normalized Phone prefix index must exist';
end;
$$;

-- Representative planner evidence: with sequential scans disabled, PostgreSQL
-- must be able to choose each S08 predicate index. This proves index eligibility,
-- not production p95 latency.
do $$
declare
  v_line record;
  v_plan text;
begin
  perform set_config('enable_seqscan', 'off', true);

  v_plan := '';
  for v_line in execute $q$
    explain
    select submission_id
    from public.submissions
    where private.normalize_vietnamese_search_text(full_name)
      like '%nguyen%'
  $q$ loop
    v_plan := v_plan || v_line."QUERY PLAN" || E'\n';
  end loop;
  assert position('submissions_full_name_vi_search_trgm_idx' in v_plan) > 0,
    'planner can use normalized Name trigram index';

  v_plan := '';
  for v_line in execute $q$
    explain
    select candidate_id
    from public.candidates
    where lower(email::text) like 'search.alpha@%'
  $q$ loop
    v_plan := v_plan || v_line."QUERY PLAN" || E'\n';
  end loop;
  assert position('candidates_email_lower_prefix_idx' in v_plan) > 0,
    'planner can use Candidate email prefix index';

  v_plan := '';
  for v_line in execute $q$
    explain
    select submission_id
    from public.submissions
    where regexp_replace(phone, '[^0-9]', '', 'g') like '0901234%'
  $q$ loop
    v_plan := v_plan || v_line."QUERY PLAN" || E'\n';
  end loop;
  assert position('submissions_phone_digits_prefix_idx' in v_plan) > 0,
    'planner can use digit-normalized Phone prefix index';
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000008102',
  false
);
set role authenticated;

-- Accent-insensitive broad Name search.
do $$
declare
  v_ids uuid[];
begin
  select array_agg(distinct candidate_id order by candidate_id)
    into v_ids
  from public.list_application_inbox(
    'nguyen thi anh', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );

  assert v_ids = array[
    '00000000-0000-0000-0000-000000008201'::uuid
  ], 'unaccented query must match Vietnamese accented latest Name';
end;
$$;

-- Search predicates apply only to the Candidate's latest Submission. An older
-- matching Name must not promote that Candidate into the result set.
do $$
declare
  v_ids uuid[];
begin
  select array_agg(distinct candidate_id order by candidate_id)
    into v_ids
  from public.list_application_inbox(
    'legacy search', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );

  assert v_ids is null,
    'historical Name match must not surface a Candidate whose latest Submission does not match';
end;
$$;

-- Email search authority is current Candidate email, not Submission snapshot.
do $$
declare
  v_ids uuid[];
begin
  select array_agg(distinct candidate_id order by candidate_id)
    into v_ids
  from public.list_application_inbox(
    'SEARCH.ALPHA@', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );

  assert v_ids = array[
    '00000000-0000-0000-0000-000000008201'::uuid
  ], 'Email prefix search is case-insensitive on authoritative Candidate email';

  select array_agg(distinct candidate_id order by candidate_id)
    into v_ids
  from public.list_application_inbox(
    'snapshot.alpha@', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );

  assert v_ids is null,
    'Submission email_snapshot is not silently substituted for Candidate email authority';
end;
$$;

-- Formatted phone matches digit-normalized prefix.
do $$
declare
  v_ids uuid[];
begin
  select array_agg(distinct candidate_id order by candidate_id)
    into v_ids
  from public.list_application_inbox(
    '0901234', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );

  assert v_ids = array[
    '00000000-0000-0000-0000-000000008201'::uuid
  ], 'Phone search must normalize formatting to digits';
end;
$$;

-- One-character generic Name search must not become a broad scan, and SQL LIKE
-- wildcard characters supplied by the user must be treated literally.
do $$
declare
  v_count bigint;
begin
  select count(*) into v_count
  from public.list_application_inbox(
    'n', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );
  assert v_count = 0,
    'one-character generic Name query must not return broad matches';

  select count(*) into v_count
  from public.list_application_inbox(
    'Search.%@example.test', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );
  assert v_count = 0,
    'Email wildcard characters must be escaped and treated literally';

  select count(*) into v_count
  from public.list_application_inbox(
    'Ng_%', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );
  assert v_count = 0,
    'Name wildcard characters must be escaped and treated literally';
end;
$$;

-- The RPC default is canonical 25 and only 25/50/100 are accepted. Invalid
-- sizes fall back to 25; Candidate-group pagination still returns full history.
do $$
declare
  v_default text;
  v_invalid_size_ids uuid[];
  v_child_ids uuid[];
begin
  select pg_get_function_arguments(p.oid)
    into v_default
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'list_application_inbox'
  limit 1;

  assert position('p_page_size integer DEFAULT 25' in v_default) > 0,
    'RPC default page size must remain 25';

  select array_agg(distinct candidate_id order by candidate_id)
    into v_invalid_size_ids
  from public.list_application_inbox(
    '', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 1
  );

  assert v_invalid_size_ids = array[
    '00000000-0000-0000-0000-000000008201'::uuid,
    '00000000-0000-0000-0000-000000008202'::uuid
  ], 'invalid page size must fall back to canonical 25';

  select array_agg(submission_id order by submitted_at desc, submission_id desc)
    into v_child_ids
  from public.list_application_inbox(
    '', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  )
  where candidate_id = '00000000-0000-0000-0000-000000008201'::uuid;

  assert v_child_ids = array[
    '00000000-0000-0000-0000-000000008402'::uuid,
    '00000000-0000-0000-0000-000000008401'::uuid
  ], 'Candidate group returns complete historical Submission children';
end;
$$;

reset role;

-- Authenticated caller without submissions.view/root authority gets no PII rows.
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000008103',
  false
);
set role authenticated;

do $$
declare
  v_count bigint;
begin
  select count(*) into v_count
  from public.list_application_inbox(
    '', 'ALL', null, null,
    'ALL', 'ALL', 'ALL', 1, 25
  );
  assert v_count = 0,
    'caller without submissions.view must not receive Application Inbox rows';
end;
$$;

reset role;
rollback;
