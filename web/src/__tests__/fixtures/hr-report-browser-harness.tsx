import { createRoot } from "react-dom/client";
import { HrReportView } from "@/components/reports/HrReportView";
import { AppShell } from "@/components/shell/AppShell";
import {
  HR_REPORT_STATUSES,
  type HrReportFilters,
  type HrReportPageData,
  INITIAL_HR_REPORT_FILTERS,
} from "@/lib/reports/hr-model";
import type {
  BulkHrReportStatusInput,
  DeleteHrParticipantReportInput,
  HrReportCommandResult,
  HrReportNoteInput,
  HrReportStatusInput,
  HrReportVisibilityInput,
  SaveHrParticipantReportInput,
} from "@/lib/reports/hr-server";
import { EMPTY_REPORT_FIELDS } from "@/lib/reports/model";
import "@/app/globals.css";
import "@/styles/reports.css";

const APP_1 = "11111111-1111-4111-8111-111111111111";
const APP_2 = "11111111-1111-4111-8111-222222222222";
const INTERVIEW_1 = "22222222-2222-4222-8222-111111111111";
const INTERVIEW_2 = "22222222-2222-4222-8222-222222222222";
const PARTICIPANT_1 = "33333333-3333-4333-8333-111111111111";
const PARTICIPANT_2 = "33333333-3333-4333-8333-222222222222";
const REPORT_1 = "44444444-4444-4444-8444-111111111111";
const REPORT_2 = "44444444-4444-4444-8444-222222222222";

const NAV_ITEMS = [
  {
    href: "/reports",
    labelVi: "Báo cáo phỏng vấn",
    labelEn: "Interview Reports",
  },
] as const;

function initialData(): HrReportPageData {
  return {
    rows: [
      {
        applicationId: APP_1,
        interviewId: INTERVIEW_1,
        roundNo: 2,
        interviewVersionNo: 5,
        candidateName: "Nguyễn Minh Anh",
        positionNameVi: "Giảng viên Kỹ thuật",
        positionNameEn: "Engineering Lecturer",
        startAt: "2026-09-10T02:00:00Z",
        endAt: "2026-09-10T03:00:00Z",
        formatNameVi: "Trực tuyến",
        formatNameEn: "Online",
        roomName: null,
        reportStatus: "WAITING_FOR_REPORT",
        hrReportNote: "Ghi chú HR giữ nguyên ngôn ngữ người dùng",
        visibleToInterviewers: true,
        lastUpdatedAt: "2026-09-10T03:05:00Z",
        lastUpdatedByName: "HR Owner",
        drawer: {
          hrOwnerName: "HR Owner",
          participants: [
            {
              interviewParticipantId: PARTICIPANT_1,
              participantOrder: 1,
              name: "Interviewer One",
              jobTitle: "Lecturer",
              interviewReportId: REPORT_1,
              reportVersionNo: 3,
              report: {
                ...EMPTY_REPORT_FIELDS,
                professional_knowledge: "Kiến thức tốt",
                conclusion: "Proceed",
              },
              updatedAt: "2026-09-10T03:00:00Z",
              updatedByName: "Interviewer One",
            },
            {
              interviewParticipantId: PARTICIPANT_2,
              participantOrder: 2,
              name: "Interviewer Two",
              jobTitle: "Professor",
              interviewReportId: REPORT_2,
              reportVersionNo: 2,
              report: {
                ...EMPTY_REPORT_FIELDS,
                professional_knowledge: "Strong",
                conclusion: "Follow up",
              },
              updatedAt: "2026-09-10T03:01:00Z",
              updatedByName: "Interviewer Two",
            },
          ],
          finalDecision: {
            sourceInterviewReportId: REPORT_1,
            sourceParticipantName: "Interviewer One",
            conclusion: "Proceed",
            expectedSpecificJobAssigned: "Engineering Lecturer",
            expectedRecruitmentTime: "October 2026",
            updatedAt: "2026-09-10T03:00:00Z",
            updatedByName: "Interviewer One",
          },
        },
      },
      {
        applicationId: APP_2,
        interviewId: INTERVIEW_2,
        roundNo: 1,
        interviewVersionNo: 2,
        candidateName: "Trần Gia Bảo",
        positionNameVi: "Chuyên viên Tuyển dụng",
        positionNameEn: "Recruitment Specialist",
        startAt: "2026-09-11T02:00:00Z",
        endAt: "2026-09-11T03:00:00Z",
        formatNameVi: "Trực tiếp",
        formatNameEn: "In person",
        roomName: "B1.101",
        reportStatus: "FOLLOW_UP",
        hrReportNote: null,
        visibleToInterviewers: false,
        lastUpdatedAt: "2026-09-09T04:00:00Z",
        lastUpdatedByName: "HR Owner",
        drawer: {
          hrOwnerName: "HR Owner",
          participants: [],
          finalDecision: {
            sourceInterviewReportId: null,
            sourceParticipantName: null,
            conclusion: null,
            expectedSpecificJobAssigned: null,
            expectedRecruitmentTime: null,
            updatedAt: null,
            updatedByName: null,
          },
        },
      },
    ],
    page: 1,
    pageSize: 20,
    total: 2,
    pageCount: 1,
    permissions: {
      manageStatus: true,
      visibility: true,
      editInterviewer: true,
      delete: true,
    },
  };
}

let data = initialData();

function success(extra: Record<string, unknown> = {}): HrReportCommandResult {
  return { success: true, data: extra };
}

function remoteParticipantEdit(value: string) {
  data = {
    ...data,
    rows: data.rows.map((row) => ({
      ...row,
      drawer: {
        ...row.drawer,
        participants: row.drawer.participants.map((participant) =>
          participant.interviewParticipantId === PARTICIPANT_1
            ? {
                ...participant,
                report: {
                  ...participant.report,
                  professional_knowledge: value,
                },
                reportVersionNo: participant.reportVersionNo + 1,
              }
            : participant,
        ),
      },
    })),
  };
}

Object.defineProperty(globalThis, "__hrReportRemoteParticipantEdit", {
  configurable: true,
  value: remoteParticipantEdit,
});

async function refresh(
  filters?: Partial<HrReportFilters>,
): Promise<HrReportPageData> {
  const normalized = { ...INITIAL_HR_REPORT_FILTERS, ...filters };
  let rows = [...data.rows];
  if (normalized.status) {
    rows = rows.filter((row) => row.reportStatus === normalized.status);
  }
  if (normalized.visibility === "VISIBLE") {
    rows = rows.filter((row) => row.visibleToInterviewers);
  }
  if (normalized.visibility === "HIDDEN") {
    rows = rows.filter((row) => !row.visibleToInterviewers);
  }
  if (normalized.search) {
    const term = normalized.search.toLocaleLowerCase("vi");
    rows = rows.filter(
      (row) =>
        row.candidateName.toLocaleLowerCase("vi").includes(term) ||
        row.positionNameVi.toLocaleLowerCase("vi").includes(term),
    );
  }
  return {
    ...data,
    rows,
    page: normalized.page,
    pageSize: normalized.pageSize,
    total: rows.length,
    pageCount: rows.length ? 1 : 0,
  };
}

async function status(
  input: HrReportStatusInput,
): Promise<HrReportCommandResult> {
  if (!HR_REPORT_STATUSES.includes(input.status)) {
    return { success: false, error: { code: "VALIDATION_ERROR" } };
  }
  data = {
    ...data,
    rows: data.rows.map((row) =>
      row.interviewId === input.interviewId
        ? {
            ...row,
            reportStatus: input.status,
            interviewVersionNo: row.interviewVersionNo + 1,
          }
        : row,
    ),
  };
  return success();
}

async function bulkStatus(
  input: BulkHrReportStatusInput,
): Promise<HrReportCommandResult> {
  const ids = new Set(input.targets.map((target) => target.interviewId));
  data = {
    ...data,
    rows: data.rows.map((row) =>
      ids.has(row.interviewId)
        ? {
            ...row,
            reportStatus: input.status,
            interviewVersionNo: row.interviewVersionNo + 1,
          }
        : row,
    ),
  };
  return success({ updated_count: ids.size });
}

async function visibility(
  input: HrReportVisibilityInput,
): Promise<HrReportCommandResult> {
  data = {
    ...data,
    rows: data.rows.map((row) =>
      row.interviewId === input.interviewId
        ? {
            ...row,
            visibleToInterviewers: input.visible,
            interviewVersionNo: row.interviewVersionNo + 1,
          }
        : row,
    ),
  };
  return success();
}

async function note(input: HrReportNoteInput): Promise<HrReportCommandResult> {
  data = {
    ...data,
    rows: data.rows.map((row) =>
      row.interviewId === input.interviewId
        ? {
            ...row,
            hrReportNote: input.note,
            interviewVersionNo: row.interviewVersionNo + 1,
          }
        : row,
    ),
  };
  return success();
}

async function saveParticipant(
  input: SaveHrParticipantReportInput,
): Promise<HrReportCommandResult> {
  const currentParticipant = data.rows
    .flatMap((row) => row.drawer.participants)
    .find(
      (participant) =>
        participant.interviewParticipantId === input.interviewParticipantId,
    );
  if (!currentParticipant) {
    return { success: false, error: { code: "NOT_FOUND" } };
  }
  for (const key of Object.keys(input.patches) as Array<
    keyof typeof input.patches
  >) {
    if (currentParticipant.report[key] !== input.baseValues[key]) {
      return { success: false, error: { code: "STALE_VERSION" } };
    }
  }

  data = {
    ...data,
    rows: data.rows.map((row) => ({
      ...row,
      drawer: {
        ...row.drawer,
        participants: row.drawer.participants.map((participant) =>
          participant.interviewParticipantId === input.interviewParticipantId
            ? {
                ...participant,
                report: { ...participant.report, ...input.patches },
                reportVersionNo: participant.reportVersionNo + 1,
              }
            : participant,
        ),
      },
    })),
  };
  return success();
}

async function deleteParticipant(
  input: DeleteHrParticipantReportInput,
): Promise<HrReportCommandResult> {
  data = {
    ...data,
    rows: data.rows.map((row) => ({
      ...row,
      drawer: {
        ...row.drawer,
        participants: row.drawer.participants.map((participant) =>
          participant.interviewReportId === input.interviewReportId
            ? {
                ...participant,
                interviewReportId: null,
                reportVersionNo: 1,
                report: { ...EMPTY_REPORT_FIELDS },
              }
            : participant,
        ),
      },
    })),
  };
  return success({ action: "INACTIVATED" });
}

function Surface() {
  return (
    <HrReportView
      initialData={data}
      onRefresh={refresh}
      onStatus={status}
      onBulkStatus={bulkStatus}
      onVisibility={visibility}
      onNote={note}
      onSaveParticipantReport={saveParticipant}
      onDeleteParticipantReport={deleteParticipant}
    />
  );
}

function Harness() {
  return (
    <div id="app-root" data-harness-ready="hr-report">
      <AppShell currentPath="/reports" navItems={NAV_ITEMS}>
        <Surface />
      </AppShell>
    </div>
  );
}

data = initialData();
const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("HR Report browser harness root is missing");
}
createRoot(rootElement).render(<Harness />);
