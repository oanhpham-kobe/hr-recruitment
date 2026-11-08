"use client";

import {
  refreshInterviewerReportPageAction,
  saveInterviewerReportAction,
} from "@/app/reports/actions";
import type { InterviewerReportPageData } from "@/lib/reports/model";
import { InterviewerReportView } from "./InterviewerReportView";

export function InterviewerReportPage({
  initialData,
}: {
  initialData: InterviewerReportPageData;
}) {
  return (
    <InterviewerReportView
      initialData={initialData}
      onSave={saveInterviewerReportAction}
      onRefresh={refreshInterviewerReportPageAction}
    />
  );
}
