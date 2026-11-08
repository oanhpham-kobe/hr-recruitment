-- App Tuyển dụng EIU — Identity & Authorization Schema Migration
-- Slice 01 / TASK-S01-001: app_users, candidates, roles, permissions, auth mapping, and RLS
-- Source authority:
--   recruitment_webapp/review_pack/database_schema.sql
--   recruitment_webapp/review_pack/40_DATABASE_INVARIANTS.md
--   recruitment_webapp/review_pack/39_SECURITY_RLS_MATRIX.md
--   recruitment_webapp/review_pack/59_RLS_POLICY_BLUEPRINT.md

-- -----------------------------------------------------------------------------
-- 1. Master Data & Organizational Structure
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

-- -----------------------------------------------------------------------------
-- 2. Internal Personnel (app_users)
-- -----------------------------------------------------------------------------
create table if not exists public.app_users (
  app_user_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,
  email extensions.citext not null unique,
  full_name text not null,
  job_title text,
  unit_id uuid references public.organizational_units(unit_id) on delete restrict,
  is_active boolean not null default true,
  is_root_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1,
  constraint internal_email_domain_ck check (lower(email::text) ~ '^[^@[:space:]]+@eiu\.edu\.vn$')
);

create unique index if not exists one_root_admin_uq
  on public.app_users ((is_root_admin))
  where is_root_admin = true;

create index if not exists app_users_unit_id_idx on public.app_users(unit_id);

-- -----------------------------------------------------------------------------
-- 3. Roles, Permissions & Dependencies
-- -----------------------------------------------------------------------------
create table if not exists public.app_user_roles (
  app_user_id uuid not null references public.app_users(app_user_id) on delete restrict,
  role_code text not null check (role_code in ('HR')),
  created_at timestamptz not null default now(),
  primary key (app_user_id, role_code)
);

create table if not exists public.permissions (
  permission_code text primary key,
  description text not null
);

create table if not exists public.app_user_permissions (
  app_user_id uuid not null references public.app_users(app_user_id) on delete restrict,
  permission_code text not null references public.permissions(permission_code) on delete restrict,
  granted_by uuid references public.app_users(app_user_id) on delete restrict,
  granted_at timestamptz not null default now(),
  primary key (app_user_id, permission_code)
);

create index if not exists app_user_permissions_permission_code_idx on public.app_user_permissions(permission_code);
create index if not exists app_user_permissions_granted_by_idx on public.app_user_permissions(granted_by);

create table if not exists public.permission_dependencies (
  permission_code text not null references public.permissions(permission_code) on delete cascade,
  requires_permission_code text not null references public.permissions(permission_code) on delete cascade,
  primary key (permission_code, requires_permission_code),
  constraint permission_dependency_not_self_ck check (permission_code <> requires_permission_code)
);

create index if not exists permission_dependencies_requires_idx on public.permission_dependencies(requires_permission_code);

-- -----------------------------------------------------------------------------
-- 4. Candidates
-- -----------------------------------------------------------------------------
create table if not exists public.candidates (
  candidate_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  email extensions.citext not null unique,
  current_full_name text,
  current_phone text,
  last_submission_at timestamptz,
  is_active boolean not null default true,
  inactive_at timestamptz,
  inactive_by uuid references public.app_users(app_user_id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1,
  constraint candidate_inactive_metadata_ck check (
    (is_active = true and inactive_at is null and inactive_by is null)
    or (is_active = false and inactive_at is not null and inactive_by is not null)
  )
);

create index if not exists candidates_inactive_by_idx on public.candidates(inactive_by);

-- -----------------------------------------------------------------------------
-- 5. Version Touch Triggers
-- -----------------------------------------------------------------------------
create trigger organizational_units_touch_version
  before update on public.organizational_units
  for each row execute function private.touch_version();

create trigger app_users_touch_version
  before update on public.app_users
  for each row execute function private.touch_version();

create trigger candidates_touch_version
  before update on public.candidates
  for each row execute function private.touch_version();

-- -----------------------------------------------------------------------------
-- 6. Private Identity & Authorization Helpers (SECURITY DEFINER, empty search_path)
-- -----------------------------------------------------------------------------
-- Ensure authenticated role has usage on schema private to call approved functions
grant usage on schema private to authenticated;

create or replace function private.current_app_user_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.app_user_id
  from public.app_users u
  where u.auth_user_id = (select auth.uid())
    and u.is_active = true
  limit 1;
$$;

create or replace function private.is_root_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.app_users u
    where u.auth_user_id = (select auth.uid())
      and u.is_active = true
      and u.is_root_admin = true
  );
$$;

create or replace function private.has_permission(p_permission_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_permission_code is null then false
    when private.is_root_admin() then true
    else exists (
      select 1
      from public.app_user_permissions aup
      where aup.app_user_id = private.current_app_user_id()
        and aup.permission_code = p_permission_code
    )
  end;
$$;

create or replace function private.current_candidate_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.candidate_id
  from public.candidates c
  where c.auth_user_id = (select auth.uid())
    and c.is_active = true
  limit 1;
$$;

revoke all on function private.current_app_user_id() from public, anon;
grant execute on function private.current_app_user_id() to authenticated, postgres, service_role;

revoke all on function private.is_root_admin() from public, anon;
grant execute on function private.is_root_admin() to authenticated, postgres, service_role;

revoke all on function private.has_permission(text) from public, anon;
grant execute on function private.has_permission(text) to authenticated, postgres, service_role;

revoke all on function private.current_candidate_id() from public, anon;
grant execute on function private.current_candidate_id() to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 7. Row Level Security & Minimal-Grant Policies
-- -----------------------------------------------------------------------------
alter table public.organizational_units enable row level security;
alter table public.app_users enable row level security;
alter table public.app_user_roles enable row level security;
alter table public.permissions enable row level security;
alter table public.app_user_permissions enable row level security;
alter table public.permission_dependencies enable row level security;
alter table public.candidates enable row level security;

-- Revoke direct DML from untrusted roles
revoke insert, update, delete on public.organizational_units from anon, authenticated;
revoke insert, update, delete on public.app_users from anon, authenticated;
revoke insert, update, delete on public.app_user_roles from anon, authenticated;
revoke insert, update, delete on public.permissions from anon, authenticated;
revoke insert, update, delete on public.app_user_permissions from anon, authenticated;
revoke insert, update, delete on public.permission_dependencies from anon, authenticated;
revoke insert, update, delete on public.candidates from anon, authenticated;

-- Allow SELECT under RLS evaluation
grant select on public.organizational_units to authenticated, anon;
grant select on public.app_users to authenticated, anon;
grant select on public.app_user_roles to authenticated, anon;
grant select on public.permissions to authenticated, anon;
grant select on public.app_user_permissions to authenticated, anon;
grant select on public.permission_dependencies to authenticated, anon;
grant select on public.candidates to authenticated, anon;

-- Explicit full grants to trusted service and administration roles
grant all on public.organizational_units to postgres, service_role;
grant all on public.app_users to postgres, service_role;
grant all on public.app_user_roles to postgres, service_role;
grant all on public.permissions to postgres, service_role;
grant all on public.app_user_permissions to postgres, service_role;
grant all on public.permission_dependencies to postgres, service_role;
grant all on public.candidates to postgres, service_role;

-- SELECT Policies:
-- app_users: authenticated users can SELECT own record, or all active records if private.has_permission('users.directory_read')
create policy app_users_select_policy on public.app_users
  for select
  to authenticated
  using (
    auth_user_id = (select auth.uid())
    or (
      is_active = true
      and private.has_permission('users.directory_read')
    )
  );

-- candidates: authenticated candidate can SELECT own record, or internal user if private.has_permission('submissions.view')
create policy candidates_select_policy on public.candidates
  for select
  to authenticated
  using (
    auth_user_id = (select auth.uid())
    or private.has_permission('submissions.view')
  );

-- app_user_roles: users can SELECT own roles, or if user has users.directory_read
create policy app_user_roles_select_policy on public.app_user_roles
  for select
  to authenticated
  using (
    app_user_id = private.current_app_user_id()
    or private.has_permission('users.directory_read')
  );

-- app_user_permissions: users can SELECT own permissions, or if user has users.directory_read
create policy app_user_permissions_select_policy on public.app_user_permissions
  for select
  to authenticated
  using (
    app_user_id = private.current_app_user_id()
    or private.has_permission('users.directory_read')
  );

-- organizational_units, permissions, permission_dependencies: readable by authenticated internal users
create policy organizational_units_select_policy on public.organizational_units
  for select
  to authenticated
  using (
    private.current_app_user_id() is not null
  );

create policy permissions_select_policy on public.permissions
  for select
  to authenticated
  using (
    private.current_app_user_id() is not null
  );

create policy permission_dependencies_select_policy on public.permission_dependencies
  for select
  to authenticated
  using (
    private.current_app_user_id() is not null
  );

-- -----------------------------------------------------------------------------
-- 8. Canonical Permissions & Dependencies Seed
-- -----------------------------------------------------------------------------
insert into public.permissions(permission_code, description) values
  ('submissions.view','View application submissions'),
  ('submissions.edit','Edit HR-editable submission fields'),
  ('submissions.status','Change submission status'),
  ('candidates.active_manage','Activate/inactivate candidate accounts'),
  ('candidates.delete_unused','Hard-delete unused Candidate only'),
  ('applications.manage','Manage applications'),
  ('interviews.view','View interviews'),
  ('interviews.manage','Create/edit/copy/delete-or-inactivate interviews'),
  ('interviews.status','Change interview schedule status'),
  ('interviews.participants','Manage interview participants'),
  ('interviews.documents','Manage interview documents'),
  ('interviews.email','Send interview operational email'),
  ('emails.history_view','View operational Email History within parent context'),
  ('emails.history_delete','Delete operational Email History under frozen cleanup rule'),
  ('reports.view','View report pages/preview/PDF'),
  ('reports.manage_status','Manage report status/HR report note'),
  ('reports.visibility','Hide/show record to interviewers'),
  ('reports.edit_interviewer','Edit an interviewer report'),
  ('reports.delete','Delete/inactivate report by rule'),
  ('master_data.manage','Manage allowed master data'),
  ('users.directory_read','Read internal user directory and roles/permissions'),
  ('users.directory_manage','Manage internal user directory/business profile; unbound email typo only'),
  ('users.identity_manage','Manage bound Auth identity — Root Admin only'),
  ('users.permissions_manage','Manage HR permissions — Root Admin only')
on conflict (permission_code) do update set description = excluded.description;

insert into public.permission_dependencies(permission_code, requires_permission_code) values
  ('submissions.edit','submissions.view'),
  ('submissions.status','submissions.view'),
  ('applications.manage','submissions.view'),
  ('interviews.manage','interviews.view'),
  ('interviews.status','interviews.view'),
  ('interviews.participants','interviews.view'),
  ('interviews.documents','interviews.view'),
  ('interviews.email','interviews.view'),
  ('reports.manage_status','reports.view'),
  ('reports.visibility','reports.view'),
  ('reports.edit_interviewer','reports.view'),
  ('reports.delete','reports.view'),
  ('emails.history_delete','emails.history_view'),
  ('users.directory_manage','users.directory_read')
on conflict do nothing;
