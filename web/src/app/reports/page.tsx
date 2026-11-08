import { HrReportPage } from "@/components/reports/HrReportPage";
import { InterviewerReportErrorState } from "@/components/reports/InterviewerReportErrorState";
import { InterviewerReportPage } from "@/components/reports/InterviewerReportPage";
import { getServerSession } from "@/lib/auth/session";
import {
  HrReportAccessError,
  loadHrReportPage,
  sessionUsesHrReportExperience,
} from "@/lib/reports/hr-server";
import {
  InterviewerReportAccessError,
  loadInterviewerReportPage,
} from "@/lib/reports/server";
import "@/styles/reports.css";

export const dynamic = "force-dynamic";

export default async function ReportsPage() {
  try {
    const session = await getServerSession();
    if (sessionUsesHrReportExperience(session)) {
      const data = await loadHrReportPage();
      return <HrReportPage initialData={data} />;
    }

    const data = await loadInterviewerReportPage();
    return <InterviewerReportPage initialData={data} />;
  } catch (error) {
    return (
      <InterviewerReportErrorState
        kind={
          error instanceof InterviewerReportAccessError ||
          error instanceof HrReportAccessError
            ? "access"
            : "load"
        }
      />
    );
  }
}
