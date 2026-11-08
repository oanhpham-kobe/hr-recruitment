-- TASK-S04-002: Interview reports, lifecycle commands, documents, and derived views

-- -----------------------------------------------------------------------------
-- 1. Report and document persistence
-- -----------------------------------------------------------------------------
create table if not exists public.interview_reports (
  interview_report_id uuid primary key default gen_random_uuid(),
  interview_participant_id uuid not null references public.interview_participants(interview_participant_id) on delete restrict,
  professional_knowledge text,
  necessary_skills text,
  qualities_personality text,
  strengths_limitations text,
  other_comment text,
  conclusion text,
  expected_specific_job_assigned text,
  expected_recruitment_time text,
  decision_updated_at timestamptz,
  decision_updated_by uuid references public.app_users(app_user_id) on delete restrict,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references public.app_users(app_user_id) on delete restrict,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(app_user_id) on delete restrict,
  version_no bigint not null default 1,
  constraint interview_report_lifecycle_ck check (
    (is_active = true and is_archived = false)
    or (is_active = false and is_archived = true)
  )
);

create unique index if not exists active_report_per_participant_uq
  on public.interview_reports(interview_participant_id)
  where is_active = true and is_archived = false;

create table if not exists public.interview_document_logicals (
  logical_document_id uuid primary key default gen_random_uuid(),
  interview_id uuid not null references public.interviews(interview_id) on delete cascade,
  document_type_id uuid not null references public.document_types(document_type_id) on delete restrict,
  created_by uuid not null references public.app_users(app_user_id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists interview_document_logicals_parent_idx
  on public.interview_document_logicals(interview_id, document_type_id);

create table if not exists public.interview_documents (
  interview_document_id uuid primary key default gen_random_uuid(),
  logical_document_id uuid not null references public.interview_document_logicals(logical_document_id) on delete cascade,
  storage_bucket text not null,
  storage_path text not null,
  original_filename text not null check (char_length(original_filename) <= 255),
  mime_type text not null check (mime_type in (
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'image/png', 'image/jpeg'
  )),
  file_size_bytes bigint not null check (file_size_bytes > 0 and file_size_bytes <= 5242880),
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9A-Fa-f]{64}$'),
  malware_scan_status text not null default 'CLEAN' check (malware_scan_status = 'CLEAN'),
  exif_stripped boolean,
  version_no integer not null default 1 check (version_no > 0),
  is_current boolean not null default true,
  uploaded_by uuid not null references public.app_users(app_user_id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  unique(logical_document_id, version_no),
  unique(storage_bucket, storage_path)
);

create unique index if not exists interview_current_logical_document_uq
  on public.interview_documents(logical_document_id)
  where is_current = true;

create or replace function private.enforce_report_decision_metadata()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  decision_changed boolean;
begin
  if tg_op = 'INSERT' then
    decision_changed := (
      nullif(btrim(new.conclusion), '') is not null or
      nullif(btrim(new.expected_specific_job_assigned), '') is not null or
      nullif(btrim(new.expected_recruitment_time), '') is not null
    );
    if decision_changed then
      new.decision_updated_by := new.updated_by;
    end if;
  else
    decision_changed := (
      new.conclusion is distinct from old.conclusion or
      new.expected_specific_job_assigned is distinct from old.expected_specific_job_assigned or
      new.expected_recruitment_time is distinct from old.expected_recruitment_time
    );
    if decision_changed then
      new.decision_updated_by := new.updated_by;
    end if;
  end if;

  if decision_changed then
    if new.decision_updated_by is null then
      raise exception 'decision_updated_by is required when final decision fields change' using errcode = '23514';
    end if;
    new.decision_updated_at := now();
  elsif tg_op = 'UPDATE' then
    new.decision_updated_at := old.decision_updated_at;
    new.decision_updated_by := old.decision_updated_by;
  end if;
  return new;
end;
$$;

drop trigger if exists interview_reports_touch_version on public.interview_reports;
create trigger interview_reports_touch_version
  before update on public.interview_reports
  for each row execute function private.touch_version();

drop trigger if exists a_report_decision_metadata_guard on public.interview_reports;
create trigger a_report_decision_metadata_guard
  before insert or update on public.interview_reports
  for each row execute function private.enforce_report_decision_metadata();

-- -----------------------------------------------------------------------------
-- 2. RLS and private derived read models
-- -----------------------------------------------------------------------------
alter table public.interview_reports enable row level security;
alter table public.interview_document_logicals enable row level security;
alter table public.interview_documents enable row level security;

revoke all on public.interview_reports, public.interview_document_logicals, public.interview_documents from public, anon;
grant select on public.interview_reports, public.interview_document_logicals, public.interview_documents to authenticated;
grant all on public.interview_reports, public.interview_document_logicals, public.interview_documents to postgres, service_role;

create or replace function private.can_view_interview_report(p_interview_participant_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.interview_participants ip
    join public.app_users u on u.app_user_id = ip.app_user_id
    join public.interviews i on i.interview_id = ip.interview_id
    join public.applications a on a.application_id = i.application_id
    where ip.interview_participant_id = p_interview_participant_id
      and u.auth_user_id = (select auth.uid())
      and u.is_active
      and ip.is_current
      and i.is_active
      and a.is_active
      and i.visible_to_interviewers
  );
$$;

create or replace function private.can_view_interview_document_logical(p_logical_document_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.interview_document_logicals l
    join public.interview_participants ip on ip.interview_id = l.interview_id
    join public.app_users u on u.app_user_id = ip.app_user_id
    join public.interviews i on i.interview_id = l.interview_id
    join public.applications a on a.application_id = i.application_id
    where l.logical_document_id = p_logical_document_id
      and u.auth_user_id = (select auth.uid())
      and u.is_active
      and ip.is_current
      and i.is_active
      and a.is_active
      and i.visible_to_interviewers
  );
$$;

revoke all on function private.can_view_interview_report(uuid), private.can_view_interview_document_logical(uuid) from public, anon;
grant execute on function private.can_view_interview_report(uuid), private.can_view_interview_document_logical(uuid) to authenticated, postgres, service_role;

drop policy if exists interview_reports_select on public.interview_reports;
create policy interview_reports_select on public.interview_reports
  for select to authenticated
  using (
    private.has_permission('reports.view')
    or private.is_root_admin()
    or private.can_view_interview_report(interview_reports.interview_participant_id)
  );

drop policy if exists interview_document_logicals_select on public.interview_document_logicals;
create policy interview_document_logicals_select on public.interview_document_logicals
  for select to authenticated
  using (
    private.has_permission('interviews.view')
    or private.is_root_admin()
    or private.can_view_interview_document_logical(interview_document_logicals.logical_document_id)
  );

drop policy if exists interview_documents_select on public.interview_documents;
create policy interview_documents_select on public.interview_documents
  for select to authenticated
  using (
    private.has_permission('interviews.view')
    or private.is_root_admin()
    or private.can_view_interview_document_logical(interview_documents.logical_document_id)
  );

-- -----------------------------------------------------------------------------
-- Email History table
-- -----------------------------------------------------------------------------
create table if not exists public.email_history (
  email_history_id uuid primary key default gen_random_uuid(),
  email_outbox_id uuid references public.email_outbox(email_outbox_id) on delete set null,
  interview_id uuid references public.interviews(interview_id) on delete restrict,
  application_id uuid references public.applications(application_id) on delete restrict,
  submission_id uuid references public.submissions(submission_id) on delete restrict,
  email_type text not null,
  environment_code text not null default 'PRODUCTION' check (environment_code in ('PRODUCTION','TEST')),
  recipients jsonb not null,
  subject text,
  template_version text,
  sent_by uuid references public.app_users(app_user_id) on delete restrict,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.email_history enable row level security;
revoke all on public.email_history from public, anon;
grant select on public.email_history to authenticated;
grant all on public.email_history to postgres, service_role;

drop policy if exists email_history_select on public.email_history;
create policy email_history_select on public.email_history
  for select to authenticated
  using (
    private.is_root_admin()
    or (
      private.has_permission('emails.history_view')
      and case
        when email_history.email_type like 'INTERVIEW_%' then
          email_history.interview_id is not null
          and (private.has_permission('interviews.view') or private.has_permission('interviews.manage') or private.has_permission('reports.view'))
        when email_history.email_type like 'APPLICATION_%' then
          email_history.application_id is not null
          and (private.has_permission('applications.view') or private.has_permission('applications.manage'))
        when email_history.email_type like '%SUBMISSION%' then
          email_history.submission_id is not null
          and private.has_permission('submissions.view')
        else false
      end
    )
  );
alter table public.upload_reservations
  add column if not exists finalize_request_fingerprint text,
  add column if not exists finalize_result jsonb;

create or replace view private.interview_final_decision_source
with (security_invoker = true)
as
select ci.application_id,
       ci.interview_id,
       r.interview_report_id,
       r.interview_participant_id,
       r.conclusion,
       r.expected_specific_job_assigned,
       r.expected_recruitment_time,
       r.decision_updated_at,
       r.decision_updated_by
from private.application_current_interview ci
left join lateral (
  select r1.*
  from public.interview_reports r1
  join public.interview_participants ip
    on ip.interview_participant_id = r1.interview_participant_id
  where ip.interview_id = ci.interview_id
    and ip.is_current = true
    and r1.is_active = true
    and r1.is_archived = false
    and r1.decision_updated_at is not null
    and (
      nullif(btrim(r1.conclusion), '') is not null or
      nullif(btrim(r1.expected_specific_job_assigned), '') is not null or
      nullif(btrim(r1.expected_recruitment_time), '') is not null
    )
  order by r1.decision_updated_at desc, r1.interview_report_id desc
  limit 1
) r on true;

create or replace view private.application_effective_outcome
with (security_invoker = true)
as
select ci.application_id,
       ci.interview_id,
       i.report_status_code as current_report_status_code
from private.application_current_interview ci
left join public.interviews i on i.interview_id = ci.interview_id;

-- -----------------------------------------------------------------------------
-- 3. Shared trusted-command helpers
-- -----------------------------------------------------------------------------
create or replace function private.interview_command_actor(p_permission_a text, p_permission_b text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_actor uuid;
begin
  if auth.uid() is null then return null; end if;
  select u.app_user_id into v_actor from public.app_users u
  where u.auth_user_id = auth.uid() and u.is_active = true;
  if v_actor is null then return null; end if;
  if not private.is_root_admin()
     and not private.has_permission(p_permission_a)
     and (p_permission_b is null or not private.has_permission(p_permission_b)) then
    return null;
  end if;
  return v_actor;
end;
$$;

create or replace function private.interview_resource_error(
  p_interview public.interviews,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_room_id uuid,
  p_interviewer_ids uuid[]
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidate_id uuid;
  v_conflict text;
begin
  if not private.all_current_participants_selectable(p_interview.interview_id) then
    return 'CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED';
  end if;
  select s.candidate_id into v_candidate_id
  from public.applications a join public.submissions s on s.submission_id = a.submission_id
  where a.application_id = p_interview.application_id;
  perform private.lock_interview_resources(v_candidate_id, p_room_id, p_interviewer_ids);
  select c.conflict_type into v_conflict
  from private.check_interview_conflicts(p_interview.interview_id, v_candidate_id, p_room_id, p_interviewer_ids, p_start_at, p_end_at) c
  order by case c.conflict_type when 'CANDIDATE' then 1 when 'ROOM' then 2 else 3 end
  limit 1;
  if v_conflict is null then return null; end if;
  return 'SCHEDULE_CONFLICT_' || v_conflict;
end;
$$;

create or replace function private.audit_interview_command(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_actor uuid,
  p_request_id uuid default null,
  p_data jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.activity_log(entity_type, entity_id, action_code, actor_app_user_id, request_id, source_code, old_values, new_values)
  values (p_entity_type, p_entity_id, p_action, p_actor, p_request_id, 'RPC', null, p_data);
  insert into public.security_audit_log(actor_auth_user_id, actor_app_user_id, action_code, entity_type, entity_id, request_id, source_code, metadata)
  values (auth.uid(), p_actor, p_action, p_entity_type, p_entity_id, p_request_id, 'RPC', p_data);
end;
$$;

revoke all on function private.interview_command_actor(text, text) from public, anon, authenticated;
grant execute on function private.interview_command_actor(text, text) to postgres, service_role;
revoke all on function private.interview_resource_error(public.interviews, timestamptz, timestamptz, uuid, uuid[]) from public, anon, authenticated;
grant execute on function private.interview_resource_error(public.interviews, timestamptz, timestamptz, uuid, uuid[]) to postgres, service_role;
revoke all on function private.audit_interview_command(text, text, uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function private.audit_interview_command(text, text, uuid, uuid, uuid, jsonb) to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 4. Participant lifecycle
-- -----------------------------------------------------------------------------
create or replace function public.add_interview_participant(
  p_interview_id uuid,
  p_app_user_id uuid,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_interview public.interviews%rowtype;
  v_user public.app_users%rowtype;
  v_participant_id uuid;
  v_order integer;
  v_ids uuid[];
  v_error text;
  v_result jsonb;
  v_existing jsonb;
  v_fingerprint text;
begin
  if v_actor is null then return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_idempotency_key is not null then
    v_fingerprint := encode(extensions.digest(jsonb_build_object('interview_id',p_interview_id,'app_user_id',p_app_user_id)::text,'sha256'),'hex');
    v_existing := private.check_idempotency('app_user:'||v_actor::text, 'add_interview_participant_v2', p_idempotency_key, v_fingerprint);
    if v_existing is not null then return v_existing; end if;
  end if;
  select * into v_interview from public.interviews where interview_id = p_interview_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_user from public.app_users where app_user_id = p_app_user_id and is_active = true;
  if not found then return jsonb_build_object('success',false,'error_code','USER_INACTIVE_NOT_SELECTABLE'); end if;
  if exists(select 1 from public.interview_participants where interview_id=p_interview_id and app_user_id=p_app_user_id and is_current) then
    return jsonb_build_object('success',false,'error_code','DUPLICATE_PARTICIPANT');
  end if;
  if v_interview.is_active and v_interview.schedule_status_code <> 'CANCELLED' and v_interview.start_at is not null and v_interview.end_at is not null then
    select coalesce(array_agg(ip.app_user_id order by ip.app_user_id), array[]::uuid[]) || p_app_user_id into v_ids
    from public.interview_participants ip where ip.interview_id=p_interview_id and ip.is_current;
    v_error := private.interview_resource_error(v_interview,v_interview.start_at,v_interview.end_at,v_interview.room_id,v_ids);
    if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if;
  end if;
  select coalesce(max(participant_order),0)+1 into v_order from public.interview_participants where interview_id=p_interview_id and is_current;
  insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email)
  values(p_interview_id,p_app_user_id,v_order,v_user.full_name,v_user.job_title,v_user.email)
  returning interview_participant_id into v_participant_id;
  update public.interviews set updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('ADD_INTERVIEW_PARTICIPANT','INTERVIEW_PARTICIPANT',v_participant_id,v_actor,p_idempotency_key,jsonb_build_object('interview_id',p_interview_id,'participant_order',v_order));
  v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('interview_participant_id',v_participant_id,'participant_order',v_order,'snapshot_name',v_user.full_name,'snapshot_job_title',v_user.job_title,'snapshot_email',v_user.email));
  if p_idempotency_key is not null then perform private.record_idempotency('app_user:'||v_actor::text,'add_interview_participant_v2',p_idempotency_key,v_fingerprint,v_result,'INTERVIEW_PARTICIPANT',v_participant_id); end if;
  return v_result;
end;
$$;

drop function if exists public.remove_interview_participant(uuid, bigint, uuid);
drop function if exists public.remove_interview_participant(uuid, bigint);
create or replace function public.remove_interview_participant(
  p_interview_participant_id uuid,
  p_expected_version bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_part public.interview_participants%rowtype;
  v_interview public.interviews%rowtype;
  v_has_report boolean;
  v_idemp_result jsonb;
  v_result jsonb;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_idempotency_key is not null then
    v_idemp_result := private.check_idempotency('app_user:' || v_actor::text, 'remove_interview_participant_v2', p_idempotency_key, p_interview_participant_id::text || ':' || p_expected_version::text);
    if v_idemp_result is not null then return v_idemp_result; end if;
  end if;
  select ip.* into v_part from public.interview_participants ip where ip.interview_participant_id=p_interview_participant_id;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_interview from public.interviews where interview_id=v_part.interview_id for update;
  select * into v_part from public.interview_participants where interview_participant_id=p_interview_participant_id for update;
  if v_part.version_no <> p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if not v_part.is_current then return jsonb_build_object('success',false,'error_code','ALREADY_REMOVED'); end if;
  select exists(select 1 from public.interview_reports where interview_participant_id=v_part.interview_participant_id) into v_has_report;
  update public.interview_participants set is_current=false, removed_at=clock_timestamp() where interview_participant_id=v_part.interview_participant_id;
  update public.interview_reports set is_active=false, is_archived=true, updated_by=v_actor where interview_participant_id=v_part.interview_participant_id and is_active=true and is_archived=false;
  update public.interview_participants set participant_order=participant_order+1000000 where interview_id=v_part.interview_id and is_current;
  with ordered as (select interview_participant_id,row_number() over(order by participant_order)::integer as n from public.interview_participants where interview_id=v_part.interview_id and is_current)
  update public.interview_participants ip set participant_order=o.n from ordered o where ip.interview_participant_id=o.interview_participant_id;
  update public.interviews set updated_by=v_actor where interview_id=v_part.interview_id;
  perform private.audit_interview_command('REMOVE_INTERVIEW_PARTICIPANT','INTERVIEW_PARTICIPANT',v_part.interview_participant_id,v_actor,null,jsonb_build_object('report_exists',v_has_report));
  v_result := jsonb_build_object('success',true,'data',jsonb_build_object('interview_participant_id',v_part.interview_participant_id,'removed',true,'report_exists',v_has_report));
  if p_idempotency_key is not null then
    perform private.record_idempotency('app_user:' || v_actor::text, 'remove_interview_participant_v2', p_idempotency_key, p_interview_participant_id::text || ':' || p_expected_version::text, v_result, 'INTERVIEW_PARTICIPANT', v_part.interview_participant_id);
  end if;
  return v_result;
end;
$$;

create or replace function public.remove_interview_participant(
  p_interview_participant_id uuid,
  p_expected_version bigint
)
returns jsonb
language sql security definer set search_path = ''
as $$
  select public.remove_interview_participant(p_interview_participant_id, p_expected_version, null);
$$;
revoke all on function public.remove_interview_participant(uuid, bigint) from public, anon;
grant execute on function public.remove_interview_participant(uuid, bigint) to authenticated;
revoke all on function public.remove_interview_participant(uuid, bigint, uuid) from public, anon;
grant execute on function public.remove_interview_participant(uuid, bigint, uuid) to authenticated;

create or replace function public.readd_interview_participant(p_interview_participant_id uuid, p_restore_mode text, p_idempotency_key uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_old public.interview_participants%rowtype;
  v_interview public.interviews%rowtype;
  v_user public.app_users%rowtype;
  v_ids uuid[];
  v_error text;
  v_order integer;
  v_new_id uuid;
  v_result jsonb;
  v_existing jsonb;
  v_fingerprint text;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_restore_mode not in ('RESTORE_OLD_REPORT','CREATE_NEW_REPORT') then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  if p_idempotency_key is not null then
    v_fingerprint:=encode(extensions.digest(jsonb_build_object('participant_id',p_interview_participant_id,'restore_mode',p_restore_mode)::text,'sha256'),'hex');
    v_existing:=private.check_idempotency('app_user:'||v_actor::text,'readd_interview_participant',p_idempotency_key,v_fingerprint);
    if v_existing is not null then return v_existing; end if;
  end if;
  select ip.* into v_old from public.interview_participants ip where ip.interview_participant_id=p_interview_participant_id;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_interview from public.interviews where interview_id=v_old.interview_id for update;
  select * into v_old from public.interview_participants where interview_participant_id=p_interview_participant_id for update;
  if v_old.is_current then return jsonb_build_object('success',false,'error_code','DUPLICATE_PARTICIPANT'); end if;
  select * into v_user from public.app_users where app_user_id=v_old.app_user_id and is_active;
  if not found then return jsonb_build_object('success',false,'error_code','USER_INACTIVE_NOT_SELECTABLE'); end if;
  if exists(select 1 from public.interview_participants where interview_id=v_old.interview_id and app_user_id=v_old.app_user_id and is_current) then return jsonb_build_object('success',false,'error_code','DUPLICATE_PARTICIPANT'); end if;
  if v_interview.is_active and v_interview.schedule_status_code<>'CANCELLED' and v_interview.start_at is not null and v_interview.end_at is not null then
    select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) || v_old.app_user_id into v_ids from public.interview_participants where interview_id=v_old.interview_id and is_current;
    v_error:=private.interview_resource_error(v_interview,v_interview.start_at,v_interview.end_at,v_interview.room_id,v_ids);
    if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if;
  end if;
  select coalesce(max(participant_order),0)+1 into v_order from public.interview_participants where interview_id=v_old.interview_id and is_current;
  if p_restore_mode='RESTORE_OLD_REPORT' then
    update public.interview_participants set is_current=true,removed_at=null,participant_order=v_order where interview_participant_id=v_old.interview_participant_id;
    update public.interview_reports set is_active=true,is_archived=false,updated_by=v_actor where interview_participant_id=v_old.interview_participant_id and is_active=false and is_archived=true;
    v_new_id:=v_old.interview_participant_id;
    perform private.audit_interview_command('RESTORE_PARTICIPANT_REPORT','INTERVIEW_PARTICIPANT',v_new_id,v_actor,p_idempotency_key,'{}');
  else
    insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email)
    values(v_old.interview_id,v_user.app_user_id,v_order,v_user.full_name,v_user.job_title,v_user.email) returning interview_participant_id into v_new_id;
    perform private.audit_interview_command('READD_INTERVIEW_PARTICIPANT','INTERVIEW_PARTICIPANT',v_new_id,v_actor,p_idempotency_key,jsonb_build_object('restore_mode',p_restore_mode));
  end if;
  update public.interviews set updated_by=v_actor where interview_id=v_old.interview_id;
  v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('interview_participant_id',v_new_id,'restore_mode',p_restore_mode,'participant_order',v_order));

  if p_idempotency_key is not null then perform private.record_idempotency('app_user:'||v_actor::text,'readd_interview_participant',p_idempotency_key,v_fingerprint,v_result,'INTERVIEW_PARTICIPANT',v_new_id); end if;
  return v_result;
end;
$$;

create or replace function public.reorder_interview_participants(p_interview_id uuid, p_ordered_participant_ids uuid[], p_expected_versions bigint[])
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.manage');
  v_count integer;
  v_idx integer;
  v_id uuid;
  v_expected bigint;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  perform 1 from public.interviews where interview_id=p_interview_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select count(*) into v_count from public.interview_participants where interview_id=p_interview_id and is_current;
  if cardinality(p_ordered_participant_ids) is distinct from v_count or cardinality(p_expected_versions) is distinct from v_count
     or (select count(distinct x) from unnest(p_ordered_participant_ids) x) <> v_count
     or exists(select 1 from unnest(p_ordered_participant_ids) x where not exists(select 1 from public.interview_participants ip where ip.interview_participant_id=x and ip.interview_id=p_interview_id and ip.is_current)) then
    return jsonb_build_object('success',false,'error_code','PARTICIPANT_SET_MISMATCH');
  end if;
  for v_idx in 1..v_count loop
    v_id:=p_ordered_participant_ids[v_idx]; v_expected:=p_expected_versions[v_idx];
    if not exists(select 1 from public.interview_participants where interview_participant_id=v_id and version_no=v_expected) then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  end loop;
  update public.interview_participants set participant_order=participant_order+1000000 where interview_id=p_interview_id and is_current;
  for v_idx in 1..v_count loop update public.interview_participants set participant_order=v_idx where interview_participant_id=p_ordered_participant_ids[v_idx]; end loop;
  update public.interviews set updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('REORDER_INTERVIEW_PARTICIPANTS','INTERVIEW',p_interview_id,v_actor,null,jsonb_build_object('participant_ids',p_ordered_participant_ids));
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'reordered_count',v_count));
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Schedule lifecycle
-- -----------------------------------------------------------------------------
create or replace function private.normalized_schedule_format(p_format_id uuid, p_room_id uuid, p_meeting_link text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_format public.interview_formats%rowtype;
begin
  select * into v_format from public.interview_formats where interview_format_id=p_format_id and is_active;
  if not found then return null; end if;
  if v_format.requires_room and p_room_id is null then return jsonb_build_object('error','VALIDATION_ERROR'); end if;
  if v_format.requires_meeting_link and nullif(btrim(p_meeting_link),'') is null then return jsonb_build_object('error','VALIDATION_ERROR'); end if;
  return jsonb_build_object('room_id',case when v_format.requires_room then p_room_id else null end,'meeting_link',case when v_format.requires_meeting_link then nullif(btrim(p_meeting_link),'') else null end);
end;
$$;

create or replace function public.save_interview_schedule(p_interview_id uuid,p_start_at timestamptz,p_end_at timestamptz,p_interview_format_id uuid,p_room_id uuid,p_meeting_link text,p_demo_topic text,p_interview_note text,p_expected_version bigint,p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.manage'); v_i public.interviews%rowtype; v_format jsonb; v_ids uuid[]; v_error text; v_result jsonb; v_existing jsonb; v_fingerprint text;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_start_at is not null and p_end_at is not null and p_start_at>=p_end_at then return jsonb_build_object('success',false,'error_code','INVALID_INTERVAL'); end if;
  if p_idempotency_key is not null then v_fingerprint:=encode(extensions.digest(jsonb_build_object('interview_id',p_interview_id,'start_at',p_start_at,'end_at',p_end_at,'format',p_interview_format_id,'room',p_room_id,'meeting_link',p_meeting_link,'demo_topic',p_demo_topic,'note',p_interview_note,'version',p_expected_version)::text,'sha256'),'hex'); v_existing:=private.check_idempotency('app_user:'||v_actor::text,'save_interview_schedule',p_idempotency_key,v_fingerprint); if v_existing is not null then return v_existing; end if; end if;
  select * into v_i from public.interviews where interview_id=p_interview_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_i.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_i.schedule_status_code='CONFIRMED' then return jsonb_build_object('success',false,'error_code','INVALID_STATE'); end if;
  if (p_start_at is null) <> (p_end_at is null) or (p_start_at is not null and p_interview_format_id is null) then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  if p_start_at is not null then
    v_format:=private.normalized_schedule_format(p_interview_format_id,p_room_id,p_meeting_link); if v_format is null or v_format ? 'error' then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
    select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) into v_ids from public.interview_participants where interview_id=p_interview_id and is_current;
    if v_i.is_active and v_i.schedule_status_code<>'CANCELLED' then v_error:=private.interview_resource_error(v_i,p_start_at,p_end_at,(v_format->>'room_id')::uuid,v_ids); if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if; end if;
  else v_format:=jsonb_build_object('room_id',null,'meeting_link',null); end if;
  update public.interviews set start_at=p_start_at,end_at=p_end_at,interview_format_id=p_interview_format_id,room_id=(v_format->>'room_id')::uuid,meeting_link=v_format->>'meeting_link',demo_topic=p_demo_topic,interview_note=p_interview_note,updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('SAVE_INTERVIEW_SCHEDULE','INTERVIEW',p_interview_id,v_actor,p_idempotency_key,jsonb_build_object('start_at',p_start_at,'end_at',p_end_at));
  v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id));
  if p_idempotency_key is not null then perform private.record_idempotency('app_user:'||v_actor::text,'save_interview_schedule',p_idempotency_key,v_fingerprint,v_result,'INTERVIEW',p_interview_id); end if;
  return v_result;
end;
$$;

create or replace function public.change_interview_schedule_status(p_interview_id uuid,p_schedule_status_code text,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.status'); v_i public.interviews%rowtype; v_ids uuid[]; v_error text;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_schedule_status_code not in ('AVAILABLE','SCHEDULED','AWAITING','CONFIRMED','CANCELLED') then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  select * into v_i from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_i.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if p_schedule_status_code<>'CANCELLED' and v_i.is_active and v_i.start_at is not null and v_i.end_at is not null then
    select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) into v_ids from public.interview_participants where interview_id=p_interview_id and is_current;
    v_error:=private.interview_resource_error(v_i,v_i.start_at,v_i.end_at,v_i.room_id,v_ids); if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if;
  end if;
  update public.interviews set schedule_status_code=p_schedule_status_code,updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('CHANGE_INTERVIEW_SCHEDULE_STATUS','INTERVIEW',p_interview_id,v_actor,null,jsonb_build_object('schedule_status_code',p_schedule_status_code));
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'schedule_status_code',p_schedule_status_code));
end;
$$;

create or replace function public.reschedule_confirmed_interview(p_interview_id uuid,p_start_at timestamptz,p_end_at timestamptz,p_interview_format_id uuid,p_room_id uuid,p_meeting_link text,p_expected_version bigint,p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.manage'); v_i public.interviews%rowtype; v_format jsonb; v_ids uuid[]; v_error text; v_result jsonb; v_existing jsonb; v_fingerprint text;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_start_at is null or p_end_at is null or p_start_at>=p_end_at then return jsonb_build_object('success',false,'error_code','INVALID_INTERVAL'); end if;
  if p_idempotency_key is not null then v_fingerprint:=encode(extensions.digest(jsonb_build_object('interview_id',p_interview_id,'start_at',p_start_at,'end_at',p_end_at,'format',p_interview_format_id,'room',p_room_id,'link',p_meeting_link,'version',p_expected_version)::text,'sha256'),'hex'); v_existing:=private.check_idempotency('app_user:'||v_actor::text,'reschedule_confirmed_interview',p_idempotency_key,v_fingerprint); if v_existing is not null then return v_existing; end if; end if;
  select * into v_i from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_i.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_i.schedule_status_code<>'CONFIRMED' then return jsonb_build_object('success',false,'error_code','INVALID_STATE'); end if;
  v_format:=private.normalized_schedule_format(p_interview_format_id,p_room_id,p_meeting_link); if v_format is null or v_format ? 'error' then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) into v_ids from public.interview_participants where interview_id=p_interview_id and is_current;
  v_error:=private.interview_resource_error(v_i,p_start_at,p_end_at,(v_format->>'room_id')::uuid,v_ids); if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if;
  update public.interviews set start_at=p_start_at,end_at=p_end_at,interview_format_id=p_interview_format_id,room_id=(v_format->>'room_id')::uuid,meeting_link=v_format->>'meeting_link',schedule_status_code='AWAITING',updated_by=v_actor where interview_id=p_interview_id;
  perform private.audit_interview_command('RESCHEDULE_CONFIRMED_INTERVIEW','INTERVIEW',p_interview_id,v_actor,p_idempotency_key,jsonb_build_object('schedule_status_code','AWAITING'));
  v_result:=jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'schedule_status_code','AWAITING'));
  if p_idempotency_key is not null then perform private.record_idempotency('app_user:'||v_actor::text,'reschedule_confirmed_interview',p_idempotency_key,v_fingerprint,v_result,'INTERVIEW',p_interview_id); end if;
  return v_result;
end;
$$;

create or replace function public.reactivate_interview(p_interview_id uuid,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.manage'); v_i public.interviews%rowtype; v_app public.applications%rowtype; v_ids uuid[]; v_error text;
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  select * into v_i from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_i.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  select * into v_app from public.applications where application_id=v_i.application_id for update; if not v_app.is_active then return jsonb_build_object('success',false,'error_code','APPLICATION_INACTIVE'); end if;
  if exists(select 1 from public.interviews where application_id=v_i.application_id and round_no>v_i.round_no and is_active) then return jsonb_build_object('success',false,'error_code','LATEST_ROUND_REQUIRED'); end if;
  if v_i.schedule_status_code<>'CANCELLED' and v_i.start_at is not null and v_i.end_at is not null then select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) into v_ids from public.interview_participants where interview_id=p_interview_id and is_current; v_error:=private.interview_resource_error(v_i,v_i.start_at,v_i.end_at,v_i.room_id,v_ids); if v_error is not null then return jsonb_build_object('success',false,'error_code',v_error); end if; end if;
  update public.interviews set is_active=true,updated_by=v_actor where interview_id=p_interview_id; perform private.audit_interview_command('REACTIVATE_INTERVIEW','INTERVIEW',p_interview_id,v_actor,null,'{}'); return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'is_active',true));
end;
$$;

create or replace function private.delete_or_inactivate_interview_core(p_interview_id uuid,p_expected_version bigint,p_actor uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_i public.interviews%rowtype; v_submission_id uuid; v_used boolean; v_res public.upload_reservations%rowtype;
begin
  select * into v_i from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_i.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_i.round_no<>(select max(round_no) from public.interviews where application_id=v_i.application_id and is_active) then return jsonb_build_object('success',false,'error_code','LATEST_ROUND_REQUIRED'); end if;
  select a.submission_id into v_submission_id from public.applications a where a.application_id=v_i.application_id;
  perform 1 from public.submissions where submission_id=v_submission_id for update;
  select exists(select 1 from public.interview_participants where interview_id=p_interview_id)
      or exists(select 1 from public.interview_document_logicals where interview_id=p_interview_id)
      or exists(select 1 from public.email_outbox where interview_id=p_interview_id)
      or exists(select 1 from public.email_history where interview_id=p_interview_id)
      or exists(select 1 from public.interviews where copied_from_interview_id=p_interview_id)
      or v_i.copied_from_interview_id is not null
      or v_i.start_at is not null or v_i.end_at is not null or nullif(btrim(coalesce(v_i.demo_topic,'')),'') is not null
      or nullif(btrim(coalesce(v_i.interview_note,'')),'') is not null or nullif(btrim(coalesce(v_i.hr_report_note,'')),'') is not null
      or v_i.schedule_status_code<>'AVAILABLE' or v_i.report_status_code<>'INTERVIEW_SCHEDULING' into v_used;
  if not v_used then
    for v_res in select * from public.upload_reservations where interview_id=p_interview_id for update loop
      insert into public.storage_cleanup_queue(source_type,source_parent_id,source_upload_reservation_id,bucket_name,object_path,reason_code,status_code,not_before)
      values('INTERVIEW_UPLOAD',p_interview_id,v_res.upload_reservation_id,v_res.temp_bucket,v_res.temp_path,'INTERVIEW_HARD_DELETE','PENDING',greatest(v_res.expires_at,coalesce(v_res.signed_upload_expires_at,v_res.expires_at)))
      on conflict(bucket_name,object_path) do update set not_before=greatest(public.storage_cleanup_queue.not_before,excluded.not_before);
      delete from public.upload_reservations where upload_reservation_id=v_res.upload_reservation_id;
    end loop;
    perform private.audit_interview_command('DELETE_INTERVIEW','INTERVIEW',p_interview_id,p_actor,null,'{}');
    delete from public.interviews where interview_id=p_interview_id;
    perform public.recalculate_submission_status(v_submission_id);
    return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'action','DELETED'));
  end if;
  update public.interviews set is_active=false,updated_by=p_actor where interview_id=p_interview_id;
  perform public.recalculate_submission_status(v_submission_id);
  perform private.audit_interview_command('INACTIVATE_INTERVIEW','INTERVIEW',p_interview_id,p_actor,null,'{}');
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'action','INACTIVATED'));
end;
$$;
revoke all on function private.delete_or_inactivate_interview_core(uuid, bigint, uuid) from public, anon, authenticated;
grant execute on function private.delete_or_inactivate_interview_core(uuid, bigint, uuid) to postgres, service_role;
create or replace function public.delete_or_inactivate_interview(p_interview_id uuid,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.manage');
begin if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if; return private.delete_or_inactivate_interview_core(p_interview_id,p_expected_version,v_actor); end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Reports
-- -----------------------------------------------------------------------------
create or replace function public.save_interviewer_report(p_interview_participant_id uuid,p_field_patches jsonb,p_expected_version_no bigint,p_base_values jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.current_app_user_id(); v_part public.interview_participants%rowtype; v_i public.interviews%rowtype; v_report public.interview_reports%rowtype; v_hr boolean; v_owner boolean; v_key text; v_current text; v_base text; v_conflict boolean:=false; v_updates jsonb:=coalesce(p_field_patches,'{}'::jsonb); v_allowed text[]:=array['professional_knowledge','necessary_skills','qualities_personality','strengths_limitations','other_comment','conclusion','expected_specific_job_assigned','expected_recruitment_time'];
begin
  if v_actor is null then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if jsonb_typeof(v_updates)<>'object' or exists(select 1 from jsonb_object_keys(v_updates) k where not k=any(v_allowed)) or exists(select 1 from jsonb_object_keys(v_updates) k where not (coalesce(p_base_values,'{}'::jsonb) ? k)) then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  select * into v_part from public.interview_participants where interview_participant_id=p_interview_participant_id; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_i from public.interviews where interview_id=v_part.interview_id;
  v_hr:=private.is_root_admin() or (private.has_permission('reports.view') and private.has_permission('reports.edit_interviewer'));
  v_owner:=v_part.app_user_id=v_actor and v_part.is_current and v_i.is_active and v_i.visible_to_interviewers and v_i.report_status_code not in ('HIRED','REJECTED') and exists(select 1 from private.application_current_interview ci where ci.application_id=v_i.application_id and ci.interview_id=v_i.interview_id);
  if not v_hr and not v_owner then return jsonb_build_object('success',false,'error_code','FORBIDDEN'); end if;
  select * into v_report from public.interview_reports where interview_participant_id=p_interview_participant_id and is_active and not is_archived for update;
  if not found then
    insert into public.interview_reports(interview_participant_id,created_by,updated_by) values(p_interview_participant_id,v_actor,v_actor) returning * into v_report;
    select * into v_report from public.interview_reports where interview_report_id=v_report.interview_report_id for update;
  end if;
  for v_key in select jsonb_object_keys(v_updates) loop
    execute format('select %I from public.interview_reports where interview_report_id=$1',v_key) into v_current using v_report.interview_report_id;
    v_base:=p_base_values->>v_key;
    if v_current is distinct from v_base then v_conflict:=true; end if;
  end loop;
  if v_hr and v_conflict then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if v_owner and v_report.version_no<>p_expected_version_no and v_report.updated_by=v_actor then
    return jsonb_build_object('success',false,'error_code','STALE_VERSION');
  end if;
  update public.interview_reports set
    professional_knowledge=case when v_updates?'professional_knowledge' then v_updates->>'professional_knowledge' else professional_knowledge end,
    necessary_skills=case when v_updates?'necessary_skills' then v_updates->>'necessary_skills' else necessary_skills end,
    qualities_personality=case when v_updates?'qualities_personality' then v_updates->>'qualities_personality' else qualities_personality end,
    strengths_limitations=case when v_updates?'strengths_limitations' then v_updates->>'strengths_limitations' else strengths_limitations end,
    other_comment=case when v_updates?'other_comment' then v_updates->>'other_comment' else other_comment end,
    conclusion=case when v_updates?'conclusion' then v_updates->>'conclusion' else conclusion end,
    expected_specific_job_assigned=case when v_updates?'expected_specific_job_assigned' then v_updates->>'expected_specific_job_assigned' else expected_specific_job_assigned end,
    expected_recruitment_time=case when v_updates?'expected_recruitment_time' then v_updates->>'expected_recruitment_time' else expected_recruitment_time end,
    updated_by=v_actor
  where interview_report_id=v_report.interview_report_id returning * into v_report;
  perform private.audit_interview_command('SAVE_INTERVIEWER_REPORT','INTERVIEW_REPORT',v_report.interview_report_id,v_actor,null,jsonb_build_object('patched_fields',v_updates));
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_report_id',v_report.interview_report_id,'version_no',v_report.version_no));
end;
$$;

create or replace function public.change_report_status(p_interview_id uuid,p_report_status_code text,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('reports.manage_status'); v_i public.interviews%rowtype; v_app public.applications%rowtype; v_application_id uuid;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('reports.view')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_report_status_code not in ('INTERVIEW_SCHEDULING','AWAITING_INTERVIEW','WAITING_FOR_REPORT','REPORT_SUBMITTED','FOLLOW_UP','ON_HOLD','HIRED','REJECTED') then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  select application_id into v_application_id from public.interviews where interview_id=p_interview_id;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_app from public.applications where application_id=v_application_id for update;
  if not found or not v_app.is_active then return jsonb_build_object('success',false,'error_code','APPLICATION_INACTIVE'); end if;
  select * into v_i from public.interviews where interview_id=p_interview_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_i.application_id<>v_app.application_id then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if v_i.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  if not exists(select 1 from private.application_current_interview where application_id=v_i.application_id and interview_id=v_i.interview_id) then return jsonb_build_object('success',false,'error_code','LATEST_ROUND_REQUIRED'); end if;
  perform 1 from public.submissions where submission_id=v_app.submission_id for update;
  update public.interviews set report_status_code=p_report_status_code,updated_by=v_actor where interview_id=p_interview_id;
  perform public.recalculate_submission_status(v_app.submission_id); perform private.audit_interview_command('CHANGE_REPORT_STATUS','INTERVIEW',p_interview_id,v_actor,null,jsonb_build_object('report_status_code',p_report_status_code));
  return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id,'report_status_code',p_report_status_code));
end;
$$;

create or replace function public.update_hr_report_note(p_interview_id uuid,p_hr_report_note text,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('reports.manage_status'); v_i public.interviews%rowtype;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('reports.view')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  select * into v_i from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if; if v_i.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  update public.interviews set hr_report_note=p_hr_report_note,updated_by=v_actor where interview_id=p_interview_id; perform private.audit_interview_command('UPDATE_HR_REPORT_NOTE','INTERVIEW',p_interview_id,v_actor,null,'{}'); return jsonb_build_object('success',true,'data',jsonb_build_object('interview_id',p_interview_id));
end;
$$;

create or replace function public.delete_or_inactivate_report(p_interview_report_id uuid,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('reports.manage_status'); v_r public.interview_reports%rowtype; v_used boolean;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('reports.view')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  select * into v_r from public.interview_reports where interview_report_id=p_interview_report_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if; if v_r.version_no<>p_expected_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
  v_used:=nullif(btrim(coalesce(v_r.professional_knowledge,'')),'') is not null or nullif(btrim(coalesce(v_r.necessary_skills,'')),'') is not null or nullif(btrim(coalesce(v_r.qualities_personality,'')),'') is not null or nullif(btrim(coalesce(v_r.strengths_limitations,'')),'') is not null or nullif(btrim(coalesce(v_r.other_comment,'')),'') is not null or nullif(btrim(coalesce(v_r.conclusion,'')),'') is not null or nullif(btrim(coalesce(v_r.expected_specific_job_assigned,'')),'') is not null or nullif(btrim(coalesce(v_r.expected_recruitment_time,'')),'') is not null or v_r.decision_updated_at is not null;
  if v_used then update public.interview_reports set is_active=false,is_archived=true,updated_by=v_actor where interview_report_id=p_interview_report_id; perform private.audit_interview_command('INACTIVATE_INTERVIEW_REPORT','INTERVIEW_REPORT',p_interview_report_id,v_actor,null,'{}'); return jsonb_build_object('success',true,'data',jsonb_build_object('action','INACTIVATED')); end if;
  delete from public.interview_reports where interview_report_id=p_interview_report_id; perform private.audit_interview_command('DELETE_INTERVIEW_REPORT','INTERVIEW_REPORT',p_interview_report_id,v_actor,null,'{}'); return jsonb_build_object('success',true,'data',jsonb_build_object('action','DELETED'));
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Interview document upload lifecycle
-- -----------------------------------------------------------------------------
create or replace function public.reserve_interview_upload(p_interview_id uuid,p_document_type_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.documents'); v_type public.document_types%rowtype; v_res uuid; v_path text;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.manage')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  perform 1 from public.interviews where interview_id=p_interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  select * into v_type from public.document_types where document_type_id=p_document_type_id and is_active and scope_code in ('INTERVIEW','BOTH'); if not found then return jsonb_build_object('success',false,'error_code','INVALID_DOCUMENT_TYPE'); end if;
  v_res:=gen_random_uuid(); v_path:='temp/interview/'||p_interview_id::text||'/'||v_res::text;
  insert into public.upload_reservations(upload_reservation_id,interview_id,intended_document_type_id,temp_bucket,temp_path,original_filename,expected_max_size_bytes,malware_scan_status,status_code,actor_auth_user_id,idempotency_key,expires_at)
  values(v_res,p_interview_id,p_document_type_id,'interview-quarantine',v_path,'pending-upload',5242880,'PENDING','RESERVED',auth.uid(),v_res,clock_timestamp()+interval '30 minutes');
  perform private.audit_interview_command('RESERVE_INTERVIEW_UPLOAD','UPLOAD_RESERVATION',v_res,v_actor,v_res,jsonb_build_object('interview_id',p_interview_id));
  return jsonb_build_object('success',true,'data',jsonb_build_object('upload_reservation_id',v_res,'temp_bucket','interview-quarantine','temp_path',v_path,'expires_at',clock_timestamp()+interval '30 minutes','presigned_upload_url',null));
end;
$$;

create or replace function public.finalize_interview_upload(p_reservation_id uuid,p_logical_document_id_or_null uuid,p_storage_bucket text,p_storage_path text,p_original_filename text,p_mime_type text,p_file_size_bytes bigint,p_checksum_sha256 text,p_expected_logical_version_or_null integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.documents'); v_res public.upload_reservations%rowtype; v_i public.interviews%rowtype; v_logical public.interview_document_logicals%rowtype; v_document uuid; v_count integer; v_version integer; v_old public.interview_documents%rowtype; v_fingerprint text; v_result jsonb;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.manage')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  select * into v_res from public.upload_reservations where upload_reservation_id=p_reservation_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'logical_document_id', p_logical_document_id_or_null,
    'storage_bucket', p_storage_bucket,
    'storage_path', p_storage_path,
    'original_filename', p_original_filename,
    'mime_type', p_mime_type,
    'file_size_bytes', p_file_size_bytes,
    'checksum_sha256', p_checksum_sha256,
    'expected_logical_version', p_expected_logical_version_or_null
  )::text, 'sha256'), 'hex');
  if v_res.status_code = 'FINALIZED' then
    if v_res.finalize_request_fingerprint = v_fingerprint and v_res.finalize_result is not null then
      return v_res.finalize_result;
    end if;
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR');
  end if;
  if v_res.interview_id is null or v_res.status_code not in ('VALIDATED','UPLOADED') or v_res.malware_scan_status<>'CLEAN' then return jsonb_build_object('success',false,'error_code','MALWARE_SCAN_REQUIRED'); end if;
  if v_res.expires_at<=clock_timestamp() then return jsonb_build_object('success',false,'error_code','UPLOAD_RESERVATION_EXPIRED'); end if;
  if v_res.actual_size_bytes is null
     or v_res.checksum_sha256 is null
     or v_res.detected_mime_type is null
     or v_res.actual_size_bytes <> p_file_size_bytes
     or lower(v_res.checksum_sha256) <> lower(coalesce(p_checksum_sha256, ''))
     or v_res.detected_mime_type <> p_mime_type then
    return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR');
  end if;
  select * into v_i from public.interviews where interview_id=v_res.interview_id for update;
  if p_original_filename is null or char_length(p_original_filename)>255 or p_file_size_bytes is null or p_file_size_bytes<=0 or p_file_size_bytes>5242880 or p_mime_type not in ('application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation','image/png','image/jpeg') or (p_checksum_sha256 is not null and p_checksum_sha256 !~ '^[0-9A-Fa-f]{64}$') then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  if p_logical_document_id_or_null is null then
    select count(*) into v_count from public.interview_documents d join public.interview_document_logicals l on l.logical_document_id=d.logical_document_id where l.interview_id=v_i.interview_id and d.is_current;
    if v_count>=5 then return jsonb_build_object('success',false,'error_code','UPLOAD_LIMIT_EXCEEDED'); end if;
    insert into public.interview_document_logicals(interview_id,document_type_id,created_by) values(v_i.interview_id,v_res.intended_document_type_id,v_actor) returning * into v_logical; v_version:=1;
  else
    select * into v_logical from public.interview_document_logicals where logical_document_id=p_logical_document_id_or_null and interview_id=v_i.interview_id for update; if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
    select * into v_old from public.interview_documents where logical_document_id=v_logical.logical_document_id and is_current for update; if not found then return jsonb_build_object('success',false,'error_code','INVALID_DOCUMENT_TARGET'); end if;
    if p_expected_logical_version_or_null is null or v_old.version_no<>p_expected_logical_version_or_null then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
    v_version:=v_old.version_no+1; update public.interview_documents set is_current=false where interview_document_id=v_old.interview_document_id;
    insert into public.storage_cleanup_queue(source_type,source_parent_id,bucket_name,object_path,reason_code,status_code) values('INTERVIEW_UPLOAD',v_i.interview_id,v_old.storage_bucket,v_old.storage_path,'DOCUMENT_REPLACED','PENDING') on conflict(bucket_name,object_path) do nothing;
  end if;
  insert into public.interview_documents(logical_document_id,storage_bucket,storage_path,original_filename,mime_type,file_size_bytes,checksum_sha256,version_no,is_current,uploaded_by)
  values(v_logical.logical_document_id,p_storage_bucket,p_storage_path,p_original_filename,v_res.detected_mime_type,v_res.actual_size_bytes,v_res.checksum_sha256,v_version,true,v_actor) returning interview_document_id into v_document;
  v_result := jsonb_build_object('success',true,'data',jsonb_build_object('interview_document_id',v_document,'logical_document_id',v_logical.logical_document_id,'version_no',v_version));
  update public.upload_reservations set status_code='FINALIZED', finalize_request_fingerprint=v_fingerprint, finalize_result=v_result where upload_reservation_id=p_reservation_id;
  perform private.audit_interview_command('FINALIZE_INTERVIEW_UPLOAD','INTERVIEW_DOCUMENT',v_document,v_actor,p_reservation_id,jsonb_build_object('interview_id',v_i.interview_id));
  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Deterministic bulk commands
-- -----------------------------------------------------------------------------
create or replace function public.bulk_delete_or_inactivate_interviews(p_interview_ids uuid[],p_expected_versions bigint[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=private.interview_command_actor('interviews.manage'); v_id uuid; v_result jsonb; v_items jsonb:='[]'::jsonb; v_version bigint;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if cardinality(p_interview_ids) is null or cardinality(p_interview_ids)>100 or cardinality(p_interview_ids)<>cardinality(p_expected_versions) or (select count(distinct x) from unnest(p_interview_ids) x)<>cardinality(p_interview_ids) then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  perform 1 from public.interviews where interview_id=any(p_interview_ids) order by interview_id for update;
  if (select count(*) from public.interviews where interview_id=any(p_interview_ids))<>cardinality(p_interview_ids) then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  for v_id in select x from unnest(p_interview_ids) x order by x loop
    select p_expected_versions[array_position(p_interview_ids,v_id)] into v_version; v_result:=private.delete_or_inactivate_interview_core(v_id,v_version,v_actor); if not coalesce((v_result->>'success')::boolean,false) then return v_result; end if; v_items:=v_items||jsonb_build_array(v_result->'data');
  end loop;
  return jsonb_build_object('success',true,'data',jsonb_build_object('items',v_items));
end;
$$;

create or replace function public.bulk_change_interview_schedule_status(p_interview_ids uuid[],p_target_status text,p_expected_versions bigint[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid:=private.interview_command_actor('interviews.status');
  v_id uuid;
  v_i public.interviews%rowtype;
  v_version bigint;
  v_cand uuid;
  v_lock_id uuid;
  v_ids uuid[];
  v_conflict text;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.view')) then return jsonb_build_object('success',false,'error_code',case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end); end if;
  if p_target_status not in ('AVAILABLE','SCHEDULED','AWAITING','CONFIRMED','CANCELLED') or cardinality(p_interview_ids) is null or cardinality(p_interview_ids)>100 or cardinality(p_interview_ids)<>cardinality(p_expected_versions) or (select count(distinct x) from unnest(p_interview_ids) x)<>cardinality(p_interview_ids) then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
  perform 1 from public.interviews where interview_id=any(p_interview_ids) order by interview_id for update;
  if (select count(*) from public.interviews where interview_id=any(p_interview_ids))<>cardinality(p_interview_ids) then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
  if p_target_status<>'CANCELLED' then
    for v_lock_id in
      select distinct s.candidate_id
      from public.interviews i
      join public.applications a on a.application_id=i.application_id
      join public.submissions s on s.submission_id=a.submission_id
      where i.interview_id=any(p_interview_ids)
        and i.is_active and i.start_at is not null and i.end_at is not null
        and s.candidate_id is not null
      order by s.candidate_id
    loop
      perform pg_advisory_xact_lock(hashtextextended('candidate:' || v_lock_id::text, 0));
    end loop;
    for v_lock_id in
      select distinct i.room_id
      from public.interviews i
      where i.interview_id=any(p_interview_ids)
        and i.is_active and i.start_at is not null and i.end_at is not null
        and i.room_id is not null
      order by i.room_id
    loop
      perform pg_advisory_xact_lock(hashtextextended('room:' || v_lock_id::text, 0));
    end loop;
    for v_lock_id in
      select distinct ip.app_user_id
      from public.interview_participants ip
      join public.interviews i on i.interview_id=ip.interview_id
      where i.interview_id=any(p_interview_ids)
        and i.is_active and i.start_at is not null and i.end_at is not null
        and ip.is_current and ip.app_user_id is not null
      order by ip.app_user_id
    loop
      perform pg_advisory_xact_lock(hashtextextended('interviewer:' || v_lock_id::text, 0));
    end loop;
  end if;
  for v_id in select x from unnest(p_interview_ids) x order by x loop
    select * into v_i from public.interviews where interview_id=v_id; select p_expected_versions[array_position(p_interview_ids,v_id)] into v_version; if v_i.version_no<>v_version then return jsonb_build_object('success',false,'error_code','STALE_VERSION'); end if;
    if p_target_status<>'CANCELLED' and v_i.is_active and v_i.start_at is not null and v_i.end_at is not null then
      if not private.all_current_participants_selectable(v_id) then return jsonb_build_object('success',false,'error_code','CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED'); end if;
      select s.candidate_id into v_cand from public.applications a join public.submissions s on s.submission_id=a.submission_id where a.application_id=v_i.application_id;
      select coalesce(array_agg(app_user_id order by app_user_id),array[]::uuid[]) into v_ids from public.interview_participants where interview_id=v_id and is_current;
      select c.conflict_type into v_conflict from private.check_interview_conflicts(v_id, v_cand, v_i.room_id, v_ids, v_i.start_at, v_i.end_at) c order by case c.conflict_type when 'CANDIDATE' then 1 when 'ROOM' then 2 else 3 end limit 1;
      if v_conflict is not null then return jsonb_build_object('success',false,'error_code','SCHEDULE_CONFLICT_' || v_conflict); end if;
    end if;
  end loop;
  update public.interviews set schedule_status_code=p_target_status,updated_by=v_actor where interview_id=any(p_interview_ids);
  for v_id in select x from unnest(p_interview_ids) x order by x loop perform private.audit_interview_command('BULK_CHANGE_INTERVIEW_SCHEDULE_STATUS','INTERVIEW',v_id,v_actor,null,jsonb_build_object('schedule_status_code',p_target_status)); end loop;
  return jsonb_build_object('success',true,'data',jsonb_build_object('count',cardinality(p_interview_ids),'schedule_status_code',p_target_status));
end;
$$;

-- Expose only command APIs; direct DML remains denied by table grants/RLS.
revoke all on function public.add_interview_participant(uuid,uuid,uuid), public.remove_interview_participant(uuid,bigint), public.readd_interview_participant(uuid,text,uuid), public.reorder_interview_participants(uuid,uuid[],bigint[]), public.save_interview_schedule(uuid,timestamptz,timestamptz,uuid,uuid,text,text,text,bigint,uuid), public.change_interview_schedule_status(uuid,text,bigint), public.reschedule_confirmed_interview(uuid,timestamptz,timestamptz,uuid,uuid,text,bigint,uuid), public.reactivate_interview(uuid,bigint), public.delete_or_inactivate_interview(uuid,bigint), public.save_interviewer_report(uuid,jsonb,bigint,jsonb), public.change_report_status(uuid,text,bigint), public.update_hr_report_note(uuid,text,bigint), public.delete_or_inactivate_report(uuid,bigint), public.reserve_interview_upload(uuid,uuid), public.finalize_interview_upload(uuid,uuid,text,text,text,text,bigint,text,integer), public.bulk_delete_or_inactivate_interviews(uuid[],bigint[]), public.bulk_change_interview_schedule_status(uuid[],text,bigint[]) from public, anon;
grant execute on function public.add_interview_participant(uuid,uuid,uuid), public.remove_interview_participant(uuid,bigint), public.readd_interview_participant(uuid,text,uuid), public.reorder_interview_participants(uuid,uuid[],bigint[]), public.save_interview_schedule(uuid,timestamptz,timestamptz,uuid,uuid,text,text,text,bigint,uuid), public.change_interview_schedule_status(uuid,text,bigint), public.reschedule_confirmed_interview(uuid,timestamptz,timestamptz,uuid,uuid,text,bigint,uuid), public.reactivate_interview(uuid,bigint), public.delete_or_inactivate_interview(uuid,bigint), public.save_interviewer_report(uuid,jsonb,bigint,jsonb), public.change_report_status(uuid,text,bigint), public.update_hr_report_note(uuid,text,bigint), public.delete_or_inactivate_report(uuid,bigint), public.reserve_interview_upload(uuid,uuid), public.finalize_interview_upload(uuid,uuid,text,text,text,text,bigint,text,integer), public.bulk_delete_or_inactivate_interviews(uuid[],bigint[]), public.bulk_change_interview_schedule_status(uuid[],text,bigint[]) to authenticated;
