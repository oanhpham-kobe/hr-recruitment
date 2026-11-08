-- TASK-S03-004: bounded, RLS-preserving Application Inbox read model.
create or replace function public.list_application_inbox(
  p_query text default '',
  p_status text default 'ALL',
  p_date_from date default null,
  p_date_to date default null,
  p_candidate_activity text default 'ALL',
  p_new_read text default 'ALL',
  p_application text default 'ALL',
  p_page integer default 1,
  p_page_size integer default 10
)
returns table (
  candidate_id uuid,
  email text,
  is_candidate_active boolean,
  submission_id uuid,
  status_code text,
  full_name text,
  date_of_birth date,
  gender_code text,
  phone text,
  hr_note text,
  submitted_at timestamptz,
  has_application boolean,
  total_count bigint
)
language sql
security invoker
set search_path = ''
stable
as $$
  with ranked as (
    select
      s.submission_id, s.candidate_id, s.status_code, s.full_name,
      s.date_of_birth, s.gender_code, s.phone, s.hr_note, s.submitted_at,
      c.email::text as email, c.is_active as is_candidate_active,
      exists (select 1 from public.applications a where a.submission_id = s.submission_id) as has_application,
      row_number() over (
        partition by s.candidate_id
        order by s.submitted_at desc, s.submission_id desc
      ) as submission_rank
    from public.submissions s
    join public.candidates c on c.candidate_id = s.candidate_id
    where private.has_permission('submissions.view') or private.is_root_admin()
  ), latest as (
    select * from ranked where submission_rank = 1
  ), filtered as (
    select * from latest
    where (
      nullif(btrim(p_query), '') is null
      or full_name ilike '%' || btrim(p_query) || '%'
      or email ilike '%' || btrim(p_query) || '%'
      or phone ilike '%' || btrim(p_query) || '%'
    )
    and (p_status = 'ALL' or status_code = p_status)
    and (
      p_date_from is null
      or submitted_at >= p_date_from::timestamp at time zone 'Asia/Ho_Chi_Minh'
    )
    and (
      p_date_to is null
      or submitted_at < (p_date_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh'
    )
    and (p_candidate_activity = 'ALL' or (p_candidate_activity = 'ACTIVE') = is_candidate_active)
    and (p_new_read = 'ALL' or status_code = p_new_read)
    and (p_application = 'ALL' or (p_application = 'HAS_APPLICATION') = has_application)
  ), counted as (
    select *, count(*) over () as total_count from filtered
  ), paged as (
    select * from counted
    order by submitted_at desc, submission_id desc, candidate_id asc
    offset (
      (least(
        greatest(p_page, 1),
        greatest(ceil((select count(*) from filtered)::numeric / least(greatest(p_page_size, 1), 100)), 1)
      ) - 1) * least(greatest(p_page_size, 1), 100)
    )
    limit least(greatest(p_page_size, 1), 100)
  )
  select
    p.candidate_id, p.email, p.is_candidate_active,
    s.submission_id, s.status_code, s.full_name, s.date_of_birth,
    s.gender_code, s.phone, s.hr_note, s.submitted_at,
    exists (select 1 from public.applications a where a.submission_id = s.submission_id) as has_application,
    p.total_count
  from paged p
  join public.submissions s on s.candidate_id = p.candidate_id
  order by p.submitted_at desc, p.submission_id desc, p.candidate_id asc,
    s.submitted_at desc, s.submission_id desc;
$$;

revoke all on function public.list_application_inbox(text, text, date, date, text, text, text, integer, integer) from public, anon;
grant execute on function public.list_application_inbox(text, text, date, date, text, text, text, integer, integer) to authenticated;
