import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  AuthorizedStorageCleanupJob,
  AuthorizeStorageCleanupAttemptInput,
  ClaimedStorageCleanupJob,
} from "@/lib/commands/storage-reservation";
import {
  extractStorageCleanupFailureCode,
  runStorageCleanupBatch,
  type StorageCleanupDbPort,
} from "@/lib/storage/cleanup-runner";
import {
  createSupabaseStorageCleanupProvider,
  isAuthoritativeStorageAbsence,
  type StorageCleanupProvider,
  StorageCleanupProviderError,
} from "@/lib/storage/storage-provider";

function claimedJob(id: string, path: string): ClaimedStorageCleanupJob {
  return {
    storage_cleanup_id: id,
    source_type: "CANDIDATE_FORM",
    bucket_name: "candidate-quarantine",
    object_path: path,
    reason_code: "RESERVATION_EXPIRED",
    attempts: 1,
    not_before: "2026-09-16T00:00:00.000Z",
    leased_until: "2026-09-16T00:05:00.000Z",
    attempt_id: `attempt-${id}`,
    fencing_token: `token-${id}`,
  };
}

function authorizedJob(
  job: ClaimedStorageCleanupJob,
): AuthorizedStorageCleanupJob {
  return {
    storage_cleanup_id: job.storage_cleanup_id,
    bucket_name: job.bucket_name,
    object_path: job.object_path,
    reason_code: job.reason_code,
    attempt_id: job.attempt_id,
    fencing_token: job.fencing_token,
    leased_until: job.leased_until,
  };
}

function createDbPort(options: {
  claimed: ClaimedStorageCleanupJob[];
  authorize?: (
    input: AuthorizeStorageCleanupAttemptInput,
  ) => Promise<AuthorizedStorageCleanupJob>;
  complete?: (
    input: AuthorizeStorageCleanupAttemptInput & {
      success: boolean;
      errorCode?: string | null;
    },
  ) => Promise<{ status_code: string; replay?: boolean }>;
}) {
  const completionInputs: Array<
    AuthorizeStorageCleanupAttemptInput & {
      success: boolean;
      errorCode?: string | null;
    }
  > = [];

  const port: StorageCleanupDbPort = {
    async claimJobs() {
      return options.claimed;
    },
    async authorizeAttempt(input) {
      if (options.authorize) {
        return options.authorize(input);
      }
      const job = options.claimed.find(
        (item) => item.storage_cleanup_id === input.storageCleanupId,
      );
      assert.ok(job);
      return authorizedJob(job);
    },
    async completeAttempt(input) {
      completionInputs.push(input);
      if (options.complete) {
        return options.complete(input);
      }
      return { status_code: input.success ? "DONE" : "PENDING" };
    },
  };

  return { port, completionInputs };
}

test("runner skips denied first job and continues with exact authorized target", async () => {
  const first = claimedJob(
    "11111111-1111-1111-1111-111111111111",
    "candidate/11111111-1111-1111-1111-111111111111/old.pdf",
  );
  const second = claimedJob(
    "22222222-2222-2222-2222-222222222222",
    "candidate/22222222-2222-2222-2222-222222222222/resume.pdf",
  );
  const { port, completionInputs } = createDbPort({
    claimed: [first, second],
    async authorize(input) {
      if (input.storageCleanupId === first.storage_cleanup_id) {
        throw new Error(
          "authorize_storage_cleanup_attempt error: CLEANUP_WITHHELD",
        );
      }
      return authorizedJob(second);
    },
  });
  const providerCalls: Array<[string, string]> = [];
  const provider: StorageCleanupProvider = {
    async removeObject(bucket, path) {
      providerCalls.push([bucket, path]);
      return { status: "REMOVED_OR_ABSENT" };
    },
  };

  const result = await runStorageCleanupBatch({
    workerId: "cleanup-worker-1",
    db: port,
    provider,
    limit: 2,
    leaseSeconds: 300,
  });

  assert.equal(result.claimedCount, 2);
  assert.deepEqual(result.jobs, [
    {
      storageCleanupId: first.storage_cleanup_id,
      result: "AUTHORIZATION_WITHHELD",
      errorCode: "CLEANUP_WITHHELD",
    },
    { storageCleanupId: second.storage_cleanup_id, result: "DONE" },
  ]);
  assert.deepEqual(providerCalls, [[second.bucket_name, second.object_path]]);
  assert.equal(completionInputs.length, 1);
  assert.equal(
    completionInputs[0]?.storageCleanupId,
    second.storage_cleanup_id,
  );
  assert.equal(completionInputs[0]?.success, true);
});

test("provider failure is reported through the same fenced attempt", async () => {
  const job = claimedJob(
    "33333333-3333-3333-3333-333333333333",
    "candidate/33333333-3333-3333-3333-333333333333/resume.pdf",
  );
  const { port, completionInputs } = createDbPort({ claimed: [job] });
  const provider: StorageCleanupProvider = {
    async removeObject() {
      throw new StorageCleanupProviderError(
        "PROVIDER_TIMEOUT",
        "simulated timeout",
      );
    },
  };

  const result = await runStorageCleanupBatch({
    workerId: "cleanup-worker-2",
    db: port,
    provider,
  });

  assert.deepEqual(result.jobs, [
    {
      storageCleanupId: job.storage_cleanup_id,
      result: "RETRY_RECORDED",
      errorCode: "PROVIDER_TIMEOUT",
    },
  ]);
  assert.equal(completionInputs.length, 1);
  assert.equal(completionInputs[0]?.attemptId, job.attempt_id);
  assert.equal(completionInputs[0]?.fencingToken, job.fencing_token);
  assert.equal(completionInputs[0]?.success, false);
  assert.equal(completionInputs[0]?.errorCode, "PROVIDER_TIMEOUT");
});

test("stale completion after provider success is not retried with altered identity", async () => {
  const job = claimedJob(
    "44444444-4444-4444-4444-444444444444",
    "candidate/44444444-4444-4444-4444-444444444444/resume.pdf",
  );
  let providerCalls = 0;
  const { port, completionInputs } = createDbPort({
    claimed: [job],
    async complete() {
      throw new Error("complete_storage_cleanup_attempt error: STALE_ATTEMPT");
    },
  });

  const result = await runStorageCleanupBatch({
    workerId: "cleanup-worker-3",
    db: port,
    provider: {
      async removeObject() {
        providerCalls += 1;
        return { status: "REMOVED_OR_ABSENT" };
      },
    },
  });

  assert.equal(providerCalls, 1);
  assert.equal(completionInputs.length, 1);
  assert.deepEqual(result.jobs, [
    {
      storageCleanupId: job.storage_cleanup_id,
      result: "COMPLETION_REJECTED",
      errorCode: "STALE_ATTEMPT",
    },
  ]);
});

test("runner validates the accepted claim bounds before DB work", async () => {
  let claimCalls = 0;
  const db: StorageCleanupDbPort = {
    async claimJobs() {
      claimCalls += 1;
      return [];
    },
    async authorizeAttempt() {
      throw new Error("unexpected authorize");
    },
    async completeAttempt() {
      throw new Error("unexpected complete");
    },
  };

  await assert.rejects(
    runStorageCleanupBatch({
      workerId: "bad worker id",
      db,
      provider: {
        async removeObject() {
          return { status: "REMOVED_OR_ABSENT" };
        },
      },
    }),
    /Invalid storage cleanup workerId/,
  );
  await assert.rejects(
    runStorageCleanupBatch({
      workerId: "worker-ok",
      db,
      provider: {
        async removeObject() {
          return { status: "REMOVED_OR_ABSENT" };
        },
      },
      limit: 101,
    }),
    /limit must be an integer between 1 and 100/,
  );
  await assert.rejects(
    runStorageCleanupBatch({
      workerId: "worker-ok",
      db,
      provider: {
        async removeObject() {
          return { status: "REMOVED_OR_ABSENT" };
        },
      },
      leaseSeconds: 29,
    }),
    /leaseSeconds must be an integer between 30 and 3600/,
  );
  assert.equal(claimCalls, 0);
});

test("failure code extraction is bounded to the accepted adapter envelope", () => {
  assert.equal(
    extractStorageCleanupFailureCode(
      new Error("authorize_storage_cleanup_attempt error: STALE_ATTEMPT"),
    ),
    "STALE_ATTEMPT",
  );
  assert.equal(extractStorageCleanupFailureCode(new Error("boom")), "UNKNOWN");
});

test("absence classifier accepts object absence but rejects missing bucket", () => {
  assert.equal(
    isAuthoritativeStorageAbsence({
      statusCode: "404",
      code: "NoSuchKey",
      message: "Object not found",
    }),
    true,
  );
  assert.equal(
    isAuthoritativeStorageAbsence({
      statusCode: 404,
      code: "NoSuchBucket",
      message: "Bucket not found",
    }),
    false,
  );
  assert.equal(
    isAuthoritativeStorageAbsence({
      statusCode: 404,
      code: "not_found",
      message: "request not found",
    }),
    false,
  );
});

test("Supabase provider treats success/authoritative absence as terminal and maps outages", async () => {
  const calls: Array<[string, string[]]> = [];
  const responses: Array<{ error: unknown }> = [
    { error: null },
    {
      error: {
        statusCode: "404",
        code: "NoSuchKey",
        message: "Object not found",
      },
    },
    {
      error: {
        statusCode: "503",
        code: "service_unavailable",
        message: "Service unavailable",
      },
    },
  ];
  const client = {
    storage: {
      from(bucket: string) {
        return {
          async remove(paths: string[]) {
            calls.push([bucket, paths]);
            return responses.shift() ?? { error: null };
          },
        };
      },
    },
  } as unknown as SupabaseClient;
  const provider = createSupabaseStorageCleanupProvider(client);

  assert.deepEqual(
    await provider.removeObject("candidate-quarantine", "candidate/a/file.pdf"),
    { status: "REMOVED_OR_ABSENT" },
  );
  assert.deepEqual(
    await provider.removeObject("candidate-quarantine", "candidate/b/file.pdf"),
    { status: "ABSENT" },
  );
  await assert.rejects(
    provider.removeObject("interview-quarantine", "interview/c/file.pdf"),
    (error: unknown) =>
      error instanceof StorageCleanupProviderError &&
      error.code === "PROVIDER_UNAVAILABLE",
  );

  assert.deepEqual(calls, [
    ["candidate-quarantine", ["candidate/a/file.pdf"]],
    ["candidate-quarantine", ["candidate/b/file.pdf"]],
    ["interview-quarantine", ["interview/c/file.pdf"]],
  ]);
});
