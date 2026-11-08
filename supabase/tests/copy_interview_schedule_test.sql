-- TASK-S04-003: public copy_interview_schedule consumer-observable integration coverage
-- Run against an unlinked disposable local Supabase database after migration replay.
\set ON_ERROR_STOP on

begin;
do $$
<<test>>
declare
  s text := substr(gen_random_uuid()::text,1,8);
  hr_auth uuid := gen_random_uuid(); hr uuid;
  manage_auth uuid := gen_random_uuid(); manage_only uuid;
  view_auth uuid := gen_random_uuid(); view_only uuid;
  i1 uuid; i2 uuid; inactive uuid;
  unit_id uuid; group_id uuid; position_id uuid; position2_id uuid; position3_id uuid; room_id uuid; room2_id uuid; format_id uuid; doc_type uuid;
  candidate_id uuid; candidate2_id uuid; submission_id uuid; submission2_id uuid;
  source_app uuid; target_app uuid; same_app uuid; source_id uuid; target_r1 uuid; same_r1 uuid;
  same_empty_app uuid; same_empty_r1 uuid; same_empty_r2 uuid;
  incoming_app uuid; incoming_r1 uuid; incoming_child_app uuid; incoming_child uuid;
  v bigint; target_app_v bigint; target_r1_v bigint; r jsonb; copied_id uuid; before_note text;
  v_round1 jsonb; v_artifact jsonb; v_round1_after jsonb; v_artifact_after jsonb;
  conflict_app uuid; conflict_r1 uuid; inactive_app uuid; inactive_r1 uuid;
  usage_app uuid; usage_r1 uuid; usage_r2 uuid; usage_kind text;
  replay_key uuid := gen_random_uuid(); raised boolean;
begin
  raise notice '=== Running TASK-S04-003 Copy Interview Schedule Test Suite ===';
  insert into public.organizational_units(code,name_vi) values ('T003_U_'||s,'T003 Unit') returning public.organizational_units.unit_id into unit_id;
  insert into public.position_groups(code,name_vi) values ('T003_G_'||s,'T003 Group') returning public.position_groups.position_group_id into group_id;
  insert into public.positions(unit_id,position_group_id,code,name_vi) values(unit_id,group_id,'T003_P_'||s,'T003 Position') returning public.positions.position_id into position_id;
  insert into public.positions(unit_id,position_group_id,code,name_vi) values(unit_id,group_id,'T003_P2_'||s,'T003 Position 2') returning public.positions.position_id into position2_id;
  insert into public.positions(unit_id,position_group_id,code,name_vi) values(unit_id,group_id,'T003_P3_'||s,'T003 Position 3') returning public.positions.position_id into position3_id;
  insert into public.rooms(code,display_name) values('T003_R_'||s,'T003 Room') returning public.rooms.room_id into room_id;
  insert into public.rooms(code,display_name) values('T003_R2_'||s,'T003 Room 2') returning public.rooms.room_id into room2_id;
  insert into public.interview_formats(code,name_vi,requires_room,requires_meeting_link) values('T003_F_'||s,'T003 In person',true,false) returning public.interview_formats.interview_format_id into format_id;
  insert into public.document_types(code,name_vi,scope_code) values('T003_D_'||s,'T003 Document','INTERVIEW') returning public.document_types.document_type_id into doc_type;
  insert into public.app_users(auth_user_id,full_name,email,is_active) values(hr_auth,'T003 HR','t003_hr_'||s||'@eiu.edu.vn',true) returning public.app_users.app_user_id into hr;
  insert into public.app_user_roles(app_user_id,role_code) values(hr,'HR');
  insert into public.app_user_permissions(app_user_id,permission_code) values(hr,'interviews.view'),(hr,'interviews.manage') on conflict do nothing;
  insert into public.app_users(auth_user_id,full_name,email,is_active) values(manage_auth,'T003 Manage','t003_manage_'||s||'@eiu.edu.vn',true) returning public.app_users.app_user_id into manage_only;
  insert into public.app_user_permissions(app_user_id,permission_code) values(manage_only,'interviews.manage') on conflict do nothing;
  insert into public.app_users(auth_user_id,full_name,email,is_active) values(view_auth,'T003 View','t003_view_'||s||'@eiu.edu.vn',true) returning public.app_users.app_user_id into view_only;
  insert into public.app_user_permissions(app_user_id,permission_code) values(view_only,'interviews.view') on conflict do nothing;
  insert into public.app_users(auth_user_id,full_name,job_title,email,is_active) values(gen_random_uuid(),'T003 Interviewer 1','Lecturer','t003_i1_'||s||'@eiu.edu.vn',true) returning public.app_users.app_user_id into i1;
  insert into public.app_users(auth_user_id,full_name,job_title,email,is_active) values(gen_random_uuid(),'T003 Interviewer 2','Professor','t003_i2_'||s||'@eiu.edu.vn',true) returning public.app_users.app_user_id into i2;
  insert into public.app_users(auth_user_id,full_name,email,is_active) values(gen_random_uuid(),'T003 Inactive','t003_inactive_'||s||'@eiu.edu.vn',false) returning public.app_users.app_user_id into inactive;
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_c1_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate_id;
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_c2_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate2_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate_id,'T003 Candidate 1','1990-01-01','MALE','Address','0900000000','t003_c1_'||s||'@example.com') returning public.submissions.submission_id into submission_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate2_id,'T003 Candidate 2','1991-01-01','FEMALE','Address','0900000001','t003_c2_'||s||'@example.com') returning public.submissions.submission_id into submission2_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission_id,unit_id,position_id,hr) returning public.applications.application_id into source_app;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission2_id,unit_id,position_id,hr) returning public.applications.application_id into target_app;
  insert into public.interviews(application_id,round_no,start_at,end_at,interview_format_id,room_id,interview_note) values(source_app,1,'2035-01-01 09:00+07','2035-01-01 10:00+07',format_id,room_id,'source logistics') returning public.interviews.interview_id into source_id;
  insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email) values
    (source_id,i2,1,'Historic Two',null,'historic2_'||s||'@eiu.edu.vn'),
    (source_id,i1,2,'Historic One','Historic Lecturer','historic1_'||s||'@eiu.edu.vn');
  insert into public.interviews(application_id,round_no) values(target_app,1) returning public.interviews.interview_id into target_r1;
  same_app:=source_app;
  same_r1:=source_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',hr_auth::text)::text,true);

  select version_no into v from public.interviews where interview_id=source_id;
  select version_no into target_app_v from public.applications where application_id=target_app;
  select version_no into target_r1_v from public.interviews where interview_id=target_r1;
  r:=public.copy_interview_schedule(source_id,target_app,v,target_app_v,target_r1,target_r1_v,'2035-01-02 09:00+07','2035-01-02 10:00+07',format_id,room_id,null,'copied logistics',array[i2,i1],replay_key);
  assert (r->>'success')::boolean,'authorized cross-application copy succeeds'; copied_id:=(r->'data'->>'interview_id')::uuid;
  assert copied_id=target_r1 and (select copied_from_interview_id from public.interviews where interview_id=copied_id)=source_id,'empty target Round 1 is filled with provenance';
  assert (select demo_topic is null and interview_note='copied logistics' and start_at='2035-01-02 09:00+07'::timestamptz from public.interviews where interview_id=copied_id),'logistics copied and demo topic blank';
  assert (select array_agg(snapshot_name order by participant_order) from public.interview_participants where interview_id=copied_id)=array['Historic Two','Historic One'],'participant snapshots and order copied';
  assert (select snapshot_job_title is null from public.interview_participants where interview_id=copied_id and app_user_id=i2),'null source job-title snapshot is preserved instead of directory fallback';
  r:=public.copy_interview_schedule(source_id,target_app,v,target_app_v,target_r1,target_r1_v,'2035-01-02 09:00+07','2035-01-02 10:00+07',format_id,room_id,null,'copied logistics',array[i2,i1],replay_key);
  assert (r->'data'->>'interview_id')::uuid=copied_id and (select count(*) from public.interviews where application_id=target_app)=1,'same idempotency replay returns persisted result';
  raised:=false; begin
    perform public.copy_interview_schedule(source_id,target_app,v,(select version_no from public.applications where application_id=target_app),copied_id,(select version_no from public.interviews where interview_id=copied_id),'2035-01-02 10:00+07','2035-01-02 11:00+07',format_id,room_id,null,'changed',array[i2,i1],replay_key);
  exception when check_violation then raised:=true; end;
  assert raised,'different idempotency replay fails closed';

  -- A structurally empty source/target Round 1 is still never filled for a
  -- same-Application copy: the command allocates Round 2 and applies the draft.
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_same_empty_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate2_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate2_id,'T003 Same Empty','1990-01-01','MALE','Address','0900000002','t003_same_empty_'||s||'@example.com') returning public.submissions.submission_id into submission2_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission2_id,unit_id,position2_id,hr) returning public.applications.application_id into same_empty_app;
  insert into public.interviews(application_id,round_no) values(same_empty_app,1) returning public.interviews.interview_id into same_empty_r1;
  assert private.is_structurally_empty_default_round(same_empty_r1),'same-application Round 1 starts structurally empty';
  select to_jsonb(i) into v_round1 from public.interviews i where i.interview_id=same_empty_r1;
  select version_no into v from public.interviews where interview_id=same_empty_r1;
  r:=public.copy_interview_schedule(same_empty_r1,same_empty_app,v,(select version_no from public.applications where application_id=same_empty_app),same_empty_r1,v,'2035-01-04 09:00+07','2035-01-04 10:00+07',format_id,room_id,null,'same empty logistics',array[i2,i1],gen_random_uuid());
  same_empty_r2:=(r->'data'->>'interview_id')::uuid;
  assert (r->>'success')::boolean and (select round_no from public.interviews where interview_id=same_empty_r2)=2,'structurally empty same-application Round 1 allocates Round 2';
  select to_jsonb(i) into v_round1_after from public.interviews i where i.interview_id=same_empty_r1;
  assert v_round1_after=v_round1,'same-application Round 1 fields remain unchanged';
  assert (select i.start_at='2035-01-04 09:00+07'::timestamptz and i.end_at='2035-01-04 10:00+07'::timestamptz and i.interview_format_id=test.format_id and i.room_id=test.room_id and i.meeting_link is null and i.interview_note='same empty logistics' and i.copied_from_interview_id=test.same_empty_r1 and i.demo_topic is null from public.interviews i where i.interview_id=test.same_empty_r2),'same-application Round 2 preserves normalized schedule, provenance, note, and blank demo topic';
  assert (select jsonb_agg(jsonb_build_object('participant_id',ip.app_user_id,'full_name',ip.snapshot_name,'job_title',ip.snapshot_job_title,'email',ip.snapshot_email,'display_order',ip.participant_order) order by ip.participant_order) from public.interview_participants ip where ip.interview_id=test.same_empty_r2)=jsonb_build_array(jsonb_build_object('participant_id',test.i2,'full_name','T003 Interviewer 2','job_title','Professor','email','t003_i2_'||test.s||'@eiu.edu.vn','display_order',1),jsonb_build_object('participant_id',test.i1,'full_name','T003 Interviewer 1','job_title','Lecturer','email','t003_i1_'||test.s||'@eiu.edu.vn','display_order',2)),'same-application Round 2 preserves every selected participant snapshot field and order';

  -- Same-Application Copy always allocates the next legal round, even when Round 1 is empty.
  select version_no into v from public.interviews where interview_id=source_id;
  r:=public.copy_interview_schedule(source_id,same_app,v,(select version_no from public.applications where application_id=same_app),same_r1,(select version_no from public.interviews where interview_id=same_r1),'2035-01-03 09:00+07','2035-01-03 10:00+07',format_id,room_id,null,'same app',array[i1],gen_random_uuid());
  assert (r->>'success')::boolean and (r->'data'->>'round_no')::integer=2,'same-application copy allocates Round 2';
  assert (select copied_from_interview_id is null from public.interviews where interview_id=same_r1),'same-application copy leaves Round 1 unchanged';

  -- Every structural-empty exclusion forces allocation and leaves target Round 1 unchanged.
  foreach usage_kind in array array['PARTICIPANT','REPORT','DOCUMENT','OUTBOX','HISTORY','PROVENANCE'] loop
    insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_usage_'||usage_kind||'_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate2_id;
    insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate2_id,'T003 Used','1990-01-01','MALE','Address','0900000002','t003_usage_'||usage_kind||'_'||s||'@example.com') returning public.submissions.submission_id into submission2_id;
    insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission2_id,unit_id,position_id,hr) returning public.applications.application_id into usage_app;
    insert into public.interviews(application_id,round_no) values(usage_app,1) returning public.interviews.interview_id into usage_r1;
    if usage_kind='PARTICIPANT' then insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_email) values(usage_r1,i1,1,'Used','used_'||s||'@eiu.edu.vn');
    elsif usage_kind='REPORT' then insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_email) values(usage_r1,i1,1,'Used','usedr_'||s||'@eiu.edu.vn'); insert into public.interview_reports(interview_participant_id,created_by,updated_by) select interview_participant_id,hr,hr from public.interview_participants where interview_id=usage_r1;
    elsif usage_kind='DOCUMENT' then insert into public.interview_document_logicals(interview_id,document_type_id,created_by) values(usage_r1,doc_type,hr);
    elsif usage_kind='OUTBOX' then insert into public.email_outbox(interview_id,email_type,recipients,subject,body_html,idempotency_key,actor_scope) values(usage_r1,'TEST','[]','subject','body',gen_random_uuid(),'test:'||s);
    elsif usage_kind='HISTORY' then insert into public.email_history(interview_id,email_type,recipients,subject) values(usage_r1,'TEST','[]','subject');
    else update public.interviews set copied_from_interview_id=source_id where interview_id=usage_r1; end if;
    select to_jsonb(i) into v_round1 from public.interviews i where i.interview_id=usage_r1;
    select jsonb_build_object(
      'participants',coalesce((select jsonb_agg(to_jsonb(ip) order by ip.interview_participant_id) from public.interview_participants ip where ip.interview_id=usage_r1),'[]'::jsonb),
      'reports',coalesce((select jsonb_agg(to_jsonb(ir) order by ir.interview_report_id) from public.interview_reports ir join public.interview_participants ip on ip.interview_participant_id=ir.interview_participant_id where ip.interview_id=usage_r1),'[]'::jsonb),
      'documents',coalesce((select jsonb_agg(to_jsonb(dl) order by dl.logical_document_id) from public.interview_document_logicals dl where dl.interview_id=usage_r1),'[]'::jsonb),
      'outbox',coalesce((select jsonb_agg(to_jsonb(eo) order by eo.email_outbox_id) from public.email_outbox eo where eo.interview_id=usage_r1),'[]'::jsonb),
      'history',coalesce((select jsonb_agg(to_jsonb(eh) order by eh.email_history_id) from public.email_history eh where eh.interview_id=usage_r1),'[]'::jsonb),
      'reverse_copies',coalesce((select jsonb_agg(to_jsonb(child) order by child.interview_id) from public.interviews child where child.copied_from_interview_id=usage_r1),'[]'::jsonb)
    ) into v_artifact;
    select version_no into v from public.interviews where interview_id=source_id;
    r:=public.copy_interview_schedule(source_id,usage_app,v,(select version_no from public.applications where application_id=usage_app),usage_r1,(select version_no from public.interviews where interview_id=usage_r1),'2035-02-01 09:00+07'::timestamptz + array_position(array['PARTICIPANT','REPORT','DOCUMENT','OUTBOX','HISTORY','PROVENANCE'],usage_kind)*interval '2 hours','2035-02-01 10:00+07'::timestamptz + array_position(array['PARTICIPANT','REPORT','DOCUMENT','OUTBOX','HISTORY','PROVENANCE'],usage_kind)*interval '2 hours',format_id,room_id,null,'new',array[]::uuid[],gen_random_uuid());
    usage_r2:=(r->'data'->>'interview_id')::uuid;
    assert (r->>'success')::boolean and usage_r2<>usage_r1 and (select round_no from public.interviews where interview_id=usage_r2)=2,'used Round 1 exclusion allocates Round 2: '||usage_kind;
    select to_jsonb(i) into v_round1_after from public.interviews i where i.interview_id=usage_r1;
    select jsonb_build_object(
      'participants',coalesce((select jsonb_agg(to_jsonb(ip) order by ip.interview_participant_id) from public.interview_participants ip where ip.interview_id=usage_r1),'[]'::jsonb),
      'reports',coalesce((select jsonb_agg(to_jsonb(ir) order by ir.interview_report_id) from public.interview_reports ir join public.interview_participants ip on ip.interview_participant_id=ir.interview_participant_id where ip.interview_id=usage_r1),'[]'::jsonb),
      'documents',coalesce((select jsonb_agg(to_jsonb(dl) order by dl.logical_document_id) from public.interview_document_logicals dl where dl.interview_id=usage_r1),'[]'::jsonb),
      'outbox',coalesce((select jsonb_agg(to_jsonb(eo) order by eo.email_outbox_id) from public.email_outbox eo where eo.interview_id=usage_r1),'[]'::jsonb),
      'history',coalesce((select jsonb_agg(to_jsonb(eh) order by eh.email_history_id) from public.email_history eh where eh.interview_id=usage_r1),'[]'::jsonb),
      'reverse_copies',coalesce((select jsonb_agg(to_jsonb(child) order by child.interview_id) from public.interviews child where child.copied_from_interview_id=usage_r1),'[]'::jsonb)
    ) into v_artifact_after;
    assert v_round1_after=v_round1 and v_artifact_after=v_artifact,'used Round 1 and usage artifact remain unchanged: '||usage_kind;
  end loop;
  -- Incoming/reverse provenance is independently business-used: Copy must not
  -- overwrite the referenced Round 1 or disturb the reverse reference.
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_incoming_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate2_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate2_id,'T003 Incoming','1990-01-01','MALE','Address','0900000005','t003_incoming_'||s||'@example.com') returning public.submissions.submission_id into submission2_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission2_id,unit_id,position2_id,hr) returning public.applications.application_id into incoming_app;
  insert into public.interviews(application_id,round_no) values(incoming_app,1) returning public.interviews.interview_id into incoming_r1;
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_reverse_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate2_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate2_id,'T003 Reverse','1990-01-01','MALE','Address','0900000006','t003_reverse_'||s||'@example.com') returning public.submissions.submission_id into submission2_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission2_id,unit_id,position3_id,hr) returning public.applications.application_id into incoming_child_app;
  insert into public.interviews(application_id,round_no,copied_from_interview_id) values(incoming_child_app,1,incoming_r1) returning public.interviews.interview_id into incoming_child;
  select to_jsonb(i) into v_round1 from public.interviews i where i.interview_id=incoming_r1;
  select to_jsonb(i) into v_artifact from public.interviews i where i.interview_id=incoming_child;
  select version_no into v from public.interviews where interview_id=source_id;
  r:=public.copy_interview_schedule(source_id,incoming_app,v,(select version_no from public.applications where application_id=incoming_app),incoming_r1,(select version_no from public.interviews where interview_id=incoming_r1),'2035-02-20 09:00+07','2035-02-20 10:00+07',format_id,room_id,null,'incoming provenance',array[]::uuid[],gen_random_uuid());
  usage_r2:=(r->'data'->>'interview_id')::uuid;
  assert (r->>'success')::boolean and usage_r2<>incoming_r1 and (select round_no from public.interviews where interview_id=usage_r2)=2,'incoming provenance allocates next legal round';
  select to_jsonb(i) into v_round1_after from public.interviews i where i.interview_id=incoming_r1;
  select to_jsonb(i) into v_artifact_after from public.interviews i where i.interview_id=incoming_child;
  assert v_round1_after=v_round1 and v_artifact_after=v_artifact,'incoming provenance Round 1 and reverse reference remain unchanged';

  -- Version mismatches, including a later competing round, fail before mutation.
  select version_no into v from public.interviews where interview_id=source_id;
  r:=public.copy_interview_schedule(source_id,same_app,v-1,(select version_no from public.applications where application_id=same_app),same_r1,(select version_no from public.interviews where interview_id=same_r1),'2035-03-01 09:00+07','2035-03-01 10:00+07',format_id,room_id,null,'stale',array[]::uuid[],gen_random_uuid()); assert r->>'error_code'='STALE_VERSION','stale source rejected';
  r:=public.copy_interview_schedule(source_id,same_app,v,0,same_r1,(select version_no from public.interviews where interview_id=same_r1),'2035-03-01 09:00+07','2035-03-01 10:00+07',format_id,room_id,null,'stale',array[]::uuid[],gen_random_uuid()); assert r->>'error_code'='STALE_VERSION','stale application rejected';
  r:=public.copy_interview_schedule(source_id,same_app,v,(select version_no from public.applications where application_id=same_app),same_r1,0,'2035-03-01 09:00+07','2035-03-01 10:00+07',format_id,room_id,null,'stale',array[]::uuid[],gen_random_uuid()); assert r->>'error_code'='STALE_VERSION','stale target round rejected';
  insert into public.interviews(application_id,round_no) values(same_app,3);
  r:=public.copy_interview_schedule(source_id,same_app,v,(select version_no from public.applications where application_id=same_app),same_r1,(select version_no from public.interviews where interview_id=same_r1),'2035-03-01 09:00+07','2035-03-01 10:00+07',format_id,room_id,null,'stale',array[]::uuid[],gen_random_uuid()); assert r->>'error_code'='STALE_VERSION','competing later round rejected';
  -- Candidate, Room, Interviewer conflicts and inactive target/participant all
  -- reject before changing the structurally empty target Round 1.
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission_id,unit_id,position3_id,hr) returning public.applications.application_id into conflict_app;
  insert into public.interviews(application_id,round_no) values(conflict_app,1) returning public.interviews.interview_id into conflict_r1;
  r:=public.copy_interview_schedule(source_id,conflict_app,v,(select version_no from public.applications where application_id=conflict_app),conflict_r1,(select version_no from public.interviews where interview_id=conflict_r1),'2035-01-01 09:30+07','2035-01-01 10:30+07',format_id,room_id,null,'candidate conflict',array[]::uuid[],gen_random_uuid());
  assert r->>'error_code'='SCHEDULE_CONFLICT_CANDIDATE' and private.is_structurally_empty_default_round(conflict_r1),'candidate conflict rolls back target';
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_room_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate2_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate2_id,'T003 Room','1990-01-01','MALE','Address','0900000003','t003_room_'||s||'@example.com') returning public.submissions.submission_id into submission2_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission2_id,unit_id,position_id,hr) returning public.applications.application_id into inactive_app;
  insert into public.interviews(application_id,round_no) values(inactive_app,1) returning public.interviews.interview_id into inactive_r1;
  r:=public.copy_interview_schedule(source_id,inactive_app,v,(select version_no from public.applications where application_id=inactive_app),inactive_r1,(select version_no from public.interviews where interview_id=inactive_r1),'2035-01-01 09:30+07','2035-01-01 10:30+07',format_id,room_id,null,'room conflict',array[]::uuid[],gen_random_uuid());
  assert r->>'error_code'='SCHEDULE_CONFLICT_ROOM' and private.is_structurally_empty_default_round(inactive_r1),'room conflict rolls back target';
  r:=public.copy_interview_schedule(source_id,inactive_app,v,(select version_no from public.applications where application_id=inactive_app),inactive_r1,(select version_no from public.interviews where interview_id=inactive_r1),'2035-01-01 09:30+07','2035-01-01 10:30+07',format_id,room2_id,null,'interviewer conflict',array[i1],gen_random_uuid());
  assert r->>'error_code'='SCHEDULE_CONFLICT_INTERVIEWER' and private.is_structurally_empty_default_round(inactive_r1),'interviewer conflict rolls back target';
  insert into public.candidates(auth_user_id,email,is_active) values(gen_random_uuid(),'t003_inactive_'||s||'@example.com',true) returning public.candidates.candidate_id into candidate2_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot) values(candidate2_id,'T003 Inactive','1990-01-01','MALE','Address','0900000004','t003_inactive_'||s||'@example.com') returning public.submissions.submission_id into submission2_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(submission2_id,unit_id,position2_id,hr) returning public.applications.application_id into inactive_app;
  insert into public.interviews(application_id,round_no) values(inactive_app,1) returning public.interviews.interview_id into inactive_r1;
  r:=public.copy_interview_schedule(source_id,inactive_app,v,(select version_no from public.applications where application_id=inactive_app),inactive_r1,(select version_no from public.interviews where interview_id=inactive_r1),'2035-04-01 09:00+07','2035-04-01 10:00+07',format_id,room_id,null,'inactive participant',array[inactive],gen_random_uuid());
  assert r->>'error_code'='CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED' and private.is_structurally_empty_default_round(inactive_r1),'inactive participant rolls back target with canonical error';
  update public.applications set is_active=false where application_id=inactive_app;
  r:=public.copy_interview_schedule(source_id,inactive_app,v,(select version_no from public.applications where application_id=inactive_app),inactive_r1,(select version_no from public.interviews where interview_id=inactive_r1),'2035-04-01 09:00+07','2035-04-01 10:00+07',format_id,room_id,null,'inactive target',array[]::uuid[],gen_random_uuid());
  assert r->>'error_code'='APPLICATION_INACTIVE','inactive target application rejected';
  perform set_config('request.jwt.claims','{}',true);
  r:=public.copy_interview_schedule(source_id,target_app,v,(select version_no from public.applications where application_id=target_app),copied_id,(select version_no from public.interviews where interview_id=copied_id),'2035-05-01 09:00+07','2035-05-01 10:00+07',format_id,room_id,null,'auth',array[]::uuid[],gen_random_uuid()); assert r->>'error_code'='UNAUTHENTICATED','unauthenticated caller denied';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',manage_auth::text)::text,true);
  r:=public.copy_interview_schedule(source_id,target_app,v,(select version_no from public.applications where application_id=target_app),copied_id,(select version_no from public.interviews where interview_id=copied_id),'2035-05-01 09:00+07','2035-05-01 10:00+07',format_id,room_id,null,'auth',array[]::uuid[],gen_random_uuid()); assert r->>'error_code'='FORBIDDEN','manage-only caller denied';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',view_auth::text)::text,true);
  r:=public.copy_interview_schedule(source_id,target_app,v,(select version_no from public.applications where application_id=target_app),copied_id,(select version_no from public.interviews where interview_id=copied_id),'2035-05-01 09:00+07','2035-05-01 10:00+07',format_id,room_id,null,'auth',array[]::uuid[],gen_random_uuid()); assert r->>'error_code'='FORBIDDEN','view-only caller denied';
  execute 'set local role authenticated';
  raised:=false; begin insert into public.interviews(application_id,round_no) values(target_app,99); exception when insufficient_privilege then raised:=true; end;
  execute 'reset role';
  assert raised,'direct table DML denied to authenticated caller';
end;
$$;
rollback;

-- Direct DML is denied to authenticated callers. The migration test block above
-- runs as postgres to create fixtures, while production callers only receive RPC execute.
do $$
begin
  raise notice '=== TASK-S04-003 Copy Interview Schedule Test Suite PASSED ===';
end;
$$;
