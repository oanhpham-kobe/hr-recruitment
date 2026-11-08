-- App Tuyển dụng EIU
-- Technical starter schema v1.18 — 2026-09-06
-- IMPORTANT: This is a reviewed implementation starter, NOT a production migration bundle.
-- Production requires the RLS/GRANT/RPC/security tests in CURRENT/NORMATIVE entries of source_registry.yaml plus the current implementation gate. Owner decisions 1–4 are closed; official PDF layout is deferred.

create extension if not exists pgcrypto;
create extension if not exists citext;
create extension if not exists pg_trgm;
create extension if not exists unaccent;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
create or replace function private.touch_version()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.version_no := coalesce(old.version_no, 0) + 1;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Master data / internal directory
-- -----------------------------------------------------------------------------
create table if not exists public.organizational_units (
  unit_id uuid primary key default gen_random_uuid(),
  code text unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.department_teams (
  department_team_id uuid primary key default gen_random_uuid(),
  constraint department_team_zero_uuid_reserved_ck check (department_team_id <> '00000000-0000-0000-0000-000000000000'::uuid),
  unit_id uuid not null references public.organizational_units(unit_id) on delete restrict,
  code text,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1,
  unique(unit_id, code)
);

create table if not exists public.position_groups (
  position_group_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  requires_demo_topic boolean not null default false,
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

create table if not exists public.cancellation_reasons (
  cancellation_reason_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.rejection_reasons (
  rejection_reason_id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.positions (
  position_id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.organizational_units(unit_id) on delete restrict,
  department_team_id uuid references public.department_teams(department_team_id) on delete restrict,
  position_group_id uuid not null references public.position_groups(position_group_id) on delete restrict,
  code text,
  name_vi text not null,
  name_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.interview_formats (
  interview_format_id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name_vi text not null,
  name_en text,
  requires_room boolean not null default false,
  requires_meeting_link boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.rooms (
  room_id uuid primary key default gen_random_uuid(),
  code text unique,
  display_name text not null,
  building text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1
);

create table if not exists public.app_users (
  app_user_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,
  email citext not null unique,
  full_name text not null,
  job_title text,
  unit_id uuid references public.organizational_units(unit_id) on delete restrict,
  is_active boolean not null default true,
  is_root_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1,
  constraint internal_email_domain_ck check (lower(email::text) ~ '^[^@[:space:]]+@eiu\.edu\.vn$')
);

-- At most one root admin. Bootstrap/protection procedures must also guarantee one exists after bootstrap.
create unique index if not exists one_root_admin_uq
  on public.app_users ((is_root_admin))
  where is_root_admin = true;

create table if not exists public.app_user_roles (
  app_user_id uuid not null references public.app_users(app_user_id) on delete restrict,
  role_code text not null check (role_code in ('HR')),
  created_at timestamptz not null default now(),
  primary key (app_user_id, role_code)
);

create table if not exists public.permissions (
  permission_code text primary key,
  description text not null
);

create table if not exists public.app_user_permissions (
  app_user_id uuid not null references public.app_users(app_user_id) on delete restrict,
  permission_code text not null references public.permissions(permission_code) on delete restrict,
  granted_by uuid references public.app_users(app_user_id) on delete restrict,
  granted_at timestamptz not null default now(),
  primary key (app_user_id, permission_code)
);

create table if not exists public.permission_dependencies (
  permission_code text not null references public.permissions(permission_code) on delete cascade,
  requires_permission_code text not null references public.permissions(permission_code) on delete cascade,
  primary key (permission_code, requires_permission_code),
  constraint permission_dependency_not_self_ck check (permission_code <> requires_permission_code)
);

-- -----------------------------------------------------------------------------
-- Candidate / Submission
-- -----------------------------------------------------------------------------
create table if not exists public.candidates (
  candidate_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  email citext not null unique,
  current_full_name text,
  current_phone text,
  last_submission_at timestamptz,
  is_active boolean not null default true,
  inactive_at timestamptz,
  inactive_by uuid references public.app_users(app_user_id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version_no bigint not null default 1,
  constraint candidate_inactive_metadata_ck check (
    (is_active = true and inactive_at is null and inactive_by is null)
    or (is_active = false and inactive_at is not null and inactive_by is not null)
  )
);

create table if not exists public.submissions (
  submission_id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(candidate_id) on delete restrict,
  status_code text not null default 'NEW'
    check (status_code in ('NEW','READ','PROCESSED','DONE','CLOSED')),
  full_name text not null,
  date_of_birth date not null,
  gender_code text not null check (gender_code in ('MALE','FEMALE')),
  current_address text not null,
  phone text not null,
  email_snapshot citext not null,
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

create index if not exists submissions_candidate_idx on public.submissions(candidate_id, submitted_at desc);
create index if not exists submissions_status_idx on public.submissions(status_code, submitted_at desc);
create index if not exists submissions_email_lower_idx on public.submissions((lower(email_snapshot::text)));
create index if not exists submissions_phone_digits_idx on public.submissions((regexp_replace(phone, '[^0-9]', '', 'g')));
create index if not exists submissions_full_name_trgm_idx on public.submissions using gin (full_name gin_trgm_ops);

create table if not exists public.submission_education (
  education_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete cascade,
  sort_order integer not null default 1 check (sort_order > 0),
  period_text text,
  qualification_id uuid references public.qualification_levels(qualification_id) on delete restrict,
  major text,
  institution text
);

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

create table if not exists public.submission_documents (
  document_id uuid primary key default gen_random_uuid(),
  logical_document_id uuid not null references public.submission_document_logicals(logical_document_id) on delete cascade,
  storage_bucket text not null,
  storage_path text not null,
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
  unique(logical_document_id, version_no),
  unique(storage_bucket, storage_path)
);

create unique index if not exists submission_current_logical_document_uq
  on public.submission_documents(logical_document_id)
  where is_current = true;

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
  on public.privacy_notice_versions ((is_current)) where is_current = true;

-- Candidate new/edit forms use a staged session. A Submission is not created until Submit.
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
  constraint candidate_form_target_ck check (
    (mode_code = 'NEW_SUBMISSION' and target_submission_id is null and base_submission_version_no is null)
    or (mode_code = 'EDIT_SUBMISSION' and target_submission_id is not null and base_submission_version_no is not null)
  )
);

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

-- Durable object-storage cleanup intent. It intentionally snapshots parent/reservation IDs without FKs
-- so cleanup remains actionable after a trusted hard-delete commits.
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

create table if not exists public.candidate_form_document_changes (
  candidate_form_document_change_id uuid primary key default gen_random_uuid(),
  candidate_form_session_id uuid not null references public.candidate_form_sessions(candidate_form_session_id) on delete cascade,
  action_code text not null check (action_code in ('ADD','REPLACE','DELETE')),
  target_logical_document_id uuid references public.submission_document_logicals(logical_document_id) on delete restrict,
  intended_document_type_id uuid not null references public.document_types(document_type_id) on delete restrict,
  upload_reservation_id uuid references public.upload_reservations(upload_reservation_id) on delete restrict,
  status_code text not null default 'PENDING' check (status_code in ('PENDING','APPLIED','CANCELLED')),
  created_at timestamptz not null default now(),
  constraint candidate_document_change_shape_ck check (
    (action_code = 'DELETE' and target_logical_document_id is not null and upload_reservation_id is null)
    or (action_code = 'ADD' and target_logical_document_id is null and upload_reservation_id is not null)
    or (action_code = 'REPLACE' and target_logical_document_id is not null and upload_reservation_id is not null)
  )
);

-- A logical document can have at most one pending edit in the same form session.
create unique index if not exists candidate_form_pending_target_uq
  on public.candidate_form_document_changes(candidate_form_session_id, target_logical_document_id)
  where status_code = 'PENDING' and target_logical_document_id is not null;

-- One temp upload reservation may back only one staged document mutation.
create unique index if not exists candidate_form_upload_reservation_uq
  on public.candidate_form_document_changes(upload_reservation_id)
  where upload_reservation_id is not null;

-- -----------------------------------------------------------------------------
-- Application / Interview rounds
-- -----------------------------------------------------------------------------
create table if not exists public.applications (
  application_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete restrict,
  unit_id uuid not null references public.organizational_units(unit_id) on delete restrict,
  department_team_id uuid references public.department_teams(department_team_id) on delete restrict,
  position_id uuid not null references public.positions(position_id) on delete restrict,
  hr_owner_id uuid not null references public.app_users(app_user_id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(app_user_id) on delete restrict,
  version_no bigint not null default 1
);

-- candidate_id is intentionally NOT duplicated here. Candidate is derived via Submission.
-- ZERO UUID is reserved as the NULL-team sentinel for durable identity and must never be used as a real master PK.
create unique index if not exists application_durable_identity_uq
  on public.applications(
    submission_id,
    unit_id,
    coalesce(department_team_id, '00000000-0000-0000-0000-000000000000'::uuid),
    position_id
  );

create index if not exists applications_submission_idx on public.applications(submission_id);
create index if not exists applications_hr_owner_idx on public.applications(hr_owner_id) where is_active = true;

create table if not exists public.interviews (
  interview_id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(application_id) on delete restrict,
  round_no integer not null check (round_no > 0),
  demo_topic text,
  start_at timestamptz,
  end_at timestamptz,
  interview_format_id uuid references public.interview_formats(interview_format_id) on delete restrict,
  room_id uuid references public.rooms(room_id) on delete restrict,
  meeting_link text,
  schedule_status_code text not null default 'AVAILABLE'
    check (schedule_status_code in ('AVAILABLE','SCHEDULED','AWAITING','CONFIRMED','CANCELLED')),
  report_status_code text not null default 'INTERVIEW_SCHEDULING'
    check (report_status_code in ('INTERVIEW_SCHEDULING','AWAITING_INTERVIEW','WAITING_FOR_REPORT','REPORT_SUBMITTED','FOLLOW_UP','ON_HOLD','HIRED','REJECTED')),
  cancellation_reason_id uuid references public.cancellation_reasons(cancellation_reason_id) on delete restrict,
  rejection_reason_id uuid references public.rejection_reasons(rejection_reason_id) on delete restrict,
  visible_to_interviewers boolean not null default true,
  interview_note text,
  hr_report_note text,
  copied_from_interview_id uuid references public.interviews(interview_id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(app_user_id) on delete restrict,
  version_no bigint not null default 1,
  constraint interview_time_range_ck check (start_at is null or end_at is null or start_at < end_at),
  unique(application_id, round_no)
);

create index if not exists interviews_application_idx on public.interviews(application_id, round_no desc);
create index if not exists interviews_time_idx on public.interviews(start_at, end_at) where is_active = true;
create index if not exists interviews_room_time_idx on public.interviews(room_id, start_at, end_at) where is_active = true and room_id is not null;

alter table public.upload_reservations
  drop constraint if exists upload_reservations_interview_fk;
alter table public.upload_reservations
  add constraint upload_reservations_interview_fk foreign key (interview_id) references public.interviews(interview_id) on delete restrict;

create index if not exists upload_reservations_interview_idx
  on public.upload_reservations(interview_id) where interview_id is not null;

create table if not exists public.interview_participants (
  interview_participant_id uuid primary key default gen_random_uuid(),
  interview_id uuid not null references public.interviews(interview_id) on delete restrict,
  app_user_id uuid not null references public.app_users(app_user_id) on delete restrict,
  participant_order integer not null check (participant_order > 0),
  snapshot_name text not null,
  snapshot_job_title text,
  snapshot_email citext not null,
  is_current boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  removed_at timestamptz,
  version_no bigint not null default 1
);

create unique index if not exists current_participant_user_uq
  on public.interview_participants(interview_id, app_user_id)
  where is_current = true;

create unique index if not exists current_participant_order_uq
  on public.interview_participants(interview_id, participant_order)
  where is_current = true;

create index if not exists participant_user_idx on public.interview_participants(app_user_id, interview_id) where is_current = true;

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
    'image/png','image/jpeg'
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

-- -----------------------------------------------------------------------------
-- Email / audit / idempotency
-- -----------------------------------------------------------------------------
create table if not exists public.email_outbox (
  email_outbox_id uuid primary key default gen_random_uuid(),
  interview_id uuid references public.interviews(interview_id) on delete restrict,
  application_id uuid references public.applications(application_id) on delete restrict,
  submission_id uuid references public.submissions(submission_id) on delete restrict,
  email_type text not null,
  environment_code text not null default 'PRODUCTION' check (environment_code in ('PRODUCTION','TEST')),
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

alter table public.email_outbox add constraint email_outbox_one_human_actor_ck check ((created_by_app_user_id is not null)::int + (created_by_candidate_id is not null)::int <= 1);

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

create table if not exists public.activity_log (
  activity_id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id uuid not null,
  action_code text not null,
  actor_app_user_id uuid references public.app_users(app_user_id) on delete set null,
  actor_candidate_id uuid references public.candidates(candidate_id) on delete set null,
  old_values jsonb,
  new_values jsonb,
  request_id uuid,
  correlation_id uuid,
  source_code text not null default 'WEB' check (source_code in ('WEB','RPC','SYSTEM','WORKER')),
  reason text,
  created_at timestamptz not null default now(),
  constraint activity_one_human_actor_ck check ((actor_app_user_id is not null)::int + (actor_candidate_id is not null)::int <= 1)
);

create table if not exists public.security_audit_log (
  audit_id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  actor_auth_user_id uuid,
  actor_app_user_id uuid references public.app_users(app_user_id) on delete set null,
  actor_candidate_id uuid references public.candidates(candidate_id) on delete set null,
  action_code text not null,
  entity_type text,
  entity_id uuid,
  request_id uuid,
  correlation_id uuid,
  source_code text not null default 'WEB' check (source_code in ('WEB','RPC','SYSTEM','WORKER')),
  result_code text not null default 'SUCCESS' check (result_code in ('SUCCESS','DENIED','FAILED')),
  reason text,
  diff jsonb,
  metadata jsonb,
  constraint security_audit_one_human_actor_ck check ((actor_app_user_id is not null)::int + (actor_candidate_id is not null)::int <= 1)
);

create index if not exists security_audit_entity_idx on public.security_audit_log(entity_type, entity_id, occurred_at desc);
create index if not exists security_audit_actor_idx on public.security_audit_log(actor_app_user_id, occurred_at desc);

create table if not exists public.privacy_acknowledgements (
  privacy_acknowledgement_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(submission_id) on delete cascade,
  notice_version text not null references public.privacy_notice_versions(notice_version) on delete restrict,
  acknowledged_at timestamptz not null default now(),
  source_code text not null default 'CANDIDATE_PORTAL',
  unique(submission_id, notice_version)
);

create table if not exists public.idempotency_records (
  idempotency_record_id uuid primary key default gen_random_uuid(),
  actor_scope text not null,
  command_type text not null,
  idempotency_key uuid not null,
  result_entity_type text,
  result_entity_id uuid,
  result_payload jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  unique(actor_scope, command_type, idempotency_key)
);

-- -----------------------------------------------------------------------------
-- Integrity triggers
-- -----------------------------------------------------------------------------
create or replace function private.validate_submission_document_logical()
returns trigger
language plpgsql
set search_path = ''
as $$
declare scope text; active_flag boolean;
begin
  select d.scope_code, d.is_active into scope, active_flag
  from public.document_types d where d.document_type_id = new.document_type_id;
  if not found then raise exception 'document type not found' using errcode = '23503'; end if;
  if tg_op = 'INSERT' and not active_flag then raise exception 'inactive document type cannot be selected' using errcode = '23514'; end if;
  if scope not in ('SUBMISSION','BOTH') then raise exception 'document type scope is not valid for Submission' using errcode = '23514'; end if;
  if tg_op = 'UPDATE' and (new.document_type_id is distinct from old.document_type_id or new.submission_id is distinct from old.submission_id) then
    raise exception 'logical document parent/type is immutable; create a new logical document' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.validate_interview_document_logical()
returns trigger
language plpgsql
set search_path = ''
as $$
declare scope text; active_flag boolean;
begin
  select d.scope_code, d.is_active into scope, active_flag
  from public.document_types d where d.document_type_id = new.document_type_id;
  if not found then raise exception 'document type not found' using errcode = '23503'; end if;
  if tg_op = 'INSERT' and not active_flag then raise exception 'inactive document type cannot be selected' using errcode = '23514'; end if;
  if scope not in ('INTERVIEW','BOTH') then raise exception 'document type scope is not valid for Interview' using errcode = '23514'; end if;
  if tg_op = 'UPDATE' and (new.document_type_id is distinct from old.document_type_id or new.interview_id is distinct from old.interview_id) then
    raise exception 'logical document parent/type is immutable; create a new logical document' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger submission_document_logical_scope_guard
  before insert or update on public.submission_document_logicals
  for each row execute function private.validate_submission_document_logical();

create trigger interview_document_logical_scope_guard
  before insert or update on public.interview_document_logicals
  for each row execute function private.validate_interview_document_logical();

create or replace function private.validate_candidate_form_session_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status_code is distinct from new.status_code then
    if old.status_code <> 'OPEN' or new.status_code not in ('SUBMITTED','CANCELLED','EXPIRED') then
      raise exception 'CANDIDATE_FORM_SESSION_INVALID_TRANSITION' using errcode = '23514';
    end if;
    new.updated_at := transaction_timestamp();
  end if;
  return new;
end;
$$;

create trigger candidate_form_session_transition_guard
  before update of status_code on public.candidate_form_sessions
  for each row execute function private.validate_candidate_form_session_transition();

create or replace function private.validate_candidate_form_document_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  form_mode text;
  form_status text;
  form_expires_at timestamptz;
  target_submission uuid;
  logical_submission uuid;
  logical_type uuid;
  current_version_count integer;
  reservation_session uuid;
  reservation_type uuid;
  reservation_status text;
  reservation_expires_at timestamptz;
  doc_scope text;
  doc_active boolean;
begin
  select fs.mode_code, fs.status_code, fs.expires_at, fs.target_submission_id
    into form_mode, form_status, form_expires_at, target_submission
  from public.candidate_form_sessions fs
  where fs.candidate_form_session_id = new.candidate_form_session_id;
  if not found then raise exception 'candidate form session not found' using errcode = '23503'; end if;
  if form_status <> 'OPEN' then
    raise exception 'document changes require an OPEN candidate form session' using errcode = '23514';
  end if;
  if form_expires_at <= transaction_timestamp() then
    raise exception 'FORM_SESSION_EXPIRED' using errcode = '23514';
  end if;

  -- A brand-new Submission has no persisted logical documents to replace/delete.
  if form_mode = 'NEW_SUBMISSION' and new.action_code <> 'ADD' then
    raise exception 'new Submission form only supports staged ADD document actions' using errcode = '23514';
  end if;

  select d.scope_code, d.is_active into doc_scope, doc_active
  from public.document_types d where d.document_type_id = new.intended_document_type_id;
  if not found then raise exception 'document type not found' using errcode = '23503'; end if;
  if doc_scope not in ('SUBMISSION','BOTH') then
    raise exception 'document type is not valid for Submission documents' using errcode = '23514';
  end if;
  if new.action_code = 'ADD' and not doc_active then
    raise exception 'inactive document type cannot be selected for a new document' using errcode = '23514';
  end if;

  if new.target_logical_document_id is not null then
    select l.submission_id, l.document_type_id into logical_submission, logical_type
    from public.submission_document_logicals l where l.logical_document_id = new.target_logical_document_id;
    if not found or target_submission is null or logical_submission is distinct from target_submission then
      raise exception 'target logical document does not belong to edit Submission' using errcode = '23514';
    end if;
    if logical_type is distinct from new.intended_document_type_id then
      raise exception 'replace/delete document type must match logical header type' using errcode = '23514';
    end if;
    if new.action_code in ('REPLACE','DELETE') then
      select count(*) into current_version_count
      from public.submission_documents v
      where v.logical_document_id = new.target_logical_document_id and v.is_current = true;
      if current_version_count <> 1 then
        raise exception 'INVALID_DOCUMENT_TARGET: replace/delete requires exactly one current version' using errcode = '23514';
      end if;
    end if;
  end if;

  if new.upload_reservation_id is not null then
    select u.candidate_form_session_id, u.intended_document_type_id, u.status_code, u.expires_at
      into reservation_session, reservation_type, reservation_status, reservation_expires_at
    from public.upload_reservations u where u.upload_reservation_id = new.upload_reservation_id;
    if not found or reservation_session is distinct from new.candidate_form_session_id then
      raise exception 'upload reservation does not belong to candidate form session' using errcode = '23514';
    end if;
    if reservation_type is distinct from new.intended_document_type_id then
      raise exception 'upload reservation document type mismatch' using errcode = '23514';
    end if;
    if reservation_status not in ('UPLOADED','VALIDATED') then
      raise exception 'upload reservation is not stageable' using errcode = '23514';
    end if;
    if reservation_expires_at <= transaction_timestamp() then
      raise exception 'UPLOAD_RESERVATION_EXPIRED' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

-- Called by Submit/Save RPC after locking the OPEN form session. This validates the
-- effective document plan before any staged mutation is committed to the Submission.
create or replace function private.validate_candidate_form_document_plan(p_candidate_form_session_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  form_mode text;
  form_status text;
  form_expires_at timestamptz;
  target_submission uuid;
  effective_count integer;
  cv_count integer;
  unready_count integer;
  expired_reservation_count integer;
  invalid_target_count integer;
begin
  select fs.mode_code, fs.status_code, fs.expires_at, fs.target_submission_id
    into form_mode, form_status, form_expires_at, target_submission
  from public.candidate_form_sessions fs
  where fs.candidate_form_session_id = p_candidate_form_session_id
  for update;
  if not found then raise exception 'candidate form session not found' using errcode = '23503'; end if;
  if form_status <> 'OPEN' then raise exception 'candidate form session is not OPEN' using errcode = '23514'; end if;
  if form_expires_at <= transaction_timestamp() then raise exception 'FORM_SESSION_EXPIRED' using errcode = '23514'; end if;

  -- Save-time target-current invariant. Lock logical headers + current versions for every
  -- staged REPLACE/DELETE so a historical logical document cannot be resurrected and
  -- plan cardinality remains correct under concurrency.
  if form_mode = 'EDIT_SUBMISSION' then
    perform 1
    from public.submission_document_logicals l
    join public.candidate_form_document_changes c on c.target_logical_document_id = l.logical_document_id
    where c.candidate_form_session_id = p_candidate_form_session_id
      and c.status_code = 'PENDING' and c.action_code in ('REPLACE','DELETE')
    for update of l;

    perform 1
    from public.submission_documents v
    join public.candidate_form_document_changes c on c.target_logical_document_id = v.logical_document_id
    where c.candidate_form_session_id = p_candidate_form_session_id
      and c.status_code = 'PENDING' and c.action_code in ('REPLACE','DELETE')
      and v.is_current = true
    for update of v;

    select count(*) into invalid_target_count
    from public.candidate_form_document_changes c
    where c.candidate_form_session_id = p_candidate_form_session_id
      and c.status_code = 'PENDING' and c.action_code in ('REPLACE','DELETE')
      and (select count(*) from public.submission_documents v
           where v.logical_document_id = c.target_logical_document_id and v.is_current = true) <> 1;
    if invalid_target_count > 0 then
      raise exception 'INVALID_DOCUMENT_TARGET: target no longer has exactly one current version' using errcode = '23514';
    end if;
  end if;

  -- Reservation expiry is an authoritative synchronous gate, independent of cleanup timing.
  select count(*) into expired_reservation_count
  from public.candidate_form_document_changes c
  join public.upload_reservations u on u.upload_reservation_id = c.upload_reservation_id
  where c.candidate_form_session_id = p_candidate_form_session_id
    and c.status_code = 'PENDING'
    and c.action_code in ('ADD','REPLACE')
    and u.expires_at <= transaction_timestamp();
  if expired_reservation_count > 0 then
    raise exception 'UPLOAD_RESERVATION_EXPIRED' using errcode = '23514';
  end if;

  -- Every staged ADD/REPLACE must be fully validated and malware-clean at Save/Submit time.
  select count(*) into unready_count
  from public.candidate_form_document_changes c
  join public.upload_reservations u on u.upload_reservation_id = c.upload_reservation_id
  where c.candidate_form_session_id = p_candidate_form_session_id
    and c.status_code = 'PENDING'
    and c.action_code in ('ADD','REPLACE')
    and (u.status_code <> 'VALIDATED' or u.malware_scan_status <> 'CLEAN' or coalesce(u.actual_size_bytes,0) <= 0 or u.actual_size_bytes > 5242880);
  if unready_count > 0 then
    raise exception 'staged upload is not validated/CLEAN/finalizable' using errcode = '23514';
  end if;

  if form_mode = 'NEW_SUBMISSION' then
    select count(*) into effective_count
    from public.candidate_form_document_changes c
    where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING' and c.action_code = 'ADD';

    select count(*) into cv_count
    from public.candidate_form_document_changes c
    join public.document_types d on d.document_type_id = c.intended_document_type_id
    where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
      and c.action_code = 'ADD' and d.code = 'CV_RESUME';
  else
    -- Existing current logical documents, minus staged DELETE, plus staged ADD. REPLACE keeps cardinality/type.
    select
      count(*)
      - count(*) filter (where exists (
          select 1 from public.candidate_form_document_changes c
          where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
            and c.action_code = 'DELETE' and c.target_logical_document_id = l.logical_document_id
        ))
      + (select count(*) from public.candidate_form_document_changes c
         where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING' and c.action_code = 'ADD')
      into effective_count
    from public.submission_document_logicals l
    where l.submission_id = target_submission
      and exists (select 1 from public.submission_documents v where v.logical_document_id = l.logical_document_id and v.is_current = true);

    select count(*) into cv_count
    from public.submission_document_logicals l
    join public.document_types d on d.document_type_id = l.document_type_id
    where l.submission_id = target_submission and d.code = 'CV_RESUME'
      and exists (select 1 from public.submission_documents v where v.logical_document_id = l.logical_document_id and v.is_current = true)
      and not exists (
        select 1 from public.candidate_form_document_changes c
        where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
          and c.action_code = 'DELETE' and c.target_logical_document_id = l.logical_document_id
      );

    cv_count := cv_count + (
      select count(*)
      from public.candidate_form_document_changes c
      join public.document_types d on d.document_type_id = c.intended_document_type_id
      where c.candidate_form_session_id = p_candidate_form_session_id and c.status_code = 'PENDING'
        and c.action_code = 'ADD' and d.code = 'CV_RESUME'
    );
  end if;

  if effective_count > 5 then raise exception 'MAX_5_SUBMISSION_FILES' using errcode = '23514'; end if;
  if cv_count < 1 then raise exception 'CURRENT_CV_REQUIRED' using errcode = '23514'; end if;
end;
$$;

create trigger candidate_form_document_change_guard
  before insert or update on public.candidate_form_document_changes
  for each row execute function private.validate_candidate_form_document_change();

create or replace function private.validate_optional_team_belongs_to_unit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare team_unit uuid;
begin
  if new.department_team_id is null then return new; end if;
  select dt.unit_id into team_unit
  from public.department_teams dt
  where dt.department_team_id = new.department_team_id;
  if team_unit is null or team_unit is distinct from new.unit_id then
    raise exception 'department_team does not belong to unit' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.validate_position_hierarchy()
returns trigger
language plpgsql
set search_path = ''
as $$
declare p_unit uuid; p_team uuid;
begin
  select p.unit_id, p.department_team_id into p_unit, p_team
  from public.positions p
  where p.position_id = new.position_id;
  if p_unit is null then
    raise exception 'position not found' using errcode = '23503';
  end if;
  if p_unit is distinct from new.unit_id then
    raise exception 'position does not belong to application unit' using errcode = '23514';
  end if;
  if p_team is distinct from new.department_team_id then
    raise exception 'application department/team must match position department/team, including NULL' using errcode = '23514';
  end if;
  if new.department_team_id is not null then
    perform 1 from public.department_teams dt
      where dt.department_team_id = new.department_team_id and dt.unit_id = new.unit_id;
    if not found then
      raise exception 'application team does not belong to unit' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.validate_interview_format_requirements()
returns trigger
language plpgsql
set search_path = ''
as $$
declare req_room boolean; req_link boolean; fmt_active boolean; format_changed boolean;
begin
  if new.schedule_status_code in ('SCHEDULED','AWAITING','CONFIRMED') and (new.start_at is null or new.end_at is null) then
    raise exception 'start_at and end_at are required for scheduled/awaiting/confirmed interview' using errcode = '23514';
  end if;
  if new.start_at is null and new.end_at is null then
    return new;
  end if;
  if new.interview_format_id is null then
    raise exception 'interview format is required when interview time is set' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' then
    format_changed := true;
  else
    format_changed := (new.interview_format_id is distinct from old.interview_format_id);
  end if;
  select f.requires_room, f.requires_meeting_link, f.is_active into req_room, req_link, fmt_active
  from public.interview_formats f
  where f.interview_format_id = new.interview_format_id;
  if not found then
    raise exception 'interview format not found' using errcode = '23503';
  end if;
  if format_changed and coalesce(fmt_active,false) = false then
    raise exception 'inactive interview format cannot be selected for a new/change operation' using errcode = '23514';
  end if;

  -- Normalize stale resources when switching format. Existing historical inactive formats remain operable.
  if coalesce(req_room,false) = false then new.room_id := null; end if;
  if coalesce(req_link,false) = false then new.meeting_link := null; end if;

  if req_room and new.room_id is null then
    raise exception 'room is required by interview format' using errcode = '23514';
  end if;
  if req_link and nullif(btrim(new.meeting_link), '') is null then
    raise exception 'meeting link is required by interview format' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.normalize_interview_reason_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.schedule_status_code <> 'CANCELLED' then new.cancellation_reason_id := null; end if;
  if new.report_status_code <> 'REJECTED' then new.rejection_reason_id := null; end if;
  return new;
end;
$$;

create or replace function private.validate_submission_email_snapshot()
returns trigger
language plpgsql
set search_path = ''
as $$
declare candidate_email citext;
begin
  select c.email into candidate_email
  from public.candidates c
  where c.candidate_id = new.candidate_id;
  if candidate_email is null or candidate_email is distinct from new.email_snapshot then
    raise exception 'submission email snapshot must match candidate verified email' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.validate_application_owner_and_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare owner_ok boolean;
begin
  select (u.is_active and (u.is_root_admin or exists (
      select 1 from public.app_user_roles ur
      where ur.app_user_id = u.app_user_id and ur.role_code = 'HR'
    ))) into owner_ok
  from public.app_users u
  where u.app_user_id = new.hr_owner_id;

  if new.is_active and coalesce(owner_ok,false) = false then
    raise exception 'ACTIVE_APPLICATION_OWNER_MUST_BE_ACTIVE_HR_OR_ROOT' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and (
    new.submission_id is distinct from old.submission_id or
    new.unit_id is distinct from old.unit_id or
    new.department_team_id is distinct from old.department_team_id or
    new.position_id is distinct from old.position_id
  ) then
    raise exception 'APPLICATION_DURABLE_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.protect_master_structural_semantics()
returns trigger
language plpgsql
set search_path = ''
as $$
declare used boolean := false;
begin
  if tg_table_name = 'positions' then
    select exists(select 1 from public.applications a where a.position_id = old.position_id) into used;
    if used and (new.unit_id is distinct from old.unit_id or new.department_team_id is distinct from old.department_team_id or new.position_group_id is distinct from old.position_group_id or new.code is distinct from old.code) then
      raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD';
    end if;
  elsif tg_table_name = 'department_teams' then
    select exists(select 1 from public.applications a where a.department_team_id = old.department_team_id)
        or exists(select 1 from public.positions p where p.department_team_id = old.department_team_id) into used;
    if used and (new.unit_id is distinct from old.unit_id or new.code is distinct from old.code) then
      raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD';
    end if;
  elsif tg_table_name = 'organizational_units' then
    select exists(select 1 from public.applications a where a.unit_id = old.unit_id)
        or exists(select 1 from public.positions p where p.unit_id = old.unit_id) into used;
    if used and new.code is distinct from old.code then
      raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD';
    end if;
  elsif tg_table_name = 'position_groups' then
    select exists(select 1 from public.positions p where p.position_group_id = old.position_group_id) into used;
    if used and (new.code is distinct from old.code or new.requires_demo_topic is distinct from old.requires_demo_topic) then
      raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD';
    end if;
  elsif tg_table_name = 'rooms' then
    select exists(select 1 from public.interviews i where i.room_id = old.room_id) into used;
    if used and (new.code is distinct from old.code or new.building is distinct from old.building) then
      raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD';
    end if;
  elsif tg_table_name = 'interview_formats' then
    select exists(select 1 from public.interviews i where i.interview_format_id = old.interview_format_id) into used;
    if used and (new.code is distinct from old.code or new.requires_room is distinct from old.requires_room or new.requires_meeting_link is distinct from old.requires_meeting_link) then
      raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD';
    end if;
  elsif tg_table_name = 'document_types' then
    select exists(select 1 from public.submission_document_logicals d where d.document_type_id = old.document_type_id)
        or exists(select 1 from public.interview_document_logicals d where d.document_type_id = old.document_type_id) into used;
    if used and (new.code is distinct from old.code or new.scope_code is distinct from old.scope_code) then
      raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD';
    end if;
  elsif tg_table_name = 'recruitment_sources' then
    select exists(select 1 from public.submissions x where x.recruitment_source_id = old.recruitment_source_id) into used;
    if used and new.code is distinct from old.code then raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD'; end if;
  elsif tg_table_name = 'qualification_levels' then
    select exists(select 1 from public.submission_education x where x.qualification_id = old.qualification_id) into used;
    if used and new.code is distinct from old.code then raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD'; end if;
  elsif tg_table_name = 'cancellation_reasons' then
    select exists(select 1 from public.interviews x where x.cancellation_reason_id = old.cancellation_reason_id) into used;
    if used and new.code is distinct from old.code then raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD'; end if;
  elsif tg_table_name = 'rejection_reasons' then
    select exists(select 1 from public.interviews x where x.rejection_reason_id = old.rejection_reason_id) into used;
    if used and new.code is distinct from old.code then raise exception 'REFERENCED_MASTER_STRUCTURAL_CHANGE_REQUIRES_NEW_RECORD'; end if;
  end if;
  return new;
end;
$$;

create or replace function private.protect_published_privacy_notice()
returns trigger
language plpgsql
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

create or replace function private.refresh_candidate_current_profile(p_candidate_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare s_name text; s_phone text; s_at timestamptz;
begin
  perform 1 from public.candidates c where c.candidate_id = p_candidate_id for update;
  if not found then raise exception 'CANDIDATE_NOT_FOUND' using errcode = '23503'; end if;
  select s.full_name, s.phone, s.submitted_at into s_name, s_phone, s_at
    from public.submissions s where s.candidate_id = p_candidate_id
    order by s.submitted_at desc, s.submission_id desc limit 1;
  update public.candidates set current_full_name=s_name, current_phone=s_phone, last_submission_at=s_at
    where candidate_id=p_candidate_id;
end;
$$;

create or replace function private.enforce_report_decision_metadata()
returns trigger
language plpgsql
set search_path = ''
as $$
declare decision_changed boolean;
begin
  if tg_op = 'INSERT' then
    decision_changed := (
      nullif(btrim(new.conclusion), '') is not null or
      nullif(btrim(new.expected_specific_job_assigned), '') is not null or
      nullif(btrim(new.expected_recruitment_time), '') is not null
    );
  else
    decision_changed := (
      new.conclusion is distinct from old.conclusion or
      new.expected_specific_job_assigned is distinct from old.expected_specific_job_assigned or
      new.expected_recruitment_time is distinct from old.expected_recruitment_time
    );
  end if;

  if decision_changed then
    if new.decision_updated_by is null then
      raise exception 'decision_updated_by is required when final decision fields change' using errcode = '23514';
    end if;
    new.decision_updated_at := now();
  elsif tg_op = 'UPDATE' then
    -- Qualitative edits must not move the Final Decision Source.
    new.decision_updated_at := old.decision_updated_at;
    new.decision_updated_by := old.decision_updated_by;
  end if;
  return new;
end;
$$;

create or replace function private.protect_root_admin()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.is_root_admin = true then
    if tg_op = 'DELETE' then
      raise exception 'ROOT_ADMIN_PROTECTED';
    end if;
    if new.is_root_admin is distinct from true or new.is_active is distinct from true then
      raise exception 'ROOT_ADMIN_PROTECTED';
    end if;
    if new.email is distinct from old.email or new.auth_user_id is distinct from old.auth_user_id then
      raise exception 'ROOT_ADMIN_IDENTITY_CHANGE_REQUIRES_RECOVERY';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;


-- v1.9 defense-in-depth helpers
create or replace function private.protect_candidate_verified_email()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.email is distinct from old.email then
    if current_setting('recruitment.candidate_email_recovery_active', true) = 'on' then
      return new;
    end if;
    raise exception 'CANDIDATE_VERIFIED_EMAIL_IMMUTABLE' using errcode='23514';
  end if;
  return new;
end; $$;

create or replace function private.validate_form_session_candidate_owner()
returns trigger language plpgsql set search_path = '' as $$
declare owner_candidate uuid;
begin
  if new.mode_code='EDIT_SUBMISSION' then
    select candidate_id into owner_candidate from public.submissions where submission_id=new.target_submission_id;
    if owner_candidate is null or owner_candidate is distinct from new.candidate_id then raise exception 'FORM_SESSION_SUBMISSION_CANDIDATE_MISMATCH' using errcode='23514'; end if;
  end if;
  return new;
end; $$;

create or replace function private.validate_participant_lifecycle_and_user()
returns trigger language plpgsql set search_path = '' as $$
declare user_active boolean;
begin
  if not ((new.is_current=true and new.removed_at is null) or (new.is_current=false and new.removed_at is not null)) then raise exception 'PARTICIPANT_LIFECYCLE_INVALID' using errcode='23514'; end if;
  if new.is_current=true and (tg_op='INSERT' or old.is_current is distinct from new.is_current or old.app_user_id is distinct from new.app_user_id) then
    select is_active into user_active from public.app_users where app_user_id=new.app_user_id;
    if coalesce(user_active,false)=false then raise exception 'USER_INACTIVE_NOT_SELECTABLE' using errcode='23514'; end if;
  end if;
  return new;
end; $$;

create or replace function private.protect_published_privacy_notice_delete()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'PUBLISHED_PRIVACY_NOTICE_DELETE_FORBIDDEN' using errcode='23514'; end; $$;

create or replace function private.validate_active_master_references()
returns trigger language plpgsql set search_path = '' as $$
declare ok boolean;
begin
  if tg_table_name='applications' then
    if tg_op='INSERT' or new.unit_id is distinct from old.unit_id then select is_active into ok from public.organizational_units where unit_id=new.unit_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_UNIT_NOT_SELECTABLE' using errcode='23514'; end if; end if;
    if new.department_team_id is not null and (tg_op='INSERT' or new.department_team_id is distinct from old.department_team_id) then select is_active into ok from public.department_teams where department_team_id=new.department_team_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_TEAM_NOT_SELECTABLE' using errcode='23514'; end if; end if;
    if tg_op='INSERT' or new.position_id is distinct from old.position_id then select is_active into ok from public.positions where position_id=new.position_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_POSITION_NOT_SELECTABLE' using errcode='23514'; end if; end if;
  elsif tg_table_name='positions' then
    if tg_op='INSERT' or new.unit_id is distinct from old.unit_id then select is_active into ok from public.organizational_units where unit_id=new.unit_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_UNIT_NOT_SELECTABLE' using errcode='23514'; end if; end if;
    if new.department_team_id is not null and (tg_op='INSERT' or new.department_team_id is distinct from old.department_team_id) then select is_active into ok from public.department_teams where department_team_id=new.department_team_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_TEAM_NOT_SELECTABLE' using errcode='23514'; end if; end if;
    if tg_op='INSERT' or new.position_group_id is distinct from old.position_group_id then select is_active into ok from public.position_groups where position_group_id=new.position_group_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_POSITION_GROUP_NOT_SELECTABLE' using errcode='23514'; end if; end if;
  elsif tg_table_name='submission_education' then
    -- Education qualification is optional in Phase 1. NULL means no qualification selected,
    -- so active-master validation applies only to a non-NULL new/changed reference.
    if new.qualification_id is not null and (tg_op='INSERT' or new.qualification_id is distinct from old.qualification_id) then
      select is_active into ok from public.qualification_levels where qualification_id=new.qualification_id;
      if coalesce(ok,false)=false then raise exception 'INACTIVE_QUALIFICATION_NOT_SELECTABLE' using errcode='23514'; end if;
    end if;
  elsif tg_table_name='submissions' then
    if new.recruitment_source_id is not null and (tg_op='INSERT' or new.recruitment_source_id is distinct from old.recruitment_source_id) then select is_active into ok from public.recruitment_sources where recruitment_source_id=new.recruitment_source_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_RECRUITMENT_SOURCE_NOT_SELECTABLE' using errcode='23514'; end if; end if;
  elsif tg_table_name='interviews' then
    if new.room_id is not null and (tg_op='INSERT' or new.room_id is distinct from old.room_id) then select is_active into ok from public.rooms where room_id=new.room_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_ROOM_NOT_SELECTABLE' using errcode='23514'; end if; end if;
    if new.interview_format_id is not null and (tg_op='INSERT' or new.interview_format_id is distinct from old.interview_format_id) then select is_active into ok from public.interview_formats where interview_format_id=new.interview_format_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_INTERVIEW_FORMAT_NOT_SELECTABLE' using errcode='23514'; end if; end if;
    if new.cancellation_reason_id is not null and (tg_op='INSERT' or new.cancellation_reason_id is distinct from old.cancellation_reason_id) then select is_active into ok from public.cancellation_reasons where cancellation_reason_id=new.cancellation_reason_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_CANCELLATION_REASON_NOT_SELECTABLE' using errcode='23514'; end if; end if;
    if new.rejection_reason_id is not null and (tg_op='INSERT' or new.rejection_reason_id is distinct from old.rejection_reason_id) then select is_active into ok from public.rejection_reasons where rejection_reason_id=new.rejection_reason_id; if coalesce(ok,false)=false then raise exception 'INACTIVE_REJECTION_REASON_NOT_SELECTABLE' using errcode='23514'; end if; end if;
  end if;
  return new;
end; $$;

create or replace function private.is_structurally_empty_default_round(p_interview_id uuid)
returns boolean language sql stable set search_path = '' as $$
select exists(select 1 from public.interviews i where i.interview_id=p_interview_id and i.round_no=1
 and i.demo_topic is null and i.start_at is null and i.end_at is null and i.interview_format_id is null and i.room_id is null and i.meeting_link is null
 and i.schedule_status_code='AVAILABLE' and i.report_status_code='INTERVIEW_SCHEDULING' and i.cancellation_reason_id is null and i.rejection_reason_id is null
 and nullif(btrim(coalesce(i.interview_note,'')),'') is null and nullif(btrim(coalesce(i.hr_report_note,'')),'') is null
 and i.copied_from_interview_id is null
 and not exists(select 1 from public.interviews child where child.copied_from_interview_id=i.interview_id)
 and not exists(select 1 from public.interview_participants ip where ip.interview_id=i.interview_id)
 and not exists(select 1 from public.interview_document_logicals dl where dl.interview_id=i.interview_id)
 and not exists(select 1 from public.email_outbox eo where eo.interview_id=i.interview_id)
 and not exists(select 1 from public.email_history eh where eh.interview_id=i.interview_id)); $$;

create or replace function private.all_current_participants_selectable(p_interview_id uuid)
returns boolean language sql stable set search_path = '' as $$
select not exists (
  select 1
  from public.interview_participants ip
  left join public.app_users u on u.app_user_id=ip.app_user_id
  where ip.interview_id=p_interview_id
    and ip.is_current=true
    and (u.app_user_id is null or u.is_active=false)
); $$;

-- Trusted schedule/reactivation RPCs MUST call all_current_participants_selectable()
-- before any mutation that makes an Interview resource_blocking. Stable error:
-- CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED.

-- Version triggers
create trigger organizational_units_touch_version before update on public.organizational_units
  for each row execute function private.touch_version();
create trigger department_teams_touch_version before update on public.department_teams
  for each row execute function private.touch_version();
create trigger position_groups_touch_version before update on public.position_groups
  for each row execute function private.touch_version();
create trigger qualification_levels_touch_version before update on public.qualification_levels
  for each row execute function private.touch_version();
create trigger recruitment_sources_touch_version before update on public.recruitment_sources
  for each row execute function private.touch_version();
create trigger document_types_touch_version before update on public.document_types
  for each row execute function private.touch_version();
create trigger cancellation_reasons_touch_version before update on public.cancellation_reasons
  for each row execute function private.touch_version();
create trigger rejection_reasons_touch_version before update on public.rejection_reasons
  for each row execute function private.touch_version();
create trigger positions_touch_version before update on public.positions
  for each row execute function private.touch_version();
create trigger interview_formats_touch_version before update on public.interview_formats
  for each row execute function private.touch_version();
create trigger rooms_touch_version before update on public.rooms
  for each row execute function private.touch_version();

create trigger app_users_touch_version before update on public.app_users
  for each row execute function private.touch_version();
create trigger candidates_touch_version before update on public.candidates
  for each row execute function private.touch_version();
create trigger submissions_touch_version before update on public.submissions
  for each row execute function private.touch_version();
create trigger applications_touch_version before update on public.applications
  for each row execute function private.touch_version();
create trigger interviews_touch_version before update on public.interviews
  for each row execute function private.touch_version();
create trigger interview_participants_touch_version before update on public.interview_participants
  for each row execute function private.touch_version();
create trigger interview_reports_touch_version before update on public.interview_reports
  for each row execute function private.touch_version();

create trigger organizational_units_semantic_guard before update on public.organizational_units
  for each row execute function private.protect_master_structural_semantics();
create trigger department_teams_semantic_guard before update on public.department_teams
  for each row execute function private.protect_master_structural_semantics();
create trigger position_groups_semantic_guard before update on public.position_groups
  for each row execute function private.protect_master_structural_semantics();
create trigger qualification_levels_semantic_guard before update on public.qualification_levels
  for each row execute function private.protect_master_structural_semantics();
create trigger recruitment_sources_semantic_guard before update on public.recruitment_sources
  for each row execute function private.protect_master_structural_semantics();
create trigger document_types_semantic_guard before update on public.document_types
  for each row execute function private.protect_master_structural_semantics();
create trigger cancellation_reasons_semantic_guard before update on public.cancellation_reasons
  for each row execute function private.protect_master_structural_semantics();
create trigger rejection_reasons_semantic_guard before update on public.rejection_reasons
  for each row execute function private.protect_master_structural_semantics();
create trigger positions_semantic_guard before update on public.positions
  for each row execute function private.protect_master_structural_semantics();
create trigger interview_formats_semantic_guard before update on public.interview_formats
  for each row execute function private.protect_master_structural_semantics();

create trigger position_team_unit_guard
  before insert or update of unit_id, department_team_id on public.positions
  for each row execute function private.validate_optional_team_belongs_to_unit();

create trigger application_position_hierarchy_guard
  before insert or update of unit_id, department_team_id, position_id on public.applications
  for each row execute function private.validate_position_hierarchy();

create trigger interview_format_requirements_guard
  before insert or update of start_at, end_at, interview_format_id, room_id, meeting_link, schedule_status_code on public.interviews
  for each row execute function private.validate_interview_format_requirements();

create trigger interview_reason_normalize_guard
  before insert or update of schedule_status_code, report_status_code, cancellation_reason_id, rejection_reason_id on public.interviews
  for each row execute function private.normalize_interview_reason_fields();

create trigger submission_email_snapshot_guard
  before insert or update of candidate_id, email_snapshot on public.submissions
  for each row execute function private.validate_submission_email_snapshot();

create or replace function private.block_ineligible_hr_owner_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'app_users' then
    if old.is_active = true and new.is_active = false and exists (
      select 1 from public.applications a where a.hr_owner_id = old.app_user_id and a.is_active = true
    ) then
      raise exception 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED' using errcode = '23514';
    end if;
    if old.is_active = true and new.is_active = false and exists (
      select 1 from public.interview_participants ip
      join public.interviews i on i.interview_id=ip.interview_id
      join public.applications a on a.application_id=i.application_id
      where ip.app_user_id=old.app_user_id and ip.is_current=true and a.is_active=true and i.is_active=true
        and i.schedule_status_code<>'CANCELLED' and i.start_at is not null and i.end_at is not null and i.end_at > now()
    ) then
      raise exception 'FUTURE_INTERVIEW_PARTICIPANT_REASSIGN_REQUIRED' using errcode='23514';
    end if;
  elsif tg_table_name = 'app_user_roles' then
    if (tg_op = 'DELETE' or (tg_op = 'UPDATE' and old.role_code = 'HR' and new.role_code is distinct from old.role_code)) and old.role_code = 'HR' and exists (
      select 1 from public.applications a where a.hr_owner_id = old.app_user_id and a.is_active = true
    ) then
      raise exception 'ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger app_user_owner_lifecycle_guard
  before update of is_active on public.app_users
  for each row execute function private.block_ineligible_hr_owner_lifecycle();

create trigger hr_role_owner_lifecycle_guard
  before update or delete on public.app_user_roles
  for each row execute function private.block_ineligible_hr_owner_lifecycle();

create trigger application_owner_identity_guard
  before insert or update of submission_id, unit_id, department_team_id, position_id, hr_owner_id, is_active on public.applications
  for each row execute function private.validate_application_owner_and_identity();

create trigger a_report_decision_metadata_guard
  before insert or update on public.interview_reports
  for each row execute function private.enforce_report_decision_metadata();

create trigger root_admin_update_guard
  before update or delete on public.app_users
  for each row execute function private.protect_root_admin();

create trigger candidate_verified_email_immutable_guard before update of email on public.candidates for each row execute function private.protect_candidate_verified_email();
create trigger candidate_form_session_owner_guard before insert or update of candidate_id, target_submission_id, mode_code on public.candidate_form_sessions for each row execute function private.validate_form_session_candidate_owner();
create trigger participant_lifecycle_user_guard before insert or update of is_current, removed_at, app_user_id on public.interview_participants for each row execute function private.validate_participant_lifecycle_and_user();
create trigger privacy_notice_delete_guard before delete on public.privacy_notice_versions for each row execute function private.protect_published_privacy_notice_delete();
create trigger application_active_master_guard before insert or update of unit_id, department_team_id, position_id on public.applications for each row execute function private.validate_active_master_references();
create trigger position_active_master_guard before insert or update of unit_id, department_team_id, position_group_id on public.positions for each row execute function private.validate_active_master_references();
create trigger education_active_master_guard before insert or update of qualification_id on public.submission_education for each row execute function private.validate_active_master_references();
create trigger submission_source_active_master_guard before insert or update of recruitment_source_id on public.submissions for each row execute function private.validate_active_master_references();
create trigger interview_active_master_guard before insert or update of room_id, interview_format_id, cancellation_reason_id, rejection_reason_id on public.interviews for each row execute function private.validate_active_master_references();

-- -----------------------------------------------------------------------------
-- Private implementation views
-- -----------------------------------------------------------------------------
create or replace view private.access_active_interviews
with (security_invoker = true)
as
select i.*
from public.interviews i
join public.applications a on a.application_id = i.application_id
where a.is_active = true and i.is_active = true;

create or replace view private.resource_blocking_interviews
with (security_invoker = true)
as
select i.*
from private.access_active_interviews i
where i.schedule_status_code <> 'CANCELLED'
  and i.start_at is not null
  and i.end_at is not null;

create or replace view private.application_current_interview
with (security_invoker = true)
as
select a.application_id, i.interview_id, i.round_no
from public.applications a
left join lateral (
  select i1.interview_id, i1.round_no
  from private.access_active_interviews i1
  where i1.application_id = a.application_id
  order by i1.round_no desc
  limit 1
) i on true
where a.is_active = true;

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
-- Authoritative Submission status helpers
-- -----------------------------------------------------------------------------
create or replace function private.bump_submission_aggregate_version(p_submission_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.submissions
     set updated_at = now()
   where submission_id = p_submission_id;
  if not found then raise exception 'SUBMISSION_NOT_FOUND'; end if;
end;
$$;

create or replace function private.recalculate_submission_status(p_submission_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare next_status text; current_status text; active_count integer; rejected_count integer; hired_count integer;
begin
  -- Mandatory parent lock prevents lost recalculation across concurrent Applications.
  select s.status_code into current_status from public.submissions s where s.submission_id = p_submission_id for update;
  if not found then raise exception 'submission not found' using errcode = '23503'; end if;

  select count(*) into active_count from public.applications a
   where a.submission_id = p_submission_id and a.is_active = true;

  if active_count = 0 then
    -- Preserve an untouched manual state; if applications were removed from a derived state, return to READ.
    next_status := case when current_status in ('NEW','READ') then current_status else 'READ' end;
  else
    select count(*) filter (where coalesce(i.report_status_code,'') = 'HIRED'),
           count(*) filter (where coalesce(i.report_status_code,'') = 'REJECTED')
      into hired_count, rejected_count
    from public.applications a
    left join private.application_current_interview ci on ci.application_id = a.application_id
    left join public.interviews i on i.interview_id = ci.interview_id
    where a.submission_id = p_submission_id and a.is_active = true;

    if hired_count > 0 then next_status := 'DONE';
    elsif rejected_count = active_count then next_status := 'CLOSED';
    else next_status := 'PROCESSED'; end if;
  end if;

  update public.submissions set status_code = next_status where submission_id = p_submission_id;
  return next_status;
end;
$$;

create or replace function private.set_latest_submission_manual_status(
  p_candidate_id uuid,
  p_expected_latest_submission_id uuid,
  p_expected_version bigint,
  p_status text
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_submission_id uuid;
  v_version bigint;
begin
  if p_status not in ('NEW','READ') then
    raise exception 'ONLY_NEW_READ_ARE_MANUAL_SUBMISSION_STATES' using errcode = '23514';
  end if;

  perform 1 from public.candidates c where c.candidate_id = p_candidate_id for update;
  if not found then raise exception 'candidate not found' using errcode = '23503'; end if;

  select s.submission_id, s.version_no
    into v_submission_id, v_version
  from public.submissions s
  where s.candidate_id = p_candidate_id
  order by s.submitted_at desc, s.submission_id desc
  limit 1
  for update;

  if v_submission_id is null then
    raise exception 'LATEST_SUBMISSION_NOT_FOUND' using errcode = '23503';
  end if;
  if v_submission_id <> p_expected_latest_submission_id then
    raise exception 'LATEST_SUBMISSION_CHANGED' using errcode = '40001';
  end if;
  if v_version <> p_expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if exists(select 1 from public.applications a where a.submission_id = v_submission_id and a.is_active = true) then
    raise exception 'CANNOT_SET_MANUAL_STATUS_WHILE_ACTIVE_APPLICATION_EXISTS' using errcode = '23514';
  end if;

  update public.submissions set status_code = p_status where submission_id = v_submission_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- RLS baseline
-- -----------------------------------------------------------------------------
-- Enable RLS on all business tables before exposing them through the Data API.
-- Exact SELECT/INSERT/UPDATE/DELETE policies and GRANT/REVOKE statements are defined by
-- 39_SECURITY_RLS_MATRIX.md and MUST be implemented/tested in migrations before production.

do $$
declare t text;
begin
  foreach t in array array[
    'organizational_units','department_teams','position_groups','qualification_levels','recruitment_sources','document_types','cancellation_reasons','rejection_reasons','positions','interview_formats','rooms',
    'app_users','app_user_roles','permissions','app_user_permissions','permission_dependencies',
    'candidates','submissions','privacy_notice_versions','submission_education','submission_work_experiences','submission_activities',
    'submission_document_logicals','submission_documents','candidate_form_sessions','candidate_form_document_changes','applications','interviews','interview_participants','interview_reports',
    'interview_document_logicals','interview_documents','email_outbox','email_history','activity_log','security_audit_log','privacy_acknowledgements','upload_reservations','storage_cleanup_queue','idempotency_records'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Strong default: anonymous role receives no business-table access.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
-- Do not rely on default privileges. Production migrations must explicitly grant only the operations
-- required by authenticated users/RPCs and must test grants separately from RLS.

-- -----------------------------------------------------------------------------
create trigger rooms_structural_guard before update on public.rooms
  for each row execute function private.protect_master_structural_semantics();

create trigger privacy_notice_immutable_guard before update on public.privacy_notice_versions
  for each row execute function private.protect_published_privacy_notice();

-- Permission seed
-- -----------------------------------------------------------------------------
insert into public.permissions(permission_code, description) values
  ('submissions.view','View application submissions'),
  ('submissions.edit','Edit HR-editable submission fields'),
  ('submissions.status','Change submission status'),
  ('candidates.active_manage','Activate/inactivate candidate accounts'),
  ('candidates.delete_unused','Hard-delete unused Candidate only'),
  ('applications.view','View applications'),
  ('applications.manage','Manage applications'),
  ('interviews.view','View interviews'),
  ('interviews.manage','Create/edit/copy/delete-or-inactivate interviews'),
  ('interviews.status','Change interview schedule status'),
  ('interviews.participants','Manage interview participants'),
  ('interviews.documents','Manage interview documents'),
  ('interviews.email','Send interview operational email'),
  ('emails.history_view','View operational Email History within parent context'),
  ('emails.history_delete','Delete operational Email History under frozen cleanup rule'),
  ('reports.view','View report pages/preview/PDF'),
  ('reports.manage_status','Manage report status/HR report note'),
  ('reports.visibility','Hide/show record to interviewers'),
  ('reports.edit_interviewer','Edit an interviewer report'),
  ('reports.delete','Delete/inactivate report by rule'),
  ('master_data.manage','Manage allowed master data'),
  ('users.directory_manage','Manage internal user directory/business profile; unbound email typo only'),
  ('users.identity_manage','Manage bound Auth identity — Root Admin only'),
  ('users.permissions_manage','Manage HR permissions — Root Admin only'),
  ('candidates.identity_manage','Manage Candidate login email identity recovery')
on conflict (permission_code) do update set description = excluded.description;

-- -----------------------------------------------------------------------------
-- Production implementation gates intentionally NOT hidden in this starter
-- -----------------------------------------------------------------------------
-- 1) Implement exact RLS policies + GRANT/REVOKE and adversarial tests from doc 39.
-- 2) Implement RPCs/commands from doc 37 and command coverage matrix; browser must not multi-write.
-- 3) Schedule conflict is BLOCK for Candidate + Room + Interviewer and requires mandatory resource locks.
-- 4) Implement field-aware report patching and decision-only metadata semantics.
-- 5) Implement Root bootstrap/recovery; ordinary update cannot rebind Root identity.
-- 6) Configure private Storage and two-phase reserve/finalize upload, max 5 files/parent, 5 MB/file.
-- 7) Candidate Auth = Email OTP; Internal = Google Workspace OAuth only; pin auth dependencies.
-- 8) Current business retention = no automatic purge; capacity alerts/export/archive workflow required.
-- 9) Official PDF pixel layout is deferred until owner supplies the approved template.
-- 10) Run schema conformance, command coverage, race, RLS, migration, backup/restore and accessibility gates before freeze.


-- Permission dependency seed — action permissions imply/require read context.
insert into public.permission_dependencies(permission_code, requires_permission_code) values
  ('submissions.edit','submissions.view'),
  ('submissions.status','submissions.view'),
  ('applications.manage','applications.view'),
  ('interviews.manage','interviews.view'),
  ('interviews.status','interviews.view'),
  ('interviews.participants','interviews.view'),
  ('interviews.documents','interviews.view'),
  ('interviews.email','interviews.view'),
  ('reports.manage_status','reports.view'),
  ('reports.visibility','reports.view'),
  ('reports.edit_interviewer','reports.view'),
  ('reports.delete','reports.view'),
  ('emails.history_delete','emails.history_view')
on conflict do nothing;
