import "server-only";

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import type {
  AuthorizeStorageCleanupAttemptInput,
  ClaimedStorageCleanupJob,
} from "@/lib/commands/storage-reservation";
import {
  createStorageCleanupDbPort,
  runStorageCleanupBatch,
  type StorageCleanupDbPort,
} from "@/lib/storage/cleanup-runner";
import { createStorageCleanupWorkerClient } from "@/lib/storage/cleanup-worker-client";
import {
  createSupabaseStorageCleanupProvider,
  isAuthoritativeStorageAbsence,
  type StorageCleanupProvider,
  StorageCleanupProviderError,
} from "@/lib/storage/storage-provider";

const apiUrl = mustEnv("SUPABASE_LOCAL_API_URL");
const anonKey = mustEnv("SUPABASE_LOCAL_ANON_KEY");
const serviceRoleKey = mustEnv("SUPABASE_LOCAL_SERVICE_ROLE_KEY");
const jwtSecret = mustEnv("SUPABASE_LOCAL_JWT_SECRET");
const containerName =
  process.env.CONTAINER_NAME || "supabase_db_eiu-recruitment-dev";

function mustEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value)
    throw new Error(`Missing required local integration env: ${name}`);
  return value;
}

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

function mintRoleJwt(role: string): string {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(
    JSON.stringify({ iss: "supabase-demo", role, iat: now, exp: now + 300 }),
  );
  const unsigned = `${header}.${payload}`;
  const signature = createHmac("sha256", jwtSecret)
    .update(unsigned)
    .digest("base64url");
  return `${unsigned}.${signature}`;
}

function psql(sql: string): string {
  return execFileSync(
    "docker",
    [
      "exec",
      "-i",
      containerName,
      "psql",
      "-qAt",
      "-v",
      "ON_ERROR_STOP=1",
      "-U",
      "postgres",
      "-d",
      "postgres",
    ],
    { input: sql, encoding: "utf8" },
  ).trim();
}

function q(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function candidatePath(
  parentId: string,
  reservationId: string,
  name: string,
): string {
  return `temp/${parentId}/${reservationId}/${name}`;
}

function interviewPath(parentId: string, reservationId: string): string {
  return `temp/interview/${parentId}/${reservationId}`;
}

function sourceType(bucket: string): "CANDIDATE_FORM" | "INTERVIEW_UPLOAD" {
  return bucket === "interview-quarantine"
    ? "INTERVIEW_UPLOAD"
    : "CANDIDATE_FORM";
}

type SeededQueue = {
  queueId: string;
  parentId: string;
  reservationId: string;
  bucket: string;
  path: string;
};

function retireActiveQueues(): void {
  psql(`
    update public.storage_cleanup_queue
    set status_code = 'ERROR', leased_until = null, authorized_at = null,
        eligibility_code = coalesce(eligibility_code, 'TEST_RETIRED')
    where status_code in ('PENDING','PROCESSING');
  `);
}

function seedDetachedQueue(options: {
  bucket: string;
  path?: string;
  reason?: string;
  parentId?: string;
  reservationId?: string;
}): SeededQueue {
  const queueId = randomUUID();
  const parentId = options.parentId ?? randomUUID();
  const reservationId = options.reservationId ?? randomUUID();
  const bucket = options.bucket;
  const path =
    options.path ??
    (bucket === "interview-quarantine"
      ? interviewPath(parentId, reservationId)
      : candidatePath(parentId, reservationId, "cleanup.pdf"));
  const reason = options.reason ?? "RESERVATION_EXPIRED";
  const src = sourceType(bucket);
  psql(`
    insert into private.storage_cleanup_provenance(
      bucket_name, object_path, upload_reservation_id, source_type, source_parent_id,
      reservation_expires_at, signed_upload_expires_at, detached_at
    ) values (
      ${q(bucket)}, ${q(path)}, ${q(reservationId)}::uuid, ${q(src)}, ${q(parentId)}::uuid,
      clock_timestamp() - interval '2 hours', clock_timestamp() - interval '1 hour', clock_timestamp()
    );
    insert into public.storage_cleanup_queue(
      storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
      bucket_name, object_path, reason_code, status_code, not_before
    ) values (
      ${q(queueId)}::uuid, ${q(src)}, ${q(parentId)}::uuid, ${q(reservationId)}::uuid,
      ${q(bucket)}, ${q(path)}, ${q(reason)}, 'PENDING', clock_timestamp() - interval '1 hour'
    );
  `);
  return { queueId, parentId, reservationId, bucket, path };
}

function queueState(queueId: string): string {
  return psql(`
    select status_code || '|' || coalesce(eligibility_code,'') || '|' || attempts::text || '|' || coalesce(last_error,'')
    from public.storage_cleanup_queue where storage_cleanup_id = ${q(queueId)}::uuid;
  `);
}

function expireLease(queueId: string): void {
  psql(
    `update public.storage_cleanup_queue set leased_until = clock_timestamp() - interval '1 second' where storage_cleanup_id = ${q(queueId)}::uuid;`,
  );
}

function makeCountingProvider(base: StorageCleanupProvider) {
  const calls: Array<[string, string]> = [];
  const provider: StorageCleanupProvider = {
    async removeObject(bucket, path) {
      calls.push([bucket, path]);
      return base.removeObject(bucket, path);
    },
  };
  return { provider, calls };
}

const workerToken = mintRoleJwt("storage_cleanup_worker");
const workerClient = createStorageCleanupWorkerClient({
  supabaseUrl: apiUrl,
  apiKey: anonKey,
  workerAccessToken: workerToken,
});
const workerDb = createStorageCleanupDbPort(workerClient);
const serviceClient = createClient(apiUrl, serviceRoleKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
});
const anonClient = createClient(apiUrl, anonKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
});
const authenticatedClient = createClient(apiUrl, anonKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
  global: {
    headers: { Authorization: `Bearer ${mintRoleJwt("authenticated")}` },
  },
});
const realProvider = createSupabaseStorageCleanupProvider(serviceClient);
const createdObjects: Array<[string, string]> = [];

async function ensureBucket(bucket: string): Promise<void> {
  const existing = await serviceClient.storage.getBucket(bucket);
  if (existing.data && !existing.error) return;
  const created = await serviceClient.storage.createBucket(bucket, {
    public: false,
    fileSizeLimit: 5 * 1024 * 1024,
    allowedMimeTypes: ["application/pdf"],
  });
  if (
    created.error &&
    !created.error.message.toLowerCase().includes("already")
  ) {
    throw created.error;
  }
}

async function upload(
  bucket: string,
  path: string,
  body = "s07-004",
): Promise<void> {
  const result = await serviceClient.storage
    .from(bucket)
    .upload(path, new Blob([body], { type: "application/pdf" }), {
      contentType: "application/pdf",
      upsert: false,
    });
  if (result.error) throw result.error;
  createdObjects.push([bucket, path]);
}

async function exists(bucket: string, path: string): Promise<boolean> {
  const result = await serviceClient.storage.from(bucket).download(path);
  return !result.error && result.data !== null;
}

async function cleanupObjects(): Promise<void> {
  const byBucket = new Map<string, string[]>();
  for (const [bucket, path] of createdObjects) {
    const list = byBucket.get(bucket) ?? [];
    list.push(path);
    byBucket.set(bucket, list);
  }
  for (const [bucket, paths] of byBucket) {
    await serviceClient.storage.from(bucket).remove(paths);
  }
}

async function assertRoleBoundary(): Promise<void> {
  retireActiveQueues();
  for (const [label, client] of [
    ["anon", anonClient],
    ["authenticated", authenticatedClient],
    ["service_role", serviceClient],
  ] as const) {
    const denied = await client.rpc("claim_storage_cleanup_jobs", {
      p_worker_id: `deny-${label}`,
      p_limit: 1,
      p_lease_seconds: 60,
    });
    assert.ok(
      denied.error,
      `${label} must remain denied cleanup RPC execution`,
    );
  }
  const allowed = await workerClient.rpc("claim_storage_cleanup_jobs", {
    p_worker_id: "worker-boundary",
    p_limit: 1,
    p_lease_seconds: 60,
  });
  assert.equal(
    allowed.error,
    null,
    "worker JWT must reach cleanup RPC through PostgREST",
  );
  assert.equal((allowed.data as { success?: boolean })?.success, true);
}

function seedReferencedQueues(): {
  current: SeededQueue;
  historical: SeededQueue;
} {
  const candidateId = randomUUID();
  const authId = randomUUID();
  const documentTypeId = randomUUID();
  const submissionId = randomUUID();
  const currentLogical = randomUUID();
  const historicalLogical = randomUUID();
  const current = seedDetachedQueue({ bucket: "candidate-quarantine" });
  const historical = seedDetachedQueue({ bucket: "candidate-quarantine" });
  psql(`
    insert into public.candidates(candidate_id, auth_user_id, email)
    values (${q(candidateId)}::uuid, ${q(authId)}::uuid, ${q(`s07-${candidateId}@example.test`)});
    insert into public.document_types(document_type_id, code, name_vi, scope_code)
    values (${q(documentTypeId)}::uuid, ${q(`S07P-${documentTypeId.slice(0, 8)}`)}, 'S07 physical', 'SUBMISSION');
    insert into public.submissions(
      submission_id, candidate_id, full_name, date_of_birth, gender_code,
      current_address, phone, email_snapshot
    ) values (
      ${q(submissionId)}::uuid, ${q(candidateId)}::uuid, 'S07 physical', date '2000-01-01',
      'FEMALE', 'test', '0000000000', ${q(`s07-sub-${candidateId}@example.test`)}
    );
    insert into public.submission_document_logicals(
      logical_document_id, submission_id, document_type_id, created_by_candidate_id
    ) values
      (${q(currentLogical)}::uuid, ${q(submissionId)}::uuid, ${q(documentTypeId)}::uuid, ${q(candidateId)}::uuid),
      (${q(historicalLogical)}::uuid, ${q(submissionId)}::uuid, ${q(documentTypeId)}::uuid, ${q(candidateId)}::uuid);
    insert into public.submission_documents(
      logical_document_id, storage_bucket, storage_path, original_filename, mime_type,
      file_size_bytes, version_no, is_current, uploaded_by_candidate_id
    ) values
      (${q(currentLogical)}::uuid, ${q(current.bucket)}, ${q(current.path)}, 'current.pdf', 'application/pdf', 1, 1, true, ${q(candidateId)}::uuid),
      (${q(historicalLogical)}::uuid, ${q(historical.bucket)}, ${q(historical.path)}, 'historical.pdf', 'application/pdf', 1, 1, false, ${q(candidateId)}::uuid);
  `);
  return { current, historical };
}

function seedTerminalReservation(): SeededQueue {
  const candidateId = randomUUID();
  const authId = randomUUID();
  const notice = `s07-physical-${randomUUID()}`;
  const documentTypeId = randomUUID();
  const sessionId = randomUUID();
  const reservationId = randomUUID();
  const queueId = randomUUID();
  const path = candidatePath(sessionId, reservationId, "terminal.pdf");
  psql(`
    insert into public.candidates(candidate_id, auth_user_id, email)
    values (${q(candidateId)}::uuid, ${q(authId)}::uuid, ${q(`s07-terminal-${candidateId}@example.test`)});
    insert into public.privacy_notice_versions(notice_version, content_vi, content_hash_sha256, is_current)
    values (${q(notice)}, 'S07 physical', repeat('e', 64), false);
    insert into public.document_types(document_type_id, code, name_vi, scope_code)
    values (${q(documentTypeId)}::uuid, ${q(`S07T-${documentTypeId.slice(0, 8)}`)}, 'S07 terminal', 'SUBMISSION');
    insert into public.candidate_form_sessions(
      candidate_form_session_id, candidate_id, mode_code, presented_privacy_notice_version,
      status_code, expires_at
    ) values (
      ${q(sessionId)}::uuid, ${q(candidateId)}::uuid, 'NEW_SUBMISSION', ${q(notice)},
      'CANCELLED', clock_timestamp() - interval '2 hours'
    );
    insert into public.upload_reservations(
      upload_reservation_id, candidate_form_session_id, intended_document_type_id,
      temp_bucket, temp_path, original_filename, actor_auth_user_id, idempotency_key,
      expires_at, signed_upload_expires_at, status_code
    ) values (
      ${q(reservationId)}::uuid, ${q(sessionId)}::uuid, ${q(documentTypeId)}::uuid,
      'candidate-quarantine', ${q(path)}, 'terminal.pdf', ${q(authId)}::uuid, gen_random_uuid(),
      clock_timestamp() - interval '2 hours', clock_timestamp() - interval '1 hour', 'CANCELLED'
    );
    insert into public.storage_cleanup_queue(
      storage_cleanup_id, source_type, source_parent_id, source_upload_reservation_id,
      bucket_name, object_path, reason_code, status_code, not_before
    ) values (
      ${q(queueId)}::uuid, 'CANDIDATE_FORM', ${q(sessionId)}::uuid, ${q(reservationId)}::uuid,
      'candidate-quarantine', ${q(path)}, 'SESSION_CANCELLED', 'PENDING', clock_timestamp() - interval '1 hour'
    );
  `);
  return {
    queueId,
    parentId: sessionId,
    reservationId,
    bucket: "candidate-quarantine",
    path,
  };
}

async function main(): Promise<void> {
  await ensureBucket("candidate-quarantine");
  await ensureBucket("interview-quarantine");
  await assertRoleBoundary();

  const absenceProbe = candidatePath(
    randomUUID(),
    randomUUID(),
    "absent-probe.pdf",
  );
  const absenceObservation = await serviceClient.storage
    .from("candidate-quarantine")
    .remove([absenceProbe]);
  if (absenceObservation.error) {
    assert.equal(
      isAuthoritativeStorageAbsence(absenceObservation.error),
      true,
      "local absent-object response must be recognized narrowly",
    );
  }
  console.log(
    `S07-004 local absent-object behavior: error=${absenceObservation.error ? "present" : "none"}; dataCount=${Array.isArray(absenceObservation.data) ? absenceObservation.data.length : "n/a"}`,
  );

  // 1 + 3 + 12: Candidate deletion, neighbor isolation, exact targeted provider call.
  retireActiveQueues();
  const candidate = seedDetachedQueue({ bucket: "candidate-quarantine" });
  const neighbor = candidatePath(
    candidate.parentId,
    randomUUID(),
    "neighbor.pdf",
  );
  await upload(candidate.bucket, candidate.path, "candidate-target");
  await upload(candidate.bucket, neighbor, "candidate-neighbor");
  const candidateCounted = makeCountingProvider(realProvider);
  const candidateResult = await runStorageCleanupBatch({
    workerId: "physical-candidate",
    db: workerDb,
    provider: candidateCounted.provider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(candidateResult.jobs[0]?.result, "DONE");
  assert.equal(await exists(candidate.bucket, candidate.path), false);
  assert.equal(await exists(candidate.bucket, neighbor), true);
  assert.deepEqual(candidateCounted.calls, [
    [candidate.bucket, candidate.path],
  ]);
  assert.match(queueState(candidate.queueId), /^DONE\|AUTHORIZED\|1\|/);

  // 2: Interview-quarantine physical deletion using its accepted managed path shape.
  retireActiveQueues();
  const interview = seedDetachedQueue({ bucket: "interview-quarantine" });
  await upload(interview.bucket, interview.path, "interview-target");
  const interviewCounted = makeCountingProvider(realProvider);
  const interviewResult = await runStorageCleanupBatch({
    workerId: "physical-interview",
    db: workerDb,
    provider: interviewCounted.provider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(interviewResult.jobs[0]?.result, "DONE");
  assert.equal(await exists(interview.bucket, interview.path), false);
  assert.deepEqual(interviewCounted.calls, [
    [interview.bucket, interview.path],
  ]);

  // 4: No authorization -> zero provider calls and object remains.
  retireActiveQueues();
  const withheld = seedDetachedQueue({
    bucket: "candidate-quarantine",
    reason: "DOCUMENT_REPLACED",
  });
  await upload(withheld.bucket, withheld.path, "withheld");
  const withheldCounted = makeCountingProvider(realProvider);
  const withheldResult = await runStorageCleanupBatch({
    workerId: "physical-withheld",
    db: workerDb,
    provider: withheldCounted.provider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(withheldResult.claimedCount, 0);
  assert.equal(withheldCounted.calls.length, 0);
  assert.equal(await exists(withheld.bucket, withheld.path), true);
  assert.match(
    queueState(withheld.queueId),
    /^ERROR\|RETAINED_REPLACEMENT\|0\|/,
  );

  // 5 + 6: Current and historical document references both block physical deletion.
  retireActiveQueues();
  const refs = seedReferencedQueues();
  await upload(refs.current.bucket, refs.current.path, "current-ref");
  await upload(refs.historical.bucket, refs.historical.path, "historical-ref");
  const refsCounted = makeCountingProvider(realProvider);
  const refsResult = await runStorageCleanupBatch({
    workerId: "physical-retained",
    db: workerDb,
    provider: refsCounted.provider,
    limit: 10,
    leaseSeconds: 60,
  });
  assert.equal(refsResult.claimedCount, 0);
  assert.equal(refsCounted.calls.length, 0);
  assert.equal(await exists(refs.current.bucket, refs.current.path), true);
  assert.equal(
    await exists(refs.historical.bucket, refs.historical.path),
    true,
  );
  assert.match(
    queueState(refs.current.queueId),
    /^ERROR\|RETAINED_REFERENCE\|0\|/,
  );
  assert.match(
    queueState(refs.historical.queueId),
    /^ERROR\|RETAINED_REFERENCE\|0\|/,
  );

  // 7: Stale attempt is rejected before provider I/O.
  retireActiveQueues();
  const stale = seedDetachedQueue({ bucket: "candidate-quarantine" });
  await upload(stale.bucket, stale.path, "stale");
  const staleClaims = await workerDb.claimJobs("stale-worker", 1, 60);
  assert.equal(staleClaims.length, 1);
  const staleClaim = staleClaims[0] as ClaimedStorageCleanupJob;
  expireLease(stale.queueId);
  const reclaimed = await workerDb.claimJobs("fresh-worker", 1, 60);
  assert.equal(reclaimed.length, 1);
  const stalePort: StorageCleanupDbPort = {
    async claimJobs() {
      return [staleClaim];
    },
    authorizeAttempt(input) {
      return workerDb.authorizeAttempt(input);
    },
    completeAttempt(input) {
      return workerDb.completeAttempt(input);
    },
  };
  const staleCounted = makeCountingProvider(realProvider);
  const staleResult = await runStorageCleanupBatch({
    workerId: "stale-worker",
    db: stalePort,
    provider: staleCounted.provider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(staleResult.jobs[0]?.result, "AUTHORIZATION_WITHHELD");
  assert.equal(staleResult.jobs[0]?.errorCode, "STALE_ATTEMPT");
  assert.equal(staleCounted.calls.length, 0);
  assert.equal(await exists(stale.bucket, stale.path), true);

  // 8: Actual terminal CANCELLED reservation past all bounds deletes and settles DONE.
  retireActiveQueues();
  const terminal = seedTerminalReservation();
  await upload(terminal.bucket, terminal.path, "terminal");
  const terminalResult = await runStorageCleanupBatch({
    workerId: "physical-terminal",
    db: workerDb,
    provider: realProvider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(terminalResult.jobs[0]?.result, "DONE");
  assert.equal(await exists(terminal.bucket, terminal.path), false);
  assert.match(queueState(terminal.queueId), /^DONE\|AUTHORIZED\|1\|/);

  // 9: Crash after physical delete but before completion -> reclaim -> absent -> DONE.
  retireActiveQueues();
  const crash = seedDetachedQueue({ bucket: "candidate-quarantine" });
  await upload(crash.bucket, crash.path, "crash-window");
  const crashClaim = (await workerDb.claimJobs("crash-worker-a", 1, 60))[0];
  assert.ok(crashClaim);
  const crashInput: AuthorizeStorageCleanupAttemptInput = {
    storageCleanupId: crashClaim.storage_cleanup_id,
    attemptId: crashClaim.attempt_id,
    fencingToken: crashClaim.fencing_token,
    workerId: "crash-worker-a",
  };
  const crashAuthorized = await workerDb.authorizeAttempt(crashInput);
  await realProvider.removeObject(
    crashAuthorized.bucket_name,
    crashAuthorized.object_path,
  );
  assert.equal(await exists(crash.bucket, crash.path), false);
  expireLease(crash.queueId);
  const crashRecovery = await runStorageCleanupBatch({
    workerId: "crash-worker-b",
    db: workerDb,
    provider: realProvider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(crashRecovery.jobs[0]?.result, "DONE");
  assert.match(queueState(crash.queueId), /^DONE\|AUTHORIZED\|2\|/);

  // 10: Object already absent before first delete converges to DONE.
  retireActiveQueues();
  const absent = seedDetachedQueue({ bucket: "candidate-quarantine" });
  assert.equal(await exists(absent.bucket, absent.path), false);
  const absentResult = await runStorageCleanupBatch({
    workerId: "physical-absent",
    db: workerDb,
    provider: realProvider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(absentResult.jobs[0]?.result, "DONE");
  assert.match(queueState(absent.queueId), /^DONE\|AUTHORIZED\|1\|/);

  // 11: Provider timeout records bounded retry and does not falsely delete; retry succeeds.
  retireActiveQueues();
  const retry = seedDetachedQueue({ bucket: "candidate-quarantine" });
  await upload(retry.bucket, retry.path, "retry");
  const failingProvider: StorageCleanupProvider = {
    async removeObject() {
      throw new StorageCleanupProviderError(
        "PROVIDER_TIMEOUT",
        "simulated timeout",
      );
    },
  };
  const firstRetry = await runStorageCleanupBatch({
    workerId: "retry-worker-a",
    db: workerDb,
    provider: failingProvider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(firstRetry.jobs[0]?.result, "RETRY_RECORDED");
  assert.equal(firstRetry.jobs[0]?.errorCode, "PROVIDER_TIMEOUT");
  assert.equal(await exists(retry.bucket, retry.path), true);
  assert.match(
    queueState(retry.queueId),
    /^PENDING\|WORKER_RETRY\|1\|PROVIDER_TIMEOUT$/,
  );
  psql(
    `update public.storage_cleanup_queue set not_before = clock_timestamp() - interval '1 second' where storage_cleanup_id = ${q(retry.queueId)}::uuid;`,
  );
  const secondRetry = await runStorageCleanupBatch({
    workerId: "retry-worker-b",
    db: workerDb,
    provider: realProvider,
    limit: 1,
    leaseSeconds: 60,
  });
  assert.equal(secondRetry.jobs[0]?.result, "DONE");
  assert.equal(await exists(retry.bucket, retry.path), false);
  assert.match(queueState(retry.queueId), /^DONE\|AUTHORIZED\|2\|$/);

  console.log(
    "PASS: S07-004 physical local Storage integration cases 1-12 succeeded.",
  );
}

async function runIntegration(): Promise<void> {
  try {
    await main();
  } finally {
    await cleanupObjects();
  }
}

void runIntegration().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
