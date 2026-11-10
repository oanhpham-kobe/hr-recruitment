-- Narrow runtime binding for the accepted email_worker role (S07-001).
--
-- PostgREST connects as `authenticator` and switches to the role named by the
-- verified JWT `role` claim. S07-001 granted the three delivery RPCs only to
-- email_worker; this migration grants only the SET ROLE membership needed for
-- that existing capability, exactly as S07-004 did for storage_cleanup_worker.
--
-- It does NOT grant the delivery RPCs to service_role/anon/authenticated and
-- does not provision or persist any worker credential.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'email_worker') then
    raise exception 'email_worker predecessor role is required';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    raise exception 'authenticator role is required for PostgREST worker binding';
  end if;
end;
$$;

grant email_worker to authenticator;

-- Defense in depth: browser/service roles must never hold membership.
revoke email_worker from anon;
revoke email_worker from authenticated;
revoke email_worker from service_role;

comment on role email_worker is
  'NOLOGIN narrow email delivery RPC capability; PostgREST authenticator may SET ROLE only after verified worker JWT role selection';
