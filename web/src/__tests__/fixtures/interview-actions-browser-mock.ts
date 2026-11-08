import { interviewEmailHarnessState } from "./interview-email-harness-state";

function findTarget(interviewId: string) {
  const state = interviewEmailHarnessState();
  for (const application of state.pageData.groups) {
    const round = application.rounds.find(
      (candidateRound) => candidateRound.interviewId === interviewId,
    );
    if (round) return { application, round };
  }
  return null;
}

function fingerprintFor(interviewId: string, revision: number): string {
  const suffix = interviewId.at(-1) ?? "0";
  const revisionHex = (revision % 16).toString(16);
  return `${"a".repeat(62)}${suffix}${revisionHex}`;
}

export async function getInterviewEmailCapabilitiesAction() {
  return {
    canSend: true,
    canViewHistory: true,
    canDeleteHistory: true,
  };
}

export async function previewInterviewEmailAction(input: {
  emailType: "INTERVIEW_INVITATION" | "INTERVIEW_PARTICIPANT_INVITATION";
  interviewId: string;
  applicationId: string;
  submissionId: string;
}) {
  const state = interviewEmailHarnessState();
  state.previewCalls.push(input);
  const previewFingerprint = fingerprintFor(
    input.interviewId,
    state.previewCalls.length,
  );
  state.previewFingerprints.push(previewFingerprint);
  const target = findTarget(input.interviewId);
  if (!target) {
    return {
      success: false as const,
      error: {
        code: "INVALID_EMAIL_CONTEXT",
        message: "Missing harness target",
      },
    };
  }
  const recipients =
    input.emailType === "INTERVIEW_INVITATION"
      ? [target.application.candidateEmail]
      : target.round.participants
          .filter((participant) => participant.isCurrent)
          .map((participant) => participant.email);
  return {
    success: true as const,
    data: {
      recipients: { to: recipients, cc: [] },
      subject: `Server subject — ${target.application.candidateName}`,
      body_text: `Server body — ${target.application.candidateName}\nInterview ${target.round.roundNo}`,
      template_version: "test-1",
      environment_code: "TEST" as const,
      context_fingerprint: "b".repeat(64),
      preview_fingerprint: previewFingerprint,
      email_type: input.emailType,
      interview_id: input.interviewId,
      application_id: input.applicationId,
      submission_id: input.submissionId,
    },
  };
}

export async function enqueueInterviewEmailAction(input: {
  request: {
    email_type: "INTERVIEW_INVITATION" | "INTERVIEW_PARTICIPANT_INVITATION";
    interview_id: string;
    application_id: string;
    submission_id: string;
    preview_fingerprint: string;
  };
  idempotencyKey: string;
}) {
  const state = interviewEmailHarnessState();
  state.enqueueCalls.push(input);
  if (state.staleNextEnqueue) {
    state.staleNextEnqueue = false;
    return {
      success: false as const,
      error: {
        code: "STALE_PREVIEW",
        message:
          "Thông tin phỏng vấn đã thay đổi, vui lòng xem lại bản xem trước.",
      },
    };
  }
  return {
    success: true as const,
    data: { email_outbox_id: `outbox-${input.request.interview_id}` },
  };
}

export async function bulkEnqueueInterviewEmailsAction(input: {
  requests: Array<{
    email_type: "INTERVIEW_INVITATION" | "INTERVIEW_PARTICIPANT_INVITATION";
    interview_id: string;
    application_id: string;
    submission_id: string;
    preview_fingerprint: string;
  }>;
  idempotencyKey: string;
}) {
  const state = interviewEmailHarnessState();
  state.bulkCalls.push(input);
  return {
    success: true as const,
    data: {
      success: input.requests.map((request) => ({
        id: request.interview_id,
        email_type: request.email_type,
        application_id: request.application_id,
        submission_id: request.submission_id,
        email_outbox_id: `outbox-${request.interview_id}`,
      })),
      failed: [],
    },
  };
}

export async function loadInterviewEmailHistoryAction(interviewId: string) {
  const state = interviewEmailHarnessState();
  if (state.failNextHistoryLoad) {
    state.failNextHistoryLoad = false;
    return {
      success: false as const,
      error: {
        code: "INTERNAL_ERROR",
        message: "Không thể tải Email History. Vui lòng thử lại.",
      },
    };
  }
  return {
    success: true as const,
    data: state.historyRows.filter((row) => row.interview_id === interviewId),
  };
}

export async function deleteEmailHistoryEntryAction(input: {
  emailHistoryId: string;
  classification: "TEST_RECORD" | "WRONG_RECORD";
  reason: string | null;
}) {
  const state = interviewEmailHarnessState();
  state.deleteCalls.push(input);
  state.historyRows = state.historyRows.filter(
    (row) => row.email_history_id !== input.emailHistoryId,
  );
  return {
    success: true as const,
    data: { email_history_id: input.emailHistoryId },
  };
}

export async function queryInterviewPageAction() {
  return interviewEmailHarnessState().pageData;
}

export async function changeInterviewStatusAction() {
  const state = interviewEmailHarnessState();
  state.interviewStatusMutations += 1;
  return { success: true as const, data: {} };
}

const mutationSuccess = async () => ({ success: true as const, data: {} });
const searchSuccess = async () => ({ success: true as const, data: [] });

export const addInterviewParticipantAction = mutationSuccess;
export const copyInterviewScheduleAction = mutationSuccess;
export const createNextRoundAction = mutationSuccess;
export const deleteOrInactivateApplicationAction = mutationSuccess;
export const deleteOrInactivateInterviewAction = mutationSuccess;
export const reactivateApplicationAction = mutationSuccess;
export const reactivateInterviewAction = mutationSuccess;
export const readdInterviewParticipantAction = mutationSuccess;
export const removeInterviewParticipantAction = mutationSuccess;
export const reorderInterviewParticipantsAction = mutationSuccess;
export const rescheduleConfirmedAction = mutationSuccess;
export const saveInterviewScheduleAction = mutationSuccess;
export const searchApplicationOptionsAction = searchSuccess;
export const searchSubmissionOptionsAction = searchSuccess;

export async function createInterviewApplicationAction() {
  return { success: true as const, data: {} };
}

export async function getInterviewAssignmentOptionsAction() {
  return { success: true as const, data: null };
}
