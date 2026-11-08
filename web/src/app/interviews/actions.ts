"use server";

import { revalidatePath } from "next/cache";
import { loadAssignmentOptions } from "@/lib/application-inbox/submission-detail-server";
import { getServerSession } from "@/lib/auth/session";
import { createOrUpdateApplication } from "@/lib/commands/application-lifecycle";
import {
  bulkEnqueueInterviewEmails,
  deleteEmailHistoryEntry,
  type EmailEnqueueInput,
  type EmailPreviewInput,
  enqueueInterviewEmail,
  loadInterviewEmailHistory,
  previewInterviewEmail,
} from "@/lib/commands/email-commands";
import {
  addInterviewParticipant,
  type CopyInterviewScheduleInput,
  changeInterviewScheduleStatus,
  copyInterviewSchedule,
  createNextInterviewRound,
  deleteOrInactivateApplication,
  deleteOrInactivateInterview,
  reactivateApplication,
  reactivateInterview,
  readdInterviewParticipant,
  removeInterviewParticipant,
  reorderInterviewParticipants,
  rescheduleConfirmedInterview,
  type SaveInterviewScheduleInput,
  saveInterviewSchedule,
} from "@/lib/commands/interview-lifecycle";
import type { InterviewPageFilters } from "@/lib/interview/model";
import {
  loadInterviewPage,
  searchApplicationOptions,
  searchSubmissionOptions,
} from "@/lib/interview/server";
import { createServerClient } from "@/lib/supabase/server";

function refreshOnSuccess<T extends { success: boolean }>(result: T): T {
  if (result.success) revalidatePath("/interviews");
  return result;
}

export async function queryInterviewPageAction(input: {
  filters: InterviewPageFilters;
  page: number;
}) {
  return loadInterviewPage({ filters: input.filters, page: input.page });
}

export async function searchSubmissionOptionsAction(query: string) {
  try {
    return {
      success: true as const,
      data: await searchSubmissionOptions(query),
    };
  } catch {
    return {
      success: false as const,
      error: "Không thể tải danh sách Phiếu ứng tuyển.",
    };
  }
}

export async function searchApplicationOptionsAction(query: string) {
  try {
    return {
      success: true as const,
      data: await searchApplicationOptions(query),
    };
  } catch {
    return {
      success: false as const,
      error: "Không thể tải danh sách Application.",
    };
  }
}

export async function getInterviewAssignmentOptionsAction() {
  try {
    return { success: true as const, data: await loadAssignmentOptions() };
  } catch {
    return {
      success: false as const,
      error: "Không thể tải danh mục phân công Application.",
    };
  }
}

export async function getInterviewEmailCapabilitiesAction() {
  const client = await createServerClient();
  const session = await getServerSession(client);
  const user = session.user;
  const root = user?.roles.includes("ROOT_ADMIN") === true;
  const has = (permission: string) =>
    root || user?.permissions.includes(permission) === true;
  return {
    canSend: Boolean(user?.isInternal && has("interviews.email")),
    canViewHistory: Boolean(user?.isInternal && has("emails.history_view")),
    canDeleteHistory: Boolean(
      user?.isInternal &&
        has("emails.history_view") &&
        has("emails.history_delete"),
    ),
  };
}

export async function previewInterviewEmailAction(input: EmailPreviewInput) {
  return previewInterviewEmail(input);
}

export async function enqueueInterviewEmailAction(input: {
  request: EmailEnqueueInput;
  idempotencyKey: string;
}) {
  return enqueueInterviewEmail(input.request, input.idempotencyKey);
}

export async function bulkEnqueueInterviewEmailsAction(input: {
  requests: EmailEnqueueInput[];
  idempotencyKey: string;
}) {
  return bulkEnqueueInterviewEmails(input.requests, input.idempotencyKey);
}

export async function loadInterviewEmailHistoryAction(interviewId: string) {
  return loadInterviewEmailHistory(interviewId);
}

export async function deleteEmailHistoryEntryAction(input: {
  emailHistoryId: string;
  classification: "TEST_RECORD" | "WRONG_RECORD";
  reason: string | null;
}) {
  return deleteEmailHistoryEntry(
    input.emailHistoryId,
    input.classification,
    input.reason,
  );
}

export async function createInterviewApplicationAction(input: {
  submissionId: string;
  unitId: string;
  departmentTeamId?: string | null;
  positionId: string;
  hrOwnerId: string;
  idempotencyKey: string;
  confirmDuplicate?: boolean;
}) {
  const result = await createOrUpdateApplication({
    submissionId: input.submissionId,
    unitId: input.unitId,
    departmentTeamId: input.departmentTeamId ?? null,
    positionId: input.positionId,
    hrOwnerId: input.hrOwnerId,
    idempotencyKey: input.idempotencyKey,
    confirmDuplicate: input.confirmDuplicate,
  });
  if (!result.success)
    return {
      success: false as const,
      error: result.error.message,
      code: result.error.code,
    };
  revalidatePath("/interviews");
  return { success: true as const, data: result.data };
}

export async function createNextRoundAction(input: {
  applicationId: string;
  idempotencyKey: string;
}) {
  return refreshOnSuccess(await createNextInterviewRound(input));
}

export async function saveInterviewScheduleAction(
  input: SaveInterviewScheduleInput,
) {
  return refreshOnSuccess(await saveInterviewSchedule(input));
}

export async function changeInterviewStatusAction(input: {
  interviewId: string;
  status: string;
  expectedVersion: number;
}) {
  return refreshOnSuccess(await changeInterviewScheduleStatus(input));
}

export async function rescheduleConfirmedAction(
  input: Omit<SaveInterviewScheduleInput, "demoTopic" | "interviewNote">,
) {
  return refreshOnSuccess(await rescheduleConfirmedInterview(input));
}

export async function copyInterviewScheduleAction(
  input: CopyInterviewScheduleInput,
) {
  return refreshOnSuccess(await copyInterviewSchedule(input));
}

export async function reactivateApplicationAction(input: {
  applicationId: string;
  expectedVersion: number;
}) {
  return refreshOnSuccess(await reactivateApplication(input));
}

export async function deleteOrInactivateApplicationAction(
  applicationId: string,
) {
  return refreshOnSuccess(await deleteOrInactivateApplication(applicationId));
}

export async function reactivateInterviewAction(input: {
  interviewId: string;
  expectedVersion: number;
}) {
  return refreshOnSuccess(await reactivateInterview(input));
}

export async function deleteOrInactivateInterviewAction(input: {
  interviewId: string;
  expectedVersion: number;
}) {
  return refreshOnSuccess(await deleteOrInactivateInterview(input));
}

export async function addInterviewParticipantAction(input: {
  interviewId: string;
  appUserId: string;
  idempotencyKey: string;
}) {
  return refreshOnSuccess(await addInterviewParticipant(input));
}

export async function removeInterviewParticipantAction(input: {
  interviewParticipantId: string;
  expectedVersion: number;
}) {
  return refreshOnSuccess(await removeInterviewParticipant(input));
}

export async function readdInterviewParticipantAction(input: {
  interviewParticipantId: string;
  restoreMode: "RESTORE_OLD_REPORT" | "CREATE_NEW_REPORT";
  idempotencyKey: string;
}) {
  return refreshOnSuccess(await readdInterviewParticipant(input));
}

export async function reorderInterviewParticipantsAction(input: {
  interviewId: string;
  participantIds: string[];
  expectedVersions: number[];
}) {
  return refreshOnSuccess(await reorderInterviewParticipants(input));
}
