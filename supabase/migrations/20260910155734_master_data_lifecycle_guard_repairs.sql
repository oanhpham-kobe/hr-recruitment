-- TASK-S06-001 repair: materialize canonical Document Type seed semantics and
-- close active-master selection races without invalidating historical references.

-- -----------------------------------------------------------------------------
-- 1. Canonical Document Type seed semantics.
-- Missing rows are materialized Active. Existing rows retain lifecycle/labels.
-- A wrong structural scope is corrected only while still unreferenced; once used,
-- migration fails closed rather than rewriting historical meaning.
-- -----------------------------------------------------------------------------
insert into public.document_types(code, name_vi, name_en, scope_code, is_active)
values
  ('CV_RESUME', 'CV/Resume', 'CV/Resume', 'SUBMISSION', true),
  ('DEGREE', 'Degree', 'Degree', 'SUBMISSION', true),
  ('TRANSCRIPT', 'Transcript', 'Transcript', 'SUBMISSION', true),
  ('LANGUAGE_CERTIFICATE', 'Language Certificate', 'Language Certificate', 'SUBMISSION', true),
  ('PROFESSIONAL_CERTIFICATE', 'Professional Certificate', 'Professional Certificate', 'SUBMISSION', true),
  ('SLIDE_DEMO_MATERIAL', 'Slide/Demo Material', 'Slide/Demo Material', 'INTERVIEW', true),
  ('PUBLICATION', 'Publication', 'Publication', 'INTERVIEW', true),
  ('PORTFOLIO', 'Portfolio', 'Portfolio', 'INTERVIEW', true),
  ('OTHER', 'Other', 'Other', 'BOTH', true)
on conflict (code) do nothing;

do $$
declare
  v_seed record;
  v_existing public.document_types%rowtype;
begin
  for v_seed in
    select *
    from (values
      ('CV_RESUME'::text, 'SUBMISSION'::text),
      ('DEGREE', 'SUBMISSION'),
      ('TRANSCRIPT', 'SUBMISSION'),
      ('LANGUAGE_CERTIFICATE', 'SUBMISSION'),
      ('PROFESSIONAL_CERTIFICATE', 'SUBMISSION'),
      ('SLIDE_DEMO_MATERIAL', 'INTERVIEW'),
      ('PUBLICATION', 'INTERVIEW'),
      ('PORTFOLIO', 'INTERVIEW'),
      ('OTHER', 'BOTH')
    ) as canonical(code, scope_code)
  loop
    select * into v_existing
    from public.document_types d
    where d.code = v_seed.code
    for update;

    if v_existing.scope_code is distinct from v_seed.scope_code then
      if private.master_usage_exists('document_types', v_existing.document_type_id) then
        raise exception 'CANONICAL_DOCUMENT_TYPE_SCOPE_HISTORY_CONFLICT:%', v_seed.code
          using errcode = '23514';
      end if;

      update public.document_types
      set scope_code = v_seed.scope_code
      where document_type_id = v_existing.document_type_id;
    end if;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Active-reference guard.
-- Only INSERT or an actual FK change is validated, so a retained historical row
-- can continue to operate after its master becomes Inactive.
-- Parent/master rows are locked FOR KEY SHARE to serialize against S06 lifecycle
-- FOR UPDATE and close check-then-inactivate races.
-- -----------------------------------------------------------------------------
create or replace function private.validate_s06_active_master_reference()
returns trigger
language plpgsql
set search_path = ''
as $$
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
      perform 1
      from public.document_types d
      where d.document_type_id = new.intended_document_type_id and d.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:document_types'
          using errcode = '23514';
      end if;
    end if;

  elsif tg_table_name = 'candidate_form_document_changes' then
    if new.document_type_id is not null
       and (tg_op = 'INSERT' or new.document_type_id is distinct from old.document_type_id) then
      perform 1
      from public.document_types d
      where d.document_type_id = new.document_type_id and d.is_active = true
      for key share;
      if not found then
        raise exception 'MASTER_INACTIVE_NOT_SELECTABLE:document_types'
          using errcode = '23514';
      end if;
    end if;

    if new.intended_document_type_id is not null
       and (tg_op = 'INSERT' or new.intended_document_type_id is distinct from old.intended_document_type_id) then
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

  return new;
end;
$$;

revoke all on function private.validate_s06_active_master_reference()
  from public, anon, authenticated;
grant execute on function private.validate_s06_active_master_reference()
  to postgres, service_role;

drop trigger if exists s06_department_team_active_master_guard on public.department_teams;
create trigger s06_department_team_active_master_guard
  before insert or update of unit_id on public.department_teams
  for each row execute function private.validate_s06_active_master_reference();

drop trigger if exists s06_position_active_master_guard on public.positions;
create trigger s06_position_active_master_guard
  before insert or update of unit_id, department_team_id, position_group_id on public.positions
  for each row execute function private.validate_s06_active_master_reference();

drop trigger if exists s06_application_active_master_guard on public.applications;
create trigger s06_application_active_master_guard
  before insert or update of unit_id, department_team_id, position_id on public.applications
  for each row execute function private.validate_s06_active_master_reference();

drop trigger if exists s06_education_active_master_guard on public.submission_education;
create trigger s06_education_active_master_guard
  before insert or update of qualification_id on public.submission_education
  for each row execute function private.validate_s06_active_master_reference();

drop trigger if exists s06_submission_source_active_master_guard on public.submissions;
create trigger s06_submission_source_active_master_guard
  before insert or update of recruitment_source_id on public.submissions
  for each row execute function private.validate_s06_active_master_reference();

drop trigger if exists s06_interview_active_master_guard on public.interviews;
create trigger s06_interview_active_master_guard
  before insert or update of interview_format_id, room_id, cancellation_reason_id, rejection_reason_id on public.interviews
  for each row execute function private.validate_s06_active_master_reference();

drop trigger if exists s06_upload_reservation_active_master_guard on public.upload_reservations;
create trigger s06_upload_reservation_active_master_guard
  before insert or update of intended_document_type_id on public.upload_reservations
  for each row execute function private.validate_s06_active_master_reference();

drop trigger if exists s06_candidate_form_document_change_active_master_guard on public.candidate_form_document_changes;
create trigger s06_candidate_form_document_change_active_master_guard
  before insert or update of document_type_id, intended_document_type_id on public.candidate_form_document_changes
  for each row execute function private.validate_s06_active_master_reference();
