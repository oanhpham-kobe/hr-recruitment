-- =============================================================================
-- RECOVERY PACKAGE 005: REC-15 Whole HR Submission Editing
--
-- Implements atomic versioned aggregate Save for HR:
--   1. Permitted profile fields (full_name, phone, date_of_birth, gender_code, current_address)
--   2. Recruitment source (recruitment_source_id)
--   3. HR note (hr_note)
--   4. Education records (submission_education)
--
-- Invariants enforced:
--   - Email is strictly immutable (email_snapshot cannot be modified)
--   - Atomic transaction with FOR UPDATE row lock on public.submissions
--   - Mandatory positive expected_version guard with STALE_VERSION rejection
--   - Inactive recruitment sources and qualification levels rejected
--   - Security audit logging with changed_fields metadata
--   - Automatic candidate profile cache refresh when editing latest submission
-- =============================================================================

create or replace function public.update_submission_aggregate_by_hr(
  p_submission_id uuid,
  p_expected_version bigint,
  p_full_name text default null,
  p_phone text default null,
  p_date_of_birth date default null,
  p_gender_code text default null,
  p_current_address text default null,
  p_recruitment_source_id uuid default null,
  p_hr_note text default null,
  p_education jsonb default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
  v_sub record;
  v_changed_fields text[] := '{}';
  v_new_full_name text;
  v_new_phone text;
  v_new_dob date;
  v_new_gender text;
  v_new_address text;
  v_new_source_id uuid;
  v_new_hr_note text;
  v_item jsonb;
  v_sort integer;
  v_qual_id uuid;
  v_now timestamptz;
begin
  -- 1. Authorization: Root Admin OR submissions.edit
  v_auth_user_id := auth.uid();
  if v_auth_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Authenticated internal user required'
    );
  end if;

  select u.app_user_id into v_actor_app_user_id
  from public.app_users u
  where u.auth_user_id = v_auth_user_id
    and u.is_active = true;

  if v_actor_app_user_id is null
    or not (private.has_permission('submissions.edit') or private.is_root_admin()) then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.edit required'
    );
  end if;

  -- 2. Validate mandatory optimistic expected_version
  if p_expected_version is null or p_expected_version <= 0 then
    return jsonb_build_object(
      'success', false,
      'error_code', 'VALIDATION_ERROR',
      'message', 'Expected version is required and must be positive'
    );
  end if;

  -- 3. Lock Submission row FOR UPDATE
  select * into v_sub
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

  -- 4. Optimistic expected_version check
  if v_sub.version_no <> p_expected_version then
    return jsonb_build_object(
      'success', false,
      'error_code', 'STALE_VERSION',
      'message', 'Submission version mismatch; reload required'
    );
  end if;

  -- 5. Field validations & preparation
  v_new_full_name := v_sub.full_name;
  if p_full_name is not null then
    if btrim(p_full_name) = '' or char_length(btrim(p_full_name)) > 200 then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'Full name must not be empty and must not exceed 200 characters'
      );
    end if;
    if btrim(p_full_name) is distinct from v_sub.full_name then
      v_new_full_name := btrim(p_full_name);
      v_changed_fields := array_append(v_changed_fields, 'full_name');
    end if;
  end if;

  v_new_phone := v_sub.phone;
  if p_phone is not null then
    if btrim(p_phone) = '' or char_length(btrim(p_phone)) > 32 then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'Phone number must not be empty and must not exceed 32 characters'
      );
    end if;
    if btrim(p_phone) is distinct from v_sub.phone then
      v_new_phone := btrim(p_phone);
      v_changed_fields := array_append(v_changed_fields, 'phone');
    end if;
  end if;

  v_new_dob := v_sub.date_of_birth;
  if p_date_of_birth is not null then
    if p_date_of_birth < '1900-01-01'::date or p_date_of_birth > current_date then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'Date of birth must be between 1900-01-01 and today'
      );
    end if;
    if p_date_of_birth is distinct from v_sub.date_of_birth then
      v_new_dob := p_date_of_birth;
      v_changed_fields := array_append(v_changed_fields, 'date_of_birth');
    end if;
  end if;

  v_new_gender := v_sub.gender_code;
  if p_gender_code is not null then
    if upper(btrim(p_gender_code)) not in ('MALE', 'FEMALE') then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'Gender must be MALE or FEMALE'
      );
    end if;
    if upper(btrim(p_gender_code)) is distinct from v_sub.gender_code then
      v_new_gender := upper(btrim(p_gender_code));
      v_changed_fields := array_append(v_changed_fields, 'gender_code');
    end if;
  end if;

  v_new_address := v_sub.current_address;
  if p_current_address is not null then
    if btrim(p_current_address) = '' or char_length(btrim(p_current_address)) > 500 then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'Address must not be empty and must not exceed 500 characters'
      );
    end if;
    if btrim(p_current_address) is distinct from v_sub.current_address then
      v_new_address := btrim(p_current_address);
      v_changed_fields := array_append(v_changed_fields, 'current_address');
    end if;
  end if;

  v_new_source_id := v_sub.recruitment_source_id;
  if p_recruitment_source_id is distinct from v_sub.recruitment_source_id then
    if p_recruitment_source_id is not null then
      if not exists (
        select 1
        from public.recruitment_sources
        where recruitment_source_id = p_recruitment_source_id
          and is_active = true
      ) then
        return jsonb_build_object(
          'success', false,
          'error_code', 'INVALID_MASTER_DATA',
          'message', 'Recruitment source is inactive or does not exist'
        );
      end if;
    end if;
    v_new_source_id := p_recruitment_source_id;
    v_changed_fields := array_append(v_changed_fields, 'recruitment_source_id');
  end if;

  v_new_hr_note := v_sub.hr_note;
  if p_hr_note is not null or v_sub.hr_note is not null then
    if nullif(btrim(coalesce(p_hr_note, '')), '') is distinct from v_sub.hr_note then
      v_new_hr_note := nullif(btrim(coalesce(p_hr_note, '')), '');
      v_changed_fields := array_append(v_changed_fields, 'hr_note');
    end if;
  end if;

  -- 6. Education replacement (if provided)
  if p_education is not null then
    if jsonb_typeof(p_education) <> 'array' then
      return jsonb_build_object(
        'success', false,
        'error_code', 'VALIDATION_ERROR',
        'message', 'Education must be a JSON array'
      );
    end if;

    -- Preflight: validate all qualification levels are active before deleting existing rows
    for v_item in select * from jsonb_array_elements(p_education) loop
      if v_item ? 'qualification_id' and (v_item ->> 'qualification_id') is not null and (v_item ->> 'qualification_id') <> '' then
        v_qual_id := (v_item ->> 'qualification_id')::uuid;
        if not exists (
          select 1
          from public.qualification_levels
          where qualification_id = v_qual_id
            and is_active = true
        ) then
          return jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_MASTER_DATA',
            'message', 'Qualification level is inactive or does not exist'
          );
        end if;
      end if;
    end loop;

    -- All items pre-validated: execute atomic replacement
    delete from public.submission_education where submission_id = p_submission_id;

    v_sort := 1;
    for v_item in select * from jsonb_array_elements(p_education) loop
      v_qual_id := null;
      if v_item ? 'qualification_id' and (v_item ->> 'qualification_id') is not null and (v_item ->> 'qualification_id') <> '' then
        v_qual_id := (v_item ->> 'qualification_id')::uuid;
      end if;

      insert into public.submission_education (
        submission_id,
        sort_order,
        period_text,
        institution,
        major,
        qualification_id
      ) values (
        p_submission_id,
        v_sort,
        nullif(btrim(coalesce(v_item ->> 'period_text', '')), ''),
        coalesce(btrim(coalesce(v_item ->> 'institution', v_item ->> 'institution_name', '')), ''),
        coalesce(btrim(coalesce(v_item ->> 'major', v_item ->> 'major_name', '')), ''),
        v_qual_id
      );
      v_sort := v_sort + 1;
    end loop;
    v_changed_fields := array_append(v_changed_fields, 'education');
  end if;

  v_now := clock_timestamp();

  -- 7. Apply updates to submission
  update public.submissions
  set
    full_name = v_new_full_name,
    phone = v_new_phone,
    date_of_birth = v_new_dob,
    gender_code = v_new_gender,
    current_address = v_new_address,
    recruitment_source_id = v_new_source_id,
    hr_note = v_new_hr_note,
    updated_at = v_now,
    updated_by_internal_user_id = v_actor_app_user_id
  where submission_id = p_submission_id
  returning * into v_sub;

  -- 8. Refresh Candidate profile cache if latest
  perform private.refresh_candidate_current_profile(v_sub.candidate_id);

  -- 9. Mandatory Security Audit Logging
  insert into public.security_audit_log (
    action_code,
    actor_app_user_id,
    entity_type,
    entity_id,
    metadata,
    reason,
    source_code,
    result_code
  ) values (
    'UPDATE_SUBMISSION_AGGREGATE_BY_HR',
    v_actor_app_user_id,
    'SUBMISSION',
    p_submission_id,
    jsonb_build_object(
      'submission_id', p_submission_id,
      'candidate_id', v_sub.candidate_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'version_no', v_sub.version_no
    ),
    p_reason,
    'RPC',
    'SUCCESS'
  );

  return jsonb_build_object(
    'success', true,
    'submission_id', v_sub.submission_id,
    'version_no', v_sub.version_no,
    'changed_fields', v_changed_fields
  );
end;
$$;

revoke all on function public.update_submission_aggregate_by_hr(uuid, bigint, text, text, date, text, text, uuid, text, jsonb, text) from public, anon;
grant execute on function public.update_submission_aggregate_by_hr(uuid, bigint, text, text, date, text, text, uuid, text, jsonb, text) to authenticated;
