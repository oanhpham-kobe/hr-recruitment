import { detectUploadMimeType } from "../../../web/src/lib/storage/content-signature";
import {
  DRIVE_MAX_BYTES,
  DriveError,
  type DriveGrant,
  readBounded,
  sha256,
  verifyDriveGrant,
} from "../../../web/src/lib/storage/drive-protocol";
import {
  authenticate,
  boundedFetch,
  configured,
  type Env,
  type Fetcher,
  GoogleDrive,
  googleToken,
  type Location,
  rpc,
} from "./runtime";

type Lease = {
  provider_file_id: string;
  fencing_token: string;
  leased_until: string;
  write_deadline: string;
};
type Attempt = {
  attempt_id: string;
  fencing_token: string;
  document_scan_request_id: string;
  storage_cleanup_id: string;
};
function actorArgs(grant: DriveGrant) {
  return { p_actor_auth_user_id: grant.actor };
}
async function upload(
  request: Request,
  grant: Extract<DriveGrant, { purpose: "upload" }>,
  env: Env,
  fetcher: Fetcher,
): Promise<Response> {
  const bytes = await readBounded(
    request.body,
    Math.min(grant.maxBytes, DRIVE_MAX_BYTES),
  );
  const mime = detectUploadMimeType(bytes);
  if (!mime || mime !== grant.mimeType)
    throw new DriveError("INVALID_CONTENT_SIGNATURE", 415);
  const checksum = await sha256(bytes);
  const worker = crypto.randomUUID();
  const args = {
    ...actorArgs(grant),
    p_upload_reservation_id: grant.reservationId,
  };
  const claim = () =>
    rpc<Lease>(
      env,
      env.DRIVE_WORKER_TOKEN,
      "claim_drive_upload_attempt",
      { ...args, p_worker_id: worker, p_lease_seconds: 120 },
      fetcher,
    );
  const drive = new GoogleDrive(env, await googleToken(env, fetcher), fetcher);
  let lease: Lease;
  try {
    lease = await claim();
  } catch (error) {
    if (error instanceof DriveError && error.code === "ALREADY_SEALED") {
      // Claim already rechecked the current candidate/session. Never trust the
      // browser's completion flag or route an existing binding to Supabase.
      const location = await rpc<Location>(
        env,
        env.DRIVE_WORKER_TOKEN,
        "resolve_drive_object_location",
        { p_bucket_name: grant.bucket, p_object_path: grant.path },
        fetcher,
      );
      if (
        location?.state_code !== "SEALED" ||
        location.checksum_sha256 !== checksum ||
        Number(location.actual_size_bytes) !== bytes.length
      )
        throw new DriveError("FINGERPRINT_MISMATCH", 409);
      await drive.verified(location);
      return Response.json({
        status: "SEALED",
        malwareScanStatus: "PENDING",
        replay: true,
      });
    }
    if (!(error instanceof DriveError) || error.code !== "NOT_FOUND")
      throw error;
    const id = await drive.generateId();
    try {
      await rpc(
        env,
        env.DRIVE_WORKER_TOKEN,
        "bind_candidate_drive_object",
        { ...args, p_provider_file_id: id },
        fetcher,
      );
    } catch (bindError) {
      if (
        !(bindError instanceof DriveError) ||
        bindError.code !== "IDEMPOTENCY_CONFLICT"
      )
        throw bindError;
    }
    lease = await claim();
  }
  const deadline = Math.min(
    Date.parse(lease.write_deadline),
    Date.parse(lease.leased_until),
  );
  if (!Number.isFinite(deadline) || deadline <= Date.now())
    throw new DriveError("WRITE_DEADLINE", 409);
  // CREATE only, including retries. A response loss/conflict is reconciled by
  // reading the same permanent ID; no new ID or content replacement is allowed.
  try {
    await drive.create(lease.provider_file_id, bytes, mime, deadline);
  } catch {
    /* exact byte reconciliation below determines the outcome */
  }
  await drive.verified({
    provider_file_id: lease.provider_file_id,
    actual_size_bytes: bytes.length,
    checksum_sha256: checksum,
  });
  await rpc(
    env,
    env.DRIVE_WORKER_TOKEN,
    "seal_drive_upload_attempt",
    {
      ...args,
      p_worker_id: worker,
      p_fencing_token: lease.fencing_token,
      p_actual_size_bytes: bytes.length,
      p_detected_mime_type: mime,
      p_checksum_sha256: checksum,
      p_magic_bytes_verified: true,
    },
    fetcher,
  );
  return Response.json({ status: "SEALED", malwareScanStatus: "PENDING" });
}
export function byteResponse(
  bytes: Uint8Array,
  mime: string,
  filename: string,
  purpose: "preview" | "download",
  range: string | null,
): Response {
  const headers = new Headers({
    "Content-Type": mime,
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
    "Accept-Ranges": "bytes",
    "Content-Security-Policy": "default-src 'none'; sandbox",
    "Referrer-Policy": "no-referrer",
  });
  const name =
    Array.from(filename, (char) =>
      char.charCodeAt(0) < 32 ||
      char.charCodeAt(0) === 127 ||
      char === "/" ||
      char === "\\"
        ? "_"
        : char,
    )
      .join("")
      .slice(0, 200) || "document";
  headers.set(
    "Content-Disposition",
    `${purpose === "preview" ? "inline" : "attachment"}; filename="document"; filename*=UTF-8''${encodeURIComponent(name).replaceAll("'", "%27")}`,
  );
  let start = 0;
  let end = bytes.length - 1;
  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!match || (!match[1] && !match[2])) {
      headers.set("Content-Range", `bytes */${bytes.length}`);
      return new Response(null, { status: 416, headers });
    }
    if (!match[1]) start = Math.max(0, bytes.length - Number(match[2]));
    else {
      start = Number(match[1]);
      if (match[2]) end = Math.min(end, Number(match[2]));
    }
    if (
      !Number.isSafeInteger(start) ||
      !Number.isSafeInteger(end) ||
      start > end ||
      start >= bytes.length
    ) {
      headers.set("Content-Range", `bytes */${bytes.length}`);
      return new Response(null, { status: 416, headers });
    }
    headers.set("Content-Range", `bytes ${start}-${end}/${bytes.length}`);
  }
  headers.set("Content-Length", String(end - start + 1));
  return new Response(Uint8Array.from(bytes.subarray(start, end + 1)), {
    status: range ? 206 : 200,
    headers,
  });
}
export async function handleRequest(
  request: Request,
  env: Env,
  fetcher: Fetcher = fetch,
): Promise<Response> {
  const origin = request.headers.get("Origin");
  let response: Response;
  try {
    configured(env);
    const url = new URL(request.url);
    if (
      origin !== env.APP_ORIGIN ||
      url.origin !== env.GATEWAY_ORIGIN ||
      url.search ||
      url.pathname !== "/bytes"
    )
      throw new DriveError("FORBIDDEN", 403);
    if (request.method === "OPTIONS")
      response = new Response(null, { status: 204 });
    else {
      const grant = await verifyDriveGrant(
        request.headers.get("X-Document-Grant") ?? "",
        env.DRIVE_GRANT_SECRET,
        env.GATEWAY_ORIGIN,
        env.APP_ORIGIN,
      );
      const actor = await authenticate(request, env, fetcher);
      if (actor !== grant.actor) throw new DriveError("ACTOR_MISMATCH", 403);
      if (grant.purpose === "upload") {
        if (request.method !== "PUT")
          throw new DriveError("PURPOSE_MISMATCH", 403);
        response = await upload(request, grant, env, fetcher);
      } else {
        if (request.method !== "GET")
          throw new DriveError("PURPOSE_MISMATCH", 403);
        const location = await rpc<Location>(
          env,
          env.DRIVE_WORKER_TOKEN,
          "authorize_drive_document_read",
          {
            ...actorArgs(grant),
            p_submission_id: grant.submissionId,
            p_logical_document_id: grant.logicalDocumentId,
            p_document_id: grant.documentId,
            p_purpose: grant.purpose,
          },
          fetcher,
        );
        if (
          location.mime_type !== grant.mimeType ||
          location.original_filename !== grant.filename ||
          (grant.purpose === "preview" &&
            !["application/pdf", "image/png", "image/jpeg"].includes(
              grant.mimeType,
            ))
        )
          throw new DriveError("DOCUMENT_CHANGED", 409);
        const drive = new GoogleDrive(
          env,
          await googleToken(env, fetcher),
          fetcher,
        );
        const bytes = await drive.verified(location);
        response = byteResponse(
          bytes,
          grant.mimeType,
          grant.filename,
          grant.purpose,
          request.headers.get("Range"),
        );
      }
    }
  } catch (error) {
    response = Response.json(
      {
        error: error instanceof DriveError ? error.code : "GATEWAY_UNAVAILABLE",
      },
      { status: error instanceof DriveError ? error.status : 503 },
    );
  }
  response.headers.set("Cache-Control", "private, no-store");
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("Vary", "Origin");
  if (origin === env.APP_ORIGIN) {
    response.headers.set("Access-Control-Allow-Origin", origin);
    response.headers.set("Access-Control-Allow-Methods", "GET, PUT, OPTIONS");
    response.headers.set(
      "Access-Control-Allow-Headers",
      "Authorization, X-Document-Grant, Content-Type, Range",
    );
    response.headers.set(
      "Access-Control-Expose-Headers",
      "Content-Type, Content-Disposition, Content-Length, Content-Range",
    );
  }
  return response;
}
/** Background jobs that live in the web app (it holds their credentials). */
const APP_CRON_PATHS = ["/api/cron/storage-cleanup"];
export async function runScheduled(
  env: Env,
  fetcher: Fetcher = fetch,
): Promise<void> {
  configured(env);
  // Started first and awaited last: app jobs must not wait for, or be skipped
  // by, Drive work. A failed ping is simply retried by the next tick.
  const appJobs = Promise.allSettled(
    APP_CRON_PATHS.map((path) =>
      boundedFetch(
        fetcher,
        `${env.APP_ORIGIN}${path}`,
        {
          method: "POST",
          headers: { Authorization: `Bearer ${env.CRON_SECRET}` },
        },
        async (response) => {
          await response.body?.cancel();
        },
        25_000,
      ),
    ),
  );
  try {
    await runDriveJobs(env, fetcher);
  } finally {
    await appJobs;
  }
}
async function runDriveJobs(env: Env, fetcher: Fetcher): Promise<void> {
  if (env.DRIVE_SCHEDULES_VERIFIED !== "true")
    throw new DriveError("SCHEDULES_NOT_CONFIGURED");
  const worker = crypto.randomUUID();
  const drive = new GoogleDrive(env, await googleToken(env, fetcher), fetcher);
  const scans = await rpc<Attempt[]>(
    env,
    env.SCAN_WORKER_TOKEN,
    "claim_drive_document_scan_requests",
    { p_worker_id: worker, p_limit: 5, p_lease_seconds: 300 },
    fetcher,
  );
  for (const attempt of scans) {
    const args = {
      p_document_scan_request_id: attempt.document_scan_request_id,
      p_attempt_id: attempt.attempt_id,
      p_fencing_token: attempt.fencing_token,
      p_worker_id: worker,
    };
    let outcome = "ERROR";
    try {
      const location = await rpc<Location>(
        env,
        env.SCAN_WORKER_TOKEN,
        "resolve_drive_scan_attempt",
        args,
        fetcher,
      );
      // Verdict source is Drive's own malware scan (spec 102): it serves a
      // file only if it has not flagged it. CLEAN additionally requires the
      // served bytes to match the sealed size and SHA-256.
      await drive.verified(location);
      outcome = "CLEAN";
    } catch (error) {
      // Anything else (changed bytes, outage, lost access) stays ERROR.
      if (error instanceof DriveError && error.code === "DRIVE_FLAGGED_ABUSIVE")
        outcome = "INFECTED";
    }
    try {
      await rpc(
        env,
        env.SCAN_WORKER_TOKEN,
        "complete_document_scan_attempt",
        {
          ...args,
          p_outcome: outcome,
          p_error_code: outcome === "ERROR" ? "PROVIDER_UNAVAILABLE" : null,
        },
        fetcher,
      );
    } catch {
      /* fencing is final */
    }
  }
  await rpc(
    env,
    env.CLEANUP_WORKER_TOKEN,
    "discover_expired_storage_cleanup",
    { p_limit: 10 },
    fetcher,
  );
  const cleanup = await rpc<Attempt[]>(
    env,
    env.CLEANUP_WORKER_TOKEN,
    "claim_drive_storage_cleanup_jobs",
    { p_worker_id: worker, p_limit: 5, p_lease_seconds: 300 },
    fetcher,
  );
  for (const attempt of cleanup) {
    const args = {
      p_storage_cleanup_id: attempt.storage_cleanup_id,
      p_attempt_id: attempt.attempt_id,
      p_fencing_token: attempt.fencing_token,
      p_worker_id: worker,
    };
    let success = false;
    try {
      const target = await rpc<{ location: Location | null }>(
        env,
        env.CLEANUP_WORKER_TOKEN,
        "resolve_drive_cleanup_location",
        args,
        fetcher,
      );
      // This runner never guesses a provider for an unbound legacy identity.
      if (!target.location) throw new DriveError("LEGACY_PROVIDER_REQUIRED");
      await drive.remove(target.location.provider_file_id);
      success = true;
    } catch {
      /* Unknown absence is retryable, never successful. */
    }
    try {
      await rpc(
        env,
        env.CLEANUP_WORKER_TOKEN,
        "complete_storage_cleanup_attempt",
        {
          ...args,
          p_success: success,
          p_error_code: success ? null : "PROVIDER_UNAVAILABLE",
        },
        fetcher,
      );
    } catch {
      /* fencing is final */
    }
  }
}
export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
  async scheduled(_event: unknown, env: Env): Promise<void> {
    await runScheduled(env);
  },
};
