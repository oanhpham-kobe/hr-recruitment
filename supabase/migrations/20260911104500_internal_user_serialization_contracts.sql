-- TASK-S06-002 / Part 1: shared Internal User serialization and lifecycle/owner/participant race closure.
-- Append-only over accepted Slice-01..06 migrations.

-- -----------------------------------------------------------------------------
-- 1. Shared Internal User serialization and identity helpers
-- -----------------------------------------------------------------------------
create or replace function private.lock_internal_user_ids(p_app_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  for v_user_id in
    select distinct x.app_user_id
    from unnest(coalesce(p_app_user_ids, array[]::uuid[])) as x(app_user_id)
    where x.app_user_id is not null
    order by x.app_user_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('internal-user:' || v_user_id::text, 0)
    );
  end loop;
end;
$$;

create or replace function private.normalize_internal_eiu_email(p_email text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if v_email = ''
     or char_length(v_email) > 320
     or v_email !~ '^[^@[:space:]]+@eiu[.]edu[.]vn$' then
    raise exception 'invalid EIU internal email' using errcode = '22023';
  end if;
  return v_email;
end;
$$;

create or replace function private.verified_google_auth_email(p_auth_user_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  select lower(btrim(u.email::text))
  into v_email
  from auth.users u
  where u.id = p_auth_user_id
    and u.email is not null
    and u.email_confirmed_at is not null;

  if v_email is null then
    return null;
  end if;

  begin
    v_email := private.normalize_internal_eiu_email(v_email);
  exception
    when invalid_parameter_value then
      return null;
  end;

  if not exists (
    select 1
    from auth.identities i
    where i.user_id = p_auth_user_id
      and i.provider = 'google'
      and lower(btrim(coalesce(i.identity_data ->> 'email', ''))) = v_email
  ) then
    return null;
  end if;

  return v_email;
end;
$$;

revoke all on function private.lock_internal_user_ids(uuid[]) from public, anon, authenticated;
revoke all on function private.normalize_internal_eiu_email(text) from public, anon, authenticated;
revoke all on function private.verified_google_auth_email(uuid) from public, anon, authenticated;
grant execute on function private.lock_internal_user_ids(uuid[]) to postgres, service_role;
grant execute on function private.normalize_internal_eiu_email(text) to postgres, service_role;
grant execute on function private.verified_google_auth_email(uuid) to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 2. Write-boundary race closure for lifecycle vs owner / participant writers
-- -----------------------------------------------------------------------------
create or replace function private.serialize_app_user_lifecycle_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.is_active is distinct from new.is_active then
    perform private.lock_internal_user_ids(array[old.app_user_id]);
  end if;
  return new;
end;
$$;

revoke all on function private.serialize_app_user_lifecycle_write() from public, anon, authenticated;
grant execute on function private.serialize_app_user_lifecycle_write() to postgres, service_role;

drop trigger if exists a_s06_002_app_user_lifecycle_serialize on public.app_users;
create trigger a_s06_002_app_user_lifecycle_serialize
  before update of is_active on public.app_users
  for each row execute function private.serialize_app_user_lifecycle_write();

create or replace function private.serialize_internal_security_row_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if tg_op = 'DELETE' then
    v_user_id := old.app_user_id;
  else
    v_user_id := new.app_user_id;
  end if;
  perform private.lock_internal_user_ids(array[v_user_id]);
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function private.serialize_internal_security_row_write() from public, anon, authenticated;
grant execute on function private.serialize_internal_security_row_write() to postgres, service_role;

drop trigger if exists a_s06_002_role_security_serialize on public.app_user_roles;
create trigger a_s06_002_role_security_serialize
  before insert or update or delete on public.app_user_roles
  for each row execute function private.serialize_internal_security_row_write();

drop trigger if exists a_s06_002_permission_security_serialize on public.app_user_permissions;
create trigger a_s06_002_permission_security_serialize
  before insert or update or delete on public.app_user_permissions
  for each row execute function private.serialize_internal_security_row_write();

create or replace function private.guard_active_application_owner_eligibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_ids uuid[] := array[]::uuid[];
  v_owner_ok boolean;
begin
  if not new.is_active then
    return new;
  end if;

  v_user_ids := array[new.hr_owner_id];

  if tg_op = 'UPDATE' and old.is_active = false and new.is_active = true then
    select v_user_ids || coalesce(array_agg(distinct ip.app_user_id order by ip.app_user_id), array[]::uuid[])
    into v_user_ids
    from public.interviews i
    join public.interview_participants ip
      on ip.interview_id = i.interview_id
     and ip.is_current = true
    where i.application_id = new.application_id
      and i.is_active = true
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null
      and i.end_at is not null
      and i.end_at > clock_timestamp();
  end if;

  perform private.lock_internal_user_ids(v_user_ids);

  select exists (
    select 1
    from public.app_users u
    where u.app_user_id = new.hr_owner_id
      and u.is_active = true
      and (
        u.is_root_admin = true
        or exists (
          select 1
          from public.app_user_roles r
          where r.app_user_id = u.app_user_id
            and r.role_code = 'HR'
        )
      )
  ) into v_owner_ok;

  if not coalesce(v_owner_ok, false) then
    raise exception 'APPLICATION_OWNER_NOT_ELIGIBLE'
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.is_active = false and new.is_active = true
     and exists (
       select 1
       from public.interviews i
       join public.interview_participants ip
         on ip.interview_id = i.interview_id
        and ip.is_current = true
       left join public.app_users u on u.app_user_id = ip.app_user_id
       where i.application_id = new.application_id
         and i.is_active = true
         and i.schedule_status_code <> 'CANCELLED'
         and i.start_at is not null
         and i.end_at is not null
         and i.end_at > clock_timestamp()
         and coalesce(u.is_active, false) = false
     ) then
    raise exception 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_active_application_owner_eligibility() from public, anon, authenticated;
grant execute on function private.guard_active_application_owner_eligibility() to postgres, service_role;

drop trigger if exists s06_002_active_application_owner_guard on public.applications;
create trigger s06_002_active_application_owner_guard
  before insert or update of hr_owner_id, is_active on public.applications
  for each row execute function private.guard_active_application_owner_eligibility();

create or replace function private.guard_resource_blocking_interview_participants()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_application_active boolean;
  v_user_ids uuid[];
begin
  if not new.is_active
     or new.schedule_status_code = 'CANCELLED'
     or new.start_at is null
     or new.end_at is null
     or new.end_at <= clock_timestamp() then
    return new;
  end if;

  select a.is_active
  into v_application_active
  from public.applications a
  where a.application_id = new.application_id;

  if not coalesce(v_application_active, false) then
    return new;
  end if;

  select coalesce(array_agg(distinct ip.app_user_id order by ip.app_user_id), array[]::uuid[])
  into v_user_ids
  from public.interview_participants ip
  where ip.interview_id = new.interview_id
    and ip.is_current = true;

  perform private.lock_internal_user_ids(v_user_ids);

  if exists (
    select 1
    from public.interview_participants ip
    left join public.app_users u on u.app_user_id = ip.app_user_id
    where ip.interview_id = new.interview_id
      and ip.is_current = true
      and coalesce(u.is_active, false) = false
  ) then
    raise exception 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_resource_blocking_interview_participants() from public, anon, authenticated;
grant execute on function private.guard_resource_blocking_interview_participants() to postgres, service_role;

drop trigger if exists s06_002_resource_blocking_participant_guard on public.interviews;
create trigger s06_002_resource_blocking_participant_guard
  before insert or update of application_id, is_active, schedule_status_code, start_at, end_at
  on public.interviews
  for each row execute function private.guard_resource_blocking_interview_participants();

create or replace function private.recheck_current_participants_after_statement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_ids uuid[];
begin
  select coalesce(array_agg(distinct n.app_user_id order by n.app_user_id), array[]::uuid[])
  into v_user_ids
  from s06_new_participants n
  where n.is_current = true;

  perform private.lock_internal_user_ids(v_user_ids);

  if exists (
    select 1
    from s06_new_participants n
    left join public.app_users u on u.app_user_id = n.app_user_id
    where n.is_current = true
      and coalesce(u.is_active, false) = false
  ) then
    raise exception 'USER_INACTIVE_NOT_SELECTABLE'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

revoke all on function private.recheck_current_participants_after_statement() from public, anon, authenticated;
grant execute on function private.recheck_current_participants_after_statement() to postgres, service_role;

drop trigger if exists s06_002_participant_insert_recheck on public.interview_participants;
create trigger s06_002_participant_insert_recheck
  after insert on public.interview_participants
  referencing new table as s06_new_participants
  for each statement execute function private.recheck_current_participants_after_statement();

drop trigger if exists s06_002_participant_update_recheck on public.interview_participants;
create trigger s06_002_participant_update_recheck
  after update on public.interview_participants
  referencing new table as s06_new_participants
  for each statement execute function private.recheck_current_participants_after_statement();

-- Keep the accepted lifecycle blocker but reconcile it to the canonical
-- non-elapsed resource_blocking predicate. The earlier serialization trigger
-- acquires the same per-user advisory gate before this check runs.
create or replace function private.block_ineligible_hr_owner_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'app_users' then
    if old.is_active = true and new.is_active = false and exists (
      select 1
      from public.applications a
      where a.hr_owner_id = old.app_user_id
        and a.is_active = true
    ) then
      raise exception 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED'
        using errcode = '23514';
    end if;

    if old.is_active = true and new.is_active = false and exists (
      select 1
      from public.interview_participants ip
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
      raise exception 'FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED'
        using errcode = '23514';
    end if;

  elsif tg_table_name = 'app_user_roles' then
    if (tg_op = 'DELETE'
        or (tg_op = 'UPDATE' and old.role_code = 'HR' and new.role_code is distinct from old.role_code))
       and old.role_code = 'HR'
       and exists (
         select 1
         from public.applications a
         where a.hr_owner_id = old.app_user_id
           and a.is_active = true
       ) then
      raise exception 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED'
        using errcode = '23514';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function private.block_ineligible_hr_owner_lifecycle() from public, anon, authenticated;
grant execute on function private.block_ineligible_hr_owner_lifecycle() to postgres, service_role;
