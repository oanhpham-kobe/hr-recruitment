-- TASK-S07-003: trusted storage cleanup eligibility, provenance and fenced worker contracts.
-- Protocol only: no Storage/network calls and no physical deletion.

create table if not exists private.storage_cleanup_provenance (
  bucket_name text not null,
  object_path text not null,
  upload_reservation_id uuid,
  source_type text not null check (source_type in ('CANDIDATE_FORM','INTERVIEW_UPLOAD')),
  source_parent_id uuid,
  reservation_expires_at timestamptz,
  signed_upload_expires_at timestamptz,
  captured_at timestamptz not null default clock_timestamp(),
  detached_at timestamptz,
  tombstoned_at timestamptz,
  tombstone_cleanup_id uuid,
  primary key (bucket_name, object_path)
);

alter table private.storage_cleanup_provenance
  add column if not exists tombstoned_at timestamptz,
  add column if not exists tombstone_cleanup_id uuid;

alter table public.storage_cleanup_queue
  add column if not exists worker_id text,
  add column if not exists attempt_id uuid,
  add column if not exists fencing_token uuid,
  add column if not exists eligibility_code text,
  add column if not exists provenance_captured_at timestamptz,
  add column if not exists authorized_at timestamptz;

create index if not exists storage_cleanup_queue_fenced_claim_idx
  on public.storage_cleanup_queue(status_code, not_before, leased_until, attempts, storage_cleanup_id)
  where status_code in ('PENDING', 'PROCESSING');

create or replace function private.storage_cleanup_identity_lock(
  p_bucket text,
  p_path text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_bucket || chr(31) || p_path, 0)
  );
end;
$$;

create or replace function private.capture_storage_cleanup_provenance(
  p_bucket text,
  p_path text,
  p_reservation uuid,
  p_source_type text,
  p_parent uuid,
  p_expires timestamptz,
  p_signed_expires timestamptz,
  p_detached boolean default false
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_bucket not in ('candidate-quarantine', 'interview-quarantine')
    or (p_bucket = 'candidate-quarantine' and p_path !~ '^temp/[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]+$')
    or (p_bucket = 'interview-quarantine' and p_path !~ '^temp/interview/[0-9a-f-]{36}/[0-9a-f-]{36}$') then
    return;
  end if;

  insert into private.storage_cleanup_provenance (
    bucket_name, object_path, upload_reservation_id, source_type, source_parent_id,
    reservation_expires_at, signed_upload_expires_at, detached_at
  ) values (
    p_bucket, p_path, p_reservation, p_source_type, p_parent,
    p_expires, p_signed_expires, case when p_detached then clock_timestamp() end
  )
  on conflict (bucket_name, object_path) do update set
    upload_reservation_id = coalesce(private.storage_cleanup_provenance.upload_reservation_id, excluded.upload_reservation_id),
    source_parent_id = coalesce(private.storage_cleanup_provenance.source_parent_id, excluded.source_parent_id),
    reservation_expires_at = case
      when private.storage_cleanup_provenance.reservation_expires_at is null then excluded.reservation_expires_at
      when excluded.reservation_expires_at is null then private.storage_cleanup_provenance.reservation_expires_at
      else greatest(private.storage_cleanup_provenance.reservation_expires_at, excluded.reservation_expires_at)
    end,
    signed_upload_expires_at = case
      when private.storage_cleanup_provenance.signed_upload_expires_at is null then excluded.signed_upload_expires_at
      when excluded.signed_upload_expires_at is null then private.storage_cleanup_provenance.signed_upload_expires_at
      else greatest(private.storage_cleanup_provenance.signed_upload_expires_at, excluded.signed_upload_expires_at)
    end,
    detached_at = coalesce(private.storage_cleanup_provenance.detached_at, excluded.detached_at);
end;
$$;

create or replace function private.capture_upload_reservation_provenance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.capture_storage_cleanup_provenance(
    new.temp_bucket,
    new.temp_path,
    new.upload_reservation_id,
    case when new.candidate_form_session_id is not null then 'CANDIDATE_FORM' else 'INTERVIEW_UPLOAD' end,
    coalesce(new.candidate_form_session_id, new.interview_id),
    new.expires_at,
    new.signed_upload_expires_at,
    false
  );
  return new;
end;
$$;

drop trigger if exists upload_reservation_cleanup_provenance on public.upload_reservations;
create trigger upload_reservation_cleanup_provenance
after insert or update of expires_at, signed_upload_expires_at on public.upload_reservations
for each row execute function private.capture_upload_reservation_provenance();

create or replace function private.capture_deleted_upload_provenance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.storage_cleanup_queue q
    where q.bucket_name = old.temp_bucket
      and q.object_path = old.temp_path
  ) then
    perform private.capture_storage_cleanup_provenance(
      old.temp_bucket,
      old.temp_path,
      old.upload_reservation_id,
      case when old.candidate_form_session_id is not null then 'CANDIDATE_FORM' else 'INTERVIEW_UPLOAD' end,
      coalesce(old.candidate_form_session_id, old.interview_id),
      old.expires_at,
      old.signed_upload_expires_at,
      true
    );
  end if;
  return old;
end;
$$;

drop trigger if exists upload_reservation_deleted_cleanup_provenance on public.upload_reservations;
create trigger upload_reservation_deleted_cleanup_provenance
before delete on public.upload_reservations
for each row execute function private.capture_deleted_upload_provenance();

-- Forward-migration provenance backfill for authoritative pre-existing upload reservations.
-- Derives strictly from existing upload_reservations rows; applies the same managed bucket/path validation;
-- preserves exact reservation identity, source type, parent, and expiries with idempotent conflict handling.
insert into private.storage_cleanup_provenance (
  bucket_name,
  object_path,
  upload_reservation_id,
  source_type,
  source_parent_id,
  reservation_expires_at,
  signed_upload_expires_at
)
select
  r.temp_bucket,
  r.temp_path,
  r.upload_reservation_id,
  case when r.candidate_form_session_id is not null then 'CANDIDATE_FORM' else 'INTERVIEW_UPLOAD' end,
  coalesce(r.candidate_form_session_id, r.interview_id),
  r.expires_at,
  r.signed_upload_expires_at
from public.upload_reservations r
where (
  (r.temp_bucket = 'candidate-quarantine' and r.temp_path ~ '^temp/[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]+$')
  or
  (r.temp_bucket = 'interview-quarantine' and r.temp_path ~ '^temp/interview/[0-9a-f-]{36}/[0-9a-f-]{36}$')
)
and (r.candidate_form_session_id is not null or r.interview_id is not null)
on conflict (bucket_name, object_path) do update set
  upload_reservation_id = coalesce(private.storage_cleanup_provenance.upload_reservation_id, excluded.upload_reservation_id),
  source_parent_id = coalesce(private.storage_cleanup_provenance.source_parent_id, excluded.source_parent_id),
  reservation_expires_at = case
    when private.storage_cleanup_provenance.reservation_expires_at is null then excluded.reservation_expires_at
    when excluded.reservation_expires_at is null then private.storage_cleanup_provenance.reservation_expires_at
    else greatest(private.storage_cleanup_provenance.reservation_expires_at, excluded.reservation_expires_at)
  end,
  signed_upload_expires_at = case
    when private.storage_cleanup_provenance.signed_upload_expires_at is null then excluded.signed_upload_expires_at
    when excluded.signed_upload_expires_at is null then private.storage_cleanup_provenance.signed_upload_expires_at
    else greatest(private.storage_cleanup_provenance.signed_upload_expires_at, excluded.signed_upload_expires_at)
  end,
  detached_at = coalesce(private.storage_cleanup_provenance.detached_at, excluded.detached_at);

create or replace function private.reject_cleanup_reservation_resurrection()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.storage_cleanup_identity_lock(new.temp_bucket, new.temp_path);
  if exists (
    select 1
    from private.storage_cleanup_provenance p
    where p.bucket_name = new.temp_bucket
      and p.object_path = new.temp_path
  ) then
    raise exception using errcode = '23514', message = 'STORAGE_CLEANUP_IDENTITY_REUSED';
  end if;
  return new;
end;
$$;

drop trigger if exists upload_reservation_cleanup_identity_guard on public.upload_reservations;
create trigger upload_reservation_cleanup_identity_guard
before insert on public.upload_reservations
for each row execute function private.reject_cleanup_reservation_resurrection();

create or replace function private.reject_cleanup_document_resurrection()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.storage_cleanup_identity_lock(new.storage_bucket, new.storage_path);
  if exists (
    select 1
    from private.storage_cleanup_provenance p
    where p.bucket_name = new.storage_bucket
      and p.object_path = new.storage_path
      and p.tombstoned_at is not null
  ) then
    raise exception using errcode = '23514', message = 'STORAGE_CLEANUP_IDENTITY_TOMBSTONED';
  end if;
  return new;
end;
$$;

drop trigger if exists submission_document_cleanup_identity_guard on public.submission_documents;
create trigger submission_document_cleanup_identity_guard
before insert or update of storage_bucket, storage_path on public.submission_documents
for each row execute function private.reject_cleanup_document_resurrection();

drop trigger if exists interview_document_cleanup_identity_guard on public.interview_documents;
create trigger interview_document_cleanup_identity_guard
before insert or update of storage_bucket, storage_path on public.interview_documents
for each row execute function private.reject_cleanup_document_resurrection();

create or replace function private.storage_cleanup_audit(
  p_action text,
  p_queue uuid,
  p_result text,
  p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.security_audit_log(
    action_code, entity_type, entity_id, source_code, result_code, metadata
  ) values (
    p_action,
    'STORAGE_CLEANUP',
    p_queue,
    'WORKER',
    p_result,
    coalesce(p_metadata, '{}'::jsonb)
  );
end;
$$;

create or replace function private.storage_cleanup_eligibility(
  p_q public.storage_cleanup_queue,
  p_now timestamptz
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p private.storage_cleanup_provenance%rowtype;
  v_r public.upload_reservations%rowtype;
  v_has_reservation boolean;
  v_bound timestamptz;
begin
  select * into v_p
  from private.storage_cleanup_provenance
  where bucket_name = p_q.bucket_name
    and object_path = p_q.object_path;

  if not found
    or p_q.bucket_name not in ('candidate-quarantine', 'interview-quarantine')
    or (p_q.bucket_name = 'candidate-quarantine' and p_q.object_path !~ '^temp/[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]+$')
    or (p_q.bucket_name = 'interview-quarantine' and p_q.object_path !~ '^temp/interview/[0-9a-f-]{36}/[0-9a-f-]{36}$')
    or p_q.source_type is distinct from v_p.source_type
    or p_q.source_parent_id is distinct from v_p.source_parent_id
    or p_q.source_upload_reservation_id is distinct from v_p.upload_reservation_id then
    return 'UNKNOWN_PROVENANCE';
  end if;

  select * into v_r
  from public.upload_reservations r
  where r.temp_bucket = p_q.bucket_name
    and r.temp_path = p_q.object_path;
  v_has_reservation := found;

  v_bound := greatest(
    coalesce(v_p.reservation_expires_at, '-infinity'::timestamptz),
    coalesce(v_p.signed_upload_expires_at, '-infinity'::timestamptz),
    coalesce(v_r.expires_at, '-infinity'::timestamptz),
    coalesce(v_r.signed_upload_expires_at, '-infinity'::timestamptz),
    p_q.not_before
  );
  if v_bound > p_now then
    return 'SIGNED_WINDOW';
  end if;

  if v_has_reservation and v_r.status_code not in ('EXPIRED', 'REJECTED', 'CANCELLED') then
    return 'LIVE_RESERVATION';
  end if;

  if exists (
    select 1 from public.submission_documents d
    where d.storage_bucket = p_q.bucket_name
      and d.storage_path = p_q.object_path
  ) or exists (
    select 1 from public.interview_documents d
    where d.storage_bucket = p_q.bucket_name
      and d.storage_path = p_q.object_path
  ) then
    return 'RETAINED_REFERENCE';
  end if;

  if p_q.reason_code = 'DOCUMENT_REPLACED' then
    return 'RETAINED_REPLACEMENT';
  end if;

  if not v_has_reservation and v_p.detached_at is null then
    return 'UNKNOWN_PROVENANCE';
  end if;

  if v_p.tombstoned_at is not null and v_p.tombstone_cleanup_id is distinct from p_q.storage_cleanup_id then
    return 'TOMBSTONED';
  end if;

  return 'ELIGIBLE';
end;
$$;

create or replace function private.storage_cleanup_defer_until(
  p_q public.storage_cleanup_queue,
  p_now timestamptz
) returns timestamptz
language sql
security definer
set search_path = ''
as $$
  select greatest(
    p_q.not_before,
    coalesce(p.reservation_expires_at, '-infinity'::timestamptz),
    coalesce(p.signed_upload_expires_at, '-infinity'::timestamptz),
    coalesce(r.expires_at, '-infinity'::timestamptz),
    coalesce(r.signed_upload_expires_at, '-infinity'::timestamptz),
    p_now + interval '5 minutes'
  )
  from private.storage_cleanup_provenance p
  left join public.upload_reservations r
    on r.temp_bucket = p.bucket_name
   and r.temp_path = p.object_path
  where p.bucket_name = p_q.bucket_name
    and p.object_path = p_q.object_path
$$;

create or replace function public.discover_expired_storage_cleanup(
  p_limit integer default 50
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidate_session_id uuid;
  v_interview_id uuid;
  v_res public.upload_reservations%rowtype;
  v_session public.candidate_form_sessions%rowtype;
  v_n integer := 0;
  v_now timestamptz;
begin
  if p_limit is null or p_limit not between 1 and 100 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  for v_candidate_session_id in
    select distinct r.candidate_form_session_id
    from public.upload_reservations r
    where r.candidate_form_session_id is not null
      and r.status_code in ('RESERVED', 'UPLOADED', 'VALIDATED')
      and r.expires_at <= clock_timestamp()
    order by r.candidate_form_session_id
    limit p_limit
  loop
    exit when v_n >= p_limit;
    select * into v_session
    from public.candidate_form_sessions
    where candidate_form_session_id = v_candidate_session_id
    for update;
    if not found then
      continue;
    end if;

    for v_res in
      select *
      from public.upload_reservations
      where candidate_form_session_id = v_candidate_session_id
        and status_code in ('RESERVED', 'UPLOADED', 'VALIDATED')
        and expires_at <= clock_timestamp()
      order by upload_reservation_id
      for update skip locked
    loop
      exit when v_n >= p_limit;
      v_now := clock_timestamp();
      if v_session.status_code = 'OPEN' and v_session.expires_at <= v_now then
        update public.candidate_form_sessions
        set status_code = 'EXPIRED', updated_at = v_now
        where candidate_form_session_id = v_session.candidate_form_session_id
          and status_code = 'OPEN'
          and expires_at <= v_now;
      end if;

      perform private.capture_storage_cleanup_provenance(
        v_res.temp_bucket, v_res.temp_path, v_res.upload_reservation_id,
        'CANDIDATE_FORM', v_res.candidate_form_session_id,
        v_res.expires_at, v_res.signed_upload_expires_at, false
      );
      insert into public.storage_cleanup_queue(
        source_type, source_parent_id, source_upload_reservation_id,
        bucket_name, object_path, reason_code, status_code, not_before,
        provenance_captured_at
      ) values (
        'CANDIDATE_FORM', v_res.candidate_form_session_id, v_res.upload_reservation_id,
        v_res.temp_bucket, v_res.temp_path, 'RESERVATION_EXPIRED', 'PENDING',
        greatest(v_res.expires_at, coalesce(v_res.signed_upload_expires_at, v_res.expires_at)),
        v_now
      )
      on conflict (bucket_name, object_path) do update set
        not_before = greatest(public.storage_cleanup_queue.not_before, excluded.not_before),
        provenance_captured_at = coalesce(
          public.storage_cleanup_queue.provenance_captured_at,
          excluded.provenance_captured_at
        );
      update public.upload_reservations
      set status_code = 'EXPIRED'
      where upload_reservation_id = v_res.upload_reservation_id
        and status_code in ('RESERVED', 'UPLOADED', 'VALIDATED');
      v_n := v_n + 1;
    end loop;
  end loop;

  for v_interview_id in
    select distinct r.interview_id
    from public.upload_reservations r
    where r.interview_id is not null
      and r.status_code in ('RESERVED', 'UPLOADED', 'VALIDATED')
      and r.expires_at <= clock_timestamp()
    order by r.interview_id
    limit p_limit
  loop
    exit when v_n >= p_limit;
    perform 1
    from public.interviews
    where interview_id = v_interview_id
    for update;
    if not found then
      continue;
    end if;

    for v_res in
      select *
      from public.upload_reservations
      where interview_id = v_interview_id
        and status_code in ('RESERVED', 'UPLOADED', 'VALIDATED')
        and expires_at <= clock_timestamp()
      order by upload_reservation_id
      for update skip locked
    loop
      exit when v_n >= p_limit;
      v_now := clock_timestamp();
      perform private.capture_storage_cleanup_provenance(
        v_res.temp_bucket, v_res.temp_path, v_res.upload_reservation_id,
        'INTERVIEW_UPLOAD', v_res.interview_id,
        v_res.expires_at, v_res.signed_upload_expires_at, false
      );
      insert into public.storage_cleanup_queue(
        source_type, source_parent_id, source_upload_reservation_id,
        bucket_name, object_path, reason_code, status_code, not_before,
        provenance_captured_at
      ) values (
        'INTERVIEW_UPLOAD', v_res.interview_id, v_res.upload_reservation_id,
        v_res.temp_bucket, v_res.temp_path, 'RESERVATION_EXPIRED', 'PENDING',
        greatest(v_res.expires_at, coalesce(v_res.signed_upload_expires_at, v_res.expires_at)),
        v_now
      )
      on conflict (bucket_name, object_path) do update set
        not_before = greatest(public.storage_cleanup_queue.not_before, excluded.not_before),
        provenance_captured_at = coalesce(
          public.storage_cleanup_queue.provenance_captured_at,
          excluded.provenance_captured_at
        );
      update public.upload_reservations
      set status_code = 'EXPIRED'
      where upload_reservation_id = v_res.upload_reservation_id
        and status_code in ('RESERVED', 'UPLOADED', 'VALIDATED');
      v_n := v_n + 1;
    end loop;
  end loop;

  perform private.storage_cleanup_audit(
    'STORAGE_CLEANUP_EXPIRY_DISCOVERY',
    null,
    'SUCCESS',
    jsonb_build_object('captured_count', v_n)
  );
  return jsonb_build_object('success', true, 'data', jsonb_build_object('captured_count', v_n));
end;
$$;

create or replace function public.claim_storage_cleanup_jobs(
  p_worker_id text,
  p_limit integer default 10,
  p_lease_seconds integer default 300
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q public.storage_cleanup_queue%rowtype;
  v_now timestamptz := clock_timestamp();
  v_attempt uuid;
  v_token uuid;
  v_items jsonb := '[]'::jsonb;
  v_code text;
begin
  if p_worker_id is null
    or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$'
    or p_limit is null or p_limit not between 1 and 100
    or p_lease_seconds is null or p_lease_seconds not between 30 and 3600 then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  for v_q in
    select *
    from public.storage_cleanup_queue
    where attempts >= 5
      and (status_code = 'PENDING' or (status_code = 'PROCESSING' and leased_until <= v_now))
    order by storage_cleanup_id
    for update skip locked
    limit p_limit
  loop
    update public.storage_cleanup_queue
    set status_code = 'ERROR',
        eligibility_code = 'ATTEMPT_EXHAUSTED',
        leased_until = null,
        updated_at = v_now
    where storage_cleanup_id = v_q.storage_cleanup_id;
    perform private.storage_cleanup_audit(
      'STORAGE_CLEANUP_LEASE_EXHAUSTED',
      v_q.storage_cleanup_id,
      'FAILED',
      jsonb_build_object('attempt_count', v_q.attempts)
    );
  end loop;

  for v_q in
    select *
    from public.storage_cleanup_queue
    where (
      (status_code = 'PENDING' and not_before <= v_now and attempts < 5)
      or (status_code = 'PROCESSING' and leased_until <= v_now and attempts < 5)
    )
    order by not_before, storage_cleanup_id
    for update skip locked
    limit p_limit
  loop
    v_now := clock_timestamp();
    v_code := private.storage_cleanup_eligibility(v_q, v_now);
    if v_code = 'ELIGIBLE' then
      v_attempt := gen_random_uuid();
      v_token := gen_random_uuid();
      update public.storage_cleanup_queue
      set status_code = 'PROCESSING',
          worker_id = p_worker_id,
          attempt_id = v_attempt,
          fencing_token = v_token,
          attempts = attempts + 1,
          leased_until = v_now + (p_lease_seconds || ' seconds')::interval,
          eligibility_code = 'ELIGIBLE',
          authorized_at = null,
          updated_at = v_now
      where storage_cleanup_id = v_q.storage_cleanup_id
      returning * into v_q;
      perform private.storage_cleanup_audit(
        'STORAGE_CLEANUP_CLAIMED',
        v_q.storage_cleanup_id,
        'SUCCESS',
        jsonb_build_object('worker_id', p_worker_id, 'attempt_id', v_attempt, 'attempt_count', v_q.attempts)
      );
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'storage_cleanup_id', v_q.storage_cleanup_id,
        'source_type', v_q.source_type,
        'bucket_name', v_q.bucket_name,
        'object_path', v_q.object_path,
        'reason_code', v_q.reason_code,
        'attempts', v_q.attempts,
        'not_before', v_q.not_before,
        'attempt_id', v_q.attempt_id,
        'fencing_token', v_q.fencing_token,
        'leased_until', v_q.leased_until
      ));
    elsif v_code in ('SIGNED_WINDOW', 'LIVE_RESERVATION') then
      update public.storage_cleanup_queue
      set status_code = 'PENDING',
          leased_until = null,
          authorized_at = null,
          eligibility_code = v_code,
          not_before = private.storage_cleanup_defer_until(v_q, v_now),
          updated_at = v_now
      where storage_cleanup_id = v_q.storage_cleanup_id;
      perform private.storage_cleanup_audit(
        'STORAGE_CLEANUP_DEFERRED',
        v_q.storage_cleanup_id,
        'DENIED',
        jsonb_build_object('eligibility_code', v_code)
      );
    else
      update public.storage_cleanup_queue
      set status_code = 'ERROR',
          leased_until = null,
          authorized_at = null,
          eligibility_code = v_code,
          updated_at = v_now
      where storage_cleanup_id = v_q.storage_cleanup_id;
      perform private.storage_cleanup_audit(
        'STORAGE_CLEANUP_WITHHELD',
        v_q.storage_cleanup_id,
        'DENIED',
        jsonb_build_object('eligibility_code', v_code)
      );
    end if;
  end loop;

  return jsonb_build_object('success', true, 'data', v_items);
end;
$$;

create or replace function public.authorize_storage_cleanup_attempt(
  p_storage_cleanup_id uuid,
  p_attempt_id uuid,
  p_fencing_token uuid,
  p_worker_id text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q public.storage_cleanup_queue%rowtype;
  v_now timestamptz := clock_timestamp();
  v_code text;
begin
  select * into v_q from public.storage_cleanup_queue where storage_cleanup_id = p_storage_cleanup_id;
  if not found then return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND'); end if;
  perform private.storage_cleanup_identity_lock(v_q.bucket_name, v_q.object_path);
  select * into v_q
  from public.storage_cleanup_queue
  where storage_cleanup_id = p_storage_cleanup_id
  for update;
  v_now := clock_timestamp();
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_q.status_code <> 'PROCESSING'
    or v_q.worker_id is distinct from p_worker_id
    or v_q.attempt_id is distinct from p_attempt_id
    or v_q.fencing_token is distinct from p_fencing_token
    or v_q.leased_until <= v_now then
    return jsonb_build_object('success', false, 'error_code', 'STALE_ATTEMPT');
  end if;

  v_code := private.storage_cleanup_eligibility(v_q, clock_timestamp());
  if v_code <> 'ELIGIBLE' then
    update public.storage_cleanup_queue
    set status_code = case when v_code in ('SIGNED_WINDOW', 'LIVE_RESERVATION') then 'PENDING' else 'ERROR' end,
        leased_until = null,
        authorized_at = null,
        eligibility_code = v_code,
        not_before = case
          when v_code in ('SIGNED_WINDOW', 'LIVE_RESERVATION')
            then private.storage_cleanup_defer_until(v_q, clock_timestamp())
          else not_before
        end,
        updated_at = clock_timestamp()
    where storage_cleanup_id = v_q.storage_cleanup_id;
    perform private.storage_cleanup_audit(
      'STORAGE_CLEANUP_AUTHORIZATION_WITHHELD',
      v_q.storage_cleanup_id,
      'DENIED',
      jsonb_build_object('eligibility_code', v_code)
    );
    return jsonb_build_object('success', false, 'error_code', 'CLEANUP_WITHHELD');
  end if;

  update private.storage_cleanup_provenance
  set tombstoned_at = coalesce(tombstoned_at, v_now),
      tombstone_cleanup_id = v_q.storage_cleanup_id
  where bucket_name = v_q.bucket_name
    and object_path = v_q.object_path;
  update public.storage_cleanup_queue
  set authorized_at = v_now,
      eligibility_code = 'AUTHORIZED',
      updated_at = v_now
  where storage_cleanup_id = v_q.storage_cleanup_id;
  perform private.storage_cleanup_audit(
    'STORAGE_CLEANUP_AUTHORIZED',
    v_q.storage_cleanup_id,
    'SUCCESS',
    jsonb_build_object('worker_id', p_worker_id, 'attempt_id', p_attempt_id)
  );

  return jsonb_build_object('success', true, 'data', jsonb_build_object(
    'storage_cleanup_id', v_q.storage_cleanup_id,
    'bucket_name', v_q.bucket_name,
    'object_path', v_q.object_path,
    'reason_code', v_q.reason_code,
    'attempt_id', p_attempt_id,
    'fencing_token', p_fencing_token,
    'leased_until', v_q.leased_until
  ));
end;
$$;

create or replace function public.complete_storage_cleanup_attempt(
  p_storage_cleanup_id uuid,
  p_attempt_id uuid,
  p_fencing_token uuid,
  p_worker_id text,
  p_success boolean,
  p_error_code text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q public.storage_cleanup_queue%rowtype;
  v_now timestamptz := clock_timestamp();
  v_code text;
begin
  if not p_success and coalesce(p_error_code, 'WORKER_ERROR') not in (
    'WORKER_ERROR', 'TEMPORARY_FAILURE', 'PROVIDER_UNAVAILABLE',
    'PROVIDER_TIMEOUT', 'OBJECT_NOT_FOUND'
  ) then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;
  if p_success is null then return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR'); end if;
  select * into v_q from public.storage_cleanup_queue where storage_cleanup_id = p_storage_cleanup_id;
  if not found then return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND'); end if;
  perform private.storage_cleanup_identity_lock(v_q.bucket_name, v_q.object_path);

  select * into v_q
  from public.storage_cleanup_queue
  where storage_cleanup_id = p_storage_cleanup_id
  for update;
  v_now := clock_timestamp();
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  if v_q.status_code = 'DONE'
    and v_q.worker_id = p_worker_id
    and v_q.attempt_id = p_attempt_id
    and v_q.fencing_token = p_fencing_token then
    return jsonb_build_object('success', true, 'data', jsonb_build_object('status_code', 'DONE', 'replay', true));
  end if;
  if v_q.status_code <> 'PROCESSING'
    or v_q.worker_id is distinct from p_worker_id
    or v_q.attempt_id is distinct from p_attempt_id
    or v_q.fencing_token is distinct from p_fencing_token
    or v_q.leased_until <= v_now then
    return jsonb_build_object('success', false, 'error_code', 'STALE_ATTEMPT');
  end if;

  if p_success then
    if v_q.authorized_at is null then
      return jsonb_build_object('success', false, 'error_code', 'AUTHORIZATION_REQUIRED');
    end if;
    v_code := private.storage_cleanup_eligibility(v_q, clock_timestamp());
    if v_code <> 'ELIGIBLE' then
      update public.storage_cleanup_queue
      set status_code = 'ERROR',
          leased_until = null,
          eligibility_code = v_code,
          updated_at = v_now
      where storage_cleanup_id = v_q.storage_cleanup_id;
      perform private.storage_cleanup_audit(
        'STORAGE_CLEANUP_COMPLETION_WITHHELD',
        v_q.storage_cleanup_id,
        'DENIED',
        jsonb_build_object('eligibility_code', v_code)
      );
      return jsonb_build_object('success', false, 'error_code', 'CLEANUP_WITHHELD');
    end if;
    update public.storage_cleanup_queue
    set status_code = 'DONE',
        leased_until = null,
        last_error = null,
        updated_at = v_now
    where storage_cleanup_id = v_q.storage_cleanup_id;
    perform private.storage_cleanup_audit(
      'STORAGE_CLEANUP_COMPLETED',
      v_q.storage_cleanup_id,
      'SUCCESS',
      jsonb_build_object('worker_id', p_worker_id, 'attempt_id', p_attempt_id)
    );
    return jsonb_build_object('success', true, 'data', jsonb_build_object('status_code', 'DONE'));
  end if;

  update public.storage_cleanup_queue
  set status_code = case when attempts >= 5 then 'ERROR' else 'PENDING' end,
      leased_until = null,
      authorized_at = null,
      last_error = coalesce(p_error_code, 'WORKER_ERROR'),
      not_before = case when attempts < 5 then v_now + interval '5 minutes' else not_before end,
      eligibility_code = case when attempts >= 5 then 'ATTEMPT_EXHAUSTED' else 'WORKER_RETRY' end,
      updated_at = v_now
  where storage_cleanup_id = v_q.storage_cleanup_id;
  perform private.storage_cleanup_audit(
    case when v_q.attempts >= 5 then 'STORAGE_CLEANUP_ATTEMPT_EXHAUSTED' else 'STORAGE_CLEANUP_RETRY' end,
    v_q.storage_cleanup_id,
    'FAILED',
    jsonb_build_object('worker_id', p_worker_id, 'attempt_id', p_attempt_id, 'error_code', coalesce(p_error_code, 'WORKER_ERROR'))
  );
  return jsonb_build_object('success', true, 'data', jsonb_build_object(
    'status_code', case when v_q.attempts >= 5 then 'ERROR' else 'PENDING' end
  ));
end;
$$;

-- Align the effective Interview finalization order with hard-delete and cleanup:
-- Interview -> reservation -> document/version -> queue.
create or replace function public.finalize_interview_upload(
  p_reservation_id uuid,
  p_logical_document_id_or_null uuid,
  p_storage_bucket text,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_checksum_sha256 text,
  p_expected_logical_version_or_null integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.interview_command_actor('interviews.documents');
  v_res public.upload_reservations%rowtype;
  v_i public.interviews%rowtype;
  v_interview_id uuid;
  v_logical public.interview_document_logicals%rowtype;
  v_document uuid;
  v_count integer;
  v_version integer;
  v_old public.interview_documents%rowtype;
  v_fingerprint text;
  v_result jsonb;
begin
  if v_actor is null or (not private.is_root_admin() and not private.has_permission('interviews.manage')) then
    return jsonb_build_object('success', false, 'error_code', case when auth.uid() is null then 'UNAUTHENTICATED' else 'FORBIDDEN' end);
  end if;

  select interview_id into v_interview_id
  from public.upload_reservations
  where upload_reservation_id = p_reservation_id;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  select * into v_i
  from public.interviews
  where interview_id = v_interview_id
  for update;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;
  select * into v_res
  from public.upload_reservations
  where upload_reservation_id = p_reservation_id
    and interview_id = v_i.interview_id
  for update;
  if not found then
    return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  end if;

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
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;
  if v_res.status_code not in ('VALIDATED', 'UPLOADED') or v_res.malware_scan_status <> 'CLEAN' then
    return jsonb_build_object('success', false, 'error_code', 'MALWARE_SCAN_REQUIRED');
  end if;
  if v_res.expires_at <= clock_timestamp() then
    return jsonb_build_object('success', false, 'error_code', 'UPLOAD_RESERVATION_EXPIRED');
  end if;
  if v_res.actual_size_bytes is null
    or v_res.checksum_sha256 is null
    or v_res.detected_mime_type is null
    or v_res.actual_size_bytes <> p_file_size_bytes
    or lower(v_res.checksum_sha256) <> lower(coalesce(p_checksum_sha256, ''))
    or v_res.detected_mime_type <> p_mime_type then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;
  if p_original_filename is null
    or char_length(p_original_filename) > 255
    or p_file_size_bytes is null
    or p_file_size_bytes <= 0
    or p_file_size_bytes > 5242880
    or p_mime_type not in (
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'image/png',
      'image/jpeg'
    )
    or (p_checksum_sha256 is not null and p_checksum_sha256 !~ '^[0-9A-Fa-f]{64}$') then
    return jsonb_build_object('success', false, 'error_code', 'VALIDATION_ERROR');
  end if;

  if p_logical_document_id_or_null is null then
    select count(*) into v_count
    from public.interview_documents d
    join public.interview_document_logicals l on l.logical_document_id = d.logical_document_id
    where l.interview_id = v_i.interview_id
      and d.is_current;
    if v_count >= 5 then
      return jsonb_build_object('success', false, 'error_code', 'UPLOAD_LIMIT_EXCEEDED');
    end if;
    insert into public.interview_document_logicals(interview_id, document_type_id, created_by)
    values(v_i.interview_id, v_res.intended_document_type_id, v_actor)
    returning * into v_logical;
    v_version := 1;
  else
    select * into v_logical
    from public.interview_document_logicals
    where logical_document_id = p_logical_document_id_or_null
      and interview_id = v_i.interview_id
    for update;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
    end if;
    select * into v_old
    from public.interview_documents
    where logical_document_id = v_logical.logical_document_id
      and is_current
    for update;
    if not found then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_DOCUMENT_TARGET');
    end if;
    if p_expected_logical_version_or_null is null or v_old.version_no <> p_expected_logical_version_or_null then
      return jsonb_build_object('success', false, 'error_code', 'STALE_VERSION');
    end if;
    v_version := v_old.version_no + 1;
    update public.interview_documents
    set is_current = false
    where interview_document_id = v_old.interview_document_id;
    insert into public.storage_cleanup_queue(
      source_type, source_parent_id, bucket_name, object_path, reason_code, status_code
    ) values (
      'INTERVIEW_UPLOAD', v_i.interview_id, v_old.storage_bucket, v_old.storage_path,
      'DOCUMENT_REPLACED', 'PENDING'
    )
    on conflict(bucket_name, object_path) do nothing;
  end if;
  insert into public.interview_documents(
    logical_document_id, storage_bucket, storage_path, original_filename, mime_type,
    file_size_bytes, checksum_sha256, version_no, is_current, uploaded_by
  ) values (
    v_logical.logical_document_id, p_storage_bucket, p_storage_path, p_original_filename,
    v_res.detected_mime_type, v_res.actual_size_bytes, v_res.checksum_sha256,
    v_version, true, v_actor
  )
  returning interview_document_id into v_document;
  v_result := jsonb_build_object('success', true, 'data', jsonb_build_object(
    'interview_document_id', v_document,
    'logical_document_id', v_logical.logical_document_id,
    'version_no', v_version
  ));
  update public.upload_reservations
  set status_code = 'FINALIZED',
      finalize_request_fingerprint = v_fingerprint,
      finalize_result = v_result
  where upload_reservation_id = p_reservation_id;
  perform private.audit_interview_command(
    'FINALIZE_INTERVIEW_UPLOAD',
    'INTERVIEW_DOCUMENT',
    v_document,
    v_actor,
    p_reservation_id,
    jsonb_build_object('interview_id', v_i.interview_id)
  );
  return v_result;
end;
$$;

-- The former ID-only completion seam is intentionally removed, not merely hidden.
drop function if exists public.claim_due_storage_cleanup_jobs(integer, integer);
drop function if exists public.complete_storage_cleanup_job(uuid, boolean, text);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'storage_cleanup_worker') then
    create role storage_cleanup_worker nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
  end if;
end;
$$;

revoke all on public.storage_cleanup_queue from public, anon, authenticated, service_role;
revoke all on private.storage_cleanup_provenance from public, anon, authenticated, service_role;
revoke all on function public.discover_expired_storage_cleanup(integer) from public, anon, authenticated, service_role;
revoke all on function public.claim_storage_cleanup_jobs(text, integer, integer) from public, anon, authenticated, service_role;
revoke all on function public.authorize_storage_cleanup_attempt(uuid, uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.complete_storage_cleanup_attempt(uuid, uuid, uuid, text, boolean, text) from public, anon, authenticated, service_role;
revoke all on function private.storage_cleanup_identity_lock(text, text) from public, anon, authenticated, service_role;
revoke all on function private.capture_storage_cleanup_provenance(text, text, uuid, text, uuid, timestamptz, timestamptz, boolean) from public, anon, authenticated, service_role;
revoke all on function private.capture_upload_reservation_provenance() from public, anon, authenticated, service_role;
revoke all on function private.capture_deleted_upload_provenance() from public, anon, authenticated, service_role;
revoke all on function private.reject_cleanup_reservation_resurrection() from public, anon, authenticated, service_role;
revoke all on function private.reject_cleanup_document_resurrection() from public, anon, authenticated, service_role;
revoke all on function private.storage_cleanup_audit(text, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.storage_cleanup_eligibility(public.storage_cleanup_queue, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.storage_cleanup_defer_until(public.storage_cleanup_queue, timestamptz) from public, anon, authenticated, service_role;

grant usage on schema public to storage_cleanup_worker;
grant execute on function public.discover_expired_storage_cleanup(integer) to storage_cleanup_worker;
grant execute on function public.claim_storage_cleanup_jobs(text, integer, integer) to storage_cleanup_worker;
grant execute on function public.authorize_storage_cleanup_attempt(uuid, uuid, uuid, text) to storage_cleanup_worker;
grant execute on function public.complete_storage_cleanup_attempt(uuid, uuid, uuid, text, boolean, text) to storage_cleanup_worker;
