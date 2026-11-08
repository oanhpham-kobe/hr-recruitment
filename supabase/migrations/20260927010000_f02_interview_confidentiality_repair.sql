-- ============================================================================
-- F02 CONFIDENTIALITY REPAIR: Remove Interviewer contextual arms from raw
-- table RLS SELECT policies on public.interviews and public.interview_reports.
--
-- Problem:
--   Row-level security cannot redact columns. The Interviewer contextual arms
--   in these policies granted row-level read access to rows the Interviewer
--   participates in, but exposed confidential HR-only columns:
--     - interviews.hr_report_note (HR-only operational note)
--     - interview_reports.decision_updated_by, decision_updated_at,
--       created_by, updated_by (source/audit metadata)
--
-- Fix:
--   Remove the Interviewer contextual arms from raw table policies. Interviewer
--   read access is already served by safe SECURITY DEFINER RPCs:
--     - public.get_interviewer_report_page (contextual read with column projection)
--     - public.save_own_interviewer_report (owner-only mutation)
--   These RPCs bypass RLS (SECURITY DEFINER) and apply strict column allowlists.
--
-- Preserved:
--   - HR (interviews.view, interviews.manage) and Root Admin retain full raw access.
--   - private.can_view_visible_interview and private.can_view_interview_report
--     helper functions remain: they are used by SECURITY DEFINER RPCs and
--     private.can_read_email_context (email persistence).
--   - interview_participants_select policy unchanged: own-row access exposes no
--     confidential columns.
--
-- Evidence: supabase/tests/recovery_confidentiality_baseline.sql confirms the
-- leak pre-repair and validates all persona boundaries post-repair.
-- ============================================================================

-- 1. Replace interviews_select: HR/manage/root only, no Interviewer arm
drop policy if exists interviews_select on public.interviews;
create policy interviews_select on public.interviews
  for select to authenticated
  using (
    private.has_permission('interviews.view')
    or private.has_permission('interviews.manage')
    or private.is_root_admin()
  );

-- 2. Replace interview_reports_select: HR/root only, no Interviewer arm
drop policy if exists interview_reports_select on public.interview_reports;
create policy interview_reports_select on public.interview_reports
  for select to authenticated
  using (
    private.has_permission('reports.view')
    or private.is_root_admin()
  );
