-- Migration: 20260905100000_application_schema_and_status_commands.sql
-- TASK-S03-001: Application Inbox status calculation schema and manual status transition commands

-- -----------------------------------------------------------------------------
-- 0. Master Data Tables (prerequisites for applications and interviews)
-- -----------------------------------------------------------------------------

create table if not exists public.organizational_units (
  unit_id uuid primary key default gen_random_uuid(),
  code text unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.department_teams (
  department_team_id uuid primary key default gen_random_uuid(),
  constraint department_team_zero_uuid_reserved_ck check (department_team_id <> '00000000-0000-0000-0000-000000000000'::uuid),
  unit_id uuid not null references public.organizational_units(unit_id) on delete restrict,
  code text,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1,
  unique(unit_id, code)
);

create table if not exists public.position_groups (
  position_group_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  requires_demo_topic boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.positions (
  position_id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.organizational_units(unit_id) on delete restrict,
  department_team_id uuid references public.department_teams(department_team_id) on delete restrict,
  position_group_id uuid not null references public.position_groups(position_group_id) on delete restrict,
  code text,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.interview_formats (
  interview_format_id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name_vi text not null,
  name_en text,
  requires_room boolean not null default false,
  requires_meeting_link boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.rooms (
  room_id uuid primary key default gen_random_uuid(),
  code text unique,
  display_name text not null,
  building text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

-- Enable RLS on master data
alter table public.organizational_units enable row level security;
alter table public.department_teams enable row level security;
alter table public.position_groups enable row level security;
alter table public.positions enable row level security;
alter table public.interview_formats enable row level security;
alter table public.rooms enable row level security;

-- Master data grants & policies (read for authenticated)
revoke all on public.organizational_units, public.department_teams, public.position_groups, public.positions, public.interview_formats, public.rooms from public, anon;
grant select on public.organizational_units, public.department_teams, public.position_groups, public.positions, public.interview_formats, public.rooms to authenticated;
grant all on public.organizational_units, public.department_teams, public.position_groups, public.positions, public.interview_formats, public.rooms to postgres, service_role;

create policy organizational_units_select on public.organizational_units for select to authenticated using (true);
create policy department_teams_select on public.department_teams for select to authenticated using (true);
create policy position_groups_select on public.position_groups for select to authenticated using (true);
create policy positions_select on public.positions for select to authenticated using (true);
create policy interview_formats_select on public.interview_formats for select to authenticated using (true);
create policy rooms_select on public.rooms for select to authenticated using (true);

-- -----------------------------------------------------------------------------
-- 1. Schema Definitions: applications and interviews
-- -----------------------------------------------------------------------------

create table if not exists public.applications (
  application_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete restrict,
  unit_id uuid not null references public.organizational_units(unit_id) on delete restrict,
  department_team_id uuid references public.department_teams(department_team_id) on delete restrict,
  position_id uuid not null references public.positions(position_id) on delete restrict,
  hr_owner_id uuid not null references public.app_users(app_user_id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(app_user_id) on delete restrict,
  version_no bigint not null default 1
);

-- Zero UUID sentinel used for NULL-team durable identity uniqueness
create unique index if not exists application_durable_identity_uq
  on public.applications(
    submission_id,
    unit_id,
    coalesce(department_team_id, '00000000-0000-0000-0000-000000000000'::uuid),
    position_id
  );

create index if not exists applications_submission_idx on public.applications(submission_id);
create index if not exists applications_hr_owner_idx on public.applications(hr_owner_id) where is_active = true;

create table if not exists public.interviews (
  interview_id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(application_id) on delete restrict,
  round_no integer not null check (round_no > 0),
  demo_topic text,
  start_at timestamptz,
  end_at timestamptz,
  interview_format_id uuid references public.interview_formats(interview_format_id) on delete restrict,
  room_id uuid references public.rooms(room_id) on delete restrict,
  meeting_link text,
  schedule_status_code text not null default 'AVAILABLE'
    check (schedule_status_code in ('AVAILABLE','SCHEDULED','AWAITING','CONFIRMED','CANCELLED')),
  report_status_code text not null default 'INTERVIEW_SCHEDULING'
    check (report_status_code in ('INTERVIEW_SCHEDULING','AWAITING_INTERVIEW','WAITING_FOR_REPORT','REPORT_SUBMITTED','FOLLOW_UP','ON_HOLD','HIRED','REJECTED')),
  notes text,
  hr_report_note text,
  copied_from_interview_id uuid references public.interviews(interview_id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1,
  unique(application_id, round_no)
);

create index if not exists interviews_application_idx on public.interviews(application_id);
create index if not exists interviews_active_idx on public.interviews(is_active);

-- Enable RLS
alter table public.applications enable row level security;
alter table public.interviews enable row level security;

-- Grants
revoke all on public.applications, public.interviews from public, anon;
grant select on public.applications, public.interviews to authenticated;
grant all on public.applications, public.interviews to postgres, service_role;

-- Policies
create policy applications_select on public.applications
  for select to authenticated
  using (
    private.has_permission('submissions.view')
    or private.has_permission('applications.view')
    or private.is_root_admin()
  );

create policy interviews_select on public.interviews
  for select to authenticated
  using (
    private.has_permission('interviews.view')
    or private.has_permission('submissions.view')
    or private.is_root_admin()
  );

-- -----------------------------------------------------------------------------
-- 2. recalculate_submission_status
-- Authoritative status recalculation based on active applications and outcomes
-- -----------------------------------------------------------------------------
create or replace function public.recalculate_submission_status(
  p_submission_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_status text;
  v_new_status text;
  v_active_apps integer;
  v_has_hired boolean;
  v_all_rejected boolean;
begin
  -- Mandatory parent lock
  select status_code into v_current_status
  from public.submissions
  where submission_id = p_submission_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Submission not found'
    );
  end if;

  -- Count active applications
  select count(*) into v_active_apps
  from public.applications
  where submission_id = p_submission_id
    and is_active = true;

  if v_active_apps = 0 then
    -- Rule: if no active application exists, preserve existing manual NEW or READ.
    -- If coming from a derived state (PROCESSED, DONE, CLOSED), return READ.
    if v_current_status in ('PROCESSED', 'DONE', 'CLOSED') then
      v_new_status := 'READ';
    else
      v_new_status := v_current_status;
    end if;
  else
    -- Active applications exist:
    -- Check if any active application is HIRED
    select exists (
      select 1
      from public.interviews i
      join public.applications a on a.application_id = i.application_id
      where a.submission_id = p_submission_id
        and a.is_active = true
        and i.is_active = true
        and i.report_status_code = 'HIRED'
    ) into v_has_hired;

    if v_has_hired then
      v_new_status := 'DONE';
    else
      -- Check if all active applications are REJECTED
      select (
        v_active_apps > 0
        and not exists (
          select 1
          from public.applications a
          where a.submission_id = p_submission_id
            and a.is_active = true
            and not exists (
              select 1
              from public.interviews i
              where i.application_id = a.application_id
                and i.is_active = true
                and i.report_status_code = 'REJECTED'
            )
        )
      ) into v_all_rejected;

      if v_all_rejected then
        v_new_status := 'CLOSED';
      else
        v_new_status := 'PROCESSED';
      end if;
    end if;
  end if;

  -- Atomic update if status changed
  if v_new_status <> v_current_status then
    update public.submissions
    set
      status_code = v_new_status,
      updated_at = clock_timestamp()
    where submission_id = p_submission_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', p_submission_id,
      'status_code', v_new_status,
      'previous_status_code', v_current_status
    )
  );
end;
$$;

revoke all on function public.recalculate_submission_status(uuid) from public, anon;
grant execute on function public.recalculate_submission_status(uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. open_submission
-- Conditional mutation: NEW -> READ if actor has submissions.status; pure read otherwise
-- -----------------------------------------------------------------------------
create or replace function public.open_submission(
  p_submission_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_view boolean;
  v_has_status boolean;
  v_sub record;
  v_status text;
begin
  -- 1. Authorization check
  v_has_view := private.has_permission('submissions.view') or private.is_root_admin();
  if not v_has_view then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.view required to open submission'
    );
  end if;

  v_has_status := private.has_permission('submissions.status') or private.is_root_admin();

  -- 2. Query submission
  select * into v_sub
  from public.submissions
  where submission_id = p_submission_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Submission not found'
    );
  end if;

  v_status := v_sub.status_code;

  -- 3. Conditional Mutation: NEW -> READ if caller has submissions.status
  if v_has_status and v_sub.status_code = 'NEW' then
    update public.submissions
    set
      status_code = 'READ',
      updated_at = clock_timestamp()
    where submission_id = p_submission_id;

    v_status := 'READ';
  end if;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', v_sub.submission_id,
      'candidate_id', v_sub.candidate_id,
      'status_code', v_status,
      'full_name', v_sub.full_name,
      'email', v_sub.email,
      'phone', v_sub.phone,
      'date_of_birth', v_sub.date_of_birth,
      'gender', v_sub.gender,
      'address', v_sub.address,
      'candidate_notes', v_sub.candidate_notes,
      'submitted_at', v_sub.submitted_at,
      'version_no', v_sub.version_no
    )
  );
end;
$$;

revoke all on function public.open_submission(uuid) from public, anon;
grant execute on function public.open_submission(uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 4. set_submission_manual_status
-- Deterministic latest-submission manual status transition (NEW <-> READ)
-- -----------------------------------------------------------------------------
create or replace function public.set_submission_manual_status(
  p_candidate_id uuid,
  p_status_code text,
  p_expected_latest_submission_id uuid,
  p_expected_version bigint,
  p_idempotency_key uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_status boolean;
  v_latest record;
  v_active_apps integer;
  v_new_version bigint;
begin
  -- 1. Authorization check
  v_has_status := private.has_permission('submissions.status') or private.is_root_admin();
  if not v_has_status then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.status required to manually change status'
    );
  end if;

  -- 2. Validate requested status (AC-STAT-01: only NEW and READ allowed)
  if p_status_code not in ('NEW', 'READ') then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_ACTION',
      'message', 'PROCESSED, DONE, and CLOSED are system-derived only and cannot be assigned manually'
    );
  end if;

  -- 3. Lock candidate row (Lock 1)
  perform 1
  from public.candidates
  where candidate_id = p_candidate_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Candidate not found'
    );
  end if;

  -- 4. Resolve latest submission deterministically (Lock 2)
  select * into v_latest
  from public.submissions
  where candidate_id = p_candidate_id
  order by submitted_at desc, submission_id desc
  limit 1
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'No submissions found for candidate'
    );
  end if;

  -- 5. Historical submission guard (AC-HIST-SUB-01)
  if v_latest.submission_id <> p_expected_latest_submission_id then
    return jsonb_build_object(
      'success', false,
      'error_code', 'HISTORICAL_SUBMISSION_READ_ONLY',
      'message', 'Only the latest submission of a candidate may be manually changed'
    );
  end if;

  -- 6. Optimistic version guard
  if v_latest.version_no <> p_expected_version then
    return jsonb_build_object(
      'success', false,
      'error_code', 'STALE_VERSION',
      'message', 'Submission version mismatch'
    );
  end if;

  -- 7. Active application guard (AC-STAT-03)
  select count(*) into v_active_apps
  from public.applications
  where submission_id = v_latest.submission_id
    and is_active = true;

  if v_active_apps > 0 then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_STATE',
      'message', 'Neither NEW nor READ may be written manually while any active Application exists'
    );
  end if;

  -- 8. Mutation
  v_new_version := v_latest.version_no + 1;
  update public.submissions
  set
    status_code = p_status_code,
    version_no = v_new_version,
    updated_at = clock_timestamp()
  where submission_id = v_latest.submission_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', v_latest.submission_id,
      'status_code', p_status_code,
      'version_no', v_new_version
    )
  );
end;
$$;

revoke all on function public.set_submission_manual_status(uuid, text, uuid, bigint, uuid) from public, anon;
grant execute on function public.set_submission_manual_status(uuid, text, uuid, bigint, uuid) to authenticated, postgres, service_role;
