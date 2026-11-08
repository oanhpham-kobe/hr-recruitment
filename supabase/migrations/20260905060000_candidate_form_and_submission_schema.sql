-- App Tuyển dụng EIU — Candidate Form & Submission Schema Migration
-- Slice 02 / TASK-S02-001: Master data, Privacy notices, Form sessions, Upload reservations, Submissions, Documents
-- Source authority:
--   recruitment_webapp/review_pack/database_schema.sql
--   recruitment_webapp/review_pack/40_DATABASE_INVARIANTS.md
--   recruitment_webapp/review_pack/39_SECURITY_RLS_MATRIX.md
--   recruitment_webapp/review_pack/59_RLS_POLICY_BLUEPRINT.md

-- -----------------------------------------------------------------------------
-- 1. Master Data
-- -----------------------------------------------------------------------------
create table if not exists public.recruitment_sources (
  recruitment_source_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.document_types (
  document_type_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  scope_code text not null check (scope_code in ('SUBMISSION','INTERVIEW','BOTH')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.qualification_levels (
  qualification_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

-- -----------------------------------------------------------------------------
-- 2. Privacy Notices
-- -----------------------------------------------------------------------------
create table if not exists public.privacy_notice_versions (
  notice_version text primary key,
  content_vi text not null,
  content_en text,
  content_hash_sha256 text not null check (content_hash_sha256 ~ '^[0-9A-Fa-f]{64}$'),
  published_at timestamptz not null default now(),
  effective_from timestamptz not null default now(),
  is_current boolean not null default false,
  created_by uuid references public.app_users(app_user_id) on delete restrict
);

create unique index if not exists one_current_privacy_notice_uq
  on public.privacy_notice_versions ((is_current))
  where is_current = true;

create index if not exists privacy_notice_versions_created_by_idx
  on public.privacy_notice_versions(created_by);

-- -----------------------------------------------------------------------------
-- 3. Submissions & Children
-- -----------------------------------------------------------------------------
create table if not exists public.submissions (
  submission_id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(candidate_id) on delete restrict,
  status_code text not null default 'NEW' check (status_code in ('NEW','READ','PROCESSED','DONE','CLOSED')),
  full_name text not null,
  date_of_birth date not null,
  gender_code text not null check (gender_code in ('MALE','FEMALE')),
  current_address text not null,
  phone text not null,
  email_snapshot extensions.citext not null,
  recruitment_source_id uuid references public.recruitment_sources(recruitment_source_id) on delete restrict,
  other_info text,
  hr_note text,
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by_internal_user_id uuid references public.app_users(app_user_id) on delete restrict,
  updated_by_candidate_id uuid references public.candidates(candidate_id) on delete restrict,
  version_no bigint not null default 1,
  constraint submission_updater_ck check (
    (updated_by_internal_user_id is not null)::int + (updated_by_candidate_id is not null)::int <= 1
  )
);

create index if not exists submissions_candidate_idx
  on public.submissions(candidate_id, submitted_at desc);
create index if not exists submissions_status_idx
  on public.submissions(status_code, submitted_at desc);
create index if not exists submissions_email_lower_idx
  on public.submissions((lower(email_snapshot::text)));
create index if not exists submissions_phone_digits_idx
  on public.submissions((regexp_replace(phone, '[^0-9]', '', 'g')));
create index if not exists submissions_full_name_trgm_idx
  on public.submissions using gin (full_name extensions.gin_trgm_ops);
create index if not exists submissions_recruitment_source_idx
  on public.submissions(recruitment_source_id);
create index if not exists submissions_updated_by_internal_idx
  on public.submissions(updated_by_internal_user_id);
create index if not exists submissions_updated_by_candidate_idx
  on public.submissions(updated_by_candidate_id);

create table if not exists public.submission_education (
  education_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete cascade,
  sort_order integer not null default 1 check (sort_order > 0),
  period_text text,
  qualification_id uuid references public.qualification_levels(qualification_id) on delete restrict,
  major text,
  institution text
);

create index if not exists submission_education_submission_idx
  on public.submission_education(submission_id, sort_order);
create index if not exists submission_education_qualification_idx
  on public.submission_education(qualification_id);

create table if not exists public.submission_work_experiences (
  experience_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete cascade,
  sort_order integer not null default 1 check (sort_order > 0),
  start_date date,
  end_date date,
  is_current boolean not null default false,
  employer text,
  job_title text,
  job_description text
);

create index if not exists submission_work_experiences_submission_idx
  on public.submission_work_experiences(submission_id, sort_order);

create table if not exists public.submission_activities (
  activity_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete cascade,
  sort_order integer not null default 1 check (sort_order > 0),
  period_text text,
  activity_name text,
  role_name text,
  organizer text,
  description text
);

create index if not exists submission_activities_submission_idx
  on public.submission_activities(submission_id, sort_order);

-- -----------------------------------------------------------------------------
-- 4. Document Management
-- -----------------------------------------------------------------------------
create table if not exists public.submission_document_logicals (
  logical_document_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete cascade,
  document_type_id uuid not null references public.document_types(document_type_id) on delete restrict,
  created_at timestamptz not null default now(),
  created_by_candidate_id uuid references public.candidates(candidate_id) on delete restrict,
  created_by_app_user_id uuid references public.app_users(app_user_id) on delete restrict,
  constraint one_submission_logical_creator_ck check (
    (created_by_candidate_id is not null)::int + (created_by_app_user_id is not null)::int = 1
  )
);

create index if not exists submission_document_logicals_parent_idx
  on public.submission_document_logicals(submission_id, document_type_id);
create index if not exists submission_document_logicals_created_cand_idx
  on public.submission_document_logicals(created_by_candidate_id);
create index if not exists submission_document_logicals_created_user_idx
  on public.submission_document_logicals(created_by_app_user_id);

create table if not exists public.submission_documents (
  document_id uuid primary key default gen_random_uuid(),
  logical_document_id uuid not null references public.submission_document_logicals(logical_document_id) on delete cascade,
  storage_bucket text not null,
  storage_path text not null unique,
  original_filename text not null check (char_length(original_filename) <= 255),
  mime_type text not null check (mime_type in (
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'image/png','image/jpeg'
  )),
  file_size_bytes bigint not null check (file_size_bytes > 0 and file_size_bytes <= 5242880),
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9A-Fa-f]{64}$'),
  malware_scan_status text not null default 'CLEAN' check (malware_scan_status = 'CLEAN'),
  exif_stripped boolean,
  version_no integer not null default 1 check (version_no > 0),
  is_current boolean not null default true,
  uploaded_by_candidate_id uuid references public.candidates(candidate_id) on delete restrict,
  uploaded_by_app_user_id uuid references public.app_users(app_user_id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  constraint one_document_uploader_ck check (
    (uploaded_by_candidate_id is not null)::int + (uploaded_by_app_user_id is not null)::int = 1
  ),
  unique(logical_document_id, version_no)
);

create unique index if not exists submission_current_logical_document_uq
  on public.submission_documents(logical_document_id)
  where is_current = true;

create index if not exists submission_documents_uploader_cand_idx
  on public.submission_documents(uploaded_by_candidate_id);
create index if not exists submission_documents_uploader_user_idx
  on public.submission_documents(uploaded_by_app_user_id);

-- -----------------------------------------------------------------------------
-- 5. Staged Form Sessions & Upload Reservations
-- -----------------------------------------------------------------------------
create table if not exists public.candidate_form_sessions (
  candidate_form_session_id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(candidate_id) on delete cascade,
  mode_code text not null check (mode_code in ('NEW_SUBMISSION','EDIT_SUBMISSION')),
  target_submission_id uuid references public.submissions(submission_id) on delete cascade,
  base_submission_version_no bigint,
  presented_privacy_notice_version text not null references public.privacy_notice_versions(notice_version) on delete restrict,
  status_code text not null default 'OPEN' check (status_code in ('OPEN','SUBMITTED','CANCELLED','EXPIRED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  version_no bigint not null default 1,
  constraint candidate_form_target_ck check (
    (mode_code = 'NEW_SUBMISSION' and target_submission_id is null and base_submission_version_no is null)
    or (mode_code = 'EDIT_SUBMISSION' and target_submission_id is not null and base_submission_version_no is not null)
  )
);

create index if not exists candidate_form_sessions_candidate_idx
  on public.candidate_form_sessions(candidate_id, created_at desc);
create index if not exists candidate_form_sessions_target_idx
  on public.candidate_form_sessions(target_submission_id);
create index if not exists candidate_form_sessions_privacy_idx
  on public.candidate_form_sessions(presented_privacy_notice_version);

create table if not exists public.upload_reservations (
  upload_reservation_id uuid primary key default gen_random_uuid(),
  candidate_form_session_id uuid references public.candidate_form_sessions(candidate_form_session_id) on delete cascade,
  interview_id uuid,
  intended_document_type_id uuid not null references public.document_types(document_type_id) on delete restrict,
  temp_bucket text not null,
  temp_path text not null unique,
  original_filename text not null check (char_length(original_filename) <= 255),
  declared_mime_type text,
  detected_mime_type text,
  expected_max_size_bytes bigint not null default 5242880 check (expected_max_size_bytes > 0 and expected_max_size_bytes <= 5242880),
  actual_size_bytes bigint,
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9A-Fa-f]{64}$'),
  malware_scan_status text not null default 'PENDING' check (malware_scan_status in ('PENDING','CLEAN','INFECTED','ERROR')),
  status_code text not null default 'RESERVED' check (status_code in ('RESERVED','UPLOADED','VALIDATED','FINALIZED','EXPIRED','REJECTED','CANCELLED')),
  actor_auth_user_id uuid not null,
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint upload_reservation_parent_ck check (
    (candidate_form_session_id is not null)::int + (interview_id is not null)::int = 1
  ),
  unique(actor_auth_user_id, idempotency_key)
);

create index if not exists upload_reservations_session_idx
  on public.upload_reservations(candidate_form_session_id);
create index if not exists upload_reservations_intended_type_idx
  on public.upload_reservations(intended_document_type_id);
create index if not exists upload_reservations_actor_idx
  on public.upload_reservations(actor_auth_user_id);

create table if not exists public.candidate_form_document_changes (
  candidate_form_document_change_id uuid primary key default gen_random_uuid(),
  candidate_form_session_id uuid not null references public.candidate_form_sessions(candidate_form_session_id) on delete cascade,
  action_code text not null check (action_code in ('ADD','REPLACE','DELETE')),
  target_logical_document_id uuid references public.submission_document_logicals(logical_document_id) on delete restrict,
  upload_reservation_id uuid references public.upload_reservations(upload_reservation_id) on delete set null,
  document_type_id uuid references public.document_types(document_type_id) on delete restrict,
  intended_document_type_id uuid references public.document_types(document_type_id) on delete restrict,
  status_code text not null default 'PENDING' check (status_code in ('PENDING','APPLIED','CANCELLED')),
  created_at timestamptz not null default now()
);

create index if not exists candidate_form_document_changes_session_idx
  on public.candidate_form_document_changes(candidate_form_session_id);
create index if not exists candidate_form_document_changes_target_idx
  on public.candidate_form_document_changes(target_logical_document_id);
create index if not exists candidate_form_document_changes_reservation_idx
  on public.candidate_form_document_changes(upload_reservation_id);
create index if not exists candidate_form_document_changes_doc_type_idx
  on public.candidate_form_document_changes(document_type_id);
create index if not exists candidate_form_document_changes_intended_type_idx
  on public.candidate_form_document_changes(intended_document_type_id);

-- Keep document_type_id and intended_document_type_id in sync regardless of which identifier caller writes
create or replace function private.sync_candidate_form_doc_change_type()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.intended_document_type_id is null and new.document_type_id is not null then
    new.intended_document_type_id := new.document_type_id;
  elsif new.document_type_id is null and new.intended_document_type_id is not null then
    new.document_type_id := new.intended_document_type_id;
  end if;
  return new;
end;
$$;

revoke all on function private.sync_candidate_form_doc_change_type() from public, anon, authenticated;
grant execute on function private.sync_candidate_form_doc_change_type() to postgres, service_role;

create trigger candidate_form_document_changes_sync_type
  before insert or update on public.candidate_form_document_changes
  for each row execute function private.sync_candidate_form_doc_change_type();

create table if not exists public.storage_cleanup_queue (
  storage_cleanup_id uuid primary key default gen_random_uuid(),
  source_type text not null check (source_type in ('CANDIDATE_FORM','INTERVIEW_UPLOAD')),
  source_parent_id uuid,
  source_upload_reservation_id uuid,
  bucket_name text not null,
  object_path text not null,
  reason_code text not null,
  status_code text not null default 'PENDING' check (status_code in ('PENDING','PROCESSING','DONE','ERROR')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(bucket_name, object_path)
);

create index if not exists storage_cleanup_queue_status_idx
  on public.storage_cleanup_queue(status_code, created_at);

create table if not exists public.privacy_acknowledgements (
  privacy_acknowledgement_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete cascade,
  notice_version text not null references public.privacy_notice_versions(notice_version) on delete restrict,
  acknowledged_at timestamptz not null default now(),
  source_code text not null default 'CANDIDATE_PORTAL',
  unique(submission_id, notice_version)
);

create index if not exists privacy_acknowledgements_submission_idx
  on public.privacy_acknowledgements(submission_id);
create index if not exists privacy_acknowledgements_notice_version_idx
  on public.privacy_acknowledgements(notice_version);

-- -----------------------------------------------------------------------------
-- 6. Integrity Functions & Triggers
-- -----------------------------------------------------------------------------
create trigger submissions_touch_version
  before update on public.submissions
  for each row execute function private.touch_version();

create trigger candidate_form_sessions_touch_version
  before update on public.candidate_form_sessions
  for each row execute function private.touch_version();

create or replace function private.protect_published_privacy_notice()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.notice_version is distinct from old.notice_version
     or new.content_vi is distinct from old.content_vi
     or new.content_en is distinct from old.content_en
     or new.content_hash_sha256 is distinct from old.content_hash_sha256
     or new.published_at is distinct from old.published_at
     or new.effective_from is distinct from old.effective_from
     or new.created_by is distinct from old.created_by then
    raise exception 'PUBLISHED_PRIVACY_NOTICE_IMMUTABLE_CREATE_NEW_VERSION' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.protect_published_privacy_notice() from public, anon, authenticated;
grant execute on function private.protect_published_privacy_notice() to postgres, service_role;

create trigger privacy_notice_immutable_guard
  before update on public.privacy_notice_versions
  for each row execute function private.protect_published_privacy_notice();

create or replace function private.protect_published_privacy_notice_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'PUBLISHED_PRIVACY_NOTICE_DELETE_FORBIDDEN' using errcode = '23514';
end;
$$;

revoke all on function private.protect_published_privacy_notice_delete() from public, anon, authenticated;
grant execute on function private.protect_published_privacy_notice_delete() to postgres, service_role;

create trigger privacy_notice_delete_guard
  before delete on public.privacy_notice_versions
  for each row execute function private.protect_published_privacy_notice_delete();

create or replace function private.validate_form_session_candidate_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner_candidate uuid;
begin
  if new.mode_code = 'EDIT_SUBMISSION' then
    select candidate_id into owner_candidate
    from public.submissions
    where submission_id = new.target_submission_id;

    if owner_candidate is null or owner_candidate is distinct from new.candidate_id then
      raise exception 'FORM_SESSION_SUBMISSION_CANDIDATE_MISMATCH' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.validate_form_session_candidate_owner() from public, anon, authenticated;
grant execute on function private.validate_form_session_candidate_owner() to postgres, service_role;

create trigger candidate_form_session_owner_guard
  before insert or update of candidate_id, target_submission_id, mode_code on public.candidate_form_sessions
  for each row execute function private.validate_form_session_candidate_owner();

-- -----------------------------------------------------------------------------
-- 7. Row Level Security & Minimal Grants
-- -----------------------------------------------------------------------------
alter table public.recruitment_sources enable row level security;
alter table public.document_types enable row level security;
alter table public.qualification_levels enable row level security;
alter table public.privacy_notice_versions enable row level security;
alter table public.submissions enable row level security;
alter table public.submission_education enable row level security;
alter table public.submission_work_experiences enable row level security;
alter table public.submission_activities enable row level security;
alter table public.submission_document_logicals enable row level security;
alter table public.submission_documents enable row level security;
alter table public.candidate_form_sessions enable row level security;
alter table public.upload_reservations enable row level security;
alter table public.candidate_form_document_changes enable row level security;
alter table public.storage_cleanup_queue enable row level security;
alter table public.privacy_acknowledgements enable row level security;

-- Revoke direct DML from client roles
revoke insert, update, delete on public.recruitment_sources, public.document_types, public.qualification_levels from anon, authenticated;
revoke insert, update, delete on public.privacy_notice_versions from anon, authenticated;
revoke insert, update, delete on public.submissions, public.candidate_form_sessions, public.upload_reservations, public.submission_documents, public.privacy_acknowledgements from anon, authenticated;
revoke insert, update, delete on public.submission_education, public.submission_work_experiences, public.submission_activities, public.submission_document_logicals, public.candidate_form_document_changes, public.storage_cleanup_queue from anon, authenticated;

-- Master data read grants
grant select on public.recruitment_sources, public.document_types, public.qualification_levels, public.privacy_notice_versions to anon, authenticated;

-- Transactional tables read grants (RLS policy restricts row visibility; anon denied via to authenticated policies)
grant select on public.candidate_form_sessions, public.upload_reservations, public.submissions, public.submission_education, public.submission_work_experiences, public.submission_activities, public.submission_document_logicals, public.submission_documents, public.candidate_form_document_changes, public.privacy_acknowledgements to authenticated, anon;
grant select on public.storage_cleanup_queue to authenticated;

-- Full grants to trusted service and administration roles
grant all on public.recruitment_sources to postgres, service_role;
grant all on public.document_types to postgres, service_role;
grant all on public.qualification_levels to postgres, service_role;
grant all on public.privacy_notice_versions to postgres, service_role;
grant all on public.submissions to postgres, service_role;
grant all on public.submission_education to postgres, service_role;
grant all on public.submission_work_experiences to postgres, service_role;
grant all on public.submission_activities to postgres, service_role;
grant all on public.submission_document_logicals to postgres, service_role;
grant all on public.submission_documents to postgres, service_role;
grant all on public.candidate_form_sessions to postgres, service_role;
grant all on public.upload_reservations to postgres, service_role;
grant all on public.candidate_form_document_changes to postgres, service_role;
grant all on public.storage_cleanup_queue to postgres, service_role;
grant all on public.privacy_acknowledgements to postgres, service_role;

-- SELECT Policies:
-- Master data & privacy notices (anon sees active/current; authenticated checks view permissions or root admin)
create policy recruitment_sources_anon_select on public.recruitment_sources
  for select to anon using (is_active = true);

create policy recruitment_sources_authenticated_select on public.recruitment_sources
  for select to authenticated using (is_active = true or private.has_permission('submissions.view') or private.is_root_admin());

create policy document_types_anon_select on public.document_types
  for select to anon using (is_active = true);

create policy document_types_authenticated_select on public.document_types
  for select to authenticated using (is_active = true or private.has_permission('submissions.view') or private.is_root_admin());

create policy qualification_levels_anon_select on public.qualification_levels
  for select to anon using (is_active = true);

create policy qualification_levels_authenticated_select on public.qualification_levels
  for select to authenticated using (is_active = true or private.has_permission('submissions.view') or private.is_root_admin());

create policy privacy_notice_anon_read on public.privacy_notice_versions
  for select to anon using (is_current = true);

create policy privacy_notice_authenticated_read on public.privacy_notice_versions
  for select to authenticated using (is_current = true or private.is_root_admin());

-- Transactional tables policies (authenticated users only; anon receives 0 rows under RLS)
create policy candidate_form_sessions_candidate_select on public.candidate_form_sessions
  for select to authenticated using (candidate_id = private.current_candidate_id() or private.is_root_admin());

create policy upload_reservations_select on public.upload_reservations
  for select to authenticated using (actor_auth_user_id = (select auth.uid()) or private.is_root_admin());

create policy submissions_select on public.submissions
  for select to authenticated using (candidate_id = private.current_candidate_id() or private.has_permission('submissions.view'));

create policy submission_education_select on public.submission_education
  for select to authenticated using (
    exists (
      select 1 from public.submissions s
      where s.submission_id = submission_education.submission_id
        and (s.candidate_id = private.current_candidate_id() or private.has_permission('submissions.view'))
    )
  );

create policy submission_work_experiences_select on public.submission_work_experiences
  for select to authenticated using (
    exists (
      select 1 from public.submissions s
      where s.submission_id = submission_work_experiences.submission_id
        and (s.candidate_id = private.current_candidate_id() or private.has_permission('submissions.view'))
    )
  );

create policy submission_activities_select on public.submission_activities
  for select to authenticated using (
    exists (
      select 1 from public.submissions s
      where s.submission_id = submission_activities.submission_id
        and (s.candidate_id = private.current_candidate_id() or private.has_permission('submissions.view'))
    )
  );

create policy submission_document_logicals_select on public.submission_document_logicals
  for select to authenticated using (
    exists (
      select 1 from public.submissions s
      where s.submission_id = submission_document_logicals.submission_id
        and (s.candidate_id = private.current_candidate_id() or private.has_permission('submissions.view'))
    )
  );

create policy submission_documents_select on public.submission_documents
  for select to authenticated using (
    exists (
      select 1 from public.submission_document_logicals l
      join public.submissions s on s.submission_id = l.submission_id
      where l.logical_document_id = submission_documents.logical_document_id
        and (s.candidate_id = private.current_candidate_id() or private.has_permission('submissions.view'))
    )
  );

create policy candidate_form_document_changes_select on public.candidate_form_document_changes
  for select to authenticated using (
    exists (
      select 1 from public.candidate_form_sessions s
      where s.candidate_form_session_id = candidate_form_document_changes.candidate_form_session_id
        and (s.candidate_id = private.current_candidate_id() or private.is_root_admin())
    )
  );

create policy privacy_acknowledgements_select on public.privacy_acknowledgements
  for select to authenticated using (
    exists (
      select 1 from public.submissions s
      where s.submission_id = privacy_acknowledgements.submission_id
        and (s.candidate_id = private.current_candidate_id() or private.has_permission('submissions.view'))
    )
  );

create policy storage_cleanup_queue_select on public.storage_cleanup_queue
  for select to authenticated using (private.is_root_admin());
