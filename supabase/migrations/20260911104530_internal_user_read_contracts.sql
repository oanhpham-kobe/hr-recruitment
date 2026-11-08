-- TASK-S06-002 / Part 1B: minimum-safe Internal User/RBAC read surfaces.
-- Depends on 20260911104500_internal_user_serialization_contracts.sql.

-- -----------------------------------------------------------------------------
-- 3. Minimum-safe directory and permission read surfaces
-- -----------------------------------------------------------------------------
-- app_users mixes business-directory data with the Supabase Auth binding. Keep
-- the raw security identity column (`auth_user_id`) unavailable to ordinary
-- authenticated clients while preserving the accepted Interview selectors on
-- the safe business columns below. SECURITY DEFINER session/directory RPCs own
-- the few reads that genuinely need the binding state.
revoke select on public.app_users from anon, authenticated;
grant select (
  app_user_id, email, full_name, job_title, unit_id, is_active, is_root_admin,
  created_at, updated_at, version_no
) on public.app_users to authenticated;

drop policy if exists app_users_select_policy on public.app_users;
create policy app_users_select_policy on public.app_users
  for select to authenticated
  using (
    app_user_id = (select private.current_app_user_id())
    or (select private.is_root_admin())
    or (
      private.has_permission('users.directory_manage')
      or private.has_permission('users.directory_read')
    )
    or (
      is_active = true
      and (
        private.has_permission('applications.view')
        or private.has_permission('applications.manage')
        or private.has_permission('interviews.view')
        or private.has_permission('interviews.manage')
        or private.has_permission('interviews.participants')
      )
    )
  );

drop policy if exists app_user_roles_select_policy on public.app_user_roles;
create policy app_user_roles_select_policy on public.app_user_roles
  for select to authenticated
  using (
    app_user_id = (select private.current_app_user_id())
    or (select private.is_root_admin())
    or private.has_permission('users.directory_read')
    or private.has_permission('users.directory_manage')
  );

drop policy if exists app_user_permissions_select_policy on public.app_user_permissions;
create policy app_user_permissions_select_policy on public.app_user_permissions
  for select to authenticated
  using (
    app_user_id = (select private.current_app_user_id())
    or (select private.is_root_admin())
  );

create or replace function public.get_current_internal_session()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_user public.app_users%rowtype;
  v_roles jsonb;
  v_permissions jsonb;
begin
  if v_auth_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error_code', 'UNAUTHENTICATED',
      'message', 'Authentication required'
    );
  end if;

  select * into v_user
  from public.app_users u
  where u.auth_user_id = v_auth_user_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Internal user binding not found'
    );
  end if;
  if not v_user.is_active then
    return jsonb_build_object(
      'success', false,
      'error_code', 'USER_INACTIVE',
      'message', 'User account is inactive'
    );
  end if;

  select coalesce(jsonb_agg(r.role_code order by r.role_code), '[]'::jsonb)
  into v_roles
  from public.app_user_roles r
  where r.app_user_id = v_user.app_user_id;

  if v_user.is_root_admin then
    select coalesce(jsonb_agg(p.permission_code order by p.permission_code), '[]'::jsonb)
    into v_permissions
    from public.permissions p;
  else
    select coalesce(jsonb_agg(p.permission_code order by p.permission_code), '[]'::jsonb)
    into v_permissions
    from public.app_user_permissions p
    where p.app_user_id = v_user.app_user_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'app_user_id', v_user.app_user_id,
      'is_active', v_user.is_active,
      'is_root_admin', v_user.is_root_admin,
      'roles', v_roles,
      'permissions', v_permissions
    )
  );
end;
$$;

create or replace function public.list_internal_user_directory(
  p_include_inactive boolean default true
)
returns table (
  app_user_id uuid,
  email text,
  full_name text,
  job_title text,
  unit_id uuid,
  is_active boolean,
  is_root_admin boolean,
  is_hr boolean,
  identity_bound boolean,
  version_no bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  if not (
    private.is_root_admin()
    or private.has_permission('users.directory_read')
    or private.has_permission('users.directory_manage')
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query
  select
    u.app_user_id,
    u.email::text,
    u.full_name,
    u.job_title,
    u.unit_id,
    u.is_active,
    u.is_root_admin,
    exists (
      select 1
      from public.app_user_roles r
      where r.app_user_id = u.app_user_id
        and r.role_code = 'HR'
    ) as is_hr,
    (u.auth_user_id is not null) as identity_bound,
    u.version_no
  from public.app_users u
  where p_include_inactive or u.is_active = true
  order by lower(u.full_name), u.app_user_id;
end;
$$;

create or replace function public.list_internal_user_selector()
returns table (
  app_user_id uuid,
  email text,
  full_name text,
  job_title text,
  unit_id uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  if not (
    private.is_root_admin()
    or private.has_permission('users.directory_read')
    or private.has_permission('users.directory_manage')
    or private.has_permission('applications.manage')
    or private.has_permission('interviews.manage')
    or private.has_permission('interviews.participants')
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query
  select u.app_user_id, u.email::text, u.full_name, u.job_title, u.unit_id
  from public.app_users u
  where u.is_active = true
  order by lower(u.full_name), u.app_user_id;
end;
$$;

revoke all on function public.get_current_internal_session() from public, anon;
revoke all on function public.list_internal_user_directory(boolean) from public, anon;
revoke all on function public.list_internal_user_selector() from public, anon;
grant execute on function public.get_current_internal_session() to authenticated, postgres, service_role;
grant execute on function public.list_internal_user_directory(boolean) to authenticated, postgres, service_role;
grant execute on function public.list_internal_user_selector() to authenticated, postgres, service_role;
