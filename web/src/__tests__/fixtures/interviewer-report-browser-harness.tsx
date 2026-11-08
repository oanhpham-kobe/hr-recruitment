import { createRoot } from "react-dom/client";
import { InterviewerReportErrorState } from "@/components/reports/InterviewerReportErrorState";
import { InterviewerReportView } from "@/components/reports/InterviewerReportView";
import { AppShell } from "@/components/shell/AppShell";
import {
  LocaleProvider,
  useAppLocale,
} from "@/components/shell/LocaleProvider";
import {
  EMPTY_REPORT_FIELDS,
  type InterviewerReportPageData,
} from "@/lib/reports/model";
import type {
  SaveInterviewerReportInput,
  SaveInterviewerReportResult,
} from "@/lib/reports/server";
import "@/app/globals.css";
import "@/styles/reports.css";

const CURRENT_INTERVIEW = "22222222-2222-4222-8222-222222222222";
const CURRENT_PARTICIPANT = "33333333-3333-4333-8333-333333333333";
const REPORT_NAV_ITEMS = [
  {
    href: "/reports",
    labelVi: "Báo cáo phỏng vấn",
    labelEn: "Interview Reports",
  },
] as const;

let releasePendingSave: (() => void) | null = null;

Object.defineProperty(globalThis, "__releasePendingReportSave", {
  configurable: true,
  value: () => {
    releasePendingSave?.();
    releasePendingSave = null;
  },
});

function initialData(): InterviewerReportPageData {
  return {
    rounds: [
      {
        applicationId: "11111111-1111-4111-8111-111111111111",
        interviewId: CURRENT_INTERVIEW,
        roundNo: 2,
        isCurrentRound: true,
        candidateName: "Nguyễn Minh Anh",
        positionNameVi: "Giảng viên Kỹ thuật",
        positionNameEn: "Engineering Lecturer",
        startAt: "2026-09-08T02:00:00Z",
        endAt: "2026-09-08T03:00:00Z",
        formatNameVi: "Trực tuyến",
        formatNameEn: "Online",
        roomName: null,
        meetingLink: "https://meet.example.test/current",
        displayReportStatus: "WAITING_FOR_REPORT",
        canEdit: true,
        interviewParticipantId: CURRENT_PARTICIPANT,
        hasOwnReport: false,
        ownVersionNo: 1,
        ownReport: { ...EMPTY_REPORT_FIELDS },
        preview: {
          participants: [
            {
              participantOrder: 1,
              name: "Interviewer One",
              jobTitle: "Lecturer",
              report: { ...EMPTY_REPORT_FIELDS },
            },
            {
              participantOrder: 2,
              name: "Interviewer Two",
              jobTitle: "Professor",
              report: {
                ...EMPTY_REPORT_FIELDS,
                conclusion: "Trao đổi thêm",
              },
            },
          ],
          finalDecision: {
            conclusion: "Trao đổi thêm",
            expectedSpecificJobAssigned: null,
            expectedRecruitmentTime: null,
          },
        },
      },
      {
        applicationId: "11111111-1111-4111-8111-111111111111",
        interviewId: "44444444-4444-4444-8444-444444444444",
        roundNo: 1,
        isCurrentRound: false,
        candidateName: "Nguyễn Minh Anh",
        positionNameVi: "Giảng viên Kỹ thuật",
        positionNameEn: "Engineering Lecturer",
        startAt: "2026-08-20T02:00:00Z",
        endAt: "2026-08-20T03:00:00Z",
        formatNameVi: "Trực tiếp",
        formatNameEn: "In person",
        roomName: "B1.101",
        meetingLink: null,
        displayReportStatus: "REPORT_SUBMITTED",
        canEdit: false,
        interviewParticipantId: "55555555-5555-4555-8555-555555555555",
        hasOwnReport: true,
        ownVersionNo: 3,
        ownReport: {
          ...EMPTY_REPORT_FIELDS,
          professional_knowledge: "Historical knowledge",
          conclusion: "Historical conclusion",
        },
        preview: null,
      },
    ],
  };
}

let data = initialData();

async function save(
  input: SaveInterviewerReportInput,
): Promise<SaveInterviewerReportResult> {
  if (document.body.dataset.harness === "pending") {
    await new Promise<void>((resolve) => {
      releasePendingSave = resolve;
    });
  }

  const current = data.rounds.find(
    (round) => round.interviewParticipantId === input.interviewParticipantId,
  );
  if (!current?.canEdit) {
    return {
      success: false,
      error: { code: "FORBIDDEN", message: "Read only" },
    };
  }

  const nextReport = { ...current.ownReport, ...input.patches };
  data = {
    rounds: data.rounds.map((round) =>
      round.interviewId === current.interviewId
        ? {
            ...round,
            hasOwnReport: true,
            ownVersionNo: round.ownVersionNo + 1,
            ownReport: nextReport,
          }
        : round,
    ),
  };

  return {
    success: true,
    data: {
      interviewReportId: "66666666-6666-4666-8666-666666666666",
      versionNo: current.ownVersionNo + 1,
    },
  };
}

async function refresh() {
  return data;
}

function ReportSurface() {
  return (
    <InterviewerReportView
      initialData={data}
      onSave={save}
      onRefresh={refresh}
    />
  );
}

function ProductionHarness() {
  return (
    <div id="app-root" data-harness-ready="production">
      <AppShell currentPath="/reports" navItems={REPORT_NAV_ITEMS}>
        <ReportSurface />
      </AppShell>
    </div>
  );
}

function PendingHarness() {
  return (
    <div id="app-root" data-harness-ready="pending">
      <AppShell currentPath="/reports" navItems={REPORT_NAV_ITEMS}>
        <ReportSurface />
      </AppShell>
    </div>
  );
}

function LocaleHarness() {
  return (
    <LocaleProvider>
      <div id="app-root" data-harness-ready="locale">
        <ReportSurface />
      </div>
    </LocaleProvider>
  );
}

function ErrorHarnessContent() {
  const { setLocale } = useAppLocale();
  return (
    <>
      <button
        type="button"
        data-testid="error-switch-en"
        onClick={() => setLocale("en")}
      >
        Error switch EN
      </button>
      <button
        type="button"
        data-testid="error-switch-vi"
        onClick={() => setLocale("vi")}
      >
        Error switch VI
      </button>
      <div id="app-root" data-harness-ready="error">
        <InterviewerReportErrorState kind="access" />
      </div>
    </>
  );
}

function ErrorHarness() {
  return (
    <LocaleProvider>
      <ErrorHarnessContent />
    </LocaleProvider>
  );
}

const mode = document.body.dataset.harness;
data = initialData();
releasePendingSave = null;

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Report browser harness root is missing");
}

createRoot(rootElement).render(
  mode === "locale" ? (
    <LocaleHarness />
  ) : mode === "pending" ? (
    <PendingHarness />
  ) : mode === "error" ? (
    <ErrorHarness />
  ) : (
    <ProductionHarness />
  ),
);
