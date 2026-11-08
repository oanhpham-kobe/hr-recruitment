import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  bulkEnqueueInterviewEmails,
  deleteEmailHistoryEntry,
  type EmailEnqueueInput,
  enqueueInterviewEmail,
  loadInterviewEmailHistory,
  previewInterviewEmail,
} from "@/lib/commands/email-commands";

const interviewId = "10000000-0000-0000-0000-000000000001";
const applicationId = "20000000-0000-0000-0000-000000000001";
const submissionId = "30000000-0000-0000-0000-000000000001";
const historyId = "40000000-0000-0000-0000-000000000001";
const idempotencyKey = "50000000-0000-0000-0000-000000000001";
const previewFingerprint = "a".repeat(64);

function rpcClient(handlers: Record<string, (args: unknown) => unknown>): {
  client: SupabaseClient;
  calls: Array<{ fn: string; args: unknown }>;
} {
  const calls: Array<{ fn: string; args: unknown }> = [];
  return {
    client: {
      rpc: async (fn: string, args?: unknown) => {
        calls.push({ fn, args });
        return { data: handlers[fn]?.(args) ?? null, error: null };
      },
    } as unknown as SupabaseClient,
    calls,
  };
}

function historyClient(rows: unknown[]) {
  const calls: Array<{ method: string; value: unknown }> = [];
  const query = {
    select(value: string) {
      calls.push({ method: "select", value });
      return this;
    },
    eq(column: string, value: string) {
      calls.push({ method: "eq", value: { column, value } });
      return this;
    },
    async order(column: string, options: unknown) {
      calls.push({ method: "order", value: { column, options } });
      return { data: rows, error: null };
    },
  };
  const client = {
    from(table: string) {
      calls.push({ method: "from", value: table });
      return query;
    },
  } as unknown as SupabaseClient;
  return { client, calls };
}

function enqueueRequest(
  emailType: EmailEnqueueInput["email_type"] = "INTERVIEW_INVITATION",
): EmailEnqueueInput {
  return {
    email_type: emailType,
    interview_id: interviewId,
    application_id: applicationId,
    submission_id: submissionId,
    preview_fingerprint: previewFingerprint,
  };
}

test("previewInterviewEmail sends the exact accepted four RPC parameters and returns preview_fingerprint", async () => {
  const { client, calls } = rpcClient({
    preview_email: () => ({
      success: true,
      data: {
        recipients: { to: ["candidate@example.com"], cc: [] },
        subject: "Interview invitation",
        body_text: "Rendered by server",
        template_version: "test-1",
        environment_code: "TEST",
        context_fingerprint: "b".repeat(64),
        preview_fingerprint: previewFingerprint,
        email_type: "INTERVIEW_INVITATION",
        interview_id: interviewId,
        application_id: applicationId,
        submission_id: submissionId,
      },
    }),
  });

  const result = await previewInterviewEmail(
    {
      emailType: "INTERVIEW_INVITATION",
      interviewId,
      applicationId,
      submissionId,
    },
    { client },
  );

  assert.equal(result.success, true);
  if (result.success)
    assert.equal(result.data.preview_fingerprint, previewFingerprint);
  assert.deepEqual(calls, [
    {
      fn: "preview_email",
      args: {
        p_email_type: "INTERVIEW_INVITATION",
        p_interview_id: interviewId,
        p_application_id: applicationId,
        p_submission_id: submissionId,
      },
    },
  ]);
});

test("email command adapters preserve backend FORBIDDEN and never fabricate UNAUTHENTICATED", async () => {
  const preview = rpcClient({
    preview_email: () => ({ success: false, error_code: "FORBIDDEN" }),
  });
  const previewResult = await previewInterviewEmail(
    {
      emailType: "INTERVIEW_INVITATION",
      interviewId,
      applicationId,
      submissionId,
    },
    { client: preview.client },
  );
  assert.equal(previewResult.success, false);
  if (!previewResult.success) {
    assert.equal(previewResult.error.code, "FORBIDDEN");
    assert.notEqual(previewResult.error.code, "UNAUTHENTICATED");
  }

  const enqueue = rpcClient({
    enqueue_email: () => ({ success: false, error_code: "FORBIDDEN" }),
  });
  const enqueueResult = await enqueueInterviewEmail(
    enqueueRequest(),
    idempotencyKey,
    { client: enqueue.client },
  );
  assert.equal(enqueueResult.success, false);
  if (!enqueueResult.success)
    assert.equal(enqueueResult.error.code, "FORBIDDEN");

  const bulk = rpcClient({
    bulk_enqueue_email: () => ({ success: false, error_code: "FORBIDDEN" }),
  });
  const bulkResult = await bulkEnqueueInterviewEmails(
    [enqueueRequest()],
    idempotencyKey,
    { client: bulk.client },
  );
  assert.equal(bulkResult.success, false);
  if (!bulkResult.success) assert.equal(bulkResult.error.code, "FORBIDDEN");

  const historyDelete = rpcClient({
    delete_email_history: () => ({ success: false, error_code: "FORBIDDEN" }),
  });
  const deleteResult = await deleteEmailHistoryEntry(
    historyId,
    "WRONG_RECORD",
    "Wrong record",
    { client: historyDelete.client },
  );
  assert.equal(deleteResult.success, false);
  if (!deleteResult.success) assert.equal(deleteResult.error.code, "FORBIDDEN");
});

test("enqueueInterviewEmail sends exactly the five-key request and idempotency key", async () => {
  const { client, calls } = rpcClient({
    enqueue_email: () => ({
      success: true,
      data: { email_outbox_id: "60000000-0000-0000-0000-000000000001" },
    }),
  });
  const request = enqueueRequest();
  const result = await enqueueInterviewEmail(request, idempotencyKey, {
    client,
  });

  assert.equal(result.success, true);
  assert.deepEqual(calls, [
    {
      fn: "enqueue_email",
      args: {
        p_request: {
          email_type: "INTERVIEW_INVITATION",
          interview_id: interviewId,
          application_id: applicationId,
          submission_id: submissionId,
          preview_fingerprint: previewFingerprint,
        },
        p_idempotency_key: idempotencyKey,
      },
    },
  ]);
  const enqueueCall = calls[0];
  assert.ok(enqueueCall);
  const sentRequest = (
    enqueueCall.args as { p_request: Record<string, unknown> }
  ).p_request;
  assert.deepEqual(Object.keys(sentRequest).sort(), [
    "application_id",
    "email_type",
    "interview_id",
    "preview_fingerprint",
    "submission_id",
  ]);
});

test("enqueueInterviewEmail surfaces STALE_PREVIEW as the accepted structured error", async () => {
  const { client } = rpcClient({
    enqueue_email: () => ({ success: false, error_code: "STALE_PREVIEW" }),
  });
  const result = await enqueueInterviewEmail(enqueueRequest(), idempotencyKey, {
    client,
  });
  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, "STALE_PREVIEW");
    assert.match(result.error.message, /xem lại bản xem trước/i);
  }
});

test("bulkEnqueueInterviewEmails sends 1..100 complete requests and parses the direct per-item result", async () => {
  const requests = [
    enqueueRequest("INTERVIEW_INVITATION"),
    enqueueRequest("INTERVIEW_PARTICIPANT_INVITATION"),
  ];
  const { client, calls } = rpcClient({
    bulk_enqueue_email: () => ({
      success: [
        {
          id: interviewId,
          email_type: "INTERVIEW_INVITATION",
          application_id: applicationId,
          submission_id: submissionId,
          email_outbox_id: "60000000-0000-0000-0000-000000000001",
        },
      ],
      failed: [],
    }),
  });
  const result = await bulkEnqueueInterviewEmails(requests, idempotencyKey, {
    client,
  });
  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.success[0]?.id, interviewId);
    assert.equal(
      result.data.success[0]?.email_outbox_id,
      "60000000-0000-0000-0000-000000000001",
    );
    assert.deepEqual(result.data.failed, []);
  }
  assert.deepEqual(calls, [
    {
      fn: "bulk_enqueue_email",
      args: {
        p_requests: requests,
        p_idempotency_key: idempotencyKey,
      },
    },
  ]);

  const invalid = await bulkEnqueueInterviewEmails([], idempotencyKey, {
    client,
  });
  assert.equal(invalid.success, false);
  assert.equal(calls.length, 1);
});

test("deleteEmailHistoryEntry validates classification/reason and passes accepted RPC arguments", async () => {
  const { client, calls } = rpcClient({
    delete_email_history: () => ({
      success: true,
      data: { email_history_id: historyId },
    }),
  });

  const missingReason = await deleteEmailHistoryEntry(
    historyId,
    "WRONG_RECORD",
    "   ",
    { client },
  );
  assert.equal(missingReason.success, false);
  assert.equal(calls.length, 0);

  const tooLong = await deleteEmailHistoryEntry(
    historyId,
    "WRONG_RECORD",
    "x".repeat(1001),
    { client },
  );
  assert.equal(tooLong.success, false);
  assert.equal(calls.length, 0);

  const result = await deleteEmailHistoryEntry(
    historyId,
    "WRONG_RECORD",
    "  Duplicate operational record  ",
    { client },
  );
  assert.equal(result.success, true);
  assert.deepEqual(calls, [
    {
      fn: "delete_email_history",
      args: {
        p_email_history_id: historyId,
        p_classification: "WRONG_RECORD",
        p_reason: "Duplicate operational record",
      },
    },
  ]);
});

test("loadInterviewEmailHistory scopes by interview and accepts only completed history statuses", async () => {
  const base = {
    email_history_id: historyId,
    interview_id: interviewId,
    email_type: "INTERVIEW_INVITATION",
    environment_code: "TEST",
    recipients: { to: ["candidate@example.com"], cc: [] },
    subject: "Interview invitation",
    template_version: "test-1",
    sent_at: "2026-09-16T10:00:00.000Z",
    created_at: "2026-09-16T10:00:00.000Z",
    error_code: null,
  };
  const { client, calls } = historyClient([
    { ...base, status_code: "SENT" },
    {
      ...base,
      email_history_id: "40000000-0000-0000-0000-000000000002",
      status_code: "FAILED",
      error_code: "PROVIDER_ERROR",
    },
    {
      ...base,
      email_history_id: "40000000-0000-0000-0000-000000000003",
      status_code: "CANCELLED",
    },
    {
      ...base,
      email_history_id: "40000000-0000-0000-0000-000000000004",
      status_code: "ABANDONED",
    },
  ]);
  const result = await loadInterviewEmailHistory(interviewId, { client });
  assert.equal(result.success, true);
  assert.deepEqual(
    result.success ? result.data.map((row) => row.status_code) : [],
    ["SENT", "FAILED", "CANCELLED", "ABANDONED"],
  );
  assert.equal(calls[0]?.value, "email_history");
  assert.deepEqual(calls[2]?.value, {
    column: "interview_id",
    value: interviewId,
  });

  const queuedClient = historyClient([{ ...base, status_code: "QUEUED" }]);
  const queued = await loadInterviewEmailHistory(interviewId, {
    client: queuedClient.client,
  });
  assert.equal(queued.success, false);
  if (!queued.success) assert.equal(queued.error.code, "INTERNAL_ERROR");
});
