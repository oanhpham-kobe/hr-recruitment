import { useState } from "react";
import { createRoot } from "react-dom/client";
import { SubmissionDetailDrawer } from "@/components/inbox/SubmissionDetailDrawer";
import type {
  AssignmentOptions,
  SubmissionDetail,
} from "@/lib/application-inbox/submission-detail-model";
import "@/app/globals.css";

declare global {
  interface Window {
    __DRAWER_HARNESS_DATA__?: {
      detail?: SubmissionDetail;
      assignmentOptions?: AssignmentOptions | null;
      loadOptionsError?: string | null;
      saveNoteError?: string | null;
      createAppError?: { error: string; code?: string } | null;
      deferOptionsLoad?: boolean;
    };
    __DRAWER_HARNESS_LOGS__?: Array<{ event: string; payload?: unknown }>;
    __DRAWER_RESOLVE_OPTIONS__?: (options?: AssignmentOptions) => void;
    __DRAWER_REJECT_OPTIONS__?: (error: string) => void;
  }
}

const defaultDetail: SubmissionDetail = {
  submission_id: "11111111-1111-1111-1111-111111111111",
  candidate_id: "22222222-2222-2222-2222-222222222222",
  status_code: "NEW",
  full_name: "Nguyễn Văn A",
  date_of_birth: "1995-01-01",
  gender_code: "MALE",
  current_address: "Thủ Dầu Một, Bình Dương",
  phone: "0901234567",
  email: "nguyenvana@example.com",
  other_info: "Ghi chú ứng viên",
  hr_note: "Ghi chú nhân sự ban đầu",
  recruitment_source_id: "src-1",
  recruitment_source_name: "Website EIU",
  submitted_at: "2026-09-01T08:00:00Z",
  updated_at: "2026-09-01T08:00:00Z",
  updated_by_name: "Ứng viên",
  version_no: 1,
  education: [],
  work_experiences: [],
  activities: [],
  documents: [],
  applications: [
    {
      application_id: "app-1",
      unit_id: "unit-1",
      unit_name: "Khoa Công nghệ Thông tin",
      department_team_id: null,
      department_team_name: null,
      position_id: "pos-1",
      position_name: "Giảng viên CNTT",
      hr_owner_id: "hr-1",
      hr_owner_name: "Lê Văn HR",
      round_count: 1,
      round1_interview_id: null,
      is_active: true,
      version_no: 1,
      created_at: "2026-09-01T10:00:00Z",
    },
    {
      application_id: "app-2",
      unit_id: "unit-1",
      unit_name: "Khoa Công nghệ Thông tin",
      department_team_id: "team-1",
      department_team_name: "Bộ môn CNPM",
      position_id: "pos-2",
      position_name: "Giảng viên CNPM",
      hr_owner_id: "hr-1",
      hr_owner_name: "Lê Văn HR",
      round_count: 1,
      round1_interview_id: null,
      is_active: true,
      version_no: 1,
      created_at: "2026-09-01T10:00:00Z",
    },
  ],
};

const defaultOptions: AssignmentOptions = {
  units: [
    { unit_id: "unit-1", code: "FIT", name_vi: "Khoa CNTT" },
    { unit_id: "unit-2", code: "FBA", name_vi: "Khoa QTKD" },
  ],
  department_teams: [
    {
      department_team_id: "team-1",
      unit_id: "unit-1",
      code: "SE",
      name_vi: "Bộ môn CNPM",
    },
    {
      department_team_id: "team-2",
      unit_id: "unit-1",
      code: "CS",
      name_vi: "Bộ môn KHMT",
    },
  ],
  positions: [
    {
      position_id: "pos-1",
      unit_id: "unit-1",
      department_team_id: null,
      code: "LEC-FIT",
      name_vi: "Giảng viên CNTT",
    },
    {
      position_id: "pos-2",
      unit_id: "unit-1",
      department_team_id: "team-1",
      code: "LEC-SE",
      name_vi: "Giảng viên CNPM",
    },
    {
      position_id: "pos-2b",
      unit_id: "unit-1",
      department_team_id: "team-2",
      code: "LEC-CS",
      name_vi: "Giảng viên KHMT",
    },
    {
      position_id: "pos-3",
      unit_id: "unit-2",
      department_team_id: null,
      code: "LEC-FBA",
      name_vi: "Giảng viên QTKD",
    },
  ],
  hr_owners: [
    {
      app_user_id: "hr-1",
      full_name: "Lê Văn HR",
      email: "hr1@eiu.edu.vn",
    },
    {
      app_user_id: "hr-2",
      full_name: "Trần Thị HR",
      email: "hr2@eiu.edu.vn",
    },
  ],
};

function logHarnessEvent(event: string, payload?: unknown) {
  if (typeof window !== "undefined") {
    window.__DRAWER_HARNESS_LOGS__ = window.__DRAWER_HARNESS_LOGS__ ?? [];
    window.__DRAWER_HARNESS_LOGS__.push({ event, payload });
  }
}

export function SubmissionDetailDrawerHarness() {
  const [isOpen, setIsOpen] = useState(false);

  if (typeof window !== "undefined" && !window.__DRAWER_HARNESS_LOGS__) {
    window.__DRAWER_HARNESS_LOGS__ = [];
  }

  const testData = window.__DRAWER_HARNESS_DATA__ ?? {};
  const detail = testData.detail ?? defaultDetail;
  const options = testData.assignmentOptions ?? defaultOptions;

  const mockActions = {
    getSubmissionDetail: async (id: string) => {
      logHarnessEvent("getSubmissionDetail", { id });
      return { success: true as const, data: detail };
    },
    updateSubmissionHrNote: async (input: {
      submissionId: string;
      hrNote: string | null;
      expectedVersion: number;
    }) => {
      logHarnessEvent("updateSubmissionHrNote", input);
      if (testData.saveNoteError) {
        return {
          success: false as const,
          error: testData.saveNoteError,
          code: testData.saveNoteError.includes("STALE")
            ? "STALE_VERSION"
            : "ERROR",
        };
      }
      return {
        success: true as const,
        data: {
          submission_id: input.submissionId,
          hr_note: input.hrNote,
          version_no: input.expectedVersion + 1,
        },
      };
    },
    getAssignmentOptions: async () => {
      logHarnessEvent("getAssignmentOptions");
      const currentData = window.__DRAWER_HARNESS_DATA__ ?? {};
      if (currentData.deferOptionsLoad) {
        const { promise, resolve } = Promise.withResolvers<
          | { success: true; data: AssignmentOptions }
          | { success: false; error: string }
        >();
        window.__DRAWER_RESOLVE_OPTIONS__ = (
          customOpts?: AssignmentOptions,
        ) => {
          resolve({
            success: true,
            data: customOpts ?? currentData.assignmentOptions ?? options,
          });
        };
        window.__DRAWER_REJECT_OPTIONS__ = (errorMsg: string) => {
          resolve({
            success: false,
            error: errorMsg,
          });
        };
        return promise;
      }
      if (currentData.loadOptionsError) {
        return {
          success: false as const,
          error: currentData.loadOptionsError,
        };
      }
      return {
        success: true as const,
        data: currentData.assignmentOptions ?? options,
      };
    },
    createApplication: async (input: unknown) => {
      logHarnessEvent("createApplication", input);
      if (testData.createAppError) {
        return {
          success: false as const,
          error: testData.createAppError.error,
          code: testData.createAppError.code,
        };
      }
      return {
        success: true as const,
        data: {
          application_id: "new-app-1",
          submission_id: detail.submission_id,
          is_active: true,
          version_no: 1,
          round1_interview_id: "round-1",
        },
      };
    },
    updateSubmissionAggregate: async (input: unknown) => {
      logHarnessEvent("updateSubmissionAggregate", input);
      return {
        success: true as const,
        data: {
          submission_id: detail.submission_id,
          version_no: detail.version_no + 1,
          changed_fields: ["full_name", "hr_note"],
        },
      };
    },
    getRecruitmentSources: async () => [
      {
        recruitment_source_id: "src-1",
        code: "WEBSITE",
        name_vi: "Website EIU",
      },
      { recruitment_source_id: "src-2", code: "LINKEDIN", name_vi: "LinkedIn" },
    ],
    getQualificationLevels: async () => [
      { qualification_id: "qual-1", code: "BACHELOR", name_vi: "Cử nhân" },
      { qualification_id: "qual-2", code: "MASTER", name_vi: "Thạc sĩ" },
      { qualification_id: "qual-3", code: "DOCTOR", name_vi: "Tiến sĩ" },
    ],
  };

  return (
    <div style={{ padding: "20px" }}>
      <button
        id="external-open-drawer"
        type="button"
        className="btn-primary"
        onClick={() => setIsOpen(true)}
      >
        Mở chi tiết phiếu
      </button>

      <SubmissionDetailDrawer
        submissionId={detail.submission_id}
        isOpen={isOpen}
        onClose={() => setIsOpen(false)}
        actions={mockActions}
      />
    </div>
  );
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing drawer test root");
createRoot(root).render(<SubmissionDetailDrawerHarness />);
