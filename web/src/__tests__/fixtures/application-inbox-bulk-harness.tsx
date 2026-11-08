import { useState } from "react";
import { createRoot } from "react-dom/client";
import { ApplicationInboxTable } from "@/components/inbox/ApplicationInboxTable";
import type {
  ApplicationInboxFilters,
  ApplicationInboxGroup,
} from "@/lib/application-inbox/model";
import type { SubmissionDetail } from "@/lib/application-inbox/submission-detail-model";
import type { BulkSetCandidateActiveData } from "@/lib/commands/candidate-lifecycle";
import type {
  BulkSetLatestSubmissionManualStatusData,
  OpenSubmissionData,
} from "@/lib/commands/submission-status";
import "@/app/globals.css";

declare global {
  interface Window {
    __BULK_HARNESS_DATA__?: {
      groups?: ApplicationInboxGroup[];
      bulkStatusResult?:
        | {
            success: true;
            data: BulkSetLatestSubmissionManualStatusData;
          }
        | { success: false; error: string; code?: string };
      bulkActiveResult?:
        | {
            success: true;
            data: BulkSetCandidateActiveData;
          }
        | { success: false; error: string; code?: string };
      delayActiveMs?: number;
      drawerDetailResult?:
        | {
            success: true;
            data: SubmissionDetail;
          }
        | { success: false; error: string; code?: string };
      drawerUpdateHrNoteResult?:
        | {
            success: true;
            data: {
              submission_id: string;
              hr_note: string | null;
              version_no: number;
            };
          }
        | { success: false; error: string; code?: string };
      openSubmissionResult?:
        | {
            success: true;
            data: OpenSubmissionData;
          }
        | { success: false; error: string; code?: string };
    };
    __BULK_HARNESS_LOGS__?: Array<{ event: string; payload?: unknown }>;
  }
}

const defaultGroups: ApplicationInboxGroup[] = [
  {
    candidateId: "candidate-1",
    email: "an@example.com",
    isCandidateActive: true,
    candidateVersionNo: 1,
    latestSubmissionId: "submission-1",
    latestSubmissionVersionNo: 1,
    submissions: [
      {
        submissionId: "submission-1",
        candidateId: "candidate-1",
        status: "NEW",
        fullName: "Nguyễn Thị An",
        dateOfBirth: "1995-08-15",
        gender: "FEMALE",
        phone: "0901 234 567",
        hrNote: "Đã liên hệ",
        submittedAt: "2026-09-02T09:00:00.000Z",
        hasApplication: false,
        versionNo: 1,
      },
    ],
  },
  {
    candidateId: "candidate-2",
    email: "binh@example.com",
    isCandidateActive: true,
    candidateVersionNo: 2,
    latestSubmissionId: "submission-2",
    latestSubmissionVersionNo: 3,
    submissions: [
      {
        submissionId: "submission-2",
        candidateId: "candidate-2",
        status: "READ",
        fullName: "Trần Minh Bình",
        dateOfBirth: "1994-04-01",
        gender: "MALE",
        phone: "0987 654 321",
        hrNote: "Chờ phỏng vấn",
        submittedAt: "2026-09-01T09:00:00.000Z",
        hasApplication: false,
        versionNo: 3,
      },
    ],
  },
  {
    candidateId: "candidate-3",
    email: "cuong@example.com",
    isCandidateActive: false,
    candidateVersionNo: 1,
    latestSubmissionId: "submission-3",
    latestSubmissionVersionNo: 1,
    submissions: [
      {
        submissionId: "submission-3",
        candidateId: "candidate-3",
        status: "PROCESSED",
        fullName: "Lê Văn Cường",
        dateOfBirth: "1992-12-10",
        gender: "MALE",
        phone: "0912 345 678",
        hrNote: "Đang có Application",
        submittedAt: "2026-08-20T09:00:00.000Z",
        hasApplication: true,
        versionNo: 1,
      },
    ],
  },
];

export function ApplicationInboxBulkHarness() {
  const [groups] = useState<ApplicationInboxGroup[]>(
    window.__BULK_HARNESS_DATA__?.groups ?? defaultGroups,
  );

  const mockActions = {
    queryApplicationInbox: async (params?: {
      filters?: ApplicationInboxFilters;
      page?: number;
      pageSize?: number;
    }) => {
      window.__BULK_HARNESS_LOGS__ = window.__BULK_HARNESS_LOGS__ ?? [];
      window.__BULK_HARNESS_LOGS__.push({
        event: "queryInbox",
        payload: params,
      });
      return {
        groups: window.__BULK_HARNESS_DATA__?.groups ?? groups,
        page: params?.page ?? 1,
        pageCount: 2,
      };
    },
    bulkSetLatestSubmissionManualStatusAction: async (input: {
      items: Array<{
        candidateId: string;
        expectedLatestSubmissionId: string;
        expectedVersion: number;
      }>;
      statusCode: "NEW" | "READ";
    }) => {
      window.__BULK_HARNESS_LOGS__ = window.__BULK_HARNESS_LOGS__ ?? [];
      window.__BULK_HARNESS_LOGS__.push({
        event: "bulkSetStatus",
        payload: input,
      });
      if (window.__BULK_HARNESS_DATA__?.bulkStatusResult) {
        return window.__BULK_HARNESS_DATA__.bulkStatusResult;
      }
      return {
        success: true as const,
        data: {
          count: input.items.length,
          items: input.items.map((item) => ({
            candidate_id: item.candidateId,
            submission_id: item.expectedLatestSubmissionId,
            status_code: input.statusCode,
            version_no: item.expectedVersion + 1,
          })),
          idempotency_key: "idemp-status-key-1",
        },
      };
    },
    bulkSetCandidateActiveAction: async (input: {
      items: Array<{
        candidateId: string;
        expectedVersion: number;
      }>;
      active: boolean;
    }) => {
      window.__BULK_HARNESS_LOGS__ = window.__BULK_HARNESS_LOGS__ ?? [];
      window.__BULK_HARNESS_LOGS__.push({
        event: "bulkSetActive",
        payload: input,
      });
      if (window.__BULK_HARNESS_DATA__?.delayActiveMs) {
        const { promise, resolve } = Promise.withResolvers<void>();
        setTimeout(resolve, window.__BULK_HARNESS_DATA__?.delayActiveMs);
        await promise;
      }
      if (window.__BULK_HARNESS_DATA__?.bulkActiveResult) {
        return window.__BULK_HARNESS_DATA__.bulkActiveResult;
      }
      return {
        success: true as const,
        data: {
          count: input.items.length,
          items: input.items.map((item) => ({
            candidate_id: item.candidateId,
            is_active: input.active,
            inactive_at: input.active ? null : "2026-09-05T12:00:00Z",
            inactive_by: input.active ? null : "actor-user-id",
            version_no: item.expectedVersion + 1,
          })),
          idempotency_key: "idemp-active-key-1",
        },
      };
    },
    openSubmissionAction: async (submissionId: string) => {
      window.__BULK_HARNESS_LOGS__ = window.__BULK_HARNESS_LOGS__ ?? [];
      window.__BULK_HARNESS_LOGS__.push({
        event: "openSubmission",
        payload: { submissionId },
      });
      if (window.__BULK_HARNESS_DATA__?.openSubmissionResult) {
        return window.__BULK_HARNESS_DATA__.openSubmissionResult;
      }
      return {
        success: true as const,
        data: {
          submission_id: submissionId,
          candidate_id: "candidate-1",
          status_code: "READ" as const,
          full_name: "Nguyễn Thị An",
          email: "an@example.com",
          phone: "0901 234 567",
          date_of_birth: "1995-08-15",
          gender: "FEMALE",
          address: "Hà Nội",
          candidate_notes: null,
          submitted_at: "2026-09-02T09:00:00.000Z",
          version_no: 2,
        },
      };
    },
    drawerActions: {
      openSubmission: async (submissionId: string) => {
        window.__BULK_HARNESS_LOGS__ = window.__BULK_HARNESS_LOGS__ ?? [];
        window.__BULK_HARNESS_LOGS__.push({
          event: "openSubmission",
          payload: { submissionId },
        });
        if (window.__BULK_HARNESS_DATA__?.openSubmissionResult) {
          return window.__BULK_HARNESS_DATA__.openSubmissionResult;
        }
        return {
          success: true as const,
          data: {
            submission_id: submissionId,
            candidate_id: "candidate-1",
            status_code: "READ" as const,
            full_name: "Nguyễn Thị An",
            email: "an@example.com",
            phone: "0901 234 567",
            date_of_birth: "1995-08-15",
            gender: "FEMALE",
            address: "Hà Nội",
            candidate_notes: null,
            submitted_at: "2026-09-02T09:00:00.000Z",
            version_no: 2,
          },
        };
      },
      getSubmissionDetail: async (submissionId: string) => {
        window.__BULK_HARNESS_LOGS__ = window.__BULK_HARNESS_LOGS__ ?? [];
        window.__BULK_HARNESS_LOGS__.push({
          event: "getSubmissionDetail",
          payload: { submissionId },
        });
        if (window.__BULK_HARNESS_DATA__?.drawerDetailResult) {
          return window.__BULK_HARNESS_DATA__.drawerDetailResult;
        }
        return {
          success: true as const,
          data: {
            submission_id: submissionId,
            candidate_id: "candidate-1",
            status_code: "READ" as const,
            full_name: "Nguyễn Thị An",
            date_of_birth: "1995-08-15",
            gender_code: "FEMALE" as const,
            current_address: "Hà Nội",
            phone: "0901 234 567",
            email: "an@example.com",
            other_info: null,
            hr_note: "Đã liên hệ qua drawer",
            recruitment_source_id: null,
            recruitment_source_name: null,
            submitted_at: "2026-09-02T09:00:00.000Z",
            updated_at: "2026-09-05T12:00:00.000Z",
            updated_by_name: "HR User",
            version_no: 2,
            education: [],
            work_experiences: [],
            activities: [],
            documents: [],
            applications: [],
          },
        };
      },
      updateSubmissionHrNote: async (input: {
        submissionId: string;
        hrNote: string | null;
        expectedVersion: number;
      }) => {
        window.__BULK_HARNESS_LOGS__ = window.__BULK_HARNESS_LOGS__ ?? [];
        window.__BULK_HARNESS_LOGS__.push({
          event: "updateSubmissionHrNote",
          payload: input,
        });
        if (window.__BULK_HARNESS_DATA__?.drawerUpdateHrNoteResult) {
          return window.__BULK_HARNESS_DATA__.drawerUpdateHrNoteResult;
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
    },
  };

  return (
    <div style={{ padding: "20px" }}>
      <ApplicationInboxTable groups={groups} actions={mockActions} />
    </div>
  );
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing inbox bulk test root");
createRoot(root).render(<ApplicationInboxBulkHarness />);
