-- App Tuyển dụng EIU — Internal User Provisioning Migration
-- Slice 01 / TASK-S01-002: Internal Google Workspace OAuth first-login provisioning command
-- Source authority:
--   recruitment_webapp/review_pack/12_IMPLEMENTATION_NOTES_VERCEL_SUPABASE.md (§Auth)
--   recruitment_webapp/review_pack/37_BACKEND_COMMAND_CONTRACTS.md (§2 Core error codes, §13 Internal Users)
--   recruitment_webapp/review_pack/39_SECURITY_RLS_MATRIX.md (§Identity helpers)
--   recruitment_webapp/review_pack/40_DATABASE_INVARIANTS.md (§app_users invariants, §rebind invariants)

-- -----------------------------------------------------------------------------
-- Transactional first-login provisioning function for internal EIU personnel
-- -----------------------------------------------------------------------------
create or replace function public.provision_internal_user_identity()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_auth_email text;
  v_user record;
  v_roles text[];
  v_permissions text[];
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

  -- Read email from auth.jwt() or auth.users
  v_auth_email := lower(coalesce(
    auth.jwt() ->> 'email',
    (select email::text from auth.users where id = v_auth_uid)
  ));

  if v_auth_email is null or v_auth_email = '' then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Verified email required'
    );
  end if;

  -- 2. Domain check
  if v_auth_email !~ '^[^@[:space:]]+@eiu\.edu\.vn$' then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Only @eiu.edu.vn Google Workspace accounts are permitted'
    );
  end if;

  -- 3. Lookup pre-seeded/invited user
  select * into v_user
  from public.app_users
  where lower(email::text) = v_auth_email
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'User account not found in internal directory'
    );
  end if;

  -- 4. Active check
  if not v_user.is_active then
    return jsonb_build_object(
      'success', false,
      'error_code', 'USER_INACTIVE',
      'message', 'User account is inactive'
    );
  end if;

  -- 5. Rebind defense
  if v_user.auth_user_id is not null and v_user.auth_user_id <> v_auth_uid then
    return jsonb_build_object(
      'success', false,
      'error_code', 'IDENTITY_REBIND_FORBIDDEN',
      'message', 'Account is already bound to a different identity'
    );
  end if;

  -- 6. First-time bind
  if v_user.auth_user_id is null then
    update public.app_users
    set auth_user_id = v_auth_uid,
        updated_at = now(),
        version_no = coalesce(version_no, 0) + 1
    where app_user_id = v_user.app_user_id;
  end if;

  -- 7. Collect roles and permissions
  select coalesce(array_agg(role_code order by role_code), '{}') into v_roles
  from public.app_user_roles
  where app_user_id = v_user.app_user_id;

  select coalesce(array_agg(permission_code order by permission_code), '{}') into v_permissions
  from public.app_user_permissions
  where app_user_id = v_user.app_user_id;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'app_user_id', v_user.app_user_id,
      'auth_user_id', v_auth_uid,
      'email', v_user.email,
      'full_name', v_user.full_name,
      'is_root_admin', v_user.is_root_admin,
      'roles', v_roles,
      'permissions', v_permissions
    )
  );
end;
$$;

comment on function public.provision_internal_user_identity() is
  'Transactional first-login provisioning command for internal Google Workspace OAuth users.';

revoke all on function public.provision_internal_user_identity() from public, anon;
grant execute on function public.provision_internal_user_identity() to authenticated, postgres, service_role;
