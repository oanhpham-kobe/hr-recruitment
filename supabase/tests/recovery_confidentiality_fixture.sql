-- RECOVERY PACKAGE 001: F02 Confidentiality Test Fixture (Seeding Script)
-- Privileged seeding of stable synthetic UUIDs for genuine-role baseline reproduction
-- and server smoke testing.
-- Run with: docker exec -i <container> psql -v ON_ERROR_STOP=1 -U postgres -d postgres -f ...

\set ON_ERROR_STOP on

begin;

-- 1. Idempotent cleanup in reverse-dependency order
delete from public.interview_reports
where interview_report_id in ('f0200000-0000-0000-0000-000000000b01'::uuid);

delete from public.interview_participants
where interview_participant_id in (
  'f0200000-0000-0000-0000-000000000a01'::uuid,
  'f0200000-0000-0000-0000-000000000a02'::uuid,
  'f0200000-0000-0000-0000-000000000a03'::uuid,
  'f0200000-0000-0000-0000-000000000a04'::uuid,
  'f0200000-0000-0000-0000-000000000a05'::uuid
);

delete from public.interviews
where interview_id in (
  'f0200000-0000-0000-0000-000000000901'::uuid,
  'f0200000-0000-0000-0000-000000000902'::uuid,
  'f0200000-0000-0000-0000-000000000903'::uuid
);

delete from public.applications
where application_id in (
  'f0200000-0000-0000-0000-000000000802'::uuid,
  'f0200000-0000-0000-0000-000000000803'::uuid
);

delete from public.submissions
where submission_id in ('f0200000-0000-0000-0000-000000000801'::uuid);

delete from public.candidates
where candidate_id in ('f0200000-0000-0000-0000-000000000702'::uuid);

delete from public.app_user_permissions
where app_user_id in ('f0200000-0000-0000-0000-000000000102'::uuid);

delete from public.app_user_roles
where app_user_id in ('f0200000-0000-0000-0000-000000000102'::uuid);

delete from public.app_users
where app_user_id in (
  'f0200000-0000-0000-0000-000000000102'::uuid,
  'f0200000-0000-0000-0000-000000000202'::uuid,
  'f0200000-0000-0000-0000-000000000302'::uuid,
  'f0200000-0000-0000-0000-000000000402'::uuid,
  'f0200000-0000-0000-0000-000000000502'::uuid,
  'f0200000-0000-0000-0000-000000000602'::uuid
);

delete from public.positions
where position_id in (
  'f0200000-0000-0000-0000-000000000003'::uuid,
  'f0200000-0000-0000-0000-000000000004'::uuid
);

delete from public.position_groups
where position_group_id in ('f0200000-0000-0000-0000-000000000002'::uuid);

delete from public.organizational_units
where unit_id in ('f0200000-0000-0000-0000-000000000001'::uuid);

-- 2. Master Data
insert into public.organizational_units(unit_id, code, name_vi, name_en)
values ('f0200000-0000-0000-0000-000000000001'::uuid, 'F02_UNIT', 'Khoa CNTT F02', 'F02 IT Faculty');

insert into public.position_groups(position_group_id, code, name_vi, name_en)
values ('f0200000-0000-0000-0000-000000000002'::uuid, 'F02_GROUP', 'Nhóm Giảng viên F02', 'F02 Lecturer Group');

insert into public.positions(position_id, unit_id, position_group_id, code, name_vi, name_en)
values
  ('f0200000-0000-0000-0000-000000000003'::uuid, 'f0200000-0000-0000-0000-000000000001'::uuid, 'f0200000-0000-0000-0000-000000000002'::uuid, 'F02_POS_1', 'Giảng viên SE', 'SE Lecturer'),
  ('f0200000-0000-0000-0000-000000000004'::uuid, 'f0200000-0000-0000-0000-000000000001'::uuid, 'f0200000-0000-0000-0000-000000000002'::uuid, 'F02_POS_2', 'Giảng viên AI', 'AI Lecturer');

-- 3. Internal Users
-- HR User
insert into public.app_users(app_user_id, auth_user_id, full_name, email, job_title, is_active)
values ('f0200000-0000-0000-0000-000000000102'::uuid, 'f0200000-0000-0000-0000-000000000101'::uuid, 'F02 HR Manager', 'f02_hr@eiu.edu.vn', 'HR Specialist', true);

insert into public.app_user_roles(app_user_id, role_code)
values ('f0200000-0000-0000-0000-000000000102'::uuid, 'HR');

insert into public.app_user_permissions(app_user_id, permission_code)
values
  ('f0200000-0000-0000-0000-000000000102'::uuid, 'interviews.view'),
  ('f0200000-0000-0000-0000-000000000102'::uuid, 'reports.view'),
  ('f0200000-0000-0000-0000-000000000102'::uuid, 'reports.manage_status')
on conflict do nothing;

-- Assigned Interviewer
insert into public.app_users(app_user_id, auth_user_id, full_name, email, job_title, is_active)
values ('f0200000-0000-0000-0000-000000000202'::uuid, 'f0200000-0000-0000-0000-000000000201'::uuid, 'F02 Assigned Interviewer', 'f02_assigned_interviewer@eiu.edu.vn', 'Senior Lecturer', true);

-- Unassigned Interviewer
insert into public.app_users(app_user_id, auth_user_id, full_name, email, job_title, is_active)
values ('f0200000-0000-0000-0000-000000000302'::uuid, 'f0200000-0000-0000-0000-000000000301'::uuid, 'F02 Unassigned Interviewer', 'f02_unassigned_interviewer@eiu.edu.vn', 'Associate Professor', true);

-- Removed Interviewer
insert into public.app_users(app_user_id, auth_user_id, full_name, email, job_title, is_active)
values ('f0200000-0000-0000-0000-000000000402'::uuid, 'f0200000-0000-0000-0000-000000000401'::uuid, 'F02 Removed Interviewer', 'f02_removed_interviewer@eiu.edu.vn', 'Lecturer', true);

-- Hidden Session Interviewer
insert into public.app_users(app_user_id, auth_user_id, full_name, email, job_title, is_active)
values ('f0200000-0000-0000-0000-000000000502'::uuid, 'f0200000-0000-0000-0000-000000000501'::uuid, 'F02 Hidden Interviewer', 'f02_hidden_interviewer@eiu.edu.vn', 'Researcher', true);

-- Inactive Internal User (inserted as active; deactivated after participant assignment below)
insert into public.app_users(app_user_id, auth_user_id, full_name, email, job_title, is_active)
values ('f0200000-0000-0000-0000-000000000602'::uuid, 'f0200000-0000-0000-0000-000000000601'::uuid, 'F02 Inactive Interviewer', 'f02_inactive_interviewer@eiu.edu.vn', 'Former Lecturer', true);

-- 4. Candidate & Submission
insert into public.candidates(candidate_id, auth_user_id, email, is_active)
values ('f0200000-0000-0000-0000-000000000702'::uuid, 'f0200000-0000-0000-0000-000000000701'::uuid, 'f02_candidate@example.com', true);

insert into public.submissions(
  submission_id, candidate_id, full_name, date_of_birth, gender_code,
  current_address, phone, email_snapshot, status_code
) values (
  'f0200000-0000-0000-0000-000000000801'::uuid,
  'f0200000-0000-0000-0000-000000000702'::uuid,
  'Nguyễn Văn Ứng Viên F02',
  date '1992-06-15',
  'MALE',
  'Thành phố Mới, Bình Dương',
  '0901234567',
  'f02_candidate@example.com',
  'PROCESSED'
);

-- 5. Applications
-- Application 1: Main Application with historical Round 1 and Current Round 2
insert into public.applications(
  application_id, submission_id, unit_id, position_id, hr_owner_id, is_active
) values (
  'f0200000-0000-0000-0000-000000000802'::uuid,
  'f0200000-0000-0000-0000-000000000801'::uuid,
  'f0200000-0000-0000-0000-000000000001'::uuid,
  'f0200000-0000-0000-0000-000000000003'::uuid,
  'f0200000-0000-0000-0000-000000000102'::uuid,
  true
);

-- Application 2: Application for Hidden Session evaluation
insert into public.applications(
  application_id, submission_id, unit_id, position_id, hr_owner_id, is_active
) values (
  'f0200000-0000-0000-0000-000000000803'::uuid,
  'f0200000-0000-0000-0000-000000000801'::uuid,
  'f0200000-0000-0000-0000-000000000001'::uuid,
  'f0200000-0000-0000-0000-000000000004'::uuid,
  'f0200000-0000-0000-0000-000000000102'::uuid,
  true
);

-- 6. Interviews
-- App 1, Round 1 (Historical, Participated by Assigned Interviewer, visible)
insert into public.interviews(
  interview_id, application_id, round_no, schedule_status_code, report_status_code,
  notes, hr_report_note, visible_to_interviewers, is_active
) values (
  'f0200000-0000-0000-0000-000000000901'::uuid,
  'f0200000-0000-0000-0000-000000000802'::uuid,
  1,
  'AVAILABLE',
  'WAITING_FOR_REPORT',
  'Operational note for Round 1',
  'CONFIDENTIAL_HR_NOTE_ROUND_1_HISTORICAL',
  true,
  true
);

-- App 1, Round 2 (Current Round, visible, contains sensitive HR Note)
insert into public.interviews(
  interview_id, application_id, round_no, schedule_status_code, report_status_code,
  notes, hr_report_note, visible_to_interviewers, is_active
) values (
  'f0200000-0000-0000-0000-000000000902'::uuid,
  'f0200000-0000-0000-0000-000000000802'::uuid,
  2,
  'AVAILABLE',
  'WAITING_FOR_REPORT',
  'Operational note for Round 2',
  'CONFIDENTIAL_HR_NOTE_ROUND_2_CURRENT_LEAK',
  true,
  true
);

-- App 2, Round 1 (Hidden Session: visible_to_interviewers = false)
insert into public.interviews(
  interview_id, application_id, round_no, schedule_status_code, report_status_code,
  notes, hr_report_note, visible_to_interviewers, is_active
) values (
  'f0200000-0000-0000-0000-000000000903'::uuid,
  'f0200000-0000-0000-0000-000000000803'::uuid,
  1,
  'AVAILABLE',
  'INTERVIEW_SCHEDULING',
  'Hidden session operational note',
  'CONFIDENTIAL_HR_NOTE_HIDDEN_SESSION',
  false,
  true
);

-- 7. Participants
-- App 1, Round 1: Assigned Interviewer participated historically
insert into public.interview_participants(
  interview_participant_id, interview_id, app_user_id, participant_order,
  snapshot_name, snapshot_job_title, snapshot_email, is_current
) values (
  'f0200000-0000-0000-0000-000000000a01'::uuid,
  'f0200000-0000-0000-0000-000000000901'::uuid,
  'f0200000-0000-0000-0000-000000000202'::uuid,
  1,
  'F02 Assigned Interviewer',
  'Senior Lecturer',
  'f02_assigned_interviewer@eiu.edu.vn',
  true
);

-- App 1, Round 2: Assigned Interviewer (current participant)
insert into public.interview_participants(
  interview_participant_id, interview_id, app_user_id, participant_order,
  snapshot_name, snapshot_job_title, snapshot_email, is_current
) values (
  'f0200000-0000-0000-0000-000000000a02'::uuid,
  'f0200000-0000-0000-0000-000000000902'::uuid,
  'f0200000-0000-0000-0000-000000000202'::uuid,
  1,
  'F02 Assigned Interviewer',
  'Senior Lecturer',
  'f02_assigned_interviewer@eiu.edu.vn',
  true
);

-- App 1, Round 2: Removed Interviewer (is_current = false, removed_at is not null)
insert into public.interview_participants(
  interview_participant_id, interview_id, app_user_id, participant_order,
  snapshot_name, snapshot_job_title, snapshot_email, is_current, removed_at
) values (
  'f0200000-0000-0000-0000-000000000a03'::uuid,
  'f0200000-0000-0000-0000-000000000902'::uuid,
  'f0200000-0000-0000-0000-000000000402'::uuid,
  2,
  'F02 Removed Interviewer',
  'Lecturer',
  'f02_removed_interviewer@eiu.edu.vn',
  false,
  clock_timestamp()
);

-- App 2, Round 1: Hidden Interviewer
insert into public.interview_participants(
  interview_participant_id, interview_id, app_user_id, participant_order,
  snapshot_name, snapshot_job_title, snapshot_email, is_current
) values (
  'f0200000-0000-0000-0000-000000000a04'::uuid,
  'f0200000-0000-0000-0000-000000000903'::uuid,
  'f0200000-0000-0000-0000-000000000502'::uuid,
  1,
  'F02 Hidden Interviewer',
  'Researcher',
  'f02_hidden_interviewer@eiu.edu.vn',
  true
);

-- App 1, Round 2: Inactive Interviewer
insert into public.interview_participants(
  interview_participant_id, interview_id, app_user_id, participant_order,
  snapshot_name, snapshot_job_title, snapshot_email, is_current
) values (
  'f0200000-0000-0000-0000-000000000a05'::uuid,
  'f0200000-0000-0000-0000-000000000902'::uuid,
  'f0200000-0000-0000-0000-000000000602'::uuid,
  3,
  'F02 Inactive Interviewer',
  'Former Lecturer',
  'f02_inactive_interviewer@eiu.edu.vn',
  true
);

-- 7b. Deactivate the Inactive user after participant was created
update public.app_users set is_active = false where app_user_id = 'f0200000-0000-0000-0000-000000000602'::uuid;

-- 8. Reports
-- Participant report on App 1, Round 2 with conclusion set (triggers decision metadata guard)
insert into public.interview_reports(
  interview_report_id, interview_participant_id, professional_knowledge, necessary_skills,
  qualities_personality, strengths_limitations, other_comment, conclusion,
  expected_specific_job_assigned, expected_recruitment_time, created_by, updated_by
) values (
  'f0200000-0000-0000-0000-000000000b01'::uuid,
  'f0200000-0000-0000-0000-000000000a02'::uuid,
  'Excellent software engineering background',
  'Strong system design skills',
  'Dedicated, collegiate',
  'Strong analytical mindset',
  'None',
  'HIRE_RECOMMENDED_CONFIDENTIAL_DECISION',
  'Lecturer in Software Engineering',
  'Semester 2 2026-2027',
  'f0200000-0000-0000-0000-000000000202'::uuid,
  'f0200000-0000-0000-0000-000000000202'::uuid
);

commit;
