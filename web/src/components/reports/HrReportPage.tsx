"use client";

import {
  bulkChangeHrReportStatusAction,
  changeHrReportStatusAction,
  deleteHrParticipantReportAction,
  refreshHrReportPageAction,
  saveHrParticipantReportAction,
  setHrReportVisibilityAction,
  updateHrReportNoteAction,
} from "@/app/reports/actions";
import type { HrReportPageData } from "@/lib/reports/hr-model";
import { HrReportView } from "./HrReportView";

export function HrReportPage({
  initialData,
}: {
  initialData: HrReportPageData;
}) {
  return (
    <HrReportView
      initialData={initialData}
      onRefresh={refreshHrReportPageAction}
      onStatus={changeHrReportStatusAction}
      onBulkStatus={bulkChangeHrReportStatusAction}
      onVisibility={setHrReportVisibilityAction}
      onNote={updateHrReportNoteAction}
      onSaveParticipantReport={saveHrParticipantReportAction}
      onDeleteParticipantReport={deleteHrParticipantReportAction}
    />
  );
}
