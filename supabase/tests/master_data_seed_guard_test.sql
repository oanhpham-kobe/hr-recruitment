-- TASK-S06-001: canonical Document Type seed and DB active-reference guard checks.
\set ON_ERROR_STOP on

do $$
begin
  assert (
    select count(*) = 9
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
    ) expected(code, scope_code)
    join public.document_types d
      on d.code = expected.code
     and d.scope_code = expected.scope_code
  ), 'all 9 canonical Document Type seed scopes must be materialized exactly';

  assert has_table_privilege('anon', 'public.document_types', 'SELECT'),
    'accepted anonymous Document Type lookup SELECT must be preserved';
  assert not has_table_privilege('anon', 'public.document_types', 'INSERT'),
    'anon must not gain Document Type INSERT';
  assert not has_table_privilege('anon', 'public.document_types', 'UPDATE'),
    'anon must not gain Document Type UPDATE';
  assert not has_table_privilege('anon', 'public.document_types', 'DELETE'),
    'anon must not gain Document Type DELETE';

  assert (
    select count(*) = 8
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and not t.tgisinternal
      and t.tgname in (
        's06_department_team_active_master_guard',
        's06_position_active_master_guard',
        's06_application_active_master_guard',
        's06_education_active_master_guard',
        's06_submission_source_active_master_guard',
        's06_interview_active_master_guard',
        's06_upload_reservation_active_master_guard',
        's06_candidate_form_document_change_active_master_guard'
      )
  ), 'S06 active-reference guards must be installed on all owned consumer surfaces';

  assert not has_function_privilege(
    'authenticated', 'private.validate_s06_active_master_reference()', 'EXECUTE'
  ), 'authenticated must not execute S06 active-reference helper directly';
end;
$$;
