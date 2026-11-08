import type { SubmissionStatus } from "./model";

export const DOCUMENT_SIGNED_URL_TTL_SECONDS = 180; // 3 minutes, strictly between 60 and 300 seconds

export const PREVIEWABLE_MIME_TYPES = [
  "application/pdf",
  "image/png",
  "image/jpeg",
] as const;

export function isPreviewableDocument(mimeType: string): boolean {
  return (PREVIEWABLE_MIME_TYPES as readonly string[]).includes(mimeType);
}

export function isDownloadOnlyDocument(mimeType: string): boolean {
  return !isPreviewableDocument(mimeType);
}

export interface SubmissionEducationItem {
  education_id: string;
  sort_order: number;
  period_text: string | null;
  qualification_id: string | null;
  qualification_name: string | null;
  major: string | null;
  institution: string | null;
}

export interface SubmissionWorkExperienceItem {
  experience_id: string;
  sort_order: number;
  start_date: string | null;
  end_date: string | null;
  is_current: boolean;
  employer: string | null;
  job_title: string | null;
  job_description: string | null;
}

export interface SubmissionActivityItem {
  activity_id: string;
  sort_order: number;
  period_text: string | null;
  activity_name: string | null;
  role_name: string | null;
  organizer: string | null;
  description: string | null;
}

export interface SubmissionDocumentItem {
  document_id: string;
  logical_document_id: string;
  document_type_id: string;
  document_type_code: string | null;
  document_type_name: string | null;
  original_filename: string;
  mime_type: string;
  previewable?: boolean;
  file_size_bytes: number;
  uploaded_at: string;
}

export interface SubmissionApplicationItem {
  application_id: string;
  unit_id: string;
  unit_name: string;
  department_team_id: string | null;
  department_team_name: string | null;
  position_id: string;
  position_name: string;
  hr_owner_id: string;
  hr_owner_name: string;
  is_active: boolean;
  version_no: number;
  created_at: string;
  round1_interview_id: string | null;
  round_count: number;
}

export interface SubmissionDetail {
  submission_id: string;
  candidate_id: string;
  status_code: SubmissionStatus;
  full_name: string;
  date_of_birth: string | null;
  gender_code: "MALE" | "FEMALE" | null;
  current_address: string | null;
  phone: string | null;
  email: string;
  other_info: string | null;
  hr_note: string | null;
  recruitment_source_id: string | null;
  recruitment_source_name: string | null;
  submitted_at: string;
  updated_at: string;
  updated_by_name: string | null;
  version_no: number;
  education: SubmissionEducationItem[];
  work_experiences: SubmissionWorkExperienceItem[];
  activities: SubmissionActivityItem[];
  documents: SubmissionDocumentItem[];
  applications: SubmissionApplicationItem[];
}

export interface UnitOption {
  unit_id: string;
  code: string;
  name_vi: string;
}

export interface DepartmentTeamOption {
  department_team_id: string;
  unit_id: string;
  code: string;
  name_vi: string;
}

export interface PositionOption {
  position_id: string;
  unit_id: string;
  department_team_id: string | null;
  code: string;
  name_vi: string;
}

export interface HrOwnerOption {
  app_user_id: string;
  full_name: string;
  email: string;
}

export interface AssignmentOptions {
  units: UnitOption[];
  department_teams: DepartmentTeamOption[];
  positions: PositionOption[];
  hr_owners: HrOwnerOption[];
}
