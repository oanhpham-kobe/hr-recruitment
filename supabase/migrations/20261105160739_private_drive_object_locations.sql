-- CR-DRIVE-FILES-HOSTED-20261105. Additive, disabled until gateway configuration.
-- Aliases retain their existing lifecycle; no provider I/O or CLEAN verdict here.
create table private.storage_object_locations (
  bucket_name text not null,
  object_path text not null,
  upload_reservation_id uuid not null unique,
  provider_code text not null default 'GOOGLE_DRIVE' check (provider_code = 'GOOGLE_DRIVE'),
  provider_file_id text not null unique check (provider_file_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  state_code text not null default 'BOUND' check (state_code in ('BOUND', 'SEALED')),
  worker_id text,
  fencing_token uuid,
  leased_until timestamptz,
  checksum_sha256 text,
  actual_size_bytes bigint,
  detected_mime_type text,
  created_at timestamptz not null default clock_timestamp(),
  sealed_at timestamptz,
  primary key (bucket_name, object_path),
  check ((state_code = 'BOUND' and sealed_at is null) or
    (state_code = 'SEALED' and sealed_at is not null and checksum_sha256 is not null
     and checksum_sha256 ~ '^[a-f0-9]{64}$' and actual_size_bytes is not null
     and actual_size_bytes between 1 and 5242880 and detected_mime_type is not null))
);
-- Deliberately no FK to a disposable reservation: identity survives parent cleanup.
alter table private.storage_object_locations enable row level security;
revoke all on private.storage_object_locations from public, anon, authenticated, service_role;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'drive_storage_worker') then
    create role drive_storage_worker nologin noinherit;
  end if;
end $$;
grant usage on schema public to drive_storage_worker;
grant drive_storage_worker to authenticator;
revoke drive_storage_worker from anon, authenticated, service_role;
-- Match the accepted cleanup worker's PostgREST binding; no credential is created.
grant document_scan_worker to authenticator;
revoke document_scan_worker from anon, authenticated, service_role;

create function private.guard_drive_location_identity() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'DRIVE_IDENTITY_IMMUTABLE'; end if;
  if row(new.bucket_name,new.object_path,new.upload_reservation_id,new.provider_code,new.provider_file_id)
     is distinct from row(old.bucket_name,old.object_path,old.upload_reservation_id,old.provider_code,old.provider_file_id)
     or old.state_code = 'SEALED' then
    raise exception 'DRIVE_IDENTITY_IMMUTABLE';
  end if;
  return new;
end $$;
create trigger drive_location_identity_guard before update or delete on private.storage_object_locations
for each row execute function private.guard_drive_location_identity();

-- All mutation helpers enter through the same business -> reservation -> identity order.
create function private.lock_candidate_drive_reservation(p_reservation uuid,p_actor uuid)
returns public.upload_reservations language plpgsql security definer set search_path = '' as $$
declare v_session_id uuid; v_session public.candidate_form_sessions%rowtype;
  v_res public.upload_reservations%rowtype; v_submission public.submissions%rowtype;
begin
  select candidate_form_session_id into v_session_id from public.upload_reservations
    where upload_reservation_id = p_reservation;
  select * into v_session from public.candidate_form_sessions
    where candidate_form_session_id = v_session_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_session.mode_code = 'EDIT_SUBMISSION' then
    select * into v_submission from public.submissions
      where submission_id = v_session.target_submission_id for update;
    if not found or v_submission.candidate_id <> v_session.candidate_id or v_submission.status_code <> 'NEW' then
      raise exception 'INVALID_STATE';
    end if;
  end if;
  select * into v_res from public.upload_reservations where upload_reservation_id = p_reservation for update;
  if not found or v_res.candidate_form_session_id is distinct from v_session.candidate_form_session_id
     or v_res.actor_auth_user_id is distinct from p_actor
     or not exists (select 1 from public.candidates where candidate_id = v_session.candidate_id
                    and auth_user_id = p_actor and is_active) then raise exception 'FORBIDDEN'; end if;
  if v_session.status_code <> 'OPEN' or v_session.expires_at <= clock_timestamp()
     or v_res.status_code not in ('RESERVED','UPLOADED') or v_res.expires_at <= clock_timestamp() then
    raise exception 'INVALID_STATE';
  end if;
  perform private.storage_cleanup_identity_lock(v_res.temp_bucket,v_res.temp_path);
  if exists(select 1 from private.storage_cleanup_provenance where bucket_name = v_res.temp_bucket
            and object_path = v_res.temp_path and tombstoned_at is not null) then
    raise exception 'STORAGE_CLEANUP_IDENTITY_TOMBSTONED';
  end if;
  return v_res;
end $$;

create function public.bind_candidate_drive_object(p_upload_reservation_id uuid,p_actor_auth_user_id uuid,p_provider_file_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_res public.upload_reservations%rowtype; v_location private.storage_object_locations%rowtype;
begin
  if p_provider_file_id is null or p_provider_file_id !~ '^[A-Za-z0-9_-]{10,200}$' then raise exception 'VALIDATION_ERROR'; end if;
  v_res := private.lock_candidate_drive_reservation(p_upload_reservation_id,p_actor_auth_user_id);
  select * into v_location from private.storage_object_locations
    where bucket_name = v_res.temp_bucket and object_path = v_res.temp_path for update;
  if found then
    if v_location.provider_file_id <> p_provider_file_id then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return jsonb_build_object('provider_file_id',v_location.provider_file_id,'state_code',v_location.state_code,'replay',true);
  end if;
  if v_res.status_code <> 'RESERVED' or v_res.signed_upload_expires_at is not null
     or exists(select 1 from storage.objects where bucket_id = v_res.temp_bucket and name = v_res.temp_path) then
    raise exception 'STORAGE_PROVIDER_CONFLICT';
  end if;
  -- Covers every permitted attempt, including bounded in-flight I/O after expiry.
  update public.upload_reservations set signed_upload_expires_at = expires_at + interval '5 minutes'
    where upload_reservation_id = p_upload_reservation_id;
  insert into private.storage_object_locations(bucket_name,object_path,upload_reservation_id,provider_file_id)
    values(v_res.temp_bucket,v_res.temp_path,p_upload_reservation_id,p_provider_file_id);
  insert into public.security_audit_log(actor_auth_user_id,action_code,entity_type,entity_id,source_code,result_code)
    values(p_actor_auth_user_id,'DRIVE_OBJECT_BOUND','UPLOAD_RESERVATION',p_upload_reservation_id,'RPC','SUCCESS');
  return jsonb_build_object('provider_file_id',p_provider_file_id,'state_code','BOUND','replay',false);
end $$;

create function public.claim_drive_upload_attempt(p_upload_reservation_id uuid,p_actor_auth_user_id uuid,p_worker_id text,p_lease_seconds integer default 120)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_res public.upload_reservations%rowtype; v_location private.storage_object_locations%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$' or p_lease_seconds is null or p_lease_seconds not between 30 and 300 then
    raise exception 'VALIDATION_ERROR';
  end if;
  v_res := private.lock_candidate_drive_reservation(p_upload_reservation_id,p_actor_auth_user_id);
  select * into v_location from private.storage_object_locations where upload_reservation_id = p_upload_reservation_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_location.state_code <> 'BOUND' or v_res.status_code <> 'RESERVED' then raise exception 'ALREADY_SEALED'; end if;
  if v_location.leased_until > clock_timestamp() then raise exception 'UPLOAD_BUSY'; end if;
  update private.storage_object_locations set worker_id = p_worker_id, fencing_token = gen_random_uuid(),
    leased_until = least(v_res.expires_at,clock_timestamp() + make_interval(secs => p_lease_seconds))
    where upload_reservation_id = p_upload_reservation_id returning * into v_location;
  insert into public.security_audit_log(actor_auth_user_id,action_code,entity_type,entity_id,source_code,result_code,metadata)
    values(p_actor_auth_user_id,'DRIVE_UPLOAD_CLAIMED','UPLOAD_RESERVATION',p_upload_reservation_id,'RPC','SUCCESS',jsonb_build_object('worker_id',p_worker_id));
  return jsonb_build_object('provider_file_id',v_location.provider_file_id,'fencing_token',v_location.fencing_token,
    'leased_until',v_location.leased_until,'write_deadline',v_res.signed_upload_expires_at);
end $$;

create function public.seal_drive_upload_attempt(p_upload_reservation_id uuid,p_actor_auth_user_id uuid,p_worker_id text,
  p_fencing_token uuid,p_actual_size_bytes bigint,p_detected_mime_type text,p_checksum_sha256 text,p_magic_bytes_verified boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_res public.upload_reservations%rowtype; v_location private.storage_object_locations%rowtype;
  v_result jsonb; v_expected_mime text;
begin
  v_res := private.lock_candidate_drive_reservation(p_upload_reservation_id,p_actor_auth_user_id);
  select * into v_location from private.storage_object_locations where upload_reservation_id = p_upload_reservation_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_location.worker_id is distinct from p_worker_id or v_location.fencing_token is distinct from p_fencing_token
     or v_location.fencing_token is null or v_location.leased_until <= clock_timestamp() then raise exception 'STALE_ATTEMPT'; end if;
  v_expected_mime := case lower(substring(v_res.original_filename from '\.([^.]+)$'))
    when 'pdf' then 'application/pdf'
    when 'doc' then 'application/msword'
    when 'docx' then 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    when 'ppt' then 'application/vnd.ms-powerpoint'
    when 'pptx' then 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
    when 'png' then 'image/png'
    when 'jpg' then 'image/jpeg'
    when 'jpeg' then 'image/jpeg' end;
  if v_expected_mime is null or p_detected_mime_type is distinct from v_expected_mime
     or (v_res.declared_mime_type is not null and lower(v_res.declared_mime_type) <> v_expected_mime) then
    raise exception 'INSPECTION_REJECTED';
  end if;
  if v_location.state_code = 'SEALED' then
    if v_location.checksum_sha256 is distinct from lower(p_checksum_sha256)
       or v_location.actual_size_bytes is distinct from p_actual_size_bytes
       or v_location.detected_mime_type is distinct from p_detected_mime_type or not coalesce(p_magic_bytes_verified,false) then
      raise exception 'FINGERPRINT_MISMATCH';
    end if;
    return jsonb_build_object('state_code','SEALED','replay',true);
  end if;
  v_result := public.record_inspected_upload_reservation(p_upload_reservation_id,p_actual_size_bytes,
    p_detected_mime_type,lower(p_checksum_sha256),p_magic_bytes_verified);
  if not coalesce((v_result->>'success')::boolean,false) then raise exception 'INSPECTION_REJECTED'; end if;
  update private.storage_object_locations set state_code = 'SEALED',checksum_sha256 = lower(p_checksum_sha256),
    actual_size_bytes = p_actual_size_bytes,detected_mime_type = p_detected_mime_type,sealed_at = clock_timestamp()
    where upload_reservation_id = p_upload_reservation_id;
  insert into public.security_audit_log(actor_auth_user_id,action_code,entity_type,entity_id,source_code,result_code,metadata)
    values(p_actor_auth_user_id,'DRIVE_UPLOAD_SEALED','UPLOAD_RESERVATION',p_upload_reservation_id,'RPC','SUCCESS',jsonb_build_object('worker_id',p_worker_id));
  return jsonb_build_object('state_code','SEALED','malware_scan_status','PENDING','replay',false);
end $$;

-- Internal routing only. No browser authorization is conferred by this result.
create function public.resolve_drive_object_location(p_bucket_name text,p_object_path text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('provider_code',provider_code,'provider_file_id',provider_file_id,
    'state_code',state_code,'checksum_sha256',checksum_sha256,'actual_size_bytes',actual_size_bytes,
    'detected_mime_type',detected_mime_type)
  from private.storage_object_locations where bucket_name = p_bucket_name and object_path = p_object_path
$$;

create function public.resolve_drive_cleanup_location(p_storage_cleanup_id uuid,p_attempt_id uuid,p_fencing_token uuid,p_worker_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_auth jsonb;
begin
  -- Reauthorization checks the current lease, signed window, reference and tombstone.
  v_auth := public.authorize_storage_cleanup_attempt(p_storage_cleanup_id,p_attempt_id,p_fencing_token,p_worker_id);
  if not coalesce((v_auth->>'success')::boolean,false) then return v_auth; end if;
  return jsonb_build_object('success',true,'data',jsonb_build_object(
    'authorization',v_auth->'data','location',public.resolve_drive_object_location(
      v_auth->'data'->>'bucket_name',v_auth->'data'->>'object_path')));
end $$;

-- Supabase signed issuance changes this column. Freeze it after Drive binding;
-- the registered horizon already covers all bounded attempts for this reservation.
create function private.guard_drive_signed_window() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from private.storage_object_locations where bucket_name = new.temp_bucket and object_path = new.temp_path) then
    raise exception 'STORAGE_PROVIDER_CONFLICT';
  end if;
  return new;
end $$;
create trigger drive_signed_window_guard before update of signed_upload_expires_at on public.upload_reservations
for each row execute function private.guard_drive_signed_window();

create function private.guard_drive_storage_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.bucket_id not in ('candidate-quarantine','interview-quarantine') then return new; end if;
  -- Serialize with binding before examining provider identity. No session lock
  -- is acquired here, so this cannot invert the domain parent lock order.
  perform 1 from public.upload_reservations where temp_bucket = new.bucket_id and temp_path = new.name for update;
  perform private.storage_cleanup_identity_lock(new.bucket_id,new.name);
  if exists(select 1 from private.storage_object_locations where bucket_name = new.bucket_id and object_path = new.name) then
    raise exception 'STORAGE_PROVIDER_CONFLICT';
  end if;
  return new;
end $$;
create trigger drive_storage_write_guard before insert or update on storage.objects
for each row execute function private.guard_drive_storage_write();

revoke all on function private.guard_drive_location_identity(), private.lock_candidate_drive_reservation(uuid,uuid),
  private.guard_drive_signed_window(),private.guard_drive_storage_write() from public,anon,authenticated,service_role;
revoke all on function public.bind_candidate_drive_object(uuid,uuid,text),
  public.claim_drive_upload_attempt(uuid,uuid,text,integer),
  public.seal_drive_upload_attempt(uuid,uuid,text,uuid,bigint,text,text,boolean),
  public.resolve_drive_object_location(text,text),public.resolve_drive_cleanup_location(uuid,uuid,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.bind_candidate_drive_object(uuid,uuid,text),
  public.claim_drive_upload_attempt(uuid,uuid,text,integer),
  public.seal_drive_upload_attempt(uuid,uuid,text,uuid,bigint,text,text,boolean),
  public.resolve_drive_object_location(text,text) to drive_storage_worker;
grant execute on function public.resolve_drive_cleanup_location(uuid,uuid,uuid,text) to storage_cleanup_worker;

create function public.resolve_drive_scan_attempt(p_document_scan_request_id uuid,p_attempt_id uuid,p_fencing_token uuid,p_worker_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_result jsonb;
begin
  select jsonb_build_object('provider_code',l.provider_code,'provider_file_id',l.provider_file_id,
    'checksum_sha256',q.checksum_sha256,'actual_size_bytes',q.actual_size_bytes,'detected_mime_type',q.detected_mime_type,
    'upload_reservation_id',q.upload_reservation_id,'leased_until',q.leased_until)
  into v_result
  from public.document_scan_requests q
  join private.document_scan_attempts a on a.document_scan_request_id=q.document_scan_request_id
  join public.upload_reservations r on r.upload_reservation_id=q.upload_reservation_id
  join public.candidate_form_sessions s on s.candidate_form_session_id=r.candidate_form_session_id
  join private.storage_object_locations l on l.bucket_name=q.bucket_name and l.object_path=q.object_path
  where q.document_scan_request_id=p_document_scan_request_id and a.document_scan_attempt_id=p_attempt_id
    and a.worker_id=p_worker_id and a.fencing_token=p_fencing_token and a.completed_at is null
    and a.leased_until>clock_timestamp() and q.leased_until>clock_timestamp()
    and q.status_code='PROCESSING' and q.current_attempt_id=p_attempt_id and q.current_fencing_token=p_fencing_token
    and q.candidate_form_session_id=s.candidate_form_session_id and s.status_code='OPEN' and s.expires_at>clock_timestamp()
    and r.status_code='UPLOADED' and r.malware_scan_status='PENDING' and r.expires_at>clock_timestamp()
    and r.temp_bucket=q.bucket_name and r.temp_path=q.object_path
    and q.object_fingerprint=private.document_scan_fingerprint(r,r.checksum_sha256,r.detected_mime_type,r.actual_size_bytes)
    and l.upload_reservation_id=r.upload_reservation_id and l.state_code='SEALED'
    and l.checksum_sha256=q.checksum_sha256 and l.actual_size_bytes=q.actual_size_bytes and l.detected_mime_type=q.detected_mime_type;
  if v_result is null then raise exception 'STALE_SCAN_CONTEXT'; end if;
  return v_result;
end $$;

create function public.authorize_drive_document_read(p_actor_auth_user_id uuid,p_submission_id uuid,
  p_logical_document_id uuid,p_document_id uuid,p_purpose text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user public.app_users%rowtype; v_doc public.submission_documents%rowtype;
  v_location private.storage_object_locations%rowtype;
begin
  if p_purpose is null or p_purpose not in ('preview','download') then raise exception 'VALIDATION_ERROR'; end if;
  -- Match User lifecycle writers: row before advisory. The access audit's
  -- actor FK later needs KEY SHARE on this same row and must not invert them.
  select * into v_user from public.app_users where auth_user_id=p_actor_auth_user_id for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  perform private.lock_internal_user_ids(array[v_user.app_user_id]);
  select * into v_user from public.app_users where app_user_id=v_user.app_user_id
    and auth_user_id=p_actor_auth_user_id and is_active;
  if not found then raise exception 'FORBIDDEN'; end if;
  if not v_user.is_root_admin and not exists(select 1 from public.app_user_permissions
     where app_user_id=v_user.app_user_id and permission_code='submissions.view') then raise exception 'FORBIDDEN'; end if;
  select d.* into v_doc from public.submission_documents d
    join public.submission_document_logicals l on l.logical_document_id=d.logical_document_id
    join public.submissions s on s.submission_id=l.submission_id
    where d.document_id=p_document_id and l.logical_document_id=p_logical_document_id
      and s.submission_id=p_submission_id and d.malware_scan_status='CLEAN';
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_purpose='preview' and v_doc.mime_type not in ('application/pdf','image/png','image/jpeg') then
    raise exception 'DOCUMENT_NOT_PREVIEWABLE';
  end if;
  select * into v_location from private.storage_object_locations
    where bucket_name=v_doc.storage_bucket and object_path=v_doc.storage_path and state_code='SEALED'
      and checksum_sha256=v_doc.checksum_sha256 and actual_size_bytes=v_doc.file_size_bytes and detected_mime_type=v_doc.mime_type;
  if not found then raise exception 'DOCUMENT_UNAVAILABLE'; end if;
  insert into public.security_audit_log(actor_auth_user_id,actor_app_user_id,action_code,entity_type,entity_id,source_code,result_code,metadata)
    values(p_actor_auth_user_id,v_user.app_user_id,'DOCUMENT_ACCESS','SUBMISSION_DOCUMENT',p_document_id,'WEB','SUCCESS',
      jsonb_build_object('submission_id',p_submission_id,'logical_document_id',p_logical_document_id,'document_id',p_document_id,'purpose',p_purpose));
  return jsonb_build_object('provider_code',v_location.provider_code,'provider_file_id',v_location.provider_file_id,
    'checksum_sha256',v_location.checksum_sha256,'actual_size_bytes',v_location.actual_size_bytes,
    'mime_type',v_location.detected_mime_type,'original_filename',v_doc.original_filename,'purpose',p_purpose);
end $$;

revoke all on function public.resolve_drive_scan_attempt(uuid,uuid,uuid,text),
  public.authorize_drive_document_read(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.resolve_drive_scan_attempt(uuid,uuid,uuid,text) to document_scan_worker;
grant execute on function public.authorize_drive_document_read(uuid,uuid,uuid,uuid,text) to drive_storage_worker;
