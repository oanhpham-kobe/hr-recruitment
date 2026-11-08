-- TASK-S07-001. Provider-independent persistence only; no network calls.
-- Configuration is deployment-owned SQL, never an authenticated RPC argument.
-- TEST templates below are explicitly non-production fixtures, not approved copy.
create table private.email_configuration (
  singleton boolean primary key default true check (singleton),
  environment_code text not null default 'TEST' check (environment_code in ('TEST','PRODUCTION')),
  delivery_paused boolean not null default true,
  delivery_not_before timestamptz,
  test_sink text not null default 'email-sink@example.invalid'
    check (test_sink ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'),
  hr_recipients text[] not null default array['hr@example.invalid'],
  check (cardinality(hr_recipients) between 1 and 100 and array_position(hr_recipients,null) is null)
);
insert into private.email_configuration default values;
create table private.email_templates (
  environment_code text not null check (environment_code in ('TEST','PRODUCTION')),
  email_type text not null check (email_type in ('INTERVIEW_INVITATION','INTERVIEW_PARTICIPANT_INVITATION',
    'CANDIDATE_SUBMISSION_CONFIRMATION','HR_SUBMISSION_CREATED_NOTIFICATION','HR_SUBMISSION_UPDATED_NOTIFICATION')),
  template_version text not null check (length(btrim(template_version)) between 1 and 100),
  subject text not null check (length(btrim(subject)) between 1 and 998 and subject !~ '[\r\n]'),
  body_text text not null check (length(btrim(body_text)) between 1 and 100000),
  primary key(environment_code,email_type)
);
insert into private.email_templates(environment_code,email_type,template_version,subject,body_text)
select 'TEST',t,'test-1','[TEST] '||t,'Non-production recruitment notification.'
from unnest(array['INTERVIEW_INVITATION','INTERVIEW_PARTICIPANT_INVITATION',
 'CANDIDATE_SUBMISSION_CONFIRMATION','HR_SUBMISSION_CREATED_NOTIFICATION','HR_SUBMISSION_UPDATED_NOTIFICATION']) t;
alter table private.email_configuration enable row level security;
alter table private.email_templates enable row level security;
revoke all on private.email_configuration, private.email_templates from public, anon, authenticated, service_role;
grant all on private.email_configuration, private.email_templates to postgres;

alter table public.email_outbox add column request_fingerprint text,
  add column context_fingerprint text,
  add column attempt_id uuid;
alter table public.email_history alter column environment_code set default 'TEST';
alter table public.email_history add column attempt_id uuid,
  add column status_code text check (status_code in ('SENT','FAILED','CANCELLED','ABANDONED')),
  add column error_code text;
-- Existing classifications/payloads remain untouched. Legacy rows without the
-- protocol fingerprint are retained but cannot accidentally enter this worker.
create table private.email_attempts (
  attempt_id uuid primary key,
  email_outbox_id uuid not null references public.email_outbox(email_outbox_id) on delete restrict,
  attempt_no integer not null check (attempt_no > 0),
  worker_id text not null,
  claimed_at timestamptz not null,
  locked_until timestamptz not null,
  authorized_at timestamptz,
  finished_at timestamptz,
  status_code text not null check (status_code in ('SENDING','SENT','FAILED','CANCELLED','ABANDONED')),
  provider_message_id text,
  error_code text,
  result_payload jsonb,
  unique(email_outbox_id,attempt_no)
);
alter table private.email_attempts enable row level security;
revoke all on private.email_attempts from public, anon, authenticated, service_role;
grant all on private.email_attempts to postgres;
alter table public.email_history add constraint email_history_attempt_fk foreign key(attempt_id)
  references private.email_attempts(attempt_id) on delete restrict;
create unique index email_history_attempt_uq on public.email_history(attempt_id) where attempt_id is not null;
create index email_outbox_retry_due_idx on public.email_outbox(next_attempt_at,email_outbox_id)
  where request_fingerprint is not null and status_code in ('QUEUED','FAILED','SENDING');

-- Operational history cleanup cannot detach or erase retained production usage.
-- No purge bypass is introduced; approved archive/purge is a separate domain.
create or replace function private.retain_production_email()
returns trigger language plpgsql set search_path = '' as $$
begin
 if old.environment_code='PRODUCTION' then
   if tg_op='DELETE' then raise exception 'RETAINED_PRODUCTION_EMAIL' using errcode='23514'; end if;
   if row(new.environment_code,new.submission_id,new.application_id,new.interview_id,new.email_type,
       new.recipients,new.subject,new.body_text,new.body_html,new.template_version,new.request_fingerprint,new.context_fingerprint)
     is distinct from row(old.environment_code,old.submission_id,old.application_id,old.interview_id,old.email_type,
       old.recipients,old.subject,old.body_text,old.body_html,old.template_version,old.request_fingerprint,old.context_fingerprint) then
     raise exception 'RETAINED_PRODUCTION_EMAIL' using errcode='23514';
   end if;
 end if;
 return case when tg_op='DELETE' then old else new end;
end;
$$;
create trigger email_outbox_production_retention before update or delete on public.email_outbox
 for each row execute function private.retain_production_email();
revoke all on function private.retain_production_email() from public,anon,authenticated,service_role;

-- Exact entity chain is checked even for Root. Unsupported types fail closed.
create or replace function private.can_read_email_context(p_type text,p_submission uuid,p_application uuid,p_interview uuid)
returns boolean language sql stable security definer set search_path = '' as $$
select private.current_app_user_id() is not null and case
 when p_type in ('INTERVIEW_INVITATION','INTERVIEW_PARTICIPANT_INVITATION') then exists (
   select 1 from public.interviews i join public.applications a on a.application_id=i.application_id
   where i.interview_id=p_interview and a.application_id=p_application and a.submission_id=p_submission
   and (private.has_permission('interviews.view') or private.has_permission('interviews.manage')
     or (i.visible_to_interviewers and private.can_view_visible_interview(i.interview_id))))
 when p_type in ('CANDIDATE_SUBMISSION_CONFIRMATION','HR_SUBMISSION_CREATED_NOTIFICATION','HR_SUBMISSION_UPDATED_NOTIFICATION') then
   p_application is null and p_interview is null and private.has_permission('submissions.view')
   and exists(select 1 from public.submissions where submission_id=p_submission)
 else false end;
$$;
revoke all on function private.can_read_email_context(text,uuid,uuid,uuid) from public,anon;
grant execute on function private.can_read_email_context(text,uuid,uuid,uuid) to authenticated,postgres;
drop policy email_history_select on public.email_history;
create policy email_history_select on public.email_history for select to authenticated using (
 private.has_permission('emails.history_view') and
 private.can_read_email_context(email_type,submission_id,application_id,interview_id));

-- Same parent-first ordering as Interview commands. Lock the complete batch at
-- once, never acquire per-item parent locks in caller selection order. User rows
-- precede the accepted S06 advisory gates; permission revocation shares the gate.
create or replace function private.lock_email_contexts(p_interviews uuid[],p_actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_users uuid[];
begin
 perform 1 from public.applications a where a.application_id in
   (select i.application_id from public.interviews i where i.interview_id=any(p_interviews))
   order by a.application_id for share;
 -- Serialize schedule/participant writers without excluding history's FK KEY
 -- SHARE locks. Worker result/reclaim holds outbox first; authorization holds
 -- context first. FOR UPDATE here would create their inverse-lock deadlock.
 -- NO KEY UPDATE still conflicts with every accepted Interview writer lock.
 perform 1 from public.interviews i where i.interview_id=any(p_interviews) order by i.interview_id for no key update;
 perform 1 from public.submissions s where s.submission_id in
   (select a.submission_id from public.applications a join public.interviews i on i.application_id=a.application_id
    where i.interview_id=any(p_interviews)) order by s.submission_id for share;
 select coalesce(array_agg(distinct id order by id),'{}'::uuid[]) into v_users from (
   select p_actor id where p_actor is not null union
   select ip.app_user_id from public.interview_participants ip where ip.interview_id=any(p_interviews) and ip.is_current
 ) u;
 perform 1 from public.app_users u where u.app_user_id=any(v_users) order by u.app_user_id for share;
 perform private.lock_internal_user_ids(v_users);
end;
$$;

create or replace function private.email_snapshot(p_type text,p_submission uuid,p_application uuid,p_interview uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_config private.email_configuration%rowtype; v_template private.email_templates%rowtype;
 v_recipients jsonb; v_context jsonb; v_i public.interviews%rowtype; v_s public.submissions%rowtype;
 v_participants jsonb; v_body text;
begin
 select * into strict v_config from private.email_configuration where singleton for share;
 select * into v_template from private.email_templates where environment_code=v_config.environment_code and email_type=p_type for share;
 if not found then raise exception 'EMAIL_CONFIGURATION_UNAVAILABLE' using errcode='P0701'; end if;
 select * into v_s from public.submissions where submission_id=p_submission;
 if not found then raise exception 'INVALID_EMAIL_CONTEXT' using errcode='P0701'; end if;
 if p_type in ('INTERVIEW_INVITATION','INTERVIEW_PARTICIPANT_INVITATION') then
   select i.* into v_i from public.interviews i join public.applications a on a.application_id=i.application_id
   where i.interview_id=p_interview and a.application_id=p_application and a.submission_id=p_submission and a.is_active;
   if not found or not v_i.is_active or v_i.schedule_status_code='CANCELLED' then
     raise exception 'INVALID_EMAIL_CONTEXT' using errcode='P0701';
   end if;
   select coalesce(jsonb_agg(jsonb_build_object('id',ip.interview_participant_id,'user_id',ip.app_user_id,
     'order',ip.participant_order,'email',u.email,'active',u.is_active,'name',ip.snapshot_name)
     order by ip.participant_order,ip.interview_participant_id),'[]') into v_participants
   from public.interview_participants ip join public.app_users u on u.app_user_id=ip.app_user_id
   where ip.interview_id=p_interview and ip.is_current and ip.removed_at is null;
   if exists(select 1 from jsonb_array_elements(v_participants) x where not (x->>'active')::boolean) then
     raise exception 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED' using errcode='P0701';
   end if;
   if p_type='INTERVIEW_INVITATION' then v_recipients:=jsonb_build_array(v_s.email_snapshot::text);
   else select coalesce(jsonb_agg(distinct x->>'email'),'[]') into v_recipients from jsonb_array_elements(v_participants) x; end if;
   v_context:=jsonb_build_object('interview_id',p_interview,'application_id',p_application,'submission_id',p_submission,
     'start_at',v_i.start_at,'end_at',v_i.end_at,'room_id',v_i.room_id,'format_id',v_i.interview_format_id,
     'meeting_link',v_i.meeting_link,'demo_topic',v_i.demo_topic,'schedule_status',v_i.schedule_status_code,
     'participants',v_participants,'candidate_name',v_s.full_name,'recipients',v_recipients);
   -- Plain text only. No HTML/template execution or arbitrary browser content.
   v_body:=v_template.body_text || E'\nStart: ' || coalesce(v_i.start_at::text,'Not scheduled')
     || E'\nEnd: ' || coalesce(v_i.end_at::text,'Not scheduled')
     || E'\nMeeting: ' || coalesce(v_i.meeting_link,'')
     || E'\nTopic: ' || coalesce(v_i.demo_topic,'');
 else
   if p_interview is not null or p_application is not null then raise exception 'INVALID_EMAIL_CONTEXT' using errcode='P0701'; end if;
   if p_type='CANDIDATE_SUBMISSION_CONFIRMATION' then v_recipients:=jsonb_build_array(v_s.email_snapshot::text);
   else v_recipients:=to_jsonb(v_config.hr_recipients); end if;
   v_context:=jsonb_build_object('submission_id',p_submission,'version_no',v_s.version_no,'recipients',v_recipients);
   v_body:=v_template.body_text || E'\nSubmission: ' || p_submission::text;
 end if;
 if jsonb_array_length(v_recipients)=0 or exists(select 1 from jsonb_array_elements_text(v_recipients) e
   where e !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then
   raise exception 'EMAIL_RECIPIENTS_UNAVAILABLE' using errcode='P0701';
 end if;
 return jsonb_build_object('environment_code',v_config.environment_code,'recipients',jsonb_build_object('to',v_recipients,'cc','[]'::jsonb),
   'subject',v_template.subject,'body_text',v_body,'template_version',v_template.template_version,
   'context_fingerprint',encode(extensions.digest(v_context::text,'sha256'),'hex'));
end;
$$;

-- One insert/audit core for manual and existing Candidate business writers.
-- The request identity is independent of mutable delivery state/template config.
create or replace function private.persist_email(p_type text,p_submission uuid,p_application uuid,p_interview uuid,
 p_actor uuid,p_candidate uuid,p_key uuid,p_request_fingerprint text,p_snapshot jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_scope text; v_old public.email_outbox%rowtype; v_id uuid;
begin
 if p_key is null or (p_actor is null)=(p_candidate is null) then raise exception 'INVALID_EMAIL_ACTOR' using errcode='P0701'; end if;
 v_scope:=case when p_actor is not null then 'app_user:'||p_actor else 'candidate:'||p_candidate end;
 perform pg_advisory_xact_lock(hashtextextended(v_scope||':email:'||p_type||':'||p_key,0));
 select * into v_old from public.email_outbox where actor_scope=v_scope and email_type=p_type and idempotency_key=p_key;
 if found then
   if v_old.request_fingerprint is distinct from p_request_fingerprint then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='P0701'; end if;
   return v_old.email_outbox_id;
 end if;
 insert into public.email_outbox(submission_id,application_id,interview_id,email_type,environment_code,
   recipients,subject,body_text,template_version,idempotency_key,actor_scope,created_by_app_user_id,created_by_candidate_id,
   request_fingerprint,context_fingerprint,next_attempt_at)
 values(p_submission,p_application,p_interview,p_type,p_snapshot->>'environment_code',p_snapshot->'recipients',
   p_snapshot->>'subject',p_snapshot->>'body_text',p_snapshot->>'template_version',p_key,v_scope,p_actor,p_candidate,
   p_request_fingerprint,p_snapshot->>'context_fingerprint',clock_timestamp()) returning email_outbox_id into v_id;
 insert into public.security_audit_log(actor_auth_user_id,actor_app_user_id,actor_candidate_id,action_code,entity_type,entity_id,request_id,source_code,metadata)
 values(auth.uid(),p_actor,p_candidate,'EMAIL_ENQUEUED','EMAIL_OUTBOX',v_id,p_key,'RPC',
   jsonb_build_object('email_type',p_type,'submission_id',p_submission,'application_id',p_application,'interview_id',p_interview,
     'template_version',p_snapshot->>'template_version','environment_code',p_snapshot->>'environment_code'));
 return v_id;
end;
$$;
create or replace function private.enqueue_candidate_email(p_type text,p_submission uuid,p_candidate uuid,p_key uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_snapshot jsonb;
begin
 if p_type not in ('CANDIDATE_SUBMISSION_CONFIRMATION','HR_SUBMISSION_CREATED_NOTIFICATION','HR_SUBMISSION_UPDATED_NOTIFICATION')
   or not exists(select 1 from public.submissions where submission_id=p_submission and candidate_id=p_candidate)
   or p_candidate is distinct from private.current_candidate_id() then
   raise exception 'INVALID_EMAIL_CONTEXT' using errcode='P0701';
 end if;
 v_snapshot:=private.email_snapshot(p_type,p_submission,null,null);
 return private.persist_email(p_type,p_submission,null,null,null,p_candidate,p_key,
   encode(extensions.digest(jsonb_build_object('type',p_type,'submission_id',p_submission,'candidate_id',p_candidate)::text,'sha256'),'hex'),v_snapshot);
end;
$$;

create or replace function public.preview_email(p_email_type text,p_interview_id uuid,p_application_id uuid,p_submission_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.email'); v_snapshot jsonb;
begin
 if v_actor is null then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 if p_email_type not in ('INTERVIEW_INVITATION','INTERVIEW_PARTICIPANT_INVITATION') or p_email_type is null then
   return jsonb_build_object('success',false,'error_code','UNSUPPORTED_EMAIL_TYPE'); end if;
 if not private.can_read_email_context(p_email_type,p_submission_id,p_application_id,p_interview_id) then
   return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 perform private.lock_email_contexts(array[p_interview_id],v_actor);
 if private.interview_command_actor('interviews.email') is distinct from v_actor or
   not private.can_read_email_context(p_email_type,p_submission_id,p_application_id,p_interview_id) then
   return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 v_snapshot:=private.email_snapshot(p_email_type,p_submission_id,p_application_id,p_interview_id);
 return jsonb_build_object('success',true,'data',v_snapshot||jsonb_build_object('email_type',p_email_type,
   'interview_id',p_interview_id,'application_id',p_application_id,'submission_id',p_submission_id,
   'preview_fingerprint',encode(extensions.digest(v_snapshot::text,'sha256'),'hex')));
exception when sqlstate 'P0701' then return jsonb_build_object('success',false,'error_code',sqlerrm);
end;
$$;

create or replace function private.enqueue_manual_email(p_request jsonb,p_key uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_type text; v_i uuid; v_a uuid; v_s uuid; v_snapshot jsonb; v_fp text; v_result jsonb; v_id uuid;
begin
 if jsonb_typeof(p_request) is distinct from 'object' or p_key is null or
    p_request - array['email_type','interview_id','application_id','submission_id','preview_fingerprint'] <> '{}'::jsonb then
   raise exception 'VALIDATION_ERROR' using errcode='P0701'; end if;
 begin v_i:=(p_request->>'interview_id')::uuid; v_a:=(p_request->>'application_id')::uuid; v_s:=(p_request->>'submission_id')::uuid;
 exception when invalid_text_representation then raise exception 'VALIDATION_ERROR' using errcode='P0701'; end;
 v_type:=p_request->>'email_type';
 if v_type is null or v_type not in ('INTERVIEW_INVITATION','INTERVIEW_PARTICIPANT_INVITATION') then
   raise exception 'UNSUPPORTED_EMAIL_TYPE' using errcode='P0701'; end if;
 if private.interview_command_actor('interviews.email') is distinct from p_actor or
   not private.can_read_email_context(v_type,v_s,v_a,v_i) then raise exception 'FORBIDDEN' using errcode='P0701'; end if;
 if nullif(p_request->>'preview_fingerprint','') is null then raise exception 'PREVIEW_REQUIRED' using errcode='P0701'; end if;
 v_fp:=encode(extensions.digest(jsonb_build_object('email_type',v_type,'interview_id',v_i,'application_id',v_a,
   'submission_id',v_s,'preview_fingerprint',p_request->>'preview_fingerprint')::text,'sha256'),'hex');
 begin
   v_result:=private.check_idempotency('app_user:'||p_actor,'enqueue_email',p_key,v_fp);
 exception when check_violation then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='P0701'; end;
 if v_result is not null then return v_result; end if;
 v_snapshot:=private.email_snapshot(v_type,v_s,v_a,v_i);
 if p_request->>'preview_fingerprint' is distinct from encode(extensions.digest(v_snapshot::text,'sha256'),'hex') then
   raise exception 'STALE_PREVIEW' using errcode='P0701'; end if;
 v_id:=private.persist_email(v_type,v_s,v_a,v_i,p_actor,null,p_key,v_fp,v_snapshot);
 v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('email_outbox_id',v_id));
 perform private.record_idempotency('app_user:'||p_actor,'enqueue_email',p_key,v_fp,v_result,'EMAIL_OUTBOX',v_id);
 return v_result;
end;
$$;
create or replace function public.enqueue_email(p_request jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.email'); v_i uuid;
begin
 if v_actor is null then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 begin v_i:=(p_request->>'interview_id')::uuid;
 exception when invalid_text_representation then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end;
 perform private.lock_email_contexts(array[v_i],v_actor);
 return private.enqueue_manual_email(p_request,p_idempotency_key,v_actor);
exception when sqlstate 'P0701' then return jsonb_build_object('success',false,'error_code',sqlerrm);
end;
$$;
create or replace function public.bulk_enqueue_email(p_requests jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.email'); v_ids uuid[]:='{}'; v_item jsonb; v_r jsonb;
 v_success jsonb:='[]'; v_failed jsonb:='[]'; v_key uuid; v_fp text; v_existing jsonb; v_result jsonb;
 v_interview_id uuid;
begin
 if v_actor is null then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 if p_idempotency_key is null or jsonb_typeof(p_requests) is distinct from 'array' then
   return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
 if jsonb_array_length(p_requests) not between 1 and 100 then return jsonb_build_object('success',false,'error_code','BATCH_LIMIT_EXCEEDED'); end if;
-- Parse with PostgreSQL UUID semantics; malformed items remain per-item failures.
for v_item in select value from jsonb_array_elements(p_requests) loop
  begin v_interview_id:=(v_item->>'interview_id')::uuid;
  exception when invalid_text_representation then continue; end;
  if v_interview_id is not null then v_ids:=v_ids||v_interview_id; end if;
end loop;
select coalesce(array_agg(distinct x order by x),'{}'::uuid[]) into v_ids from unnest(v_ids) x;
perform private.lock_email_contexts(v_ids,v_actor);
 if private.interview_command_actor('interviews.email') is distinct from v_actor then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 v_fp:=encode(extensions.digest(p_requests::text,'sha256'),'hex');
 perform pg_advisory_xact_lock(hashtextextended('app_user:'||v_actor||':bulk_enqueue_email:'||p_idempotency_key,0));
 select result_payload into v_existing from public.idempotency_records where actor_scope='app_user:'||v_actor
   and command_type='bulk_enqueue_email' and idempotency_key=p_idempotency_key;
 if found then
   if v_existing->>'request_fingerprint' is distinct from v_fp then return jsonb_build_object('success',false,'error_code','IDEMPOTENCY_CONFLICT'); end if;
   -- Never disclose stored successful targets after current context access is lost.
   for v_item in select value from jsonb_array_elements(v_existing->'result'->'success') loop
     if not private.can_read_email_context(v_item->>'email_type',(v_item->>'submission_id')::uuid,
       (v_item->>'application_id')::uuid,(v_item->>'id')::uuid) then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
   end loop;
   return v_existing->'result';
 end if;
 for v_item in select value from jsonb_array_elements(p_requests) loop
   -- Stable target identity uses canonical UUID spelling.
   begin v_interview_id:=(v_item->>'interview_id')::uuid;
   exception when invalid_text_representation then v_interview_id:=null; end;
   v_key:=md5(p_idempotency_key::text||':'||coalesce(v_item->>'email_type','')||':'||coalesce(v_interview_id::text,''))::uuid;
   begin
     v_r:=private.enqueue_manual_email(v_item,v_key,v_actor);
     v_success:=v_success||jsonb_build_array(jsonb_build_object('id',v_item->>'interview_id','email_type',v_item->>'email_type',
       'application_id',v_item->>'application_id','submission_id',v_item->>'submission_id','email_outbox_id',v_r->'data'->>'email_outbox_id'));
   exception when sqlstate 'P0701' then
     v_failed:=v_failed||jsonb_build_array(jsonb_build_object('id',v_item->>'interview_id','error_code',sqlerrm));
   end;
 end loop;
 v_result:=jsonb_build_object('success',v_success,'failed',v_failed);
 insert into public.idempotency_records(actor_scope,command_type,idempotency_key,result_payload)
 values('app_user:'||v_actor,'bulk_enqueue_email',p_idempotency_key,jsonb_build_object('request_fingerprint',v_fp,'result',v_result));
 return v_result;
end;
$$;

-- Attempt completion, history and minimal immutable audit are one transaction.
create or replace function private.finish_email_attempt(p_outbox public.email_outbox,p_status text,p_provider text,p_error text,p_result jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
 update private.email_attempts set status_code=p_status,finished_at=clock_timestamp(),provider_message_id=p_provider,
   error_code=p_error,result_payload=p_result where attempt_id=p_outbox.attempt_id;
 insert into public.email_history(email_outbox_id,interview_id,application_id,submission_id,email_type,environment_code,
   recipients,subject,template_version,sent_by,sent_at,attempt_id,status_code,error_code)
 values(p_outbox.email_outbox_id,p_outbox.interview_id,p_outbox.application_id,p_outbox.submission_id,p_outbox.email_type,
   p_outbox.environment_code,p_outbox.recipients,p_outbox.subject,p_outbox.template_version,p_outbox.created_by_app_user_id,
   case when p_status='SENT' then clock_timestamp() end,p_outbox.attempt_id,p_status,p_error);
 insert into public.security_audit_log(action_code,entity_type,entity_id,source_code,result_code,metadata)
 values(case when p_status='SENT' then 'EMAIL_SENT' else 'EMAIL_DELIVERY_FAILED' end,'EMAIL_OUTBOX',p_outbox.email_outbox_id,'WORKER',
   case when p_status='SENT' then 'SUCCESS' else 'FAILED' end,
   jsonb_build_object('attempt_id',p_outbox.attempt_id,'attempt_no',p_outbox.attempt_no,'status_code',p_status,'error_code',p_error,
     'submission_id',p_outbox.submission_id,'application_id',p_outbox.application_id,'interview_id',p_outbox.interview_id));
end;
$$;

do $$ begin
 if not exists(select 1 from pg_roles where rolname='email_worker') then create role email_worker nologin noinherit; end if;
end $$;
-- The role has only these RPCs, no table access, no membership in service_role.
create or replace function public.claim_email_outbox(p_worker_id text,p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_o public.email_outbox%rowtype; v_now timestamptz:=clock_timestamp(); v_token uuid; v_items jsonb:='[]';
 v_ids uuid[]:='{}'; v_context_ids uuid[]:='{}'; v_candidate uuid;
begin
 if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$' or p_limit is null or p_limit not between 1 and 100 then
   return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
 if not exists(select 1 from private.email_configuration where singleton and not delivery_paused
   and (delivery_not_before is null or delivery_not_before<=v_now)) then return jsonb_build_object('success',true,'data','[]'::jsonb); end if;
-- Lock order is context (Interview FK parent) before outbox for every worker
-- operation. A per-outbox advisory try-lock replaces FOR UPDATE SKIP LOCKED:
-- it keeps competing claims nonblocking without taking the outbox lock before
-- the Interview FK parent. The row is re-read after the parent lock, so stale
-- candidates are skipped without reversing the authorization order.
-- Reserve up to p_limit rows before consuming the limit. Advisory try-locks
-- skip rows already claimed by another worker without waiting.
for v_candidate in select email_outbox_id from public.email_outbox where request_fingerprint is not null and
  (((status_code='QUEUED' or (status_code='FAILED' and next_attempt_at is not null))
     and attempt_no<3 and coalesce(next_attempt_at,v_now)<=v_now)
    or (status_code='SENDING' and locked_until<=v_now))
  order by interview_id nulls first,email_outbox_id loop
  if pg_try_advisory_xact_lock(hashtextextended('email-outbox:'||v_candidate::text,0)) then
    v_ids:=v_ids||v_candidate;
    if cardinality(v_ids)>=p_limit then exit; end if;
  end if;
end loop;
select coalesce(array_agg(distinct interview_id order by interview_id),'{}'::uuid[]) into v_context_ids
from public.email_outbox where email_outbox_id=any(v_ids) and interview_id is not null;
if cardinality(v_context_ids)>0 then perform private.lock_email_contexts(v_context_ids,null); end if;
foreach v_candidate in array v_ids loop
  select * into v_o from public.email_outbox where email_outbox_id=v_candidate for update;
  if not found or not (v_o.request_fingerprint is not null and
    (((v_o.status_code='QUEUED' or (v_o.status_code='FAILED' and v_o.next_attempt_at is not null))
       and v_o.attempt_no<3 and coalesce(v_o.next_attempt_at,v_now)<=v_now)
      or (v_o.status_code='SENDING' and v_o.locked_until<=v_now))) then
    continue;
  end if;
  if v_o.status_code='SENDING' then
    perform private.finish_email_attempt(v_o,'ABANDONED',null,'LEASE_EXPIRED',jsonb_build_object('success',false,'error_code','LEASE_EXPIRED'));
    if v_o.attempt_no>=3 then
      update public.email_outbox set status_code='FAILED',next_attempt_at=null,locked_at=null,locked_until=null,worker_id=null,
        last_error='RETRY_EXHAUSTED',provider_error_code='RETRY_EXHAUSTED' where email_outbox_id=v_o.email_outbox_id;
      continue;
    end if;
  end if;
  v_token:=gen_random_uuid();
  update public.email_outbox set status_code='SENDING',attempt_no=attempt_no+1,attempt_id=v_token,
    locked_at=v_now,locked_until=v_now+interval '2 minutes',worker_id=p_worker_id,next_attempt_at=null
  where email_outbox_id=v_o.email_outbox_id returning * into v_o;
  insert into private.email_attempts(attempt_id,email_outbox_id,attempt_no,worker_id,claimed_at,locked_until,status_code)
  values(v_token,v_o.email_outbox_id,v_o.attempt_no,p_worker_id,v_now,v_o.locked_until,'SENDING');
  v_items:=v_items||jsonb_build_array(jsonb_build_object('email_outbox_id',v_o.email_outbox_id,'attempt_id',v_token,
    'attempt_no',v_o.attempt_no,'locked_until',v_o.locked_until));
end loop;
 return jsonb_build_object('success',true,'data',v_items);
end;
$$;
create or replace function public.authorize_email_send(p_email_outbox_id uuid,p_attempt_id uuid,p_worker_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_o public.email_outbox%rowtype; v_snapshot jsonb; v_error text; v_sink text;
begin
 select * into v_o from public.email_outbox where email_outbox_id=p_email_outbox_id;
 if not found then return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
 if v_o.interview_id is not null then perform private.lock_email_contexts(array[v_o.interview_id],null); end if;
select * into v_o from public.email_outbox where email_outbox_id=p_email_outbox_id for update;
if not found then return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
if v_o.status_code<>'SENDING' or v_o.attempt_id is distinct from p_attempt_id or v_o.worker_id is distinct from p_worker_id
  or v_o.locked_until<=clock_timestamp() then return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
 if v_o.interview_id is not null then
   begin
     v_snapshot:=private.email_snapshot(v_o.email_type,v_o.submission_id,v_o.application_id,v_o.interview_id);
     if v_snapshot->>'context_fingerprint' is distinct from v_o.context_fingerprint then v_error:='STALE_PREVIEW'; end if;
   exception when sqlstate 'P0701' then v_error:=sqlerrm; end;
 end if;
 if v_error is not null then
   perform private.finish_email_attempt(v_o,'CANCELLED',null,v_error,jsonb_build_object('success',false,'error_code',v_error));
   update public.email_outbox set status_code='CANCELLED',last_error=v_error,provider_error_code=v_error,
     next_attempt_at=null,locked_at=null,locked_until=null,worker_id=null where email_outbox_id=p_email_outbox_id;
   return jsonb_build_object('success',false,'error_code',v_error);
 end if;
 -- Configuration can pause dispatch without undoing valid Candidate Saves.
 if not exists(select 1 from private.email_configuration where singleton and not delivery_paused
   and (delivery_not_before is null or delivery_not_before<=clock_timestamp())) then
   return jsonb_build_object('success',false,'error_code','DELIVERY_PAUSED'); end if;
 select test_sink into v_sink from private.email_configuration where singleton;
 update private.email_attempts set authorized_at=clock_timestamp() where attempt_id=p_attempt_id;
 return jsonb_build_object('success',true,'data',jsonb_build_object('email_outbox_id',v_o.email_outbox_id,'attempt_id',v_o.attempt_id,
   'environment_code',v_o.environment_code,'recipients',case when v_o.environment_code='TEST' then
      jsonb_build_object('to',jsonb_build_array(v_sink),'cc','[]'::jsonb) else v_o.recipients end,
   'subject',v_o.subject,'body_text',v_o.body_text,'template_version',v_o.template_version));
end;
$$;
create or replace function public.complete_email_attempt(p_email_outbox_id uuid,p_attempt_id uuid,p_worker_id text,
 p_outcome text,p_provider_message_id text default null,p_error_code text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_o public.email_outbox%rowtype; v_a private.email_attempts%rowtype; v_result jsonb; v_retry boolean;
begin
 if p_outcome is null or p_outcome not in ('SENT','RETRYABLE_FAILURE','PERMANENT_FAILURE') or
   (p_outcome='SENT' and (p_provider_message_id is null or p_provider_message_id !~ '^[A-Za-z0-9_.:@/+==-]{1,200}$' or p_error_code is not null)) or
   (p_outcome<>'SENT' and (p_provider_message_id is not null or p_error_code is null or p_error_code not in
      ('PROVIDER_TEMPORARY','PROVIDER_REJECTED','RATE_LIMITED','NETWORK_ERROR'))) then
   return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
-- Context is locked before the outbox row, matching authorization and reclaim.
select * into v_o from public.email_outbox where email_outbox_id=p_email_outbox_id;
if not found then return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
if v_o.interview_id is not null then perform private.lock_email_contexts(array[v_o.interview_id],null); end if;
select * into v_o from public.email_outbox where email_outbox_id=p_email_outbox_id for update;
if not found then return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
select * into v_a from private.email_attempts where attempt_id=p_attempt_id and email_outbox_id=p_email_outbox_id;
if not found or v_a.worker_id is distinct from p_worker_id then return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
 v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('outcome',p_outcome,'provider_message_id',p_provider_message_id,'error_code',p_error_code));
 if v_a.finished_at is not null then
   if v_a.result_payload=v_result then return v_result; end if;
   return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT');
 end if;
 if v_o.status_code<>'SENDING' or v_o.attempt_id is distinct from p_attempt_id or v_o.worker_id is distinct from p_worker_id
   or v_o.locked_until<=clock_timestamp() or v_a.authorized_at is null then
   return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
 v_retry:=p_outcome='RETRYABLE_FAILURE' and v_o.attempt_no<3;
 perform private.finish_email_attempt(v_o,case when p_outcome='SENT' then 'SENT' else 'FAILED' end,p_provider_message_id,p_error_code,v_result);
 update public.email_outbox set status_code=case when p_outcome='SENT' then 'SENT' else 'FAILED' end,
   next_attempt_at=case when v_retry then clock_timestamp()+make_interval(secs=>case when attempt_no=1 then 30 else 120 end) end,
   sent_at=case when p_outcome='SENT' then clock_timestamp() end,provider_message_id=p_provider_message_id,
   provider_error_code=p_error_code,last_error=p_error_code,provider_error_message=null,locked_at=null,locked_until=null,worker_id=null
 where email_outbox_id=p_email_outbox_id;
 return v_result;
end;
$$;

create or replace function public.delete_email_history(p_email_history_id uuid,p_classification text,p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('emails.history_delete'); v_h public.email_history%rowtype;
begin
 if v_actor is null or not private.has_permission('emails.history_view') then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 select * into v_h from public.email_history where email_history_id=p_email_history_id;
 if not found or not private.can_read_email_context(v_h.email_type,v_h.submission_id,v_h.application_id,v_h.interview_id) then
   return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 perform private.lock_email_contexts(array[v_h.interview_id],v_actor);
 select * into v_h from public.email_history where email_history_id=p_email_history_id for update;
 if not found or not private.has_permission('emails.history_delete') or not private.has_permission('emails.history_view') or
   not private.can_read_email_context(v_h.email_type,v_h.submission_id,v_h.application_id,v_h.interview_id) then
   return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
 if p_classification is null or p_classification not in ('TEST_RECORD','WRONG_RECORD') or
   (p_classification='TEST_RECORD' and v_h.environment_code<>'TEST') or
   (p_classification='WRONG_RECORD' and nullif(btrim(p_reason),'') is null) or length(p_reason)>1000 then
   return jsonb_build_object('success',false,'error_code','INVALID_CLEANUP_CLASSIFICATION'); end if;
 insert into public.security_audit_log(actor_auth_user_id,actor_app_user_id,action_code,entity_type,entity_id,source_code,reason,metadata)
 values(auth.uid(),v_actor,'EMAIL_HISTORY_DELETED','EMAIL_HISTORY',p_email_history_id,'RPC',nullif(btrim(p_reason),''),
   jsonb_build_object('classification',p_classification,'submission_id',v_h.submission_id,'application_id',v_h.application_id,
     'interview_id',v_h.interview_id,'email_outbox_id',v_h.email_outbox_id,'attempt_id',v_h.attempt_id));
 delete from public.email_history where email_history_id=p_email_history_id;
 return jsonb_build_object('success',true,'data',jsonb_build_object('email_history_id',p_email_history_id));
end;
$$;

-- Explicit least privilege. No private mutator is available through browser RPC.
revoke all on function private.lock_email_contexts(uuid[],uuid),private.email_snapshot(text,uuid,uuid,uuid),
 private.persist_email(text,uuid,uuid,uuid,uuid,uuid,uuid,text,jsonb),private.enqueue_candidate_email(text,uuid,uuid,uuid),
 private.enqueue_manual_email(jsonb,uuid,uuid),private.finish_email_attempt(public.email_outbox,text,text,text,jsonb)
 from public,anon,authenticated,service_role;
revoke all on function public.preview_email(text,uuid,uuid,uuid),public.enqueue_email(jsonb,uuid),public.bulk_enqueue_email(jsonb,uuid),
 public.delete_email_history(uuid,text,text) from public,anon;
grant execute on function public.preview_email(text,uuid,uuid,uuid),public.enqueue_email(jsonb,uuid),public.bulk_enqueue_email(jsonb,uuid),
 public.delete_email_history(uuid,text,text) to authenticated;
revoke all on function public.claim_email_outbox(text,integer),public.authorize_email_send(uuid,uuid,text),
 public.complete_email_attempt(uuid,uuid,text,text,text,text) from public,anon,authenticated,service_role;
grant usage on schema public to email_worker;
grant execute on function public.claim_email_outbox(text,integer),public.authorize_email_send(uuid,uuid,text),
 public.complete_email_attempt(uuid,uuid,text,text,text,text) to email_worker;

-- Forward Candidate reconciliation: only the two enqueue blocks change.
-- All accepted form-session/privacy/document/status/result contracts remain verbatim.
create or replace function public.submit_candidate_submission(
  p_candidate_form_session_id uuid,
  p_full_name text,
  p_phone text default null,
  p_date_of_birth date default null,
  p_gender text default null,
  p_address text default null,
  p_education jsonb default '[]'::jsonb,
  p_privacy_notice_version text default null,
  p_idempotency_key uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_cand record;
  v_session record;
  v_submission_id uuid;
  v_submitted_at timestamptz;
  v_item jsonb;
  v_chg record;
  v_res record;
  v_log_id uuid;
  v_current_notice_version text;
  v_idx integer;
  v_sort integer;
  v_qual_id uuid;
  v_current_notice_content_vi text;
  v_current_notice_content_en text;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_result jsonb;
begin
  -- 1. Canonical Authentication & Active Verification
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  select * into v_cand
  from public.candidates
  where auth_user_id = v_auth_uid;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  if not v_cand.is_active then
    return jsonb_build_object('success', false, 'error_code', 'USER_INACTIVE', 'message', 'Candidate account is inactive');
  end if;

  -- 2. Deterministic Lock Sequence: Lock 1 - candidate identity
  perform 1
  from public.candidates
  where candidate_id = v_cand.candidate_id
  for update;

  -- 3. Lock 2: form session
  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_candidate_form_session_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate form session not found or access denied');
  end if;
  if p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key is required');
  end if;

  v_actor_scope := 'candidate:' || v_cand.candidate_id::text;
  v_fingerprint := encode(
    extensions.digest(
      convert_to(jsonb_build_object(
        'command', 'submit_candidate_submission',
        'candidate_form_session_id', p_candidate_form_session_id,
        'full_name', p_full_name,
        'phone', p_phone,
        'date_of_birth', p_date_of_birth,
        'gender', p_gender,
        'address', p_address,
        'education', p_education,
        'privacy_notice_version', p_privacy_notice_version
      )::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(hashtextextended(v_actor_scope || ':submit_candidate_submission:' || p_idempotency_key::text, 0));
  select result_payload into v_existing_result
  from public.idempotency_records
  where actor_scope = v_actor_scope
    and command_type = 'submit_candidate_submission'
    and idempotency_key = p_idempotency_key;
  if found then
    if v_existing_result ->> 'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key has already been used for a different request');
    end if;
    return v_existing_result -> 'result';
  end if;

  if v_session.status_code <> 'OPEN' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Candidate form session is not open');
  end if;

  if v_session.expires_at <= clock_timestamp() then
    return jsonb_build_object('success', false, 'error_code', 'FORM_SESSION_EXPIRED', 'message', 'Candidate form session has expired');
  end if;

  if v_session.mode_code <> 'NEW_SUBMISSION' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_ACTION', 'message', 'submit_candidate_submission requires a NEW_SUBMISSION form session');
  end if;

  -- 4. Privacy Notice Verification (Strong-Current Verification)
  if p_privacy_notice_version is null or p_privacy_notice_version <> v_session.presented_privacy_notice_version then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Acknowledged privacy notice version must match server-pinned notice version');
  end if;

  -- Strong-current check: re-verify notice is currently effective and published
  select notice_version, content_vi, content_en
  into v_current_notice_version, v_current_notice_content_vi, v_current_notice_content_en
  from public.privacy_notice_versions
  where is_current = true
    and effective_from <= clock_timestamp()
  order by effective_from desc
  limit 1;

  if v_current_notice_version is null then
    return jsonb_build_object('success', false, 'error_code', 'PRIVACY_NOTICE_UNAVAILABLE', 'message', 'Current privacy notice is unavailable');
  end if;

  if v_current_notice_version <> p_privacy_notice_version then
    update public.candidate_form_sessions
    set presented_privacy_notice_version = v_current_notice_version,
        updated_at = clock_timestamp()
    where candidate_form_session_id = p_candidate_form_session_id;
    return jsonb_build_object(
      'success', false,
      'error_code', 'PRIVACY_NOTICE_CHANGED',
      'message', 'Privacy notice has been updated; review and acknowledge the current version',
      'data', jsonb_build_object(
        'privacy_notice_version', v_current_notice_version,
        'content_vi', v_current_notice_content_vi,
        'content_en', v_current_notice_content_en
      )
    );
  end if;

  -- 5. Field Validations (Canonical Validation Contract)
  if p_full_name is null or btrim(p_full_name) = '' or char_length(btrim(p_full_name)) > 200 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Full name is required and must not exceed 200 characters');
  end if;

  if p_phone is null or btrim(p_phone) = '' or char_length(btrim(p_phone)) > 32 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Phone number is required and must not exceed 32 characters');
  end if;

  if p_date_of_birth is null or p_date_of_birth < '1900-01-01'::date or p_date_of_birth > current_date then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Date of birth is required and must be between 1900-01-01 and today');
  end if;

  if p_gender is null or upper(btrim(p_gender)) not in ('MALE', 'FEMALE') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Gender must be MALE or FEMALE');
  end if;

  if p_address is null or btrim(p_address) = '' or char_length(btrim(p_address)) > 500 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Address is required and must not exceed 500 characters');
  end if;

  -- Education validation (max 20 items, array type)
  if p_education is not null then
    if jsonb_typeof(p_education) <> 'array' then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Education must be an array');
    end if;
    if jsonb_array_length(p_education) > 20 then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Education cannot exceed 20 items');
    end if;
  end if;
  -- Pre-validate every education qualification before any parent or child mutation.
  if p_education is not null and jsonb_typeof(p_education) = 'array' then
    for v_item in select * from jsonb_array_elements(p_education) loop
      if v_item->>'qualification_id' is not null and btrim(v_item->>'qualification_id') <> '' then
        begin
          v_qual_id := (v_item->>'qualification_id')::uuid;
        exception when others then
          return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid qualification_id format');
        end;
        if not exists (
          select 1
          from public.qualification_levels
          where qualification_id = v_qual_id
            and is_active = true
        ) then
          return jsonb_build_object('success', false, 'error_code', 'INACTIVE_QUALIFICATION_NOT_SELECTABLE', 'message', 'Selected qualification level is inactive');
        end if;
      end if;
    end loop;
  end if;

  -- 6. Document Plan Pre-Materialization Validation
  begin
    perform private.validate_candidate_form_document_plan(p_candidate_form_session_id);
  exception
    when sqlstate '23514' then
      if sqlerrm like '%REQUIRED_CV_DOCUMENT_MISSING%' then
        return jsonb_build_object('success', false, 'error_code', 'REQUIRED_CV_DOCUMENT_MISSING', 'message', 'A valid current CV document is required');
      elsif sqlerrm like '%MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED%' then
        return jsonb_build_object('success', false, 'error_code', 'MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED', 'message', 'A submission cannot exceed 5 current documents');
      elsif sqlerrm like '%UPLOAD_RESERVATION_NOT_CLEAN%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_NOT_CLEAN', 'message', 'All uploaded documents must be validated and verified clean');
      elsif sqlerrm like '%UPLOAD_RESERVATION_EXPIRED%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'An upload reservation has expired');
      else
        return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', sqlerrm);
      end if;
  end;

  -- 7. Insert public.submissions (Canonical Columns Only)
  v_submission_id := gen_random_uuid();
  v_submitted_at := clock_timestamp();

  insert into public.submissions (
    submission_id,
    candidate_id,
    status_code,
    full_name,
    date_of_birth,
    gender_code,
    current_address,
    phone,
    email_snapshot,
    submitted_at,
    created_at,
    updated_at,
    updated_by_candidate_id,
    version_no
  ) values (
    v_submission_id,
    v_cand.candidate_id,
    'NEW',
    btrim(p_full_name),
    p_date_of_birth,
    upper(btrim(p_gender)),
    btrim(p_address),
    btrim(p_phone),
    v_cand.email,
    v_submitted_at,
    v_submitted_at,
    v_submitted_at,
    v_cand.candidate_id,
    1
  );

  -- 8. Insert Education Rows (1-based sort order)
  if p_education is not null and jsonb_typeof(p_education) = 'array' then
    v_sort := 1;
    for v_item in select * from jsonb_array_elements(p_education) loop
      -- Validate qualification_id if provided
      if v_item->>'qualification_id' is not null and btrim(v_item->>'qualification_id') <> '' then
        begin
          v_qual_id := (v_item->>'qualification_id')::uuid;
        exception when others then
          return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid qualification_id format');
        end;
        if not exists (select 1 from public.qualification_levels where qualification_id = v_qual_id and is_active = true) then
          return jsonb_build_object('success', false, 'error_code', 'INACTIVE_QUALIFICATION_NOT_SELECTABLE', 'message', 'Selected qualification level is inactive');
        end if;
      else
        v_qual_id := null;
      end if;

      insert into public.submission_education (
        submission_id,
        sort_order,
        period_text,
        qualification_id,
        major,
        institution
      ) values (
        v_submission_id,
        v_sort,
        nullif(btrim(v_item->>'period_text'), ''),
        v_qual_id,
        nullif(btrim(v_item->>'major'), ''),
        nullif(btrim(v_item->>'institution'), '')
      );
      v_sort := v_sort + 1;
    end loop;
  end if;

  -- 9. Materialize Staged Document Changes
  -- Non-unique logical header on ADD
  for v_chg in
    select *
    from public.candidate_form_document_changes
    where candidate_form_session_id = p_candidate_form_session_id
      and status_code = 'PENDING'
    for update
  loop
    select * into v_res
    from public.upload_reservations
    where upload_reservation_id = v_chg.upload_reservation_id
    for update;

    -- ADD creates a NEW logical header; sets candidate creator
    insert into public.submission_document_logicals (
      submission_id,
      document_type_id,
      created_by_candidate_id,
      created_by_app_user_id,
      created_at
    ) values (
      v_submission_id,
      v_chg.intended_document_type_id,
      v_cand.candidate_id,
      null,
      v_submitted_at
    )
    returning logical_document_id into v_log_id;

    -- Insert version 1
    insert into public.submission_documents (
      logical_document_id,
      storage_bucket,
      storage_path,
      original_filename,
      mime_type,
      file_size_bytes,
      checksum_sha256,
      version_no,
      is_current,
      uploaded_by_candidate_id,
      uploaded_by_app_user_id,
      uploaded_at
    ) values (
      v_log_id,
      v_res.temp_bucket,
      v_res.temp_path,
      v_res.original_filename,
      coalesce(v_res.detected_mime_type, v_res.declared_mime_type, 'application/pdf'),
      coalesce(v_res.actual_size_bytes, v_res.expected_max_size_bytes, 1024),
      v_res.checksum_sha256,
      1,
      true,
      v_cand.candidate_id,
      null,
      v_submitted_at
    );

    update public.candidate_form_document_changes
    set status_code = 'APPLIED'
    where candidate_form_document_change_id = v_chg.candidate_form_document_change_id;

    update public.upload_reservations
    set status_code = 'FINALIZED'
    where upload_reservation_id = v_chg.upload_reservation_id;
  end loop;

  -- 10. Privacy Acknowledgement
  insert into public.privacy_acknowledgements (
    submission_id,
    notice_version,
    acknowledged_at,
    source_code
  ) values (
    v_submission_id,
    p_privacy_notice_version,
    v_submitted_at,
    'CANDIDATE_PORTAL'
  )
  on conflict (submission_id, notice_version) do nothing;

  -- 11. Refresh Candidate Profile Cache
  perform private.refresh_candidate_current_profile(v_cand.candidate_id);

  -- Required HR notification and accepted Candidate confirmation share Save's transaction.
  perform private.enqueue_candidate_email('HR_SUBMISSION_CREATED_NOTIFICATION',
    v_submission_id, v_cand.candidate_id, p_idempotency_key);
  perform private.enqueue_candidate_email('CANDIDATE_SUBMISSION_CONFIRMATION',
    v_submission_id, v_cand.candidate_id, p_idempotency_key);

  -- 13. Transition Form Session to SUBMITTED
  update public.candidate_form_sessions
  set
    status_code = 'SUBMITTED',
    updated_at = v_submitted_at
  where candidate_form_session_id = p_candidate_form_session_id;

  -- 14. Security Audit Log
  insert into public.security_audit_log (
    action_code,
    actor_candidate_id,
    entity_type,
    entity_id,
    metadata,
    source_code,
    result_code
  ) values (
    'SUBMIT_CANDIDATE_SUBMISSION',
    v_cand.candidate_id,
    'SUBMISSION',
    v_submission_id,
    jsonb_build_object(
      'submission_id', v_submission_id,
      'candidate_id', v_cand.candidate_id,
      'status_code', 'NEW',
      'version_no', 1,
      'changed_fields', jsonb_build_array('full_name', 'phone', 'date_of_birth', 'gender_code', 'current_address', 'education', 'documents', 'privacy_notice')
    ),
    'RPC',
    'SUCCESS'
  );
  v_result := jsonb_build_object(
    'success', true,
    'submission_id', v_submission_id,
    'status_code', 'NEW',
    'version_no', 1
  );
  insert into public.idempotency_records (
    actor_scope,
    command_type,
    idempotency_key,
    result_entity_type,
    result_entity_id,
    result_payload
  ) values (
    v_actor_scope,
    'submit_candidate_submission',
    p_idempotency_key,
    'SUBMISSION',
    v_submission_id,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  )
  on conflict (actor_scope, command_type, idempotency_key) do nothing;
  return v_result;
end;
$$;

revoke all on function public.submit_candidate_submission(uuid, text, text, date, text, text, jsonb, text, uuid) from public, anon;
grant execute on function public.submit_candidate_submission(uuid, text, text, date, text, text, jsonb, text, uuid) to authenticated;

create or replace function public.update_candidate_submission(
  p_candidate_form_session_id uuid,
  p_full_name text,
  p_phone text default null,
  p_date_of_birth date default null,
  p_gender text default null,
  p_address text default null,
  p_education jsonb default '[]'::jsonb,
  p_privacy_notice_version text default null,
  p_idempotency_key uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_cand record;
  v_session record;
  v_sub record;
  v_now timestamptz;
  v_item jsonb;
  v_chg record;
  v_res record;
  v_log record;
  v_current_doc record;
  v_new_doc_id uuid;
  v_current_notice_version text;
  v_sort integer;
  v_qual_id uuid;
  v_current_notice_content_vi text;
  v_current_notice_content_en text;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_result jsonb;
begin
  -- 1. Authentication & Active Verification
  v_auth_uid := auth.uid();
  if v_auth_uid is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  select * into v_cand
  from public.candidates
  where auth_user_id = v_auth_uid;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Candidate authentication required');
  end if;

  if not v_cand.is_active then
    return jsonb_build_object('success', false, 'error_code', 'USER_INACTIVE', 'message', 'Candidate account is inactive');
  end if;

  -- 2. Deterministic Lock Sequence: Lock 1 - candidate identity
  perform 1
  from public.candidates
  where candidate_id = v_cand.candidate_id
  for update;

  -- 3. Lock 2: form session
  select * into v_session
  from public.candidate_form_sessions
  where candidate_form_session_id = p_candidate_form_session_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate form session not found or access denied');
  end if;
  if p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key is required');
  end if;

  v_actor_scope := 'candidate:' || v_cand.candidate_id::text;
  v_fingerprint := encode(
    extensions.digest(
      convert_to(jsonb_build_object(
        'command', 'update_candidate_submission',
        'candidate_form_session_id', p_candidate_form_session_id,
        'full_name', p_full_name,
        'phone', p_phone,
        'date_of_birth', p_date_of_birth,
        'gender', p_gender,
        'address', p_address,
        'education', p_education,
        'privacy_notice_version', p_privacy_notice_version
      )::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(hashtextextended(v_actor_scope || ':update_candidate_submission:' || p_idempotency_key::text, 0));
  select result_payload into v_existing_result
  from public.idempotency_records
  where actor_scope = v_actor_scope
    and command_type = 'update_candidate_submission'
    and idempotency_key = p_idempotency_key;
  if found then
    if v_existing_result ->> 'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key has already been used for a different request');
    end if;
    return v_existing_result -> 'result';
  end if;

  if v_session.status_code <> 'OPEN' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Candidate form session is not open');
  end if;

  if v_session.expires_at <= clock_timestamp() then
    return jsonb_build_object('success', false, 'error_code', 'FORM_SESSION_EXPIRED', 'message', 'Candidate form session has expired');
  end if;

  if v_session.mode_code <> 'EDIT_SUBMISSION' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_ACTION', 'message', 'update_candidate_submission requires an EDIT_SUBMISSION form session');
  end if;

  -- 4. Lock 3: Target Submission
  select * into v_sub
  from public.submissions
  where submission_id = v_session.target_submission_id
    and candidate_id = v_cand.candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Target submission not found or access denied');
  end if;

  if v_sub.status_code <> 'NEW' then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_STATE', 'message', 'Submission is no longer in NEW status and cannot be edited by candidate');
  end if;

  if v_sub.version_no <> v_session.base_submission_version_no then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Submission has been modified since session was opened');
  end if;

  -- 5. Strong-Current Privacy Notice Verification
  if p_privacy_notice_version is null or p_privacy_notice_version <> v_session.presented_privacy_notice_version then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Acknowledged privacy notice version must match server-pinned notice version');
  end if;

  select notice_version, content_vi, content_en
  into v_current_notice_version, v_current_notice_content_vi, v_current_notice_content_en
  from public.privacy_notice_versions
  where is_current = true
    and effective_from <= clock_timestamp()
  order by effective_from desc
  limit 1;

  if v_current_notice_version is null then
    return jsonb_build_object('success', false, 'error_code', 'PRIVACY_NOTICE_UNAVAILABLE', 'message', 'Current privacy notice is unavailable');
  end if;

  if v_current_notice_version <> p_privacy_notice_version then
    update public.candidate_form_sessions
    set presented_privacy_notice_version = v_current_notice_version,
        updated_at = clock_timestamp()
    where candidate_form_session_id = p_candidate_form_session_id;
    return jsonb_build_object(
      'success', false,
      'error_code', 'PRIVACY_NOTICE_CHANGED',
      'message', 'Privacy notice has been updated; review and acknowledge the current version',
      'data', jsonb_build_object(
        'privacy_notice_version', v_current_notice_version,
        'content_vi', v_current_notice_content_vi,
        'content_en', v_current_notice_content_en
      )
    );
  end if;

  -- 6. Field Validations (Canonical Validation Contract)
  if p_full_name is null or btrim(p_full_name) = '' or char_length(btrim(p_full_name)) > 200 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Full name is required and must not exceed 200 characters');
  end if;

  if p_phone is null or btrim(p_phone) = '' or char_length(btrim(p_phone)) > 32 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Phone number is required and must not exceed 32 characters');
  end if;

  if p_date_of_birth is null or p_date_of_birth < '1900-01-01'::date or p_date_of_birth > current_date then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Date of birth is required and must be between 1900-01-01 and today');
  end if;

  if p_gender is null or upper(btrim(p_gender)) not in ('MALE', 'FEMALE') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Gender must be MALE or FEMALE');
  end if;

  if p_address is null or btrim(p_address) = '' or char_length(btrim(p_address)) > 500 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Address is required and must not exceed 500 characters');
  end if;

  if p_education is not null then
    if jsonb_typeof(p_education) <> 'array' then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Education must be an array');
    end if;
    if jsonb_array_length(p_education) > 20 then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Education cannot exceed 20 items');
    end if;
  end if;
  -- Pre-validate every education qualification before any parent or child mutation.
  if p_education is not null and jsonb_typeof(p_education) = 'array' then
    for v_item in select * from jsonb_array_elements(p_education) loop
      if v_item->>'qualification_id' is not null and btrim(v_item->>'qualification_id') <> '' then
        begin
          v_qual_id := (v_item->>'qualification_id')::uuid;
        exception when others then
          return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid qualification_id format');
        end;
        if not exists (
          select 1
          from public.qualification_levels
          where qualification_id = v_qual_id
            and is_active = true
        ) then
          return jsonb_build_object('success', false, 'error_code', 'INACTIVE_QUALIFICATION_NOT_SELECTABLE', 'message', 'Selected qualification level is inactive');
        end if;
      end if;
    end loop;
  end if;

  -- 7. Document Plan Pre-Materialization Validation
  begin
    perform private.validate_candidate_form_document_plan(p_candidate_form_session_id);
  exception
    when sqlstate '23514' then
      if sqlerrm like '%REQUIRED_CV_DOCUMENT_MISSING%' then
        return jsonb_build_object('success', false, 'error_code', 'REQUIRED_CV_DOCUMENT_MISSING', 'message', 'A valid current CV document is required');
      elsif sqlerrm like '%MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED%' then
        return jsonb_build_object('success', false, 'error_code', 'MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED', 'message', 'A submission cannot exceed 5 current documents');
      elsif sqlerrm like '%UPLOAD_RESERVATION_NOT_CLEAN%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_NOT_CLEAN', 'message', 'All uploaded documents must be validated and verified clean');
      elsif sqlerrm like '%UPLOAD_RESERVATION_EXPIRED%' then
        return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED', 'message', 'An upload reservation has expired');
      else
        return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', sqlerrm);
      end if;
  end;

  v_now := clock_timestamp();

  -- 8. Update public.submissions (Candidate-owned mutable fields ONLY)
  -- HR-only fields (other_info, hr_note, etc.) remain untouched!
  update public.submissions
  set
    full_name = btrim(p_full_name),
    phone = btrim(p_phone),
    date_of_birth = p_date_of_birth,
    gender_code = upper(btrim(p_gender)),
    current_address = btrim(p_address),
    updated_at = v_now,
    updated_by_candidate_id = v_cand.candidate_id,
    updated_by_internal_user_id = null
  where submission_id = v_sub.submission_id
  returning * into v_sub;

  -- 9. Replace Education child rows
  delete from public.submission_education where submission_id = v_sub.submission_id;

  if p_education is not null and jsonb_typeof(p_education) = 'array' then
    v_sort := 1;
    for v_item in select * from jsonb_array_elements(p_education) loop
      if v_item->>'qualification_id' is not null and btrim(v_item->>'qualification_id') <> '' then
        begin
          v_qual_id := (v_item->>'qualification_id')::uuid;
        exception when others then
          return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid qualification_id format');
        end;
        if not exists (select 1 from public.qualification_levels where qualification_id = v_qual_id and is_active = true) then
          return jsonb_build_object('success', false, 'error_code', 'INACTIVE_QUALIFICATION_NOT_SELECTABLE', 'message', 'Selected qualification level is inactive');
        end if;
      else
        v_qual_id := null;
      end if;

      insert into public.submission_education (
        submission_id,
        sort_order,
        period_text,
        qualification_id,
        major,
        institution
      ) values (
        v_sub.submission_id,
        v_sort,
        nullif(btrim(v_item->>'period_text'), ''),
        v_qual_id,
        nullif(btrim(v_item->>'major'), ''),
        nullif(btrim(v_item->>'institution'), '')
      );
      v_sort := v_sort + 1;
    end loop;
  end if;

  -- 10. Materialize Staged Document Changes (ADD / REPLACE / DELETE)
  for v_chg in
    select *
    from public.candidate_form_document_changes
    where candidate_form_session_id = p_candidate_form_session_id
      and status_code = 'PENDING'
    for update
  loop
    if v_chg.action_code = 'ADD' then
      select * into v_res from public.upload_reservations where upload_reservation_id = v_chg.upload_reservation_id for update;

      insert into public.submission_document_logicals (
        submission_id,
        document_type_id,
        created_by_candidate_id,
        created_by_app_user_id,
        created_at
      ) values (
        v_sub.submission_id,
        v_chg.intended_document_type_id,
        v_cand.candidate_id,
        null,
        v_now
      )
      returning logical_document_id into v_log.logical_document_id;

      insert into public.submission_documents (
        logical_document_id,
        storage_bucket,
        storage_path,
        original_filename,
        mime_type,
        file_size_bytes,
        checksum_sha256,
        version_no,
        is_current,
        uploaded_by_candidate_id,
        uploaded_by_app_user_id,
        uploaded_at
      ) values (
        v_log.logical_document_id,
        v_res.temp_bucket,
        v_res.temp_path,
        v_res.original_filename,
        coalesce(v_res.detected_mime_type, v_res.declared_mime_type, 'application/pdf'),
        coalesce(v_res.actual_size_bytes, v_res.expected_max_size_bytes, 1024),
        v_res.checksum_sha256,
        1,
        true,
        v_cand.candidate_id,
        null,
        v_now
      );

      update public.upload_reservations set status_code = 'FINALIZED' where upload_reservation_id = v_chg.upload_reservation_id;

    elsif v_chg.action_code = 'REPLACE' then
      select * into v_log from public.submission_document_logicals where logical_document_id = v_chg.target_logical_document_id and submission_id = v_sub.submission_id for update;
      select * into v_current_doc from public.submission_documents where logical_document_id = v_log.logical_document_id and is_current = true for update;
      select * into v_res from public.upload_reservations where upload_reservation_id = v_chg.upload_reservation_id for update;

      update public.submission_documents set is_current = false where document_id = v_current_doc.document_id;

      insert into public.submission_documents (
        logical_document_id,
        storage_bucket,
        storage_path,
        original_filename,
        mime_type,
        file_size_bytes,
        checksum_sha256,
        version_no,
        is_current,
        uploaded_by_candidate_id,
        uploaded_by_app_user_id,
        uploaded_at
      ) values (
        v_log.logical_document_id,
        v_res.temp_bucket,
        v_res.temp_path,
        v_res.original_filename,
        coalesce(v_res.detected_mime_type, v_res.declared_mime_type, 'application/pdf'),
        coalesce(v_res.actual_size_bytes, v_res.expected_max_size_bytes, 1024),
        v_res.checksum_sha256,
        v_current_doc.version_no + 1,
        true,
        v_cand.candidate_id,
        null,
        v_now
      );

      update public.upload_reservations set status_code = 'FINALIZED' where upload_reservation_id = v_chg.upload_reservation_id;

    elsif v_chg.action_code = 'DELETE' then
      select * into v_log from public.submission_document_logicals where logical_document_id = v_chg.target_logical_document_id and submission_id = v_sub.submission_id for update;
      select * into v_current_doc from public.submission_documents where logical_document_id = v_log.logical_document_id and is_current = true for update;

      update public.submission_documents set is_current = false where document_id = v_current_doc.document_id;
    end if;

    update public.candidate_form_document_changes
    set status_code = 'APPLIED'
    where candidate_form_document_change_id = v_chg.candidate_form_document_change_id;
  end loop;

  -- 11. Privacy Acknowledgement
  insert into public.privacy_acknowledgements (
    submission_id,
    notice_version,
    acknowledged_at,
    source_code
  ) values (
    v_sub.submission_id,
    p_privacy_notice_version,
    v_now,
    'CANDIDATE_PORTAL'
  )
  on conflict (submission_id, notice_version) do nothing;

  -- 12. Refresh Candidate Profile Cache
  perform private.refresh_candidate_current_profile(v_cand.candidate_id);

  -- Notification persistence is mandatory; delivery throttling is downstream only.
  perform private.enqueue_candidate_email('HR_SUBMISSION_UPDATED_NOTIFICATION',
    v_sub.submission_id, v_cand.candidate_id, p_idempotency_key);

  -- 14. Transition Form Session to SUBMITTED
  update public.candidate_form_sessions
  set
    status_code = 'SUBMITTED',
    updated_at = v_now
  where candidate_form_session_id = p_candidate_form_session_id;

  -- 15. Security Audit Log
  insert into public.security_audit_log (
    action_code,
    actor_candidate_id,
    entity_type,
    entity_id,
    metadata,
    source_code,
    result_code
  ) values (
    'UPDATE_CANDIDATE_SUBMISSION',
    v_cand.candidate_id,
    'SUBMISSION',
    v_sub.submission_id,
    jsonb_build_object(
      'submission_id', v_sub.submission_id,
      'candidate_id', v_cand.candidate_id,
      'status_code', v_sub.status_code,
      'version_no', v_sub.version_no,
      'changed_fields', jsonb_build_array('full_name', 'phone', 'date_of_birth', 'gender_code', 'current_address', 'education', 'documents', 'privacy_notice')
    ),
    'RPC',
    'SUCCESS'
  );
  v_result := jsonb_build_object(
    'success', true,
    'submission_id', v_sub.submission_id,
    'status_code', v_sub.status_code,
    'version_no', v_sub.version_no
  );
  insert into public.idempotency_records (
    actor_scope,
    command_type,
    idempotency_key,
    result_entity_type,
    result_entity_id,
    result_payload
  ) values (
    v_actor_scope,
    'update_candidate_submission',
    p_idempotency_key,
    'SUBMISSION',
    v_sub.submission_id,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  )
  on conflict (actor_scope, command_type, idempotency_key) do nothing;
  return v_result;
end;
$$;

revoke all on function public.update_candidate_submission(uuid, text, text, date, text, text, jsonb, text, uuid) from public, anon;
grant execute on function public.update_candidate_submission(uuid, text, text, date, text, text, jsonb, text, uuid) to authenticated;

