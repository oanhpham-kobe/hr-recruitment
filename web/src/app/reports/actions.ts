"use server";

import { revalidatePath } from "next/cache";
import type { HrReportFilters } from "@/lib/reports/hr-model";
import {
  type BulkHrReportStatusInput,
  bulkChangeHrReportStatus,
  changeHrReportStatus,
  type DeleteHrParticipantReportInput,
  deleteHrParticipantReport,
  type HrReportNoteInput,
  type HrReportStatusInput,
  type HrReportVisibilityInput,
  loadHrReportPage,
  type SaveHrParticipantReportInput,
  saveHrParticipantReport,
  setHrReportVisibility,
  updateHrReportNote,
} from "@/lib/reports/hr-server";
import {
  loadInterviewerReportPage,
  type SaveInterviewerReportInput,
  saveOwnInterviewerReport,
} from "@/lib/reports/server";

export async function refreshInterviewerReportPageAction() {
  return loadInterviewerReportPage();
}

export async function saveInterviewerReportAction(
  input: SaveInterviewerReportInput,
) {
  const result = await saveOwnInterviewerReport(input);
  if (result.success) revalidatePath("/reports");
  return result;
}

export async function refreshHrReportPageAction(
  filters?: Partial<HrReportFilters>,
) {
  return loadHrReportPage({ filters });
}

export async function changeHrReportStatusAction(input: HrReportStatusInput) {
  const result = await changeHrReportStatus(input);
  if (result.success) revalidatePath("/reports");
  return result;
}

export async function bulkChangeHrReportStatusAction(
  input: BulkHrReportStatusInput,
) {
  const result = await bulkChangeHrReportStatus(input);
  if (result.success) revalidatePath("/reports");
  return result;
}

export async function setHrReportVisibilityAction(
  input: HrReportVisibilityInput,
) {
  const result = await setHrReportVisibility(input);
  if (result.success) revalidatePath("/reports");
  return result;
}

export async function updateHrReportNoteAction(input: HrReportNoteInput) {
  const result = await updateHrReportNote(input);
  if (result.success) revalidatePath("/reports");
  return result;
}

export async function saveHrParticipantReportAction(
  input: SaveHrParticipantReportInput,
) {
  const result = await saveHrParticipantReport(input);
  if (result.success) revalidatePath("/reports");
  return result;
}

export async function deleteHrParticipantReportAction(
  input: DeleteHrParticipantReportInput,
) {
  const result = await deleteHrParticipantReport(input);
  if (result.success) revalidatePath("/reports");
  return result;
}
