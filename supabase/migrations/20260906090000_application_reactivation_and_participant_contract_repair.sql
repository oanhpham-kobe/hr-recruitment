-- TASK-S04-005: Application reactivation and participant RPC contract repair.
-- This migration intentionally replaces only accepted command bodies/signatures.

-- Application soft-inactivation is parent-only: child Interview lifecycle history is preserved.
create or replace function public.delete_or_inactivate_application(
  p_application_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_round_count integer;
  v_round1 public.interviews%rowtype;
  v_action text;
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;
  select u.app_user_id into v_actor
  from public.app_users u
  where u.auth_user_id = auth.uid() and u.is_active;
  if v_actor is null or (not private.is_root_admin() and not (
    private.has_permission('applications.delete') or private.has_permission('applications.manage')
  )) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;

  select a.submission_id into v_submission_id
  from public.applications a
  where a.application_id = p_application_id;
  if v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  perform 1 from public.submissions s where s.submission_id = v_submission_id for update;
  select * into v_app from public.applications a
  where a.application_id = p_application_id and a.submission_id = v_submission_id
  for update;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

  select count(*) into v_round_count from public.interviews where application_id = p_application_id;
  select * into v_round1 from public.interviews where application_id = p_application_id and round_no = 1;
  if v_round_count = 1 and v_round1.interview_id is not null
     and private.is_structurally_empty_default_round(v_round1.interview_id) then
    delete from public.interviews where interview_id = v_round1.interview_id;
    delete from public.applications where application_id = p_application_id;
    v_action := 'DELETED';
  else
    update public.applications
    set is_active = false, version_no = version_no + 1, updated_at = clock_timestamp(), updated_by = v_actor
    where application_id = p_application_id;
    -- Do not modify interviews.is_active: intentionally inactive rounds stay
    -- inactive; active rounds are restored through the parent access predicate.
    v_action := 'INACTIVATED';
  end if;

  perform public.recalculate_submission_status(v_submission_id);
  perform private.audit_interview_command(
    'INACTIVATE_APPLICATION', 'APPLICATION', p_application_id, v_actor, null,
    jsonb_build_object('action', v_action, 'submission_id', v_submission_id)
  );
  return jsonb_build_object('success', true, 'data', jsonb_build_object(
    'application_id', p_application_id, 'action', v_action, 'submission_id', v_submission_id
  ));
end;
$$;
revoke all on function public.delete_or_inactivate_application(uuid) from public, anon;
grant execute on function public.delete_or_inactivate_application(uuid) to authenticated;

create or replace function public.reactivate_application(
  p_application_id uuid,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_submission_id uuid;
  v_app public.applications%rowtype;
  v_owner public.app_users%rowtype;
  v_interview public.interviews%rowtype;
  v_candidate_id uuid;
  v_room_id uuid;
  v_user_id uuid;
  v_interviewer_ids uuid[];
  v_conflict text;
  v_now timestamptz := transaction_timestamp();
begin
  if auth.uid() is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED');
  end if;
  select u.app_user_id into v_actor
  from public.app_users u
  where u.auth_user_id = auth.uid() and u.is_active;
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('applications.manage')) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN');
  end if;
  if p_application_id is null or p_expected_version is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  -- Resolve immutable identity, lock Submission first, then re-read and lock Application.
  select a.submission_id into v_submission_id
  from public.applications a where a.application_id = p_application_id;
  if v_submission_id is null then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  perform 1 from public.submissions s where s.submission_id = v_submission_id for update;
  select * into v_app from public.applications a
  where a.application_id = p_application_id and a.submission_id = v_submission_id
  for update;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_app.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
  end if;
  if v_app.is_active then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE');
  end if;
  select * into v_owner
  from public.app_users owner_user
  where owner_user.app_user_id = v_app.hr_owner_id
  for update;
  if not found or not v_owner.is_active then
    return jsonb_build_object('success', false, 'error_code', 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
  end if;
  if not v_owner.is_root_admin then
    perform 1 from public.app_user_roles r
    where r.app_user_id = v_owner.app_user_id and r.role_code = 'HR'
    for update;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED');
    end if;
  end if;

  -- Lock every child before snapshotting participant/resource state. Only
  -- preserved-active, non-CANCELLED complete future intervals become operational.
  perform 1 from public.interviews i
  where i.application_id = p_application_id
  order by i.interview_id
  for update;
  select s.candidate_id into v_candidate_id
  from public.submissions s where s.submission_id = v_submission_id;

  for v_interview in
    select * from public.interviews i
    where i.application_id = p_application_id
      and i.is_active
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null
      and i.end_at > v_now
    order by i.interview_id
  loop
    if not private.all_current_participants_selectable(v_interview.interview_id) then
      return jsonb_build_object('success', false, 'error_code', 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED');
    end if;
  end loop;

  -- Deterministic global lock order: candidate, every room, every interviewer.
  if v_candidate_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('candidate:' || v_candidate_id::text, 0));
  end if;
  for v_room_id in
    select distinct i.room_id from public.interviews i
    where i.application_id = p_application_id and i.is_active
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null and i.end_at > v_now
      and i.room_id is not null
    order by i.room_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('room:' || v_room_id::text, 0));
  end loop;
  for v_user_id in
    select distinct ip.app_user_id
    from public.interview_participants ip
    join public.interviews i on i.interview_id = ip.interview_id
    where i.application_id = p_application_id and i.is_active and ip.is_current
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null and i.end_at > v_now
    order by ip.app_user_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('interviewer:' || v_user_id::text, 0));
  end loop;

  -- Lock active participant identities before activation, preventing an
  -- otherwise-permitted inactive-parent user lifecycle change from racing this command.
  for v_user_id in
    select distinct ip.app_user_id
    from public.interview_participants ip
    join public.interviews i on i.interview_id = ip.interview_id
    where i.application_id = p_application_id and i.is_active and ip.is_current
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null and i.end_at > v_now
    order by ip.app_user_id
  loop
    perform 1 from public.app_users u where u.app_user_id = v_user_id for update;
  end loop;

  -- A target parent remains inactive during preflight, so the shared external
  -- conflict view excludes these rows. Check target siblings explicitly first.
  if exists (
    select 1
    from public.interviews a
    join public.interviews b on b.application_id = a.application_id
      and b.interview_id > a.interview_id
      and b.is_active and b.schedule_status_code <> 'CANCELLED'
      and b.start_at is not null and b.end_at is not null and b.end_at > v_now
    where a.application_id = p_application_id
      and a.is_active and a.schedule_status_code <> 'CANCELLED'
      and a.start_at is not null and a.end_at is not null and a.end_at > v_now
      and a.start_at < b.end_at and a.end_at > b.start_at
  ) then
    return jsonb_build_object('success', false, 'error_code', 'SCHEDULE_CONFLICT_CANDIDATE');
  end if;

  -- Child rows and their users remain locked, so this is the authoritative
  -- post-lock snapshot and external conflict check.
  for v_interview in
    select * from public.interviews i
    where i.application_id = p_application_id
      and i.is_active
      and i.schedule_status_code <> 'CANCELLED'
      and i.start_at is not null and i.end_at is not null
      and i.end_at > v_now
    order by i.interview_id
  loop
    if not private.all_current_participants_selectable(v_interview.interview_id) then
      return jsonb_build_object('success', false, 'error_code', 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED');
    end if;
    select coalesce(array_agg(ip.app_user_id order by ip.app_user_id), array[]::uuid[])
    into v_interviewer_ids
    from public.interview_participants ip
    where ip.interview_id = v_interview.interview_id and ip.is_current;
    select c.conflict_type into v_conflict
    from private.check_interview_conflicts(
      v_interview.interview_id, v_candidate_id, v_interview.room_id,
      v_interviewer_ids, v_interview.start_at, v_interview.end_at
    ) c
    order by case c.conflict_type when 'CANDIDATE' then 1 when 'ROOM' then 2 else 3 end
    limit 1;
    if v_conflict is not null then
      return jsonb_build_object('success', false, 'error_code', 'SCHEDULE_CONFLICT_' || v_conflict);
    end if;
  end loop;
  update public.applications
  set is_active = true, version_no = version_no + 1, updated_at = clock_timestamp(), updated_by = v_actor
  where application_id = p_application_id;

  perform public.recalculate_submission_status(v_submission_id);
  perform private.audit_interview_command(
    'REACTIVATE_APPLICATION', 'APPLICATION', p_application_id, v_actor, null,
    jsonb_build_object('submission_id', v_submission_id, 'expected_version', p_expected_version)
  );
  return jsonb_build_object('success', true, 'data', jsonb_build_object(
    'application_id', p_application_id, 'is_active', true,
    'version_no', (select version_no from public.applications where application_id = p_application_id)
  ));
end;
$$;
revoke all on function public.reactivate_application(uuid,bigint) from public, anon;
grant execute on function public.reactivate_application(uuid,bigint) to authenticated;

-- Replace all participant overloads with the frozen public surface.
drop function if exists public.add_interview_participant(uuid,uuid,bigint,uuid);
drop function if exists public.add_interview_participant(uuid,uuid,uuid);
drop function if exists public.remove_interview_participant(uuid,bigint,uuid);
drop function if exists public.remove_interview_participant(uuid,bigint);
drop function if exists public.readd_interview_participant(uuid,text,uuid);
drop function if exists public.reorder_interview_participants(uuid,uuid[],bigint,uuid);
drop function if exists public.reorder_interview_participants(uuid,uuid[],bigint[]);

create or replace function private.participant_command_actor()
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_actor uuid;
begin
  if auth.uid() is null then return null; end if;
  select u.app_user_id into v_actor from public.app_users u where u.auth_user_id = auth.uid() and u.is_active;
  if v_actor is null then return null; end if;
  if not private.is_root_admin() and not (
    private.has_permission('interviews.participants') and private.has_permission('interviews.view')
  ) then return null; end if;
  return v_actor;
end;
$$;
revoke all on function private.participant_command_actor() from public, anon, authenticated;
grant execute on function private.participant_command_actor() to postgres, service_role;

create or replace function public.add_interview_participant(p_interview_id uuid, p_app_user_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := private.participant_command_actor(); v_interview public.interviews%rowtype;
  v_user public.app_users%rowtype; v_participant_id uuid; v_order integer; v_ids uuid[];
  v_error text; v_result jsonb; v_fingerprint text; v_existing jsonb;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_idempotency_key is null then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  v_fingerprint := encode(extensions.digest(jsonb_build_object('interview_id',p_interview_id,'app_user_id',p_app_user_id)::text,'sha256'),'hex');
  v_existing := private.check_idempotency('app_user:'||v_actor::text,'add_interview_participant_v2',p_idempotency_key,v_fingerprint);
  if v_existing is not null then return v_existing; end if;
  select * into v_interview from public.interviews where interview_id=p_interview_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_user from public.app_users where app_user_id=p_app_user_id and is_active;
  if not found then return jsonb_build_object('success',false,'error_code','USER_INACTIVE_NOT_SELECTABLE'); end if;
  if exists(select 1 from public.interview_participants where interview_id=p_interview_id and app_user_id=p_app_user_id and is_current) then return jsonb_build_object('success',false,'error_code','DUPLICATE_PARTICIPANT'); end if;
  if v_interview.is_active and v_interview.schedule_status_code <> 'CANCELLED' and v_interview.start_at is not null and v_interview.end_at is not null then
    select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) || p_app_user_id into v_ids from public.interview_participants where interview_id=p_interview_id and is_current;
    v_error := private.interview_resource_error(v_interview,v_interview.start_at,v_interview.end_at,v_interview.room_id,v_ids);
    if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if;
  end if;
  select coalesce(max(participant_order),0)+1 into v_order from public.interview_participants where interview_id=p_interview_id and is_current;
  insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email)
  values(p_interview_id,p_app_user_id,v_order,v_user.full_name,v_user.job_title,v_user.email) returning interview_participant_id into v_participant_id;
  update public.interviews set updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('ADD_INTERVIEW_PARTICIPANT','INTERVIEW_PARTICIPANT',v_participant_id,v_actor,p_idempotency_key,jsonb_build_object('interview_id',p_interview_id,'participant_order',v_order));
  v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('interview_participant_id',v_participant_id,'participant_order',v_order,'snapshot_name',v_user.full_name,'snapshot_job_title',v_user.job_title,'snapshot_email',v_user.email));
  perform private.record_idempotency('app_user:'||v_actor::text,'add_interview_participant_v2',p_idempotency_key,v_fingerprint,v_result,'INTERVIEW_PARTICIPANT',v_participant_id);
  return v_result;
end;
$$;

create or replace function public.remove_interview_participant(p_interview_participant_id uuid, p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.participant_command_actor(); v_part public.interview_participants%rowtype; v_has_report boolean;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  select ip.* into v_part from public.interview_participants ip where ip.interview_participant_id=p_interview_participant_id;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  perform 1 from public.interviews where interview_id=v_part.interview_id for update;
  select ip.* into v_part from public.interview_participants ip where ip.interview_participant_id=p_interview_participant_id for update;
  if v_part.version_no is distinct from p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if not v_part.is_current then return jsonb_build_object('success',false,'error_code','ALREADY_REMOVED'); end if;
  select exists(select 1 from public.interview_reports where interview_participant_id=v_part.interview_participant_id) into v_has_report;
  update public.interview_participants set is_current=false,removed_at=clock_timestamp() where interview_participant_id=v_part.interview_participant_id;
  update public.interview_reports set is_active=false,is_archived=true,updated_by=v_actor where interview_participant_id=v_part.interview_participant_id and is_active and not is_archived;
  update public.interview_participants set participant_order=participant_order+1000000 where interview_id=v_part.interview_id and is_current;
  with ordered as (select interview_participant_id,row_number() over(order by participant_order)::integer n from public.interview_participants where interview_id=v_part.interview_id and is_current)
  update public.interview_participants ip set participant_order=o.n from ordered o where ip.interview_participant_id=o.interview_participant_id;
  update public.interviews set updated_by=v_actor where interview_id=v_part.interview_id;
  perform private.audit_interview_command('REMOVE_INTERVIEW_PARTICIPANT','INTERVIEW_PARTICIPANT',v_part.interview_participant_id,v_actor,null,jsonb_build_object('report_exists',v_has_report));
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_participant_id',v_part.interview_participant_id,'removed',true,'report_exists',v_has_report));
end;
$$;

create or replace function public.readd_interview_participant(p_interview_participant_id uuid,p_restore_mode text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.participant_command_actor(); v_old public.interview_participants%rowtype; v_interview public.interviews%rowtype; v_user public.app_users%rowtype; v_ids uuid[]; v_error text; v_order integer; v_new_id uuid; v_result jsonb; v_fingerprint text; v_existing jsonb;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_idempotency_key is null or p_restore_mode not in ('RESTORE_OLD_REPORT','CREATE_NEW_REPORT') then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  v_fingerprint:=encode(extensions.digest(jsonb_build_object('participant_id',p_interview_participant_id,'restore_mode',p_restore_mode)::text,'sha256'),'hex'); v_existing:=private.check_idempotency('app_user:'||v_actor::text,'readd_interview_participant',p_idempotency_key,v_fingerprint); if v_existing is not null then return v_existing; end if;
  select ip.* into v_old from public.interview_participants ip where ip.interview_participant_id=p_interview_participant_id; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_interview from public.interviews where interview_id=v_old.interview_id for update; select * into v_old from public.interview_participants where interview_participant_id=p_interview_participant_id for update;
  if v_old.is_current or exists(select 1 from public.interview_participants where interview_id=v_old.interview_id and app_user_id=v_old.app_user_id and is_current) then return jsonb_build_object('success',false,'error_code','DUPLICATE_PARTICIPANT'); end if;
  select * into v_user from public.app_users where app_user_id=v_old.app_user_id and is_active; if not found then return jsonb_build_object('success',false,'error_code','USER_INACTIVE_NOT_SELECTABLE'); end if;
  if v_interview.is_active and v_interview.schedule_status_code<>'CANCELLED' and v_interview.start_at is not null and v_interview.end_at is not null then select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) || v_old.app_user_id into v_ids from public.interview_participants where interview_id=v_old.interview_id and is_current; v_error:=private.interview_resource_error(v_interview,v_interview.start_at,v_interview.end_at,v_interview.room_id,v_ids); if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if; end if;
  select coalesce(max(participant_order),0)+1 into v_order from public.interview_participants where interview_id=v_old.interview_id and is_current;
  if p_restore_mode='RESTORE_OLD_REPORT' then update public.interview_participants set is_current=true,removed_at=null,participant_order=v_order where interview_participant_id=v_old.interview_participant_id; update public.interview_reports set is_active=true,is_archived=false,updated_by=v_actor where interview_participant_id=v_old.interview_participant_id and not is_active and is_archived; v_new_id:=v_old.interview_participant_id; perform private.audit_interview_command('RESTORE_PARTICIPANT_REPORT','INTERVIEW_PARTICIPANT',v_new_id,v_actor,p_idempotency_key,'{}'); else insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email) values(v_old.interview_id,v_user.app_user_id,v_order,v_user.full_name,v_user.job_title,v_user.email) returning interview_participant_id into v_new_id; perform private.audit_interview_command('READD_INTERVIEW_PARTICIPANT','INTERVIEW_PARTICIPANT',v_new_id,v_actor,p_idempotency_key,jsonb_build_object('restore_mode',p_restore_mode)); end if;
  update public.interviews set updated_by=v_actor where interview_id=v_old.interview_id;
  v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('interview_participant_id',v_new_id,'restore_mode',p_restore_mode,'participant_order',v_order)); perform private.record_idempotency('app_user:'||v_actor::text,'readd_interview_participant',p_idempotency_key,v_fingerprint,v_result,'INTERVIEW_PARTICIPANT',v_new_id); return v_result;
end;
$$;

create or replace function public.reorder_interview_participants(p_interview_id uuid,p_ordered_participant_ids uuid[],p_expected_versions bigint[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.participant_command_actor(); v_count integer; v_idx integer; v_id uuid; v_expected bigint;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  perform 1 from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select count(*) into v_count from public.interview_participants where interview_id=p_interview_id and is_current;
  if cardinality(p_ordered_participant_ids) is distinct from v_count or cardinality(p_expected_versions) is distinct from v_count or (select count(distinct x) from unnest(p_ordered_participant_ids) x)<>v_count or exists(select 1 from unnest(p_ordered_participant_ids) x where not exists(select 1 from public.interview_participants ip where ip.interview_participant_id=x and ip.interview_id=p_interview_id and ip.is_current)) then return jsonb_build_object('success',false,'error_code','PARTICIPANT_SET_MISMATCH'); end if;
  for v_idx in 1..v_count loop v_id:=p_ordered_participant_ids[v_idx]; v_expected:=p_expected_versions[v_idx]; if not exists(select 1 from public.interview_participants where interview_participant_id=v_id and version_no=v_expected) then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if; end loop;
  update public.interview_participants set participant_order=participant_order+1000000 where interview_id=p_interview_id and is_current;
  for v_idx in 1..v_count loop update public.interview_participants set participant_order=v_idx where interview_participant_id=p_ordered_participant_ids[v_idx]; end loop;
  update public.interviews set updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('REORDER_INTERVIEW_PARTICIPANTS','INTERVIEW',p_interview_id,v_actor,null,jsonb_build_object('participant_ids',p_ordered_participant_ids));
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'reordered_count',v_count));
end;
$$;

revoke all on function public.add_interview_participant(uuid,uuid,uuid), public.remove_interview_participant(uuid,bigint), public.readd_interview_participant(uuid,text,uuid), public.reorder_interview_participants(uuid,uuid[],bigint[]) from public, anon;
grant execute on function public.add_interview_participant(uuid,uuid,uuid), public.remove_interview_participant(uuid,bigint), public.readd_interview_participant(uuid,text,uuid), public.reorder_interview_participants(uuid,uuid[],bigint[]) to authenticated;