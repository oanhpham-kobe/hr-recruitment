-- TASK-S04-005: public command signatures, authorization, reactivation safety, and rollback.
\set ON_ERROR_STOP on

begin;
do $$
<<test>>
declare
  s text := substr(gen_random_uuid()::text,1,8);
  root_auth uuid; root_user uuid;
  manage_auth uuid := gen_random_uuid(); manage_user uuid;
  view_auth uuid := gen_random_uuid(); view_user uuid;
  participant_auth uuid := gen_random_uuid(); participant_user uuid;
  participant_only_auth uuid := gen_random_uuid(); participant_only_user uuid;
  manage_view_auth uuid := gen_random_uuid(); manage_view_user uuid;
  interviewer_auth uuid := gen_random_uuid(); interviewer uuid;
  inactive_auth uuid := gen_random_uuid(); inactive_user uuid;
  unit_id uuid; group_id uuid; pos1 uuid; pos2 uuid; pos3 uuid; pos4 uuid; room1 uuid; room2 uuid; format_id uuid;
  candidate_id uuid; candidate2_id uuid; submission_id uuid; submission2_id uuid;
  app_id uuid; app2_id uuid; interview_id uuid; conflict_id uuid; participant_id uuid;
  r jsonb; v bigint; audit_count integer; function_count integer; v_idempotency_key uuid; v_legacy_result jsonb;
begin
  raise notice '=== Running TASK-S04-005 command repair regression ===';

  -- Exact surface: no stale overloads remain.
  select count(*) into function_count from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='add_interview_participant';
  assert function_count=1 and exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='add_interview_participant' and oidvectortypes(p.proargtypes)='uuid, uuid, uuid'), 'add has exactly uuid,uuid,uuid';
  select count(*) into function_count from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='remove_interview_participant';
  assert function_count=1 and exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='remove_interview_participant' and oidvectortypes(p.proargtypes)='uuid, bigint'), 'remove has exactly uuid,bigint';
  select count(*) into function_count from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='readd_interview_participant';
  assert function_count=1 and exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='readd_interview_participant' and oidvectortypes(p.proargtypes)='uuid, text, uuid'), 'readd has exactly uuid,text,uuid';
  select count(*) into function_count from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='reorder_interview_participants';
  assert function_count=1 and exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='reorder_interview_participants' and oidvectortypes(p.proargtypes)='uuid, uuid[], bigint[]'), 'reorder has exactly uuid,uuid[],bigint[]';
  assert exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='reorder_interview_participants'
      and p.proargnames=array['p_interview_id','p_ordered_participant_ids','p_expected_versions']
  ), 'reorder retains PostgREST-visible named parameters';

  insert into public.organizational_units(code,name_vi) values ('T005_U_'||s,'T005 Unit') returning public.organizational_units.unit_id into unit_id;
  insert into public.position_groups(code,name_vi) values ('T005_G_'||s,'T005 Group') returning position_group_id into group_id;
  insert into public.positions(unit_id,position_group_id,code,name_vi) values
    (unit_id,group_id,'T005_P1_'||s,'T005 Position 1'),(unit_id,group_id,'T005_P2_'||s,'T005 Position 2'),
    (unit_id,group_id,'T005_P3_'||s,'T005 Position 3'),(unit_id,group_id,'T005_P4_'||s,'T005 Position 4');
  select position_id into pos1 from public.positions where code='T005_P1_'||s;
  select position_id into pos2 from public.positions where code='T005_P2_'||s;
  select position_id into pos3 from public.positions where code='T005_P3_'||s;
  select position_id into pos4 from public.positions where code='T005_P4_'||s;
  insert into public.rooms(code,display_name) values ('T005_R1_'||s,'T005 Room 1'),('T005_R2_'||s,'T005 Room 2');
  select room_id into room1 from public.rooms where code='T005_R1_'||s;
  select room_id into room2 from public.rooms where code='T005_R2_'||s;
  insert into public.interview_formats(code,name_vi,requires_room) values ('T005_F_'||s,'T005 In Person',true) returning public.interview_formats.interview_format_id into format_id;

  select app_user_id,auth_user_id into root_user,root_auth
  from public.app_users
  where is_root_admin and is_active and auth_user_id is not null
  order by app_user_id
  limit 1;
  if root_user is null then
    root_auth:=gen_random_uuid();
    insert into public.app_users(auth_user_id,full_name,email,is_active,is_root_admin)
    values(root_auth,'T005 Root','t005_root_'||s||'@eiu.edu.vn',true,true)
    returning app_user_id into root_user;
  end if;

  insert into public.app_users(auth_user_id,full_name,email,is_active,is_root_admin) values
    (manage_auth,'T005 Manage','t005_manage_'||s||'@eiu.edu.vn',true,false),
    (view_auth,'T005 View','t005_view_'||s||'@eiu.edu.vn',true,false),
    (participant_auth,'T005 Participant','t005_participant_'||s||'@eiu.edu.vn',true,false),
    (participant_only_auth,'T005 Participant Only','t005_participant_only_'||s||'@eiu.edu.vn',true,false),
    (manage_view_auth,'T005 Manage View','t005_manage_view_'||s||'@eiu.edu.vn',true,false),
    (interviewer_auth,'T005 Interviewer','t005_interviewer_'||s||'@eiu.edu.vn',true,false),
    (inactive_auth,'T005 Inactive','t005_inactive_'||s||'@eiu.edu.vn',false,false);
  select app_user_id into manage_user from public.app_users where auth_user_id=manage_auth;
  select app_user_id into view_user from public.app_users where auth_user_id=view_auth;
  select app_user_id into participant_user from public.app_users where auth_user_id=participant_auth;
  select app_user_id into participant_only_user from public.app_users where auth_user_id=participant_only_auth;
  select app_user_id into manage_view_user from public.app_users where auth_user_id=manage_view_auth;
  select app_user_id into interviewer from public.app_users where auth_user_id=interviewer_auth;
  select app_user_id into inactive_user from public.app_users where auth_user_id=inactive_auth;
  insert into public.app_user_roles(app_user_id,role_code) values (root_user,'HR'),(manage_user,'HR') on conflict do nothing;
  insert into public.app_user_permissions(app_user_id,permission_code) values
    (manage_user,'applications.manage'),(manage_user,'applications.view'),
    (view_user,'applications.view'),
    (participant_user,'interviews.participants'),(participant_user,'interviews.view'),
    (participant_only_user,'interviews.participants'),
    (manage_view_user,'interviews.manage'),(manage_view_user,'interviews.view')
  on conflict do nothing;

  insert into public.candidates(auth_user_id,email,is_active) values
    (gen_random_uuid(),'t005_c1_'||s||'@example.com',true),(gen_random_uuid(),'t005_c2_'||s||'@example.com',true);
  select c.candidate_id into candidate_id from public.candidates c where c.email='t005_c1_'||s||'@example.com';
  select c.candidate_id into candidate2_id from public.candidates c where c.email='t005_c2_'||s||'@example.com';
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,status_code)
  values(candidate_id,'T005 Candidate','1990-01-01','MALE','Address','0900000000','t005_c1_'||s||'@example.com','PROCESSED') returning public.submissions.submission_id into submission_id;
  insert into public.submissions(candidate_id,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,status_code)
  values(candidate2_id,'T005 Candidate 2','1990-01-01','MALE','Address','0900000001','t005_c2_'||s||'@example.com','PROCESSED') returning public.submissions.submission_id into submission2_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id,is_active) values(submission_id,unit_id,pos1,root_user,true) returning public.applications.application_id into app_id;
  insert into public.interviews(application_id,round_no,start_at,end_at,interview_format_id,room_id,schedule_status_code,is_active)
  values(app_id,1,'2099-01-01 09:00+07','2099-01-01 10:00+07',format_id,room1,'SCHEDULED',true) returning public.interviews.interview_id into interview_id;
  insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_email)
  values(interview_id,interviewer,1,'Historic Interviewer','t005_historic_'||s||'@eiu.edu.vn') returning interview_participant_id into participant_id;

  -- Unauthenticated reactivation fails before all other work.
  perform set_config('request.jwt.claims','{}',true);
  r:=public.reactivate_application(app_id,1); assert r->>'error_code'='UNAUTHENTICATED','unauthenticated reactivate denied';

  -- Root inactivates parent only, then reactivates it and recalculates status/audits.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',root_auth::text)::text,true);
  r:=public.delete_or_inactivate_application(app_id); assert (r->>'success')::boolean and r->'data'->>'action'='INACTIVATED','root inactivates used application';
  assert not (select is_active from public.applications where application_id=app_id),'parent inactive';
  assert (select i.is_active from public.interviews i where i.interview_id=test.interview_id),'active child flag preserved during parent inactivation';
  update public.interviews i set is_active=false where i.interview_id=test.interview_id;
  insert into public.interviews(application_id,round_no,start_at,end_at,interview_format_id,room_id,schedule_status_code,is_active)
  values(app_id,2,'2099-01-02 09:00+07','2099-01-02 10:00+07',format_id,room1,'SCHEDULED',true);
  select version_no into v from public.applications where application_id=app_id;
  r:=public.reactivate_application(app_id,v); assert (r->>'success')::boolean,'Root reactivation succeeds';
  assert (select is_active from public.applications where application_id=app_id),'parent reactivated';
  assert not (select i.is_active from public.interviews i where i.interview_id=test.interview_id),'intentionally inactive child remains inactive';
  assert (select s.status_code from public.submissions s where s.submission_id=test.submission_id)='PROCESSED','reactivation recalculates submission';
  assert exists(select 1 from public.security_audit_log where action_code='REACTIVATE_APPLICATION' and entity_id=app_id),'reactivation security audit written';

  -- Application manage succeeds; application-view-only does not.
  perform public.delete_or_inactivate_application(app_id); select version_no into v from public.applications where application_id=app_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',manage_auth::text)::text,true);
  r:=public.reactivate_application(app_id,v); assert (r->>'success')::boolean,'applications.manage reactivation succeeds';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',root_auth::text)::text,true); perform public.delete_or_inactivate_application(app_id); select version_no into v from public.applications where application_id=app_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',view_auth::text)::text,true);
  r:=public.reactivate_application(app_id,v); assert r->>'error_code'='FORBIDDEN','application-view-only reactivation denied';

  -- Restore state for participant authorization checks.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',root_auth::text)::text,true); r:=public.reactivate_application(app_id,v); assert (r->>'success')::boolean,'root restores test application';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',participant_auth::text)::text,true);
  r:=public.add_interview_participant(interview_id,participant_user,gen_random_uuid()); assert (r->>'success')::boolean,'participants plus view succeeds without interviews.manage';
  -- A record created by the predecessor v2 command namespace remains replayable
  -- after the frozen-signature cutover.
  v_idempotency_key:=gen_random_uuid();
  v_legacy_result:=jsonb_build_object('success',true,'data',jsonb_build_object('replayed','predecessor_v2'));
  perform private.record_idempotency(
    'app_user:'||participant_user::text, 'add_interview_participant_v2', v_idempotency_key,
    encode(extensions.digest(jsonb_build_object('interview_id',interview_id,'app_user_id',view_user)::text,'sha256'),'hex'),
    v_legacy_result, 'INTERVIEW_PARTICIPANT', participant_id
  );
  r:=public.add_interview_participant(interview_id,view_user,v_idempotency_key);
  assert r=v_legacy_result,'predecessor v2 idempotency record replays after cutover';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',participant_only_auth::text)::text,true);
  r:=public.add_interview_participant(interview_id,participant_only_user,gen_random_uuid()); assert r->>'error_code'='FORBIDDEN','participants-only denied';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',view_auth::text)::text,true);
  r:=public.add_interview_participant(interview_id,view_user,gen_random_uuid()); assert r->>'error_code'='FORBIDDEN','view-only participant mutation denied';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',manage_view_auth::text)::text,true);
  r:=public.add_interview_participant(interview_id,manage_view_user,gen_random_uuid()); assert r->>'error_code'='FORBIDDEN','manage plus view without participants denied';

  -- Stale version and inactive owner/current participant block without reactivation audit.
  -- Make the originally inactive child operational again for the eligibility
  -- guard while retaining the earlier round-trip preservation assertion.
  update public.interviews i set is_active=true where i.interview_id=test.interview_id;
  update public.interviews set is_active=false where application_id=app_id and round_no=2;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',root_auth::text)::text,true); perform public.delete_or_inactivate_application(app_id);
  select version_no into v from public.applications where application_id=app_id;
  r:=public.reactivate_application(app_id,v-1); assert r->>'error_code'='STALE_VERSION','stale reactivation rejected';
  update public.applications set hr_owner_id=manage_user where application_id=app_id;
  update public.app_users set is_active=false where app_user_id=manage_user;
  r:=public.reactivate_application(app_id,v); assert r->>'error_code'='ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED','inactive owner blocks reactivation';
  update public.app_users set is_active=true where app_user_id=manage_user;
  update public.app_users set is_active=false where app_user_id=interviewer;
  r:=public.reactivate_application(app_id,v); assert r->>'error_code'='CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED','inactive current participant blocks reactivation';
  update public.app_users set is_active=true where app_user_id=interviewer;
  update public.applications set hr_owner_id=root_user where application_id=app_id;

  -- Sibling children are invisible to the shared external conflict view while
  -- their parent is inactive; reactivation must still reject their overlap.
  update public.interviews set is_active=true, start_at='2099-01-01 09:30+07',end_at='2099-01-01 10:30+07'
  where application_id=app_id and round_no=2;
  r:=public.reactivate_application(app_id,v); assert r->>'error_code'='SCHEDULE_CONFLICT_CANDIDATE','overlapping target children block reactivation';
  update public.interviews set is_active=false where application_id=app_id and round_no=2;

  -- Candidate, Room, and Interviewer conflicts each roll back parent activation.
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id,is_active) values(submission_id,unit_id,pos2,root_user,true) returning public.applications.application_id into app2_id;
  insert into public.interviews(application_id,round_no,start_at,end_at,interview_format_id,room_id,schedule_status_code,is_active) values(app2_id,1,'2099-01-01 09:30+07','2099-01-01 10:30+07',format_id,room2,'SCHEDULED',true) returning public.interviews.interview_id into conflict_id;
  select count(*) into audit_count from public.security_audit_log where action_code='REACTIVATE_APPLICATION' and entity_id=app_id;
  r:=public.reactivate_application(app_id,v); assert r->>'error_code'='SCHEDULE_CONFLICT_CANDIDATE' and not (select is_active from public.applications where application_id=app_id),'candidate conflict rolls back reactivation';
  assert (select count(*) from public.security_audit_log where action_code='REACTIVATE_APPLICATION' and entity_id=app_id)=audit_count,'failed candidate conflict has no audit';
  update public.interviews i set is_active=false where i.interview_id=test.conflict_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id,is_active) values(submission2_id,unit_id,pos3,root_user,true) returning public.applications.application_id into app2_id;
  insert into public.interviews(application_id,round_no,start_at,end_at,interview_format_id,room_id,schedule_status_code,is_active) values(app2_id,1,'2099-01-01 09:30+07','2099-01-01 10:30+07',format_id,room1,'SCHEDULED',true) returning public.interviews.interview_id into conflict_id;
  r:=public.reactivate_application(app_id,v); assert r->>'error_code'='SCHEDULE_CONFLICT_ROOM' and not (select is_active from public.applications where application_id=app_id),'room conflict rolls back reactivation';
  update public.interviews i set is_active=false where i.interview_id=test.conflict_id;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id,is_active) values(submission2_id,unit_id,pos4,root_user,true) returning public.applications.application_id into app2_id;
  insert into public.interviews(application_id,round_no,start_at,end_at,interview_format_id,room_id,schedule_status_code,is_active) values(app2_id,1,'2099-01-01 09:30+07','2099-01-01 10:30+07',format_id,room2,'SCHEDULED',true) returning public.interviews.interview_id into conflict_id;
  insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_email) values(conflict_id,interviewer,1,'Conflict Interviewer','t005_conflict_'||s||'@eiu.edu.vn');
  r:=public.reactivate_application(app_id,v); assert r->>'error_code'='SCHEDULE_CONFLICT_INTERVIEWER' and not (select is_active from public.applications where application_id=app_id),'interviewer conflict rolls back reactivation';
  update public.interviews i set is_active=false where i.interview_id=test.conflict_id;

  -- Fully elapsed overlaps never block reactivation.
  update public.interviews set is_active=true,start_at='2000-01-01 09:00+07',end_at='2000-01-01 10:00+07' where application_id=app_id and round_no=2;
  insert into public.interviews(application_id,round_no,start_at,end_at,interview_format_id,room_id,schedule_status_code,is_active) values(app2_id,2,'2000-01-01 09:30+07','2000-01-01 10:30+07',format_id,room1,'SCHEDULED',true);
  r:=public.reactivate_application(app_id,v); assert (r->>'success')::boolean,'fully elapsed overlap permits reactivation';
  raise notice '=== TASK-S04-005 command repair regression PASSED ===';
end;
$$;
rollback;