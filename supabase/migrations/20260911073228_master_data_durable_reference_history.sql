-- TASK-S06-001 R3 repair: durable ever-reference history for semantic Master Data relationships.
--
-- The canonical lifecycle rule is "once referenced => retain history / Inactivate".
-- Current FK scans are insufficient when accepted workflows replace/delete the
-- reference row (Candidate education rebuild, Interview reschedule, mutable
-- assignment/source relationships, etc.). This append-only migration records
-- first semantic use transactionally and makes master_usage_exists consult it.
--
-- Temporary upload reservations / staged document changes intentionally remain
-- current-only usage checks; they are not promoted to permanent business history.

create table if not exists private.master_reference_history (
  master_type text not null check (
    master_type in (
      'organizational_units',
      'department_teams',
      'positions',
      'position_groups',
      'qualification_levels',
      'rooms',
      'interview_formats',
      'recruitment_sources',
      'document_types',
      'cancellation_reasons',
      'rejection_reasons'
    )
  ),
  master_id uuid not null,
  first_referenced_at timestamptz not null default clock_timestamp(),
  primary key (master_type, master_id)
);

revoke all on private.master_reference_history from public, anon, authenticated;
grant all on private.master_reference_history to postgres, service_role;

-- Backfill every semantic use that is still provable from retained rows.
insert into private.master_reference_history(master_type, master_id)
select 'organizational_units', unit_id from public.department_teams where unit_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'organizational_units', unit_id from public.positions where unit_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'organizational_units', unit_id from public.applications where unit_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'organizational_units', unit_id from public.app_users where unit_id is not null
on conflict (master_type, master_id) do nothing;

insert into private.master_reference_history(master_type, master_id)
select 'department_teams', department_team_id from public.positions where department_team_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'department_teams', department_team_id from public.applications where department_team_id is not null
on conflict (master_type, master_id) do nothing;

insert into private.master_reference_history(master_type, master_id)
select 'positions', position_id from public.applications where position_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'position_groups', position_group_id from public.positions where position_group_id is not null
on conflict (master_type, master_id) do nothing;

insert into private.master_reference_history(master_type, master_id)
select 'qualification_levels', qualification_id from public.submission_education where qualification_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'recruitment_sources', recruitment_source_id from public.submissions where recruitment_source_id is not null
on conflict (master_type, master_id) do nothing;

insert into private.master_reference_history(master_type, master_id)
select 'rooms', room_id from public.interviews where room_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'interview_formats', interview_format_id from public.interviews where interview_format_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'cancellation_reasons', cancellation_reason_id from public.interviews where cancellation_reason_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'rejection_reasons', rejection_reason_id from public.interviews where rejection_reason_id is not null
on conflict (master_type, master_id) do nothing;

insert into private.master_reference_history(master_type, master_id)
select 'document_types', document_type_id from public.submission_document_logicals where document_type_id is not null
on conflict (master_type, master_id) do nothing;
insert into private.master_reference_history(master_type, master_id)
select 'document_types', document_type_id from public.interview_document_logicals where document_type_id is not null
on conflict (master_type, master_id) do nothing;

-- Preserve the already accepted R2 reason-history evidence in the generalized store.
insert into private.master_reference_history(master_type, master_id, first_referenced_at)
select master_type, master_id, first_used_at
from private.master_reason_usage_history
on conflict (master_type, master_id) do nothing;

-- Static, closed-type recorder. New references take a KEY SHARE lock before the
-- semantic holder write completes so a concurrent structural master mutation
-- cannot pass between selection and first-use history capture. Old references
-- need no second master-row lock: the previously committed holder row or the
-- newly committed history row is always visible to a competing lifecycle check.
create or replace function private.record_master_reference_history(
  p_master_type text,
  p_master_id uuid,
  p_lock_new_reference boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_master_id is null then
    return;
  end if;

  if p_lock_new_reference then
    case p_master_type
      when 'organizational_units' then
        perform 1 from public.organizational_units x where x.unit_id = p_master_id for key share;
      when 'department_teams' then
        perform 1 from public.department_teams x where x.department_team_id = p_master_id for key share;
      when 'positions' then
        perform 1 from public.positions x where x.position_id = p_master_id for key share;
      when 'position_groups' then
        perform 1 from public.position_groups x where x.position_group_id = p_master_id for key share;
      when 'qualification_levels' then
        perform 1 from public.qualification_levels x where x.qualification_id = p_master_id for key share;
      when 'rooms' then
        perform 1 from public.rooms x where x.room_id = p_master_id for key share;
      when 'interview_formats' then
        perform 1 from public.interview_formats x where x.interview_format_id = p_master_id for key share;
      when 'recruitment_sources' then
        perform 1 from public.recruitment_sources x where x.recruitment_source_id = p_master_id for key share;
      when 'document_types' then
        perform 1 from public.document_types x where x.document_type_id = p_master_id for key share;
      when 'cancellation_reasons' then
        perform 1 from public.cancellation_reasons x where x.cancellation_reason_id = p_master_id for key share;
      when 'rejection_reasons' then
        perform 1 from public.rejection_reasons x where x.rejection_reason_id = p_master_id for key share;
      else
        raise exception 'MASTER_HISTORY_TYPE_UNSUPPORTED:%', p_master_type using errcode = '23514';
    end case;

    if not found then
      raise exception 'MASTER_HISTORY_TARGET_NOT_FOUND:%', p_master_type using errcode = '23503';
    end if;
  end if;

  insert into private.master_reference_history(master_type, master_id)
  values (p_master_type, p_master_id)
  on conflict (master_type, master_id) do nothing;
end;
$$;

revoke all on function private.record_master_reference_history(text, uuid, boolean)
  from public, anon, authenticated;
grant execute on function private.record_master_reference_history(text, uuid, boolean)
  to postgres, service_role;

-- One closed trigger function owns the semantic-reference inventory. On UPDATE
-- and DELETE it captures OLD before accepted lifecycle code can erase evidence;
-- on INSERT/UPDATE it locks and captures NEW before the holder write completes.
create or replace function private.capture_master_reference_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'department_teams' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('organizational_units', old.unit_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('organizational_units', new.unit_id, true);
    end if;

  elsif tg_table_name = 'positions' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('organizational_units', old.unit_id, false);
      perform private.record_master_reference_history('department_teams', old.department_team_id, false);
      perform private.record_master_reference_history('position_groups', old.position_group_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('organizational_units', new.unit_id, true);
      perform private.record_master_reference_history('department_teams', new.department_team_id, true);
      perform private.record_master_reference_history('position_groups', new.position_group_id, true);
    end if;

  elsif tg_table_name = 'applications' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('organizational_units', old.unit_id, false);
      perform private.record_master_reference_history('department_teams', old.department_team_id, false);
      perform private.record_master_reference_history('positions', old.position_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('organizational_units', new.unit_id, true);
      perform private.record_master_reference_history('department_teams', new.department_team_id, true);
      perform private.record_master_reference_history('positions', new.position_id, true);
    end if;

  elsif tg_table_name = 'app_users' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('organizational_units', old.unit_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('organizational_units', new.unit_id, true);
    end if;

  elsif tg_table_name = 'submission_education' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('qualification_levels', old.qualification_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('qualification_levels', new.qualification_id, true);
    end if;

  elsif tg_table_name = 'submissions' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('recruitment_sources', old.recruitment_source_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('recruitment_sources', new.recruitment_source_id, true);
    end if;

  elsif tg_table_name = 'interviews' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('interview_formats', old.interview_format_id, false);
      perform private.record_master_reference_history('rooms', old.room_id, false);
      perform private.record_master_reference_history('cancellation_reasons', old.cancellation_reason_id, false);
      perform private.record_master_reference_history('rejection_reasons', old.rejection_reason_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('interview_formats', new.interview_format_id, true);
      perform private.record_master_reference_history('rooms', new.room_id, true);
      perform private.record_master_reference_history('cancellation_reasons', new.cancellation_reason_id, true);
      perform private.record_master_reference_history('rejection_reasons', new.rejection_reason_id, true);
    end if;

  elsif tg_table_name = 'submission_document_logicals' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('document_types', old.document_type_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('document_types', new.document_type_id, true);
    end if;

  elsif tg_table_name = 'interview_document_logicals' then
    if tg_op <> 'INSERT' then
      perform private.record_master_reference_history('document_types', old.document_type_id, false);
    end if;
    if tg_op <> 'DELETE' then
      perform private.record_master_reference_history('document_types', new.document_type_id, true);
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function private.capture_master_reference_history()
  from public, anon, authenticated;
grant execute on function private.capture_master_reference_history()
  to postgres, service_role;

-- Durable semantic-holder triggers. Temporary upload reservations and staged
-- document changes are intentionally excluded from permanent history.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'department_teams',
    'positions',
    'applications',
    'app_users',
    'submission_education',
    'submissions',
    'interviews',
    'submission_document_logicals',
    'interview_document_logicals'
  ] loop
    execute format('drop trigger if exists s06_master_reference_history_capture on public.%I', v_table);
    execute format(
      'create trigger s06_master_reference_history_capture before insert or update or delete on public.%I for each row execute function private.capture_master_reference_history()',
      v_table
    );
  end loop;
end;
$$;

-- The lifecycle predicate now treats any retained semantic history as usage.
-- Current scans remain for defense-in-depth and for temporary in-flight document
-- references that must block deletion only while they exist.
create or replace function private.master_usage_exists(
  p_master_type text,
  p_master_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from private.master_reference_history h
    where h.master_type = p_master_type
      and h.master_id = p_master_id
  ) then
    return true;
  end if;

  case p_master_type
    when 'organizational_units' then
      return exists (select 1 from public.department_teams x where x.unit_id = p_master_id)
        or exists (select 1 from public.positions x where x.unit_id = p_master_id)
        or exists (select 1 from public.applications x where x.unit_id = p_master_id)
        or exists (select 1 from public.app_users x where x.unit_id = p_master_id);
    when 'department_teams' then
      return exists (select 1 from public.positions x where x.department_team_id = p_master_id)
        or exists (select 1 from public.applications x where x.department_team_id = p_master_id);
    when 'positions' then
      return exists (select 1 from public.applications x where x.position_id = p_master_id);
    when 'position_groups' then
      return exists (select 1 from public.positions x where x.position_group_id = p_master_id);
    when 'qualification_levels' then
      return exists (select 1 from public.submission_education x where x.qualification_id = p_master_id);
    when 'rooms' then
      return exists (select 1 from public.interviews x where x.room_id = p_master_id);
    when 'interview_formats' then
      return exists (select 1 from public.interviews x where x.interview_format_id = p_master_id);
    when 'recruitment_sources' then
      return exists (select 1 from public.submissions x where x.recruitment_source_id = p_master_id);
    when 'document_types' then
      return exists (select 1 from public.submission_document_logicals x where x.document_type_id = p_master_id)
        or exists (select 1 from public.interview_document_logicals x where x.document_type_id = p_master_id)
        or exists (select 1 from public.upload_reservations x where x.intended_document_type_id = p_master_id)
        or exists (
          select 1
          from public.candidate_form_document_changes x
          where x.document_type_id = p_master_id
             or x.intended_document_type_id = p_master_id
        );
    when 'cancellation_reasons' then
      return exists (select 1 from public.interviews x where x.cancellation_reason_id = p_master_id)
        or exists (
          select 1 from private.master_reason_usage_history h
          where h.master_type = 'cancellation_reasons' and h.master_id = p_master_id
        );
    when 'rejection_reasons' then
      return exists (select 1 from public.interviews x where x.rejection_reason_id = p_master_id)
        or exists (
          select 1 from private.master_reason_usage_history h
          where h.master_type = 'rejection_reasons' and h.master_id = p_master_id
        );
    else
      return false;
  end case;
end;
$$;

revoke all on function private.master_usage_exists(text, uuid)
  from public, anon, authenticated;
grant execute on function private.master_usage_exists(text, uuid)
  to postgres, service_role;
