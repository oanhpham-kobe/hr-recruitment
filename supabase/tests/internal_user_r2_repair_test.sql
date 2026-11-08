\set ON_ERROR_STOP on
begin;

insert into public.position_groups(position_group_id,name_vi,code,is_active)
values('84000000-0000-0000-0000-000000000001','S06-002 R2 Group','S06002_R2_G',true);
insert into public.organizational_units(unit_id,name_vi,code,is_active)
values('84000000-0000-0000-0000-000000000002','S06-002 R2 Unit','S06002_R2_U',true);
insert into public.positions(position_id,unit_id,position_group_id,code,name_vi,is_active)
values('84000000-0000-0000-0000-000000000003','84000000-0000-0000-0000-000000000002','84000000-0000-0000-0000-000000000001','S06002_R2_P','S06-002 R2 Position',true);
insert into public.interview_formats(interview_format_id,code,name_vi,requires_room,requires_meeting_link,is_active)
values('84000000-0000-0000-0000-000000000004','S06002_R2_F','S06-002 R2 Format',false,false,true);

insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin)
values
  ('84000000-0000-0000-0000-000000000010','84100000-0000-0000-0000-000000000010','r2root@eiu.edu.vn','R2 Root',true,true),
  ('84000000-0000-0000-0000-000000000011',null,'r2remove@eiu.edu.vn','R2 Remove',true,false),
  ('84000000-0000-0000-0000-000000000012',null,'r2history@eiu.edu.vn','R2 Historical',true,false);

insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active)
values('84000000-0000-0000-0000-000000000020','84100000-0000-0000-0000-000000000020','r2candidate@example.test','R2 Candidate',true);
insert into public.submissions(
  submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot,version_no
) values(
  '84000000-0000-0000-0000-000000000021','84000000-0000-0000-0000-000000000020','READ','R2 Candidate','1990-01-01','MALE','Address','0900000000','r2candidate@example.test',1
);
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id,is_active)
values('84000000-0000-0000-0000-000000000022','84000000-0000-0000-0000-000000000021','84000000-0000-0000-0000-000000000002','84000000-0000-0000-0000-000000000003','84000000-0000-0000-0000-000000000010',true);
insert into public.interviews(
  interview_id,application_id,round_no,start_at,end_at,interview_format_id,schedule_status_code,report_status_code,is_active
) values(
  '84000000-0000-0000-0000-000000000023','84000000-0000-0000-0000-000000000022',1,
  clock_timestamp()+interval '2 days',clock_timestamp()+interval '2 days 1 hour','84000000-0000-0000-0000-000000000004',
  'CANCELLED','FOLLOW_UP',true
);
insert into public.interview_participants(
  interview_participant_id,interview_id,app_user_id,participant_order,snapshot_name,snapshot_email,is_current
) values
  ('84000000-0000-0000-0000-000000000024','84000000-0000-0000-0000-000000000023','84000000-0000-0000-0000-000000000011',1,'R2 Remove','r2remove@eiu.edu.vn',true),
  ('84000000-0000-0000-0000-000000000025','84000000-0000-0000-0000-000000000023','84000000-0000-0000-0000-000000000012',2,'R2 Historical','r2history@eiu.edu.vn',true);

-- A CANCELLED Interview may retain a now-inactive historical current
-- participant. This lifecycle transition is allowed because the
-- Interview is not resource_blocking.
update public.app_users
set is_active=false
where app_user_id='84000000-0000-0000-0000-000000000012';

set local role authenticated;
do $$
declare
  v_status jsonb;
  v_remove jsonb;
  v_version bigint;
begin
  perform set_config('request.jwt.claim.sub','84100000-0000-0000-0000-000000000010',true);

  assert not has_column_privilege('authenticated','public.app_users','auth_user_id','SELECT'),
    'raw Internal User auth binding must remain hidden';

  v_status := public.get_current_internal_binding_status();
  assert (v_status->>'success')::boolean;
  assert (v_status->'data'->>'bound')::boolean;
  assert (v_status->'data'->>'app_user_id')::uuid='84000000-0000-0000-0000-000000000010'::uuid;
  assert (v_status->'data'->>'is_active')::boolean;
  assert (v_status->'data'->>'is_root_admin')::boolean;

  select version_no into v_version
  from public.interview_participants
  where interview_participant_id='84000000-0000-0000-0000-000000000024';
  v_remove := public.remove_interview_participant(
    '84000000-0000-0000-0000-000000000024', v_version
  );
  assert (v_remove->>'success')::boolean,
    'removing another participant from CANCELLED history must succeed';
  assert exists(
    select 1 from public.interview_participants
    where interview_participant_id='84000000-0000-0000-0000-000000000025'
      and is_current=true
      and participant_order=1
  ), 'inactive historical participant must survive allowed reorder maintenance';
end;
$$;
reset role;

do $$
begin
  assert not has_function_privilege('anon','public.get_current_internal_binding_status()','EXECUTE');
  assert has_function_privilege('authenticated','public.get_current_internal_binding_status()','EXECUTE');
end;
$$;

rollback;
