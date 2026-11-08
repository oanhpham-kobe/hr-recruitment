\set ON_ERROR_STOP on

begin;

-- The PostgREST authenticator may SET ROLE only because S07-004 explicitly
-- grants membership. Browser/service roles must not inherit or hold membership.
do $$
begin
  if not pg_has_role('authenticator', 'storage_cleanup_worker', 'MEMBER') then
    raise exception 'authenticator must be a member of storage_cleanup_worker';
  end if;
  if pg_has_role('anon', 'storage_cleanup_worker', 'MEMBER') then
    raise exception 'anon must not be a member of storage_cleanup_worker';
  end if;
  if pg_has_role('authenticated', 'storage_cleanup_worker', 'MEMBER') then
    raise exception 'authenticated must not be a member of storage_cleanup_worker';
  end if;
  if pg_has_role('service_role', 'storage_cleanup_worker', 'MEMBER') then
    raise exception 'service_role must not be a member of storage_cleanup_worker';
  end if;
end;
$$;

-- S07-003's narrow function ACL remains intact after the role bridge.
do $$
begin
  if not has_function_privilege(
    'storage_cleanup_worker',
    'public.claim_storage_cleanup_jobs(text,integer,integer)',
    'EXECUTE'
  ) then
    raise exception 'storage_cleanup_worker must retain cleanup RPC execute';
  end if;

  if has_function_privilege(
    'service_role',
    'public.claim_storage_cleanup_jobs(text,integer,integer)',
    'EXECUTE'
  ) then
    raise exception 'service_role must remain denied cleanup RPC execute';
  end if;
  if has_function_privilege(
    'anon',
    'public.claim_storage_cleanup_jobs(text,integer,integer)',
    'EXECUTE'
  ) then
    raise exception 'anon must remain denied cleanup RPC execute';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.claim_storage_cleanup_jobs(text,integer,integer)',
    'EXECUTE'
  ) then
    raise exception 'authenticated must remain denied cleanup RPC execute';
  end if;
end;
$$;

-- Prove both intended local/admin role assumption and PostgREST's role-switch
-- prerequisite without calling a destructive RPC.
set local role storage_cleanup_worker;
do $$
begin
  if current_user <> 'storage_cleanup_worker' then
    raise exception 'local postgres session could not SET ROLE storage_cleanup_worker';
  end if;
end;
$$;
reset role;

do $$
begin
  if current_user <> session_user then
    raise exception 'RESET ROLE must restore base session authority';
  end if;
end;
$$;

set local role authenticator;
set local role storage_cleanup_worker;
do $$
begin
  if current_user <> 'storage_cleanup_worker' then
    raise exception 'authenticator could not SET ROLE storage_cleanup_worker';
  end if;
end;
$$;
reset role;

rollback;

select 'PASS: storage cleanup worker runtime binding assertions succeeded.' as result;
