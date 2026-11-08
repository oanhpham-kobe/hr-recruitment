#!/usr/bin/env bash
# =============================================================================
# RECOVERY PACKAGE 005: REC-15 Whole HR Submission Editing Concurrency & Invariants
#
# Covers:
#   PG1: Two-session concurrent aggregate save & optimistic version serialization
#     Writer A commits aggregate update (version 1 -> 2)
#     Writer B waiting on lock detects STALE_VERSION and aborts with zero partial write
#   PG2: Granular permissions:
#     Caller without submissions.edit rejected with FORBIDDEN
#     Caller with submissions.edit succeeds
#   PG3: Email snapshot strict immutability:
#     Verified candidate email cannot be modified by HR aggregate update
#   PG4: Master data active validation:
#     Inactive recruitment source or qualification level rejected with INVALID_MASTER_DATA
#   PG5: Candidate profile cache refresh:
#     Updating latest submission refreshes candidate profile cache
#     Updating older historical submission does not alter profile cache
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

unit_id="$(new_uuid)"
group_id="$(new_uuid)"
pos_id="$(new_uuid)"

# Actors
hr_edit_id="$(new_uuid)"
hr_edit_auth="$(new_uuid)"

hr_view_id="$(new_uuid)"
hr_view_auth="$(new_uuid)"

# Master data test fixtures
src_active_id="$(new_uuid)"
src_inactive_id="$(new_uuid)"

qual_active_id="$(new_uuid)"
qual_inactive_id="$(new_uuid)"

# Fixtures for Scenario 1 (Concurrent HR save)
cand_1="$(new_uuid)"
sub_1="$(new_uuid)"

# Fixtures for Scenario 2, 3, 4 (Permission, immutability, master data)
cand_2="$(new_uuid)"
sub_2="$(new_uuid)"

# Fixtures for Scenario 5 (Latest vs Historical profile cache)
cand_5="$(new_uuid)"
sub_5_hist="$(new_uuid)"
sub_5_latest="$(new_uuid)"

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

  rm -f /tmp/rec15_*_${suffix}.* 2>/dev/null || true

  echo "=== Running REC-15 Fixture Cleanup ==="
  psql_exec <<SQL
begin;
delete from public.submission_education
where submission_id in ('$sub_1'::uuid, '$sub_2'::uuid, '$sub_5_hist'::uuid, '$sub_5_latest'::uuid);

delete from public.submissions
where submission_id in ('$sub_1'::uuid, '$sub_2'::uuid, '$sub_5_hist'::uuid, '$sub_5_latest'::uuid);

delete from public.candidates
where candidate_id in ('$cand_1'::uuid, '$cand_2'::uuid, '$cand_5'::uuid);

delete from public.app_user_permissions
where app_user_id in ('$hr_edit_id'::uuid, '$hr_view_id'::uuid);

delete from public.app_user_roles
where app_user_id in ('$hr_edit_id'::uuid, '$hr_view_id'::uuid);

delete from public.app_users
where app_user_id in ('$hr_edit_id'::uuid, '$hr_view_id'::uuid);

delete from public.recruitment_sources
where recruitment_source_id in ('$src_active_id'::uuid, '$src_inactive_id'::uuid);

delete from public.qualification_levels
where qualification_id in ('$qual_active_id'::uuid, '$qual_inactive_id'::uuid);

delete from public.positions where position_id = '$pos_id'::uuid;
delete from public.position_groups where position_group_id = '$group_id'::uuid;
delete from public.organizational_units where unit_id = '$unit_id'::uuid;
commit;
SQL

  local remaining_count
  remaining_count="$(psql_exec -qAt -c "
    select count(*) from (
      select candidate_id from public.candidates where candidate_id in ('$cand_1'::uuid, '$cand_2'::uuid, '$cand_5'::uuid)
      union all
      select app_user_id from public.app_users where app_user_id in ('$hr_edit_id'::uuid, '$hr_view_id'::uuid)
      union all
      select recruitment_source_id from public.recruitment_sources where recruitment_source_id in ('$src_active_id'::uuid, '$src_inactive_id'::uuid)
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

echo "=== Setting up fixtures for REC-15 Concurrency & Invariants Verification ==="
psql_exec <<SQL
begin;
-- Org structure
insert into public.organizational_units(unit_id, code, name_vi)
values ('$unit_id'::uuid, 'U_${suffix}', 'Unit ${suffix}');

insert into public.position_groups(position_group_id, code, name_vi)
values ('$group_id'::uuid, 'G_${suffix}', 'Group ${suffix}');

insert into public.positions(position_id, unit_id, position_group_id, code, name_vi)
values ('$pos_id'::uuid, '$unit_id'::uuid, '$group_id'::uuid, 'P_${suffix}', 'Pos ${suffix}');

-- 1. Full HR user with submissions.edit and submissions.view
insert into public.app_users(app_user_id, auth_user_id, full_name, email, is_active, is_root_admin)
values ('$hr_edit_id'::uuid, '$hr_edit_auth'::uuid, 'HR Edit ${suffix}', 'hr_edit_${suffix}@eiu.edu.vn', true, false);

insert into public.app_user_roles(app_user_id, role_code) values ('$hr_edit_id'::uuid, 'HR');

insert into public.app_user_permissions(app_user_id, permission_code) values
  ('$hr_edit_id'::uuid, 'submissions.view'),
  ('$hr_edit_id'::uuid, 'submissions.edit');

-- 2. View-only HR user (submissions.view only)
insert into public.app_users(app_user_id, auth_user_id, full_name, email, is_active, is_root_admin)
values ('$hr_view_id'::uuid, '$hr_view_auth'::uuid, 'HR ViewOnly ${suffix}', 'hr_view_${suffix}@eiu.edu.vn', true, false);

insert into public.app_user_roles(app_user_id, role_code) values ('$hr_view_id'::uuid, 'HR');

insert into public.app_user_permissions(app_user_id, permission_code) values
  ('$hr_view_id'::uuid, 'submissions.view');

-- 3. Master data items (Active vs Inactive)
insert into public.recruitment_sources(recruitment_source_id, code, name_vi, is_active)
values
  ('$src_active_id'::uuid, 'SRC_ACT_${suffix}', 'Active Source ${suffix}', true),
  ('$src_inactive_id'::uuid, 'SRC_INACT_${suffix}', 'Inactive Source ${suffix}', false);

insert into public.qualification_levels(qualification_id, code, name_vi, is_active)
values
  ('$qual_active_id'::uuid, 'Q_ACT_${suffix}', 'Active Qual ${suffix}', true),
  ('$qual_inactive_id'::uuid, 'Q_INACT_${suffix}', 'Inactive Qual ${suffix}', false);

-- 4. Candidate 1 + Submission 1 (for Scenario 1: Concurrent HR save)
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_1'::uuid, gen_random_uuid(), 'cand_1_${suffix}@example.com', true);

insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code, version_no)
values ('$sub_1'::uuid, '$cand_1'::uuid, 'Candidate 1 Original', '1995-01-01', 'MALE', 'Original Address', '0901000001', 'verified_cand1_${suffix}@example.com', 'READ', 1);

insert into public.submission_education(submission_id, sort_order, period_text, institution, major, qualification_id)
values ('$sub_1'::uuid, 1, '2013-2017', 'Original University', 'Computer Science', '$qual_active_id'::uuid);

-- 5. Candidate 2 + Submission 2 (for Scenarios 2, 3, 4)
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_2'::uuid, gen_random_uuid(), 'cand_2_${suffix}@example.com', true);

insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code, version_no)
values ('$sub_2'::uuid, '$cand_2'::uuid, 'Candidate 2 Original', '1996-02-02', 'FEMALE', 'Binh Duong', '0902000002', 'verified_cand2_${suffix}@example.com', 'READ', 1);

-- 6. Candidate 5 + Historical Submission and Latest Submission (for Scenario 5: Profile cache)
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('$cand_5'::uuid, gen_random_uuid(), 'cand_5_${suffix}@example.com', true);

insert into public.submissions(submission_id, candidate_id, full_name, date_of_birth, gender_code, current_address, phone, email_snapshot, status_code, submitted_at, version_no)
values
  ('$sub_5_hist'::uuid, '$cand_5'::uuid, 'Cand 5 Old Name', '1997-03-03', 'MALE', 'Old City', '0905000001', 'cand5_${suffix}@example.com', 'READ', clock_timestamp() - interval '2 days', 1),
  ('$sub_5_latest'::uuid, '$cand_5'::uuid, 'Cand 5 Latest Name', '1997-03-03', 'MALE', 'Latest City', '0905000002', 'cand5_${suffix}@example.com', 'READ', clock_timestamp() - interval '1 hour', 1);

-- Initialize candidate 5 profile cache to match latest submission
select private.refresh_candidate_current_profile('$cand_5'::uuid);

commit;
SQL

# =============================================================================
# SCENARIO 1: Two-session concurrent aggregate save & version serialization
# =============================================================================
echo "--- Scenario 1: Concurrent HR aggregate save & version serialization ---"
s1_hr_a_app="rec15_s1_a_${suffix}"
s1_hr_b_app="rec15_s1_b_${suffix}"
registered_apps+=("$s1_hr_a_app" "$s1_hr_b_app")
out_s1_a="/tmp/${s1_hr_a_app}.out"
out_s1_b="/tmp/${s1_hr_b_app}.out"

# Writer A updates full name, phone, address, and education; holds lock for 2s via pg_sleep, commits
s1_a_sql="set application_name='$s1_hr_a_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$hr_edit_auth')::text,true); select public.update_submission_aggregate_by_hr('$sub_1'::uuid, 1, 'Candidate 1 Updated by A', '0901888888', '1995-01-01'::date, 'MALE', 'Address by A', '$src_active_id'::uuid, 'HR note by A', jsonb_build_array(jsonb_build_object('period_text','2013-2018','institution','Updated Uni','major','SE','qualification_id','$qual_active_id')), 'Reason A'); select pg_sleep(2); commit;"

# Writer B concurrently attempts to save based on stale expected_version = 1
s1_b_sql="set application_name='$s1_hr_b_app'; set statement_timeout='15s'; begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$hr_edit_auth')::text,true); select public.update_submission_aggregate_by_hr('$sub_1'::uuid, 1, 'Candidate 1 Overwrite by B', '0901777777', '1995-01-01'::date, 'MALE', 'Address by B', '$src_active_id'::uuid, 'HR note by B', null, 'Reason B'); commit;"

run_sql_file "$s1_a_sql" "$out_s1_a" &
pid_1_a=$!
registered_pids+=("$pid_1_a")

sleep 0.25

run_sql_file "$s1_b_sql" "$out_s1_b" &
pid_1_b=$!
registered_pids+=("$pid_1_b")

wait_for_lock_wait "$s1_hr_b_app"
echo "PASS: Writer B cleanly waited on Writer A row lock without deadlock."

wait "$pid_1_a"
wait "$pid_1_b"

if grep -qi 'deadlock detected' "$out_s1_a" "$out_s1_b"; then
  echo "FAIL: Deadlock detected in Scenario 1:" >&2
  cat "$out_s1_a" "$out_s1_b" >&2
  exit 1
fi

if ! grep -q '"success": true' "$out_s1_a"; then
  echo "FAIL: Writer A did not succeed:" >&2
  cat "$out_s1_a" >&2
  exit 1
fi

# Writer B must be rejected with STALE_VERSION
if ! grep -q '"success": false' "$out_s1_b" || ! grep -q 'STALE_VERSION' "$out_s1_b"; then
  echo "FAIL: Writer B did not reject with STALE_VERSION:" >&2
  cat "$out_s1_b" >&2
  exit 1
fi

# Assert final DB state:
# 1. Writer A's updates committed:
psql_exec -qAt -c "select full_name from public.submissions where submission_id='$sub_1'::uuid;" | tr -d '\r' | grep -qx 'Candidate 1 Updated by A'
psql_exec -qAt -c "select phone from public.submissions where submission_id='$sub_1'::uuid;" | tr -d '\r' | grep -qx '0901888888'
psql_exec -qAt -c "select current_address from public.submissions where submission_id='$sub_1'::uuid;" | tr -d '\r' | grep -qx 'Address by A'
psql_exec -qAt -c "select hr_note from public.submissions where submission_id='$sub_1'::uuid;" | tr -d '\r' | grep -qx 'HR note by A'
# 2. Education updated:
psql_exec -qAt -c "select institution from public.submission_education where submission_id='$sub_1'::uuid;" | tr -d '\r' | grep -qx 'Updated Uni'
# 3. Version number is 2:
psql_exec -qAt -c "select version_no::text from public.submissions where submission_id='$sub_1'::uuid;" | tr -d '\r' | grep -qx '2'

echo "PASS: Scenario 1 concurrent save serialized cleanly; Writer A succeeded, Writer B rejected with STALE_VERSION."

# =============================================================================
# SCENARIO 2: Granular permission boundary
# =============================================================================
echo "--- Scenario 2: Granular permissions for update_submission_aggregate_by_hr ---"

# 2.1 View-only HR (lacks submissions.edit) -> FORBIDDEN
view_only_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_view_auth')::text, true);
  select public.update_submission_aggregate_by_hr('$sub_2'::uuid, 1, 'Attempted Name');
  commit;
" | tr -d '\r')"

if ! echo "$view_only_res" | grep -q '"success": false' || ! echo "$view_only_res" | grep -q 'FORBIDDEN'; then
  echo "FAIL: View-only HR was not rejected with FORBIDDEN: $view_only_res" >&2
  exit 1
fi
echo "PASS: 2.1 Caller without submissions.edit rejected with FORBIDDEN."

# 2.2 Authorized HR with submissions.edit -> succeeds
edit_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_edit_auth')::text, true);
  select public.update_submission_aggregate_by_hr('$sub_2'::uuid, 1, 'Candidate 2 Name Edited by HR', '0902111111', '1996-02-02'::date, 'FEMALE', 'Binh Duong New', '$src_active_id'::uuid, 'Note 2');
  commit;
" | tr -d '\r')"

if ! echo "$edit_res" | grep -q '"success": true'; then
  echo "FAIL: Authorized HR edit failed: $edit_res" >&2
  exit 1
fi
echo "PASS: 2.2 Authorized HR edit succeeded with version increment."

# =============================================================================
# SCENARIO 3: Verified email snapshot strict immutability
# =============================================================================
echo "--- Scenario 3: Email snapshot strict immutability ---"

# Query email before and after updates
email_before="verified_cand2_${suffix}@example.com"
email_after="$(psql_exec -qAt -c "select email_snapshot::text from public.submissions where submission_id='$sub_2'::uuid;" | tr -d '\r')"

if [[ "$email_after" != "$email_before" ]]; then
  echo "FAIL: Email snapshot was altered! (expected '$email_before', got '$email_after')" >&2
  exit 1
fi
echo "PASS: Verified candidate email remains strictly immutable after HR aggregate update."

# =============================================================================
# SCENARIO 4: Master data active validation
# =============================================================================
echo "--- Scenario 4: Master data active validation ---"

# 4.1 Inactive recruitment source rejected with INVALID_MASTER_DATA
inact_src_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_edit_auth')::text, true);
  select public.update_submission_aggregate_by_hr('$sub_2'::uuid, 2, null, null, null, null, null, '$src_inactive_id'::uuid);
  commit;
" | tr -d '\r')"

if ! echo "$inact_src_res" | grep -q '"success": false' || ! echo "$inact_src_res" | grep -q 'INVALID_MASTER_DATA'; then
  echo "FAIL: Inactive recruitment source was not rejected with INVALID_MASTER_DATA: $inact_src_res" >&2
  exit 1
fi
echo "PASS: 4.1 Inactive recruitment source rejected with INVALID_MASTER_DATA."

# 4.2 Inactive qualification level in education rejected with INVALID_MASTER_DATA
inact_qual_res="$(psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_edit_auth')::text, true);
  select public.update_submission_aggregate_by_hr('$sub_2'::uuid, 2, null, null, null, null, null, null, null, jsonb_build_array(jsonb_build_object('institution_name','Test','qualification_id','$qual_inactive_id')));
  commit;
" | tr -d '\r')"

if ! echo "$inact_qual_res" | grep -q '"success": false' || ! echo "$inact_qual_res" | grep -q 'INVALID_MASTER_DATA'; then
  echo "FAIL: Inactive qualification level was not rejected with INVALID_MASTER_DATA: $inact_qual_res" >&2
  exit 1
fi
echo "PASS: 4.2 Inactive qualification level rejected with INVALID_MASTER_DATA."

# =============================================================================
# SCENARIO 5: Candidate profile cache refresh semantics
# =============================================================================
echo "--- Scenario 5: Candidate profile cache refresh semantics ---"

# 5.1 Updating older historical submission does NOT alter candidate's latest profile cache
psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_edit_auth')::text, true);
  select public.update_submission_aggregate_by_hr('$sub_5_hist'::uuid, 1, 'Historical Correction');
  commit;
" >/dev/null

# Candidate's current profile must STILL match latest submission ('Cand 5 Latest Name')
cand_name="$(psql_exec -qAt -c "select current_full_name from public.candidates where candidate_id='$cand_5'::uuid;" | tr -d '\r')"
if [[ "$cand_name" != "Cand 5 Latest Name" ]]; then
  echo "FAIL: Updating historical submission altered candidate profile cache! (got '$cand_name')" >&2
  exit 1
fi
echo "PASS: 5.1 Editing historical submission did not alter candidate latest profile cache."

# 5.2 Updating latest submission refreshes candidate profile cache
psql_exec -qAt -c "
  begin;
  select set_config('request.jwt.claims', jsonb_build_object('sub', '$hr_edit_auth')::text, true);
  select public.update_submission_aggregate_by_hr('$sub_5_latest'::uuid, 1, 'Candidate 5 Fresh Name');
  commit;
" >/dev/null

cand_name_updated="$(psql_exec -qAt -c "select current_full_name from public.candidates where candidate_id='$cand_5'::uuid;" | tr -d '\r')"
if [[ "$cand_name_updated" != "Candidate 5 Fresh Name" ]]; then
  echo "FAIL: Updating latest submission failed to refresh candidate profile cache! (got '$cand_name_updated')" >&2
  exit 1
fi
echo "PASS: 5.2 Editing latest submission refreshed candidate profile cache."

echo "====================================================================="
echo "=== ALL REC-15 CONCURRENCY & INVARIANT TESTS PASSED CLEANLY       ==="
echo "====================================================================="
