-- S07-002: durable, provider-independent document scan request and result fencing.
-- No scanner/provider/runtime is invoked by this migration.

create table if not exists public.document_scan_requests (
  document_scan_request_id uuid primary key default gen_random_uuid(),
  upload_reservation_id uuid not null unique references public.upload_reservations(upload_reservation_id) on delete cascade,
  candidate_form_session_id uuid references public.candidate_form_sessions(candidate_form_session_id) on delete cascade,
  interview_id uuid,
  action_code text not null check (action_code in ('ADD','REPLACE')),
  intended_document_type_id uuid not null references public.document_types(document_type_id) on delete restrict,
  target_logical_document_id uuid references public.submission_document_logicals(logical_document_id) on delete restrict,
  bucket_name text not null,
  object_path text not null,
  checksum_sha256 text not null check (checksum_sha256 ~ '^[0-9A-Fa-f]{64}$'),
  object_fingerprint text not null check (char_length(object_fingerprint) = 64),
  detected_mime_type text not null,
  actual_size_bytes bigint not null check (actual_size_bytes > 0 and actual_size_bytes <= 5242880),
  status_code text not null default 'PENDING' check (status_code in ('PENDING','PROCESSING','CLEAN','INFECTED','ERROR','CANCELLED','EXPIRED')),
  attempt_no integer not null default 0 check (attempt_no >= 0 and attempt_no <= 3),
  next_attempt_at timestamptz not null default clock_timestamp(),
  current_attempt_id uuid,
  current_fencing_token uuid,
  leased_until timestamptz,
  staged_change_id uuid references public.candidate_form_document_changes(candidate_form_document_change_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint document_scan_request_parent_ck check ((candidate_form_session_id is not null)::int + (interview_id is not null)::int = 1),
  constraint document_scan_request_target_ck check (
    (action_code = 'ADD' and target_logical_document_id is null) or
    (action_code = 'REPLACE' and target_logical_document_id is not null)
  )
);
create index if not exists document_scan_requests_claim_idx
  on public.document_scan_requests(status_code, next_attempt_at, leased_until)
  where status_code in ('PENDING','PROCESSING','ERROR');

create table if not exists private.document_scan_attempts (
  document_scan_attempt_id uuid primary key,
  document_scan_request_id uuid not null references public.document_scan_requests(document_scan_request_id) on delete cascade,
  attempt_no integer not null,
  worker_id text not null,
  fencing_token uuid not null unique,
  claimed_at timestamptz not null,
  leased_until timestamptz not null,
  completed_at timestamptz,
  outcome_code text check (outcome_code in ('CLEAN','INFECTED','ERROR','STALE')),
  error_code text,
  unique(document_scan_request_id, attempt_no)
);

alter table public.document_scan_requests enable row level security;
alter table private.document_scan_attempts enable row level security;
revoke all on public.document_scan_requests from public, anon, authenticated;
revoke all on private.document_scan_attempts from public, anon, authenticated;
grant all on public.document_scan_requests to postgres, service_role;
grant all on private.document_scan_attempts to postgres, service_role;

do $$ begin
  if not exists(select 1 from pg_roles where rolname='document_scan_worker') then
    create role document_scan_worker nologin noinherit;
  end if;
end $$;

create or replace function private.document_scan_fingerprint(
  p_res public.upload_reservations,
  p_checksum text,
  p_mime text,
  p_size bigint
) returns text language sql immutable set search_path='' as $$
  select encode(extensions.digest(jsonb_build_object(
    'reservation_id',p_res.upload_reservation_id,
    'candidate_form_session_id',p_res.candidate_form_session_id,
    'interview_id',p_res.interview_id,
    'bucket',p_res.temp_bucket,
    'path',p_res.temp_path,
    'checksum',p_checksum,
    'mime',p_mime,
    'size',p_size
  )::text,'sha256'),'hex')
$$;

create or replace function private.document_scan_audit(p_action text,p_request uuid,p_result text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
  insert into public.security_audit_log(action_code,entity_type,entity_id,source_code,result_code,metadata)
  values(p_action,'DOCUMENT_SCAN_REQUEST',p_request,'RPC',p_result,jsonb_build_object('request_id',p_request));
end;
$$;

-- Candidate path: no scanner call, no verdict input, no object identity input.
create or replace function public.request_candidate_document_scan(
  p_candidate_form_session_id uuid,
  p_upload_reservation_id uuid,
  p_action_code text,
  p_target_logical_document_id uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_auth uuid:=auth.uid(); v_cand public.candidates%rowtype; v_session public.candidate_form_sessions%rowtype;
 v_res public.upload_reservations%rowtype; v_existing public.document_scan_requests%rowtype; v_target public.submission_document_logicals%rowtype;
 v_id uuid; v_fp text;
begin
 if v_auth is null then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED'); end if;
 select * into v_cand from public.candidates where auth_user_id=v_auth and is_active;
 if not found then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED'); end if;
 select * into v_session from public.candidate_form_sessions where candidate_form_session_id=p_candidate_form_session_id and candidate_id=v_cand.candidate_id for update;
 if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
 if v_session.status_code<>'OPEN' then return jsonb_build_object('success',false,'error_code','INVALID_STATE'); end if;
 if v_session.expires_at<=clock_timestamp() then return jsonb_build_object('success',false,'error_code','FORM_SESSION_EXPIRED'); end if;
 if p_action_code not in ('ADD','REPLACE') or (p_action_code='ADD' and p_target_logical_document_id is not null) or (p_action_code='REPLACE' and p_target_logical_document_id is null) then
   return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
 select * into v_res from public.upload_reservations where upload_reservation_id=p_upload_reservation_id and candidate_form_session_id=v_session.candidate_form_session_id and actor_auth_user_id=v_auth for update;
 if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
 if v_res.status_code<>'UPLOADED' or v_res.malware_scan_status<>'PENDING' or v_res.expires_at<=clock_timestamp() then
   return jsonb_build_object('success',false,'error_code','INVALID_STATE'); end if;
 if v_res.checksum_sha256 is null or v_res.detected_mime_type is null or v_res.actual_size_bytes is null then
   return jsonb_build_object('success',false,'error_code','UPLOAD_METADATA_UNAVAILABLE'); end if;
 if p_action_code='REPLACE' then
   select * into v_target from public.submission_document_logicals where logical_document_id=p_target_logical_document_id and submission_id=v_session.target_submission_id for update;
   if not found or v_target.document_type_id is distinct from v_res.intended_document_type_id then return jsonb_build_object('success',false,'error_code','INVALID_DOCUMENT_TARGET'); end if;
 end if;
 v_fp:=private.document_scan_fingerprint(v_res,v_res.checksum_sha256,v_res.detected_mime_type,v_res.actual_size_bytes);
 select * into v_existing from public.document_scan_requests where upload_reservation_id=v_res.upload_reservation_id for update;
 if found then
   if v_existing.candidate_form_session_id is distinct from v_session.candidate_form_session_id or v_existing.bucket_name is distinct from v_res.temp_bucket or v_existing.object_path is distinct from v_res.temp_path or v_existing.object_fingerprint is distinct from v_fp or v_existing.action_code is distinct from p_action_code or v_existing.target_logical_document_id is distinct from p_target_logical_document_id then
     return jsonb_build_object('success',false,'error_code','FINGERPRINT_MISMATCH'); end if;
   return jsonb_build_object('success',true,'data',jsonb_build_object('kind','PENDING_SCAN','document_scan_request_id',v_existing.document_scan_request_id,'upload_reservation_id',v_res.upload_reservation_id));
 end if;
 insert into public.document_scan_requests(upload_reservation_id,candidate_form_session_id,action_code,intended_document_type_id,target_logical_document_id,bucket_name,object_path,checksum_sha256,object_fingerprint,detected_mime_type,actual_size_bytes)
 values(v_res.upload_reservation_id,v_session.candidate_form_session_id,p_action_code,v_res.intended_document_type_id,p_target_logical_document_id,v_res.temp_bucket,v_res.temp_path,v_res.checksum_sha256,v_fp,v_res.detected_mime_type,v_res.actual_size_bytes)
 returning document_scan_request_id into v_id;
 perform private.document_scan_audit('DOCUMENT_SCAN_REQUESTED',v_id,'SUCCESS');
 return jsonb_build_object('success',true,'data',jsonb_build_object('kind','PENDING_SCAN','document_scan_request_id',v_id,'upload_reservation_id',v_res.upload_reservation_id));
end;
$$;

create or replace function public.claim_document_scan_requests(p_worker_id text,p_limit integer default 10,p_lease_seconds integer default 300)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_r public.document_scan_requests%rowtype; v_attempt uuid; v_token uuid; v_now timestamptz:=clock_timestamp(); v_items jsonb:='[]'::jsonb;
begin
 if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$' or p_limit not between 1 and 100 or p_lease_seconds not between 30 and 3600 then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
 for v_r in select * from public.document_scan_requests
   where ((status_code='PENDING' and next_attempt_at<=v_now) or (status_code='ERROR' and attempt_no<3 and next_attempt_at<=v_now) or (status_code='PROCESSING' and leased_until<=v_now and attempt_no<3))
   order by next_attempt_at,document_scan_request_id for update skip locked limit p_limit loop
   if not exists(select 1 from public.upload_reservations r join public.candidate_form_sessions s on s.candidate_form_session_id=r.candidate_form_session_id where r.upload_reservation_id=v_r.upload_reservation_id and r.status_code='UPLOADED' and r.malware_scan_status='PENDING' and r.expires_at>v_now and s.status_code='OPEN' and s.expires_at>v_now) then
     update public.document_scan_requests set status_code='CANCELLED',leased_until=null,updated_at=v_now where document_scan_request_id=v_r.document_scan_request_id;
     continue;
   end if;
   v_attempt:=gen_random_uuid(); v_token:=gen_random_uuid();
   update public.document_scan_requests set status_code='PROCESSING',attempt_no=attempt_no+1,current_attempt_id=v_attempt,current_fencing_token=v_token,leased_until=v_now+(p_lease_seconds||' seconds')::interval,updated_at=v_now where document_scan_request_id=v_r.document_scan_request_id returning * into v_r;
   insert into private.document_scan_attempts(document_scan_attempt_id,document_scan_request_id,attempt_no,worker_id,fencing_token,claimed_at,leased_until)
   values(v_attempt,v_r.document_scan_request_id,v_r.attempt_no,p_worker_id,v_token,v_now,v_r.leased_until);
   perform private.document_scan_audit('DOCUMENT_SCAN_CLAIMED',v_r.document_scan_request_id,'SUCCESS');
   v_items:=v_items||jsonb_build_array(jsonb_build_object('document_scan_request_id',v_r.document_scan_request_id,'upload_reservation_id',v_r.upload_reservation_id,'attempt_id',v_attempt,'fencing_token',v_token,'leased_until',v_r.leased_until));
 end loop;
 return jsonb_build_object('success',true,'data',v_items);
end;
$$;

create or replace function public.complete_document_scan_attempt(p_document_scan_request_id uuid,p_attempt_id uuid,p_fencing_token uuid,p_worker_id text,p_outcome text,p_error_code text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_q public.document_scan_requests%rowtype; v_a private.document_scan_attempts%rowtype; v_session public.candidate_form_sessions%rowtype;
 v_res public.upload_reservations%rowtype; v_now timestamptz; v_retry boolean; v_not_before timestamptz;
begin
 if p_outcome not in ('CLEAN','INFECTED','ERROR') or p_worker_id is null then return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR'); end if;
 -- Match cancellation's session -> reservation -> request lock order before
 -- checking a fenced completion; never hold the request while waiting on a
 -- reservation whose cancellation trigger will take that request.
 select s.* into v_session from public.candidate_form_sessions s
 join public.document_scan_requests q on q.candidate_form_session_id=s.candidate_form_session_id
 where q.document_scan_request_id=p_document_scan_request_id for update of s;
 if not found then return jsonb_build_object('success',false,'error_code','STALE_CONTEXT'); end if;
 select r.* into v_res from public.upload_reservations r
 join public.document_scan_requests q on q.upload_reservation_id=r.upload_reservation_id
 where q.document_scan_request_id=p_document_scan_request_id for update of r;
 if not found then return jsonb_build_object('success',false,'error_code','STALE_CONTEXT'); end if;
 select * into v_q from public.document_scan_requests where document_scan_request_id=p_document_scan_request_id for update;
 select * into v_a from private.document_scan_attempts where document_scan_attempt_id=p_attempt_id and document_scan_request_id=p_document_scan_request_id for update;
 v_now:=clock_timestamp();
 if not found or v_a.worker_id is distinct from p_worker_id or v_a.fencing_token is distinct from p_fencing_token or v_q.status_code<>'PROCESSING' or v_q.current_attempt_id is distinct from p_attempt_id or v_q.current_fencing_token is distinct from p_fencing_token or v_q.leased_until<=v_now then return jsonb_build_object('success',false,'error_code','STALE_ATTEMPT'); end if;
 if v_res.candidate_form_session_id is distinct from v_q.candidate_form_session_id or v_res.status_code<>'UPLOADED' or v_res.malware_scan_status<>'PENDING' or v_res.expires_at<=v_now or v_res.temp_bucket is distinct from v_q.bucket_name or v_res.temp_path is distinct from v_q.object_path or v_res.checksum_sha256 is distinct from v_q.checksum_sha256 or v_session.status_code<>'OPEN' or v_session.expires_at<=v_now then
   update private.document_scan_attempts set completed_at=v_now,outcome_code='STALE',error_code='STALE_CONTEXT' where document_scan_attempt_id=p_attempt_id;
   return jsonb_build_object('success',false,'error_code','STALE_CONTEXT');
 end if;
 update private.document_scan_attempts set completed_at=v_now,outcome_code=p_outcome,error_code=p_error_code where document_scan_attempt_id=p_attempt_id;
 if p_outcome='CLEAN' then
   update public.upload_reservations set status_code='VALIDATED',malware_scan_status='CLEAN' where upload_reservation_id=v_q.upload_reservation_id;
   update public.document_scan_requests set status_code='CLEAN',leased_until=null,updated_at=v_now where document_scan_request_id=v_q.document_scan_request_id;
 elsif p_outcome='INFECTED' then
   update public.upload_reservations set status_code='REJECTED',malware_scan_status='INFECTED' where upload_reservation_id=v_q.upload_reservation_id;
   update public.document_scan_requests set status_code='INFECTED',leased_until=null,updated_at=v_now where document_scan_request_id=v_q.document_scan_request_id;
   v_not_before:=greatest(v_res.expires_at,coalesce(v_res.signed_upload_expires_at,v_res.expires_at));
   insert into public.storage_cleanup_queue(source_type,source_parent_id,source_upload_reservation_id,bucket_name,object_path,reason_code,status_code,not_before)
   values('CANDIDATE_FORM',v_res.candidate_form_session_id,v_res.upload_reservation_id,v_res.temp_bucket,v_res.temp_path,'MALWARE_REJECTED','PENDING',v_not_before)
   on conflict(bucket_name,object_path) do update set not_before=greatest(public.storage_cleanup_queue.not_before,excluded.not_before);
 else
   v_retry:=v_q.attempt_no<3;
   if v_retry then
     update public.document_scan_requests set status_code='ERROR',leased_until=null,next_attempt_at=v_now+(least(300,30*(2^v_q.attempt_no))||' seconds')::interval,updated_at=v_now where document_scan_request_id=v_q.document_scan_request_id;
   else
     update public.upload_reservations set status_code='REJECTED',malware_scan_status='ERROR' where upload_reservation_id=v_q.upload_reservation_id;
     update public.document_scan_requests set status_code='ERROR',leased_until=null,next_attempt_at='infinity'::timestamptz,updated_at=v_now where document_scan_request_id=v_q.document_scan_request_id;
     v_not_before:=greatest(v_res.expires_at,coalesce(v_res.signed_upload_expires_at,v_res.expires_at));
     insert into public.storage_cleanup_queue(source_type,source_parent_id,source_upload_reservation_id,bucket_name,object_path,reason_code,status_code,not_before)
     values('CANDIDATE_FORM',v_res.candidate_form_session_id,v_res.upload_reservation_id,v_res.temp_bucket,v_res.temp_path,'MALWARE_REJECTED','PENDING',v_not_before)
     on conflict(bucket_name,object_path) do update set not_before=greatest(public.storage_cleanup_queue.not_before,excluded.not_before);
   end if;
 end if;
 perform private.document_scan_audit('DOCUMENT_SCAN_RESULT',v_q.document_scan_request_id,case when p_outcome='ERROR' then 'FAILED' else 'SUCCESS' end);
 return jsonb_build_object('success',true,'data',jsonb_build_object('status_code',p_outcome));
end;
$$;

-- Candidate continuation owns composition, not worker result persistence.
create or replace function public.continue_clean_candidate_document_scan(p_candidate_form_session_id uuid,p_upload_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_auth uuid:=auth.uid(); v_cand public.candidates%rowtype; v_session public.candidate_form_sessions%rowtype;
 v_res public.upload_reservations%rowtype; v_q public.document_scan_requests%rowtype; v_result jsonb; v_change uuid;
 v_now timestamptz; v_not_before timestamptz;
begin
 if v_auth is null then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED'); end if;
 select * into v_cand from public.candidates where auth_user_id=v_auth and is_active;
 if not found then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED'); end if;
 select * into v_session from public.candidate_form_sessions
   where candidate_form_session_id=p_candidate_form_session_id and candidate_id=v_cand.candidate_id for update;
 if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
 select * into v_res from public.upload_reservations
   where upload_reservation_id=p_upload_reservation_id and candidate_form_session_id=v_session.candidate_form_session_id for update;
 if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
 select * into v_q from public.document_scan_requests
   where upload_reservation_id=v_res.upload_reservation_id and candidate_form_session_id=v_session.candidate_form_session_id for update;
 if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
 if v_q.staged_change_id is not null then return jsonb_build_object('success',true,'data',jsonb_build_object('kind','STAGED','change_id',v_q.staged_change_id)); end if;
 v_now:=clock_timestamp();
 if v_q.status_code='PROCESSING' and v_q.attempt_no>=3 and v_q.leased_until<=v_now then
   update public.upload_reservations set status_code='REJECTED',malware_scan_status='ERROR' where upload_reservation_id=v_res.upload_reservation_id;
   update public.document_scan_requests set status_code='ERROR',leased_until=null,next_attempt_at='infinity'::timestamptz,updated_at=v_now where document_scan_request_id=v_q.document_scan_request_id;
   v_not_before:=greatest(v_res.expires_at,coalesce(v_res.signed_upload_expires_at,v_res.expires_at));
   insert into public.storage_cleanup_queue(source_type,source_parent_id,source_upload_reservation_id,bucket_name,object_path,reason_code,status_code,not_before)
   values('CANDIDATE_FORM',v_res.candidate_form_session_id,v_res.upload_reservation_id,v_res.temp_bucket,v_res.temp_path,'MALWARE_REJECTED','PENDING',v_not_before)
   on conflict(bucket_name,object_path) do update set not_before=greatest(public.storage_cleanup_queue.not_before,excluded.not_before);
   perform private.document_scan_audit('DOCUMENT_SCAN_RESULT',v_q.document_scan_request_id,'FAILED');
   return jsonb_build_object('success',false,'error_code','SCAN_FAILED');
 end if;
 if v_q.status_code='INFECTED' then return jsonb_build_object('success',false,'error_code','SCAN_REJECTED'); end if;
 if v_q.status_code='ERROR' and v_q.attempt_no>=3 then return jsonb_build_object('success',false,'error_code','SCAN_FAILED'); end if;
 if v_q.status_code='CANCELLED' then return jsonb_build_object('success',false,'error_code','SCAN_CANCELLED'); end if;
 if v_q.status_code<>'CLEAN' then return jsonb_build_object('success',false,'error_code','SCAN_NOT_CLEAN'); end if;
 select public.stage_candidate_document_change(v_q.candidate_form_session_id,v_q.action_code,v_q.intended_document_type_id,v_q.upload_reservation_id,v_q.target_logical_document_id) into v_result;
 if not coalesce((v_result->>'success')::boolean,false) then return v_result; end if;
 v_change:=(v_result->'data'->>'candidate_form_document_change_id')::uuid;
 update public.document_scan_requests set staged_change_id=v_change,updated_at=clock_timestamp() where document_scan_request_id=v_q.document_scan_request_id and staged_change_id is null;
 perform private.document_scan_audit('DOCUMENT_SCAN_STAGED',v_q.document_scan_request_id,'SUCCESS');
 return jsonb_build_object('success',true,'data',jsonb_build_object('kind','STAGED','change_id',coalesce((select staged_change_id from public.document_scan_requests where document_scan_request_id=v_q.document_scan_request_id),v_change)));
end;
$$;


revoke all on function public.request_candidate_document_scan(uuid,uuid,text,uuid), public.continue_clean_candidate_document_scan(uuid,uuid) from public,anon;
grant execute on function public.request_candidate_document_scan(uuid,uuid,text,uuid), public.continue_clean_candidate_document_scan(uuid,uuid) to authenticated;
revoke all on function public.claim_document_scan_requests(text,integer,integer), public.complete_document_scan_attempt(uuid,uuid,uuid,text,text,text) from public,anon,authenticated,service_role;
grant usage on schema public to document_scan_worker;
grant execute on function public.claim_document_scan_requests(text,integer,integer), public.complete_document_scan_attempt(uuid,uuid,uuid,text,text,text) to document_scan_worker;

-- Server-side inspection records metadata before request creation. It is not
-- callable by browser roles and never accepts a scan verdict.
create or replace function public.record_inspected_upload_reservation(
  p_upload_reservation_id uuid,
  p_actual_size_bytes bigint,
  p_detected_mime_type text,
  p_checksum_sha256 text,
  p_magic_bytes_verified boolean
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_res public.upload_reservations%rowtype;
begin
 if p_actual_size_bytes is null or p_actual_size_bytes not between 1 and 5242880
    or p_checksum_sha256 is null or p_checksum_sha256 !~ '^[0-9A-Fa-f]{64}$'
    or p_detected_mime_type is null or btrim(p_detected_mime_type)='' or not coalesce(p_magic_bytes_verified,false) then
   return jsonb_build_object('success',false,'error_code','VALIDATION_ERROR');
 end if;
 select * into v_res from public.upload_reservations where upload_reservation_id=p_upload_reservation_id for update;
 if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND'); end if;
 if v_res.status_code not in ('RESERVED','UPLOADED') or v_res.expires_at<=clock_timestamp() then
   return jsonb_build_object('success',false,'error_code','INVALID_STATE');
 end if;
 if p_actual_size_bytes>v_res.expected_max_size_bytes then return jsonb_build_object('success',false,'error_code','FILE_SIZE_EXCEEDED'); end if;
 if v_res.status_code='UPLOADED' and (v_res.checksum_sha256 is distinct from p_checksum_sha256 or v_res.actual_size_bytes is distinct from p_actual_size_bytes or v_res.detected_mime_type is distinct from p_detected_mime_type) then
   return jsonb_build_object('success',false,'error_code','FINGERPRINT_MISMATCH');
 end if;
 update public.upload_reservations set status_code='UPLOADED',actual_size_bytes=p_actual_size_bytes,
   detected_mime_type=p_detected_mime_type,checksum_sha256=p_checksum_sha256,malware_scan_status='PENDING'
 where upload_reservation_id=p_upload_reservation_id;
 return jsonb_build_object('success',true,'data',jsonb_build_object('upload_reservation_id',p_upload_reservation_id,'status_code','UPLOADED','malware_scan_status','PENDING'));
end;
$$;

create or replace function private.fence_document_scan_on_reservation_cancel()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status_code in ('CANCELLED','EXPIRED','REJECTED') and old.status_code is distinct from new.status_code then
   update public.document_scan_requests set status_code='CANCELLED',leased_until=null,updated_at=clock_timestamp()
   where upload_reservation_id=new.upload_reservation_id and staged_change_id is null
     and status_code in ('PENDING','PROCESSING','ERROR','CLEAN');
 end if;
 return new;
end;
$$;
drop trigger if exists document_scan_reservation_fence on public.upload_reservations;
create trigger document_scan_reservation_fence after update of status_code on public.upload_reservations
for each row execute function private.fence_document_scan_on_reservation_cancel();
revoke all on function private.document_scan_fingerprint(public.upload_reservations,text,text,bigint),
  private.document_scan_audit(text,uuid,text),
  private.fence_document_scan_on_reservation_cancel()
  from public,anon,authenticated,service_role;

revoke all on function public.record_inspected_upload_reservation(uuid,bigint,text,text,boolean) from public,anon,authenticated;
grant execute on function public.record_inspected_upload_reservation(uuid,bigint,text,text,boolean) to service_role,postgres;

-- Retire the synchronous provider-shaped result API. New result persistence is
-- reachable only through the narrow document_scan_worker role above.
revoke all on function public.validate_and_scan_upload_reservation(uuid,text,bigint,text,boolean,text)
  from public, anon, authenticated, service_role;

-- A retry may arrive after trusted inspection wrote UPLOADED. Keep the
-- candidate/session authorization exact while allowing request idempotency to
-- converge on the immutable inspected reservation evidence.
create or replace function public.authorize_candidate_upload_scan(
  p_candidate_form_session_id uuid,
  p_upload_reservation_id uuid
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_auth_uid uuid:=auth.uid();
  v_candidate_id uuid;
  v_session public.candidate_form_sessions%rowtype;
  v_submission public.submissions%rowtype;
  v_reservation public.upload_reservations%rowtype;
begin
  if v_auth_uid is null then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED','message','Candidate authentication required'); end if;
  select candidate_id into v_candidate_id from public.candidates where auth_user_id=v_auth_uid and is_active;
  if v_candidate_id is null then return jsonb_build_object('success',false,'error_code','UNAUTHENTICATED','message','Candidate authentication required'); end if;
  select * into v_session from public.candidate_form_sessions
    where candidate_form_session_id=p_candidate_form_session_id and candidate_id=v_candidate_id for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND','message','Candidate form session not found or access denied'); end if;
  if v_session.status_code<>'OPEN' then return jsonb_build_object('success',false,'error_code','INVALID_STATE','message','Candidate form session is not open'); end if;
  if v_session.expires_at<=clock_timestamp() then return jsonb_build_object('success',false,'error_code','FORM_SESSION_EXPIRED','message','Candidate form session has expired'); end if;
  if v_session.mode_code='EDIT_SUBMISSION' then
    select * into v_submission from public.submissions
      where submission_id=v_session.target_submission_id and candidate_id=v_candidate_id for update;
    if not found or v_submission.status_code<>'NEW' then return jsonb_build_object('success',false,'error_code','INVALID_STATE','message','Target submission is no longer in editable NEW status'); end if;
  end if;
  select * into v_reservation from public.upload_reservations
    where upload_reservation_id=p_upload_reservation_id
      and candidate_form_session_id=p_candidate_form_session_id
      and actor_auth_user_id=v_auth_uid for update;
  if not found then return jsonb_build_object('success',false,'error_code','NOT_FOUND','message','Upload reservation not found or access denied'); end if;
  if v_reservation.status_code not in ('RESERVED','UPLOADED') then return jsonb_build_object('success',false,'error_code','INVALID_STATE','message','Upload reservation is not inspectable'); end if;
  if v_reservation.expires_at<=clock_timestamp() then return jsonb_build_object('success',false,'error_code','UPLOAD_RESERVATION_EXPIRED','message','Upload reservation has expired'); end if;
  return jsonb_build_object('success',true,'data',jsonb_build_object('candidate_form_session_id',p_candidate_form_session_id,'upload_reservation_id',p_upload_reservation_id));
end;
$$;

revoke all on function public.authorize_candidate_upload_scan(uuid,uuid) from public,anon;
grant execute on function public.authorize_candidate_upload_scan(uuid,uuid) to authenticated;
