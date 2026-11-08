-- TASK-S06-001 independent review repairs R1-R4.
-- Append-only repair over the accepted S06 candidate.

-- -----------------------------------------------------------------------------
-- R1. Durable first-use history for cancellation/rejection reasons.
-- Accepted lifecycle normalization intentionally clears replaceable reason FKs
-- after leaving CANCELLED/REJECTED, so current FK scans alone cannot define
-- "ever referenced" history.
-- -----------------------------------------------------------------------------
create table if not exists private.master_reason_usage_history (
  master_type text not null check (master_type in ('cancellation_reasons', 'rejection_reasons')),
  master_id uuid not null,
  first_used_at timestamptz not null default clock_timestamp(),
  primary key (master_type, master_id)
);

revoke all on private.master_reason_usage_history from public, anon, authenticated;
grant all on private.master_reason_usage_history to postgres, service_role;

-- Backfill every usage that is still provable from retained Interview state.
insert into private.master_reason_usage_history(master_type, master_id, first_used_at)
select 'cancellation_reasons', i.cancellation_reason_id, coalesce(i.created_at, clock_timestamp())
from public.interviews i
where i.schedule_status_code = 'CANCELLED'
  and i.cancellation_reason_id is not null
on conflict (master_type, master_id) do nothing;

insert into private.master_reason_usage_history(master_type, master_id, first_used_at)
select 'rejection_reasons', i.rejection_reason_id, coalesce(i.created_at, clock_timestamp())
from public.interviews i
where i.report_status_code = 'REJECTED'
  and i.rejection_reason_id is not null
on conflict (master_type, master_id) do nothing;

create or replace function private.capture_interview_reason_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Lock the selected reason before recording first use so a concurrent
  -- structural master update cannot pass between selection and history capture.
  if new.schedule_status_code = 'CANCELLED' and new.cancellation_reason_id is not null then
    perform 1
    from public.cancellation_reasons r
    where r.cancellation_reason_id = new.cancellation_reason_id
    for key share;

    insert into private.master_reason_usage_history(master_type, master_id)
    values ('cancellation_reasons', new.cancellation_reason_id)
    on conflict (master_type, master_id) do nothing;
  end if;

  if new.report_status_code = 'REJECTED' and new.rejection_reason_id is not null then
    perform 1
    from public.rejection_reasons r
    where r.rejection_reason_id = new.rejection_reason_id
    for key share;

    insert into private.master_reason_usage_history(master_type, master_id)
    values ('rejection_reasons', new.rejection_reason_id)
    on conflict (master_type, master_id) do nothing;
  end if;

  -- Defensive capture of the previously valid semantic state on UPDATE. This
  -- preserves history even when the same statement transitions away from the
  -- terminal status and the later normalization trigger clears the FK.
  if tg_op = 'UPDATE' then
    if old.schedule_status_code = 'CANCELLED' and old.cancellation_reason_id is not null then
      insert into private.master_reason_usage_history(master_type, master_id)
      values ('cancellation_reasons', old.cancellation_reason_id)
      on conflict (master_type, master_id) do nothing;
    end if;

    if old.report_status_code = 'REJECTED' and old.rejection_reason_id is not null then
      insert into private.master_reason_usage_history(master_type, master_id)
      values ('rejection_reasons', old.rejection_reason_id)
      on conflict (master_type, master_id) do nothing;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.capture_interview_reason_history()
  from public, anon, authenticated;
grant execute on function private.capture_interview_reason_history()
  to postgres, service_role;

drop trigger if exists a_s06_interview_reason_history_capture on public.interviews;
create trigger a_s06_interview_reason_history_capture
  before insert or update of schedule_status_code, report_status_code, cancellation_reason_id, rejection_reason_id
  on public.interviews
  for each row execute function private.capture_interview_reason_history();

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
          select 1
          from private.master_reason_usage_history h
          where h.master_type = 'cancellation_reasons' and h.master_id = p_master_id
        );
    when 'rejection_reasons' then
      return exists (select 1 from public.interviews x where x.rejection_reason_id = p_master_id)
        or exists (
          select 1
          from private.master_reason_usage_history h
          where h.master_type = 'rejection_reasons' and h.master_id = p_master_id
        );
    else
      return false;
  end case;
end;
$$;

-- -----------------------------------------------------------------------------
-- R2. Active Document Type selection is required only for a new selection.
-- Historical Candidate EDIT reservations may retain the existing inactive type;
-- the trusted stage command still owns target/ownership/type/current-version
-- validation, while ADD remains an active-only selection.
-- -----------------------------------------------------------------------------
create or replace function private.validate_s06_active_master_reference()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_session_mode text;
  v_document_type_id uuid;
begin
  if tg_table_name = 'department_teams' then
    if tg_op = 'INSERT' or new.unit_id is distinct from old.unit_id then
      perform 1
      from public.organizational_units u
      where u.unit_id = new.unit_id and u.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:organizational_units'
          using errcode = '23514';
      end if;
    end if;

  elsif tg_table_name = 'positions' then
    if tg_op = 'INSERT' or new.unit_id is distinct from old.unit_id then
      perform 1
      from public.organizational_units u
      where u.unit_id = new.unit_id and u.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:organizational_units'
          using errcode = '23514';
      end if;
    end if;

    if tg_op = 'INSERT' or new.position_group_id is distinct from old.position_group_id then
      perform 1
      from public.position_groups g
      where g.position_group_id = new.position_group_id and g.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:position_groups'
          using errcode = '23514';
      end if;
    end if;

    if new.department_team_id is not null
       and (tg_op = 'INSERT'
         or new.department_team_id is distinct from old.department_team_id
         or new.unit_id is distinct from old.unit_id) then
      perform 1
      from public.department_teams t
      where t.department_team_id = new.department_team_id
        and t.unit_id = new.unit_id
        and t.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_OR_HIERARCHY_INVALID:department_teams'
          using errcode = '23514';
      end if;
    end if;

  elsif tg_table_name = 'applications' then
    if tg_op = 'INSERT' or new.unit_id is distinct from old.unit_id then
      perform 1
      from public.organizational_units u
      where u.unit_id = new.unit_id and u.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:organizational_units'
          using errcode = '23514';
      end if;
    end if;

    if new.department_team_id is not null
       and (tg_op = 'INSERT'
         or new.department_team_id is distinct from old.department_team_id
         or new.unit_id is distinct from old.unit_id) then
      perform 1
      from public.department_teams t
      where t.department_team_id = new.department_team_id
        and t.unit_id = new.unit_id
        and t.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_OR_HIERARCHY_INVALID:department_teams'
          using errcode = '23514';
      end if;
    end if;

    if tg_op = 'INSERT'
       or new.position_id is distinct from old.position_id
       or new.unit_id is distinct from old.unit_id
       or new.department_team_id is distinct from old.department_team_id then
      perform 1
      from public.positions p
      where p.position_id = new.position_id
        and p.is_active = true
        and p.unit_id = new.unit_id
        and p.department_team_id is not distinct from new.department_team_id
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_OR_HIERARCHY_INVALID:positions'
          using errcode = '23514';
      end if;
    end if;

  elsif tg_table_name = 'submission_education' then
    if new.qualification_id is not null
       and (tg_op = 'INSERT' or new.qualification_id is distinct from old.qualification_id) then
      perform 1
      from public.qualification_levels q
      where q.qualification_id = new.qualification_id and q.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:qualification_levels'
          using errcode = '23514';
      end if;
    end if;

  elsif tg_table_name = 'submissions' then
    if new.recruitment_source_id is not null
       and (tg_op = 'INSERT' or new.recruitment_source_id is distinct from old.recruitment_source_id) then
      perform 1
      from public.recruitment_sources r
      where r.recruitment_source_id = new.recruitment_source_id and r.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:recruitment_sources'
          using errcode = '23514';
      end if;
    end if;

  elsif tg_table_name = 'interviews' then
    if new.interview_format_id is not null
       and (tg_op = 'INSERT' or new.interview_format_id is distinct from old.interview_format_id) then
      perform 1
      from public.interview_formats f
      where f.interview_format_id = new.interview_format_id and f.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:interview_formats'
          using errcode = '23514';
      end if;
    end if;

    if new.room_id is not null
       and (tg_op = 'INSERT' or new.room_id is distinct from old.room_id) then
      perform 1
      from public.rooms r
      where r.room_id = new.room_id and r.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:rooms'
          using errcode = '23514';
      end if;
    end if;

    if new.cancellation_reason_id is not null
       and (tg_op = 'INSERT' or new.cancellation_reason_id is distinct from old.cancellation_reason_id) then
      perform 1
      from public.cancellation_reasons r
      where r.cancellation_reason_id = new.cancellation_reason_id and r.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:cancellation_reasons'
          using errcode = '23514';
      end if;
    end if;

    if new.rejection_reason_id is not null
       and (tg_op = 'INSERT' or new.rejection_reason_id is distinct from old.rejection_reason_id) then
      perform 1
      from public.rejection_reasons r
      where r.rejection_reason_id = new.rejection_reason_id and r.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:rejection_reasons'
          using errcode = '23514';
      end if;
    end if;

  elsif tg_table_name = 'upload_reservations' then
    if tg_op = 'INSERT' or new.intended_document_type_id is distinct from old.intended_document_type_id then
      v_session_mode := null;
      if new.candidate_form_session_id is not null then
        select s.mode_code into v_session_mode
        from public.candidate_form_sessions s
        where s.candidate_form_session_id = new.candidate_form_session_id;
      end if;

      -- EDIT_SUBMISSION reservations can only become a retained historical
      -- REPLACE at the later trusted staging seam. NEW_SUBMISSION and Interview
      -- reservations are new selections and stay active-only.
      if new.candidate_form_session_id is null or v_session_mode is distinct from 'EDIT_SUBMISSION' then
        perform 1
        from public.document_types d
        where d.document_type_id = new.intended_document_type_id and d.is_active = true
        for key share;
        if not found then
          raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:document_types'
            using errcode = '23514';
        end if;
      end if;
    end if;

  elsif tg_table_name = 'candidate_form_document_changes' then
    -- Only ADD creates a new logical document/type selection. REPLACE/DELETE
    -- preserve the existing logical type and are validated by the accepted
    -- trusted stage command against target ownership, type equality and current
    -- version before this row is inserted.
    if new.action_code = 'ADD'
       and (tg_op = 'INSERT'
         or new.document_type_id is distinct from old.document_type_id
         or new.intended_document_type_id is distinct from old.intended_document_type_id) then
      v_document_type_id := coalesce(new.intended_document_type_id, new.document_type_id);
      perform 1
      from public.document_types d
      where d.document_type_id = v_document_type_id and d.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:document_types'
          using errcode = '23514';
      end if;
    end if;
  end if;

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- R3. Interview Format metadata is locked before authoritative validation.
-- This closes first-use vs structural metadata-update races: the requirements
-- read and the Interview write now share one transaction-scoped row lock.
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

  select f.requires_room, f.requires_meeting_link, f.is_active
  into req_room, req_link, fmt_active
  from public.interview_formats f
  where f.interview_format_id = new.interview_format_id
  for key share;

  if not found then
    raise exception 'interview format not found' using errcode = '23503';
  end if;
  if format_changed and coalesce(fmt_active, false) = false then
    raise exception 'inactive interview format cannot be selected for a new/change operation' using errcode = '23514';
  end if;

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

-- -----------------------------------------------------------------------------
-- R4. A manage-only actor needs the minimum inactive management read surface.
-- Preserve accepted anonymous active-only reads and submissions-view behavior.
-- -----------------------------------------------------------------------------
drop policy if exists recruitment_sources_authenticated_select on public.recruitment_sources;
create policy recruitment_sources_authenticated_select on public.recruitment_sources
  for select to authenticated
  using (
    is_active = true
    or private.has_permission('submissions.view')
    or private.has_permission('master_data.manage')
    or private.is_root_admin()
  );

drop policy if exists document_types_authenticated_select on public.document_types;
create policy document_types_authenticated_select on public.document_types
  for select to authenticated
  using (
    is_active = true
    or private.has_permission('submissions.view')
    or private.has_permission('master_data.manage')
    or private.is_root_admin()
  );

drop policy if exists qualification_levels_authenticated_select on public.qualification_levels;
create policy qualification_levels_authenticated_select on public.qualification_levels
  for select to authenticated
  using (
    is_active = true
    or private.has_permission('submissions.view')
    or private.has_permission('master_data.manage')
    or private.is_root_admin()
  );

-- -----------------------------------------------------------------------------
-- R2b. The staged-document validator validates staging, not trusted terminalization.
-- Materialization/finalization changes reservation/current-version state before the
-- trusted command marks the immutable plan APPLIED; cancellation likewise cancels
-- its reservation/session first. Permit only the one-way terminal status transition
-- when every plan field is unchanged, and retain full validation for staging.
-- -----------------------------------------------------------------------------
create or replace function private.validate_candidate_form_document_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  form_mode text;
  form_status text;
  form_expires_at timestamptz;
  target_submission uuid;
  logical_submission uuid;
  logical_type uuid;
  current_version_count integer;
  reservation_session uuid;
  reservation_type uuid;
  reservation_status text;
  reservation_expires_at timestamptz;
  doc_scope text;
  doc_active boolean;
begin
  if tg_op = 'UPDATE' then
    if old.status_code = 'PENDING' and new.status_code in ('APPLIED', 'CANCELLED') then
      if new.candidate_form_session_id is distinct from old.candidate_form_session_id
        or new.action_code is distinct from old.action_code
        or new.target_logical_document_id is distinct from old.target_logical_document_id
        or new.upload_reservation_id is distinct from old.upload_reservation_id
        or new.document_type_id is distinct from old.document_type_id
        or new.intended_document_type_id is distinct from old.intended_document_type_id
        or new.created_at is distinct from old.created_at then
        raise exception 'candidate document plan is immutable during terminal transition'
          using errcode = '23514';
      end if;
      return new;
    end if;

    if old.status_code in ('APPLIED', 'CANCELLED')
       and new.status_code is distinct from old.status_code then
      raise exception 'candidate document terminal state cannot transition'
        using errcode = '23514';
    end if;
  end if;

  select fs.mode_code, fs.status_code, fs.expires_at, fs.target_submission_id
    into form_mode, form_status, form_expires_at, target_submission
  from public.candidate_form_sessions fs
  where fs.candidate_form_session_id = new.candidate_form_session_id;
  if not found then raise exception 'candidate form session not found' using errcode = '23503'; end if;
  if form_status <> 'OPEN' then
    raise exception 'document changes require an OPEN candidate form session' using errcode = '23514';
  end if;
  if form_expires_at <= transaction_timestamp() then
    raise exception 'FORM_SESSION_EXPIRED' using errcode = '23514';
  end if;

  if form_mode = 'NEW_SUBMISSION' and new.action_code <> 'ADD' then
    raise exception 'new Submission form only supports staged ADD document actions' using errcode = '23514';
  end if;

  select d.scope_code, d.is_active into doc_scope, doc_active
  from public.document_types d where d.document_type_id = new.intended_document_type_id;
  if not found then raise exception 'document type not found' using errcode = '23503'; end if;
  if doc_scope not in ('SUBMISSION','BOTH') then
    raise exception 'document type is not valid for Submission documents' using errcode = '23514';
  end if;
  if new.action_code = 'ADD' and not doc_active then
    raise exception 'inactive document type cannot be selected for a new document' using errcode = '23514';
  end if;

  if new.target_logical_document_id is not null then
    select l.submission_id, l.document_type_id into logical_submission, logical_type
    from public.submission_document_logicals l where l.logical_document_id = new.target_logical_document_id;
    if not found or target_submission is null or logical_submission is distinct from target_submission then
      raise exception 'target logical document does not belong to edit Submission' using errcode = '23514';
    end if;
    if logical_type is distinct from new.intended_document_type_id then
      raise exception 'replace/delete document type must match logical header type' using errcode = '23514';
    end if;
    if new.action_code in ('REPLACE','DELETE') then
      select count(*) into current_version_count
      from public.submission_documents v
      where v.logical_document_id = new.target_logical_document_id and v.is_current = true;
      if current_version_count <> 1 then
        raise exception 'INVALID_DOCUMENT_TARGET: replace/delete requires exactly one current version' using errcode = '23514';
      end if;
    end if;
  end if;

  if new.upload_reservation_id is not null then
    select u.candidate_form_session_id, u.intended_document_type_id, u.status_code, u.expires_at
      into reservation_session, reservation_type, reservation_status, reservation_expires_at
    from public.upload_reservations u where u.upload_reservation_id = new.upload_reservation_id;
    if not found or reservation_session is distinct from new.candidate_form_session_id then
      raise exception 'upload reservation does not belong to candidate form session' using errcode = '23514';
    end if;
    if reservation_type is distinct from new.intended_document_type_id then
      raise exception 'upload reservation document type mismatch' using errcode = '23514';
    end if;
    if reservation_status not in ('UPLOADED','VALIDATED') then
      raise exception 'upload reservation is not stageable' using errcode = '23514';
    end if;
    if reservation_expires_at <= transaction_timestamp() then
      raise exception 'UPLOAD_RESERVATION_EXPIRED' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
