\set ON_ERROR_STOP on
begin;
create function pg_temp.expect_error(p_sql text,p_error text) returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if sqlerrm = p_error or sqlstate = p_error then return; end if;
    raise;
  end;
  raise exception 'Expected error %, command succeeded',p_error;
end $$;

do $$
declare
  c uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); s uuid:=gen_random_uuid();
  r uuid:=gen_random_uuid(); r2 uuid:=gen_random_uuid(); t uuid:=gen_random_uuid();
  notice text:='drive-'||gen_random_uuid(); path text; token uuid; claim jsonb; result jsonb;
  sub uuid:=gen_random_uuid(); logical uuid:=gen_random_uuid(); q uuid:=gen_random_uuid();
  scan uuid; scan_attempt uuid; scan_token uuid; doc uuid; internal_id uuid:=gen_random_uuid(); internal_auth uuid:=gen_random_uuid();
  role_name text;
begin
  path:='temp/'||s||'/'||r||'/cv.pdf';
  insert into public.candidates(candidate_id,auth_user_id,email,is_active) values(c,a,c||'@example.invalid',true);
  insert into public.privacy_notice_versions(notice_version,content_vi,content_hash_sha256,is_current)
    values(notice,'Drive test',repeat('a',64),false);
  insert into public.document_types(document_type_id,code,name_vi,scope_code) values(t,'DRIVE-'||left(t::text,8),'Drive','SUBMISSION');
  insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,presented_privacy_notice_version,expires_at)
    values(s,c,'NEW_SUBMISSION',notice,clock_timestamp()+interval '1 hour');
  insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,
    temp_bucket,temp_path,original_filename,declared_mime_type,actor_auth_user_id,idempotency_key,expires_at)
    values(r,s,t,'candidate-quarantine',path,'cv.pdf','application/pdf',a,gen_random_uuid(),clock_timestamp()+interval '1 hour'),
    (r2,s,t,'candidate-quarantine','temp/'||s||'/'||r2||'/cv.pdf','cv.pdf','application/pdf',a,gen_random_uuid(),clock_timestamp()+interval '1 hour');
  foreach role_name in array array['anon','authenticated','service_role'] loop
    execute 'set local role '||quote_ident(role_name);
    perform pg_temp.expect_error(format('select public.bind_candidate_drive_object(%L,%L,%L)',r,a,'drive_file_00001'),'42501');
    perform pg_temp.expect_error(format('select public.claim_drive_upload_attempt(%L,%L,''test'',120)',r,a),'42501');
    perform pg_temp.expect_error(format('select public.seal_drive_upload_attempt(%L,%L,''test'',%L,10,''application/pdf'',%L,true)',r,a,gen_random_uuid(),repeat('a',64)),'42501');
    perform pg_temp.expect_error('select * from private.storage_object_locations','42501');
    perform pg_temp.expect_error('select public.resolve_drive_object_location(''candidate-quarantine'',''x'')','42501');
    perform pg_temp.expect_error(format('select public.resolve_drive_scan_attempt(%L,%L,%L,''test'')',r,r,r),'42501');
    perform pg_temp.expect_error(format('select public.authorize_drive_document_read(%L,%L,%L,%L,''download'')',a,sub,logical,r),'42501');
    execute 'reset role';
  end loop;
  execute 'set local role drive_storage_worker';
  perform pg_temp.expect_error(format('select public.bind_candidate_drive_object(%L,%L,%L)',r,gen_random_uuid(),'drive_file_00001'),'FORBIDDEN');
  result:=public.bind_candidate_drive_object(r,a,'drive_file_00001');
  assert result->>'replay'='false';
  result:=public.bind_candidate_drive_object(r,a,'drive_file_00001');
  assert result->>'replay'='true';
  execute 'reset role';
  assert (select count(*)=1 from public.security_audit_log where entity_id=r and action_code='DRIVE_OBJECT_BOUND' and actor_auth_user_id=a);
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a)::text,true);
  execute 'set local role authenticated';
  perform pg_temp.expect_error(format('select public.prepare_signed_upload(%L)',r),'STORAGE_PROVIDER_CONFLICT');
  execute 'reset role';
  execute 'set local role drive_storage_worker';
  perform pg_temp.expect_error(format('select public.bind_candidate_drive_object(%L,%L,%L)',r,a,'drive_file_00002'),'IDEMPOTENCY_CONFLICT');
  claim:=public.claim_drive_upload_attempt(r,a,'drive-test',120);
  token:=(claim->>'fencing_token')::uuid;
  perform pg_temp.expect_error(format('select public.seal_drive_upload_attempt(%L,%L,''drive-test'',%L,10,''image/png'',%L,true)',r,a,token,repeat('a',64)),'INSPECTION_REJECTED');
  perform pg_temp.expect_error(format('select public.seal_drive_upload_attempt(%L,%L,''drive-test'',%L,5242881,''application/pdf'',%L,true)',r,a,token,repeat('a',64)),'INSPECTION_REJECTED');
  perform pg_temp.expect_error(format('select public.claim_drive_upload_attempt(%L,%L,''other'',120)',r,a),'UPLOAD_BUSY');
  perform pg_temp.expect_error(format('select public.seal_drive_upload_attempt(%L,%L,''drive-test'',%L,10,''application/pdf'',%L,true)',r,a,gen_random_uuid(),repeat('a',64)),'STALE_ATTEMPT');
  execute 'reset role';
  update private.storage_object_locations set leased_until=clock_timestamp()-interval '1 second' where upload_reservation_id=r;
  execute 'set local role drive_storage_worker';
  perform pg_temp.expect_error(format('select public.seal_drive_upload_attempt(%L,%L,''drive-test'',%L,10,''application/pdf'',%L,true)',r,a,token,repeat('a',64)),'STALE_ATTEMPT');
  claim:=public.claim_drive_upload_attempt(r,a,'drive-test',120);
  token:=(claim->>'fencing_token')::uuid;
  result:=public.seal_drive_upload_attempt(r,a,'drive-test',token,10,'application/pdf',repeat('a',64),true);
  assert result->>'malware_scan_status'='PENDING';
  assert public.seal_drive_upload_attempt(r,a,'drive-test',token,10,'application/pdf',repeat('a',64),true)->>'replay'='true';
  perform pg_temp.expect_error(format('select public.seal_drive_upload_attempt(%L,%L,''drive-test'',%L,11,''application/pdf'',%L,true)',r,a,token,repeat('a',64)),'FINGERPRINT_MISMATCH');
  perform pg_temp.expect_error(format('select public.claim_drive_upload_attempt(%L,%L,''drive-test'',120)',r,a),'ALREADY_SEALED');
  assert public.resolve_drive_object_location('candidate-quarantine',path)->>'provider_file_id'='drive_file_00001';
  execute 'reset role';
  assert (select status_code='UPLOADED' and malware_scan_status='PENDING' from public.upload_reservations where upload_reservation_id=r);
  assert not exists(select 1 from public.security_audit_log where entity_id=r and action_code like 'DRIVE_%' and actor_auth_user_id is distinct from a);
  perform pg_temp.expect_error(format('update private.storage_object_locations set provider_file_id=''drive_file_00002'' where upload_reservation_id=%L',r),'DRIVE_IDENTITY_IMMUTABLE');
  execute 'set local role authenticated';
  result:=public.request_candidate_document_scan(s,r,'ADD',null);
  assert result->>'success'='true';
  scan:=(result->'data'->>'document_scan_request_id')::uuid;
  execute 'reset role';
  execute 'set local role document_scan_worker';
  result:=public.claim_drive_document_scan_requests('drive-scan-test',100,60);
  select value->>'attempt_id',value->>'fencing_token' into scan_attempt,scan_token
    from jsonb_array_elements(result->'data') where value->>'document_scan_request_id'=scan::text;
  assert scan_attempt is not null;
  assert public.resolve_drive_scan_attempt(scan,scan_attempt,scan_token,'drive-scan-test')->>'provider_file_id'='drive_file_00001';
  perform pg_temp.expect_error(format('select public.resolve_drive_scan_attempt(%L,%L,%L,''wrong-worker'')',scan,scan_attempt,scan_token),'STALE_SCAN_CONTEXT');
  perform pg_temp.expect_error(format('select public.resolve_drive_scan_attempt(%L,%L,%L,''drive-scan-test'')',scan,scan_attempt,gen_random_uuid()),'STALE_SCAN_CONTEXT');
  -- Simulated trusted scanner result in a rolled-back disposable fixture only.
  assert public.complete_document_scan_attempt(scan,scan_attempt,scan_token,'drive-scan-test','CLEAN',null)->>'success'='true';
  perform pg_temp.expect_error(format('select public.resolve_drive_scan_attempt(%L,%L,%L,''drive-scan-test'')',scan,scan_attempt,scan_token),'STALE_SCAN_CONTEXT');
  execute 'reset role';
  insert into storage.buckets(id,name,public) values('candidate-quarantine','candidate-quarantine',false) on conflict do nothing;
  execute 'set local role service_role';
  perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(''candidate-quarantine'',%L)',path),'STORAGE_PROVIDER_CONFLICT');
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a)::text,true);
  execute 'set local role authenticated';
  result:=public.prepare_signed_upload(r2);
  assert result->>'success'='true';
  execute 'reset role';
  execute 'set local role drive_storage_worker';
  perform pg_temp.expect_error(format('select public.bind_candidate_drive_object(%L,%L,%L)',r2,a,'drive_file_00003'),'STORAGE_PROVIDER_CONFLICT');
  execute 'reset role';
  -- A retained historical version protects the Drive object after reservation removal.
  insert into public.submissions(submission_id,candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot)
    values(sub,c,'Drive',date '2000-01-01','FEMALE','test','0000000000',c||'@example.invalid');
  insert into public.submission_document_logicals(logical_document_id,submission_id,document_type_id,created_by_candidate_id)
    values(logical,sub,t,c);
  insert into public.submission_documents(logical_document_id,storage_bucket,storage_path,original_filename,mime_type,file_size_bytes,checksum_sha256,version_no,is_current,uploaded_by_candidate_id)
    values(logical,'candidate-quarantine',path,'cv.pdf','application/pdf',10,repeat('a',64),1,false,c) returning document_id into doc;
  insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active)
    values(internal_id,internal_auth,internal_id||'@eiu.edu.vn','Drive Reader',true);
  insert into public.app_user_roles(app_user_id,role_code) values(internal_id,'HR');
  insert into public.app_user_permissions(app_user_id,permission_code) values(internal_id,'submissions.view');
  execute 'set local role drive_storage_worker';
  assert public.authorize_drive_document_read(internal_auth,sub,logical,doc,'preview')->>'provider_file_id'='drive_file_00001';
  assert public.authorize_drive_document_read(internal_auth,sub,logical,doc,'download')->>'purpose'='download';
  perform pg_temp.expect_error(format('select public.authorize_drive_document_read(%L,%L,%L,%L,''download'')',a,sub,logical,doc),'FORBIDDEN');
  perform pg_temp.expect_error(format('select public.authorize_drive_document_read(%L,%L,%L,%L,''download'')',internal_auth,gen_random_uuid(),logical,doc),'NOT_FOUND');
  execute 'reset role';
  assert (select count(*)=2 from public.security_audit_log where entity_id=doc and action_code='DOCUMENT_ACCESS'
    and actor_auth_user_id=internal_auth and actor_app_user_id=internal_id and metadata->>'purpose' in ('preview','download'));
  update public.app_users set is_active=false where app_user_id=internal_id;
  execute 'set local role drive_storage_worker';
  perform pg_temp.expect_error(format('select public.authorize_drive_document_read(%L,%L,%L,%L,''download'')',internal_auth,sub,logical,doc),'FORBIDDEN');
  execute 'reset role';
  update public.app_users set is_active=true where app_user_id=internal_id;
  delete from public.app_user_permissions where app_user_id=internal_id and permission_code='submissions.view';
  execute 'set local role drive_storage_worker';
  perform pg_temp.expect_error(format('select public.authorize_drive_document_read(%L,%L,%L,%L,''download'')',internal_auth,sub,logical,doc),'FORBIDDEN');
  execute 'reset role';
  update public.upload_reservations set status_code='CANCELLED' where upload_reservation_id=r;
  delete from public.upload_reservations where upload_reservation_id=r;
  assert exists(select 1 from private.storage_object_locations where upload_reservation_id=r);
  -- Advance only this disposable fixture's provenance horizon, not runtime rules.
  update private.storage_cleanup_provenance set reservation_expires_at=clock_timestamp()-interval '1 hour',
    signed_upload_expires_at=clock_timestamp()-interval '1 hour' where bucket_name='candidate-quarantine' and object_path=path;
  insert into public.storage_cleanup_queue(storage_cleanup_id,source_type,source_parent_id,source_upload_reservation_id,bucket_name,object_path,reason_code,not_before)
    values(q,'CANDIDATE_FORM',s,r,'candidate-quarantine',path,'RESERVATION_EXPIRED',clock_timestamp()-interval '1 hour');
  assert (select private.storage_cleanup_eligibility(x,clock_timestamp())='RETAINED_REFERENCE' from public.storage_cleanup_queue x where storage_cleanup_id=q);
  execute 'set local role storage_cleanup_worker';
  perform public.claim_drive_storage_cleanup_jobs('retained-drive-test',100,60);
  result:=public.resolve_drive_cleanup_location(q,gen_random_uuid(),gen_random_uuid(),'test');
  assert result->>'success'='false';
  execute 'reset role';
  assert (select eligibility_code='RETAINED_REFERENCE' from public.storage_cleanup_queue where storage_cleanup_id=q);
end $$;
rollback;
\echo Drive actual-role/location tests passed
