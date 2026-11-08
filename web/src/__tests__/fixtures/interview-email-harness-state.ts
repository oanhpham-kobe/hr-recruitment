import type {
  EmailEnqueueInput,
  EmailHistoryEntry,
  EmailPreviewInput,
} from "@/lib/commands/email-commands";
import type { InterviewPageData } from "@/lib/interview/model";

export interface InterviewEmailHarnessState {
  pageData: InterviewPageData;
  previewCalls: EmailPreviewInput[];
  previewFingerprints: string[];
  enqueueCalls: Array<{
    request: EmailEnqueueInput;
    idempotencyKey: string;
  }>;
  bulkCalls: Array<{
    requests: EmailEnqueueInput[];
    idempotencyKey: string;
  }>;
  deleteCalls: Array<{
    emailHistoryId: string;
    classification: "TEST_RECORD" | "WRONG_RECORD";
    reason: string | null;
  }>;
  historyRows: EmailHistoryEntry[];
  failNextHistoryLoad: boolean;
  staleNextEnqueue: boolean;
  queuedNotices: number;
  interviewStatusMutations: number;
}

declare global {
  interface Window {
    __interviewEmailHarness?: InterviewEmailHarnessState;
  }
}

export function installInterviewEmailHarnessState(
  pageData: InterviewPageData,
  historyRows: EmailHistoryEntry[] = [],
): InterviewEmailHarnessState {
  const state: InterviewEmailHarnessState = {
    pageData,
    previewCalls: [],
    previewFingerprints: [],
    enqueueCalls: [],
    bulkCalls: [],
    deleteCalls: [],
    historyRows,
    failNextHistoryLoad: false,
    staleNextEnqueue: false,
    queuedNotices: 0,
    interviewStatusMutations: 0,
  };
  window.__interviewEmailHarness = state;
  return state;
}

export function interviewEmailHarnessState(): InterviewEmailHarnessState {
  const state = window.__interviewEmailHarness;
  if (!state)
    throw new Error("Interview email browser harness state is not installed");
  return state;
}
