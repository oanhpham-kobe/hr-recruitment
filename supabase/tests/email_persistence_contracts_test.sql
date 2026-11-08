\set ON_ERROR_STOP on
begin;
-- Transaction-local fixtures isolate this gate from cumulative predecessor data.
create function private.s07_fail_audit() returns trigger language plpgsql set search_path='' as $$
begin
 if new.action_code=current_setting('s07.fail_action',true) then raise exception 'S07_FORCED_AUDIT_FAILURE'; end if;
 return new;
end $$;
create trigger s07_fail_audit before insert on public.security_audit_log for each row execute function private.s07_fail_audit();

do $$
<<t>>
declare
 actor uuid:=gen_random_uuid(); actor_auth uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); outsider_auth uuid:=gen_random_uuid();
 cand uuid:=gen_random_uuid(); cand_auth uuid:=gen_random_uuid(); sub uuid:=gen_random_uuid(); app uuid; interview uuid; other_interview uuid;
 unit uuid; pos uuid; grp uuid; participant uuid; p jsonb; req jsonb; req2 jsonb; r jsonb; replay jsonb;
 key uuid:=gen_random_uuid(); bulk_key uuid:=gen_random_uuid(); message uuid; token uuid; old_token uuid; history uuid; n integer;
 raised boolean; notice text; session_id uuid; upload uuid; cv uuid; saved_sub uuid; save_key uuid:=gen_random_uuid(); edit_key uuid:=gen_random_uuid();
 version bigint; prod_message uuid; x text;
begin
 insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active) values
 (actor,actor_auth,'s07_'||actor||'@eiu.edu.vn','S07 HR',true),(outsider,outsider_auth,'s07_'||outsider||'@eiu.edu.vn','S07 participant',true);
 insert into public.app_user_roles(app_user_id,role_code) values(actor,'HR');
insert into public.app_user_permissions(app_user_id,permission_code,granted_by,granted_at)
select actor,unnest(array['interviews.email','interviews.view','interviews.manage','applications.view','submissions.view','emails.history_view','emails.history_delete']),actor,now();
insert into public.app_user_permissions(app_user_id,permission_code,granted_by,granted_at)
values(outsider,'emails.history_view',outsider,now()),(outsider,'emails.history_delete',outsider,now());
 insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active) values(cand,cand_auth,'s07_'||cand||'@example.invalid','S07 Candidate',true);
 insert into public.submissions(submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot)
 values(sub,cand,'NEW','S07 Candidate','1990-01-01','MALE','Fixture address','0900000000','s07_'||cand||'@example.invalid');
 insert into public.organizational_units(code,name_vi) values('S07_'||actor,'S07') returning unit_id into unit;
 insert into public.position_groups(code,name_vi) values('S07_'||actor,'S07') returning position_group_id into grp;
 insert into public.positions(code,name_vi,unit_id,position_group_id) values('S07_'||actor,'S07',unit,grp) returning position_id into pos;
 insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(sub,unit,pos,actor) returning application_id into app;
 insert into public.interviews(application_id,round_no,visible_to_interviewers) values(app,1,true) returning interview_id into interview;
 insert into public.interviews(application_id,round_no,visible_to_interviewers) values(app,2,true) returning interview_id into other_interview;
 insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_email)
 values(interview,outsider,1,'Participant','s07_'||outsider||'@eiu.edu.vn') returning interview_participant_id into participant;
 assert (select environment_code='TEST' and delivery_paused from private.email_configuration), 'safe TEST default';
 perform set_config('request.jwt.claim.sub',actor_auth::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor_auth)::text,true);
 execute 'set local role authenticated';
 p:=public.preview_email('INTERVIEW_INVITATION',interview,app,sub); assert (p->>'success')::boolean,'authorized preview';
 req:=jsonb_build_object('email_type','INTERVIEW_INVITATION','interview_id',interview,'application_id',app,'submission_id',sub,'preview_fingerprint',p->'data'->>'preview_fingerprint');
 foreach x in array array['recipients','environment_code','attachments','actor_id'] loop
  r:=public.enqueue_email(req||jsonb_build_object(x,'forged'),gen_random_uuid()); assert r->>'error_code'='VALIDATION_ERROR','forged extra field rejected';
 end loop;
 r:=public.enqueue_email(req||jsonb_build_object('email_type','UNSUPPORTED'),gen_random_uuid()); assert r->>'error_code'='UNSUPPORTED_EMAIL_TYPE';
 r:=public.enqueue_email(req||jsonb_build_object('submission_id',gen_random_uuid()),gen_random_uuid()); assert r->>'error_code'='FORBIDDEN','cross-chain fails closed';
 r:=public.enqueue_email(req-'preview_fingerprint',gen_random_uuid()); assert r->>'error_code'='PREVIEW_REQUIRED';
 r:=public.enqueue_email(req,key); assert (r->>'success')::boolean,'enqueue'; message:=(r->'data'->>'email_outbox_id')::uuid;
 assert public.enqueue_email(req,key)=r,'same-key replay';
 r:=public.enqueue_email(req||jsonb_build_object('preview_fingerprint','changed'),key); assert r->>'error_code'='IDEMPOTENCY_CONFLICT';
 raised:=false; begin perform public.claim_email_outbox('forged',1); exception when insufficient_privilege then raised:=true; end; assert raised,'authenticated cannot claim';
 raised:=false; begin perform public.complete_email_attempt(message,gen_random_uuid(),'forged','SENT','forged',null); exception when insufficient_privilege then raised:=true; end; assert raised,'authenticated cannot forge completion';
 raised:=false; begin perform 1 from public.email_outbox; exception when insufficient_privilege then raised:=true; end; assert raised,'outbox PII not browser-readable';
 execute 'reset role';
 assert (select count(*)=1 from public.email_outbox where idempotency_key=key),'one logical enqueue';
 delete from public.app_user_permissions where app_user_id=actor and permission_code='interviews.email';
 assert public.enqueue_email(req,key)->>'error_code'='FORBIDDEN','lost permission replay denied';
insert into public.app_user_permissions(app_user_id,permission_code,granted_by,granted_at)
values(actor,'interviews.email',actor,now());
 update public.interviews set meeting_link='https://example.invalid/changed' where interview_id=interview;
 assert public.enqueue_email(req,gen_random_uuid())->>'error_code'='STALE_PREVIEW','schedule change invalidates preview';
 p:=public.preview_email('INTERVIEW_INVITATION',interview,app,sub); req:=jsonb_set(req,'{preview_fingerprint}',p->'data'->'preview_fingerprint');
 update public.interview_participants set is_current=false,removed_at=clock_timestamp() where interview_participant_id=participant;
 assert public.enqueue_email(req,gen_random_uuid())->>'error_code'='STALE_PREVIEW','participant change invalidates preview';
 update public.interview_participants set is_current=true,removed_at=null where interview_participant_id=participant;
 p:=public.preview_email('INTERVIEW_INVITATION',interview,app,sub); req:=jsonb_set(req,'{preview_fingerprint}',p->'data'->'preview_fingerprint');
 req2:=req||jsonb_build_object('interview_id',other_interview,'preview_fingerprint','stale');
 r:=public.bulk_enqueue_email(jsonb_build_array(req,req2),bulk_key);
 assert jsonb_array_length(r->'success')=1 and r->'failed'->0->>'error_code'='STALE_PREVIEW','partial success contract';
 assert public.bulk_enqueue_email(jsonb_build_array(req,req2),bulk_key)=r,'bulk replay';
 assert public.bulk_enqueue_email(jsonb_build_array(req),bulk_key)->>'error_code'='IDEMPOTENCY_CONFLICT';
 select jsonb_agg(req) into p from generate_series(1,101); assert public.bulk_enqueue_email(p,gen_random_uuid())->>'error_code'='BATCH_LIMIT_EXCEEDED';
 -- Audit failure rolls back both logical insert and idempotency record.
 perform set_config('s07.fail_action','EMAIL_ENQUEUED',true); key:=gen_random_uuid(); raised:=false;
 begin perform public.enqueue_email(req,key); exception when raise_exception then raised:=true; end; assert raised;
 assert not exists(select 1 from public.email_outbox where idempotency_key=key);
 assert not exists(select 1 from public.idempotency_records where idempotency_key=key);
 perform set_config('s07.fail_action','',true);
 -- Isolate worker selection without deleting predecessor traces.
 update public.email_outbox set next_attempt_at=clock_timestamp()+interval '1 day' where status_code in ('QUEUED','FAILED');
 update private.email_configuration set delivery_paused=false;
 update public.email_outbox set next_attempt_at=clock_timestamp()-interval '1 minute' where email_outbox_id=message;
 r:=public.claim_email_outbox('s07',1); assert jsonb_array_length(r->'data')=1,'claim must exercise one message'; token:=(r->'data'->0->>'attempt_id')::uuid;
 assert (r->'data'->0->>'email_outbox_id')::uuid=message;
 assert jsonb_array_length(public.claim_email_outbox('other',1)->'data')=0,'live lease not claimable';
 r:=public.authorize_email_send(message,token,'s07'); assert r->>'error_code'='STALE_PREVIEW','send authorization checks queued snapshot';
 assert (select status_code='CANCELLED' from public.email_outbox where email_outbox_id=message);
 -- Fresh message exercises crash/reclaim, late completion and finite retries.
 r:=public.enqueue_email(req,gen_random_uuid()); assert (r->>'success')::boolean; message:=(r->'data'->>'email_outbox_id')::uuid;
 r:=public.claim_email_outbox('s07',1); assert (r->'data'->0->>'email_outbox_id')::uuid=message; token:=(r->'data'->0->>'attempt_id')::uuid;
 r:=public.authorize_email_send(message,token,'s07'); assert (r->>'success')::boolean;
 assert r->'data'->'recipients'->'to'=jsonb_build_array('email-sink@example.invalid'),'TEST routes only to trusted sink';
 old_token:=token; update public.email_outbox set locked_until=clock_timestamp()-interval '1 second' where email_outbox_id=message;
 r:=public.claim_email_outbox('recovery',1); assert (r->'data'->0->>'email_outbox_id')::uuid=message; token:=(r->'data'->0->>'attempt_id')::uuid; assert token<>old_token;
 assert public.complete_email_attempt(message,old_token,'s07','SENT','provider-accepted-before-crash',null)->>'error_code'='STALE_ATTEMPT';
 assert public.authorize_email_send(message,old_token,'s07')->>'error_code'='STALE_ATTEMPT';
 assert (select status_code='ABANDONED' and authorized_at is not null from private.email_attempts where attempt_id=old_token),'ambiguous provider acceptance retained';
 assert (public.authorize_email_send(message,token,'recovery')->>'success')::boolean;
 r:=public.complete_email_attempt(message,token,'recovery','RETRYABLE_FAILURE',null,'NETWORK_ERROR'); assert (r->>'success')::boolean;
 assert public.complete_email_attempt(message,token,'recovery','RETRYABLE_FAILURE',null,'NETWORK_ERROR')=r;
 assert (select count(*)=1 from public.email_history where attempt_id=token),'repeat completion one history';
 assert jsonb_array_length(public.claim_email_outbox('retry',1)->'data')=0,'backoff enforced';
 update public.email_outbox set next_attempt_at=clock_timestamp()-interval '1 second' where email_outbox_id=message;
 r:=public.claim_email_outbox('retry',1); token:=(r->'data'->0->>'attempt_id')::uuid; assert token is not null;
 assert (public.authorize_email_send(message,token,'retry')->>'success')::boolean;
 assert (public.complete_email_attempt(message,token,'retry','RETRYABLE_FAILURE',null,'NETWORK_ERROR')->>'success')::boolean;
 assert (select attempt_no=3 and status_code='FAILED' and next_attempt_at is null from public.email_outbox where email_outbox_id=message);
 assert jsonb_array_length(public.claim_email_outbox('exhausted',1)->'data')=0,'finite retry exhausted';
 -- Exact contextual RLS: participant sees only its own visible parent.
 select email_history_id into strict history from public.email_history where attempt_id=token;
 perform set_config('request.jwt.claim.sub',outsider_auth::text,true);
 execute 'set local role authenticated'; select count(*) into n from public.email_history where email_history_id=history; assert n=1,'current participant history context'; execute 'reset role';
 update public.interviews set visible_to_interviewers=false where interview_id=interview;
 execute 'set local role authenticated'; select count(*) into n from public.email_history where email_history_id=history; assert n=0,'hidden parent history denied';
 assert public.delete_email_history(history,'WRONG_RECORD','reason')->>'error_code'='FORBIDDEN'; execute 'reset role';
 perform set_config('request.jwt.claim.sub',actor_auth::text,true);
 assert public.delete_email_history(history,'INVALID','reason')->>'error_code'='INVALID_CLEANUP_CLASSIFICATION';
 assert public.delete_email_history(history,'WRONG_RECORD','  ')->>'error_code'='INVALID_CLEANUP_CLASSIFICATION';
 perform set_config('s07.fail_action','EMAIL_HISTORY_DELETED',true); raised:=false;
 begin perform public.delete_email_history(history,'TEST_RECORD'); exception when raise_exception then raised:=true; end; assert raised;
 assert exists(select 1 from public.email_history where email_history_id=history),'audit failure rolls deletion back';
 perform set_config('s07.fail_action','',true);
 assert (public.delete_email_history(history,'TEST_RECORD')->>'success')::boolean;
 assert exists(select 1 from private.email_attempts where attempt_id=token),'cleanup preserves attempts';
 assert exists(select 1 from public.security_audit_log where entity_id=history and action_code='EMAIL_HISTORY_DELETED');
 -- Actual Candidate Save with staged CLEAN CV. No helper substituted for producer.
update public.privacy_notice_versions set is_current=false;
insert into public.privacy_notice_versions(notice_version,content_vi,content_en,content_hash_sha256,published_at,effective_from,is_current,created_by)
values('s07-'||actor,'S07 privacy notice','S07 privacy notice',repeat('0',64),clock_timestamp(),clock_timestamp(),true,actor);
insert into public.document_types(code,name_vi,name_en,scope_code,is_active)
values('CV_RESUME','S07 CV','S07 CV','SUBMISSION',true)
on conflict(code) do update set is_active=true returning document_type_id into cv;
notice:='s07-'||actor;
 assert notice is not null,'predecessor published privacy fixture';
 select document_type_id into cv from public.document_types where code='CV_RESUME'; assert cv is not null;
 session_id:=gen_random_uuid(); upload:=gen_random_uuid();
 insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,status_code,presented_privacy_notice_version,expires_at)
 values(session_id,cand,'NEW_SUBMISSION','OPEN',notice,clock_timestamp()+interval '4 hours');
 insert into public.upload_reservations(upload_reservation_id,candidate_form_session_id,intended_document_type_id,temp_bucket,temp_path,original_filename,
 declared_mime_type,expected_max_size_bytes,actual_size_bytes,status_code,malware_scan_status,actor_auth_user_id,idempotency_key,expires_at)
 values(upload,session_id,cv,'candidate-quarantine','s07/'||upload||'.pdf','cv.pdf','application/pdf',5242880,1024,'VALIDATED','CLEAN',cand_auth,gen_random_uuid(),clock_timestamp()+interval '4 hours');
 insert into public.candidate_form_document_changes(candidate_form_session_id,upload_reservation_id,action_code,intended_document_type_id,status_code)
 values(session_id,upload,'ADD',cv,'PENDING');
 perform set_config('request.jwt.claim.sub',cand_auth::text,true);
 perform set_config('s07.fail_action','EMAIL_ENQUEUED',true); raised:=false;
 begin r:=public.submit_candidate_submission(session_id,'Saved Candidate','0900000000','1990-01-01','MALE','Saved address','[]',notice,save_key);
 exception when raise_exception then raised:=true; end; assert raised,'mandatory enqueue audit rolls Save back';
 assert (select status_code='OPEN' from public.candidate_form_sessions where candidate_form_session_id=session_id);
 assert (select status_code='VALIDATED' from public.upload_reservations where upload_reservation_id=upload);
 assert not exists(select 1 from public.submission_documents where storage_path='s07/'||upload||'.pdf');
 assert not exists(select 1 from public.idempotency_records where idempotency_key=save_key);
 perform set_config('s07.fail_action','',true);
 update private.email_configuration set environment_code='PRODUCTION',delivery_paused=true,delivery_not_before=clock_timestamp()+interval '1 day',hr_recipients=array['trusted-hr@example.invalid'];
 insert into private.email_templates select 'PRODUCTION',email_type,'fixture-approved',subject,body_text from private.email_templates where environment_code='TEST';
 r:=public.submit_candidate_submission(session_id,'Saved Candidate','0900000000','1990-01-01','MALE','Saved address','[]',notice,save_key);
 assert (r->>'success')::boolean,'delivery pause/quota must not block Save'; saved_sub:=(r->>'submission_id')::uuid;
 assert public.submit_candidate_submission(session_id,'Saved Candidate','0900000000','1990-01-01','MALE','Saved address','[]',notice,save_key)=r;
 assert (select count(*)=2 from public.email_outbox where submission_id=saved_sub and environment_code='PRODUCTION'),'HR plus accepted confirmation retained at enqueue';
 select email_outbox_id into strict prod_message from public.email_outbox where submission_id=saved_sub and email_type='HR_SUBMISSION_CREATED_NOTIFICATION';
 assert (select recipients->'to'=jsonb_build_array('trusted-hr@example.invalid') from public.email_outbox where email_outbox_id=prod_message);
 session_id:=gen_random_uuid(); select version_no into version from public.submissions where submission_id=saved_sub;
 insert into public.candidate_form_sessions(candidate_form_session_id,candidate_id,mode_code,target_submission_id,base_submission_version_no,status_code,presented_privacy_notice_version,expires_at)
 values(session_id,cand,'EDIT_SUBMISSION',saved_sub,version,'OPEN',notice,clock_timestamp()+interval '4 hours');
 perform set_config('s07.fail_action','EMAIL_ENQUEUED',true); raised:=false;
 begin r:=public.update_candidate_submission(session_id,'Changed Candidate','0900000000','1990-01-01','MALE','Saved address','[]',notice,edit_key);
 exception when raise_exception then raised:=true; end; assert raised;
 assert (select full_name='Saved Candidate' and version_no=version from public.submissions where submission_id=saved_sub),'Update rollback';
 perform set_config('s07.fail_action','',true);
 r:=public.update_candidate_submission(session_id,'Changed Candidate','0900000000','1990-01-01','MALE','Saved address','[]',notice,edit_key); assert (r->>'success')::boolean;
 assert public.update_candidate_submission(session_id,'Changed Candidate','0900000000','1990-01-01','MALE','Saved address','[]',notice,edit_key)=r;
 assert (select count(*)=1 from public.email_outbox where submission_id=saved_sub and email_type='HR_SUBMISSION_UPDATED_NOTIFICATION' and environment_code='PRODUCTION');
 -- Deliver then remove wrong operational history; production business trace survives.
 update private.email_configuration set delivery_paused=false,delivery_not_before=null;
 update public.email_outbox set next_attempt_at=clock_timestamp()+interval '1 day' where status_code='QUEUED';
 update public.email_outbox set next_attempt_at=clock_timestamp()-interval '1 second' where email_outbox_id=prod_message;
 r:=public.claim_email_outbox('production-fixture',1); token:=(r->'data'->0->>'attempt_id')::uuid; assert token is not null;
 assert (public.authorize_email_send(prod_message,token,'production-fixture')->>'success')::boolean;
 assert (public.complete_email_attempt(prod_message,token,'production-fixture','SENT','simulated-provider',null)->>'success')::boolean;
 select email_history_id into strict history from public.email_history where attempt_id=token;
 assert (select environment_code='PRODUCTION' and submission_id=saved_sub from public.email_history where email_history_id=history);
 perform set_config('request.jwt.claim.sub',actor_auth::text,true);
 assert public.delete_email_history(history,'TEST_RECORD')->>'error_code'='INVALID_CLEANUP_CLASSIFICATION';
 assert (public.delete_email_history(history,'WRONG_RECORD','Fixture correction')->>'success')::boolean;
 raised:=false; begin delete from public.email_outbox where email_outbox_id=prod_message; exception when check_violation then raised:=true; end; assert raised,'production outbox retained';
 raised:=false; begin delete from public.submissions where submission_id=saved_sub; exception when foreign_key_violation then raised:=true; end; assert raised,'production submission retained';
 raise notice 'S07 manual, Candidate, worker, history and retention contracts exercised';
end $$;
rollback;
