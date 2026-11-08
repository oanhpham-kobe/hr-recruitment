\set ON_ERROR_STOP on
begin;
-- Isolate the disposable fixture, then restore all existing queues at rollback.
delete from public.document_scan_requests;
delete from public.storage_cleanup_queue;
create function pg_temp.expect_denied(p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when insufficient_privilege then return; end;
  raise exception 'Expected permission denial';
end $$;
do $$
declare c uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); t uuid:=gen_random_uuid();
  n text:='provider-'||gen_random_uuid(); r uuid; q uuid; path text; is_drive boolean;
  i integer; p integer; before_other jsonb; result jsonb; who text;
begin
  insert into public.candidates(candidate_id,auth_user_id,email,is_active) values(c,a,c||'@example.invalid',true);
  insert into public.privacy_notice_versions(notice_version,content_vi,content_hash_sha256,is_current) values(n,'Provider test',repeat('a',64),false);
  insert into public.document_types(document_type_id,code,name_vi,scope_code) values(t,'PC-'||left(t::text,8),'Provider','SUBMISSION');
  insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,presented_privacy_notice_version,expires_at)
    values(s,c,'NEW_SUBMISSION',n,clock_timestamp()+interval '1 hour');
  for p in 0..1 loop
    is_drive:=p=1;
    for i in 1..3 loop
      r:=gen_random_uuid(); q:=gen_random_uuid(); path:='temp/'||s||'/'||r||'/cv.pdf';
      insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,
        original_filename,actor_auth_user_id,idempotency_key,expires_at,status_code,malware_scan_status,actual_size_bytes,checksum_sha256,detected_mime_type)
        values(r,s,t,'candidate-quarantine',path,'cv.pdf',a,gen_random_uuid(),clock_timestamp()+interval '1 hour','UPLOADED','PENDING',10,repeat('a',64),'application/pdf');
      if is_drive then
        insert into private.storage_object_locations(bucket_name,object_path,upload_reservation_id,provider_file_id,state_code,checksum_sha256,actual_size_bytes,detected_mime_type,sealed_at)
          values('candidate-quarantine',path,r,'provider_'||r,'SEALED',repeat('a',64),10,'application/pdf',clock_timestamp());
      end if;
      insert into public.document_scan_requests(document_scan_request_id,upload_reservation_id,candidate_form_session_id,action_code,intended_document_type_id,
        bucket_name,object_path,checksum_sha256,object_fingerprint,detected_mime_type,actual_size_bytes,status_code,attempt_no,next_attempt_at,leased_until)
        select q,r,s,'ADD',t,'candidate-quarantine',path,repeat('a',64),private.document_scan_fingerprint(x,repeat('a',64),'application/pdf',10),
          'application/pdf',10,case when i=3 then 'PROCESSING' else 'PENDING' end,case when i=3 then 3 else 0 end,
          clock_timestamp()-interval '1 hour',clock_timestamp()-interval '1 hour' from public.upload_reservations x where upload_reservation_id=r;
      -- Separate detached cleanup identity; no live reservation/reference.
      r:=gen_random_uuid(); path:='temp/'||s||'/'||r||'/orphan.pdf';
      if is_drive then
        insert into private.storage_object_locations(bucket_name,object_path,upload_reservation_id,provider_file_id)
          values('candidate-quarantine',path,r,'cleanup_'||r);
      end if;
      insert into private.storage_cleanup_provenance(bucket_name,object_path,upload_reservation_id,source_type,source_parent_id,reservation_expires_at,detached_at)
        values('candidate-quarantine',path,r,'CANDIDATE_FORM',s,clock_timestamp()-interval '2 hours',clock_timestamp());
      insert into public.storage_cleanup_queue(storage_cleanup_id,source_type,source_parent_id,source_upload_reservation_id,bucket_name,object_path,reason_code,attempts,not_before)
        values(case when i=3 then ('00000000-0000-0000-0000-00000000000'||(p+1))::uuid else gen_random_uuid() end,
          'CANDIDATE_FORM',s,r,'candidate-quarantine',path,'RESERVATION_EXPIRED',case when i=3 then 5 else 0 end,clock_timestamp()-interval '1 hour');
    end loop;
  end loop;
  foreach who in array array['anon','authenticated','service_role'] loop
    execute 'set local role '||quote_ident(who);
    perform pg_temp.expect_denied('select public.claim_drive_document_scan_requests(''x'',1,60)');
    perform pg_temp.expect_denied('select public.claim_drive_storage_cleanup_jobs(''x'',1,60)');
    perform pg_temp.expect_denied('select private.claim_document_scan_requests_for_provider(''x'',1,60,true)');
    execute 'reset role';
  end loop;
  -- Put the other provider first each time: LIMIT 1 must still find our own work.
  for p in reverse 1..0 loop
    is_drive:=p=1;
    update public.document_scan_requests x set next_attempt_at=clock_timestamp()-interval '2 hours'
      where exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path) <> is_drive;
    select jsonb_agg(to_jsonb(x) order by document_scan_request_id) into before_other from public.document_scan_requests x
      where exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path) <> is_drive;
    execute 'set local role document_scan_worker';
    if is_drive then result:=public.claim_drive_document_scan_requests('drive-scan',1,60);
    else result:=public.claim_document_scan_requests('legacy-scan',1,60); end if;
    perform pg_temp.expect_denied('select private.claim_document_scan_requests_for_provider(''x'',1,60,false)');
    perform pg_temp.expect_denied('select public.claim_drive_storage_cleanup_jobs(''x'',1,60)');
    execute 'reset role';
    assert jsonb_array_length(result->'data')=1, 'scan LIMIT was starved by another provider';
    q:=(result->'data'->0->>'document_scan_request_id')::uuid;
    assert (select exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path)=is_drive from public.document_scan_requests x where document_scan_request_id=q);
    assert before_other=(select jsonb_agg(to_jsonb(x) order by document_scan_request_id) from public.document_scan_requests x
      where exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path) <> is_drive), 'other scan queue mutated';
    assert (select count(*)=2 from public.document_scan_requests where attempt_no=3 and status_code='PROCESSING'), 'scan exhaustion semantics changed';

    update public.storage_cleanup_queue x set not_before=clock_timestamp()-interval '2 hours'
      where exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path) <> is_drive;
    select jsonb_agg(to_jsonb(x) order by storage_cleanup_id) into before_other from public.storage_cleanup_queue x
      where exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path) <> is_drive;
    execute 'set local role storage_cleanup_worker';
    if is_drive then result:=public.claim_drive_storage_cleanup_jobs('drive-cleanup',1,60);
    else result:=public.claim_storage_cleanup_jobs('legacy-cleanup',1,60); end if;
    perform pg_temp.expect_denied('select private.claim_storage_cleanup_jobs_for_provider(''x'',1,60,false)');
    perform pg_temp.expect_denied('select public.claim_drive_document_scan_requests(''x'',1,60)');
    execute 'reset role';
    assert jsonb_array_length(result->'data')=1, 'cleanup LIMIT was starved by another provider';
    q:=(result->'data'->0->>'storage_cleanup_id')::uuid;
    assert (select exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path)=is_drive from public.storage_cleanup_queue x where storage_cleanup_id=q);
    assert before_other=(select jsonb_agg(to_jsonb(x) order by storage_cleanup_id) from public.storage_cleanup_queue x
      where exists(select 1 from private.storage_object_locations l where l.bucket_name=x.bucket_name and l.object_path=x.object_path) <> is_drive), 'other cleanup queue/exhaustion mutated';
    assert (select status_code='ERROR' and eligibility_code='ATTEMPT_EXHAUSTED' from public.storage_cleanup_queue
      where storage_cleanup_id=('00000000-0000-0000-0000-00000000000'||(p+1))::uuid), 'provider exhaustion was starved';
  end loop;
end $$;
rollback;
\echo Provider-partitioned actual-role mixed queues passed
