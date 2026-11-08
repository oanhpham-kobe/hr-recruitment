import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

export type StorageCleanupProviderErrorCode =
  | "PROVIDER_TIMEOUT"
  | "TEMPORARY_FAILURE"
  | "PROVIDER_UNAVAILABLE";

export type StorageRemovalResult = {
  status: "REMOVED_OR_ABSENT" | "ABSENT";
};

export interface StorageCleanupProvider {
  removeObject(
    bucketName: string,
    objectPath: string,
  ): Promise<StorageRemovalResult>;
}

export class StorageCleanupProviderError extends Error {
  readonly code: StorageCleanupProviderErrorCode;
  readonly causeValue: unknown;

  constructor(
    code: StorageCleanupProviderErrorCode,
    message: string,
    causeValue?: unknown,
  ) {
    super(message);
    this.name = "StorageCleanupProviderError";
    this.code = code;
    this.causeValue = causeValue;
  }
}

type ErrorShape = {
  code?: unknown;
  errorCode?: unknown;
  name?: unknown;
  message?: unknown;
  status?: unknown;
  statusCode?: unknown;
};

function asErrorShape(value: unknown): ErrorShape {
  return value && typeof value === "object" ? (value as ErrorShape) : {};
}

function normalizedString(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function numericStatus(error: ErrorShape): number | null {
  const value = error.statusCode ?? error.status;
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && /^\d+$/.test(value)) {
    return Number(value);
  }
  return null;
}

/**
 * Treat only an authoritative exact-object absence signal as idempotent success.
 * Missing buckets, permission failures, malformed requests, and generic 404s are
 * deliberately not collapsed into absence.
 *
 * The disposable local Storage integration test is the authority for the
 * concrete response shape emitted by the project's current Supabase version.
 */
export function isAuthoritativeStorageAbsence(errorValue: unknown): boolean {
  const error = asErrorShape(errorValue);
  const code = normalizedString(error.code ?? error.errorCode ?? error.name);
  const message = normalizedString(error.message);
  const status = numericStatus(error);

  if (code === "nosuchbucket" || message.includes("bucket not found")) {
    return false;
  }

  if (
    code === "nosuchkey" ||
    code === "objectnotfound" ||
    code === "object_not_found"
  ) {
    return true;
  }

  const explicitlyObjectScoped = /(object|file|key)/.test(message);
  const explicitlyAbsent = /(not found|does not exist|already absent)/.test(
    message,
  );

  if (
    code === "not_found" &&
    explicitlyObjectScoped &&
    explicitlyAbsent &&
    !message.includes("bucket")
  ) {
    return true;
  }

  return (
    status === 404 &&
    explicitlyObjectScoped &&
    explicitlyAbsent &&
    !message.includes("bucket")
  );
}

export function mapStorageProviderErrorCode(
  errorValue: unknown,
): StorageCleanupProviderErrorCode {
  const error = asErrorShape(errorValue);
  const name = normalizedString(error.name);
  const code = normalizedString(error.code ?? error.errorCode);
  const message = normalizedString(error.message);
  const status = numericStatus(error);

  if (
    name === "aborterror" ||
    code === "etimedout" ||
    code === "timeout" ||
    message.includes("timed out") ||
    message.includes("timeout")
  ) {
    return "PROVIDER_TIMEOUT";
  }

  if (
    status === 429 ||
    (status !== null && status >= 500) ||
    code === "econnrefused" ||
    code === "econnreset" ||
    code === "service_unavailable" ||
    message.includes("service unavailable")
  ) {
    return "PROVIDER_UNAVAILABLE";
  }

  return "TEMPORARY_FAILURE";
}

export function createSupabaseStorageCleanupProvider(
  storageClient: SupabaseClient,
): StorageCleanupProvider {
  return {
    async removeObject(bucketName, objectPath) {
      if (!bucketName || !objectPath) {
        throw new StorageCleanupProviderError(
          "TEMPORARY_FAILURE",
          "Authorized storage identity must include bucket and object path",
        );
      }

      const { error } = await storageClient.storage
        .from(bucketName)
        .remove([objectPath]);

      if (!error) {
        // Supabase Storage may report an already-absent exact object as a
        // successful no-op. Either way, the desired physical end state holds.
        return { status: "REMOVED_OR_ABSENT" };
      }

      if (isAuthoritativeStorageAbsence(error)) {
        return { status: "ABSENT" };
      }

      const code = mapStorageProviderErrorCode(error);
      throw new StorageCleanupProviderError(
        code,
        `Storage cleanup provider failed: ${code}`,
        error,
      );
    },
  };
}
