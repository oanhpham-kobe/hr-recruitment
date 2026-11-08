-- TASK-S06-002 R4 repair: preserve authorization-before-contention for
-- Internal User directory updates while retaining the accepted R3 lock order
-- for authorized callers (Email -> Unit -> User).

create or replace function public.update_internal_user_directory(
  p_target_user_id uuid,
  p_patch jsonb,
  p_expected_version_no bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_email text;
  v_unit_id uuid;
begin
  -- Authorization must precede all email / Unit contention. Keep the same
  -- contract as the delegated implementation; that implementation retains its
  -- own checks as defense in depth.
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;

  v_actor := private.current_app_user_id();
  if v_actor is null
     or not (private.is_root_admin() or private.has_permission('users.directory_manage')) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;

  if p_patch is not null and jsonb_typeof(p_patch) = 'object' then
    if p_patch ? 'email' and jsonb_typeof(p_patch -> 'email') = 'string' then
      begin
        v_email := private.normalize_internal_eiu_email(p_patch ->> 'email');
      exception
        when invalid_parameter_value then
          v_email := null;
      end;
      if v_email is not null then
        perform pg_advisory_xact_lock(hashtextextended('internal-email:' || v_email, 0));
      end if;
    end if;

    if p_patch ? 'unit_id' and jsonb_typeof(p_patch -> 'unit_id') = 'string' then
      begin
        v_unit_id := nullif(btrim(p_patch ->> 'unit_id'), '')::uuid;
      exception
        when invalid_text_representation then
          v_unit_id := null;
      end;
      if v_unit_id is not null then
        perform 1
        from public.organizational_units u
        where u.unit_id = v_unit_id
          and u.is_active = true
        for key share;
      end if;
    end if;
  end if;

  return public.update_internal_user_directory_s06_002_r2_impl(
    p_target_user_id,
    p_patch,
    p_expected_version_no,
    p_idempotency_key
  );
end;
$$;

revoke all on function public.update_internal_user_directory(uuid, jsonb, bigint, uuid)
  from public, anon;
grant execute on function public.update_internal_user_directory(uuid, jsonb, bigint, uuid)
  to authenticated, postgres, service_role;
