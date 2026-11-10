\set ON_ERROR_STOP on

begin;

-- The PostgREST authenticator may SET ROLE only through explicit membership.
-- Browser/service roles must not inherit or hold it.
do $$
declare v_role text; v_fn text;
begin
  if not pg_has_role('authenticator', 'email_worker', 'MEMBER') then
    raise exception 'authenticator must be a member of email_worker';
  end if;
  foreach v_role in array array['anon','authenticated','service_role'] loop
    if pg_has_role(v_role, 'email_worker', 'MEMBER') then
      raise exception '% must not be a member of email_worker', v_role;
    end if;
  end loop;

  -- S07-001's narrow function ACL is intact after the role bridge.
  foreach v_fn in array array[
    'public.claim_email_outbox(text,integer)',
    'public.authorize_email_send(uuid,uuid,text)',
    'public.complete_email_attempt(uuid,uuid,text,text,text,text)'
  ] loop
    if not has_function_privilege('email_worker', v_fn, 'EXECUTE') then
      raise exception 'email_worker must retain execute on %', v_fn;
    end if;
    foreach v_role in array array['anon','authenticated','service_role'] loop
      if has_function_privilege(v_role, v_fn, 'EXECUTE') then
        raise exception '% must remain denied execute on %', v_role, v_fn;
      end if;
    end loop;
  end loop;
end;
$$;

-- PostgREST's role-switch prerequisite, then a real call as the worker.
-- Delivery is paused by default, so the claim returns an empty batch.
set local role authenticator;
set local role email_worker;
do $$
declare v_result jsonb;
begin
  if current_user <> 'email_worker' then
    raise exception 'authenticator could not SET ROLE email_worker';
  end if;
  v_result := public.claim_email_outbox('binding-test', 1);
  if v_result is distinct from jsonb_build_object('success', true, 'data', '[]'::jsonb) then
    raise exception 'unexpected claim result as email_worker: %', v_result;
  end if;
end;
$$;
reset role;

rollback;

select 'PASS: email worker runtime binding assertions succeeded.' as result;
