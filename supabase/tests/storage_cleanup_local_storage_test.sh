#!/usr/bin/env bash
set -euo pipefail

if ! command -v supabase >/dev/null 2>&1; then
  echo 'supabase CLI is required' >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo 'docker is required' >&2
  exit 1
fi
if [[ ! -d web/node_modules ]]; then
  echo 'web dependencies must be installed before running the physical Storage integration test' >&2
  exit 1
fi

# Supabase CLI documents `status -o env` as the local export seam for
# API_URL/JWT_SECRET/ANON_KEY/SERVICE_ROLE_KEY. These credentials belong only to
# the disposable local stack started by the caller.
status_env="$(supabase status -o env)"
eval "$status_env"

: "${API_URL:?supabase status did not export API_URL}"
: "${ANON_KEY:?supabase status did not export ANON_KEY}"
: "${SERVICE_ROLE_KEY:?supabase status did not export SERVICE_ROLE_KEY}"
: "${JWT_SECRET:?supabase status did not export JWT_SECRET}"

export SUPABASE_LOCAL_API_URL="$API_URL"
export SUPABASE_LOCAL_ANON_KEY="$ANON_KEY"
export SUPABASE_LOCAL_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export SUPABASE_LOCAL_JWT_SECRET="$JWT_SECRET"
export CONTAINER_NAME="${CONTAINER_NAME:-supabase_db_eiu-recruitment-dev}"

(
  cd web
  node --conditions react-server --import tsx src/__tests__/storage-cleanup-local.integration.ts
)
