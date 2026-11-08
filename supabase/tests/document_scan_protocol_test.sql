\set ON_ERROR_STOP on
begin;

do $$
declare
  v_candidate uuid:=gen_random_uuid();
  v_auth uuid:=gen_random_uuid();
  v_session uuid:=gen_random_uuid();
  v_reservation uuid:=gen_random_uuid();
  v_doc_type uuid;
  v_request uuid;
  v_notice text:='s07-scan-'||replace(gen_random_uuid()::text,'-','');
  v_claim jsonb;
  v_result jsonb;
  v_attempt uuid;
  v_token uuid;
  v_change uuid;
  v_infected uuid:=gen_random_uuid();
  v_expired uuid:=gen_random_uuid();
  v_other_path uuid:=gen_random_uuid();
begin
  select document_type_id into v_doc_type from public.document_types where code='CV_RESUME' limit 1;
  if v_doc_type is null then
    insert into public.document_types(code,name_vi,name_en,scope_code,is_active)
    values('CV_RESUME','S07 scan CV','S07 scan CV','SUBMISSION',true)
    on conflict(code) do update set is_active=true returning document_type_id into v_doc_type;
  end if;
  insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active)
  values(v_candidate,v_auth,'scan-'||v_candidate||'@example.invalid','Scan Candidate',true);
  insert into public.privacy_notice_versions(notice_version,content_vi,content_en,content_hash_sha256,published_at,effective_from,is_current)
  values(v_notice,'S07 scan test notice','S07 scan test notice',repeat('e',64),clock_timestamp(),clock_timestamp(),false);
  insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,status_code,presented_privacy_notice_version,expires_at)
  values(v_session,v_candidate,'NEW_SUBMISSION','OPEN',v_notice,clock_timestamp()+interval '1 hour');
  insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,declared_mime_type,expected_max_size_bytes,actor_auth_user_id,idempotency_key,expires_at)
  values(v_reservation,v_session,v_doc_type,'candidate-quarantine','scan/'||v_reservation||'.pdf','cv.pdf','application/pdf',5242880,v_auth,gen_random_uuid(),clock_timestamp()+interval '1 hour');

  -- Browser roles cannot write inspection data or invoke worker methods.
  perform set_config('request.jwt.claim.sub',v_auth::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_auth)::text,true);
  execute 'set local role authenticated';
  begin perform public.record_inspected_upload_reservation(v_reservation,10,'application/pdf',repeat('a',64),true); raise exception 'browser inspection unexpectedly permitted';
  exception when insufficient_privilege then null; end;
  begin perform public.claim_document_scan_requests('forged',1,60); raise exception 'browser claim unexpectedly permitted';
  exception when insufficient_privilege then null; end;
  begin perform private.document_scan_audit('FORGED',gen_random_uuid(),'SUCCESS'); raise exception 'browser audit unexpectedly permitted';
  exception when insufficient_privilege then null; end;
  execute 'reset role';

  -- Trusted inspection contributes object evidence but never a CLEAN verdict.
  v_result:=public.record_inspected_upload_reservation(v_reservation,10,'application/pdf',repeat('a',64),true);
  assert (v_result->>'success')::boolean, 'trusted inspection succeeds';
  assert (select status_code='UPLOADED' and malware_scan_status='PENDING' from public.upload_reservations where upload_reservation_id=v_reservation), 'inspection leaves pending scan';

  execute 'set local role authenticated';
  assert (public.authorize_candidate_upload_scan(v_session,v_reservation)->>'success')::boolean, 'candidate retry authorization permits immutable inspected upload';
  v_result:=public.request_candidate_document_scan(v_session,v_reservation,'ADD',null);
  assert (v_result->>'success')::boolean and v_result->'data'->>'kind'='PENDING_SCAN', 'request is pending, not staged';
  v_request:=(v_result->'data'->>'document_scan_request_id')::uuid;
  assert not exists(select 1 from public.candidate_form_document_changes where upload_reservation_id=v_reservation), 'pending scan has no staged change';
  assert public.request_candidate_document_scan(v_session,v_reservation,'ADD',null)=v_result, 'same request replays';
  execute 'reset role';

  v_claim:=public.claim_document_scan_requests('scan-worker',1,60);
  assert jsonb_array_length(v_claim->'data')=1, 'one worker claim';
  v_attempt:=(v_claim->'data'->0->>'attempt_id')::uuid;
  v_token:=(v_claim->'data'->0->>'fencing_token')::uuid;
  assert public.complete_document_scan_attempt(v_request,v_attempt,v_token,'scan-worker','CLEAN',null)->>'success'='true', 'current worker may persist CLEAN';
  assert public.complete_document_scan_attempt(v_request,v_attempt,v_token,'scan-worker','CLEAN',null)->>'error_code'='STALE_ATTEMPT', 'repeat completion is fenced';

  execute 'set local role authenticated';
  v_result:=public.continue_clean_candidate_document_scan(v_session,v_reservation);
  assert (v_result->>'success')::boolean and v_result->'data'->>'kind'='STAGED', 'clean continuation stages once';
  v_change:=(v_result->'data'->>'change_id')::uuid;
  assert public.continue_clean_candidate_document_scan(v_session,v_reservation)=v_result, 'repeat continuation replays one staged change';
  assert (select count(*)=1 from public.candidate_form_document_changes where candidate_form_document_change_id=v_change), 'one staged change retained';
  execute 'reset role';

  -- Terminal infected results fence staging and retain deferred cleanup intent.
  insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,declared_mime_type,expected_max_size_bytes,actual_size_bytes,detected_mime_type,checksum_sha256,status_code,malware_scan_status,actor_auth_user_id,idempotency_key,expires_at)
  values(v_infected,v_session,v_doc_type,'candidate-quarantine','scan/'||v_infected||'.pdf','infected.pdf','application/pdf',5242880,10,'application/pdf',repeat('c',64),'UPLOADED','PENDING',v_auth,gen_random_uuid(),clock_timestamp()+interval '1 hour');
  execute 'set local role authenticated';
  v_result:=public.request_candidate_document_scan(v_session,v_infected,'ADD',null);
  v_request:=(v_result->'data'->>'document_scan_request_id')::uuid;
  execute 'reset role';
  v_claim:=public.claim_document_scan_requests('scan-worker',1,60);
  v_attempt:=(v_claim->'data'->0->>'attempt_id')::uuid;
  v_token:=(v_claim->'data'->0->>'fencing_token')::uuid;
  assert public.complete_document_scan_attempt(v_request,v_attempt,v_token,'scan-worker','INFECTED',null)->>'success'='true', 'infected result is terminal';
  assert exists(select 1 from public.storage_cleanup_queue where source_upload_reservation_id=v_infected and reason_code='MALWARE_REJECTED'), 'infected result enqueues deferred cleanup';
  execute 'set local role authenticated';
  assert public.continue_clean_candidate_document_scan(v_session,v_infected)->>'error_code'='SCAN_REJECTED', 'infected request cannot be staged';
  execute 'reset role';

  -- An exhausted final lease becomes a terminal error through ordered candidate continuation.
  insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,declared_mime_type,expected_max_size_bytes,actual_size_bytes,detected_mime_type,checksum_sha256,status_code,malware_scan_status,actor_auth_user_id,idempotency_key,expires_at)
  values(v_expired,v_session,v_doc_type,'candidate-quarantine','scan/'||v_expired||'.pdf','expired.pdf','application/pdf',5242880,10,'application/pdf',repeat('d',64),'UPLOADED','PENDING',v_auth,gen_random_uuid(),clock_timestamp()+interval '1 hour');
  execute 'set local role authenticated';
  v_result:=public.request_candidate_document_scan(v_session,v_expired,'ADD',null);
  v_request:=(v_result->'data'->>'document_scan_request_id')::uuid;
  execute 'reset role';
  update public.document_scan_requests set status_code='PROCESSING',attempt_no=3,leased_until=clock_timestamp()-interval '1 second' where document_scan_request_id=v_request;
  execute 'set local role authenticated';
  assert public.continue_clean_candidate_document_scan(v_session,v_expired)->>'error_code'='SCAN_FAILED', 'expired final lease is terminal';
  execute 'reset role';
  assert exists(select 1 from public.storage_cleanup_queue where source_upload_reservation_id=v_expired and reason_code='MALWARE_REJECTED'), 'expired final lease enqueues deferred cleanup';

  -- Cancellation fences a request before a late worker can write a result.
  insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,declared_mime_type,expected_max_size_bytes,actual_size_bytes,detected_mime_type,checksum_sha256,status_code,malware_scan_status,actor_auth_user_id,idempotency_key,expires_at)
  values(v_other_path,v_session,v_doc_type,'candidate-quarantine','scan/'||v_other_path||'.pdf','other.pdf','application/pdf',5242880,10,'application/pdf',repeat('b',64),'UPLOADED','PENDING',v_auth,gen_random_uuid(),clock_timestamp()+interval '1 hour');
  execute 'set local role authenticated';
  v_result:=public.request_candidate_document_scan(v_session,v_other_path,'ADD',null); assert (v_result->>'success')::boolean;
  execute 'reset role';
  update public.upload_reservations set status_code='CANCELLED' where upload_reservation_id=v_other_path;
  assert (select status_code='CANCELLED' from public.document_scan_requests where upload_reservation_id=v_other_path), 'reservation cancellation fences pending scan';
  assert exists(select 1 from public.security_audit_log where entity_id=v_request and action_code='DOCUMENT_SCAN_RESULT'), 'minimal result audit exists';
end $$;
rollback;
