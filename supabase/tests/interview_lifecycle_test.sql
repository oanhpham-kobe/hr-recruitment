-- TASK-S04-002: Interview report, participant, schedule, document, and RLS tests
\set ON_ERROR_STOP on

do $$
<<test>>
declare
  s text := substr(gen_random_uuid()::text, 1, 8);
  hr_auth uuid := gen_random_uuid(); hr uuid;
  i1_auth uuid := gen_random_uuid(); i1 uuid;
  i2_auth uuid := gen_random_uuid(); i2 uuid;
  outsider_auth uuid := gen_random_uuid(); outsider uuid;
  inactive_auth uuid := gen_random_uuid(); inactive_user uuid;
  unit_id uuid; pg_id uuid; pos_id uuid; room_id uuid; fmt_id uuid; doc_type uuid;
  cand uuid; sub_id uuid; app_id uuid; interview_id uuid;
  cand2 uuid; sub2 uuid; app2 uuid; conflict_interview uuid;
  p1 uuid; p2 uuid; p3 uuid; old_p2 uuid;
  report1 uuid; report2 uuid; logical_id uuid; reservation_id uuid; email_history_id uuid;
  empty_rep uuid; empty_int uuid; res_id_empty uuid; bulk_int1 uuid;
  v2 bigint;
  r jsonb; n integer; v bigint; versions bigint[]; ts timestamptz; err boolean;
begin
  raise notice '=== Running TASK-S04-002 Interview Lifecycle Test Suite ===';

  -- Shared fixture and authorized HR identity.
  insert into public.organizational_units(code,name_vi) values ('T002_U_'||s,'T002 Unit') returning public.organizational_units.unit_id into unit_id;
  insert into public.position_groups(code,name_vi) values ('T002_PG_'||s,'T002 Group') returning public.position_groups.position_group_id into pg_id;
  insert into public.positions(unit_id,position_group_id,code,name_vi) values(unit_id,pg_id,'T002_P_'||s,'T002 Position') returning public.positions.position_id into pos_id;
  insert into public.rooms(code,display_name,is_active) values('T002_R_'||s,'T002 Room',true) returning public.rooms.room_id into room_id;
  insert into public.interview_formats(code,name_vi,requires_room,requires_meeting_link,is_active) values('T002_F_'||s,'T002 In person',true,false,true) returning public.interview_formats.interview_format_id into fmt_id;
  insert into public.document_types(code,name_vi,scope_code,is_active) values('T002_D_'||s,'T002 Interview Document','INTERVIEW',true) returning public.document_types.document_type_id into doc_type;
  insert into public.app_users(auth_user_id,full_name,email,is_active) values(hr_auth,'T002 HR','t002_hr_'||s||'@eiu.edu.vn',true) returning public.app_users.app_user_id into hr;
  insert into public.app_user_roles(app_user_id,role_code) values(hr,'HR');
  insert into public.app_user_permissions(app_user_id,permission_code) values
    (hr,'interviews.view'),(hr,'interviews.manage'),(hr,'interviews.participants'),(hr,'interviews.status'),(hr,'interviews.documents'),
    (hr,'reports.view'),(hr,'reports.edit_interviewer'),(hr,'reports.manage_status'),(hr,'reports.delete') on conflict do nothing;
  insert into public.app_users(auth_user_id,full_name,email,job_title,is_active) values(i1_auth,'T002 Interviewer One','t002_i1_'||s||'@eiu.edu.vn','Lecturer',true) returning public.app_users.app_user_id into i1;
  insert into public.app_users(auth_user_id,full_name,email,job_title,is_active) values(i2_auth,'T002 Interviewer Two','t002_i2_'||s||'@eiu.edu.vn','Professor',true) returning public.app_users.app_user_id into i2;
  insert into public.app_users(auth_user_id,full_name,email,is_active) values(outsider_auth,'T002 Outsider','t002_out_'||s||'@eiu.edu.vn',true) returning public.app_users.app_user_id into outsider;
  insert into public.app_users(auth_user_id,full_name,email,is_active) values(inactive_auth,'T002 Inactive','t002_inactive_'||s||'@eiu.edu.vn',false) returning public.app_users.app_user_id into inactive_user;
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t002_c_'||s||'@example.com',true) returning public.candidates.candidate_id into cand;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,status_code) values(cand,'T002 Candidate','1990-01-01','MALE','Address','0900000000','t002_c_'||s||'@example.com','PROCESSED') returning public.submissions.submission_id into sub_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id,is_active) values(sub_id,unit_id,pos_id,hr,true) returning public.applications.application_id into app_id;
  insert into public.interviews(application_id,round_no,schedule_status_code,report_status_code,is_active) values(app_id,1,'AVAILABLE','INTERVIEW_SCHEDULING',true) returning public.interviews.interview_id into interview_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',hr_auth::text)::text,true);

  -- 1. Report table, active uniqueness and canonical lifecycle constraint.
  r:=public.add_interview_participant(interview_id,i1,gen_random_uuid()); assert (r->>'success')::boolean,'participant 1 added'; p1:=(r->'data'->>'interview_participant_id')::uuid;
  insert into public.interview_reports(interview_participant_id,created_by,updated_by) values(p1,hr,hr) returning public.interview_reports.interview_report_id into report1;
  err:=false; begin insert into public.interview_reports(interview_participant_id,created_by,updated_by) values(p1,hr,hr); exception when unique_violation then err:=true; end; assert err,'one active report per participant';
  err:=false; begin update public.interview_reports set is_active=true,is_archived=true where interview_report_id=report1; exception when check_violation then err:=true; end; assert err,'report lifecycle check rejects invalid boolean combination';

  -- 2. Decision metadata moves only for final decision changes.
  update public.interview_reports set conclusion='Recommend',updated_by=hr where interview_report_id=report1;
  select decision_updated_at into ts from public.interview_reports where interview_report_id=report1; assert ts is not null,'final decision sets metadata';
  perform pg_sleep(0.01); update public.interview_reports set professional_knowledge='Strong',updated_by=hr where interview_report_id=report1;
  assert (select decision_updated_at from public.interview_reports where interview_report_id=report1)=ts,'qualitative update preserves decision timestamp';

  -- 3. HR field-aware conflict rejects same field while disjoint patches merge.
  select version_no into v from public.interview_reports where interview_report_id=report1;
  r:=public.save_interviewer_report(p1,jsonb_build_object('necessary_skills','SQL'),v,jsonb_build_object('necessary_skills',null)); assert (r->>'success')::boolean,'first HR patch succeeds';
  r:=public.save_interviewer_report(p1,jsonb_build_object('other_comment','stale'),v,jsonb_build_object('other_comment',null)); assert (r->>'success')::boolean,'HR disjoint stale patch merges';
  r:=public.save_interviewer_report(p1,jsonb_build_object('necessary_skills','conflict'),v,jsonb_build_object('necessary_skills',null)); assert (r->>'error_code')='STALE_VERSION','HR same-field conflict rejected';

  -- 4. Owner wins on their own stale same-field patch.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',i1_auth::text)::text,true);
  r:=public.save_interviewer_report(p1,jsonb_build_object('necessary_skills','Owner wins'),v,jsonb_build_object('necessary_skills',null)); assert (r->>'success')::boolean,'interviewer owner-wins patch succeeds';
  assert (select necessary_skills from public.interview_reports where interview_report_id=report1)='Owner wins','owner value persisted';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',hr_auth::text)::text,true);

  -- 5. Report status is current-round-only, recalculates submission, preserves HR note.
  update public.interviews set hr_report_note='private HR note',updated_by=hr where public.interviews.interview_id=test.interview_id; select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  r:=public.change_report_status(interview_id,'HIRED',v); assert (r->>'success')::boolean,'report status changed';
  assert (select status_code from public.submissions where submission_id=sub_id)='DONE','status recalculated';
  assert (select hr_report_note from public.interviews where public.interviews.interview_id=test.interview_id)='private HR note','status command preserves HR note';
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id; r:=public.change_report_status(interview_id,'FOLLOW_UP',v); assert (r->>'success')::boolean,'return to writable report status';

  -- 6. Decision view chooses newest eligible report and falls back when cleared.
  r:=public.add_interview_participant(interview_id,i2,gen_random_uuid()); assert (r->>'success')::boolean,'participant 2 added'; p2:=(r->'data'->>'interview_participant_id')::uuid;
  insert into public.interview_reports(interview_report_id,interview_participant_id,conclusion,created_by,updated_by) values('ffffffff-ffff-ffff-ffff-ffffffffffff',p2,'Newer decision',hr,hr) returning public.interview_reports.interview_report_id into report2;
  assert (select interview_report_id from private.interview_final_decision_source where private.interview_final_decision_source.application_id=test.app_id)=report2,'newest decision is source';
  update public.interview_reports set conclusion=null,updated_by=hr where interview_report_id=report2;
  assert (select interview_report_id from private.interview_final_decision_source where private.interview_final_decision_source.application_id=test.app_id)=report1,'source falls back after clearing all decision fields';

  -- 7/8. Participant snapshot, duplicate prevention, removal and compact ordering.
  r:=public.add_interview_participant(interview_id,i2,gen_random_uuid()); assert (r->>'error_code')='DUPLICATE_PARTICIPANT','duplicate participant rejected';
  assert (select snapshot_name from public.interview_participants where interview_participant_id=p1)='T002 Interviewer One','participant snapshot copied';
  select version_no into v from public.interview_participants where interview_participant_id=p2; r:=public.remove_interview_participant(p2,v); assert (r->>'success')::boolean,'participant removed';
  assert not (select is_current from public.interview_participants where interview_participant_id=p2),'removed participant no longer current';
  assert (select participant_order from public.interview_participants where interview_participant_id=p1)=1,'remaining participant resequenced'; old_p2:=p2;
  assert (select not is_active and is_archived from public.interview_reports where interview_report_id=report2),'removing a participant archives their active report';

  -- 9. Re-add restore revives archived report; create-new preserves old history.
  update public.interview_reports set is_active=false,is_archived=true,updated_by=hr where interview_report_id=report2;
  r:=public.readd_interview_participant(old_p2,'RESTORE_OLD_REPORT',gen_random_uuid()); assert (r->>'success')::boolean,'restore old participant/report succeeds';
  assert (select is_active from public.interview_reports where interview_report_id=report2),'old report restored active';
  select version_no into v from public.interview_participants where interview_participant_id=old_p2; perform public.remove_interview_participant(old_p2,v);
  r:=public.readd_interview_participant(old_p2,'CREATE_NEW_REPORT',gen_random_uuid()); assert (r->>'success')::boolean,'create-new participant succeeds'; p3:=(r->'data'->>'interview_participant_id')::uuid;
  assert p3<>old_p2 and not exists(select 1 from public.interview_reports where interview_participant_id=p3),'new participant has no eager report';

  -- 10. Reorder uses collision-safe two phase ordering.
  select array_agg(ip.version_no order by q.ord) into versions from unnest(array[p3,p1]) with ordinality q(id,ord) join public.interview_participants ip on ip.interview_participant_id=q.id;
  r:=public.reorder_interview_participants(interview_id,array[p3,p1],versions); assert (r->>'success')::boolean,'reorder succeeds';
  assert (select count(distinct participant_order) from public.interview_participants where public.interview_participants.interview_id=test.interview_id and is_current)=2,'current participant orders remain unique';

  -- 11. CONFIRMED blocks ordinary schedule saves; operational resource conflicts are rejected.
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  r:=public.save_interview_schedule(interview_id,'2030-01-01 09:00+07','2030-01-01 10:00+07',fmt_id,room_id,null,null,null,v,gen_random_uuid()); assert (r->>'success')::boolean,'schedule saved';
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id; perform public.change_interview_schedule_status(interview_id,'CONFIRMED',v);
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id; r:=public.save_interview_schedule(interview_id,'2030-01-01 10:00+07','2030-01-01 11:00+07',fmt_id,room_id,null,null,null,v,gen_random_uuid()); assert (r->>'error_code')='INVALID_STATE','confirmed schedule protected';

  -- Independent candidate/session creates a true interviewer resource conflict.
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t002_c2_'||s||'@example.com',true) returning public.candidates.candidate_id into cand2;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,status_code) values(cand2,'Candidate Two','1991-01-01','FEMALE','Address','0900000001','t002_c2_'||s||'@example.com','PROCESSED') returning public.submissions.submission_id into sub2;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id,is_active) values(sub2,unit_id,pos_id,hr,true) returning public.applications.application_id into app2;
  insert into public.interviews(application_id,round_no,schedule_status_code,report_status_code,is_active) values(app2,1,'AVAILABLE','INTERVIEW_SCHEDULING',true) returning public.interviews.interview_id into conflict_interview;
  r:=public.add_interview_participant(conflict_interview,i1,gen_random_uuid()); assert (r->>'success')::boolean,'conflict fixture participant added';
  select version_no into v from public.interviews where public.interviews.interview_id=conflict_interview;
  r:=public.save_interview_schedule(conflict_interview,'2030-01-01 09:30+07','2030-01-01 10:30+07',fmt_id,room_id,null,null,null,v,gen_random_uuid()); assert (r->>'error_code') in ('SCHEDULE_CONFLICT_CANDIDATE','SCHEDULE_CONFLICT_ROOM','SCHEDULE_CONFLICT_INTERVIEWER'),'resource conflict rejected';
  r:=public.save_interview_schedule(conflict_interview,'2030-01-01 11:00+07','2030-01-01 12:00+07',fmt_id,room_id,null,null,null,v,gen_random_uuid()); assert (r->>'success')::boolean,'non-overlapping conflict fixture scheduled';
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  r:=public.reschedule_confirmed_interview(interview_id,'2030-01-01 11:30+07','2030-01-01 12:30+07',fmt_id,room_id,null,v,gen_random_uuid()); assert (r->>'success')::boolean=false,'confirmed reschedule conflict rejected';
  assert (select schedule_status_code from public.interviews where public.interviews.interview_id=test.interview_id)='CONFIRMED','failed reschedule retains confirmed state';
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  r:=public.reschedule_confirmed_interview(interview_id,'2030-01-01 10:00+07','2030-01-01 11:00+07',fmt_id,room_id,null,v,gen_random_uuid()); assert (r->>'success')::boolean,'confirmed reschedule succeeds'; assert (select schedule_status_code from public.interviews where public.interviews.interview_id=test.interview_id)='AWAITING','successful confirmed reschedule transitions to awaiting';

  -- 12. Cancelled to operational revalidates inactive participants.
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id; perform public.change_interview_schedule_status(interview_id,'CANCELLED',v);
  update public.app_users set is_active=false where app_user_id=i2;
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id; r:=public.change_interview_schedule_status(interview_id,'AWAITING',v); assert (r->>'error_code')='CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED','uncancelled inactive participant rejected';
  update public.app_users set is_active=true where app_user_id=i2;

  -- 13/14. Inactivation vs hard-delete cleanup and reactivation.
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  r:=public.delete_or_inactivate_interview(interview_id,v);
  assert (r->>'success')::boolean and (r->'data'->>'action')='INACTIVATED','latest round with history is inactivated';
  assert not (select is_active from public.interviews where public.interviews.interview_id=test.interview_id),'interview inactive';
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  r:=public.reactivate_interview(interview_id,v);
  assert (r->>'success')::boolean,'reactivate interview succeeds';
  assert (select is_active from public.interviews where public.interviews.interview_id=test.interview_id),'interview reactivated';

  -- Hard-delete empty latest round with upload reservation cleanup capture
  insert into public.interviews(application_id,round_no,schedule_status_code,report_status_code,is_active)
  values(app2,2,'AVAILABLE','INTERVIEW_SCHEDULING',true) returning public.interviews.interview_id into empty_int;
  r:=public.reserve_interview_upload(empty_int,doc_type);
  assert (r->>'success')::boolean,'reserved upload on empty round 2';
  res_id_empty := (r->'data'->>'upload_reservation_id')::uuid;
  select version_no into v from public.interviews where public.interviews.interview_id=empty_int;
  r:=public.delete_or_inactivate_interview(empty_int,v);
  assert (r->>'success')::boolean and (r->'data'->>'action')='DELETED','empty round 2 hard deleted';
  assert not exists(select 1 from public.interviews where public.interviews.interview_id=empty_int),'interview row deleted';
  assert not exists(select 1 from public.upload_reservations where upload_reservation_id=res_id_empty),'upload reservation removed';
  assert exists(select 1 from public.storage_cleanup_queue where source_parent_id=empty_int and reason_code='INTERVIEW_HARD_DELETE'),'storage cleanup queue row created';

  -- HR report note update
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  r:=public.update_hr_report_note(interview_id,'Updated note',v);
  assert (r->>'success')::boolean,'update hr report note succeeds';
  assert (select hr_report_note from public.interviews where public.interviews.interview_id=test.interview_id)='Updated note','hr report note verified';

  -- Report inactivate vs delete
  select version_no into v from public.interview_reports where interview_report_id=report1;
  r:=public.delete_or_inactivate_report(report1,v);
  assert (r->>'success')::boolean and (r->'data'->>'action')='INACTIVATED','used report inactivated';
  assert (select is_archived from public.interview_reports where interview_report_id=report1),'used report archived';
  update public.interview_reports set is_active=true,is_archived=false where interview_report_id=report1;
  insert into public.interview_reports(interview_participant_id,created_by,updated_by) values(p3,hr,hr) returning interview_report_id into empty_rep;
  select version_no into v from public.interview_reports where interview_report_id=empty_rep;
  r:=public.delete_or_inactivate_report(empty_rep,v);
  assert (r->>'success')::boolean and (r->'data'->>'action')='DELETED','empty report deleted';
  assert not exists(select 1 from public.interview_reports where interview_report_id=empty_rep),'empty report deleted from table';

  -- Bulk delete/inactivate
  insert into public.interviews(application_id,round_no,schedule_status_code,report_status_code,is_active)
  values(app2,2,'AVAILABLE','INTERVIEW_SCHEDULING',true) returning public.interviews.interview_id into bulk_int1;
  select version_no into v from public.interviews where public.interviews.interview_id=bulk_int1;
  r:=public.bulk_delete_or_inactivate_interviews(array[bulk_int1],array[v]);
  assert (r->>'success')::boolean,'bulk delete on empty round succeeds';
  -- 15. Document tables/current version invariant and fifth-file cap.
  update public.interviews set is_active=true,schedule_status_code='CANCELLED',updated_by=hr where public.interviews.interview_id=test.interview_id;
  r:=public.reserve_interview_upload(interview_id,doc_type); assert (r->>'success')::boolean,'upload reserved'; reservation_id:=(r->'data'->>'upload_reservation_id')::uuid;
  update public.upload_reservations set status_code='VALIDATED',malware_scan_status='CLEAN',detected_mime_type='application/pdf',actual_size_bytes=100,checksum_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' where upload_reservation_id=reservation_id;
  r:=public.finalize_interview_upload(reservation_id,null,'interview-private','t002/'||s||'/one.pdf','one.pdf','application/pdf',100,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null); assert (r->>'success')::boolean,'document finalized'; logical_id:=(r->'data'->>'logical_document_id')::uuid;
  r:=public.finalize_interview_upload(reservation_id,null,'interview-private','t002/'||s||'/one.pdf','one.pdf','application/pdf',100,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null); assert (r->>'success')::boolean,'identical finalize replay succeeds';
  r:=public.finalize_interview_upload(reservation_id,null,'interview-private','t002/'||s||'/one.pdf','one.pdf','application/pdf',101,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null); assert (r->>'error_code')='VALIDATION_ERROR','finalize replay rejects a changed payload';
  for n in 2..5 loop
    r:=public.reserve_interview_upload(interview_id,doc_type); reservation_id:=(r->'data'->>'upload_reservation_id')::uuid;
    update public.upload_reservations set status_code='VALIDATED',malware_scan_status='CLEAN',detected_mime_type='application/pdf',actual_size_bytes=100,checksum_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' where upload_reservation_id=reservation_id;
    r:=public.finalize_interview_upload(reservation_id,null,'interview-private','t002/'||s||'/'||n||'.pdf',n::text||'.pdf','application/pdf',100,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null);
    assert (r->>'success')::boolean,'first five current files are accepted';
  end loop;
  r:=public.reserve_interview_upload(interview_id,doc_type); reservation_id:=(r->'data'->>'upload_reservation_id')::uuid;
  update public.upload_reservations set status_code='VALIDATED',malware_scan_status='CLEAN',detected_mime_type='application/pdf',actual_size_bytes=100,checksum_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' where upload_reservation_id=reservation_id;
  r:=public.finalize_interview_upload(reservation_id,null,'interview-private','t002/'||s||'/six.pdf','six.pdf','application/pdf',100,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null);
  assert (r->>'error_code')='UPLOAD_LIMIT_EXCEEDED','sixth current file is rejected';
  insert into public.email_history(interview_id,application_id,submission_id,email_type,recipients,subject,sent_by)
  values(interview_id,app_id,sub_id,'INTERVIEW_INVITATION','[]'::jsonb,'T002 Interview',hr)
  returning public.email_history.email_history_id into email_history_id;
  insert into public.app_user_permissions(app_user_id,permission_code)
  values(hr,'emails.history_view'),(outsider,'emails.history_view'),(outsider,'applications.view') on conflict do nothing;
  err:=false; begin insert into public.interview_documents(logical_document_id,storage_bucket,storage_path,original_filename,mime_type,file_size_bytes,version_no,is_current,uploaded_by) values(logical_id,'interview-private','t002/'||s||'/duplicate.pdf','duplicate.pdf','application/pdf',100,2,true,hr); exception when unique_violation then err:=true; end; assert err,'one current version per logical document';
  -- 16/17. Comprehensive RLS visibility boundaries.
  -- Positive test: HR with permissions sees everything under authenticated role.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',hr_auth::text)::text,true); execute 'set local role authenticated';
  select count(*) into n from public.email_history eh where eh.email_history_id=test.email_history_id; assert n=1,'HR can select email history in its interview context';
  select count(*) into n from public.interview_document_logicals where logical_document_id=logical_id; assert n=1,'HR can select logical document';
  select count(*) into n from public.interview_documents where logical_document_id=logical_id; assert n=1,'HR can select interview document';
  select count(*) into n from public.interview_reports where interview_report_id=report1; assert n=1,'HR can select interview report'; execute 'reset role';

  -- Positive test: current participant sees session documents when visible.
  -- After F02 repair, raw interview_reports access is denied to Interviewers
  -- (they use the safe RPC get_interviewer_report_page instead).
  perform set_config('request.jwt.claims',jsonb_build_object('sub',i1_auth::text)::text,true); execute 'set local role authenticated';
  select count(*) into n from public.interview_document_logicals where logical_document_id=logical_id; assert n=1,'participant can select logical document';
  select count(*) into n from public.interview_reports where interview_report_id=report1; assert n=0,'participant must NOT select raw report (F02 confidentiality repair)';
  select count(*) into n from public.interview_documents where logical_document_id=logical_id; assert n=1,'participant can select interview document';

  -- Negative test: non-participant outsider denied on all three.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider_auth::text)::text,true); execute 'set local role authenticated';
  select count(*) into n from public.email_history eh where eh.email_history_id=test.email_history_id; assert n=0,'cross-context email history is denied even with history permission';
  select count(*) into n from public.interview_document_logicals where logical_document_id=logical_id; assert n=0,'outsider denied on logical document';
  select count(*) into n from public.interview_reports where interview_report_id=report1; assert n=0,'non-participant cannot select report';
  select count(*) into n from public.interview_documents where logical_document_id=logical_id; assert n=0,'non-participant cannot select document'; execute 'reset role';

  -- Negative test: participant on session with visible_to_interviewers = false is denied.
  update public.interviews set visible_to_interviewers=false where public.interviews.interview_id=test.interview_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',i1_auth::text)::text,true); execute 'set local role authenticated';
  select count(*) into n from public.interview_document_logicals where logical_document_id=logical_id; assert n=0,'hidden session logical doc denied to participant';
  select count(*) into n from public.interview_documents where logical_document_id=logical_id; assert n=0,'hidden session document denied to participant';
  select count(*) into n from public.interview_reports where interview_report_id=report1; assert n=0,'hidden session report denied to participant'; execute 'reset role';
  update public.interviews set visible_to_interviewers=true where public.interviews.interview_id=test.interview_id;

  -- SECURITY DEFINER helpers are internal-only even when a user is authenticated.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',hr_auth::text)::text,true); execute 'set local role authenticated';
  err:=false; begin perform private.audit_interview_command('FORGED','INTERVIEW',interview_id,hr,null,'{}'); exception when insufficient_privilege then err:=true; end; assert err,'authenticated cannot forge interview audit rows';
  err:=false; begin perform private.delete_or_inactivate_interview_core(interview_id,0,hr); exception when insufficient_privilege then err:=true; end; assert err,'authenticated cannot invoke private interview delete helper';
  execute 'reset role';
  -- 18. Bulk status change is all-or-nothing with multiple Interviews.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',hr_auth::text)::text,true);
  update public.interviews set schedule_status_code='CANCELLED' where public.interviews.interview_id in (test.interview_id, conflict_interview);
  update public.app_users set is_active=false where app_user_id=i2;
  select version_no into v from public.interviews where public.interviews.interview_id=test.interview_id;
  select version_no into v2 from public.interviews where public.interviews.interview_id=conflict_interview;
  r:=public.bulk_change_interview_schedule_status(array[interview_id, conflict_interview],'AWAITING',array[v, v2]);
  assert (r->>'error_code')='CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED','multi-item bulk status fails all-or-nothing on inactive participant';
  assert (select schedule_status_code from public.interviews where public.interviews.interview_id=test.interview_id)='CANCELLED','first item status unchanged';
  assert (select schedule_status_code from public.interviews where public.interviews.interview_id=conflict_interview)='CANCELLED','second item status unchanged';
  update public.app_users set is_active=true where app_user_id=i2;
  raise notice '=== TASK-S04-002 Interview Lifecycle Test Suite PASSED ===';
end $$;
