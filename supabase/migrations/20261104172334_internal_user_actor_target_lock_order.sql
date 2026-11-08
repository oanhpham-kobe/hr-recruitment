-- Internal User actor/target lock composition repair.
-- Assignment/Copy prelock the sorted actor+owner/participant union. These
-- existing-target writers previously locked only target, then acquired actor
-- KEY SHARE implicitly through security_audit_log (and granted_by on grants).
-- That inverted the union when actor < target and could deadlock at audit.
--
-- Inventory: directory update, lifecycle, HR assign/remove, permission grant/
-- revoke and identity rebind all need the union. First Google bind has actor =
-- target. Create inserts a new, transaction-private target; it does not lock an
-- existing second User. Neither needs an additional actor/target lock set.
--
-- Retain established Email -> Unit -> User ordering: the R4 directory wrapper
-- still prelocks Email/Unit before its retained implementation; identity R2
-- still prelocks replacement Email before the block replaced here. No parent
-- Application/Interview locks are introduced into Internal User commands.
--
-- Amend only the lock boundary in the effective definitions. Guards make drift
-- fail migration rather than silently replace the wrong block. CREATE OR
-- REPLACE preserves each routine's identity, grants and empty search_path.
do $migration$
declare
  v_command record;
  v_definition text;
  v_target_lock text;
  v_lock_block text := $block$  -- Include the audit/granted_by actor before taking any User advisory.
  -- Loop explicitly so row acquisition has the same ascending UUID order in
  -- every writer, including the actor = target case (one distinct row).
  for v_user_lock_id in
    select distinct q.user_id
    from unnest(array[v_actor, p_target_user_id]) q(user_id)
    where q.user_id is not null
    order by q.user_id
  loop
    perform 1 from public.app_users u
    where u.app_user_id = v_user_lock_id
    for update;
  end loop;
  perform private.lock_internal_user_ids(array[v_actor, p_target_user_id]);

$block$;
  v_recheck text;
begin
  for v_command in
    select * from (values
      ('public.update_internal_user_directory_s06_002_r2_impl(uuid,jsonb,bigint,uuid)', true, false),
      ('public.set_internal_user_active(uuid,boolean,bigint,uuid)', true, true),
      ('public.assign_hr_role_with_defaults(uuid,bigint,uuid)', false, false),
      ('public.remove_hr_role(uuid,bigint,uuid)', false, false),
      ('public.grant_hr_permission(uuid,text,bigint,uuid)', false, false),
      ('public.revoke_hr_permission(uuid,text,bigint,uuid)', false, false),
      ('public.change_internal_user_identity(uuid,uuid,bigint,uuid)', false, false)
    ) as commands(signature, directory_permission, lifecycle)
  loop
    v_definition := pg_get_functiondef(v_command.signature::regprocedure);
    v_target_lock := substring(v_definition from
      '  select \* into v_target\s+from public\.app_users u\s+where u\.app_user_id\s*=\s*p_target_user_id\s+for update;');
    if v_target_lock is null
       or position(E'  v_actor uuid;\n' in v_definition) = 0
       or position('v_user_lock_id' in v_definition) > 0 then
      raise exception 'INTERNAL_USER_ACTOR_LOCK_DEFINITION_DRIFT: %', v_command.signature;
    end if;

    v_recheck := E'  -- Authorization may have changed while waiting for the complete lock set.\n'
      || E'  if private.current_app_user_id() is distinct from v_actor\n'
      || case when v_command.directory_permission then
           E'     or not (private.is_root_admin() or private.has_permission(''users.directory_manage'')) then\n'
         else E'     or not private.is_root_admin() then\n' end
      || E'    return jsonb_build_object(''success'', false, ''error_code'', ''FORBIDDEN'');\n  end if;\n';
    if v_command.lifecycle then
      v_recheck := v_recheck || E'  v_actor_is_root := private.is_root_admin();\n';
    end if;

    v_definition := replace(v_definition, E'  v_actor uuid;\n',
      E'  v_actor uuid;\n  v_user_lock_id uuid;\n');
    v_definition := replace(v_definition, v_target_lock,
      v_lock_block || v_recheck || E'\n' || v_target_lock);
    -- The complete set above subsumes the original target-only advisory.
    v_definition := replace(v_definition,
      '  perform private.lock_internal_user_ids(array[p_target_user_id]);', '');
    execute v_definition;
  end loop;
end;
$migration$;
