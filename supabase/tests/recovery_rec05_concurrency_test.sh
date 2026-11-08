#!/usr/bin/env bash
# =============================================================================
# RECOVERY PACKAGE 004: REC-05 Concurrency & Permission Boundary Test
#
# Covers:
#   PG1: Two-session serialization between HR open_submission and Candidate update_candidate_submission
#     Case 1A: Candidate Save commits first -> HR Open commits second -> transitions NEW -> READ, candidate edits retained.
#     Case 1B: HR Open commits first -> Candidate Save rejects with INVALID_STATE -> zero candidate overwrite.
#   PG2: Permission boundaries:
#     Unauthorized caller -> FORBIDDEN
#     View-only HR (submissions.view only) -> nonmutating read, status remains NEW, version unchanged
#     Authorized HR (submissions.view + submissions.status) -> atomically transitions NEW -> READ, version bumped
#   PG3: Latest vs Historical submissions and idempotent re-open:
#     Opening historical submission transitions only that submission, leaving latest unaffected
#     Opening an already READ submission is idempotent (returns READ, version unchanged)
# =============================================================================
set -euo pipefail

container_name="${CONTAINER_NAME:-supabase_db_eiu-recruitment-dev}"

psql_exec() {
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

new_uuid() {
  if [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\r\n'
  else
    psql_exec -qAt -c "select gen_random_uuid();" | tr -d '\r\n'
  fi
}

suffix="$(new_uuid | tr -d '-' | cut -c1-12)"

# Canonical seeds are keyed by code; their UUIDs differ across clean replays.
cv_document_type_id="$(psql_exec -qAt -c "select document_type_id from public.document_types where code='CV_RESUME' and scope_code='SUBMISSION' and is_active" | tr -d '\r\n')"
if [[ ! "$cv_document_type_id" =~ ^[0-9a-f-]{36}$ ]]; then
  echo 'REC-05 requires the canonical active CV_RESUME document type' >&2
  exit 1
fi

unit_id="$(new_uuid)"
group_id="$(new_uuid)"
pos_id="$(new_uuid)"

# Actors
hr_full_id="$(new_uuid)"
hr_full_auth="$(new_uuid)"

hr_view_id="$(new_uuid)"
hr_view_auth="$(new_uuid)"

unauth_auth="$(new_uuid)"

# Candidate 1 (Scenario 1A: Candidate save commits first)
cand_1a="$(new_uuid)"
cand_1a_auth="$(new_uuid)"
sub_1a="$(new_uuid)"
doc_log_1a="$(new_uuid)"
sess_1a="$(new_uuid)"

# Candidate 2 (Scenario 1B: HR open commits first)
cand_1b="$(new_uuid)"
cand_1b_auth="$(new_uuid)"
sub_1b="$(new_uuid)"
doc_log_1b="$(new_uuid)"
sess_1b="$(new_uuid)"

# Candidate 3 (Scenario 2: Permission boundaries)
cand_2="$(new_uuid)"
sub_2="$(new_uuid)"

# Candidate 4 (Scenario 3: Historical vs Latest submissions)
cand_3="$(new_uuid)"
sub_3_hist="$(new_uuid)"
sub_3_latest="$(new_uuid)"

registered_apps=()
registered_pids=()

run_sql_file() {
  local sql="$1"
  local out="$2"
  printf '%s\n' "$sql" | docker exec -i "$container_name" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres >"$out" 2>&1
}

wait_for_lock_wait() {
  local app_name="$1"
  local i
  for i in $(seq 1 100); do
    if psql_exec -qAt -c "select coalesce(bool_or(wait_event_type='Lock'),false)::text from pg_stat_activity where application_name='${app_name}' and pid <> pg_backend_pid();" | tr -d '\r' | grep -qx 'true'; then
      return 0
    fi
    sleep 0.05
  done
  echo "Timed out waiting for ${app_name} to reach a lock wait" >&2
  psql_exec -c "select pid,application_name,state,wait_event_type,wait_event,query from pg_stat_activity where application_name='${app_name}';" >&2 || true
  return 1
}

cleanup() {
  local exit_code=$?
  for app in "${registered_apps[@]}"; do
    psql_exec -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name='$app' and pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  done
  for pid in "${registered_pids[@]}"; do
    kill -9 "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done

  rm -f /tmp/rec05_*_${suffix}.* 2>/dev/null || true

  echo "=== Running REC-05 Fixture Cleanup ==="
  psql_exec <<SQL
begin;
delete from public.idempotency_records
where actor_scope in (
  'candidate:$cand_1a',
  'candidate:$cand_1b',
  'app_user:$hr_full_id',
  'app_user:$hr_view_id'
);

delete from public.candidate_form_sessions
where candidate_form_session_id in ('$sess_1a'::uuid, '$sess_1b'::uuid);

delete from public.submission_documents
where logical_document_id in ('$doc_log_1a'::uuid, '$doc_log_1b'::uuid);

delete from public.submission_document_logicals
where logical_document_id in ('$doc_log_1a'::uuid, '$doc_log_1b'::uuid);
delete from public.email_history
where submission_id in (
  '$sub_1a'::uuid, '$sub_1b'::uuid, '$sub_2'::uuid,
  '$sub_3_hist'::uuid, '$sub_3_latest'::uuid
);

delete from public.email_outbox
where submission_id in (
  '$sub_1a'::uuid, '$sub_1b'::uuid, '$sub_2'::uuid,
  '$sub_3_hist'::uuid, '$sub_3_latest'::uuid
);

delete from public.submissions
where submission_id in (
  '$sub_1a'::uuid, '$sub_1b'::uuid, '$sub_2'::uuid,
  '$sub_3_hist'::uuid, '$sub_3_latest'::uuid
);
delete from public.candidates
where candidate_id in ('$cand_1a'::uuid, '$cand_1b'::uuid, '$cand_2'::uuid, '$cand_3'::uuid);

delete from public.app_user_permissions
where app_user_id in ('$hr_full_id'::uuid, '$hr_view_id'::uuid);

delete from public.app_user_roles
where app_user_id in ('$hr_full_id'::uuid, '$hr_view_id'::uuid);

delete from public.app_users
where app_user_id in ('$hr_full_id'::uuid, '$hr_view_id'::uuid);

delete from public.positions where position_id = '$pos_id'::uuid;
delete from public.position_groups where position_group_id = '$group_id'::uuid;
delete from public.organizational_units where unit_id = '$unit_id'::uuid;
commit;
SQL

  local remaining_count
  remaining_count="$(psql_exec -qAt -c "
    select count(*) from (
      select candidate_id from public.candidates where candidate_id in ('$cand_1a'::uuid, '$cand_1b'::uuid, '$cand_2'::uuid, '$cand_3'::uuid)
      union all
      select app_user_id from public.app_users where app_user_id in ('$hr_full_id'::uuid, '$hr_view_id'::uuid)
      union all
      select unit_id from public.organizational_units where unit_id = '$unit_id'::uuid
    ) r;
  " | tr -d '\r')"

  if [[ "$remaining_count" -ne 0 ]]; then
    echo "FAIL: Cleanup left $remaining_count surviving fixture records!" >&2
    exit 1
  fi
  echo "PASS: Cleanup verified zero surviving fixture records."
  exit "$exit_code"
}

trap cleanup EXIT

echo "=== Setting up fixtures for REC-05 Concurrency & Boundary Verification ==="
psql_exec <<SQL
begin;
-- Org structure
insert into public.organizational_units(unit_id, code, name_vi)
values ('$unit_id'::uuid, 'U_${suffix}', 'Unit ${suffix}');

insert into public.position_groups(position_group_id, code, name_vi)
values ('$group_id'::uuid, 'G_${suffix}', 'Group ${suffix}');

insert into public.positions(position_id, unit_id, position_group_id, code, name_vi)
values ('$pos_id'::uuid, '$unit_id'::uuid, '$group_id'::uuid, 'P_${suffix}', 'Pos ${suffix}');

-- 1. Full HR user (submissions.view + submissions.status)
insert into public.app_users(app_user_id, auth_user_id, full_name, email, is_active, is_root_admin)
values ('$hr_full_id'::uuid, '$hr_full_auth'::uuid, 'HR Full ${suffix}', 'hr_full_${suffix}@eiu.edu.vn', true, false);

insert into public.app_user_roles(app_user_id, role_code) values ('$hr_full_id'::uuid, 'HR');

insert into public.app_user_permissions(app_user_id, permission_code) values
  ('$hr_full_id'::uuid, 'submissions.view'),
  ('$hr_full_id'::uuid, 'submissions.status');

-- 2. View-only HR user (submissions.view only)
insert into public.app_users(app_user_id, auth_user_id, full_name, email, is_active, is_root_admin)
values ('$hr_view_id'::uuid, '$hr_view_auth'::uuid, 'HR ViewOnly ${suffix}', 'hr_view_${suffix}@eiu.edu.vn', true, false);

insert into public.app_user_roles(app_user_id, role_code) values ('$hr_view_id'::uuid, 'HR');

insert into public.app_user_permissions(app_user_id, permission_code) values
  ('$hr_view_id'::uuid, 'submissions.view');

-- Current Privacy notice version
insert into public.privacy_notice_versions(notice_version, content_vi, content_en, content_hash_sha256, effective_from, is_current)
values ('2026-09-01-v1', 'Thỏa thuận bảo mật thông tin', 'Privacy Notice', repeat('a', 64), now() - interval '1 day', true)
on conflict (notice_version) do nothing;

-- 3. Candidate 1A + NEW submission + OPEN edit form session
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_1a'::uuid, '$cand_1a_auth'::uuid, 'cand_1a_${suffix}@example.com', true);

insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code, version_no)
values ('$sub_1a'::uuid, '$cand_1a'::uuid, 'Candidate 1A Original', '1995-01-01', 'FEMALE', 'Binh Duong', '0901000001', 'cand_1a_${suffix}@example.com', 'NEW', 1);

insert into public.candidate_form_sessions(
  candidate_form_session_id, candidate_id, mode_code, status_code,
  target_submission_id, base_submission_version_no, presented_privacy_notice_version, expires_at
) values (
  '$sess_1a'::uuid, '$cand_1a'::uuid, 'EDIT_SUBMISSION', 'OPEN',
  '$sub_1a'::uuid, 1, '2026-09-01-v1', clock_timestamp() + interval '2 hours'
);
-- Seed valid current CV document for sub_1a (required by update_candidate_submission)
insert into public.submission_document_logicals(logical_document_id, submission_id, document_type_id, created_by_candidate_id)
values ('$doc_log_1a'::uuid, '$sub_1a'::uuid, '$cv_document_type_id'::uuid, '$cand_1a'::uuid);

insert into public.submission_documents(
  logical_document_id, storage_bucket, storage_path, original_filename,
  mime_type, file_size_bytes, version_no, is_current, uploaded_by_candidate_id
) values (
  '$doc_log_1a'::uuid, 'candidate-documents', 'docs/cv_1a_${suffix}.pdf',
  'cv_1a_${suffix}.pdf', 'application/pdf', 1024, 1, true, '$cand_1a'::uuid
);

-- 4. Candidate 1B + NEW submission + OPEN edit form session
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_1b'::uuid, '$cand_1b_auth'::uuid, 'cand_1b_${suffix}@example.com', true);

insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code, version_no)
values ('$sub_1b'::uuid, '$cand_1b'::uuid, 'Candidate 1B Original', '1996-02-02', 'MALE', 'Ho Chi Minh', '0902000002', 'cand_1b_${suffix}@example.com', 'NEW', 1);

insert into public.candidate_form_sessions(
  candidate_form_session_id, candidate_id, mode_code, status_code,
  target_submission_id, base_submission_version_no, presented_privacy_notice_version, expires_at
) values (
  '$sess_1b'::uuid, '$cand_1b'::uuid, 'EDIT_SUBMISSION', 'OPEN',
  '$sub_1b'::uuid, 1, '2026-09-01-v1', clock_timestamp() + interval '2 hours'
);
-- Seed valid current CV document for sub_1b (required by update_candidate_submission)
insert into public.submission_document_logicals(logical_document_id, submission_id, document_type_id, created_by_candidate_id)
values ('$doc_log_1b'::uuid, '$sub_1b'::uuid, '$cv_document_type_id'::uuid, '$cand_1b'::uuid);

insert into public.submission_documents(
  logical_document_id, storage_bucket, storage_path, original_filename,
  mime_type, file_size_bytes, version_no, is_current, uploaded_by_candidate_id
) values (
  '$doc_log_1b'::uuid, 'candidate-documents', 'docs/cv_1b_${suffix}.pdf',
  'cv_1b_${suffix}.pdf', 'application/pdf', 1024, 1, true, '$cand_1b'::uuid
);

-- 5. Candidate 2 + NEW submission (for Permission Boundary testing)
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_2'::uuid, gen_random_uuid(), 'cand_2_${suffix}@example.com', true);

insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code, version_no)
values ('$sub_2'::uuid, '$cand_2'::uuid, 'Candidate 2', '1997-03-03', 'FEMALE', 'Binh Duong', '0903000003', 'cand_2_${suffix}@example.com', 'NEW', 1);

-- 6. Candidate 3 + Historical submission (NEW) and Latest submission (NEW)
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_3'::uuid, gen_random_uuid(), 'cand_3_${suffix}@example.com', true);

insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code, submitted_at, version_no)
values
  ('$sub_3_hist'::uuid, '$cand_3'::uuid, 'Candidate 3 Hist', '1998-04-04', 'MALE', 'Da Nang', '0904000004', 'cand_3_${suffix}@example.com', 'NEW', clock_timestamp() - interval '2 days', 1),
  ('$sub_3_latest'::uuid, '$cand_3'::uuid, 'Candidate 3 Latest', '1998-04-04', 'MALE', 'Da Nang', '0904000004', 'cand_3_${suffix}@example.com', 'NEW', clock_timestamp() - interval '1 hour', 1);

commit;
SQL

# =============================================================================
# SCENARIO 1A: Candidate Save acquires lock first, commits -> HR Open runs second
# =============================================================================
echo "--- Scenario 1A: Candidate Save commits first -> HR Open runs second ---"
s1a_cand_app="rec05_s1a_cand_${suffix}"
s1a_hr_app="rec05_s1a_hr_${suffix}"
registered_apps+=("$s1a_cand_app" "$s1a_hr_app")
out_s1a_cand="/tmp/${s1a_cand_app}.out"
out_s1a_hr="/tmp/${s1a_hr_app}.out"

# Candidate acquires lock via update_candidate_submission, holds lock for 2s via pg_sleep, then commits
s1a_cand_sql="set application_name='$s1a_cand_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$cand_1a_auth')::text,true); select public.update_candidate_submission('$sess_1a'::uuid, 'Candidate 1A Updated By Candidate', '0901999999', '1995-01-01'::date, 'FEMALE', 'Binh Duong New', '[]'::jsonb, '2026-09-01-v1', '$(new_uuid)'::uuid); select pg_sleep(2); commit;"
# HR starts concurrently and attempts open_submission, which must block on the row lock held by candidate
s1a_hr_sql="set application_name='$s1a_hr_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$hr_full_auth')::text,true); select public.open_submission('$sub_1a'::uuid); commit;"

run_sql_file "$s1a_cand_sql" "$out_s1a_cand" &
pid_1a_cand=$!
registered_pids+=("$pid_1a_cand")

sleep 0.25

run_sql_file "$s1a_hr_sql" "$out_s1a_hr" &
pid_1a_hr=$!
registered_pids+=("$pid_1a_hr")

wait_for_lock_wait "$s1a_hr_app"
echo "PASS: HR open_submission cleanly waited on candidate update lock without deadlock."

wait "$pid_1a_cand"
wait "$pid_1a_hr"

if grep -qi 'deadlock detected' "$out_s1a_cand" "$out_s1a_hr"; then
  echo "FAIL: Deadlock detected in Scenario 1A:" >&2
  cat "$out_s1a_cand" "$out_s1a_hr" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s1a_cand"; then
  echo "FAIL: Candidate save did not succeed in Scenario 1A:" >&2
  cat "$out_s1a_cand" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s1a_hr" || ! grep -q '"status_code": "READ"' "$out_s1a_hr"; then
  echo "FAIL: HR open did not succeed with READ status in Scenario 1A:" >&2
  cat "$out_s1a_hr" >&2
  exit 1
fi

# Assert final DB state:
# 1. Candidate's updated fields were preserved:
psql_exec -qAt -c "select full_name from public.submissions where submission_id='$sub_1a'::uuid;" | tr -d '\r' | grep -qx 'Candidate 1A Updated By Candidate'
psql_exec -qAt -c "select phone from public.submissions where submission_id='$sub_1a'::uuid;" | tr -d '\r' | grep -qx '0901999999'
# 2. Final status is READ (from HR open):
psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_1a'::uuid;" | tr -d '\r' | grep -qx 'READ'
# 3. Version number is 3 (1 -> 2 from candidate save, 2 -> 3 from HR open):
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_1a'::uuid;" | tr -d '\r' | grep -qx '3'

echo "PASS: Scenario 1A Candidate save committed first, HR open committed second -> clean serialization and preserved candidate changes."

# =============================================================================
# SCENARIO 1B: HR Open acquires lock first, commits READ -> Candidate Save rejects
# =============================================================================
echo "--- Scenario 1B: HR Open commits first -> Candidate Save rejects with INVALID_STATE ---"
s1b_hr_app="rec05_s1b_hr_${suffix}"
s1b_cand_app="rec05_s1b_cand_${suffix}"
registered_apps+=("$s1b_hr_app" "$s1b_cand_app")
out_s1b_hr="/tmp/${s1b_hr_app}.out"
out_s1b_cand="/tmp/${s1b_cand_app}.out"

# HR locks submission via open_submission, sleeps 2s, then commits
s1b_hr_sql="set application_name='$s1b_hr_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$hr_full_auth')::text,true); select public.open_submission('$sub_1b'::uuid); select pg_sleep(2); commit;"
# Candidate starts concurrently and attempts update_candidate_submission, which must block on HR's lock
s1b_cand_sql="set application_name='$s1b_cand_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$cand_1b_auth')::text,true); select public.update_candidate_submission('$sess_1b'::uuid, 'Candidate 1B Overwrite Attempt', '0902999999', '1996-02-02'::date, 'MALE', 'Ho Chi Minh New', '[]'::jsonb, '2026-09-01-v1', '$(new_uuid)'::uuid); commit;"

run_sql_file "$s1b_hr_sql" "$out_s1b_hr" &
pid_1b_hr=$!
registered_pids+=("$pid_1b_hr")

sleep 0.25

run_sql_file "$s1b_cand_sql" "$out_s1b_cand" &
pid_1b_cand=$!
registered_pids+=("$pid_1b_cand")

wait_for_lock_wait "$s1b_cand_app"
echo "PASS: Candidate update_candidate_submission cleanly waited on HR open lock without deadlock."

wait "$pid_1b_hr"
wait "$pid_1b_cand"

if grep -qi 'deadlock detected' "$out_s1b_hr" "$out_s1b_cand"; then
  echo "FAIL: Deadlock detected in Scenario 1B:" >&2
  cat "$out_s1b_hr" "$out_s1b_cand" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s1b_hr" || ! grep -q '"status_code": "READ"' "$out_s1b_hr"; then
  echo "FAIL: HR open did not succeed with READ status in Scenario 1B:" >&2
  cat "$out_s1b_hr" >&2
  exit 1
fi

# Candidate save MUST be rejected with INVALID_STATE because submission is already READ
if ! grep -q '"success": false' "$out_s1b_cand" || ! grep -q 'INVALID_STATE' "$out_s1b_cand"; then
  echo "FAIL: Candidate save did not reject with INVALID_STATE in Scenario 1B:" >&2
  cat "$out_s1b_cand" >&2
  exit 1
fi

# Assert final DB state:
# 1. Candidate's overwrite attempt was NOT applied (full_name remains original):
psql_exec -qAt -c "select full_name from public.submissions where submission_id='$sub_1b'::uuid;" | tr -d '\r' | grep -qx 'Candidate 1B Original'
psql_exec -qAt -c "select phone from public.submissions where submission_id='$sub_1b'::uuid;" | tr -d '\r' | grep -qx '0902000002'
# 2. Final status is READ (from HR open):
psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_1b'::uuid;" | tr -d '\r' | grep -qx 'READ'
# 3. Version number is 2 (1 -> 2 from HR open, zero increment from rejected candidate save):
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_1b'::uuid;" | tr -d '\r' | grep -qx '2'

echo "PASS: Scenario 1B HR open committed first -> Candidate save failed closed with INVALID_STATE, zero overwrite."

# =============================================================================
# SCENARIO 2: Permission boundaries for open_submission
# =============================================================================
echo "--- Scenario 2: Permission boundaries for open_submission ---"

# 2.1 Unauthorized user (no submissions.view) -> FORBIDDEN
unauth_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$unauth_auth')::text, true);
  select public.open_submission('$sub_2'::uuid);
  commit;
" | tr -d '\r')"

if ! echo "$unauth_res" | grep -q '"success": false' || ! echo "$unauth_res" | grep -q 'FORBIDDEN'; then
  echo "FAIL: Unauthorized user was not rejected with FORBIDDEN: $unauth_res" >&2
  exit 1
fi
echo "PASS: 2.1 Unauthorized user rejected with FORBIDDEN."

# 2.2 View-only HR (submissions.view only) -> success: true, status_code: NEW, nonmutating read
view_only_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_view_auth')::text, true);
  select public.open_submission('$sub_2'::uuid);
  commit;
" | tr -d '\r')"

if ! echo "$view_only_res" | grep -q '"success": true' || ! echo "$view_only_res" | grep -q '"status_code": "NEW"'; then
  echo "FAIL: View-only HR did not return success with status NEW: $view_only_res" >&2
  exit 1
fi

# Assert DB row was NOT mutated (still NEW, version_no still 1)
psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_2'::uuid;" | tr -d '\r' | grep -qx 'NEW'
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_2'::uuid;" | tr -d '\r' | grep -qx '1'
echo "PASS: 2.2 View-only HR open is nonmutating; database row remains NEW with version 1."

# 2.3 Authorized HR (submissions.view + submissions.status) -> atomically transitions NEW -> READ, version bumped
full_hr_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_full_auth')::text, true);
  select public.open_submission('$sub_2'::uuid);
  commit;
" | tr -d '\r')"

if ! echo "$full_hr_res" | grep -q '"success": true' || ! echo "$full_hr_res" | grep -q '"status_code": "READ"'; then
  echo "FAIL: Authorized HR did not transition submission to READ: $full_hr_res" >&2
  exit 1
fi

# Assert DB row was updated to READ with version 2
psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_2'::uuid;" | tr -d '\r' | grep -qx 'READ'
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_2'::uuid;" | tr -d '\r' | grep -qx '2'
echo "PASS: 2.3 Authorized HR open atomically transitioned NEW -> READ with version bumped to 2."

# =============================================================================
# SCENARIO 3: Historical vs Latest submissions and idempotent re-open
# =============================================================================
echo "--- Scenario 3: Historical vs Latest submissions and idempotent re-open ---"

# 3.1 Open historical submission: transitions historical to READ, leaves latest as NEW
open_hist_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_full_auth')::text, true);
  select public.open_submission('$sub_3_hist'::uuid);
  commit;
" | tr -d '\r')"

if ! echo "$open_hist_res" | grep -q '"success": true' || ! echo "$open_hist_res" | grep -q '"status_code": "READ"'; then
  echo "FAIL: Opening historical submission did not return READ: $open_hist_res" >&2
  exit 1
fi

psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_3_hist'::uuid;" | tr -d '\r' | grep -qx 'READ'
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_3_hist'::uuid;" | tr -d '\r' | grep -qx '2'
# Latest submission MUST still be NEW with version 1
psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_3_latest'::uuid;" | tr -d '\r' | grep -qx 'NEW'
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_3_latest'::uuid;" | tr -d '\r' | grep -qx '1'
echo "PASS: 3.1 Opening historical submission transitioned only historical to READ; latest remained NEW."

# 3.2 Open latest submission: transitions latest to READ
open_latest_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_full_auth')::text, true);
  select public.open_submission('$sub_3_latest'::uuid);
  commit;
" | tr -d '\r')"

if ! echo "$open_latest_res" | grep -q '"success": true' || ! echo "$open_latest_res" | grep -q '"status_code": "READ"'; then
  echo "FAIL: Opening latest submission did not return READ: $open_latest_res" >&2
  exit 1
fi

psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_3_latest'::uuid;" | tr -d '\r' | grep -qx 'READ'
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_3_latest'::uuid;" | tr -d '\r' | grep -qx '2'
echo "PASS: 3.2 Opening latest submission transitioned latest to READ with version 2."

# 3.3 Idempotent re-open on already READ submission: returns success with READ, version unchanged
reopen_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_full_auth')::text, true);
  select public.open_submission('$sub_3_latest'::uuid);
  commit;
" | tr -d '\r')"

if ! echo "$reopen_res" | grep -q '"success": true' || ! echo "$reopen_res" | grep -q '"status_code": "READ"'; then
  echo "FAIL: Re-opening already READ submission failed: $reopen_res" >&2
  exit 1
fi

psql_exec -qAt -c "select status_code from public.submissions where submission_id='$sub_3_latest'::uuid;" | tr -d '\r' | grep -qx 'READ'
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_3_latest'::uuid;" | tr -d '\r' | grep -qx '2'
echo "PASS: 3.3 Re-opening already READ submission is idempotent (status READ, version 2 unchanged)."

echo "====================================================================="
echo "=== ALL REC-05 CONCURRENCY & BOUNDARY TESTS PASSED CLEANLY        ==="
echo "====================================================================="
