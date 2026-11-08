-- CR-DRIVE-FILES-HOSTED-20261105 / AC-DRIVE-06.
-- Exact existing claim bodies retained below, with provider filtering added
-- before every SKIP LOCKED / LIMIT selector, including cleanup exhaustion.
-- A bound alias is permanently Drive; absent binding is legacy Supabase.


create function private.claim_document_scan_requests_for_provider(p_worker_id text,p_limit integer,p_lease_seconds integer,p_is_drive boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_r public.document_scan_requests%rowtype; v_attempt uuid; v_token uuid; v_now timestamptz:=clock_timestamp(); v_items jsonb:='[]'::jsonb;
begin
 if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$' or p_limit not between 1 and 100 or p_lease_seconds not between 30 and 3600 then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
 for v_r in select * from public.document_scan_requests q
   where exists(select 1 from private.storage_object_locations l where l.bucket_name=q.bucket_name and l.object_path=q.object_path) = p_is_drive
     and ((status_code='PENDING' and next_attempt_at<=v_now) or (status_code='ERROR' and attempt_no<3 and next_attempt_at<=v_now) or (status_code='PROCESSING' and leased_until<=v_now and attempt_no<3))
   order by next_attempt_at,document_scan_request_id for update skip locked limit p_limit loop
   if not exists(select 1 from public.upload_reservations r join public.candidate_form_sessions s on s.candidate_form_session_id=r.candidate_form_session_id where r.upload_reservation_id=v_r.upload_reservation_id and r.status_code='UPLOADED' and r.malware_scan_status='PENDING' and r.expires_at>v_now and s.status_code='OPEN' and s.expires_at>v_now) then
     update public.document_scan_requests set status_code='CANCELLED',leased_until=null,updated_at=v_now where document_scan_request_id=v_r.document_scan_request_id;
     continue;
   end if;
   v_attempt:=gen_random_uuid(); v_token:=gen_random_uuid();
   update public.document_scan_requests set status_code='PROCESSING',attempt_no=attempt_no+1,current_attempt_id=v_attempt,current_fencing_token=v_token,leased_until=v_now+(p_lease_seconds||' seconds')::interval,updated_at=v_now where document_scan_request_id=v_r.document_scan_request_id returning * into v_r;
   insert into private.document_scan_attempts(document_scan_attempt_id,document_scan_request_id,attempt_no,worker_id,fencing_token,claimed_at,leased_until)
   values(v_attempt,v_r.document_scan_request_id,v_r.attempt_no,p_worker_id,v_token,v_now,v_r.leased_until);
   perform private.document_scan_audit('DOCUMENT_SCAN_CLAIMED',v_r.document_scan_request_id,'SUCCESS');
   v_items:=v_items||jsonb_build_array(jsonb_build_object('document_scan_request_id',v_r.document_scan_request_id,'upload_reservation_id',v_r.upload_reservation_id,'attempt_id',v_attempt,'fencing_token',v_token,'leased_until',v_r.leased_until));
 end loop;
 return jsonb_build_object('success',true,'data',v_items);
end;
$$;

create function private.claim_storage_cleanup_jobs_for_provider(p_worker_id text,p_limit integer,p_lease_seconds integer,p_is_drive boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q public.storage_cleanup_queue%rowtype;
  v_now timestamptz := clock_timestamp();
  v_attempt uuid;
  v_token uuid;
  v_items jsonb := '[]'::jsonb;
  v_code text;
begin
  if p_worker_id is null
    or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$'
    or p_limit is null or p_limit not between 1 and 100
    or p_lease_seconds is null or p_lease_seconds not between 30 and 3600 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  for v_q in
    select *
    from public.storage_cleanup_queue q
    where exists(select 1 from private.storage_object_locations l where l.bucket_name=q.bucket_name and l.object_path=q.object_path) = p_is_drive
      and attempts >= 5
      and (status_code = 'PENDING' or (status_code = 'PROCESSING' and leased_until <= v_now))
    order by storage_cleanup_id
    for update skip locked
    limit p_limit
  loop
    update public.storage_cleanup_queue
    set status_code = 'ERROR',
        eligibility_code = 'ATTEMPT_EXHAUSTED',
        leased_until = null,
        updated_at = v_now
    where storage_cleanup_id = v_q.storage_cleanup_id;
    perform private.storage_cleanup_audit(
      'STORAGE_CLEANUP_LEASE_EXHAUSTED',
      v_q.storage_cleanup_id,
      'FAILED',
      jsonb_build_object('attempt_count', v_q.attempts)
    );
  end loop;

  for v_q in
    select *
    from public.storage_cleanup_queue q
    where exists(select 1 from private.storage_object_locations l where l.bucket_name=q.bucket_name and l.object_path=q.object_path) = p_is_drive
      and (
      (status_code = 'PENDING' and not_before <= v_now and attempts < 5)
      or (status_code = 'PROCESSING' and leased_until <= v_now and attempts < 5)
    )
    order by not_before, storage_cleanup_id
    for update skip locked
    limit p_limit
  loop
    v_now := clock_timestamp();
    v_code := private.storage_cleanup_eligibility(v_q, v_now);
    if v_code = 'ELIGIBLE' then
      v_attempt := gen_random_uuid();
      v_token := gen_random_uuid();
      update public.storage_cleanup_queue
      set status_code = 'PROCESSING',
          worker_id = p_worker_id,
          attempt_id = v_attempt,
          fencing_token = v_token,
          attempts = attempts + 1,
          leased_until = v_now + (p_lease_seconds || ' seconds')::interval,
          eligibility_code = 'ELIGIBLE',
          authorized_at = null,
          updated_at = v_now
      where storage_cleanup_id = v_q.storage_cleanup_id
      returning * into v_q;
      perform private.storage_cleanup_audit(
        'STORAGE_CLEANUP_CLAIMED',
        v_q.storage_cleanup_id,
        'SUCCESS',
        jsonb_build_object('worker_id', p_worker_id, 'attempt_id', v_attempt, 'attempt_count', v_q.attempts)
      );
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'storage_cleanup_id', v_q.storage_cleanup_id,
        'source_type', v_q.source_type,
        'bucket_name', v_q.bucket_name,
        'object_path', v_q.object_path,
        'reason_code', v_q.reason_code,
        'attempts', v_q.attempts,
        'not_before', v_q.not_before,
        'attempt_id', v_q.attempt_id,
        'fencing_token', v_q.fencing_token,
        'leased_until', v_q.leased_until
      ));
    elsif v_code in ('SIGNED_WINDOW', 'LIVE_RESERVATION') then
      update public.storage_cleanup_queue
      set status_code = 'PENDING',
          leased_until = null,
          authorized_at = null,
          eligibility_code = v_code,
          not_before = private.storage_cleanup_defer_until(v_q, v_now),
          updated_at = v_now
      where storage_cleanup_id = v_q.storage_cleanup_id;
      perform private.storage_cleanup_audit(
        'STORAGE_CLEANUP_DEFERRED',
        v_q.storage_cleanup_id,
        'DENIED',
        jsonb_build_object('eligibility_code', v_code)
      );
    else
      update public.storage_cleanup_queue
      set status_code = 'ERROR',
          leased_until = null,
          authorized_at = null,
          eligibility_code = v_code,
          updated_at = v_now
      where storage_cleanup_id = v_q.storage_cleanup_id;
      perform private.storage_cleanup_audit(
        'STORAGE_CLEANUP_WITHHELD',
        v_q.storage_cleanup_id,
        'DENIED',
        jsonb_build_object('eligibility_code', v_code)
      );
    end if;
  end loop;

  return jsonb_build_object('success', true, 'data', v_items);
end;
$$;

create or replace function public.claim_document_scan_requests(p_worker_id text,p_limit integer default 10,p_lease_seconds integer default 300)
returns jsonb language sql security definer set search_path = '' as $$
  select private.claim_document_scan_requests_for_provider(p_worker_id,p_limit,p_lease_seconds,false);
$$;

create function public.claim_drive_document_scan_requests(p_worker_id text,p_limit integer default 10,p_lease_seconds integer default 300)
returns jsonb language sql security definer set search_path = '' as $$
  select private.claim_document_scan_requests_for_provider(p_worker_id,p_limit,p_lease_seconds,true);
$$;

create or replace function public.claim_storage_cleanup_jobs(p_worker_id text,p_limit integer default 10,p_lease_seconds integer default 300)
returns jsonb language sql security definer set search_path = '' as $$
  select private.claim_storage_cleanup_jobs_for_provider(p_worker_id,p_limit,p_lease_seconds,false);
$$;

create function public.claim_drive_storage_cleanup_jobs(p_worker_id text,p_limit integer default 10,p_lease_seconds integer default 300)
returns jsonb language sql security definer set search_path = '' as $$
  select private.claim_storage_cleanup_jobs_for_provider(p_worker_id,p_limit,p_lease_seconds,true);
$$;

revoke all on function private.claim_document_scan_requests_for_provider(text,integer,integer,boolean),
  private.claim_storage_cleanup_jobs_for_provider(text,integer,integer,boolean)
  from public,anon,authenticated,service_role,document_scan_worker,storage_cleanup_worker;
revoke all on function public.claim_drive_document_scan_requests(text,integer,integer),
  public.claim_drive_storage_cleanup_jobs(text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.claim_drive_document_scan_requests(text,integer,integer) to document_scan_worker,postgres;
grant execute on function public.claim_drive_storage_cleanup_jobs(text,integer,integer) to storage_cleanup_worker,postgres;
-- CREATE OR REPLACE preserves the legacy wrappers' existing caller grants.
