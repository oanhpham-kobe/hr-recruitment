-- Migration: 20260905150000_candidate_lifecycle_and_inbox_bulk_tokens.sql
-- TASK-S03-006: Candidate account lifecycle RPCs and optimistic version tokens in Application Inbox read model

-- -----------------------------------------------------------------------------
-- 1. Redefine list_application_inbox with candidate and latest-submission version tokens
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
  p_page_size integer default 10
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
      or full_name ilike '%' || btrim(p_query) || '%'
      or email ilike '%' || btrim(p_query) || '%'
      or phone ilike '%' || btrim(p_query) || '%'
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
        greatest(ceil((select count(*) from filtered)::numeric / least(greatest(p_page_size, 1), 100)), 1)
      ) - 1) * least(greatest(p_page_size, 1), 100)
    )
    limit least(greatest(p_page_size, 1), 100)
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

-- -----------------------------------------------------------------------------
-- 2. Single Candidate Lifecycle RPC: set_candidate_active
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

    perform pg_advisory_xact_lock(hashtextextended(v_actor_scope || ':set_candidate_active:' || p_idempotency_key::text, 0));

    select r.result_payload into v_existing_result
    from public.idempotency_records r
    where r.actor_scope = v_actor_scope
      and r.command_type = 'set_candidate_active'
      and r.idempotency_key = p_idempotency_key;

    if found then
      if v_existing_result ->> 'request_fingerprint' <> v_fingerprint then
        return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key has already been used for a different request');
      end if;
      return v_existing_result -> 'result';
    end if;
  end if;

  -- 4. Cross-command Advisory & Row Lock (Candidate -> Submissions -> Applications)
  perform pg_advisory_xact_lock(hashtextextended('bulk-candidate:' || p_candidate_id::text, 0));

  select * into v_cand
  from public.candidates
  where candidate_id = p_candidate_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'Candidate not found');
  end if;

  if v_cand.version_no <> p_expected_version then
    return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'Candidate version changed');
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

    -- Re-evaluate all Submissions for candidate
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
        v_new_sub_status := 'READ';
      else
        select exists (
          select 1
          from public.interviews i
          join public.applications a on a.application_id = i.application_id
          where a.submission_id = v_sub.submission_id
            and a.is_active = true
            and i.is_active = true
            and i.report_status_code = 'HIRED'
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
                and not exists (
                  select 1
                  from public.interviews i
                  where i.application_id = a.application_id
                    and i.is_active = true
                    and i.report_status_code = 'REJECTED'
                )
            )
          ) into v_all_rejected;

          if v_all_rejected then
            v_new_sub_status := 'CLOSED';
          else
            v_new_sub_status := 'PROCESSED';
          end if;
        end if;
      end if;

      if v_new_sub_status <> v_sub.status_code then
        update public.submissions
        set
          status_code = v_new_sub_status,
          updated_at = clock_timestamp()
        where submission_id = v_sub.submission_id;

        insert into public.activity_log (
          entity_type, entity_id, action_code, actor_app_user_id, request_id, source_code, old_values, new_values
        ) values (
          'SUBMISSION',
          v_sub.submission_id,
          'REACTIVATION_STATUS_RECALCULATE',
          v_actor_app_user_id,
          p_idempotency_key,
          'RPC',
          jsonb_build_object('status_code', v_sub.status_code),
          jsonb_build_object('status_code', v_new_sub_status)
        );
      end if;
    end loop;
  end if;

  -- 6. Mandatory Audit Logging
  insert into public.security_audit_log (
    actor_auth_user_id,
    actor_app_user_id,
    action_code,
    entity_type,
    entity_id,
    request_id,
    source_code,
    result_code,
    metadata
  ) values (
    v_auth_user_id,
    v_actor_app_user_id,
    case when p_active then 'CANDIDATE_ACTIVATE' else 'CANDIDATE_INACTIVATE' end,
    'CANDIDATE',
    p_candidate_id,
    p_idempotency_key,
    'RPC',
    'SUCCESS',
    jsonb_build_object(
      'candidate_id', p_candidate_id,
      'is_active', p_active,
      'previous_is_active', v_previous_is_active,
      'version_no', v_cand.version_no,
      'inactive_at', v_cand.inactive_at,
      'inactive_by', v_cand.inactive_by
    )
  );

  insert into public.activity_log (
    entity_type,
    entity_id,
    action_code,
    actor_app_user_id,
    request_id,
    source_code,
    old_values,
    new_values
  ) values (
    'CANDIDATE',
    p_candidate_id,
    case when p_active then 'CANDIDATE_ACTIVATE' else 'CANDIDATE_INACTIVATE' end,
    v_actor_app_user_id,
    p_idempotency_key,
    'RPC',
    jsonb_build_object('is_active', v_previous_is_active, 'version_no', p_expected_version),
    jsonb_build_object('is_active', p_active, 'version_no', v_cand.version_no)
  );

  -- 7. Result & Idempotency Storage
  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'candidate_id', v_cand.candidate_id,
      'is_active', v_cand.is_active,
      'inactive_at', v_cand.inactive_at,
      'inactive_by', v_cand.inactive_by,
      'version_no', v_cand.version_no
    )
  );

  if p_idempotency_key is not null then
    insert into public.idempotency_records (
      actor_scope, command_type, idempotency_key, result_entity_type, result_entity_id, result_payload
    ) values (
      v_actor_scope,
      'set_candidate_active',
      p_idempotency_key,
      'CANDIDATE',
      p_candidate_id,
      jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.set_candidate_active(uuid, boolean, bigint, uuid) from public, anon;
grant execute on function public.set_candidate_active(uuid, boolean, bigint, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Bulk Candidate Lifecycle RPC: bulk_set_candidate_active
-- -----------------------------------------------------------------------------
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

  perform pg_advisory_xact_lock(hashtextextended(v_actor_scope || ':bulk_set_candidate_active:' || p_idempotency_key::text, 0));

  select r.result_payload into v_existing_result
  from public.idempotency_records r
  where r.actor_scope = v_actor_scope
    and r.command_type = 'bulk_set_candidate_active'
    and r.idempotency_key = p_idempotency_key;

  if found then
    if v_existing_result ->> 'request_fingerprint' <> v_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR', 'message', 'Idempotency key has already been used for a different request');
    end if;
    return v_existing_result -> 'result';
  end if;

  -- 4. Existence and Optimistic Concurrency Pre-check (ALL_OR_NOTHING)
  select count(*) into v_count
  from public.candidates c
  where c.candidate_id = any(p_candidate_ids);

  if v_count <> cardinality(p_candidate_ids) then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND', 'message', 'One or more Candidates were not found');
  end if;

  -- Cross-command serialization starts before Candidate row locks.
  perform pg_advisory_xact_lock(hashtextextended('bulk-candidate:' || c.candidate_id::text, 0))
  from (
    select distinct candidate_id
    from unnest(p_candidate_ids) as selected(candidate_id)
    order by candidate_id
  ) c;

  -- Lock Candidate rows in deterministic order
  perform 1
  from public.candidates c
  where c.candidate_id = any(p_candidate_ids)
  order by c.candidate_id
  for update;

  -- Check expected versions for ALL selected candidates
  for v_selection in
    select s.candidate_id, s.expected_version, s.ordinality
    from unnest(p_candidate_ids, p_expected_versions)
      with ordinality as s(candidate_id, expected_version, ordinality)
    order by s.ordinality
  loop
    select * into v_cand
    from public.candidates
    where candidate_id = v_selection.candidate_id;

    if v_cand.version_no <> v_selection.expected_version then
      return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION', 'message', 'One or more Candidate versions have changed');
    end if;
  end loop;

  -- 5. Lock Submissions and Applications in hierarchy if reactivating
  if p_active = true then
    perform 1
    from public.submissions s
    where s.candidate_id = any(p_candidate_ids)
    order by s.submission_id
    for update;

    perform 1
    from public.applications a
    join public.submissions s on s.submission_id = a.submission_id
    where s.candidate_id = any(p_candidate_ids)
      and a.is_active = true
    order by a.submission_id, a.application_id
    for update;
  end if;

  -- 6. Apply Mutations & Record Per-Candidate Audit
  for v_selection in
    select s.candidate_id, s.expected_version, s.ordinality
    from unnest(p_candidate_ids, p_expected_versions)
      with ordinality as s(candidate_id, expected_version, ordinality)
    order by s.ordinality
  loop
    select c.is_active into v_previous_is_active
    from public.candidates c
    where c.candidate_id = v_selection.candidate_id;

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

      -- Per-submission reactivation recalculation
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
            from public.interviews i
            join public.applications a on a.application_id = i.application_id
            where a.submission_id = v_sub.submission_id
              and a.is_active = true
              and i.is_active = true
              and i.report_status_code = 'HIRED'
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
                  and not exists (
                    select 1
                    from public.interviews i
                    where i.application_id = a.application_id
                      and i.is_active = true
                      and i.report_status_code = 'REJECTED'
                  )
              )
            ) into v_all_rejected;

            if v_all_rejected then
              v_new_sub_status := 'CLOSED';
            else
              v_new_sub_status := 'PROCESSED';
            end if;
          end if;
        end if;

        if v_new_sub_status <> v_sub.status_code then
          update public.submissions
          set
            status_code = v_new_sub_status,
            updated_at = clock_timestamp()
          where submission_id = v_sub.submission_id;

          insert into public.activity_log (
            entity_type, entity_id, action_code, actor_app_user_id, request_id, source_code, old_values, new_values
          ) values (
            'SUBMISSION',
            v_sub.submission_id,
            'REACTIVATION_STATUS_RECALCULATE',
            v_actor_app_user_id,
            p_idempotency_key,
            'RPC',
            jsonb_build_object('status_code', v_sub.status_code),
            jsonb_build_object('status_code', v_new_sub_status)
          );
        end if;
      end loop;
    end if;

    -- Per-Candidate Security Audit
    insert into public.security_audit_log (
      actor_auth_user_id,
      actor_app_user_id,
      action_code,
      entity_type,
      entity_id,
      request_id,
      source_code,
      result_code,
      metadata
    ) values (
      v_auth_user_id,
      v_actor_app_user_id,
      case when p_active then 'CANDIDATE_ACTIVATE' else 'CANDIDATE_INACTIVATE' end,
      'CANDIDATE',
      v_selection.candidate_id,
      p_idempotency_key,
      'RPC',
      'SUCCESS',
      jsonb_build_object(
        'candidate_id', v_selection.candidate_id,
        'is_active', p_active,
        'previous_is_active', v_previous_is_active,
        'version_no', v_cand.version_no,
        'inactive_at', v_cand.inactive_at,
        'inactive_by', v_cand.inactive_by
      )
    );

    insert into public.activity_log (
      entity_type,
      entity_id,
      action_code,
      actor_app_user_id,
      request_id,
      source_code,
      old_values,
      new_values
    ) values (
      'CANDIDATE',
      v_selection.candidate_id,
      case when p_active then 'CANDIDATE_ACTIVATE' else 'CANDIDATE_INACTIVATE' end,
      v_actor_app_user_id,
      p_idempotency_key,
      'RPC',
      jsonb_build_object('is_active', v_previous_is_active, 'version_no', v_selection.expected_version),
      jsonb_build_object('is_active', p_active, 'version_no', v_cand.version_no)
    );

    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'candidate_id', v_cand.candidate_id,
      'is_active', v_cand.is_active,
      'inactive_at', v_cand.inactive_at,
      'inactive_by', v_cand.inactive_by,
      'version_no', v_cand.version_no
    ));
  end loop;

  -- 7. Exactly One Batch Audit Event (AC-BULK-CAND-LIFE-02)
  insert into public.security_audit_log (
    actor_auth_user_id,
    actor_app_user_id,
    action_code,
    entity_type,
    entity_id,
    request_id,
    source_code,
    result_code,
    metadata
  ) values (
    v_auth_user_id,
    v_actor_app_user_id,
    'BULK_SET_CANDIDATE_ACTIVE',
    'BATCH',
    p_idempotency_key,
    p_idempotency_key,
    'RPC',
    'SUCCESS',
    jsonb_build_object(
      'request_fingerprint', v_fingerprint,
      'selected_candidate_ids', to_jsonb(p_candidate_ids),
      'active', p_active,
      'count', cardinality(p_candidate_ids)
    )
  );

  -- 8. Final Result & Idempotency Cache
  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'items', v_result_items,
      'count', cardinality(p_candidate_ids),
      'idempotency_key', p_idempotency_key
    )
  );

  insert into public.idempotency_records (
    actor_scope, command_type, idempotency_key, result_entity_type, result_entity_id, result_payload
  ) values (
    v_actor_scope,
    'bulk_set_candidate_active',
    p_idempotency_key,
    'BATCH',
    p_idempotency_key,
    jsonb_build_object('request_fingerprint', v_fingerprint, 'result', v_result)
  );

  return v_result;
end;
$$;

revoke all on function public.bulk_set_candidate_active(uuid[], boolean, bigint[], uuid) from public, anon;
grant execute on function public.bulk_set_candidate_active(uuid[], boolean, bigint[], uuid) to authenticated;
