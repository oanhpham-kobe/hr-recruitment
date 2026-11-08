-- Migration: 20260906005000_pre_s04_contract_repairs.sql
-- PRE-S04 HOTFIX: Technical Source v1.18 implementation alignment, permissions,
-- RLS repair, pure detail read, candidate submission signatures & validation,
-- document materialization, authoritative outcome resolver, HR correction command,
-- and search/outbox safety.

-- -----------------------------------------------------------------------------
-- 1. Permissions Seed & Dependencies
-- -----------------------------------------------------------------------------
insert into public.permissions(permission_code, description) values
  ('applications.view', 'View applications'),
  ('candidates.identity_manage', 'Manage Candidate login email identity recovery')
on conflict (permission_code) do update set description = excluded.description;

-- Update dependency: applications.manage requires applications.view (not submissions.view)
delete from public.permission_dependencies
where permission_code = 'applications.manage' and requires_permission_code = 'submissions.view';

insert into public.permission_dependencies(permission_code, requires_permission_code) values
  ('applications.manage', 'applications.view')
on conflict do nothing;

-- Backfill applications.view for existing users who hold applications.manage
insert into public.app_user_permissions(app_user_id, permission_code, granted_by, granted_at)
select aup.app_user_id, 'applications.view', aup.granted_by, coalesce(aup.granted_at, now())
from public.app_user_permissions aup
where aup.permission_code = 'applications.manage'
on conflict (app_user_id, permission_code) do nothing;

-- -----------------------------------------------------------------------------
-- 2. Physical Email Outbox Table (Canonical DDL)
-- -----------------------------------------------------------------------------
create table if not exists public.email_outbox (
  email_outbox_id uuid primary key default gen_random_uuid(),
  interview_id uuid references public.interviews(interview_id) on delete restrict,
  application_id uuid references public.applications(application_id) on delete restrict,
  submission_id uuid references public.submissions(submission_id) on delete restrict,
  email_type text not null,
  environment_code text not null default 'TEST' check (environment_code in ('PRODUCTION','TEST')),
  recipients jsonb not null,
  subject text not null,
  body_html text,
  body_text text,
  template_version text,
  status_code text not null default 'QUEUED'
    check (status_code in ('QUEUED','SENDING','SENT','FAILED','CANCELLED')),
  attempt_no integer not null default 0 check (attempt_no >= 0),
  next_attempt_at timestamptz,
  locked_at timestamptz,
  locked_until timestamptz,
  worker_id text,
  last_error text,
  provider_message_id text,
  provider_error_code text,
  provider_error_message text,
  idempotency_key uuid not null,
  actor_scope text not null,
  created_by_app_user_id uuid references public.app_users(app_user_id) on delete restrict,
  created_by_candidate_id uuid references public.candidates(candidate_id) on delete restrict,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique(actor_scope, email_type, idempotency_key)
);

alter table public.email_outbox drop constraint if exists email_outbox_one_human_actor_ck;
alter table public.email_outbox add constraint email_outbox_one_human_actor_ck
  check ((created_by_app_user_id is not null)::int + (created_by_candidate_id is not null)::int <= 1);

create index if not exists email_outbox_status_next_idx
  on public.email_outbox(status_code, next_attempt_at)
  where status_code in ('QUEUED', 'SENDING');
create index if not exists email_outbox_submission_idx
  on public.email_outbox(submission_id);

alter table public.email_outbox enable row level security;
revoke all on public.email_outbox from public, anon, authenticated;
grant all on public.email_outbox to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. Application & Interview RLS Select Policies Direct Repair
-- Remove submissions.view; require Root OR view OR manage
-- -----------------------------------------------------------------------------
drop policy if exists applications_select on public.applications;
create policy applications_select on public.applications
  for select to authenticated
  using (
    private.is_root_admin()
    or private.has_permission('applications.view')
    or private.has_permission('applications.manage')
  );

drop policy if exists interviews_select on public.interviews;
create policy interviews_select on public.interviews
  for select to authenticated
  using (
    private.is_root_admin()
    or private.has_permission('interviews.view')
    or private.has_permission('interviews.manage')
  );

-- -----------------------------------------------------------------------------
-- 4. Authoritative Application Effective Outcome Resolver
-- Application outcome derives solely from Current Round (highest active round_no)
-- -----------------------------------------------------------------------------
create or replace function private.application_effective_outcome(p_application_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app_active boolean;
  v_current_round_status text;
begin
  select a.is_active into v_app_active
  from public.applications a
  where a.application_id = p_application_id;

  if v_app_active is null or not v_app_active then
    return 'IN_PROGRESS';
  end if;

  -- Current Round: highest round_no among access-active interviews
  select i.report_status_code into v_current_round_status
  from public.interviews i
  where i.application_id = p_application_id
    and i.is_active = true
  order by i.round_no desc, i.created_at desc
  limit 1;

  if v_current_round_status = 'HIRED' then
    return 'HIRED';
  elsif v_current_round_status = 'REJECTED' then
    return 'REJECTED';
  else
    return 'IN_PROGRESS';
  end if;
end;
$$;

revoke all on function private.application_effective_outcome(uuid) from public, anon, authenticated;
grant execute on function private.application_effective_outcome(uuid) to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 5. Authoritative recalculate_submission_status & Helper ACL Protection
-- -----------------------------------------------------------------------------
create or replace function public.recalculate_submission_status(
  p_submission_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_status text;
  v_new_status text;
  v_active_apps integer;
  v_has_hired boolean;
  v_all_rejected boolean;
begin
  -- Mandatory parent lock
  select status_code into v_current_status
  from public.submissions
  where submission_id = p_submission_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Submission not found'
    );
  end if;

  -- Count active applications
  select count(*) into v_active_apps
  from public.applications
  where submission_id = p_submission_id
    and is_active = true;

  if v_active_apps = 0 then
    -- Rule: if no active application exists, preserve existing manual NEW or READ.
    -- If coming from a derived state (PROCESSED, DONE, CLOSED), return READ.
    if v_current_status in ('PROCESSED', 'DONE', 'CLOSED') then
      v_new_status := 'READ';
    else
      v_new_status := v_current_status;
    end if;
  else
    -- Active applications exist: resolve using authoritative resolver
    select exists (
      select 1
      from public.applications a
      where a.submission_id = p_submission_id
        and a.is_active = true
        and private.application_effective_outcome(a.application_id) = 'HIRED'
    ) into v_has_hired;

    if v_has_hired then
      v_new_status := 'DONE';
    else
      select (
        v_active_apps > 0
        and not exists (
          select 1
          from public.applications a
          where a.submission_id = p_submission_id
            and a.is_active = true
            and private.application_effective_outcome(a.application_id) <> 'REJECTED'
        )
      ) into v_all_rejected;

      if v_all_rejected then
        v_new_status := 'CLOSED';
      else
        v_new_status := 'PROCESSED';
      end if;
    end if;
  end if;

  -- Update submission status if changed
  if v_new_status is distinct from v_current_status then
    update public.submissions
    set
      status_code = v_new_status,
      updated_at = clock_timestamp()
    where submission_id = p_submission_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'submission_id', p_submission_id,
    'previous_status', v_current_status,
    'new_status', v_new_status,
    'active_applications_count', v_active_apps
  );
end;
$$;

-- Deny-by-default execution ACL for internal recalculation helper
revoke all on function public.recalculate_submission_status(uuid) from public, anon, authenticated;
grant execute on function public.recalculate_submission_status(uuid) to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 6. Update Candidate Lifecycle Recalculation (set_candidate_active)
-- Reuse private.application_effective_outcome
-- -----------------------------------------------------------------------------
create or replace function public.set_candidate_active(
  p_candidate_id uuid,
  p_active boolean,
  p_expected_version bigint,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_cand record;
  v_previous_is_active boolean;
  v_sub record;
  v_sub_active_apps integer;
  v_has_hired boolean;
  v_all_rejected boolean;
  v_new_sub_status text;
  v_result jsonb;
begin
  -- 1. Authentication & Permission Check
  v_auth_user_id := auth.uid();
  if v_auth_user_id is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select u.app_user_id into v_actor_app_user_id
  from public.app_users u
  where u.auth_user_id = v_auth_user_id
    and u.is_active = true;

  if v_actor_app_user_id is null
    or not (private.has_permission('candidates.active_manage') or private.is_root_admin()) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission candidates.active_manage required');
  end if;

  -- 2. Validation
  if p_candidate_id is null
    or p_active is null
    or p_expected_version is null
    or p_expected_version <= 0 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid candidate lifecycle request');
  end if;

  -- 3. Idempotency Check
  if p_idempotency_key is not null then
    v_actor_scope := 'app_user:' || v_actor_app_user_id::text;
    v_fingerprint := encode(
      extensions.digest(
        jsonb_build_object(
          'command', 'set_candidate_active',
          'candidate_id', p_candidate_id,
          'active', p_active,
          'expected_version', p_expected_version
        )::text,
        'sha256'
      ),
      'hex'
    );

    v_existing_result := private.check_idempotency(v_actor_scope, 'set_candidate_active', p_idempotency_key, v_fingerprint);
    if v_existing_result is not null then
      return v_existing_result;
    end if;
  end if;

  -- 4. Optimistic Version & Lock Candidate
  select * into v_cand
  from public.candidates
  where candidate_id = p_candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate not found');
  end if;

  if v_cand.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Candidate version mismatch; reload required');
  end if;

  v_previous_is_active := v_cand.is_active;

  -- 5. Mutation & Reactivation Submissions Recalculation
  if p_active = false then
    update public.candidates
    set
      is_active = false,
      inactive_at = clock_timestamp(),
      inactive_by = v_actor_app_user_id,
      updated_at = clock_timestamp()
    where candidate_id = p_candidate_id
    returning * into v_cand;
  else
    update public.candidates
    set
      is_active = true,
      inactive_at = null,
      inactive_by = null,
      updated_at = clock_timestamp()
    where candidate_id = p_candidate_id
    returning * into v_cand;

    -- Lock Submissions and active Applications in deterministic order
    perform 1
    from public.submissions s
    where s.candidate_id = p_candidate_id
    order by s.submission_id
    for update;

    perform 1
    from public.applications a
    join public.submissions s on s.submission_id = a.submission_id
    where s.candidate_id = p_candidate_id
      and a.is_active = true
    order by a.submission_id, a.application_id
    for update;

    -- Re-evaluate all Submissions for candidate using authoritative outcome resolver
    for v_sub in
      select s.submission_id, s.status_code
      from public.submissions s
      where s.candidate_id = p_candidate_id
      order by s.submission_id
    loop
      select count(*) into v_sub_active_apps
      from public.applications
      where submission_id = v_sub.submission_id
        and is_active = true;

      if v_sub_active_apps = 0 then
        -- Owner Decision D: Candidate Reactivate deliberate exception
        v_new_sub_status := 'READ';
      else
        select exists (
          select 1
          from public.applications a
          where a.submission_id = v_sub.submission_id
            and a.is_active = true
            and private.application_effective_outcome(a.application_id) = 'HIRED'
        ) into v_has_hired;

        if v_has_hired then
          v_new_sub_status := 'DONE';
        else
          select (
            v_sub_active_apps > 0
            and not exists (
              select 1
              from public.applications a
              where a.submission_id = v_sub.submission_id
                and a.is_active = true
                and private.application_effective_outcome(a.application_id) <> 'REJECTED'
            )
          ) into v_all_rejected;

          if v_all_rejected then
            v_new_sub_status := 'CLOSED';
          else
            v_new_sub_status := 'PROCESSED';
          end if;
        end if;
      end if;

      if v_new_sub_status is distinct from v_sub.status_code then
        update public.submissions
        set
          status_code = v_new_sub_status,
          updated_at = clock_timestamp()
        where submission_id = v_sub.submission_id;
      end if;
    end loop;
  end if;

  -- 6. Audit Logging
  insert into public.security_audit_log (
    action_code,
    actor_app_user_id,
    entity_type,
    entity_id,
    metadata,
    source_code,
    result_code
  ) values (
    'SET_CANDIDATE_ACTIVE',
    v_actor_app_user_id,
    'CANDIDATE',
    p_candidate_id,
    jsonb_build_object(
      'candidate_id', p_candidate_id,
      'is_active', p_active,
      'previous_is_active', v_previous_is_active,
      'version_no', v_cand.version_no
    ),
    'RPC',
    'SUCCESS'
  );
  v_result := jsonb_build_object(
    'success', true,
    'candidate_id', v_cand.candidate_id,
    'is_active', v_cand.is_active,
    'version_no', v_cand.version_no,
    'inactive_at', v_cand.inactive_at,
    'inactive_by', v_cand.inactive_by
  );

  if p_idempotency_key is not null then
    perform private.record_idempotency(v_actor_scope, 'set_candidate_active', p_idempotency_key, v_fingerprint, v_result);
  end if;

  return v_result;
end;
$$;

revoke all on function public.set_candidate_active(uuid, boolean, bigint, uuid) from public, anon;
grant execute on function public.set_candidate_active(uuid, boolean, bigint, uuid) to authenticated;

-- Also update bulk_set_candidate_active recalculation to use private.application_effective_outcome
create or replace function public.bulk_set_candidate_active(
  p_candidate_ids uuid[],
  p_active boolean,
  p_expected_versions bigint[],
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
  v_actor_scope text;
  v_fingerprint text;
  v_existing_result jsonb;
  v_count integer;
  v_selection record;
  v_cand record;
  v_previous_is_active boolean;
  v_sub record;
  v_sub_active_apps integer;
  v_has_hired boolean;
  v_all_rejected boolean;
  v_new_sub_status text;
  v_result_items jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  -- 1. Authentication & Permission Check
  v_auth_user_id := auth.uid();
  if v_auth_user_id is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select u.app_user_id into v_actor_app_user_id
  from public.app_users u
  where u.auth_user_id = v_auth_user_id
    and u.is_active = true;

  if v_actor_app_user_id is null
    or not (private.has_permission('candidates.active_manage') or private.is_root_admin()) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission candidates.active_manage required');
  end if;

  -- 2. Strict Batch Validation (ALL_OR_NOTHING)
  if p_candidate_ids is null
    or cardinality(p_candidate_ids) = 0
    or p_expected_versions is null
    or cardinality(p_candidate_ids) <> cardinality(p_expected_versions)
    or array_position(p_candidate_ids, null) is not null
    or array_position(p_expected_versions, null) is not null
    or exists (select 1 from unnest(p_expected_versions) as v(version_no) where v.version_no <= 0)
    or exists (
      select 1
      from unnest(p_candidate_ids) as c(candidate_id)
      group by c.candidate_id
      having count(*) > 1
    )
    or p_active is null
    or p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Invalid bulk candidate active request');
  end if;

  v_count := cardinality(p_candidate_ids);
  if v_count > 100 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Batch size exceeds maximum limit of 100');
  end if;

  -- 3. Idempotency Check
  v_actor_scope := 'app_user:' || v_actor_app_user_id::text;
  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'command', 'bulk_set_candidate_active',
        'candidate_ids', to_jsonb(p_candidate_ids),
        'expected_versions', to_jsonb(p_expected_versions),
        'active', p_active
      )::text,
      'sha256'
    ),
    'hex'
  );

  v_existing_result := private.check_idempotency(v_actor_scope, 'bulk_set_candidate_active', p_idempotency_key, v_fingerprint);
  if v_existing_result is not null then
    return v_existing_result;
  end if;

  -- 4. Prevalidate & Lock Candidates in deterministic order
  for v_selection in
    select t.candidate_id, t.expected_version
    from unnest(p_candidate_ids, p_expected_versions) with ordinality as t(candidate_id, expected_version, ord)
    order by t.candidate_id
  loop
    select * into v_cand
    from public.candidates
    where candidate_id = v_selection.candidate_id
    for update;

    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate not found in batch', 'details', jsonb_build_object('candidate_id', v_selection.candidate_id));
    end if;

    if v_cand.version_no <> v_selection.expected_version then
      return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Candidate version mismatch in batch', 'details', jsonb_build_object('candidate_id', v_selection.candidate_id, 'expected_version', v_selection.expected_version, 'current_version', v_cand.version_no));
    end if;
  end loop;

  -- 5. Mutate Candidates & recalculate
  for v_selection in
    select t.candidate_id
    from unnest(p_candidate_ids) with ordinality as t(candidate_id, ord)
    order by t.ord
  loop
    select * into v_cand
    from public.candidates
    where candidate_id = v_selection.candidate_id;

    v_previous_is_active := v_cand.is_active;

    if p_active = false then
      update public.candidates
      set
        is_active = false,
        inactive_at = clock_timestamp(),
        inactive_by = v_actor_app_user_id,
        updated_at = clock_timestamp()
      where candidate_id = v_selection.candidate_id
      returning * into v_cand;
    else
      update public.candidates
      set
        is_active = true,
        inactive_at = null,
        inactive_by = null,
        updated_at = clock_timestamp()
      where candidate_id = v_selection.candidate_id
      returning * into v_cand;

      -- Lock Submissions and Applications
      perform 1
      from public.submissions s
      where s.candidate_id = v_selection.candidate_id
      order by s.submission_id
      for update;

      perform 1
      from public.applications a
      join public.submissions s on s.submission_id = a.submission_id
      where s.candidate_id = v_selection.candidate_id
        and a.is_active = true
      order by a.submission_id, a.application_id
      for update;

      for v_sub in
        select s.submission_id, s.status_code
        from public.submissions s
        where s.candidate_id = v_selection.candidate_id
        order by s.submission_id
      loop
        select count(*) into v_sub_active_apps
        from public.applications
        where submission_id = v_sub.submission_id
          and is_active = true;

        if v_sub_active_apps = 0 then
          v_new_sub_status := 'READ';
        else
          select exists (
            select 1
            from public.applications a
            where a.submission_id = v_sub.submission_id
              and a.is_active = true
              and private.application_effective_outcome(a.application_id) = 'HIRED'
          ) into v_has_hired;

          if v_has_hired then
            v_new_sub_status := 'DONE';
          else
            select (
              v_sub_active_apps > 0
              and not exists (
                select 1
                from public.applications a
                where a.submission_id = v_sub.submission_id
                  and a.is_active = true
                  and private.application_effective_outcome(a.application_id) <> 'REJECTED'
              )
            ) into v_all_rejected;

            if v_all_rejected then
              v_new_sub_status := 'CLOSED';
            else
              v_new_sub_status := 'PROCESSED';
            end if;
          end if;
        end if;

        if v_new_sub_status is distinct from v_sub.status_code then
          update public.submissions
          set
            status_code = v_new_sub_status,
            updated_at = clock_timestamp()
          where submission_id = v_sub.submission_id;
        end if;
      end loop;
    end if;

    -- Per-item audit
    insert into public.security_audit_log (
      action_code,
      actor_app_user_id,
      entity_type,
      entity_id,
      metadata,
      source_code,
      result_code
    ) values (
      'BULK_SET_CANDIDATE_ACTIVE_ITEM',
      v_actor_app_user_id,
      'CANDIDATE',
      v_selection.candidate_id,
      jsonb_build_object(
        'candidate_id', v_selection.candidate_id,
        'is_active', p_active,
        'previous_is_active', v_previous_is_active,
        'version_no', v_cand.version_no
      ),
      'RPC',
      'SUCCESS'
    );

    v_result_items := v_result_items || jsonb_build_object(
      'candidate_id', v_cand.candidate_id,
      'is_active', v_cand.is_active,
      'version_no', v_cand.version_no,
      'inactive_at', v_cand.inactive_at,
      'inactive_by', v_cand.inactive_by
    );
  end loop;

  -- Batch audit event
  insert into public.security_audit_log (
    action_code,
    actor_app_user_id,
    entity_type,
    entity_id,
    metadata,
    source_code,
    result_code
  ) values (
    'BULK_SET_CANDIDATE_ACTIVE_BATCH',
    v_actor_app_user_id,
    'BATCH',
    p_idempotency_key,
    jsonb_build_object(
      'candidate_ids', to_jsonb(p_candidate_ids),
      'active', p_active,
      'count', v_count
    ),
    'RPC',
    'SUCCESS'
  );
  v_result := jsonb_build_object(
    'success', true,
    'active', p_active,
    'count', v_count,
    'items', v_result_items
  );

  perform private.record_idempotency(v_actor_scope, 'bulk_set_candidate_active', p_idempotency_key, v_fingerprint, v_result);
  return v_result;
end;
$$;

revoke all on function public.bulk_set_candidate_active(uuid[], boolean, bigint[], uuid) from public, anon;
grant execute on function public.bulk_set_candidate_active(uuid[], boolean, bigint[], uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. get_submission_detail Pure Read (Remove NEW->READ Mutation)
-- -----------------------------------------------------------------------------
create or replace function public.get_submission_detail(
  p_submission_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_view boolean;
  v_has_application_view boolean;
  v_sub record;
  v_source_name text := null;
  v_updated_by_name text := null;
  v_education jsonb;
  v_experiences jsonb;
  v_activities jsonb;
  v_documents jsonb;
  v_applications jsonb;
begin
  -- 1. Authorization check: submissions.view only
  v_has_view := private.has_permission('submissions.view') or private.is_root_admin();
  v_has_application_view := private.has_permission('applications.view')
    or private.has_permission('applications.manage')
    or private.is_root_admin();
  if not v_has_view then
    return jsonb_build_object(
      'success', false,
      'error_code', 'FORBIDDEN',
      'message', 'Permission submissions.view required to view submission details'
    );
  end if;

  -- 2. Query submission
  select * into v_sub
  from public.submissions
  where submission_id = p_submission_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error_code', 'NOT_FOUND',
      'message', 'Submission not found'
    );
  end if;

  -- PURE READ: NO conditional status mutation here. Status remains untouched.

  -- 3. Recruitment source name
  if v_sub.recruitment_source_id is not null then
    select name_vi into v_source_name
    from public.recruitment_sources
    where recruitment_source_id = v_sub.recruitment_source_id;
  end if;

  -- 4. Updated by name
  if v_sub.updated_by_internal_user_id is not null then
    select full_name into v_updated_by_name
    from public.app_users
    where app_user_id = v_sub.updated_by_internal_user_id;
  elsif v_sub.updated_by_candidate_id is not null then
    v_updated_by_name := 'Ứng viên';
  end if;

  -- 5. Education
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'education_id', e.education_id,
      'sort_order', e.sort_order,
      'period_text', e.period_text,
      'qualification_id', e.qualification_id,
      'qualification_name', q.name_vi,
      'major', e.major,
      'institution', e.institution
    ) order by e.sort_order asc
  ), '[]'::jsonb)
  into v_education
  from public.submission_education e
  left join public.qualification_levels q on q.qualification_id = e.qualification_id
  where e.submission_id = p_submission_id;

  -- 6. Working Experiences
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'experience_id', w.experience_id,
      'sort_order', w.sort_order,
      'start_date', w.start_date,
      'end_date', w.end_date,
      'is_current', w.is_current,
      'employer', w.employer,
      'job_title', w.job_title,
      'job_description', w.job_description
    ) order by w.sort_order asc
  ), '[]'::jsonb)
  into v_experiences
  from public.submission_work_experiences w
  where w.submission_id = p_submission_id;

  -- 7. Activities
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'activity_id', a.activity_id,
      'sort_order', a.sort_order,
      'period_text', a.period_text,
      'activity_name', a.activity_name,
      'role_name', a.role_name,
      'organizer', a.organizer,
      'description', a.description
    ) order by a.sort_order asc
  ), '[]'::jsonb)
  into v_activities
  from public.submission_activities a
  where a.submission_id = p_submission_id;

  -- 8. Documents
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'document_id', d.document_id,
      'logical_document_id', l.logical_document_id,
      'document_type_id', l.document_type_id,
      'document_type_code', dt.code,
      'document_type_name_vi', dt.name_vi,
      'original_filename', d.original_filename,
      'file_size_bytes', d.file_size_bytes,
      'mime_type', d.mime_type,
      'version_no', d.version_no,
      'is_current', d.is_current,
      'uploaded_at', d.uploaded_at,
      'storage_bucket', d.storage_bucket,
      'storage_path', d.storage_path
    ) order by dt.code asc, d.uploaded_at desc
  ), '[]'::jsonb)
  into v_documents
  from public.submission_document_logicals l
  join public.submission_documents d on d.logical_document_id = l.logical_document_id and d.is_current = true
  join public.document_types dt on dt.document_type_id = l.document_type_id
  where l.submission_id = p_submission_id;

  -- 9. Assigned Applications
  if v_has_application_view then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'application_id', app.application_id,
        'unit_id', app.unit_id,
        'unit_name_vi', u.name_vi,
        'department_team_id', app.department_team_id,
        'team_name_vi', t.name_vi,
        'position_id', app.position_id,
        'position_name_vi', pos.name_vi,
        'hr_owner_id', app.hr_owner_id,
        'hr_owner_name', hr.full_name,
        'is_active', app.is_active,
        'created_at', app.created_at
      ) order by app.created_at desc
    ), '[]'::jsonb)
    into v_applications
    from public.applications app
    left join public.organizational_units u on u.unit_id = app.unit_id
    left join public.department_teams t on t.department_team_id = app.department_team_id
    left join public.positions pos on pos.position_id = app.position_id
    left join public.app_users hr on hr.app_user_id = app.hr_owner_id
    where app.submission_id = p_submission_id;
  else
    v_applications := '[]'::jsonb;
  end if;
  return jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'submission_id', v_sub.submission_id,
      'candidate_id', v_sub.candidate_id,
      'status_code', v_sub.status_code,
      'full_name', v_sub.full_name,
      'email', v_sub.email_snapshot::text,
      'phone', v_sub.phone,
      'date_of_birth', v_sub.date_of_birth,
      'gender', v_sub.gender_code,
      'address', v_sub.current_address,
      'candidate_notes', v_sub.other_info,
      'other_info', v_sub.other_info,
      'hr_note', v_sub.hr_note,
      'submitted_at', v_sub.submitted_at,
      'created_at', v_sub.created_at,
      'updated_at', v_sub.updated_at,
      'version_no', v_sub.version_no,
      'recruitment_source_id', v_sub.recruitment_source_id,
      'recruitment_source_name', v_source_name,
      'updated_by_name', v_updated_by_name,
      'education', v_education,
      'experiences', v_experiences,
      'activities', v_activities,
      'documents', v_documents,
      'applications', v_applications
    )
  );
end;
$$;

revoke all on function public.get_submission_detail(uuid) from public, anon;
grant execute on function public.get_submission_detail(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 8. Candidate Submission Commands Overload Drop & Canonical Re-creation
-- Signature: (p_candidate_form_session_id, p_full_name, p_phone, p_date_of_birth,
--             p_gender, p_address, p_education, p_privacy_notice_version, p_idempotency_key)
-- -----------------------------------------------------------------------------

-- Drop obsolete overloads
drop function if exists public.submit_candidate_submission(uuid, text, text, date, text, text, text, jsonb, jsonb, jsonb, text, uuid);
drop function if exists public.submit_candidate_submission(uuid, text, text, date, text, text, jsonb, text, uuid);
drop function if exists public.update_candidate_submission(uuid, text, text, date, text, text, text, jsonb, jsonb, jsonb, text, uuid);
drop function if exists public.update_candidate_submission(uuid, text, text, date, text, text, jsonb, text, uuid);

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

  -- 12. Enqueue Confirmation Email in Outbox (TEST environment default)
  insert into public.email_outbox (
    submission_id,
    email_type,
    environment_code,
    recipients,
    subject,
    body_text,
    status_code,
    idempotency_key,
    actor_scope,
    created_by_candidate_id
  ) values (
    v_submission_id,
    'CANDIDATE_SUBMISSION_CONFIRMATION',
    'TEST',
    jsonb_build_array(v_cand.email::text),
    'Application Submission Confirmation',
    'Thank you for submitting your application to Eastern International University.',
    'QUEUED',
    p_idempotency_key,
    'CANDIDATE',
    v_cand.candidate_id
  )
  on conflict (actor_scope, email_type, idempotency_key) do nothing;

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

  -- 13. Enqueue HR Notification in Outbox (TEST environment default)
  insert into public.email_outbox (
    submission_id,
    email_type,
    environment_code,
    recipients,
    subject,
    body_text,
    status_code,
    idempotency_key,
    actor_scope,
    created_by_candidate_id
  ) values (
    v_sub.submission_id,
    'HR_SUBMISSION_UPDATED_NOTIFICATION',
    'TEST',
    jsonb_build_array('hr-notification@eiu.edu.vn'),
    'Candidate Submission Updated',
    'A candidate has updated their application submission.',
    'QUEUED',
    p_idempotency_key,
    'CANDIDATE',
    v_cand.candidate_id
  )
  on conflict (actor_scope, email_type, idempotency_key) do nothing;

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

-- -----------------------------------------------------------------------------
-- 9. HR Candidate-Data Correction Backend Command (Owner Decision G)
-- -----------------------------------------------------------------------------
create or replace function public.correct_submission_candidate_fields_by_hr(
  p_submission_id uuid,
  p_full_name text default null,
  p_phone text default null,
  p_date_of_birth date default null,
  p_gender text default null,
  p_current_address text default null,
  p_expected_version bigint default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid;
  v_actor_app_user_id uuid;
  v_sub record;
  v_changed_fields text[] := '{}';
  v_new_full_name text;
  v_new_phone text;
  v_new_dob date;
  v_new_gender text;
  v_new_address text;
  v_now timestamptz;
begin
  -- 1. Authorization: Root Admin OR submissions.edit
  v_auth_user_id := auth.uid();
  if v_auth_user_id is null then
    return jsonb_build_object('success', false, 'error_code', 'UNAUTHENTICATED', 'message', 'Authenticated internal user required');
  end if;

  select u.app_user_id into v_actor_app_user_id
  from public.app_users u
  where u.auth_user_id = v_auth_user_id
    and u.is_active = true;

  if v_actor_app_user_id is null
    or not (private.has_permission('submissions.edit') or private.is_root_admin()) then
    return jsonb_build_object('success', false, 'error_code', 'FORBIDDEN', 'message', 'Permission submissions.edit required');
  end if;
  if p_expected_version is null or p_expected_version <= 0 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Expected version is required and must be positive');
  end if;

  -- 2. Validate at least one field provided
  if p_full_name is null and p_phone is null and p_date_of_birth is null and p_gender is null and p_current_address is null then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'At least one candidate field must be provided for correction');
  end if;

  -- 3. Lock Submission row FOR UPDATE
  select * into v_sub
  from public.submissions
  where submission_id = p_submission_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Submission not found');
  end if;

  -- 4. Optimistic expected_version check is mandatory after the row lock.
  if v_sub.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Submission version mismatch; reload required');
  end if;

  -- 5. Field validation & preparation
  v_new_full_name := v_sub.full_name;
  if p_full_name is not null then
    if btrim(p_full_name) = '' or char_length(btrim(p_full_name)) > 200 then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Full name must not be empty and must not exceed 200 characters');
    end if;
    v_new_full_name := btrim(p_full_name);
    v_changed_fields := array_append(v_changed_fields, 'full_name');
  end if;

  v_new_phone := v_sub.phone;
  if p_phone is not null then
    if btrim(p_phone) = '' or char_length(btrim(p_phone)) > 32 then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Phone number must not be empty and must not exceed 32 characters');
    end if;
    v_new_phone := btrim(p_phone);
    v_changed_fields := array_append(v_changed_fields, 'phone');
  end if;

  v_new_dob := v_sub.date_of_birth;
  if p_date_of_birth is not null then
    if p_date_of_birth < '1900-01-01'::date or p_date_of_birth > current_date then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Date of birth must be between 1900-01-01 and today');
    end if;
    v_new_dob := p_date_of_birth;
    v_changed_fields := array_append(v_changed_fields, 'date_of_birth');
  end if;

  v_new_gender := v_sub.gender_code;
  if p_gender is not null then
    if upper(btrim(p_gender)) not in ('MALE', 'FEMALE') then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Gender must be MALE or FEMALE');
    end if;
    v_new_gender := upper(btrim(p_gender));
    v_changed_fields := array_append(v_changed_fields, 'gender_code');
  end if;

  v_new_address := v_sub.current_address;
  if p_current_address is not null then
    if btrim(p_current_address) = '' or char_length(btrim(p_current_address)) > 500 then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Address must not be empty and must not exceed 500 characters');
    end if;
    v_new_address := btrim(p_current_address);
    v_changed_fields := array_append(v_changed_fields, 'current_address');
  end if;

  v_now := clock_timestamp();

  -- 6. Apply correction
  update public.submissions
  set
    full_name = v_new_full_name,
    phone = v_new_phone,
    date_of_birth = v_new_dob,
    gender_code = v_new_gender,
    current_address = v_new_address,
    updated_at = v_now,
    updated_by_internal_user_id = v_actor_app_user_id,
    updated_by_candidate_id = null
  where submission_id = p_submission_id
  returning * into v_sub;

  -- 7. Refresh Candidate profile cache if latest
  perform private.refresh_candidate_current_profile(v_sub.candidate_id);

  -- 8. Same-transaction Security Audit (Changed field names ONLY, no full PII dump)
  insert into public.security_audit_log (
    action_code,
    actor_app_user_id,
    entity_type,
    entity_id,
    metadata,
    reason,
    source_code,
    result_code
  ) values (
    'CORRECT_SUBMISSION_CANDIDATE_FIELDS_BY_HR',
    v_actor_app_user_id,
    'SUBMISSION',
    p_submission_id,
    jsonb_build_object(
      'submission_id', p_submission_id,
      'candidate_id', v_sub.candidate_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'version_no', v_sub.version_no
    ),
    p_reason,
    'RPC',
    'SUCCESS'
  );
  return jsonb_build_object(
    'success', true,
    'submission_id', v_sub.submission_id,
    'version_no', v_sub.version_no,
    'changed_fields', v_changed_fields
  );
end;
$$;

revoke all on function public.correct_submission_candidate_fields_by_hr(uuid, text, text, date, text, text, bigint, text) from public, anon;
grant execute on function public.correct_submission_candidate_fields_by_hr(uuid, text, text, date, text, text, bigint, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 10. Update protect_candidate_verified_email() for Trusted Recovery Context
-- -----------------------------------------------------------------------------
create or replace function private.protect_candidate_verified_email()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.email is distinct from old.email then
    if current_setting('recruitment.candidate_email_recovery_active', true) = 'on' then
      return new;
    end if;
    raise exception 'CANDIDATE_VERIFIED_EMAIL_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists candidate_verified_email_immutable_guard on public.candidates;
create trigger candidate_verified_email_immutable_guard
  before update of email on public.candidates
  for each row execute function private.protect_candidate_verified_email();

-- -----------------------------------------------------------------------------
-- 11. Application Inbox Search & Pagination Alignment
-- -----------------------------------------------------------------------------
drop function if exists public.list_application_inbox(text, text, date, date, text, text, text, integer, integer);

create or replace function public.list_application_inbox(
  p_query text default '',
  p_status text default 'ALL',
  p_date_from date default null,
  p_date_to date default null,
  p_candidate_activity text default 'ALL',
  p_new_read text default 'ALL',
  p_application text default 'ALL',
  p_page integer default 1,
  p_page_size integer default 25
)
returns table (
  candidate_id uuid,
  email text,
  is_candidate_active boolean,
  candidate_version_no bigint,
  latest_submission_id uuid,
  latest_submission_version_no bigint,
  submission_id uuid,
  submission_version_no bigint,
  status_code text,
  full_name text,
  date_of_birth date,
  gender_code text,
  phone text,
  hr_note text,
  submitted_at timestamptz,
  has_application boolean,
  total_count bigint
)
language sql
security invoker
set search_path = ''
stable
as $$
  with ranked as (
    select
      s.submission_id,
      s.candidate_id,
      s.status_code,
      s.full_name,
      s.date_of_birth,
      s.gender_code,
      s.phone,
      s.hr_note,
      s.submitted_at,
      s.version_no as submission_version_no,
      c.email::text as email,
      c.is_active as is_candidate_active,
      c.version_no as candidate_version_no,
      exists (select 1 from public.applications a where a.submission_id = s.submission_id and a.is_active = true) as has_application,
      row_number() over (
        partition by s.candidate_id
        order by s.submitted_at desc, s.submission_id desc
      ) as submission_rank
    from public.submissions s
    join public.candidates c on c.candidate_id = s.candidate_id
    where private.has_permission('submissions.view') or private.is_root_admin()
  ), latest as (
    select * from ranked where submission_rank = 1
  ), filtered as (
    select * from latest
    where (
      nullif(btrim(p_query), '') is null
      or (
        length(btrim(p_query)) >= 2
        and full_name ilike '%' || btrim(p_query) || '%'
      )
      or (
        lower(email) like lower(btrim(p_query)) || '%'
      )
      or (
        length(regexp_replace(btrim(p_query), '[^0-9]', '', 'g')) > 0
        and regexp_replace(phone, '[^0-9]', '', 'g') like regexp_replace(btrim(p_query), '[^0-9]', '', 'g') || '%'
      )
    )
    and (p_status = 'ALL' or status_code = p_status)
    and (
      p_date_from is null
      or submitted_at >= p_date_from::timestamp at time zone 'Asia/Ho_Chi_Minh'
    )
    and (
      p_date_to is null
      or submitted_at < (p_date_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh'
    )
    and (p_candidate_activity = 'ALL' or (p_candidate_activity = 'ACTIVE') = is_candidate_active)
    and (p_new_read = 'ALL' or status_code = p_new_read)
    and (p_application = 'ALL' or (p_application = 'HAS_APPLICATION') = has_application)
  ), counted as (
    select *, count(*) over () as total_count from filtered
  ), paged as (
    select * from counted
    order by submitted_at desc, submission_id desc, candidate_id asc
    offset (
      (least(
        greatest(p_page, 1),
        greatest(ceil((select count(*) from filtered)::numeric / case when p_page_size in (25, 50, 100) then p_page_size else 25 end), 1)
      ) - 1) * case when p_page_size in (25, 50, 100) then p_page_size else 25 end
    )
    limit case when p_page_size in (25, 50, 100) then p_page_size else 25 end
  )
  select
    p.candidate_id,
    p.email,
    p.is_candidate_active,
    p.candidate_version_no,
    p.submission_id as latest_submission_id,
    p.submission_version_no as latest_submission_version_no,
    s.submission_id,
    s.version_no as submission_version_no,
    s.status_code,
    s.full_name,
    s.date_of_birth,
    s.gender_code,
    s.phone,
    s.hr_note,
    s.submitted_at,
    exists (select 1 from public.applications a where a.submission_id = s.submission_id and a.is_active = true) as has_application,
    p.total_count
  from paged p
  join public.submissions s on s.candidate_id = p.candidate_id
  order by p.submitted_at desc, p.submission_id desc, p.candidate_id asc,
    s.submitted_at desc, s.submission_id desc;
$$;

revoke all on function public.list_application_inbox(text, text, date, date, text, text, text, integer, integer) from public, anon;
grant execute on function public.list_application_inbox(text, text, date, date, text, text, text, integer, integer) to authenticated;
