-- Migration: 20260906060000_interview_schema_and_conflict_locking.sql
-- SLICE-04: Interview Round and Schedule schema migration, conflict locking, and participant data model

-- -----------------------------------------------------------------------------
-- 1. Master Data Tables: cancellation_reasons & rejection_reasons
-- -----------------------------------------------------------------------------
create table if not exists public.cancellation_reasons (
  cancellation_reason_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.rejection_reasons (
  rejection_reason_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

-- Version triggers for cancellation_reasons & rejection_reasons
drop trigger if exists cancellation_reasons_touch_version on public.cancellation_reasons;
create trigger cancellation_reasons_touch_version
  before update on public.cancellation_reasons
  for each row execute function private.touch_version();

drop trigger if exists rejection_reasons_touch_version on public.rejection_reasons;
create trigger rejection_reasons_touch_version
  before update on public.rejection_reasons
  for each row execute function private.touch_version();

-- RLS & Grants for cancellation_reasons & rejection_reasons
alter table public.cancellation_reasons enable row level security;
alter table public.rejection_reasons enable row level security;

revoke all on public.cancellation_reasons, public.rejection_reasons from public, anon;
grant select on public.cancellation_reasons, public.rejection_reasons to authenticated;
grant all on public.cancellation_reasons, public.rejection_reasons to postgres, service_role;

drop policy if exists cancellation_reasons_select on public.cancellation_reasons;
create policy cancellation_reasons_select on public.cancellation_reasons
  for select to authenticated using (true);

drop policy if exists rejection_reasons_select on public.rejection_reasons;
create policy rejection_reasons_select on public.rejection_reasons
  for select to authenticated using (true);

-- -----------------------------------------------------------------------------
-- 2. Alter public.interviews with canonical columns & constraints
-- -----------------------------------------------------------------------------
alter table public.interviews
  add column if not exists cancellation_reason_id uuid references public.cancellation_reasons(cancellation_reason_id) on delete restrict,
  add column if not exists rejection_reason_id uuid references public.rejection_reasons(rejection_reason_id) on delete restrict,
  add column if not exists visible_to_interviewers boolean not null default true,
  add column if not exists interview_note text,
  add column if not exists updated_by uuid references public.app_users(app_user_id) on delete restrict;

-- Migrate notes data to interview_note if notes column exists
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'interviews' and column_name = 'notes'
  ) then
    update public.interviews
    set interview_note = coalesce(interview_note, notes)
    where notes is not null and interview_note is null;
  end if;
end $$;

-- Enforce valid time range check: start_at must be before end_at
alter table public.interviews
  drop constraint if exists interview_time_range_ck;
alter table public.interviews
  add constraint interview_time_range_ck check (start_at is null or end_at is null or start_at < end_at);

-- Foreign key for copied_from_interview_id with RESTRICT semantics
alter table public.interviews
  drop constraint if exists interviews_copied_from_interview_id_fkey;
alter table public.interviews
  add constraint interviews_copied_from_interview_id_fkey
  foreign key (copied_from_interview_id) references public.interviews(interview_id) on delete restrict;

-- Update upload_reservations foreign key to restrict on interview deletion
alter table public.upload_reservations
  drop constraint if exists upload_reservations_interview_fk;
alter table public.upload_reservations
  add constraint upload_reservations_interview_fk
  foreign key (interview_id) references public.interviews(interview_id) on delete restrict;

create index if not exists upload_reservations_interview_idx
  on public.upload_reservations(interview_id) where interview_id is not null;

-- Canonical performance indexes on interviews
drop index if exists public.interviews_application_idx;
create index if not exists interviews_application_idx
  on public.interviews(application_id, round_no desc);

create index if not exists interviews_time_idx
  on public.interviews(start_at, end_at)
  where is_active = true;

create index if not exists interviews_room_time_idx
  on public.interviews(room_id, start_at, end_at)
  where is_active = true and room_id is not null;

-- -----------------------------------------------------------------------------
-- 3. Create public.interview_participants table
-- -----------------------------------------------------------------------------
create table if not exists public.interview_participants (
  interview_participant_id uuid primary key default gen_random_uuid(),
  interview_id uuid not null references public.interviews(interview_id) on delete restrict,
  app_user_id uuid not null references public.app_users(app_user_id) on delete restrict,
  participant_order integer not null check (participant_order > 0),
  snapshot_name text not null,
  snapshot_job_title text,
  snapshot_email citext not null,
  is_current boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  removed_at timestamptz,
  version_no bigint not null default 1
);

create unique index if not exists current_participant_user_uq
  on public.interview_participants(interview_id, app_user_id)
  where is_current = true;

create unique index if not exists current_participant_order_uq
  on public.interview_participants(interview_id, participant_order)
  where is_current = true;

create index if not exists participant_user_idx
  on public.interview_participants(app_user_id, interview_id)
  where is_current = true;

-- Version triggers
drop trigger if exists interviews_touch_version on public.interviews;
create trigger interviews_touch_version
  before update on public.interviews
  for each row execute function private.touch_version();

drop trigger if exists interview_participants_touch_version on public.interview_participants;
create trigger interview_participants_touch_version
  before update on public.interview_participants
  for each row execute function private.touch_version();

-- -----------------------------------------------------------------------------
-- 4. Trigger Guards: Format requirements, Reason normalization, Participant lifecycle
-- -----------------------------------------------------------------------------
create or replace function private.validate_interview_format_requirements()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  req_room boolean;
  req_link boolean;
  fmt_active boolean;
  format_changed boolean;
begin
  if new.schedule_status_code in ('SCHEDULED','AWAITING','CONFIRMED') and (new.start_at is null or new.end_at is null) then
    raise exception 'start_at and end_at are required for scheduled/awaiting/confirmed interview' using errcode = '23514';
  end if;
  if new.start_at is null and new.end_at is null then
    return new;
  end if;
  if new.interview_format_id is null then
    raise exception 'interview format is required when interview time is set' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' then
    format_changed := true;
  else
    format_changed := (new.interview_format_id is distinct from old.interview_format_id);
  end if;

  select f.requires_room, f.requires_meeting_link, f.is_active into req_room, req_link, fmt_active
  from public.interview_formats f
  where f.interview_format_id = new.interview_format_id;
  if not found then
    raise exception 'interview format not found' using errcode = '23503';
  end if;
  if format_changed and coalesce(fmt_active, false) = false then
    raise exception 'inactive interview format cannot be selected for a new/change operation' using errcode = '23514';
  end if;

  -- Normalize stale resources when switching format.
  if coalesce(req_room, false) = false then new.room_id := null; end if;
  if coalesce(req_link, false) = false then new.meeting_link := null; end if;

  if req_room and new.room_id is null then
    raise exception 'room is required by interview format' using errcode = '23514';
  end if;
  if req_link and nullif(btrim(new.meeting_link), '') is null then
    raise exception 'meeting link is required by interview format' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists interview_format_requirements_guard on public.interviews;
create trigger interview_format_requirements_guard
  before insert or update of start_at, end_at, interview_format_id, room_id, meeting_link, schedule_status_code on public.interviews
  for each row execute function private.validate_interview_format_requirements();

create or replace function private.normalize_interview_reason_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.schedule_status_code <> 'CANCELLED' then
    new.cancellation_reason_id := null;
  end if;
  if new.report_status_code <> 'REJECTED' then
    new.rejection_reason_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists interview_reason_normalize_guard on public.interviews;
create trigger interview_reason_normalize_guard
  before insert or update of schedule_status_code, report_status_code, cancellation_reason_id, rejection_reason_id on public.interviews
  for each row execute function private.normalize_interview_reason_fields();

create or replace function private.validate_participant_lifecycle_and_user()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  user_active boolean;
begin
  if not ((new.is_current = true and new.removed_at is null) or (new.is_current = false and new.removed_at is not null)) then
    raise exception 'PARTICIPANT_LIFECYCLE_INVALID' using errcode = '23514';
  end if;

  if new.is_current = true and (tg_op = 'INSERT' or old.is_current is distinct from new.is_current or old.app_user_id is distinct from new.app_user_id) then
    select is_active into user_active from public.app_users where app_user_id = new.app_user_id;
    if coalesce(user_active, false) = false then
      raise exception 'USER_INACTIVE_NOT_SELECTABLE' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists participant_lifecycle_user_guard on public.interview_participants;
create trigger participant_lifecycle_user_guard
  before insert or update of is_current, removed_at, app_user_id on public.interview_participants
  for each row execute function private.validate_participant_lifecycle_and_user();

create or replace function private.validate_active_master_references()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  ok boolean;
begin
  if tg_table_name = 'interviews' then
    if new.room_id is not null and (tg_op = 'INSERT' or new.room_id is distinct from old.room_id) then
      select is_active into ok from public.rooms where room_id = new.room_id;
      if coalesce(ok, false) = false then raise exception 'INACTIVE_ROOM_NOT_SELECTABLE' using errcode = '23514'; end if;
    end if;
    if new.interview_format_id is not null and (tg_op = 'INSERT' or new.interview_format_id is distinct from old.interview_format_id) then
      select is_active into ok from public.interview_formats where interview_format_id = new.interview_format_id;
      if coalesce(ok, false) = false then raise exception 'INACTIVE_INTERVIEW_FORMAT_NOT_SELECTABLE' using errcode = '23514'; end if;
    end if;
    if new.cancellation_reason_id is not null and (tg_op = 'INSERT' or new.cancellation_reason_id is distinct from old.cancellation_reason_id) then
      select is_active into ok from public.cancellation_reasons where cancellation_reason_id = new.cancellation_reason_id;
      if coalesce(ok, false) = false then raise exception 'INACTIVE_CANCELLATION_REASON_NOT_SELECTABLE' using errcode = '23514'; end if;
    end if;
    if new.rejection_reason_id is not null and (tg_op = 'INSERT' or new.rejection_reason_id is distinct from old.rejection_reason_id) then
      select is_active into ok from public.rejection_reasons where rejection_reason_id = new.rejection_reason_id;
      if coalesce(ok, false) = false then raise exception 'INACTIVE_REJECTION_REASON_NOT_SELECTABLE' using errcode = '23514'; end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists interview_active_master_guard on public.interviews;
create trigger interview_active_master_guard
  before insert or update of room_id, interview_format_id, cancellation_reason_id, rejection_reason_id on public.interviews
  for each row execute function private.validate_active_master_references();

-- Update block_ineligible_hr_owner_lifecycle to defend future interview participant reassignments
create or replace function private.block_ineligible_hr_owner_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'app_users' then
    if old.is_active = true and new.is_active = false and exists (
      select 1 from public.applications a where a.hr_owner_id = old.app_user_id and a.is_active = true
    ) then
      raise exception 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED' using errcode = '23514';
    end if;
    if old.is_active = true and new.is_active = false and exists (
      select 1 from public.interview_participants ip
      join public.interviews i on i.interview_id = ip.interview_id
      join public.applications a on a.application_id = i.application_id
      where ip.app_user_id = old.app_user_id
        and ip.is_current = true
        and a.is_active = true
        and i.is_active = true
        and i.schedule_status_code <> 'CANCELLED'
        and i.start_at is not null
        and i.end_at is not null
        and i.end_at > clock_timestamp()
    ) then
      raise exception 'FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED' using errcode = '23514';
    end if;
  elsif tg_table_name = 'app_user_roles' then
    if (tg_op = 'DELETE' or (tg_op = 'UPDATE' and old.role_code = 'HR' and new.role_code is distinct from old.role_code))
       and old.role_code = 'HR' and exists (
      select 1 from public.applications a where a.hr_owner_id = old.app_user_id and a.is_active = true
    ) then
      raise exception 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists app_user_owner_lifecycle_guard on public.app_users;
create trigger app_user_owner_lifecycle_guard
  before update of is_active on public.app_users
  for each row execute function private.block_ineligible_hr_owner_lifecycle();

drop trigger if exists hr_role_owner_lifecycle_guard on public.app_user_roles;
create trigger hr_role_owner_lifecycle_guard
  before update or delete on public.app_user_roles
  for each row execute function private.block_ineligible_hr_owner_lifecycle();

-- -----------------------------------------------------------------------------
-- 5. Helper Views
-- -----------------------------------------------------------------------------
create or replace view private.access_active_interviews
with (security_invoker = true)
as
select i.*
from public.interviews i
join public.applications a on a.application_id = i.application_id
where a.is_active = true and i.is_active = true;

create or replace view private.resource_blocking_interviews
with (security_invoker = true)
as
select i.*
from private.access_active_interviews i
where i.schedule_status_code <> 'CANCELLED'
  and i.start_at is not null
  and i.end_at is not null;

create or replace view private.application_current_interview
with (security_invoker = true)
as
select a.application_id, i.interview_id, i.round_no
from public.applications a
left join lateral (
  select i1.interview_id, i1.round_no
  from private.access_active_interviews i1
  where i1.application_id = a.application_id
  order by i1.round_no desc
  limit 1
) i on true
where a.is_active = true;

-- -----------------------------------------------------------------------------
-- 6. Operational Eligibility & Clean Interview Functions
-- -----------------------------------------------------------------------------
create or replace function private.all_current_participants_selectable(p_interview_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
select not exists (
  select 1
  from public.interview_participants ip
  left join public.app_users u on u.app_user_id = ip.app_user_id
  where ip.interview_id = p_interview_id
    and ip.is_current = true
    and (u.app_user_id is null or u.is_active = false)
);
$$;

create or replace function private.is_interview_clean(p_interview_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
select exists(
  select 1 from public.interviews i
  where i.interview_id = p_interview_id
    and i.round_no = 1
    and i.demo_topic is null
    and i.start_at is null
    and i.end_at is null
    and i.interview_format_id is null
    and i.room_id is null
    and i.meeting_link is null
    and i.schedule_status_code = 'AVAILABLE'
    and i.report_status_code = 'INTERVIEW_SCHEDULING'
    and i.cancellation_reason_id is null
    and i.rejection_reason_id is null
    and nullif(btrim(coalesce(i.interview_note, '')), '') is null
    and nullif(btrim(coalesce(i.hr_report_note, '')), '') is null
    and i.copied_from_interview_id is null
    and not exists(select 1 from public.interviews child where child.copied_from_interview_id = i.interview_id)
    and not exists(select 1 from public.interview_participants ip where ip.interview_id = i.interview_id)
);
$$;

-- -----------------------------------------------------------------------------
-- 7. Idempotency Helper Functions (if not already present)
-- -----------------------------------------------------------------------------
create or replace function private.check_idempotency(
  p_actor_scope text,
  p_command_type text,
  p_idempotency_key uuid,
  p_fingerprint text
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_payload jsonb;
begin
  if p_idempotency_key is null then
    return null;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      p_actor_scope || ':' || p_command_type || ':' || p_idempotency_key::text,
      0
    )
  );

  select result_payload into v_payload
  from public.idempotency_records
  where actor_scope = p_actor_scope
    and command_type = p_command_type
    and idempotency_key = p_idempotency_key;

  if not found then
    return null;
  end if;

  if v_payload ->> 'request_fingerprint' is distinct from p_fingerprint then
    raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
      using errcode = '23514';
  end if;

  return v_payload -> 'result';
end;
$$;

create or replace function private.record_idempotency(
  p_actor_scope text,
  p_command_type text,
  p_idempotency_key uuid,
  p_fingerprint text,
  p_result jsonb,
  p_result_entity_type text default null,
  p_result_entity_id uuid default null
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_idempotency_key is null then
    return;
  end if;

  insert into public.idempotency_records (
    actor_scope,
    command_type,
    idempotency_key,
    result_entity_type,
    result_entity_id,
    result_payload
  ) values (
    p_actor_scope,
    p_command_type,
    p_idempotency_key,
    p_result_entity_type,
    p_result_entity_id,
    jsonb_build_object(
      'request_fingerprint', p_fingerprint,
      'result', p_result
    )
  )
  on conflict (actor_scope, command_type, idempotency_key) do nothing;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Deterministic Advisory Resource Locking & Conflict Detection
-- -----------------------------------------------------------------------------
create or replace function private.lock_interview_resources(
  p_candidate_id uuid,
  p_room_id uuid,
  p_interviewer_ids uuid[]
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_interviewer_id uuid;
begin
  if p_candidate_id is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('candidate:' || p_candidate_id::text, 0)
    );
  end if;

  if p_room_id is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('room:' || p_room_id::text, 0)
    );
  end if;

  for v_interviewer_id in
    select distinct interviewer_id
    from unnest(coalesce(p_interviewer_ids, array[]::uuid[])) as interviewer_id
    where interviewer_id is not null
    order by interviewer_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('interviewer:' || v_interviewer_id::text, 0)
    );
  end loop;
end;
$$;

create or replace function private.check_interview_conflicts(
  p_interview_id uuid,
  p_candidate_id uuid,
  p_room_id uuid,
  p_interviewer_ids uuid[],
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns table(
  conflict_type text,
  conflicting_interview_id uuid,
  conflicting_application_id uuid,
  conflicting_start_at timestamptz,
  conflicting_end_at timestamptz,
  conflicting_entity_id uuid,
  detail text
)
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_start_at is null or p_end_at is null or p_start_at >= p_end_at then
    return;
  end if;

  -- 1. Candidate Conflict: check other resource_blocking interviews for the same Candidate
  if p_candidate_id is not null then
    return query
    select
      'CANDIDATE'::text as conflict_type,
      rbi.interview_id as conflicting_interview_id,
      rbi.application_id as conflicting_application_id,
      rbi.start_at as conflicting_start_at,
      rbi.end_at as conflicting_end_at,
      p_candidate_id as conflicting_entity_id,
      'Candidate has overlapping interview session'::text as detail
    from private.resource_blocking_interviews rbi
    join public.applications a on a.application_id = rbi.application_id
    join public.submissions s on s.submission_id = a.submission_id
    where s.candidate_id = p_candidate_id
      and (p_interview_id is null or rbi.interview_id <> p_interview_id)
      and rbi.start_at < p_end_at
      and rbi.end_at > p_start_at;
  end if;

  -- 2. Room Conflict: check other resource_blocking interviews in the same Room
  if p_room_id is not null then
    return query
    select
      'ROOM'::text as conflict_type,
      rbi.interview_id as conflicting_interview_id,
      rbi.application_id as conflicting_application_id,
      rbi.start_at as conflicting_start_at,
      rbi.end_at as conflicting_end_at,
      p_room_id as conflicting_entity_id,
      'Room is booked by another overlapping interview'::text as detail
    from private.resource_blocking_interviews rbi
    where rbi.room_id = p_room_id
      and (p_interview_id is null or rbi.interview_id <> p_interview_id)
      and rbi.start_at < p_end_at
      and rbi.end_at > p_start_at;
  end if;

  -- 3. Interviewer Conflict: check other resource_blocking interviews with any overlapping current participant
  if p_interviewer_ids is not null and array_length(p_interviewer_ids, 1) > 0 then
    return query
    select distinct
      'INTERVIEWER'::text as conflict_type,
      rbi.interview_id as conflicting_interview_id,
      rbi.application_id as conflicting_application_id,
      rbi.start_at as conflicting_start_at,
      rbi.end_at as conflicting_end_at,
      ip.app_user_id as conflicting_entity_id,
      ('Interviewer ' || coalesce(ip.snapshot_name, ip.app_user_id::text) || ' has overlapping interview session')::text as detail
    from private.resource_blocking_interviews rbi
    join public.interview_participants ip on ip.interview_id = rbi.interview_id
    where ip.is_current = true
      and ip.app_user_id = any(p_interviewer_ids)
      and (p_interview_id is null or rbi.interview_id <> p_interview_id)
      and rbi.start_at < p_end_at
      and rbi.end_at > p_start_at;
  end if;
end;
$$;

-- SECURITY DEFINER is required here because the interviewer predicate spans
-- RLS-protected participant, user, and application rows. It returns only a
-- boolean for the caller's own authenticated identity.
create or replace function private.can_view_visible_interview(
  p_interview_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.interview_participants ip
    join public.app_users u on u.app_user_id = ip.app_user_id
    join public.interviews i on i.interview_id = ip.interview_id
    join public.applications a on a.application_id = i.application_id
    where ip.interview_id = p_interview_id
      and ip.is_current = true
      and u.auth_user_id = (select auth.uid())
      and u.is_active = true
      and i.is_active = true
      and a.is_active = true
  );
$$;

revoke all on function private.can_view_visible_interview(uuid) from public, anon;
grant execute on function private.can_view_visible_interview(uuid) to authenticated, postgres, service_role;

-- -----------------------------------------------------------------------------
-- 9. RLS, Grants & Policies
-- -----------------------------------------------------------------------------
alter table public.interview_participants enable row level security;

revoke all on public.interview_participants from public, anon;
grant select on public.interview_participants to authenticated;
grant all on public.interview_participants to postgres, service_role;

drop policy if exists interview_participants_select on public.interview_participants;
create policy interview_participants_select on public.interview_participants
  for select to authenticated
  using (
    private.has_permission('interviews.view')
    or private.has_permission('interviews.manage')
    or private.is_root_admin()
    or app_user_id = private.current_app_user_id()
  );

-- Interviewers have only contextual visibility through their own active
-- participant assignment; application and interview activity remain required.
drop policy if exists interviews_select on public.interviews;
create policy interviews_select on public.interviews
  for select to authenticated
  using (
    private.has_permission('interviews.view')
    or private.has_permission('interviews.manage')
    or private.is_root_admin()
    or (
      visible_to_interviewers = true
      and is_active = true
      and private.can_view_visible_interview(interview_id)
    )
  );

-- -----------------------------------------------------------------------------
-- 10. Public RPCs: Round creation, Conflict checking, Participant management
-- -----------------------------------------------------------------------------

-- 10.1 create_next_interview_round
create or replace function public.create_next_interview_round(
  p_application_id uuid,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_app public.applications%rowtype;
  v_latest_interview public.interviews%rowtype;
  v_next_round integer;
  v_new_interview_id uuid;
  v_result jsonb;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select app_user_id into v_actor_app_user_id
  from public.app_users
  where auth_user_id = v_auth_uid
    and is_active = true;

  if v_actor_app_user_id is null
    or not (private.has_permission('interviews.manage') or private.is_root_admin()) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission interviews.manage required');
  end if;

  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;

  if p_idempotency_key is not null then
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'command', 'create_next_interview_round',
          'application_id', p_application_id
        )::text,
        'sha256'
      ),
      'hex'
    );

    v_existing_result := private.check_idempotency(
      v_actor_scope,
      'create_next_interview_round',
      p_idempotency_key,
      v_fingerprint
    );
    if v_existing_result is not null then
      return v_existing_result;
    end if;
  end if;

  select * into v_app
  from public.applications
  where application_id = p_application_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Application not found');
  end if;

  if not v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_INACTIVE', 'message', 'Cannot create an interview round for an inactive application');
  end if;

  select * into v_latest_interview
  from public.interviews
  where application_id = p_application_id
  order by round_no desc
  limit 1
  for update;

  if found and not v_latest_interview.is_active then
    return jsonb_build_object('success', false, 'error_code', 'LATEST_INTERVIEW_INACTIVE', 'message', 'The latest interview round is inactive');
  end if;

  if found and v_latest_interview.report_status_code = 'HIRED' then
    return jsonb_build_object('success', false, 'error_code', 'APPLICATION_HIRED', 'message', 'Cannot create an interview round after a hired result');
  end if;

  perform 1
  from public.submissions
  where submission_id = v_app.submission_id
  for update;

  if not found then
    raise exception 'APPLICATION_SUBMISSION_NOT_FOUND' using errcode = '23503';
  end if;

  v_next_round := coalesce(v_latest_interview.round_no, 0) + 1;

  insert into public.interviews (
    application_id,
    round_no,
    schedule_status_code,
    report_status_code,
    is_active,
    version_no
  ) values (
    p_application_id,
    v_next_round,
    'AVAILABLE',
    'INTERVIEW_SCHEDULING',
    true,
    1
  )
  returning interview_id into v_new_interview_id;

  perform public.recalculate_submission_status(v_app.submission_id);

  insert into public.activity_log (
    entity_type,
    entity_id,
    action_code,
    actor_app_user_id,
    request_id,
    source_code,
    old_values,
    new_values
  ) values (
    'INTERVIEW',
    v_new_interview_id,
    'CREATE_NEXT_INTERVIEW_ROUND',
    v_actor_app_user_id,
    p_idempotency_key,
    'RPC',
    null,
    jsonb_build_object(
      'application_id', p_application_id,
      'round_no', v_next_round
    )
  );

  insert into public.security_audit_log (
    actor_auth_user_id,
    actor_app_user_id,
    action_code,
    entity_type,
    entity_id,
    request_id,
    source_code,
    metadata
  ) values (
    v_auth_uid,
    v_actor_app_user_id,
    'CREATE_NEXT_INTERVIEW_ROUND',
    'INTERVIEW',
    v_new_interview_id,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('application_id', p_application_id, 'round_no', v_next_round)
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', v_new_interview_id,
      'application_id', p_application_id,
      'round_no', v_next_round,
      'schedule_status_code', 'AVAILABLE',
      'report_status_code', 'INTERVIEW_SCHEDULING',
      'version_no', 1
    )
  );

  if p_idempotency_key is not null then
    perform private.record_idempotency(
      v_actor_scope,
      'create_next_interview_round',
      p_idempotency_key,
      v_fingerprint,
      v_result,
      'INTERVIEW',
      v_new_interview_id
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.create_next_interview_round(uuid, uuid) from public, anon;
grant execute on function public.create_next_interview_round(uuid, uuid) to authenticated;

-- 10.2 check_interview_schedule_conflicts
create or replace function public.check_interview_schedule_conflicts(
  p_interview_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_room_id uuid default null,
  p_interviewer_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidate_id uuid;
  v_interviewer_ids uuid[];
  v_conflicts jsonb := '[]'::jsonb;
  v_row record;
begin
  -- 1. Permission check
  if not (
    private.has_permission('interviews.view')
    or private.has_permission('interviews.manage')
    or private.is_root_admin()
  ) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission interviews.view required');
  end if;

  -- 2. Validate interval
  if p_start_at is null or p_end_at is null or p_start_at >= p_end_at then
    return jsonb_build_object(
      'success', false,
      'error_code', 'INVALID_INTERVAL',
      'message', 'Valid start_at and end_at required (start_at < end_at)'
    );
  end if;

  -- 3. Resolve candidate from interview
  if p_interview_id is not null then
    select s.candidate_id into v_candidate_id
    from public.interviews i
    join public.applications a on a.application_id = i.application_id
    join public.submissions s on s.submission_id = a.submission_id
    where i.interview_id = p_interview_id;
  end if;

  -- 4. Resolve interviewer ids if not provided
  if p_interviewer_ids is null and p_interview_id is not null then
    select coalesce(array_agg(app_user_id), array[]::uuid[]) into v_interviewer_ids
    from public.interview_participants
    where interview_id = p_interview_id and is_current = true;
  else
    v_interviewer_ids := coalesce(p_interviewer_ids, array[]::uuid[]);
  end if;

  -- 5. Query conflicts
  for v_row in (
    select * from private.check_interview_conflicts(
      p_interview_id,
      v_candidate_id,
      p_room_id,
      v_interviewer_ids,
      p_start_at,
      p_end_at
    )
  ) loop
    v_conflicts := v_conflicts || jsonb_build_object(
      'conflict_type', v_row.conflict_type,
      'conflicting_interview_id', v_row.conflicting_interview_id,
      'conflicting_application_id', v_row.conflicting_application_id,
      'conflicting_start_at', v_row.conflicting_start_at,
      'conflicting_end_at', v_row.conflicting_end_at,
      'conflicting_entity_id', v_row.conflicting_entity_id,
      'detail', v_row.detail
    );
  end loop;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'has_conflict', jsonb_array_length(v_conflicts) > 0,
      'conflict_count', jsonb_array_length(v_conflicts),
      'conflicts', v_conflicts
    )
  );
end;
$$;

revoke all on function public.check_interview_schedule_conflicts(uuid, timestamptz, timestamptz, uuid, uuid[]) from public, anon;
grant execute on function public.check_interview_schedule_conflicts(uuid, timestamptz, timestamptz, uuid, uuid[]) to authenticated;

-- 10.3 add_interview_participant
create or replace function public.add_interview_participant(
  p_interview_id uuid,
  p_app_user_id uuid,
  p_expected_version bigint,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_interview public.interviews%rowtype;
  v_user public.app_users%rowtype;
  v_max_order integer;
  v_participant_id uuid;
  v_candidate_id uuid;
  v_resource_interviewer_ids uuid[];
  v_result jsonb;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select app_user_id into v_actor_app_user_id
  from public.app_users
  where auth_user_id = v_auth_uid
    and is_active = true;

  if v_actor_app_user_id is null
    or not (
      private.has_permission('interviews.participants')
      or private.has_permission('interviews.manage')
      or private.is_root_admin()
    ) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission interviews.participants required');
  end if;

  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;

  if p_idempotency_key is not null then
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'command', 'add_interview_participant',
          'interview_id', p_interview_id,
          'app_user_id', p_app_user_id,
          'expected_version', p_expected_version
        )::text,
        'sha256'
      ),
      'hex'
    );
    v_existing_result := private.check_idempotency(
      v_actor_scope,
      'add_interview_participant',
      p_idempotency_key,
      v_fingerprint
    );
    if v_existing_result is not null then
      return v_existing_result;
    end if;
  end if;

  select * into v_interview
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Interview not found');
  end if;

  if v_interview.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Interview version mismatch; reload required');
  end if;

  select * into v_user
  from public.app_users
  where app_user_id = p_app_user_id
    and is_active = true;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'USER_INACTIVE_NOT_SELECTABLE', 'message', 'Participant must be an active internal user');
  end if;

  if exists (
    select 1
    from public.interview_participants
    where interview_id = p_interview_id
      and app_user_id = p_app_user_id
      and is_current = true
  ) then
    return jsonb_build_object('success', false, 'error_code', 'DUPLICATE_PARTICIPANT', 'message', 'User is already an active participant in this interview');
  end if;

  if v_interview.schedule_status_code <> 'CANCELLED'
    and v_interview.start_at is not null
    and v_interview.end_at is not null then
    select s.candidate_id into v_candidate_id
    from public.applications a
    join public.submissions s on s.submission_id = a.submission_id
    where a.application_id = v_interview.application_id;

    select coalesce(array_agg(distinct app_user_id order by app_user_id), array[]::uuid[])
    into v_resource_interviewer_ids
    from public.interview_participants
    where interview_id = p_interview_id
      and is_current = true;

    v_resource_interviewer_ids := array(
      select distinct interviewer_id
      from unnest(v_resource_interviewer_ids || array[p_app_user_id]) as interviewer_id
      order by interviewer_id
    );

    perform private.lock_interview_resources(
      v_candidate_id,
      v_interview.room_id,
      v_resource_interviewer_ids
    );

    -- The target Interview lock prevents participant writes during this command;
    -- re-read its set after resource locks before the authoritative conflict check.
    select coalesce(array_agg(distinct app_user_id order by app_user_id), array[]::uuid[])
    into v_resource_interviewer_ids
    from public.interview_participants
    where interview_id = p_interview_id
      and is_current = true;

    v_resource_interviewer_ids := array(
      select distinct interviewer_id
      from unnest(v_resource_interviewer_ids || array[p_app_user_id]) as interviewer_id
      order by interviewer_id
    );

    if exists (
      select 1
      from private.check_interview_conflicts(
        p_interview_id,
        v_candidate_id,
        v_interview.room_id,
        v_resource_interviewer_ids,
        v_interview.start_at,
        v_interview.end_at
      )
    ) then
      return jsonb_build_object('success', false, 'error_code', 'SCHEDULE_CONFLICT', 'message', 'Participant change would create an interview schedule conflict');
    end if;
  end if;

  select coalesce(max(participant_order), 0) + 1 into v_max_order
  from public.interview_participants
  where interview_id = p_interview_id
    and is_current = true;

  insert into public.interview_participants (
    interview_id,
    app_user_id,
    participant_order,
    snapshot_name,
    snapshot_job_title,
    snapshot_email,
    is_current
  ) values (
    p_interview_id,
    p_app_user_id,
    v_max_order,
    v_user.full_name,
    v_user.job_title,
    v_user.email,
    true
  )
  returning interview_participant_id into v_participant_id;

  update public.interviews
  set
    updated_at = clock_timestamp(),
    updated_by = v_actor_app_user_id
  where interview_id = p_interview_id;

  insert into public.activity_log (
    entity_type,
    entity_id,
    action_code,
    actor_app_user_id,
    request_id,
    source_code,
    old_values,
    new_values
  ) values (
    'INTERVIEW_PARTICIPANT',
    v_participant_id,
    'ADD_INTERVIEW_PARTICIPANT',
    v_actor_app_user_id,
    p_idempotency_key,
    'RPC',
    null,
    jsonb_build_object(
      'interview_id', p_interview_id,
      'app_user_id', p_app_user_id,
      'participant_order', v_max_order
    )
  );

  insert into public.security_audit_log (
    actor_auth_user_id,
    actor_app_user_id,
    action_code,
    entity_type,
    entity_id,
    request_id,
    source_code,
    metadata
  ) values (
    v_auth_uid,
    v_actor_app_user_id,
    'ADD_INTERVIEW_PARTICIPANT',
    'INTERVIEW_PARTICIPANT',
    v_participant_id,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('interview_id', p_interview_id, 'app_user_id', p_app_user_id)
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_participant_id', v_participant_id,
      'interview_id', p_interview_id,
      'app_user_id', p_app_user_id,
      'participant_order', v_max_order,
      'snapshot_name', v_user.full_name,
      'snapshot_email', v_user.email,
      'new_interview_version', v_interview.version_no + 1
    )
  );

  if p_idempotency_key is not null then
    perform private.record_idempotency(
      v_actor_scope,
      'add_interview_participant',
      p_idempotency_key,
      v_fingerprint,
      v_result,
      'INTERVIEW_PARTICIPANT',
      v_participant_id
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.add_interview_participant(uuid, uuid, bigint, uuid) from public, anon;
grant execute on function public.add_interview_participant(uuid, uuid, bigint, uuid) to authenticated;

-- 10.4 remove_interview_participant
create or replace function public.remove_interview_participant(
  p_interview_participant_id uuid,
  p_expected_version bigint,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_part public.interview_participants%rowtype;
  v_interview public.interviews%rowtype;
  v_result jsonb;
  v_p record;
  v_new_order integer := 1;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select app_user_id into v_actor_app_user_id
  from public.app_users
  where auth_user_id = v_auth_uid
    and is_active = true;

  if v_actor_app_user_id is null
    or not (
      private.has_permission('interviews.participants')
      or private.has_permission('interviews.manage')
      or private.is_root_admin()
    ) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission interviews.participants required');
  end if;

  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;

  if p_idempotency_key is not null then
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'command', 'remove_interview_participant',
          'participant_id', p_interview_participant_id,
          'expected_version', p_expected_version
        )::text,
        'sha256'
      ),
      'hex'
    );
    v_existing_result := private.check_idempotency(
      v_actor_scope,
      'remove_interview_participant',
      p_idempotency_key,
      v_fingerprint
    );
    if v_existing_result is not null then
      return v_existing_result;
    end if;
  end if;

  select * into v_part
  from public.interview_participants
  where interview_participant_id = p_interview_participant_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Interview participant not found');
  end if;

  select * into v_interview
  from public.interviews
  where interview_id = v_part.interview_id
  for update;

  if v_part.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Participant version mismatch; reload required');
  end if;

  if not v_part.is_current then
    return jsonb_build_object('success', false, 'error_code', 'ALREADY_REMOVED', 'message', 'Participant is already removed');
  end if;

  update public.interview_participants
  set
    is_current = false,
    removed_at = clock_timestamp()
  where interview_participant_id = p_interview_participant_id;

  -- Move orders out of the unique active range without violating order > 0,
  -- then compact in their existing relative order.
  update public.interview_participants
  set participant_order = participant_order + 1000000
  where interview_id = v_part.interview_id
    and is_current = true;

  for v_p in
    select interview_participant_id
    from public.interview_participants
    where interview_id = v_part.interview_id
      and is_current = true
    order by participant_order
  loop
    update public.interview_participants
    set participant_order = v_new_order
    where interview_participant_id = v_p.interview_participant_id;
    v_new_order := v_new_order + 1;
  end loop;

  update public.interviews
  set
    updated_at = clock_timestamp(),
    updated_by = v_actor_app_user_id
  where interview_id = v_part.interview_id;

  insert into public.activity_log (
    entity_type,
    entity_id,
    action_code,
    actor_app_user_id,
    request_id,
    source_code,
    old_values,
    new_values
  ) values (
    'INTERVIEW_PARTICIPANT',
    p_interview_participant_id,
    'REMOVE_INTERVIEW_PARTICIPANT',
    v_actor_app_user_id,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('interview_id', v_part.interview_id, 'app_user_id', v_part.app_user_id, 'is_current', true),
    jsonb_build_object('is_current', false)
  );

  insert into public.security_audit_log (
    actor_auth_user_id,
    actor_app_user_id,
    action_code,
    entity_type,
    entity_id,
    request_id,
    source_code,
    metadata
  ) values (
    v_auth_uid,
    v_actor_app_user_id,
    'REMOVE_INTERVIEW_PARTICIPANT',
    'INTERVIEW_PARTICIPANT',
    p_interview_participant_id,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('interview_id', v_part.interview_id, 'app_user_id', v_part.app_user_id)
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_participant_id', p_interview_participant_id,
      'removed', true,
      'new_interview_version', v_interview.version_no + 1
    )
  );

  if p_idempotency_key is not null then
    perform private.record_idempotency(
      v_actor_scope,
      'remove_interview_participant',
      p_idempotency_key,
      v_fingerprint,
      v_result,
      'INTERVIEW_PARTICIPANT',
      p_interview_participant_id
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.remove_interview_participant(uuid, bigint, uuid) from public, anon;
grant execute on function public.remove_interview_participant(uuid, bigint, uuid) to authenticated;
-- 10.5 reorder_interview_participants
create or replace function public.reorder_interview_participants(
  p_interview_id uuid,
  p_participant_ids uuid[],
  p_expected_version bigint,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_interview public.interviews%rowtype;
  v_current_count integer;
  v_input_count integer;
  v_distinct_input_count integer;
  v_id uuid;
  v_idx integer;
  v_result jsonb;
begin
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select app_user_id into v_actor_app_user_id
  from public.app_users
  where auth_user_id = v_auth_uid
    and is_active = true;

  if v_actor_app_user_id is null
    or not (
      private.has_permission('interviews.participants')
      or private.has_permission('interviews.manage')
      or private.is_root_admin()
    ) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission interviews.participants required');
  end if;

  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;

  if p_idempotency_key is not null then
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'command', 'reorder_interview_participants',
          'interview_id', p_interview_id,
          'participant_ids', p_participant_ids,
          'expected_version', p_expected_version
        )::text,
        'sha256'
      ),
      'hex'
    );
    v_existing_result := private.check_idempotency(
      v_actor_scope,
      'reorder_interview_participants',
      p_idempotency_key,
      v_fingerprint
    );
    if v_existing_result is not null then
      return v_existing_result;
    end if;
  end if;

  select * into v_interview
  from public.interviews
  where interview_id = p_interview_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Interview not found');
  end if;

  if v_interview.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Interview version mismatch; reload required');
  end if;

  select count(*) into v_current_count
  from public.interview_participants
  where interview_id = p_interview_id
    and is_current = true;

  v_input_count := coalesce(cardinality(p_participant_ids), 0);
  select count(distinct participant_id) into v_distinct_input_count
  from unnest(coalesce(p_participant_ids, array[]::uuid[])) as participant_id;

  if v_input_count <> v_current_count or v_distinct_input_count <> v_current_count then
    return jsonb_build_object('success', false, 'error_code', 'PARTICIPANT_SET_MISMATCH', 'message', 'Participant list must contain every current participant exactly once');
  end if;

  if exists (
    select 1
    from unnest(p_participant_ids) as input_id
    where not exists (
      select 1
      from public.interview_participants
      where interview_participant_id = input_id
        and interview_id = p_interview_id
        and is_current = true
    )
  ) then
    return jsonb_build_object('success', false, 'error_code', 'PARTICIPANT_SET_MISMATCH', 'message', 'Participant list contains a non-current participant');
  end if;

  update public.interview_participants
  set participant_order = participant_order + 1000000
  where interview_id = p_interview_id
    and is_current = true;

  v_idx := 1;
  foreach v_id in array p_participant_ids loop
    update public.interview_participants
    set participant_order = v_idx
    where interview_participant_id = v_id;
    v_idx := v_idx + 1;
  end loop;

  update public.interviews
  set
    updated_at = clock_timestamp(),
    updated_by = v_actor_app_user_id
  where interview_id = p_interview_id;

  insert into public.activity_log (
    entity_type,
    entity_id,
    action_code,
    actor_app_user_id,
    request_id,
    source_code,
    old_values,
    new_values
  ) values (
    'INTERVIEW',
    p_interview_id,
    'REORDER_INTERVIEW_PARTICIPANTS',
    v_actor_app_user_id,
    p_idempotency_key,
    'RPC',
    null,
    jsonb_build_object('participant_ids', p_participant_ids)
  );

  insert into public.security_audit_log (
    actor_auth_user_id,
    actor_app_user_id,
    action_code,
    entity_type,
    entity_id,
    request_id,
    source_code,
    metadata
  ) values (
    v_auth_uid,
    v_actor_app_user_id,
    'REORDER_INTERVIEW_PARTICIPANTS',
    'INTERVIEW',
    p_interview_id,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('participant_ids', p_participant_ids)
  );

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'interview_id', p_interview_id,
      'reordered_count', v_input_count,
      'new_interview_version', v_interview.version_no + 1
    )
  );

  if p_idempotency_key is not null then
    perform private.record_idempotency(
      v_actor_scope,
      'reorder_interview_participants',
      p_idempotency_key,
      v_fingerprint,
      v_result,
      'INTERVIEW',
      p_interview_id
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.reorder_interview_participants(uuid, uuid[], bigint, uuid) from public, anon;
grant execute on function public.reorder_interview_participants(uuid, uuid[], bigint, uuid) to authenticated;
