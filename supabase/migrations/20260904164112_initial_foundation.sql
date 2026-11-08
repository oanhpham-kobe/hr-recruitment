-- App Tuyển dụng EIU — Database Migration Foundation
-- Slice 00 / TASK-S00-003: Foundational extensions and private schema
-- Source authority:
--   recruitment_webapp/review_pack/database_schema.sql
--   recruitment_webapp/review_pack/40_DATABASE_INVARIANTS.md
--   recruitment_webapp/review_pack/59_RLS_POLICY_BLUEPRINT.md

-- -----------------------------------------------------------------------------
-- 1. Foundational Extensions
-- -----------------------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;

-- -----------------------------------------------------------------------------
-- 2. Private Internal Schema
-- -----------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to postgres, service_role;

-- -----------------------------------------------------------------------------
-- 3. Foundational Helper Functions
-- -----------------------------------------------------------------------------
-- touch_version: Trigger function to update updated_at and increment version_no
create or replace function private.touch_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.version_no := coalesce(old.version_no, 0) + 1;
  return new;
end;
$$;

revoke all on function private.touch_version() from public, anon, authenticated;
grant execute on function private.touch_version() to postgres, service_role;
