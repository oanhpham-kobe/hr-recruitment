import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type AuthorizedStorageCleanupJob,
  type AuthorizeStorageCleanupAttemptInput,
  authorizeStorageCleanupAttempt,
  type ClaimedStorageCleanupJob,
  claimStorageCleanupJobs,
  completeStorageCleanupAttempt,
} from "@/lib/commands/storage-reservation";
import {
  type StorageCleanupProvider,
  StorageCleanupProviderError,
} from "@/lib/storage/storage-provider";

export type StorageCleanupCompletionResult = {
  status_code: string;
  replay?: boolean;
};

export interface StorageCleanupDbPort {
  claimJobs(
    workerId: string,
    limit: number,
    leaseSeconds: number,
  ): Promise<ClaimedStorageCleanupJob[]>;
  authorizeAttempt(
    input: AuthorizeStorageCleanupAttemptInput,
  ): Promise<AuthorizedStorageCleanupJob>;
  completeAttempt(
    input: AuthorizeStorageCleanupAttemptInput & {
      success: boolean;
      errorCode?: string | null;
    },
  ): Promise<StorageCleanupCompletionResult>;
}

export type StorageCleanupJobResult = {
  storageCleanupId: string;
  result:
    | "DONE"
    | "AUTHORIZATION_WITHHELD"
    | "RETRY_RECORDED"
    | "COMPLETION_REJECTED";
  errorCode?: string;
};

export type StorageCleanupBatchResult = {
  claimedCount: number;
  jobs: StorageCleanupJobResult[];
};

const WORKER_ID_REGEX = /^[A-Za-z0-9_.:-]{1,100}$/;

export function createStorageCleanupDbPort(
  workerClient: SupabaseClient,
): StorageCleanupDbPort {
  return {
    claimJobs(workerId, limit, leaseSeconds) {
      return claimStorageCleanupJobs(
        workerId,
        limit,
        leaseSeconds,
        workerClient,
      );
    },
    authorizeAttempt(input) {
      return authorizeStorageCleanupAttempt(input, workerClient);
    },
    completeAttempt(input) {
      return completeStorageCleanupAttempt(input, workerClient);
    },
  };
}

export function extractStorageCleanupFailureCode(errorValue: unknown): string {
  if (!(errorValue instanceof Error)) {
    return "UNKNOWN";
  }

  const match = /\berror:\s*([A-Z0-9_]+)\b/.exec(errorValue.message);
  return match?.[1] ?? "UNKNOWN";
}

function validateBatchInput(
  workerId: string,
  limit: number,
  leaseSeconds: number,
): void {
  if (!WORKER_ID_REGEX.test(workerId)) {
    throw new Error("Invalid storage cleanup workerId");
  }
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new Error(
      "Storage cleanup limit must be an integer between 1 and 100",
    );
  }
  if (
    !Number.isInteger(leaseSeconds) ||
    leaseSeconds < 30 ||
    leaseSeconds > 3600
  ) {
    throw new Error(
      "Storage cleanup leaseSeconds must be an integer between 30 and 3600",
    );
  }
}

/**
 * Runs one bounded cleanup batch.
 *
 * The runner intentionally has no API for callers to provide bucket/path.
 * Destructive targets are consumed exclusively from the accepted authorization
 * RPC result. Provider I/O happens only after that RPC has committed.
 */
export async function runStorageCleanupBatch(input: {
  workerId: string;
  db: StorageCleanupDbPort;
  provider: StorageCleanupProvider;
  limit?: number;
  leaseSeconds?: number;
}): Promise<StorageCleanupBatchResult> {
  const limit = input.limit ?? 10;
  const leaseSeconds = input.leaseSeconds ?? 300;
  validateBatchInput(input.workerId, limit, leaseSeconds);

  const claimed = await input.db.claimJobs(input.workerId, limit, leaseSeconds);
  const jobs: StorageCleanupJobResult[] = [];

  for (const job of claimed) {
    const attemptInput: AuthorizeStorageCleanupAttemptInput = {
      storageCleanupId: job.storage_cleanup_id,
      attemptId: job.attempt_id,
      fencingToken: job.fencing_token,
      workerId: input.workerId,
    };

    let authorized: AuthorizedStorageCleanupJob;
    try {
      authorized = await input.db.authorizeAttempt(attemptInput);
    } catch (error) {
      jobs.push({
        storageCleanupId: job.storage_cleanup_id,
        result: "AUTHORIZATION_WITHHELD",
        errorCode: extractStorageCleanupFailureCode(error),
      });
      continue;
    }

    try {
      await input.provider.removeObject(
        authorized.bucket_name,
        authorized.object_path,
      );
    } catch (error) {
      const providerCode =
        error instanceof StorageCleanupProviderError
          ? error.code
          : "TEMPORARY_FAILURE";

      try {
        await input.db.completeAttempt({
          ...attemptInput,
          success: false,
          errorCode: providerCode,
        });
        jobs.push({
          storageCleanupId: job.storage_cleanup_id,
          result: "RETRY_RECORDED",
          errorCode: providerCode,
        });
      } catch (completionError) {
        jobs.push({
          storageCleanupId: job.storage_cleanup_id,
          result: "COMPLETION_REJECTED",
          errorCode: extractStorageCleanupFailureCode(completionError),
        });
      }
      continue;
    }

    try {
      await input.db.completeAttempt({
        ...attemptInput,
        success: true,
        errorCode: null,
      });
      jobs.push({
        storageCleanupId: job.storage_cleanup_id,
        result: "DONE",
      });
    } catch (error) {
      // A stale/expired attempt can reach this branch if the lease changes while
      // provider I/O is in flight. The DB fencing contract is authoritative;
      // the runner must not retry completion with altered attempt identity.
      jobs.push({
        storageCleanupId: job.storage_cleanup_id,
        result: "COMPLETION_REJECTED",
        errorCode: extractStorageCleanupFailureCode(error),
      });
    }
  }

  return { claimedCount: claimed.length, jobs };
}
