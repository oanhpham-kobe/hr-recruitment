import { createRoot } from "react-dom/client";
import { EmailHistoryDrawer } from "@/components/interview/EmailHistoryDrawer";
import { EmailPreviewDialog } from "@/components/interview/EmailPreviewDialog";
import { InterviewPage } from "@/components/interview/InterviewPage";
import { LocaleProvider } from "@/components/shell/LocaleProvider";
import type { EmailHistoryEntry } from "@/lib/commands/email-commands";
import type { InterviewPageData } from "@/lib/interview/model";
import "@/app/globals.css";
import "@/styles/interview.css";
import { installInterviewEmailHarnessState } from "./interview-email-harness-state";

const IDS = {
  interview1: "10000000-0000-0000-0000-000000000001",
  interview2: "10000000-0000-0000-0000-000000000002",
  application1: "20000000-0000-0000-0000-000000000001",
  application2: "20000000-0000-0000-0000-000000000002",
  submission1: "30000000-0000-0000-0000-000000000001",
  submission2: "30000000-0000-0000-0000-000000000002",
} as const;

const PAGE_DATA: InterviewPageData = {
  groups: [
    {
      applicationId: IDS.application1,
      submissionId: IDS.submission1,
      candidateId: "40000000-0000-0000-0000-000000000001",
      candidateName: "Nguyễn Thị An",
      candidateEmail: "an@example.com",
      candidatePhone: "0901000001",
      submissionDate: "2026-09-01T02:00:00.000Z",
      submissionStatus: "NEW",
      unitId: "50000000-0000-0000-0000-000000000001",
      unitName: "Khoa A",
      departmentTeamId: null,
      departmentTeamName: null,
      positionId: "60000000-0000-0000-0000-000000000001",
      positionName: "Giảng viên",
      hrOwnerId: "70000000-0000-0000-0000-000000000001",
      hrOwnerName: "HR One",
      isActive: true,
      versionNo: 1,
      rounds: [
        {
          interviewId: IDS.interview1,
          applicationId: IDS.application1,
          roundNo: 1,
          demoTopic: "Topic A",
          startAt: "2026-09-20T02:00:00.000Z",
          endAt: "2026-09-20T03:00:00.000Z",
          interviewFormatId: null,
          roomId: null,
          meetingLink: "https://meet.example.test/a",
          scheduleStatus: "CONFIRMED",
          reportStatus: "PENDING",
          interviewNote: null,
          isActive: true,
          versionNo: 1,
          updatedAt: "2026-09-16T02:00:00.000Z",
          participants: [
            {
              interviewParticipantId: "80000000-0000-0000-0000-000000000001",
              appUserId: "90000000-0000-0000-0000-000000000001",
              order: 1,
              name: "Interviewer One",
              email: "interviewer.one@example.com",
              jobTitle: "Lecturer",
              isCurrent: true,
              removedAt: null,
              versionNo: 1,
              hasReportHistory: false,
            },
          ],
        },
      ],
    },
    {
      applicationId: IDS.application2,
      submissionId: IDS.submission2,
      candidateId: "40000000-0000-0000-0000-000000000002",
      candidateName: "Trần Minh Bình",
      candidateEmail: "binh@example.com",
      candidatePhone: "0901000002",
      submissionDate: "2026-09-02T02:00:00.000Z",
      submissionStatus: "NEW",
      unitId: "50000000-0000-0000-0000-000000000001",
      unitName: "Khoa A",
      departmentTeamId: null,
      departmentTeamName: null,
      positionId: "60000000-0000-0000-0000-000000000001",
      positionName: "Giảng viên",
      hrOwnerId: "70000000-0000-0000-0000-000000000001",
      hrOwnerName: "HR One",
      isActive: true,
      versionNo: 1,
      rounds: [
        {
          interviewId: IDS.interview2,
          applicationId: IDS.application2,
          roundNo: 2,
          demoTopic: "Topic B",
          startAt: "2026-09-21T02:00:00.000Z",
          endAt: "2026-09-21T03:00:00.000Z",
          interviewFormatId: null,
          roomId: null,
          meetingLink: "https://meet.example.test/b",
          scheduleStatus: "CONFIRMED",
          reportStatus: "PENDING",
          interviewNote: null,
          isActive: true,
          versionNo: 1,
          updatedAt: "2026-09-16T02:00:00.000Z",
          participants: [
            {
              interviewParticipantId: "80000000-0000-0000-0000-000000000002",
              appUserId: "90000000-0000-0000-0000-000000000002",
              order: 1,
              name: "Interviewer Two",
              email: "interviewer.two@example.com",
              jobTitle: "Lecturer",
              isCurrent: true,
              removedAt: null,
              versionNo: 1,
              hasReportHistory: false,
            },
          ],
        },
      ],
    },
  ],
  page: 1,
  pageCount: 1,
  formats: [],
  rooms: [],
  participantUsers: [],
  filterUnits: [],
  filterTeams: [],
  filterPositions: [],
  filterHrOwners: [],
  permissions: {
    canView: true,
    canManage: true,
    canChangeStatus: true,
    canManageParticipants: true,
    canCreateApplication: true,
    canReactivateApplication: true,
    canDeleteApplication: true,
  },
};

const HISTORY_ROWS: EmailHistoryEntry[] = [
  {
    email_history_id: "a0000000-0000-0000-0000-000000000001",
    interview_id: IDS.interview1,
    email_type: "INTERVIEW_INVITATION",
    environment_code: "TEST",
    recipients: { to: ["an@example.com"], cc: [] },
    subject: "Sent interview",
    template_version: "test-1",
    sent_at: "2026-09-16T03:00:00.000Z",
    created_at: "2026-09-16T02:59:00.000Z",
    status_code: "SENT",
    error_code: null,
  },
  {
    email_history_id: "a0000000-0000-0000-0000-000000000002",
    interview_id: IDS.interview1,
    email_type: "INTERVIEW_PARTICIPANT_INVITATION",
    environment_code: "PRODUCTION",
    recipients: { to: ["interviewer.one@example.com"], cc: [] },
    subject: "Failed participant email",
    template_version: "prod-1",
    sent_at: null,
    created_at: "2026-09-16T03:10:00.000Z",
    status_code: "FAILED",
    error_code: "PROVIDER_ERROR",
  },
  {
    email_history_id: "a0000000-0000-0000-0000-000000000003",
    interview_id: IDS.interview1,
    email_type: "INTERVIEW_INVITATION",
    environment_code: "TEST",
    recipients: { to: ["an@example.com"], cc: [] },
    subject: "Cancelled interview email",
    template_version: "test-1",
    sent_at: null,
    created_at: "2026-09-16T03:20:00.000Z",
    status_code: "CANCELLED",
    error_code: null,
  },
  {
    email_history_id: "a0000000-0000-0000-0000-000000000004",
    interview_id: IDS.interview1,
    email_type: "INTERVIEW_INVITATION",
    environment_code: "TEST",
    recipients: { to: ["an@example.com"], cc: [] },
    subject: "Abandoned interview email",
    template_version: "test-1",
    sent_at: null,
    created_at: "2026-09-16T03:30:00.000Z",
    status_code: "ABANDONED",
    error_code: null,
  },
];

function PageHarness() {
  return (
    <div data-harness-ready="page">
      <LocaleProvider>
        <InterviewPage initialData={PAGE_DATA} />
      </LocaleProvider>
    </div>
  );
}

function PreviewStaleHarness() {
  const state = window.__interviewEmailHarness;
  if (!state) throw new Error("Preview harness state missing");
  state.staleNextEnqueue = true;
  return (
    <div data-harness-ready="preview-stale">
      <EmailPreviewDialog
        open
        emailType="INTERVIEW_INVITATION"
        interviewId={IDS.interview1}
        applicationId={IDS.application1}
        submissionId={IDS.submission1}
        contextSummary="Vòng 1 · Browser acceptance"
        onClose={() => undefined}
        onQueued={() => {
          state.queuedNotices += 1;
        }}
      />
    </div>
  );
}

function HistoryHarness() {
  return (
    <div data-harness-ready="history">
      <EmailHistoryDrawer
        open
        interviewId={IDS.interview1}
        title="Nguyễn Thị An — Vòng 1"
        canDelete
        onClose={() => undefined}
      />
    </div>
  );
}

const mode = document.body.dataset.harness ?? "page";
const historyRows = mode === "history" ? HISTORY_ROWS : [];
installInterviewEmailHarnessState(PAGE_DATA, historyRows);
const rootElement = document.getElementById("root");
if (!rootElement)
  throw new Error("Interview email browser harness root is missing");
const root = createRoot(rootElement);
if (mode === "preview-stale") root.render(<PreviewStaleHarness />);
else if (mode === "history") root.render(<HistoryHarness />);
else root.render(<PageHarness />);
