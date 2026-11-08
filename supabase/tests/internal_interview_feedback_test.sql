\set ON_ERROR_STOP on
begin;
create function pg_temp.assert_ok(p_ok boolean,p_label text) returns void language plpgsql as $$
begin if p_ok is distinct from true then raise exception 'ASSERTION FAILED: %',p_label; end if; end; $$;
create function pg_temp.denied(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when insufficient_privilege then return true; end; $$;
create function pg_temp.immutable(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when check_violation then return sqlerrm='FEEDBACK_IMMUTABLE'; end; $$;
select gen_random_uuid() unit,gen_random_uuid() grp,gen_random_uuid() pos,gen_random_uuid() pos2,gen_random_uuid() pos3,
 gen_random_uuid() candidate,gen_random_uuid() submission,gen_random_uuid() app,gen_random_uuid() app2,gen_random_uuid() app3,
 gen_random_uuid() i1,gen_random_uuid() i2,gen_random_uuid() i3,gen_random_uuid() idead,gen_random_uuid() irevoke,
 gen_random_uuid() u1,gen_random_uuid() u2,gen_random_uuid() outsider,gen_random_uuid() unbound,
 gen_random_uuid() a1,gen_random_uuid() a2,gen_random_uuid() aout,
 gen_random_uuid() p1,gen_random_uuid() p2,gen_random_uuid() pold,gen_random_uuid() pdead,gen_random_uuid() prevoke,gen_random_uuid() punbound,
 gen_random_uuid() create_key,gen_random_uuid() publish_key \gset
select coalesce((select app_user_id from public.app_users where is_root_admin),'10110000-0000-4000-8000-000000000001'::uuid) root,
 coalesce((select auth_user_id from public.app_users where is_root_admin),'10110000-0000-4000-8000-000000000002'::uuid) root_auth \gset
insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin)
select :'root',:'root_auth','feedback-root@eiu.edu.vn','Feedback Root',true,true where not exists(select 1 from public.app_users where is_root_admin);
insert into public.organizational_units(unit_id,name_vi,code) values(:'unit','Feedback Unit',:'unit');
insert into public.position_groups(position_group_id,name_vi,code) values(:'grp','Feedback Group',:'grp');
insert into public.positions(position_id,unit_id,position_group_id,name_vi,code) values
(:'pos',:'unit',:'grp','Feedback Position',:'pos'),(:'pos2',:'unit',:'grp','Deadline Position',:'pos2'),(:'pos3',:'unit',:'grp','Revoke Position',:'pos3');
insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin) values
(:'u1',:'a1',:'u1'||'@eiu.edu.vn','Evaluator One',true,false),(:'u2',:'a2',:'u2'||'@eiu.edu.vn','Evaluator Two',true,false),
(:'outsider',:'aout',:'outsider'||'@eiu.edu.vn','Unassigned User',true,false),(:'unbound',null,:'unbound'||'@eiu.edu.vn','Unbound User',true,false);
insert into public.candidates(candidate_id,auth_user_id,email,current_full_name) values(:'candidate',gen_random_uuid(),:'candidate'||'@example.invalid','Feedback Candidate');
insert into public.submissions(submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot)
values(:'submission',:'candidate','READ','Feedback Candidate','1990-01-01','MALE','Private address','0900000000','private-contact@example.invalid');
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id) values
(:'app',:'submission',:'unit',:'pos',:'root'),(:'app2',:'submission',:'unit',:'pos2',:'root'),(:'app3',:'submission',:'unit',:'pos3',:'root');
insert into public.interviews(interview_id,application_id,round_no,schedule_status_code,report_status_code,is_active,visible_to_interviewers) values
(:'i1',:'app',1,'AVAILABLE','WAITING_FOR_REPORT',true,true),(:'i2',:'app',2,'AVAILABLE','WAITING_FOR_REPORT',true,true),
(:'idead',:'app2',1,'AVAILABLE','WAITING_FOR_REPORT',true,true),(:'irevoke',:'app3',1,'AVAILABLE','WAITING_FOR_REPORT',true,true);
insert into public.interview_participants(interview_participant_id,interview_id,app_user_id,participant_order,snapshot_name,snapshot_email) values
(:'pold',:'i1',:'u1',1,'Old round evaluator','private-one@eiu.edu.vn'),
(:'p1',:'i2',:'u1',1,'Evaluator One','private-one@eiu.edu.vn'),(:'p2',:'i2',:'u2',2,'Evaluator Two','private-two@eiu.edu.vn'),
(:'punbound',:'i2',:'unbound',3,'Unbound User','private-unbound@eiu.edu.vn'),
(:'pdead',:'idead',:'u1',1,'Evaluator One','private-one@eiu.edu.vn'),(:'prevoke',:'irevoke',:'u1',1,'Evaluator One','private-one@eiu.edu.vn');
set local role authenticated;
select set_config('request.jwt.claim.sub',:'root_auth',true);
select pg_temp.assert_ok(pg_temp.denied('select * from private.interview_feedback_invitations'),'raw invitation SELECT denied');
select pg_temp.assert_ok(pg_temp.denied('select * from private.interview_feedback_templates'),'raw template SELECT denied');
select pg_temp.assert_ok(pg_temp.denied('delete from private.interview_feedback_collections'),'raw mutation denied');
select pg_temp.assert_ok(pg_temp.denied('select private.feedback_context(null)'),'private helper denied');
select public.get_interview_feedback_workspace() result \gset
select pg_temp.assert_ok((:'result'::jsonb #>> '{data,can_manage}')::boolean,'Root workspace authorized');
select pg_temp.assert_ok(:'result' not like '%private-contact%' and :'result' not like '%Private address%' and :'result' not like '%private-one%','minimal workspace allowlist');
select pg_temp.assert_ok(not exists(select 1 from jsonb_array_elements(:'result'::jsonb #> '{data,interviews}') x,
 jsonb_array_elements(x->'participants') p where p->>'participant_id'=:'punbound'),'unbound evaluator excluded');
select public.publish_interview_feedback_template('Required trial','[{"key":"knowledge","label":"Knowledge","required":true},{"key":"optional","label":"Optional","required":false}]',null,:'publish_key') result \gset
select pg_temp.assert_ok((:'result'::jsonb->>'success')::boolean,'publish template');
select :'result'::jsonb #>> '{data,template_id}' template \gset
select public.publish_interview_feedback_template('Required trial','[{"key":"knowledge","label":"Knowledge","required":true},{"key":"optional","label":"Optional","required":false}]',null,:'publish_key') result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,template_id}'=:'template','publish retry immutable version');
select pg_temp.assert_ok(public.publish_interview_feedback_template('Bad','[{"key":"a","label":"A","required":false},{"key":"a","label":"B","required":true}]',null,gen_random_uuid())->>'error_code'='VALIDATION_ERROR','duplicate question keys rejected');
select pg_temp.assert_ok(public.create_interview_feedback_collection(:'i1',:'template',array[:'pold'::uuid],null,gen_random_uuid())->>'error_code'='CONTEXT_NOT_WRITABLE','exact historical round rejected');
select pg_temp.assert_ok(public.create_interview_feedback_collection(:'i2',:'template',array[:'pold'::uuid],null,gen_random_uuid())->>'error_code'='VALIDATION_ERROR','cross-round participant rejected');
select pg_temp.assert_ok(public.create_interview_feedback_collection(:'i2',:'template',array[:'punbound'::uuid],null,gen_random_uuid())->>'error_code'='VALIDATION_ERROR','unbound evaluator rejected');
select public.create_interview_feedback_collection(:'i2',:'template',array[:'p1'::uuid,:'p2'::uuid],null,:'create_key') result \gset
select pg_temp.assert_ok((:'result'::jsonb->>'success')::boolean,'collection created');
select :'result'::jsonb #>> '{data,collection_id}' collection \gset
select public.create_interview_feedback_collection(:'i2',:'template',array[:'p1'::uuid,:'p2'::uuid],null,:'create_key') result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,collection_id}'=:'collection','same-key create replay');
select public.create_interview_feedback_collection(:'i2',:'template',array[:'p1'::uuid],null,gen_random_uuid()) result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,collection_id}'=:'collection','one collection even new key');
select public.get_interview_feedback_collection(:'collection') result \gset
select pg_temp.assert_ok(jsonb_array_length(:'result'::jsonb #> '{data,invitations}')=2,'denominator remains original selection');
select x->>'invitation_id' inv1 from jsonb_array_elements(:'result'::jsonb #> '{data,invitations}') x where x->>'participant_id'=:'p1' \gset
select x->>'invitation_id' inv2 from jsonb_array_elements(:'result'::jsonb #> '{data,invitations}') x where x->>'participant_id'=:'p2' \gset
select public.publish_interview_feedback_template('New version','[{"key":"different","label":"Different question","required":false}]',:'template',gen_random_uuid()) result \gset
select pg_temp.assert_ok((:'result'::jsonb #>> '{data,version_no}')::int=2,'publish creates next version');
select pg_temp.assert_ok(public.get_interview_feedback_collection(:'collection') #>> '{data,template,template_id}'=:'template','collection pins original template');
select pg_temp.assert_ok(public.save_interview_feedback_consolidation(:'collection','Draft','',0,false)->>'error_code'='COMPLETENESS_REQUIRED','missing responses block consolidation');
select set_config('request.jwt.claim.sub',:'aout',true);
select pg_temp.assert_ok(public.get_interview_feedback_invitation(:'inv1')->>'error_code'='FORBIDDEN','invitation UUID not bearer credential');
select pg_temp.assert_ok(public.get_interview_feedback_collection(:'collection')->>'error_code'='FORBIDDEN','unassigned collection denied');
select pg_temp.assert_ok(public.publish_interview_feedback_template('Forbidden','[]',null,gen_random_uuid())->>'error_code'='FORBIDDEN','non-HR publish denied');
reset role;
insert into public.app_user_roles(app_user_id,role_code) values(:'u1','HR');
insert into public.app_user_permissions(app_user_id,permission_code) values(:'u1','interviews.view'),(:'u1','interviews.manage'),(:'u1','reports.view');
set local role authenticated;
select set_config('request.jwt.claim.sub',:'a1',true);
select pg_temp.assert_ok((public.get_interview_feedback_workspace() #>> '{data,can_manage}')::boolean,'nonroot HR with both permissions authorized');
reset role;
delete from public.app_user_permissions where app_user_id=:'u1' and permission_code='interviews.manage';
set local role authenticated;
select pg_temp.assert_ok(not (public.get_interview_feedback_workspace() #>> '{data,can_manage}')::boolean,'missing interviews.manage denies management');
reset role;
insert into public.app_user_permissions(app_user_id,permission_code) values(:'u1','interviews.manage');
delete from public.app_user_permissions where app_user_id=:'u1' and permission_code='reports.view';
set local role authenticated;
select pg_temp.assert_ok(not (public.get_interview_feedback_workspace() #>> '{data,can_manage}')::boolean,'missing reports.view denies management');
reset role;
insert into public.app_user_permissions(app_user_id,permission_code) values(:'u1','reports.view');
set local role authenticated;
select public.get_interview_feedback_invitation(:'inv1') result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,mode}'='OWN' and not (:'result'::jsonb->'data' ?| array['invitations','blockers','consolidation']),'own detail excludes other answers and HR tracking');
select pg_temp.assert_ok(public.get_interview_feedback_invitation(:'inv2')->>'error_code'='FORBIDDEN','cross-interviewer read denied');
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv2','{}',1,false)->>'error_code'='FORBIDDEN','cross-interviewer write denied');
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"unknown":"x"}',1,false)->>'error_code'='VALIDATION_ERROR','unknown answer key rejected');
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{}',1,true)->>'error_code'='REQUIRED_ANSWER_MISSING','required answer enforced');
select public.save_interview_feedback_response(:'inv1','{"knowledge":"Draft one"}',1,false) result \gset
select pg_temp.assert_ok((:'result'::jsonb #>> '{data,version_no}')::int=2,'draft increments version');
select pg_temp.assert_ok(public.get_interview_feedback_invitation(:'inv1') #>> '{data,invitation,answers,knowledge}'='Draft one','draft reload persists');
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"knowledge":"stale"}',1,false)->>'error_code'='STALE_VERSION','stale same-user tab rejected');
reset role;
update public.interviews set visible_to_interviewers=false where interview_id=:'i2';
set local role authenticated;
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"knowledge":"Hidden"}',2,false)->>'error_code'='FORBIDDEN','hidden draft write rejected');
reset role;
update public.interviews set visible_to_interviewers=true where interview_id=:'i2';
update public.applications set is_active=false where application_id=:'app';
set local role authenticated;
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"knowledge":"Inactive"}',2,true)->>'error_code'='FORBIDDEN','inactive parent submit rejected');
reset role;
update public.applications set is_active=true where application_id=:'app';
update public.interviews set report_status_code='HIRED' where interview_id=:'i2';
set local role authenticated;
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"knowledge":"Final"}',2,true)->>'error_code'='CONTEXT_NOT_WRITABLE','final-status draft submit rejected');
reset role;
update public.interviews set report_status_code='WAITING_FOR_REPORT' where interview_id=:'i2';
insert into public.interviews(interview_id,application_id,round_no,schedule_status_code,report_status_code,is_active,visible_to_interviewers)
values(:'i3',:'app',3,'AVAILABLE','WAITING_FOR_REPORT',true,true);
set local role authenticated;
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"knowledge":"Old round"}',2,false)->>'error_code'='CONTEXT_NOT_WRITABLE','new current round blocks draft writes');
reset role;
delete from public.interviews where interview_id=:'i3';
set local role authenticated;
select public.save_interview_feedback_response(:'inv1','{"knowledge":"First final","optional":""}',2,true) result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,state}'='SUBMITTED','submit successful');
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"knowledge":"First final","optional":""}',2,true) #>> '{data,version_no}'='3','identical submit replay');
select pg_temp.assert_ok(public.save_interview_feedback_response(:'inv1','{"knowledge":"Changed"}',3,false)->>'error_code'='ALREADY_SUBMITTED','submitted answer immutable');
select set_config('request.jwt.claim.sub',:'a2',true);
select pg_temp.assert_ok((public.save_interview_feedback_response(:'inv2','{"knowledge":"Second final"}',1,true)->>'success')::boolean,'second evaluator submits');
select set_config('request.jwt.claim.sub',:'root_auth',true);
select public.save_interview_feedback_consolidation(:'collection','Pinned report','Original summary',0,false) result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,state}'='DRAFT','complete draft consolidation');
select :'result'::jsonb #> '{data,snapshot}' snapshot \gset
select pg_temp.assert_ok(jsonb_array_length(:'snapshot'::jsonb->'evaluators')=2 and jsonb_array_length(:'snapshot'::jsonb->'questions')=2,'complete pinned denominator and questions');
select pg_temp.assert_ok(:'snapshot'::jsonb #>> '{context,round_no}'='2' and :'snapshot'::jsonb #>> '{template,template_id}'=:'template','exact pinned round/template');
select pg_temp.assert_ok(exists(select 1 from jsonb_array_elements(:'snapshot'::jsonb #> '{questions,1,answers}') a where a->>'invitation_id'=:'inv2' and a->'answer'='null'::jsonb),'missing optional answer retains null meaning');
select pg_temp.assert_ok(exists(select 1 from jsonb_array_elements(:'snapshot'::jsonb #> '{questions,1,answers}') a where a->>'invitation_id'=:'inv1' and a->>'answer'=''),'explicit blank retained');
select pg_temp.assert_ok(public.save_interview_feedback_consolidation(:'collection','Stale','',0,true)->>'error_code'='STALE_VERSION','stale approval blocked');
reset role;
-- Authoritative contextual mutations emulate another concurrent workflow.
update public.app_users set is_active=false where app_user_id=:'u2';
set local role authenticated;
select pg_temp.assert_ok(public.save_interview_feedback_consolidation(:'collection','Invalid','',1,true)->>'error_code'='COMPLETENESS_REQUIRED','inactive original evaluator blocks approval');
reset role;
update public.app_users set is_active=true where app_user_id=:'u2';
update public.interview_participants set is_current=false,removed_at=clock_timestamp() where interview_participant_id=:'p2';
set local role authenticated;
select pg_temp.assert_ok(public.save_interview_feedback_consolidation(:'collection','Invalid','',1,true)->>'error_code'='COMPLETENESS_REQUIRED','removed evaluator does not shrink denominator');
select set_config('request.jwt.claim.sub',:'a2',true);
select pg_temp.assert_ok(public.get_interview_feedback_invitation(:'inv2')->>'error_code'='FORBIDDEN','removed evaluator read revoked');
reset role;
update public.interview_participants set is_current=true,removed_at=null where interview_participant_id=:'p2';
set local role authenticated;
select set_config('request.jwt.claim.sub',:'root_auth',true);
select public.save_interview_feedback_consolidation(:'collection','Edited title','Edited overall summary',1,false) result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,version_no}'='2' and :'result'::jsonb #> '{data,snapshot}'=:'snapshot'::jsonb,'draft edit preserves pinned snapshot');
select public.save_interview_feedback_consolidation(:'collection','Approved title','Edited overall summary',2,true) result \gset
select pg_temp.assert_ok(:'result'::jsonb #>> '{data,state}'='APPROVED' and :'result'::jsonb #> '{data,snapshot}'=:'snapshot'::jsonb,'approval preserves snapshot');
select pg_temp.assert_ok(public.save_interview_feedback_consolidation(:'collection','Overwrite','',3,false)->>'error_code'='ALREADY_APPROVED','approved report immutable');
-- Outstanding revoke and deadline cases use separate exact interviews.
select public.create_interview_feedback_collection(:'irevoke',:'template',array[:'prevoke'::uuid],null,gen_random_uuid()) #>> '{data,collection_id}' revoke_collection \gset
select public.get_interview_feedback_collection(:'revoke_collection') #>> '{data,invitations,0,invitation_id}' revoke_inv \gset
select pg_temp.assert_ok(public.revoke_interview_feedback_invitation(:'revoke_inv',7)->>'error_code'='STALE_VERSION','stale revoke denied');
select pg_temp.assert_ok(public.revoke_interview_feedback_invitation(:'revoke_inv',1) #>> '{data,state}'='REVOKED','outstanding revoke succeeds');
select pg_temp.assert_ok(public.save_interview_feedback_consolidation(:'revoke_collection','No waiver','',0,false)->>'error_code'='COMPLETENESS_REQUIRED','revoked invitation blocks finalization');
select pg_temp.assert_ok(public.get_interview_feedback_collection(:'revoke_collection') #>> '{data,blockers,0,reason}'='INVITATION_REVOKED','explicit denominator blocker');
select public.create_interview_feedback_collection(:'idead',:'template',array[:'pdead'::uuid],clock_timestamp()+interval '0.5 seconds',gen_random_uuid()) #>> '{data,collection_id}' dead_collection \gset
select public.get_interview_feedback_collection(:'dead_collection') #>> '{data,invitations,0,invitation_id}' dead_inv \gset
select pg_sleep(0.6);
select set_config('request.jwt.claim.sub',:'a1',true);
select pg_temp.assert_ok(public.save_interview_feedback_response(:'dead_inv','{"knowledge":"Late"}',1,true)->>'error_code'='DEADLINE_PASSED','deadline enforced');
select pg_temp.assert_ok(public.save_interview_feedback_response(:'revoke_inv','{"knowledge":"Revoked"}',2,true)->>'error_code'='INVITATION_REVOKED','revocation blocks response');
reset role;
insert into public.interviews(interview_id,application_id,round_no,schedule_status_code,report_status_code,is_active,visible_to_interviewers)
values(:'i3',:'app',3,'AVAILABLE','WAITING_FOR_REPORT',true,true);
set local role authenticated;
select pg_temp.assert_ok((public.get_interview_feedback_invitation(:'inv1')->>'success')::boolean,'historical own submitted read remains');
reset role;
update public.interviews set visible_to_interviewers=false where interview_id=:'i2';
set local role authenticated;
select pg_temp.assert_ok(public.get_interview_feedback_invitation(:'inv1')->>'error_code'='FORBIDDEN','hidden historical read denied');
reset role;
update public.interviews set visible_to_interviewers=true where interview_id=:'i2';
update public.applications set is_active=false where application_id=:'app';
set local role authenticated;
select pg_temp.assert_ok(public.get_interview_feedback_invitation(:'inv1')->>'error_code'='FORBIDDEN','inactive parent read denied');
reset role;
select pg_temp.assert_ok(pg_temp.immutable(format('update private.interview_feedback_templates set name=''tampered'' where template_id=%L',:'template')),'database enforces template immutability');
select pg_temp.assert_ok(pg_temp.immutable(format('update private.interview_feedback_invitations set answers=''{}'' where invitation_id=%L',:'inv1')),'database enforces submitted immutability');
select pg_temp.assert_ok(pg_temp.immutable(format('update private.interview_feedback_consolidations set title=''tampered'' where collection_id=%L',:'collection')),'database enforces approved immutability');
select pg_temp.assert_ok((select count(*)=2 from private.interview_feedback_notification_intents n join private.interview_feedback_invitations fi using(invitation_id) where fi.collection_id=:'collection' and delivery_state='PROVIDER_PAUSED'),'one paused intent per original invitee');
select pg_temp.assert_ok((select count(*)=1 from public.security_audit_log where entity_id=:'inv1' and action_code='FEEDBACK_RESPONSE_SUBMIT'),'submit replay emits no duplicate audit');
select pg_temp.assert_ok((select count(*)=0 from public.interview_reports r join public.interview_participants ip using(interview_participant_id) where ip.interview_id in (:'i1',:'i2',:'idead',:'irevoke')),'legacy reports untouched');
select pg_temp.assert_ok((select bool_and(report_status_code='WAITING_FOR_REPORT') from public.interviews where interview_id in (:'i1',:'i2',:'idead',:'irevoke')),'legacy status/outcome not changed');
set local role anon;
select pg_temp.assert_ok(pg_temp.denied('select public.get_interview_feedback_workspace()'),'anonymous RPC execution denied');
reset role;
rollback;
\echo 'Internal interview feedback SQL regression PASS'
