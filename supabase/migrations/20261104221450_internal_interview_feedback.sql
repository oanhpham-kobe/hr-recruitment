-- CR-INTERVIEW-FEEDBACK-20261105. Local persistence only; no outbound delivery.
-- Private feature tables: no raw authenticated access, no legacy report/status writes.
create table private.interview_feedback_templates (
  template_id uuid primary key default gen_random_uuid(),
  family_id uuid not null,
  version_no bigint not null check (version_no > 0),
  name text not null check (length(btrim(name)) between 1 and 200),
  questions jsonb not null check (jsonb_typeof(questions) = 'array' and jsonb_array_length(questions) between 1 and 30),
  published_at timestamptz not null default clock_timestamp(),
  published_by uuid references public.app_users(app_user_id) on delete restrict,
  unique(family_id,version_no)
);
create table private.interview_feedback_collections (
  collection_id uuid primary key default gen_random_uuid(),
  interview_id uuid not null unique references public.interviews(interview_id) on delete restrict,
  template_id uuid not null references private.interview_feedback_templates(template_id) on delete restrict,
  deadline_at timestamptz,
  created_by uuid not null references public.app_users(app_user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp()
);
create table private.interview_feedback_invitations (
  invitation_id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references private.interview_feedback_collections(collection_id) on delete restrict,
  participant_id uuid not null references public.interview_participants(interview_participant_id) on delete restrict,
  app_user_id uuid not null references public.app_users(app_user_id) on delete restrict,
  evaluator_name text not null,
  state text not null default 'DRAFT' check (state in ('DRAFT','SUBMITTED','REVOKED')),
  answers jsonb not null default '{}'::jsonb check (jsonb_typeof(answers)='object'),
  version_no bigint not null default 1 check (version_no > 0),
  submitted_at timestamptz,
  submit_base_version_no bigint,
  revoked_at timestamptz,
  unique(collection_id,participant_id),
  unique(collection_id,app_user_id),
  check ((state='SUBMITTED')=(submitted_at is not null)),
  check ((state='SUBMITTED')=(submit_base_version_no is not null)),
  check ((state='REVOKED')=(revoked_at is not null))
);
create index interview_feedback_own_idx on private.interview_feedback_invitations(app_user_id,collection_id);
create table private.interview_feedback_notification_intents (
  invitation_id uuid primary key references private.interview_feedback_invitations(invitation_id) on delete restrict,
  delivery_state text not null default 'PROVIDER_PAUSED' check(delivery_state='PROVIDER_PAUSED'),
  created_at timestamptz not null default clock_timestamp()
);
create table private.interview_feedback_consolidations (
  collection_id uuid primary key references private.interview_feedback_collections(collection_id) on delete restrict,
  title text not null check(length(btrim(title)) between 1 and 200),
  overall_summary text not null default '' check(length(overall_summary)<=20000),
  snapshot jsonb not null,
  version_no bigint not null default 1 check(version_no > 0),
  state text not null default 'DRAFT' check(state in ('DRAFT','APPROVED')),
  created_at timestamptz not null default clock_timestamp(),
  approved_at timestamptz,
  approved_by uuid references public.app_users(app_user_id) on delete restrict,
  check ((state='APPROVED')=(approved_at is not null)),
  check ((state='APPROVED')=(approved_by is not null))
);
alter table private.interview_feedback_templates enable row level security;
alter table private.interview_feedback_collections enable row level security;
alter table private.interview_feedback_invitations enable row level security;
alter table private.interview_feedback_notification_intents enable row level security;
alter table private.interview_feedback_consolidations enable row level security;
revoke all on private.interview_feedback_templates,private.interview_feedback_collections,
 private.interview_feedback_invitations,private.interview_feedback_notification_intents,
 private.interview_feedback_consolidations from public,anon,authenticated;

create function private.feedback_immutable_guard() returns trigger
language plpgsql set search_path='' as $$
begin
  raise exception 'FEEDBACK_IMMUTABLE' using errcode='23514';
end;
$$;
create trigger feedback_template_immutable before update or delete on private.interview_feedback_templates
for each row execute function private.feedback_immutable_guard();
create trigger feedback_collection_immutable before update or delete on private.interview_feedback_collections
for each row execute function private.feedback_immutable_guard();
create trigger feedback_submission_immutable before update or delete on private.interview_feedback_invitations
for each row when (old.state in ('SUBMITTED','REVOKED')) execute function private.feedback_immutable_guard();
create trigger feedback_approval_immutable before update or delete on private.interview_feedback_consolidations
for each row when (old.state='APPROVED') execute function private.feedback_immutable_guard();

insert into private.interview_feedback_templates(template_id,family_id,version_no,name,questions) values
('10100000-0000-4000-8000-000000000001','10100000-0000-4000-8000-000000000001',1,'Phiếu nhận xét phỏng vấn / Interview feedback',
 '[{"key":"professional_knowledge","label":"Kiến thức chuyên môn / Professional Knowledge","required":false},{"key":"necessary_skills","label":"Kỹ năng cần thiết / Necessary Skills","required":false},{"key":"qualities_personality","label":"Phẩm chất, tính cách / Qualities and Personality","required":false},{"key":"strengths_limitations","label":"Điểm mạnh và hạn chế / Strengths and Limitations","required":false},{"key":"other_comment","label":"Khác / Other","required":false}]');

create function private.feedback_can_manage() returns boolean
language sql stable security definer set search_path='' as $$
 select private.current_app_user_id() is not null and
 (private.is_root_admin() or (private.has_permission('interviews.manage') and private.has_permission('reports.view')));
$$;
create function private.feedback_error(p_code text) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_object('success',false,'error_code',p_code,'message',p_code);
$$;
-- Complete existing context fence, no parent mutations. SHARE on parents is
-- deliberate: it blocks lifecycle updates but composes with lock_email_contexts
-- which reads those parents in a different order using SHARE. Interview's
-- NO KEY UPDATE excludes every participant/status writer without blocking FKs.
create function private.lock_feedback_context(p_interview_id uuid,p_actor uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare v_application uuid; v_submission uuid; v_candidate uuid; v_user uuid; v_users uuid[];
begin
 select i.application_id,a.submission_id,s.candidate_id into v_application,v_submission,v_candidate
 from public.interviews i join public.applications a using(application_id)
 join public.submissions s using(submission_id) where i.interview_id=p_interview_id;
 if not found then return false; end if;
 perform 1 from public.candidates where candidate_id=v_candidate for share;
 perform 1 from public.submissions where submission_id=v_submission for share;
 perform 1 from public.applications where application_id=v_application for share;
 perform 1 from public.interviews where interview_id=p_interview_id for no key update;
 select array_agg(distinct id order by id) into v_users from (
  select p_actor id union all
  select ip.app_user_id from public.interview_participants ip where ip.interview_id=p_interview_id and ip.is_current union all
  select fi.app_user_id from private.interview_feedback_invitations fi
  join private.interview_feedback_collections fc using(collection_id) where fc.interview_id=p_interview_id
 ) q where id is not null;
 foreach v_user in array coalesce(v_users,'{}'::uuid[]) loop
  perform 1 from public.app_users where app_user_id=v_user for update;
 end loop;
 perform private.lock_internal_user_ids(v_users);
 return exists(select 1 from public.interviews i join public.applications a using(application_id)
 join public.submissions s using(submission_id) where i.interview_id=p_interview_id
 and i.application_id=v_application and a.submission_id=v_submission and s.candidate_id=v_candidate);
end;
$$;
create function private.feedback_context(p_interview_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('interview_id',i.interview_id,'application_id',a.application_id,
  'candidate_name',s.full_name,'position_name',p.name_vi,'unit_name',u.name_vi,
  'round_no',i.round_no,'start_at',i.start_at,'end_at',i.end_at,
  'readable',a.is_active and i.is_active and i.visible_to_interviewers,
  'writable',a.is_active and i.is_active and i.visible_to_interviewers
   and i.report_status_code not in ('HIRED','REJECTED')
   and exists(select 1 from private.application_current_interview ci where ci.interview_id=i.interview_id))
 from public.interviews i join public.applications a using(application_id)
 join public.submissions s using(submission_id) join public.positions p using(position_id)
 join public.organizational_units u on u.unit_id=a.unit_id where i.interview_id=p_interview_id;
$$;
create function private.feedback_invitation_valid(p_invitation_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.interview_feedback_invitations fi
 join private.interview_feedback_collections fc using(collection_id)
 join public.interview_participants ip on ip.interview_participant_id=fi.participant_id
 join public.app_users u on u.app_user_id=fi.app_user_id
 where fi.invitation_id=p_invitation_id and fi.state<>'REVOKED'
 and ip.interview_id=fc.interview_id and ip.app_user_id=fi.app_user_id and ip.is_current
 and ip.removed_at is null and u.is_active and u.auth_user_id is not null);
$$;
create function private.feedback_blockers(p_collection_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('invitation_id',fi.invitation_id,'evaluator_name',fi.evaluator_name,
 'reason',case when fi.state='REVOKED' then 'INVITATION_REVOKED'
  when not private.feedback_invitation_valid(fi.invitation_id) then 'EVALUATOR_UNAVAILABLE'
  else 'RESPONSE_NOT_SUBMITTED' end) order by fi.invitation_id),'[]'::jsonb)
 from private.interview_feedback_invitations fi where fi.collection_id=p_collection_id
 and (fi.state<>'SUBMITTED' or not private.feedback_invitation_valid(fi.invitation_id));
$$;

create function public.publish_interview_feedback_template(p_name text,p_questions jsonb,p_previous_template_id uuid,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=private.current_app_user_id(); v_family uuid; v_version bigint;
 v_template private.interview_feedback_templates%rowtype; v_q jsonb; v_fingerprint text; v_existing jsonb; v_result jsonb;
begin
 if v_actor is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 if not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 if p_name is null or length(btrim(p_name)) not between 1 and 200 or p_idempotency_key is null
 or p_questions is null or jsonb_typeof(p_questions)<>'array' then return private.feedback_error('VALIDATION_ERROR'); end if;
 if jsonb_array_length(p_questions) not between 1 and 30 then return private.feedback_error('VALIDATION_ERROR'); end if;
 for v_q in select value from jsonb_array_elements(p_questions) loop
  if jsonb_typeof(v_q)<>'object' or not (v_q ?& array['key','label','required']) then return private.feedback_error('VALIDATION_ERROR'); end if;
  if exists(select 1 from jsonb_object_keys(v_q) k where k not in ('key','label','required'))
   or jsonb_typeof(v_q->'key')<>'string' or (v_q->>'key') !~ '^[a-z][a-z0-9_]{0,63}$'
   or jsonb_typeof(v_q->'label')<>'string' or length(btrim(v_q->>'label')) not between 1 and 1000
   or jsonb_typeof(v_q->'required')<>'boolean' then return private.feedback_error('VALIDATION_ERROR'); end if;
 end loop;
 if (select count(distinct q->>'key') from jsonb_array_elements(p_questions) q)<>jsonb_array_length(p_questions)
 then return private.feedback_error('VALIDATION_ERROR'); end if;
 -- Idempotency precedes all locks; the publication is independent of lifecycle
 -- parents, and the only User row is the current actor.
 v_fingerprint:=encode(extensions.digest(jsonb_build_array(p_name,p_questions,p_previous_template_id)::text,'sha256'),'hex');
 begin
  v_existing:=private.check_idempotency('app_user:'||v_actor,'publish_interview_feedback_template',p_idempotency_key,v_fingerprint);
 exception when check_violation then
  if sqlerrm='IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD' then return private.feedback_error('VALIDATION_ERROR'); end if;
  raise;
 end;
 perform 1 from public.app_users where app_user_id=v_actor for update;
 perform private.lock_internal_user_ids(array[v_actor]);
 if private.current_app_user_id() is distinct from v_actor or not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 if v_existing is not null then return v_existing; end if;
 if p_previous_template_id is null then v_family:=gen_random_uuid(); v_version:=1;
 else
  select family_id into v_family from private.interview_feedback_templates where template_id=p_previous_template_id;
  if not found then return private.feedback_error('NOT_FOUND'); end if;
  perform pg_advisory_xact_lock(hashtextextended('feedback-template:'||v_family,0));
  select max(version_no)+1 into v_version from private.interview_feedback_templates where family_id=v_family;
 end if;
 insert into private.interview_feedback_templates(family_id,version_no,name,questions,published_by)
 values(v_family,v_version,btrim(p_name),p_questions,v_actor) returning * into v_template;
 perform private.audit_interview_command('FEEDBACK_TEMPLATE_PUBLISH','FEEDBACK_TEMPLATE',v_template.template_id,v_actor,p_idempotency_key,
  jsonb_build_object('family_id',v_family,'version_no',v_version));
 v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('template_id',v_template.template_id,'family_id',v_family,
  'version_no',v_version,'name',v_template.name,'questions',v_template.questions,'published_at',v_template.published_at));
 perform private.record_idempotency('app_user:'||v_actor,'publish_interview_feedback_template',p_idempotency_key,v_fingerprint,v_result,'FEEDBACK_TEMPLATE',v_template.template_id);
 return v_result;
end;
$$;
create function private.feedback_template_json(p_template_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('template_id',template_id,'family_id',family_id,'version_no',version_no,'name',name,
 'questions',questions,'published_at',published_at) from private.interview_feedback_templates where template_id=p_template_id;
$$;
create function private.feedback_collection_json(p_collection_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('collection_id',collection_id,'interview_id',interview_id,'template_id',template_id,
 'deadline_at',deadline_at,'created_at',created_at) from private.interview_feedback_collections where collection_id=p_collection_id;
$$;
create function private.feedback_invitation_json(p_invitation_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('invitation_id',invitation_id,'participant_id',participant_id,'evaluator_name',evaluator_name,
 'state',state,'answers',answers,'version_no',version_no,'submitted_at',submitted_at,
 'available',private.feedback_invitation_valid(invitation_id),'delivery_state','PROVIDER_PAUSED')
 from private.interview_feedback_invitations where invitation_id=p_invitation_id;
$$;
create function private.feedback_consolidation_json(p_collection_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('collection_id',collection_id,'title',title,'overall_summary',overall_summary,'snapshot',snapshot,
 'version_no',version_no,'state',state,'created_at',created_at,'approved_at',approved_at)
 from private.interview_feedback_consolidations where collection_id=p_collection_id;
$$;

create function public.create_interview_feedback_collection(p_interview_id uuid,p_template_id uuid,p_participant_ids uuid[],p_deadline_at timestamptz,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=private.current_app_user_id(); v_collection uuid; v_context jsonb; v_existing jsonb; v_fingerprint text; v_result jsonb;
begin
 if v_actor is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 if not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 if p_interview_id is null or p_template_id is null or p_idempotency_key is null or p_participant_ids is null
 or cardinality(p_participant_ids) not between 1 and 100 or array_position(p_participant_ids,null) is not null
 or (select count(distinct x) from unnest(p_participant_ids) x)<>cardinality(p_participant_ids)
 then return private.feedback_error('VALIDATION_ERROR'); end if;
 -- Same actor/key is serialized before context locks, as in existing commands.
 v_fingerprint:=encode(extensions.digest(jsonb_build_array(p_interview_id,p_template_id,p_participant_ids,p_deadline_at)::text,'sha256'),'hex');
 begin
  v_existing:=private.check_idempotency('app_user:'||v_actor,'create_interview_feedback_collection',p_idempotency_key,v_fingerprint);
 exception when check_violation then
  if sqlerrm='IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD' then return private.feedback_error('VALIDATION_ERROR'); end if;
  raise;
 end;
 if not private.lock_feedback_context(p_interview_id,v_actor) then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if private.current_app_user_id() is distinct from v_actor or not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 v_context:=private.feedback_context(p_interview_id);
 if v_context is null then return private.feedback_error('NOT_FOUND'); end if;
 -- Existing collection is safely returned after authorization, even if this
 -- exact round became historical since initial creation. No new write occurs.
 if v_existing is not null then return v_existing; end if;
 select collection_id into v_collection from private.interview_feedback_collections where interview_id=p_interview_id;
 if found then return jsonb_build_object('success',true,'data',private.feedback_collection_json(v_collection)); end if;
 if not (v_context->>'writable')::boolean then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if p_deadline_at is not null and p_deadline_at<=clock_timestamp() then return private.feedback_error('VALIDATION_ERROR'); end if;
 if not exists(select 1 from private.interview_feedback_templates where template_id=p_template_id) then return private.feedback_error('NOT_FOUND'); end if;
 if (select count(*) from public.interview_participants ip join public.app_users u using(app_user_id)
 where ip.interview_participant_id=any(p_participant_ids) and ip.interview_id=p_interview_id
 and ip.is_current and ip.removed_at is null and u.is_active and u.auth_user_id is not null)<>cardinality(p_participant_ids)
 then return private.feedback_error('VALIDATION_ERROR'); end if;
 insert into private.interview_feedback_collections(interview_id,template_id,deadline_at,created_by)
 values(p_interview_id,p_template_id,p_deadline_at,v_actor) returning collection_id into v_collection;
 insert into private.interview_feedback_invitations(collection_id,participant_id,app_user_id,evaluator_name)
 select v_collection,ip.interview_participant_id,ip.app_user_id,ip.snapshot_name
 from public.interview_participants ip where ip.interview_participant_id=any(p_participant_ids) order by ip.interview_participant_id;
 insert into private.interview_feedback_notification_intents(invitation_id)
 select invitation_id from private.interview_feedback_invitations where collection_id=v_collection;
 perform private.audit_interview_command('FEEDBACK_COLLECTION_CREATE','FEEDBACK_COLLECTION',v_collection,v_actor,p_idempotency_key,
 jsonb_build_object('interview_id',p_interview_id,'template_id',p_template_id,'selected_count',cardinality(p_participant_ids),'delivery_state','PROVIDER_PAUSED'));
 v_result:=jsonb_build_object('success',true,'data',private.feedback_collection_json(v_collection));
 perform private.record_idempotency('app_user:'||v_actor,'create_interview_feedback_collection',p_idempotency_key,v_fingerprint,v_result,'FEEDBACK_COLLECTION',v_collection);
 return v_result;
end;
$$;

create function private.read_feedback_detail(p_collection_id uuid,p_invitation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=private.current_app_user_id(); v_hr boolean; v_collection private.interview_feedback_collections%rowtype;
 v_own uuid; v_context jsonb; v_data jsonb;
begin
 if v_actor is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 select * into v_collection from private.interview_feedback_collections where collection_id=p_collection_id;
 if not found then return private.feedback_error('NOT_FOUND'); end if;
 v_hr:=p_invitation_id is null and private.feedback_can_manage();
 select invitation_id into v_own from private.interview_feedback_invitations
 where collection_id=p_collection_id and app_user_id=v_actor and (p_invitation_id is null or invitation_id=p_invitation_id);
 if not v_hr and (v_own is null or not private.feedback_invitation_valid(v_own)) then return private.feedback_error('FORBIDDEN'); end if;
 if not private.lock_feedback_context(v_collection.interview_id,v_actor) then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if private.current_app_user_id() is distinct from v_actor then return private.feedback_error('FORBIDDEN'); end if;
 v_context:=private.feedback_context(v_collection.interview_id);
 if v_hr then
  if not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 else
  if not private.feedback_invitation_valid(v_own) or not coalesce((v_context->>'readable')::boolean,false)
  then return private.feedback_error('FORBIDDEN'); end if;
 end if;
 v_data:=jsonb_build_object('mode',case when v_hr then 'HR' else 'OWN' end,'collection',private.feedback_collection_json(p_collection_id),
 'context',v_context,'template',private.feedback_template_json(v_collection.template_id));
 if v_hr then
  v_data:=v_data||jsonb_build_object('invitations',(select coalesce(jsonb_agg(private.feedback_invitation_json(invitation_id) order by evaluator_name,invitation_id),'[]'::jsonb)
   from private.interview_feedback_invitations where collection_id=p_collection_id),
   'blockers',private.feedback_blockers(p_collection_id),'consolidation',private.feedback_consolidation_json(p_collection_id));
 else v_data:=v_data||jsonb_build_object('invitation',private.feedback_invitation_json(v_own)); end if;
 return jsonb_build_object('success',true,'data',v_data);
end;
$$;
create function public.get_interview_feedback_collection(p_collection_id uuid) returns jsonb
language sql security definer set search_path='' as $$ select private.read_feedback_detail(p_collection_id,null); $$;
create function public.get_interview_feedback_invitation(p_invitation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_collection uuid;
begin
 if private.current_app_user_id() is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 select collection_id into v_collection from private.interview_feedback_invitations
 where invitation_id=p_invitation_id and app_user_id=private.current_app_user_id();
 if not found then return private.feedback_error('FORBIDDEN'); end if;
 return private.read_feedback_detail(v_collection,p_invitation_id);
end;
$$;

create function public.save_interview_feedback_response(p_invitation_id uuid,p_answers jsonb,p_expected_version_no bigint,p_submit boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=private.current_app_user_id(); v_inv private.interview_feedback_invitations%rowtype;
 v_collection private.interview_feedback_collections%rowtype; v_questions jsonb; v_context jsonb;
begin
 if v_actor is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 if p_answers is null or jsonb_typeof(p_answers)<>'object' or p_expected_version_no is null or p_expected_version_no<1 or p_submit is null
 then return private.feedback_error('VALIDATION_ERROR'); end if;
 select * into v_inv from private.interview_feedback_invitations where invitation_id=p_invitation_id and app_user_id=v_actor;
 if not found then return private.feedback_error('FORBIDDEN'); end if;
 select * into strict v_collection from private.interview_feedback_collections where collection_id=v_inv.collection_id;
 if not private.lock_feedback_context(v_collection.interview_id,v_actor) then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if private.current_app_user_id() is distinct from v_actor then return private.feedback_error('FORBIDDEN'); end if;
 select * into v_inv from private.interview_feedback_invitations where invitation_id=p_invitation_id for update;
 if v_inv.state='REVOKED' then return private.feedback_error('INVITATION_REVOKED'); end if;
 if not private.feedback_invitation_valid(p_invitation_id) then return private.feedback_error('FORBIDDEN'); end if;
 v_context:=private.feedback_context(v_collection.interview_id);
 if not coalesce((v_context->>'readable')::boolean,false) then return private.feedback_error('FORBIDDEN'); end if;
 if v_inv.state='SUBMITTED' then
  if p_submit and p_answers=v_inv.answers and p_expected_version_no in (v_inv.version_no,v_inv.submit_base_version_no)
  then return jsonb_build_object('success',true,'data',private.feedback_invitation_json(p_invitation_id)); end if;
  return private.feedback_error('ALREADY_SUBMITTED');
 end if;
 if not coalesce((v_context->>'writable')::boolean,false) then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if v_collection.deadline_at is not null and clock_timestamp()>=v_collection.deadline_at then return private.feedback_error('DEADLINE_PASSED'); end if;
 if v_inv.version_no<>p_expected_version_no then return private.feedback_error('STALE_VERSION'); end if;
 select questions into v_questions from private.interview_feedback_templates where template_id=v_collection.template_id;
 if exists(select 1 from jsonb_each(p_answers) a where jsonb_typeof(a.value)<>'string' or length(a.value #>> '{}')>10000
 or not exists(select 1 from jsonb_array_elements(v_questions) q where q->>'key'=a.key)) then return private.feedback_error('VALIDATION_ERROR'); end if;
 if p_submit and exists(select 1 from jsonb_array_elements(v_questions) q where (q->>'required')::boolean
 and nullif(btrim(p_answers->>(q->>'key')),'') is null) then return private.feedback_error('REQUIRED_ANSWER_MISSING'); end if;
 update private.interview_feedback_invitations set answers=p_answers,version_no=version_no+1,
 state=case when p_submit then 'SUBMITTED' else 'DRAFT' end,
 submitted_at=case when p_submit then clock_timestamp() else null end,
 submit_base_version_no=case when p_submit then p_expected_version_no else null end where invitation_id=p_invitation_id;
 perform private.audit_interview_command(case when p_submit then 'FEEDBACK_RESPONSE_SUBMIT' else 'FEEDBACK_RESPONSE_SAVE' end,
 'FEEDBACK_INVITATION',p_invitation_id,v_actor,null,jsonb_build_object('collection_id',v_inv.collection_id,'version_no',p_expected_version_no+1));
 return jsonb_build_object('success',true,'data',private.feedback_invitation_json(p_invitation_id));
end;
$$;

create function public.revoke_interview_feedback_invitation(p_invitation_id uuid,p_expected_version_no bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=private.current_app_user_id(); v_inv private.interview_feedback_invitations%rowtype; v_interview uuid;
begin
 if v_actor is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 if not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 if p_expected_version_no is null or p_expected_version_no<1 then return private.feedback_error('VALIDATION_ERROR'); end if;
 select fc.interview_id into v_interview from private.interview_feedback_invitations fi
 join private.interview_feedback_collections fc using(collection_id) where fi.invitation_id=p_invitation_id;
 if not found then return private.feedback_error('NOT_FOUND'); end if;
 if not private.lock_feedback_context(v_interview,v_actor) then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if private.current_app_user_id() is distinct from v_actor or not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 select * into v_inv from private.interview_feedback_invitations where invitation_id=p_invitation_id for update;
 if v_inv.version_no<>p_expected_version_no then return private.feedback_error('STALE_VERSION'); end if;
 if v_inv.state='SUBMITTED' then return private.feedback_error('ALREADY_SUBMITTED'); end if;
 if v_inv.state='REVOKED' then return private.feedback_error('INVITATION_REVOKED'); end if;
 update private.interview_feedback_invitations set state='REVOKED',revoked_at=clock_timestamp(),version_no=version_no+1 where invitation_id=p_invitation_id;
 perform private.audit_interview_command('FEEDBACK_INVITATION_REVOKE','FEEDBACK_INVITATION',p_invitation_id,v_actor,null,jsonb_build_object('collection_id',v_inv.collection_id));
 return jsonb_build_object('success',true,'data',private.feedback_invitation_json(p_invitation_id));
end;
$$;
create function public.save_interview_feedback_consolidation(p_collection_id uuid,p_title text,p_overall_summary text,p_expected_version_no bigint,p_approve boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=private.current_app_user_id(); v_collection private.interview_feedback_collections%rowtype;
 v_report private.interview_feedback_consolidations%rowtype; v_context jsonb; v_snapshot jsonb; v_template jsonb;
begin
 if v_actor is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 if not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 if p_title is null or length(btrim(p_title)) not between 1 and 200 or p_overall_summary is null or length(p_overall_summary)>20000
 or p_expected_version_no is null or p_expected_version_no<0 or p_approve is null then return private.feedback_error('VALIDATION_ERROR'); end if;
 select * into v_collection from private.interview_feedback_collections where collection_id=p_collection_id;
 if not found then return private.feedback_error('NOT_FOUND'); end if;
 if not private.lock_feedback_context(v_collection.interview_id,v_actor) then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if private.current_app_user_id() is distinct from v_actor or not private.feedback_can_manage() then return private.feedback_error('FORBIDDEN'); end if;
 v_context:=private.feedback_context(v_collection.interview_id);
 if not coalesce((v_context->>'writable')::boolean,false) then return private.feedback_error('CONTEXT_NOT_WRITABLE'); end if;
 if jsonb_array_length(private.feedback_blockers(p_collection_id))<>0 then return private.feedback_error('COMPLETENESS_REQUIRED'); end if;
 select * into v_report from private.interview_feedback_consolidations where collection_id=p_collection_id for update;
 if found then
  if v_report.version_no<>p_expected_version_no then return private.feedback_error('STALE_VERSION'); end if;
  if v_report.state='APPROVED' then return private.feedback_error('ALREADY_APPROVED'); end if;
  update private.interview_feedback_consolidations set title=btrim(p_title),overall_summary=p_overall_summary,
   version_no=version_no+1,state=case when p_approve then 'APPROVED' else 'DRAFT' end,
   approved_at=case when p_approve then clock_timestamp() else null end,
   approved_by=case when p_approve then v_actor else null end where collection_id=p_collection_id;
 else
  if p_expected_version_no<>0 then return private.feedback_error('STALE_VERSION'); end if;
  if p_approve then return private.feedback_error('VALIDATION_ERROR'); end if;
  v_template:=private.feedback_template_json(v_collection.template_id);
  v_snapshot:=jsonb_build_object('context',v_context,'template',v_template,
   'evaluators',(select jsonb_agg(jsonb_build_object('invitation_id',fi.invitation_id,'participant_id',fi.participant_id,
    'evaluator_name',fi.evaluator_name,'answer_version_no',fi.version_no,'submitted_at',fi.submitted_at) order by fi.evaluator_name,fi.invitation_id)
    from private.interview_feedback_invitations fi where fi.collection_id=p_collection_id),
   'questions',(select jsonb_agg(q.value||jsonb_build_object('answers',
    (select jsonb_agg(jsonb_build_object('invitation_id',fi.invitation_id,'evaluator_name',fi.evaluator_name,
     'answer',fi.answers->(q.value->>'key')) order by fi.evaluator_name,fi.invitation_id)
     from private.interview_feedback_invitations fi where fi.collection_id=p_collection_id)) order by q.ordinality)
    from jsonb_array_elements(v_template->'questions') with ordinality q));
  insert into private.interview_feedback_consolidations(collection_id,title,overall_summary,snapshot)
  values(p_collection_id,btrim(p_title),p_overall_summary,v_snapshot);
 end if;
 perform private.audit_interview_command(case when p_approve then 'FEEDBACK_CONSOLIDATION_APPROVE' else 'FEEDBACK_CONSOLIDATION_DRAFT' end,
 'FEEDBACK_COLLECTION',p_collection_id,v_actor,null,jsonb_build_object('version_no',p_expected_version_no+1));
 return jsonb_build_object('success',true,'data',private.feedback_consolidation_json(p_collection_id));
end;
$$;

create function public.get_interview_feedback_workspace(p_limit integer default 50,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=private.current_app_user_id(); v_hr boolean; v_templates jsonb:='[]'; v_interviews jsonb:='[]'; v_collections jsonb:='[]'; v_invitations jsonb;
begin
 if v_actor is null then return private.feedback_error(case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
 if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset<0 then return private.feedback_error('VALIDATION_ERROR'); end if;
 -- This read never acquires parent locks; serialize only current actor identity/
 -- permissions while projecting multiple allowlisted lists, with no lock upgrade.
 perform 1 from public.app_users where app_user_id=v_actor for share;
 if private.current_app_user_id() is distinct from v_actor then return private.feedback_error('FORBIDDEN'); end if;
 v_hr:=private.feedback_can_manage();
 if v_hr then
  select coalesce(jsonb_agg(private.feedback_template_json(t.template_id) order by t.published_at desc,t.template_id),'[]') into v_templates
  from (select template_id,published_at from private.interview_feedback_templates order by published_at desc,template_id limit p_limit offset p_offset) t;
  select coalesce(jsonb_agg(x.context||jsonb_build_object('collection_id',fc.collection_id,
   'participants',(select coalesce(jsonb_agg(jsonb_build_object('participant_id',ip.interview_participant_id,'evaluator_name',ip.snapshot_name)
    order by ip.participant_order,ip.interview_participant_id),'[]') from public.interview_participants ip join public.app_users u using(app_user_id)
    where ip.interview_id=x.interview_id and ip.is_current and ip.removed_at is null and u.is_active and u.auth_user_id is not null))
   order by x.interview_id),'[]') into v_interviews
  from (select i.interview_id,private.feedback_context(i.interview_id) context from public.interviews i
   where (private.feedback_context(i.interview_id)->>'writable')::boolean
   order by i.interview_id limit p_limit offset p_offset) x
  left join private.interview_feedback_collections fc using(interview_id);
  select coalesce(jsonb_agg(private.feedback_collection_json(fc.collection_id)||jsonb_build_object(
   'context',private.feedback_context(fc.interview_id),
   'selected_count',(select count(*) from private.interview_feedback_invitations fi where fi.collection_id=fc.collection_id),
   'submitted_count',(select count(*) from private.interview_feedback_invitations fi where fi.collection_id=fc.collection_id and fi.state='SUBMITTED'),
   'blockers',private.feedback_blockers(fc.collection_id),
   'consolidation_state',(select state from private.interview_feedback_consolidations r where r.collection_id=fc.collection_id))
   order by fc.created_at desc,fc.collection_id),'[]') into v_collections
  from (select * from private.interview_feedback_collections order by created_at desc,collection_id limit p_limit offset p_offset) fc;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('invitation_id',q.invitation_id,'collection_id',q.collection_id,'evaluator_name',q.evaluator_name,
 'state',q.state,'version_no',q.version_no,'deadline_at',q.deadline_at,'context',private.feedback_context(q.interview_id))
 order by q.created_at desc,q.invitation_id),'[]') into v_invitations
 from (select fi.*,fc.interview_id,fc.deadline_at,fc.created_at from private.interview_feedback_invitations fi
 join private.interview_feedback_collections fc using(collection_id)
 where fi.app_user_id=v_actor and private.feedback_invitation_valid(fi.invitation_id)
 and (private.feedback_context(fc.interview_id)->>'readable')::boolean
 order by fc.created_at desc,fi.invitation_id limit p_limit offset p_offset) q;
 return jsonb_build_object('success',true,'data',jsonb_build_object('can_manage',v_hr,'templates',v_templates,'interviews',v_interviews,
 'collections',v_collections,'invitations',v_invitations));
end;
$$;

-- Explicit function ACLs, including every helper. Private functions are callable
-- only through these SECURITY DEFINER entry points; tables remain inaccessible.
do $$
declare r record;
begin
 for r in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='private' and (p.proname like 'feedback_%' or p.proname in ('lock_feedback_context','read_feedback_detail')))
 or (n.nspname='public' and p.proname in ('publish_interview_feedback_template','create_interview_feedback_collection',
 'get_interview_feedback_collection','get_interview_feedback_invitation','save_interview_feedback_response',
 'revoke_interview_feedback_invitation','save_interview_feedback_consolidation','get_interview_feedback_workspace'))
 loop
  execute format('revoke all on function %s from public,anon,authenticated',r.signature);
  if r.nspname='public' then execute format('grant execute on function %s to authenticated',r.signature); end if;
 end loop;
end;
$$;
