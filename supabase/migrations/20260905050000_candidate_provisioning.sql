-- App Tuyển dụng EIU — Candidate Provisioning Migration
-- Slice 01 / TASK-S01-003: Candidate Email OTP identity verification and provisioning command
-- Source authority:
--   recruitment_webapp/review_pack/12_IMPLEMENTATION_NOTES_VERCEL_SUPABASE.md (§Auth)
--   recruitment_webapp/review_pack/37_BACKEND_COMMAND_CONTRACTS.md (§2 Core error codes, §3 provision_candidate_identity())
--   recruitment_webapp/review_pack/39_SECURITY_RLS_MATRIX.md (§Identity helpers, §Read/Write matrix)
--   recruitment_webapp/review_pack/40_DATABASE_INVARIANTS.md (§Candidate invariants, §Safe rebind)

-- -----------------------------------------------------------------------------
-- Transactional candidate provisioning function
-- -----------------------------------------------------------------------------
create or replace function public.provision_candidate_identity()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_auth_email text;
  v_norm_email text;
  v_cand record;
begin
  -- 1. Authenticate
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Authentication required'
    );
  end if;

  -- 2. Read email
  v_auth_email := coalesce(
    auth.jwt() ->> 'email',
    (select email::text from auth.users where id = v_auth_uid)
  );

  if v_auth_email is null or trim(v_auth_email) = '' then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Verified email required'
    );
  end if;

  v_norm_email := lower(trim(v_auth_email));

  -- 3. Lookup by auth_user_id
  select * into v_cand
  from public.candidates
  where auth_user_id = v_auth_uid;

  if found then
    if not v_cand.is_active then
      return jsonb_build_object(
        'success', false,
        'error_code', 'USER_INACTIVE',
        'message', 'Candidate account is inactive'
      );
    end if;

    return jsonb_build_object(
      'success', true,
      'data', jsonb_build_object(
        'candidate_id', v_cand.candidate_id,
        'auth_user_id', v_cand.auth_user_id,
        'email', v_cand.email,
        'current_full_name', v_cand.current_full_name,
        'current_phone', v_cand.current_phone,
        'is_active', v_cand.is_active
      )
    );
  end if;

  -- 4. Fallback lookup by normalized email
  select * into v_cand
  from public.candidates
  where email = v_norm_email::extensions.citext
  for update;

  if found then
    if not v_cand.is_active then
      return jsonb_build_object(
        'success', false,
        'error_code', 'USER_INACTIVE',
        'message', 'Candidate account is inactive'
      );
    end if;

    -- Safe rebind
    update public.candidates
    set auth_user_id = v_auth_uid,
        updated_at = now(),
        version_no = coalesce(version_no, 0) + 1
    where candidate_id = v_cand.candidate_id
    returning * into v_cand;

    return jsonb_build_object(
      'success', true,
      'data', jsonb_build_object(
        'candidate_id', v_cand.candidate_id,
        'auth_user_id', v_cand.auth_user_id,
        'email', v_cand.email,
        'current_full_name', v_cand.current_full_name,
        'current_phone', v_cand.current_phone,
        'is_active', v_cand.is_active
      )
    );
  end if;

  -- 5. Create new candidate
  insert into public.candidates (
    auth_user_id,
    email,
    is_active,
    version_no
  ) values (
    v_auth_uid,
    v_norm_email::extensions.citext,
    true,
    1
  ) returning * into v_cand;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_id', v_cand.candidate_id,
      'auth_user_id', v_cand.auth_user_id,
      'email', v_cand.email,
      'current_full_name', v_cand.current_full_name,
      'current_phone', v_cand.current_phone,
      'is_active', v_cand.is_active
    )
  );
end;
$$;

comment on function public.provision_candidate_identity() is
  'Transactional candidate OTP identity verification and provisioning command.';

revoke all on function public.provision_candidate_identity() from public, anon;
grant execute on function public.provision_candidate_identity() to authenticated, postgres, service_role;
