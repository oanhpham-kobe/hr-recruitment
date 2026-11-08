-- RECOVERY PACKAGE 008: REC-04 participant maintenance composition follow-up
-- Commands that make a transition table empty must acquire their complete
-- participant-plus-actor set before the first participant maintenance write.

create or replace function public.remove_interview_participant(p_interview_participant_id uuid, p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := private.participant_command_actor();
  v_part public.interview_participants%rowtype;
  v_has_report boolean;
  v_lock_ids uuid[];
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  select ip.* into v_part from public.interview_participants ip where ip.interview_participant_id=p_interview_participant_id;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  perform 1 from public.interviews where interview_id=v_part.interview_id for update;
  select ip.* into v_part from public.interview_participants ip where ip.interview_participant_id=p_interview_participant_id for update;
  if v_part.version_no is distinct from p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if not v_part.is_current then return jsonb_build_object('success',false,'error_code','ALREADY_REMOVED'); end if;
  select coalesce(array_agg(distinct q.app_user_id order by q.app_user_id),array[]::uuid[]) into v_lock_ids
  from (select ip.app_user_id from public.interview_participants ip where ip.interview_id=v_part.interview_id and ip.is_current union all select v_actor) q where q.app_user_id is not null;
  perform 1 from public.app_users u where u.app_user_id=any(v_lock_ids) order by u.app_user_id for update;
  perform private.lock_internal_user_ids(v_lock_ids);
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

create or replace function public.reorder_interview_participants(p_interview_id uuid,p_ordered_participant_ids uuid[],p_expected_versions bigint[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid:=private.participant_command_actor(); v_count integer; v_idx integer; v_id uuid; v_expected bigint; v_lock_ids uuid[];
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  perform 1 from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select count(*) into v_count from public.interview_participants where interview_id=p_interview_id and is_current;
  if cardinality(p_ordered_participant_ids) is distinct from v_count or cardinality(p_expected_versions) is distinct from v_count or (select count(distinct x) from unnest(p_ordered_participant_ids) x)<>v_count or exists(select 1 from unnest(p_ordered_participant_ids) x where not exists(select 1 from public.interview_participants ip where ip.interview_participant_id=x and ip.interview_id=p_interview_id and ip.is_current)) then return jsonb_build_object('success',false,'error_code','PARTICIPANT_SET_MISMATCH'); end if;
  for v_idx in 1..v_count loop v_id:=p_ordered_participant_ids[v_idx]; v_expected:=p_expected_versions[v_idx]; if not exists(select 1 from public.interview_participants where interview_participant_id=v_id and version_no=v_expected) then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if; end loop;
  select coalesce(array_agg(distinct q.app_user_id order by q.app_user_id),array[]::uuid[]) into v_lock_ids from (select ip.app_user_id from public.interview_participants ip where ip.interview_id=p_interview_id and ip.is_current union all select v_actor) q where q.app_user_id is not null;
  perform 1 from public.app_users u where u.app_user_id=any(v_lock_ids) order by u.app_user_id for update;
  perform private.lock_internal_user_ids(v_lock_ids);
  update public.interview_participants set participant_order=participant_order+1000000 where interview_id=p_interview_id and is_current;
  for v_idx in 1..v_count loop update public.interview_participants set participant_order=v_idx where interview_participant_id=p_ordered_participant_ids[v_idx]; end loop;
  update public.interviews set updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('REORDER_INTERVIEW_PARTICIPANTS','INTERVIEW',p_interview_id,v_actor,null,jsonb_build_object('participant_ids',p_ordered_participant_ids));
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'reordered_count',v_count));
end;
$$;

revoke all on function public.remove_interview_participant(uuid,bigint), public.reorder_interview_participants(uuid,uuid[],bigint[]) from public, anon;
grant execute on function public.remove_interview_participant(uuid,bigint), public.reorder_interview_participants(uuid,uuid[],bigint[]) to authenticated;
