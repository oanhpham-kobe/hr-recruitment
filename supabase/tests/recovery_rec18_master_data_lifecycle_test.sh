#!/usr/bin/env bash
# =============================================================================
# RECOVERY PACKAGE 006: REC-18 Master Data Management Lifecycle & Concurrency
#
# Covers:
#   PG1: Authorized Master Data Lifecycle:
#     create_master_item -> returns version 1, is_active true
#     update_master_item -> returns version 2
#   PG2: Optimistic Version Concurrency:
#     Mismatched expected_version_no rejected with STALE_VERSION
#   PG3: Unreferenced Item Hard Delete:
#     delete_or_inactivate_master_item -> outcome DELETED, row removed
#   PG4: Referenced Item Inactivation & Historical Preservation:
#     delete_or_inactivate_master_item on referenced item -> outcome INACTIVATED,
#     row preserved with is_active false, existing historical records unaffected
#   PG5: Authorization Boundary:
#     Caller without master_data.manage rejected with FORBIDDEN
# =============================================================================
set -euo pipefail

container_name="${CONTAINER_NAME:-supabase_db_eiu-recruitment-dev}"

psql_exec() {
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

run_as_actor() {
  local auth_uid="$1"
  local sql="$2"
  psql_exec -qAt <<SQL | tail -n 1
set role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', '$auth_uid')::text, false);
$sql
SQL
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

# Actors
admin_user_id="$(new_uuid)"
admin_auth_uid="$(new_uuid)"

unauth_user_id="$(new_uuid)"
unauth_auth_uid="$(new_uuid)"

# Master items
qual_id="$(new_uuid)"
room_unref_id="$(new_uuid)"
qual_ref_id="$(new_uuid)"

# Fixtures for referenced check
cand_id="$(new_uuid)"
cand_auth_uid="$(new_uuid)"
sub_id="$(new_uuid)"
edu_id="$(new_uuid)"

cleanup() {
  echo "==> Cleaning up test fixtures..."
  psql_exec <<SQL >/dev/null 2>&1 || true
delete from public.submission_education where education_id = '$edu_id'::uuid;
delete from public.submissions where submission_id = '$sub_id'::uuid;
delete from public.candidates where candidate_id = '$cand_id'::uuid;
delete from public.rooms where room_id = '$room_unref_id'::uuid;
delete from public.qualification_levels where qualification_id in ('$qual_id'::uuid, '$qual_ref_id'::uuid);
delete from public.app_user_permissions where app_user_id in ('$admin_user_id'::uuid, '$unauth_user_id'::uuid);
delete from public.app_users where app_user_id in ('$admin_user_id'::uuid, '$unauth_user_id'::uuid);
delete from auth.users where id in ('$admin_auth_uid'::uuid, '$unauth_auth_uid'::uuid, '$cand_auth_uid'::uuid);
SQL
}
trap cleanup EXIT

echo "==> Setting up security actors and permissions..."
psql_exec <<SQL
insert into auth.users (id, email)
values
  ('$admin_auth_uid'::uuid, 'master_admin_$suffix@eiu.edu.vn'),
  ('$unauth_auth_uid'::uuid, 'unauth_user_$suffix@eiu.edu.vn');

insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_active)
values
  ('$admin_user_id'::uuid, '$admin_auth_uid'::uuid, 'master_admin_$suffix@eiu.edu.vn', 'Master Admin', true),
  ('$unauth_user_id'::uuid, '$unauth_auth_uid'::uuid, 'unauth_user_$suffix@eiu.edu.vn', 'Unauth User', true);

-- admin gets master_data.manage permission
insert into public.app_user_permissions (app_user_id, permission_code)
values ('$admin_user_id'::uuid, 'master_data.manage');

-- unauth user gets no permissions
SQL

# =============================================================================
# SCENARIO 1: Authorized Master Data Lifecycle (Create -> Update)
# =============================================================================
echo "==> Running Scenario 1: Authorized Master Data Lifecycle..."
res_s1=$(run_as_actor "$admin_auth_uid" "
select public.create_master_item(
  'qualification_levels',
  jsonb_build_object(
    'code', 'QUAL_S1_$suffix',
    'name_vi', 'Kỹ sư chuyên ngành',
    'name_en', 'Specialized Engineer'
  ),
  gen_random_uuid()
);
")

echo "Create result: $res_s1"
s1_success=$(psql_exec -qAt -c "select ('$res_s1'::jsonb ->> 'success')::boolean;")
s1_master_id=$(psql_exec -qAt -c "select '$res_s1'::jsonb -> 'data' ->> 'master_id';")
s1_version=$(psql_exec -qAt -c "select ('$res_s1'::jsonb -> 'data' ->> 'version_no')::int;")
s1_active=$(psql_exec -qAt -c "select ('$res_s1'::jsonb -> 'data' ->> 'is_active')::boolean;")

if [[ "$s1_success" != "t" || "$s1_version" != "1" || "$s1_active" != "t" ]]; then
  echo "FAIL: Scenario 1 create_master_item did not return expected initial state"
  exit 1
fi

# Update master item
res_s1_upd=$(run_as_actor "$admin_auth_uid" "
select public.update_master_item(
  'qualification_levels',
  '$s1_master_id'::uuid,
  jsonb_build_object(
    'name_vi', 'Kỹ sư chuyên ngành chất lượng cao'
  ),
  1,
  gen_random_uuid()
);
")

echo "Update result: $res_s1_upd"
s1_upd_success=$(psql_exec -qAt -c "select ('$res_s1_upd'::jsonb ->> 'success')::boolean;")
s1_upd_version=$(psql_exec -qAt -c "select ('$res_s1_upd'::jsonb -> 'data' ->> 'version_no')::int;")

if [[ "$s1_upd_success" != "t" || "$s1_upd_version" != "2" ]]; then
  echo "FAIL: Scenario 1 update_master_item did not increment version to 2"
  exit 1
fi
echo "PASS: Scenario 1 - Authorized Lifecycle"

# =============================================================================
# SCENARIO 2: Optimistic Version Concurrency / Conflict (STALE_VERSION)
# =============================================================================
echo "==> Running Scenario 2: Optimistic Version Concurrency..."
res_s2=$(run_as_actor "$admin_auth_uid" "
-- Attempting update with expected_version = 1 while row is already version 2
select public.update_master_item(
  'qualification_levels',
  '$s1_master_id'::uuid,
  jsonb_build_object(
    'name_vi', 'Stale update attempt'
  ),
  1,
  gen_random_uuid()
);
")

echo "Stale update result: $res_s2"
s2_err=$(psql_exec -qAt -c "select '$res_s2'::jsonb ->> 'error_code';")
if [[ "$s2_err" != "STALE_VERSION" ]]; then
  echo "FAIL: Scenario 2 expected STALE_VERSION but got '$s2_err'"
  exit 1
fi
echo "PASS: Scenario 2 - Optimistic Version Concurrency"

# =============================================================================
# SCENARIO 3: Unreferenced Item Hard Delete (Outcome: DELETED)
# =============================================================================
echo "==> Running Scenario 3: Unreferenced Item Hard Delete..."
# Create an unreferenced room
res_s3_create=$(run_as_actor "$admin_auth_uid" "
select public.create_master_item(
  'rooms',
  jsonb_build_object(
    'code', 'ROOM_UNREF_$suffix',
    'display_name', 'Phòng Thử Nghiệm Xóa',
    'building', 'Tòa T'
  ),
  gen_random_uuid()
);
")

s3_room_id=$(psql_exec -qAt -c "select '$res_s3_create'::jsonb -> 'data' ->> 'master_id';")
room_unref_id="$s3_room_id"

# Delete unreferenced room
res_s3_del=$(run_as_actor "$admin_auth_uid" "
select public.delete_or_inactivate_master_item(
  'rooms',
  '$s3_room_id'::uuid,
  1,
  gen_random_uuid()
);
")

echo "Delete result: $res_s3_del"
s3_outcome=$(psql_exec -qAt -c "select '$res_s3_del'::jsonb -> 'data' ->> 'outcome';")
if [[ "$s3_outcome" != "DELETED" ]]; then
  echo "FAIL: Scenario 3 expected DELETED outcome but got '$s3_outcome'"
  exit 1
fi

# Verify row is removed from table
s3_exists=$(psql_exec -qAt -c "select count(*) from public.rooms where room_id = '$s3_room_id'::uuid;")
if [[ "$s3_exists" != "0" ]]; then
  echo "FAIL: Scenario 3 room row was not deleted from database"
  exit 1
fi
echo "PASS: Scenario 3 - Unreferenced Hard Delete"

# =============================================================================
# SCENARIO 4: Referenced Item Inactivation & Historical Preservation (Outcome: INACTIVATED)
# =============================================================================
echo "==> Running Scenario 4: Referenced Item Inactivation & History Preservation..."
# Create qualification level to be referenced
res_s4_create=$(run_as_actor "$admin_auth_uid" "
select public.create_master_item(
  'qualification_levels',
  jsonb_build_object(
    'code', 'QUAL_REF_$suffix',
    'name_vi', 'Bằng Tiến sĩ Chuyên sâu'
  ),
  gen_random_uuid()
);
")

s4_qual_id=$(psql_exec -qAt -c "select '$res_s4_create'::jsonb -> 'data' ->> 'master_id';")
qual_ref_id="$s4_qual_id"

# Setup a candidate, submission, and education record referencing this qualification
psql_exec <<SQL
insert into auth.users (id, email)
values ('$cand_auth_uid'::uuid, 'candidate_$suffix@example.com');

insert into public.candidates (candidate_id, auth_user_id, email, current_full_name, current_phone, is_active)
values ('$cand_id'::uuid, '$cand_auth_uid'::uuid, 'candidate_$suffix@example.com', 'Nguyen Van A', '0912345678', true);

insert into public.submissions (
  submission_id, candidate_id, status_code, full_name, email_snapshot,
  phone, date_of_birth, gender_code, current_address, version_no
) values (
  '$sub_id'::uuid, '$cand_id'::uuid, 'NEW', 'Nguyen Van A', 'candidate_$suffix@example.com',
  '0912345678', '1990-01-01', 'MALE', '123 Test St', 1
);

insert into public.submission_education (
  education_id, submission_id, sort_order, qualification_id, institution,
  major, period_text
) values (
  '$edu_id'::uuid, '$sub_id'::uuid, 1, '$s4_qual_id'::uuid, 'EIU University',
  'Khoa học máy tính', '2015-2019'
);
SQL

# Call delete_or_inactivate on referenced qualification
res_s4_del=$(run_as_actor "$admin_auth_uid" "
select public.delete_or_inactivate_master_item(
  'qualification_levels',
  '$s4_qual_id'::uuid,
  1,
  gen_random_uuid()
);
")

echo "Referenced delete result: $res_s4_del"
s4_outcome=$(psql_exec -qAt -c "select '$res_s4_del'::jsonb -> 'data' ->> 'outcome';")
if [[ "$s4_outcome" != "INACTIVATED" ]]; then
  echo "FAIL: Scenario 4 expected INACTIVATED outcome but got '$s4_outcome'"
  exit 1
fi

# Verify row still exists with is_active = false
s4_active=$(psql_exec -qAt -c "select is_active from public.qualification_levels where qualification_id = '$s4_qual_id'::uuid;")
if [[ "$s4_active" != "f" ]]; then
  echo "FAIL: Scenario 4 qualification row is not marked as is_active = false"
  exit 1
fi

# Verify historical submission education record remains fully preserved and accessible
s4_hist_count=$(psql_exec -qAt -c "select count(*) from public.submission_education where education_id = '$edu_id'::uuid and qualification_id = '$s4_qual_id'::uuid;")
if [[ "$s4_hist_count" != "1" ]]; then
  echo "FAIL: Scenario 4 historical education record was compromised"
  exit 1
fi
echo "PASS: Scenario 4 - Referenced Item Inactivation and History Preservation"

# =============================================================================
# SCENARIO 5: Authorization Boundary (FORBIDDEN for unauthorized staff)
# =============================================================================
echo "==> Running Scenario 5: Authorization Boundary..."
res_s5_create=$(run_as_actor "$unauth_auth_uid" "
select public.create_master_item(
  'qualification_levels',
  jsonb_build_object(
    'code', 'QUAL_UNAUTH_$suffix',
    'name_vi', 'Unauthorized Create'
  ),
  gen_random_uuid()
);
")

s5_err=$(psql_exec -qAt -c "select '$res_s5_create'::jsonb ->> 'error_code';")
if [[ "$s5_err" != "FORBIDDEN" ]]; then
  echo "FAIL: Scenario 5 expected FORBIDDEN but got '$s5_err'"
  exit 1
fi
echo "PASS: Scenario 5 - Authorization Boundary"

echo "==> ALL 5 REC-18 DATABASE & CONCURRENCY SCENARIOS PASSED SUCCESSFULLY!"
