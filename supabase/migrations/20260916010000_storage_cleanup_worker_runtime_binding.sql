-- TASK-S07-004: narrow runtime binding for the accepted storage_cleanup_worker role.
--
-- PostgREST connects as `authenticator` and switches to the role named by the
-- verified JWT `role` claim. S07-003 intentionally granted cleanup RPC EXECUTE
-- only to storage_cleanup_worker; this migration grants only SET ROLE
-- membership needed for that existing narrow capability.
--
-- This does NOT grant cleanup RPCs back to service_role/anon/authenticated and
-- does not provision or persist any worker credential.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'storage_cleanup_worker') then
    raise exception 'storage_cleanup_worker predecessor role is required';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    raise exception 'authenticator role is required for PostgREST worker binding';
  end if;
end;
$$;

grant storage_cleanup_worker to authenticator;

-- Defense in depth: browser/service roles must never receive membership in the
-- cleanup worker role. Their direct function EXECUTE revokes from S07-003 remain
-- authoritative as well.
revoke storage_cleanup_worker from anon;
revoke storage_cleanup_worker from authenticated;
revoke storage_cleanup_worker from service_role;

comment on role storage_cleanup_worker is
  'NOLOGIN narrow storage cleanup RPC capability; S07-004 permits PostgREST authenticator to SET ROLE only after verified worker JWT role selection';
