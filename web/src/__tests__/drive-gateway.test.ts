import assert from "node:assert/strict";
import { test } from "node:test";
import {
  byteResponse,
  handleRequest,
  runScheduled,
} from "../../../workers/drive-gateway/src/index";
import {
  boundedFetch,
  type Env,
  GoogleDrive,
} from "../../../workers/drive-gateway/src/runtime";
import {
  DRIVE_MAX_BYTES,
  type DriveGrant,
  readBounded,
  sha256,
  signDriveGrant,
  verifyDriveGrant,
} from "../lib/storage/drive-protocol";

const env: Env = {
  APP_ORIGIN: "https://app.example",
  GATEWAY_ORIGIN: "https://gateway.example",
  DRIVE_ENABLED: "true",
  DRIVE_SCHEDULES_VERIFIED: "true",
  DRIVE_GRANT_SECRET: "test-only-secret-which-is-long-enough",
  SUPABASE_URL: "https://db.example",
  SUPABASE_API_KEY: "test",
  DRIVE_WORKER_TOKEN: "drive",
  SCAN_WORKER_TOKEN: "scan",
  CLEANUP_WORKER_TOKEN: "cleanup",
  GOOGLE_CLIENT_ID: "test",
  GOOGLE_CLIENT_SECRET: "test",
  GOOGLE_REFRESH_TOKEN: "test",
  GOOGLE_PRIVATE_FOLDER_ID: "test",
  CRON_SECRET: "test-only-cron-secret-long-enough",
};
const bytes = new TextEncoder().encode("%PDF-test bytes");
function grant(): DriveGrant {
  return {
    version: 1,
    actor: "actor",
    audience: env.GATEWAY_ORIGIN,
    origin: env.APP_ORIGIN,
    issuedAt: Date.now() - 1,
    expiresAt: Date.now() + 59_000,
    purpose: "preview",
    submissionId: "submission",
    logicalDocumentId: "logical",
    documentId: "document",
    filename: "CV.pdf",
    mimeType: "application/pdf",
  };
}
async function request(
  g: DriveGrant = grant(),
  method = "GET",
  body?: Uint8Array,
) {
  return new Request(`${env.GATEWAY_ORIGIN}/bytes`, {
    method,
    headers: {
      Origin: env.APP_ORIGIN,
      Authorization: "Bearer user",
      "X-Document-Grant": await signDriveGrant(g, env.DRIVE_GRANT_SECRET),
    },
    body: body ? Uint8Array.from(body) : undefined,
  });
}
test("grants reject tampering, expiry, wrong audience/origin and excessive lifetime", async () => {
  const g = grant();
  const token = await signDriveGrant(g, env.DRIVE_GRANT_SECRET);
  assert.equal(
    (
      await verifyDriveGrant(
        token,
        env.DRIVE_GRANT_SECRET,
        env.GATEWAY_ORIGIN,
        env.APP_ORIGIN,
      )
    ).actor,
    "actor",
  );
  for (const [t, audience, origin, now] of [
    [`${token}x`, env.GATEWAY_ORIGIN, env.APP_ORIGIN, Date.now()],
    [token, "other", env.APP_ORIGIN, Date.now()],
    [token, env.GATEWAY_ORIGIN, "other", Date.now()],
    [token, env.GATEWAY_ORIGIN, env.APP_ORIGIN, g.expiresAt],
  ] as const)
    await assert.rejects(
      verifyDriveGrant(t, env.DRIVE_GRANT_SECRET, audience, origin, now),
    );
  await assert.rejects(
    verifyDriveGrant(
      await signDriveGrant(
        { ...g, expiresAt: g.issuedAt + 60_001 },
        env.DRIVE_GRANT_SECRET,
      ),
      env.DRIVE_GRANT_SECRET,
      env.GATEWAY_ORIGIN,
      env.APP_ORIGIN,
    ),
  );
});
test("bounded bodies enforce exact limit, invalid limits and stalled streams", async () => {
  assert.equal(
    (await readBounded(new Response(new Uint8Array(DRIVE_MAX_BYTES)).body))
      .length,
    DRIVE_MAX_BYTES,
  );
  let cancelled = false;
  await assert.rejects(
    readBounded(
      new ReadableStream({
        start(c) {
          c.enqueue(new Uint8Array(DRIVE_MAX_BYTES + 1));
        },
        cancel() {
          cancelled = true;
        },
      }),
    ),
    /INVALID_SIZE/,
  );
  assert.equal(cancelled, true);
  for (const limit of [NaN, Infinity, -1, 1.5])
    await assert.rejects(readBounded(new Response(bytes).body, limit));
  await assert.rejects(
    readBounded(
      new ReadableStream({
        cancel() {
          cancelled = true;
        },
      }),
      100,
      5,
    ),
    /PROVIDER_TIMEOUT|INVALID_SIZE/,
  );
});
test("missing config, mismatched caller and wrong purpose fail before provider I/O", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async () => {
    calls++;
    return Response.json({ id: "other" });
  };
  assert.equal(
    (
      await handleRequest(
        await request(),
        { ...env, GOOGLE_REFRESH_TOKEN: "" },
        fetcher,
      )
    ).status,
    503,
  );
  assert.equal(calls, 0);
  assert.equal(
    (await handleRequest(await request(), env, fetcher)).status,
    403,
  );
  const caller: typeof fetch = async () => Response.json({ id: "actor" });
  assert.equal(
    (await handleRequest(await request(grant(), "PUT", bytes), env, caller))
      .status,
    403,
  );
});
test("read reauthorizes current context and checks whole hash before any range is returned", async () => {
  let revoked = false;
  let modified = false;
  let providerReads = 0;
  const checksum = await sha256(bytes);
  const fetcher: typeof fetch = async (input) => {
    const url = String(input);
    if (url.endsWith("/auth/v1/user")) return Response.json({ id: "actor" });
    if (url.includes("authorize_drive_document_read"))
      return revoked
        ? Response.json({ message: "FORBIDDEN" }, { status: 403 })
        : Response.json({
            provider_file_id: "privateId",
            actual_size_bytes: bytes.length,
            checksum_sha256: checksum,
            mime_type: "application/pdf",
            original_filename: "CV.pdf",
          });
    if (url.includes("oauth2")) return Response.json({ access_token: "test" });
    providerReads++;
    return new Response(
      modified ? new TextEncoder().encode("%PDF-evil bytes") : bytes,
    );
  };
  const req = await request();
  req.headers.set("Range", "bytes=0-4");
  const response = await handleRequest(req, env, fetcher);
  assert.equal(response.status, 206);
  assert.equal(await response.text(), "%PDF-");
  assert.match(response.headers.get("Cache-Control") ?? "", /no-store/);
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  revoked = true;
  assert.equal(
    (await handleRequest(await request(), env, fetcher)).status,
    403,
  );
  assert.equal(providerReads, 1);
  revoked = false;
  modified = true;
  assert.equal(
    (await handleRequest(await request(), env, fetcher)).status,
    409,
  );
});
test("range and disposition reject invalid ranges and normalize malicious filenames", async () => {
  for (const range of ["bytes=999-", "bytes=0-1,4-5", "bytes=-0", "bytes=-"])
    assert.equal(
      byteResponse(bytes, "application/pdf", "CV.pdf", "preview", range).status,
      416,
    );
  const response = byteResponse(
    bytes,
    "application/pdf",
    "bad\r\nname/?.pdf",
    "download",
    "bytes=-5",
  );
  assert.equal(response.status, 206);
  assert.equal((await response.arrayBuffer()).byteLength, 5);
  assert.match(
    response.headers.get("Content-Disposition") ?? "",
    /^attachment;/,
  );
  assert.doesNotMatch(
    response.headers.get("Content-Disposition") ?? "",
    /[\r\n]/,
  );
});
test("create response loss reconciles bound ID then seals; no update or alternate ID", async () => {
  const g: DriveGrant = {
    ...grant(),
    purpose: "upload",
    reservationId: "reservation",
    sessionId: "session",
    bucket: "candidate-quarantine",
    path: "logical/path",
    filename: "CV.pdf",
    mimeType: "application/pdf",
    maxBytes: DRIVE_MAX_BYTES,
  };
  let claims = 0;
  let generated = 0;
  let sealed = false;
  let creates = 0;
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    assert.notEqual(init?.method, "PATCH");
    if (url.endsWith("/auth/v1/user")) return Response.json({ id: "actor" });
    if (url.includes("oauth2")) return Response.json({ access_token: "test" });
    if (url.includes("claim_drive_upload_attempt")) {
      claims++;
      return Response.json({
        provider_file_id: "stablePrivateId",
        fencing_token: "fence",
        leased_until: new Date(Date.now() + 120000).toISOString(),
        write_deadline: new Date(Date.now() + 300000).toISOString(),
      });
    }
    if (url.includes("generateIds")) {
      generated++;
      throw new Error("must reuse existing ID");
    }
    if (url.includes("uploadType=multipart")) {
      creates++;
      assert.equal(init?.method, "POST");
      assert.ok(init?.body instanceof Blob);
      assert.match(await init.body.text(), /stablePrivateId/);
      throw new Error("response lost after successful create");
    }
    if (url.includes("alt=media")) {
      assert.match(url, /stablePrivateId/);
      return new Response(bytes);
    }
    if (url.includes("seal_drive_upload_attempt")) {
      sealed = true;
      const args = JSON.parse(String(init?.body));
      assert.equal(args.p_fencing_token, "fence");
      assert.equal(args.p_checksum_sha256, await sha256(bytes));
      return Response.json({ state_code: "SEALED" });
    }
    throw new Error(`Unexpected mock route ${url}`);
  };
  assert.equal(
    (await handleRequest(await request(g, "PUT", bytes), env, fetcher)).status,
    200,
  );
  assert.equal(claims, 1);
  assert.equal(generated, 0);
  assert.equal(creates, 1);
  assert.equal(sealed, true);
});
test("bounded fetch times out even when response body stalls", async () => {
  const fetcher: typeof fetch = async () => new Response(new ReadableStream());
  await assert.rejects(
    boundedFetch(fetcher, "https://provider.example", {}, (r) => r.text(), 5),
    /PROVIDER_TIMEOUT/,
  );
});
test("generic Drive 404 is not successful cleanup", async () => {
  const drive = new GoogleDrive(
    env,
    "token",
    async () => new Response(null, { status: 404 }),
  );
  await assert.rejects(drive.remove("id"), /DELETE_UNCONFIRMED/);
});
/** Scheduled-run harness: one claimed scan and one claimed cleanup job. */
function scheduledFetcher(driveRead: () => Response | Promise<Response>) {
  const completions: Record<string, unknown>[] = [];
  const pings: Array<{ url: string; authorization: string | null }> = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    const args =
      init?.body && typeof init.body === "string" ? JSON.parse(init.body) : {};
    if (url.startsWith(`${env.APP_ORIGIN}/api/cron/`)) {
      pings.push({
        url,
        authorization: new Headers(init?.headers).get("Authorization"),
      });
      return Response.json({ ok: true });
    }
    if (url.includes("oauth2")) return Response.json({ access_token: "test" });
    if (url.includes("claim_drive_document_scan_requests"))
      return Response.json({
        success: true,
        data: [
          {
            document_scan_request_id: "scan",
            attempt_id: "attempt",
            fencing_token: "fence",
          },
        ],
      });
    if (url.includes("resolve_drive_scan_attempt"))
      return Response.json({
        provider_file_id: "id",
        checksum_sha256: await sha256(bytes),
        actual_size_bytes: bytes.length,
      });
    if (url.includes("alt=media")) return driveRead();
    if (url.includes("complete_document_scan_attempt")) {
      completions.push(args);
      return Response.json({ success: true, data: {} });
    }
    if (url.includes("discover_expired"))
      return Response.json({ success: true, data: {} });
    if (url.includes("claim_drive_storage_cleanup_jobs"))
      return Response.json({
        success: true,
        data: [
          {
            storage_cleanup_id: "cleanup",
            attempt_id: "attempt2",
            fencing_token: "fence2",
          },
        ],
      });
    if (url.includes("resolve_drive_cleanup_location"))
      return Response.json({
        success: true,
        data: { location: { provider_file_id: "id" } },
      });
    if (init?.method === "DELETE") return new Response(null, { status: 404 });
    if (url.includes("complete_storage_cleanup_attempt")) {
      completions.push(args);
      return Response.json({ success: true, data: {} });
    }
    throw new Error(`Unexpected route ${url}`);
  };
  return { fetcher, completions, pings };
}
test("scheduled scan reports CLEAN only for exact sealed bytes Drive agreed to serve", async () => {
  const run = scheduledFetcher(() => new Response(bytes));
  await runScheduled(env, run.fetcher);
  assert.equal(run.completions[0].p_outcome, "CLEAN");
  assert.equal(run.completions[0].p_error_code, null);
  assert.equal(run.completions[0].p_fencing_token, "fence");
  assert.equal(run.completions[1].p_success, false);
  assert.equal(run.completions[1].p_fencing_token, "fence2");
});
test("scheduled scan reports INFECTED when Drive refuses the file as abusive", async () => {
  const run = scheduledFetcher(() =>
    Response.json(
      {
        error: {
          code: 403,
          errors: [{ reason: "cannotDownloadAbusiveFile" }],
        },
      },
      { status: 403 },
    ),
  );
  await runScheduled(env, run.fetcher);
  assert.equal(run.completions[0].p_outcome, "INFECTED");
  assert.equal(run.completions[0].p_error_code, null);
});
test("scheduled scan never reports CLEAN for changed bytes or a provider failure", async () => {
  for (const driveRead of [
    () => new Response(new TextEncoder().encode("%PDF-evil bytes")),
    () => new Response(null, { status: 500 }),
    () =>
      Response.json(
        { error: { errors: [{ reason: "insufficientFilePermissions" }] } },
        { status: 403 },
      ),
  ]) {
    const run = scheduledFetcher(driveRead);
    await runScheduled(env, run.fetcher);
    assert.equal(run.completions[0].p_outcome, "ERROR");
    assert.equal(run.completions[0].p_error_code, "PROVIDER_UNAVAILABLE");
  }
});
test("scheduled run pings app cron routes with the secret, independent of Drive state", async () => {
  const run = scheduledFetcher(() => new Response(bytes));
  await runScheduled(env, run.fetcher);
  assert.deepEqual(
    run.pings.map((ping) => ping.url),
    [`${env.APP_ORIGIN}/api/cron/storage-cleanup`],
  );
  assert.equal(run.pings[0].authorization, `Bearer ${env.CRON_SECRET}`);

  const unverified = scheduledFetcher(() => new Response(bytes));
  await assert.rejects(
    runScheduled(
      { ...env, DRIVE_SCHEDULES_VERIFIED: "false" },
      unverified.fetcher,
    ),
    /SCHEDULES_NOT_CONFIGURED/,
  );
  assert.equal(unverified.pings.length, 1);
  assert.equal(unverified.completions.length, 0);
});
test("a failing app cron route does not stop Drive scan and cleanup work", async () => {
  const run = scheduledFetcher(() => new Response(bytes));
  const fetcher: typeof fetch = async (input, init) => {
    if (String(input).startsWith(`${env.APP_ORIGIN}/api/cron/`))
      throw new Error("app unavailable");
    return run.fetcher(input, init);
  };
  await runScheduled(env, fetcher);
  assert.equal(run.completions.length, 2);
});
test("gateway config needs a cron secret and no external scanner", async () => {
  const run = scheduledFetcher(() => new Response(bytes));
  await assert.rejects(
    runScheduled({ ...env, CRON_SECRET: "short" }, run.fetcher),
    /NOT_CONFIGURED/,
  );
  assert.equal(run.pings.length, 0);
});
