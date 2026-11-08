#!/usr/bin/env bash
# =============================================================================
# RECOVERY PACKAGE 007: REC-19 Users & Permissions Management Lifecycle & RBAC
#
# Covers:
#   PG1: Directory Lifecycle (Create -> Update)
#     create_internal_user -> returns version 1, is_active true
#     update_internal_user_directory -> returns version 2
#   PG2: Root Admin & Bound-Email Protection:
#     Cannot inactivate Root Admin (ROOT_ADMIN_PROTECTED)
#     Non-root cannot alter email of identity-bound user
#   PG3: Role & Permission Administration:
#     Root Admin assigns HR role with defaults (assign_hr_role_with_defaults)
#     Root Admin grants/revokes granular permissions (grant/revoke_hr_permission)
#     Root Admin revokes HR role (remove_hr_role)
#   PG4: Optimistic Version Concurrency:
#     Mismatched expected_version_no rejected with STALE_VERSION
#   PG5: Security Boundary:
#     Unauthorized caller rejected with FORBIDDEN on directory and RBAC RPCs
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

# Root Admin fixture
root_user_id="$(new_uuid)"
root_auth_uid="$(new_uuid)"
root_owned=true

# HR Manager fixture
hr_user_id="$(new_uuid)"
hr_auth_uid="$(new_uuid)"

# Normal Staff fixture
staff_user_id="$(new_uuid)"
staff_auth_uid="$(new_uuid)"

# Target test user
target_user_id="$(new_uuid)"
target_auth_uid="$(new_uuid)"

cleanup() {
  echo "==> Cleaning up test fixtures..."
  psql_exec <<SQL >/dev/null 2>&1 || true
delete from public.app_user_permissions where app_user_id in ('$hr_user_id'::uuid, '$staff_user_id'::uuid, '$target_user_id'::uuid);
delete from public.app_user_roles where app_user_id in ('$hr_user_id'::uuid, '$staff_user_id'::uuid, '$target_user_id'::uuid);
delete from public.app_users where app_user_id in ('$hr_user_id'::uuid, '$staff_user_id'::uuid, '$target_user_id'::uuid);
delete from auth.users where id in ('$hr_auth_uid'::uuid, '$staff_auth_uid'::uuid, '$target_auth_uid'::uuid);
SQL
  if [[ "$root_owned" == true ]]; then
    psql_exec <<SQL >/dev/null 2>&1 || true
delete from public.app_users where app_user_id = '$root_user_id'::uuid;
delete from auth.users where id = '$root_auth_uid'::uuid;
SQL
  fi
}
trap cleanup EXIT

echo "==> Resolving Root Admin actor..."
root_record="$(psql_exec -qAt -F '|' -c "select app_user_id::text, coalesce(auth_user_id::text,'') from public.app_users where is_root_admin=true order by app_user_id limit 1;" | tr -d '\r')"
if [[ -n "$root_record" ]]; then
  IFS='|' read -r existing_root_id existing_auth_id <<< "$root_record"
  root_user_id="$existing_root_id"
  if [[ -n "$existing_auth_id" ]]; then
    root_auth_uid="$existing_auth_id"
  else
    root_auth_uid="$(new_uuid)"
    psql_exec <<SQL
insert into auth.users (id, email) values ('$root_auth_uid'::uuid, 'root_auth_$suffix@eiu.edu.vn');
update public.app_users set auth_user_id = '$root_auth_uid'::uuid where app_user_id = '$root_user_id'::uuid;
SQL
  fi
  root_owned=false
  echo "Reusing existing Root Admin: $root_user_id (auth: $root_auth_uid)"
else
  psql_exec <<SQL
insert into auth.users (id, email) values ('$root_auth_uid'::uuid, 'rec19_root_$suffix@eiu.edu.vn');
insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_active, is_root_admin)
values ('$root_user_id'::uuid, '$root_auth_uid'::uuid, 'rec19_root_$suffix@eiu.edu.vn', 'Root Admin $suffix', true, true);
SQL
  echo "Created fresh Root Admin: $root_user_id (auth: $root_auth_uid)"
fi

echo "==> Setting up security actors and permissions..."
psql_exec <<SQL
insert into auth.users (id, email)
values
  ('$hr_auth_uid'::uuid, 'rec19_hr_$suffix@eiu.edu.vn'),
  ('$staff_auth_uid'::uuid, 'rec19_staff_$suffix@eiu.edu.vn');

insert into public.app_users (app_user_id, auth_user_id, email, full_name, is_active, is_root_admin)
values
  ('$hr_user_id'::uuid, '$hr_auth_uid'::uuid, 'rec19_hr_$suffix@eiu.edu.vn', 'HR Manager $suffix', true, false),
  ('$staff_user_id'::uuid, '$staff_auth_uid'::uuid, 'rec19_staff_$suffix@eiu.edu.vn', 'Staff $suffix', true, false);

-- HR Manager gets users.directory_manage permission
insert into public.app_user_permissions (app_user_id, permission_code)
values ('$hr_user_id'::uuid, 'users.directory_manage');

-- Staff user gets no directory permissions
SQL

# =============================================================================
# SCENARIO 1: Directory Lifecycle (Create -> Update)
# =============================================================================
echo "==> Running Scenario 1: Directory Lifecycle..."
res_s1_create=$(run_as_actor "$hr_auth_uid" "
select public.create_internal_user(
  jsonb_build_object(
    'email', 'new_hire_$suffix@eiu.edu.vn',
    'full_name', 'Nguyen Van New Hire',
    'job_title', 'Chuyên viên'
  ),
  gen_random_uuid()
);
")

echo "Create user result: $res_s1_create"
s1_success=$(psql_exec -qAt -c "select ('$res_s1_create'::jsonb ->> 'success')::boolean;")
s1_user_id=$(psql_exec -qAt -c "select '$res_s1_create'::jsonb -> 'data' ->> 'app_user_id';")
target_user_id="$s1_user_id"
s1_version=$(psql_exec -qAt -c "select ('$res_s1_create'::jsonb -> 'data' ->> 'version_no')::int;")

if [[ "$s1_success" != "t" || "$s1_version" != "1" ]]; then
  echo "FAIL: Scenario 1 create_internal_user did not succeed with version 1"
  exit 1
fi

# Update directory details
res_s1_upd=$(run_as_actor "$hr_auth_uid" "
select public.update_internal_user_directory(
  '$target_user_id'::uuid,
  jsonb_build_object(
    'full_name', 'Nguyen Van New Hire Updated',
    'job_title', 'Chuyên viên chính'
  ),
  1,
  gen_random_uuid()
);
")

echo "Update user result: $res_s1_upd"
s1_upd_success=$(psql_exec -qAt -c "select ('$res_s1_upd'::jsonb ->> 'success')::boolean;")
s1_upd_version=$(psql_exec -qAt -c "select ('$res_s1_upd'::jsonb -> 'data' ->> 'version_no')::int;")

if [[ "$s1_upd_success" != "t" || "$s1_upd_version" != "2" ]]; then
  echo "FAIL: Scenario 1 update_internal_user_directory did not increment version to 2"
  exit 1
fi
echo "PASS: Scenario 1 - Directory Lifecycle"

# =============================================================================
# SCENARIO 2: Root Admin Protection & Identity-Bound Email Protection
# =============================================================================
echo "==> Running Scenario 2: Root Admin Protection & Bound Email Protection..."
# Get current Root Admin version
root_ver=$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id = '$root_user_id'::uuid;")

# Attempting to inactivate Root Admin
res_s2_root_lock=$(run_as_actor "$root_auth_uid" "
select public.set_internal_user_active(
  '$root_user_id'::uuid,
  false,
  $root_ver,
  gen_random_uuid()
);
")

echo "Lock root result: $res_s2_root_lock"
s2_root_err=$(psql_exec -qAt -c "select '$res_s2_root_lock'::jsonb ->> 'error_code';")
if [[ "$s2_root_err" != "ROOT_ADMIN_PROTECTED" ]]; then
  echo "FAIL: Scenario 2 expected ROOT_ADMIN_PROTECTED but got '$s2_root_err'"
  exit 1
fi

# Bind an auth identity to target user
psql_exec <<SQL
insert into auth.users (id, email)
values ('$target_auth_uid'::uuid, 'new_hire_$suffix@eiu.edu.vn');

update public.app_users
set auth_user_id = '$target_auth_uid'::uuid
where app_user_id = '$target_user_id'::uuid;
SQL

s2_ver=$(psql_exec -qAt -c "select version_no from public.app_users where app_user_id = '$target_user_id'::uuid;")

# Non-root HR attempting to change email of bound user
res_s2_email_change=$(run_as_actor "$hr_auth_uid" "
select public.update_internal_user_directory(
  '$target_user_id'::uuid,
  jsonb_build_object(
    'email', 'hijacked_$suffix@eiu.edu.vn'
  ),
  $s2_ver,
  gen_random_uuid()
);
")

echo "Bound email change result: $res_s2_email_change"
s2_email_err=$(psql_exec -qAt -c "select '$res_s2_email_change'::jsonb ->> 'error_code';")
if [[ "$s2_email_err" != "IDENTITY_REBIND_FORBIDDEN" && "$s2_email_err" != "IDENTITY_EMAIL_UPDATE_FORBIDDEN" && "$s2_email_err" != "FORBIDDEN" ]]; then
  echo "FAIL: Scenario 2 expected IDENTITY_REBIND_FORBIDDEN but got '$s2_email_err'"
  exit 1
fi
echo "PASS: Scenario 2 - Root Admin & Bound Email Protection"

# =============================================================================
# SCENARIO 3: Role & Permission Administration (Root-only)
# =============================================================================
echo "==> Running Scenario 3: Role & Permission Administration..."
# Non-root attempting to assign HR role -> FORBIDDEN
res_s3_nonroot=$(run_as_actor "$hr_auth_uid" "
select public.assign_hr_role_with_defaults(
  '$target_user_id'::uuid,
  $s2_ver,
  gen_random_uuid()
);
")

s3_nonroot_err=$(psql_exec -qAt -c "select '$res_s3_nonroot'::jsonb ->> 'error_code';")
if [[ "$s3_nonroot_err" != "FORBIDDEN" ]]; then
  echo "FAIL: Scenario 3 expected FORBIDDEN for non-root assign_hr_role but got '$s3_nonroot_err'"
  exit 1
fi

# Root Admin assigns HR role with defaults
res_s3_assign=$(run_as_actor "$root_auth_uid" "
select public.assign_hr_role_with_defaults(
  '$target_user_id'::uuid,
  $s2_ver,
  gen_random_uuid()
);
")

echo "Assign HR role result: $res_s3_assign"
s3_assign_success=$(psql_exec -qAt -c "select ('$res_s3_assign'::jsonb ->> 'success')::boolean;")
s3_assign_ver=$(psql_exec -qAt -c "select ('$res_s3_assign'::jsonb -> 'data' ->> 'version_no')::int;")
if [[ "$s3_assign_success" != "t" || "$s3_assign_ver" != "$((s2_ver + 1))" ]]; then
  echo "FAIL: Scenario 3 assign_hr_role_with_defaults failed"
  exit 1
fi

# Root Admin grants candidates.identity_manage
res_s3_grant=$(run_as_actor "$root_auth_uid" "
select public.grant_hr_permission(
  '$target_user_id'::uuid,
  'candidates.identity_manage',
  $s3_assign_ver,
  gen_random_uuid()
);
")

s3_grant_success=$(psql_exec -qAt -c "select ('$res_s3_grant'::jsonb ->> 'success')::boolean;")
s3_grant_ver=$(psql_exec -qAt -c "select ('$res_s3_grant'::jsonb -> 'data' ->> 'version_no')::int;")
if [[ "$s3_grant_success" != "t" || "$s3_grant_ver" != "$((s3_assign_ver + 1))" ]]; then
  echo "FAIL: Scenario 3 grant_hr_permission failed"
  exit 1
fi

# Root Admin revokes candidates.identity_manage
res_s3_revoke=$(run_as_actor "$root_auth_uid" "
select public.revoke_hr_permission(
  '$target_user_id'::uuid,
  'candidates.identity_manage',
  $s3_grant_ver,
  gen_random_uuid()
);
")

s3_revoke_success=$(psql_exec -qAt -c "select ('$res_s3_revoke'::jsonb ->> 'success')::boolean;")
s3_revoke_ver=$(psql_exec -qAt -c "select ('$res_s3_revoke'::jsonb -> 'data' ->> 'version_no')::int;")
if [[ "$s3_revoke_success" != "t" || "$s3_revoke_ver" != "$((s3_grant_ver + 1))" ]]; then
  echo "FAIL: Scenario 3 revoke_hr_permission failed"
  exit 1
fi

# Root Admin revokes HR role and all permissions
res_s3_revoke_all=$(run_as_actor "$root_auth_uid" "
select public.remove_hr_role(
  '$target_user_id'::uuid,
  $s3_revoke_ver,
  gen_random_uuid()
);
")

s3_rev_all_success=$(psql_exec -qAt -c "select ('$res_s3_revoke_all'::jsonb ->> 'success')::boolean;")
s3_rev_all_ver=$(psql_exec -qAt -c "select ('$res_s3_revoke_all'::jsonb -> 'data' ->> 'version_no')::int;")
if [[ "$s3_rev_all_success" != "t" || "$s3_rev_all_ver" != "$((s3_revoke_ver + 1))" ]]; then
  echo "FAIL: Scenario 3 remove_hr_role failed"
  exit 1
fi
echo "PASS: Scenario 3 - Role & Permission Administration"

# =============================================================================
# SCENARIO 4: Optimistic Version Concurrency
# =============================================================================
echo "==> Running Scenario 4: Optimistic Version Concurrency..."
res_s4=$(run_as_actor "$hr_auth_uid" "
select public.update_internal_user_directory(
  '$target_user_id'::uuid,
  jsonb_build_object(
    'full_name', 'Stale Attempt'
  ),
  2,
  gen_random_uuid()
);
")

s4_err=$(psql_exec -qAt -c "select '$res_s4'::jsonb ->> 'error_code';")
if [[ "$s4_err" != "STALE_VERSION" ]]; then
  echo "FAIL: Scenario 4 expected STALE_VERSION but got '$s4_err'"
  exit 1
fi
echo "PASS: Scenario 4 - Optimistic Version Concurrency"

# =============================================================================
# SCENARIO 5: Security Boundary (FORBIDDEN for unauthorized staff)
# =============================================================================
echo "==> Running Scenario 5: Security Boundary..."
res_s5=$(run_as_actor "$staff_auth_uid" "
select public.create_internal_user(
  jsonb_build_object(
    'email', 'unauthorized_$suffix@eiu.edu.vn',
    'full_name', 'Attacker'
  ),
  gen_random_uuid()
);
")

s5_err=$(psql_exec -qAt -c "select '$res_s5'::jsonb ->> 'error_code';")
if [[ "$s5_err" != "FORBIDDEN" ]]; then
  echo "FAIL: Scenario 5 expected FORBIDDEN but got '$s5_err'"
  exit 1
fi
echo "PASS: Scenario 5 - Security Boundary"

echo "==> ALL 5 REC-19 DATABASE & RBAC SCENARIOS PASSED SUCCESSFULLY!"
