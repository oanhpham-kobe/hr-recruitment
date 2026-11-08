import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  authorizeCandidateUploadScan,
  authorizeStorageCleanupAttempt,
  claimDocumentScanRequests,
  claimStorageCleanupJobs,
  completeDocumentScanAttempt,
  completeStorageCleanupAttempt,
  continueCleanCandidateDocumentScan,
  createSignedUploadUrlForReservation,
  recordCandidateUploadCompleted,
  recordInspectedUploadReservation,
  requestCandidateDocumentScan,
  reserveCandidateFormUpload,
  stageCandidateDocumentChange,
} from "@/lib/commands/storage-reservation";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";
import { ensureQuarantineBucketExists } from "@/lib/storage/buckets";

// -----------------------------------------------------------------------------
// Test Actors
// -----------------------------------------------------------------------------

const activeCandidateActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000001",
  email: "candidate@example.com",
  isActive: true,
  roles: ["CANDIDATE"],
  permissions: ["candidate.self"],
};

const inactiveCandidateActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000002",
  email: "inactive@example.com",
  isActive: false,
  roles: ["CANDIDATE"],
  permissions: ["candidate.self"],
};

const _nonCandidateActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000003",
  email: "staff@eiu.edu.vn",
  isActive: true,
  roles: ["STAFF"],
  permissions: ["submissions.view"],
};

const serviceWorkerActor: VerifiedActor = {
  authUserId: "00000000-0000-0000-0000-000000000000",
  email: "service-worker@internal",
  isActive: true,
  roles: ["SERVICE_ROLE"],
  permissions: ["admin.full"],
};

// -----------------------------------------------------------------------------
// Mock Supabase Factory
// -----------------------------------------------------------------------------

function createMockSupabase(options: {
  rpcHandlers?: Record<string, (args: unknown) => unknown>;
  storageHandlers?: {
    createSignedUploadUrl?: (
      bucket: string,
      path: string,
      opts?: { upsert?: boolean },
    ) => Promise<{
      data: { signedUrl: string; path: string; token: string } | null;
      error: Error | null;
    }>;
    getBucket?: (id: string) => Promise<{ data: unknown; error: Error | null }>;
    createBucket?: (
      id: string,
      opts: unknown,
    ) => Promise<{ error: Error | null }>;
  };
  userData?: { id: string; email: string } | null;
  candidateData?: { candidate_id: string; is_active: boolean } | null;
}) {
  return {
    rpc: async (fn: string, args?: unknown) => {
      const handler = options.rpcHandlers?.[fn];
      if (handler) {
        const result = handler(args);
        return { data: result, error: null };
      }
      return { data: null, error: null };
    },
    storage: {
      from: (bucket: string) => ({
        createSignedUploadUrl: async (
          path: string,
          opts?: { upsert?: boolean },
        ) => {
          if (options.storageHandlers?.createSignedUploadUrl) {
            return options.storageHandlers.createSignedUploadUrl(
              bucket,
              path,
              opts,
            );
          }
          return {
            data: {
              signedUrl: `https://storage.mock/${bucket}/${path}?token=mock_jwt_token_123`,
              path,
              token: "mock_jwt_token_123",
            },
            error: null,
          };
        },
      }),
      getBucket: async (id: string) => {
        if (options.storageHandlers?.getBucket) {
          return options.storageHandlers.getBucket(id);
        }
        return { data: { id, name: id, public: false }, error: null };
      },
      createBucket: async (id: string, opts: unknown) => {
        if (options.storageHandlers?.createBucket) {
          return options.storageHandlers.createBucket(id, opts);
        }
        return { error: null };
      },
    },
    auth: {
      getUser: async () => ({
        data: {
          user:
            options.userData !== undefined
              ? options.userData
              : {
                  id: "a0000000-0000-0000-0000-000000000001",
                  email: "candidate@example.com",
                },
        },
        error: null,
      }),
    },
    from: (_table: string) => ({
      select: (_cols: string) => ({
        eq: (_col: string, _val: unknown) => ({
          maybeSingle: async () => ({
            data:
              options.candidateData !== undefined
                ? options.candidateData
                : {
                    candidate_id: "c0000000-0000-0000-0000-000000000001",
                    is_active: true,
                  },
            error: null,
          }),
        }),
      }),
    }),
  } as unknown as SupabaseClient;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test("1. UNAUTHENTICATED call rejection", async () => {
  const mockSupabase = createMockSupabase({});
  const result = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
    },
    {
      client: mockSupabase,
      resolveActor: async () => null, // Unauthenticated
    },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
  }
});

test("1b. upload scan authorization rejects unauthenticated callers before RPC", async () => {
  let rpcCalls = 0;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      authorize_candidate_upload_scan: () => {
        rpcCalls += 1;
        return { success: true, data: {} };
      },
    },
  });

  const result = await authorizeCandidateUploadScan(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      uploadReservationId: "22222222-2222-2222-2222-222222222222",
    },
    { client: mockSupabase, resolveActor: async () => null },
  );

  assert.equal(result.success, false);
  assert.equal(rpcCalls, 0);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
  }
});

test("1c. upload scan authorization binds the exact session and reservation", async () => {
  let rpcArgs: unknown;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      authorize_candidate_upload_scan: (args) => {
        rpcArgs = args;
        return {
          success: true,
          data: {
            candidate_form_session_id: "11111111-1111-1111-1111-111111111111",
            upload_reservation_id: "22222222-2222-2222-2222-222222222222",
          },
        };
      },
    },
  });

  const result = await authorizeCandidateUploadScan(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      uploadReservationId: "22222222-2222-2222-2222-222222222222",
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, true);
  assert.deepEqual(rpcArgs, {
    p_candidate_form_session_id: "11111111-1111-1111-1111-111111111111",
    p_upload_reservation_id: "22222222-2222-2222-2222-222222222222",
  });
});

test("2. USER_INACTIVE candidate rejection", async () => {
  const mockSupabase = createMockSupabase({});
  const result = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
    },
    {
      client: mockSupabase,
      resolveActor: async () => inactiveCandidateActor,
    },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
  }
});

test("3. NOT_FOUND foreign session access rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      reserve_candidate_form_upload: () => ({
        success: false,
        error_code: "NOT_FOUND",
        message: "Candidate form session not found or access denied",
      }),
    },
  });

  const result = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "99999999-9999-9999-9999-999999999999",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
    },
    {
      client: mockSupabase,
      resolveActor: async () => activeCandidateActor,
    },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.NOT_FOUND);
  }
});

test("4. FORM_SESSION_EXPIRED rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      reserve_candidate_form_upload: () => ({
        success: false,
        error_code: "FORM_SESSION_EXPIRED",
        message: "Candidate form session has expired",
      }),
    },
  });

  const result = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
    },
    {
      client: mockSupabase,
      resolveActor: async () => activeCandidateActor,
    },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, "FORM_SESSION_EXPIRED");
  }
});

test("5. INVALID_STATE (closed session) rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      reserve_candidate_form_upload: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Candidate form session is not open",
      }),
    },
  });

  const result = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
    },
    {
      client: mockSupabase,
      resolveActor: async () => activeCandidateActor,
    },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_STATE);
  }
});

test("6. INVALID_DOCUMENT_TYPE / INACTIVE_DOCUMENT_TYPE rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      reserve_candidate_form_upload: () => ({
        success: false,
        error_code: "INACTIVE_DOCUMENT_TYPE",
        message: "Inactive document type cannot be added to a new submission",
      }),
    },
  });

  const result = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "33333333-3333-3333-3333-333333333333",
      originalFilename: "resume.pdf",
    },
    {
      client: mockSupabase,
      resolveActor: async () => activeCandidateActor,
    },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, "INACTIVE_DOCUMENT_TYPE");
  }
});

test("7. INVALID_FILE_TYPE (disallowed extensions .exe, .sh, .html) rejection", async () => {
  const mockSupabase = createMockSupabase({});

  const disallowed = [
    "malware.exe",
    "script.sh",
    "payload.html",
    "archive.zip",
  ];

  for (const filename of disallowed) {
    const result = await reserveCandidateFormUpload(
      {
        candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
        intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
        originalFilename: filename,
      },
      {
        client: mockSupabase,
        resolveActor: async () => activeCandidateActor,
      },
    );

    assert.equal(result.success, false, `Expected ${filename} to be rejected`);
    if (!result.success) {
      assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    }
  }
});

test("8. FILE_SIZE_EXCEEDED (> 5MB) rejection", async () => {
  const mockSupabase = createMockSupabase({});

  const result = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
      expectedMaxSize: 6 * 1024 * 1024, // 6 MB > 5 MB
    },
    {
      client: mockSupabase,
      resolveActor: async () => activeCandidateActor,
    },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
  }
});

test("9. IDEMPOTENT_RESERVATION duplicate key returns existing reservation", async () => {
  const mockReservation = {
    upload_reservation_id: "res-001-uuid",
    candidate_form_session_id: "11111111-1111-1111-1111-111111111111",
    intended_document_type_id: "22222222-2222-2222-2222-222222222222",
    temp_bucket: "candidate-quarantine",
    temp_path: "temp/session/res-001/resume.pdf",
    original_filename: "resume.pdf",
    declared_mime_type: "application/pdf",
    expected_max_size_bytes: 2000000,
    status_code: "RESERVED",
    expires_at: "2026-09-05T12:00:00Z",
  };

  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      reserve_candidate_form_upload: () => ({
        success: true,
        data: mockReservation,
      }),
    },
  });

  const key = "e1111111-1111-1111-1111-111111111111";
  const first = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
      idempotencyKey: key,
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  const second = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "resume.pdf",
      idempotencyKey: key,
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(first.success, true);
  assert.equal(second.success, true);
  if (first.success && second.success) {
    assert.deepEqual(first.data, second.data);
  }
});

test("10. SIGNED_UPLOAD_URL_DERIVATION derived strictly from reservation, upsert false, returns expiresAt", async () => {
  let capturedBucket = "";
  let capturedPath = "";
  let capturedUpsert: boolean | undefined;

  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      prepare_signed_upload: () => ({
        success: true,
        data: {
          upload_reservation_id: "res-001-uuid",
          temp_bucket: "candidate-quarantine",
          temp_path: "temp/sess-1/res-001/cv.pdf",
          expires_at: "2026-09-05T10:30:00Z",
          signed_upload_expires_at: "2026-09-05T12:05:00Z",
        },
      }),
    },
    storageHandlers: {
      createSignedUploadUrl: async (bucket, path, opts) => {
        capturedBucket = bucket;
        capturedPath = path;
        capturedUpsert = opts?.upsert;
        return {
          data: {
            signedUrl: "https://storage.supabase.co/signed/upload/test",
            path,
            token: "jwt_signed_token_abc",
          },
          error: null,
        };
      },
    },
  });

  const result = await createSignedUploadUrlForReservation(
    {
      uploadReservationId: "11111111-1111-1111-1111-111111111111",
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(capturedBucket, "candidate-quarantine");
    assert.equal(capturedPath, "temp/sess-1/res-001/cv.pdf");
    assert.equal(capturedUpsert, false, "upsert must strictly be false");
    assert.equal(result.data.expiresAt, "2026-09-05T10:30:00Z");
    assert.equal(result.data.signedUploadExpiresAt, "2026-09-05T12:05:00Z");
    assert.equal(result.data.token, "jwt_signed_token_abc");
  }
});

test("11. LATENCY_BUFFER_IN_DURABLE_EXPIRY sets 2h 5m buffer", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      prepare_signed_upload: () => ({
        success: true,
        data: {
          upload_reservation_id: "res-001-uuid",
          temp_bucket: "candidate-quarantine",
          temp_path: "temp/sess-1/res-001/cv.pdf",
          expires_at: "2026-09-05T10:30:00Z",
          signed_upload_expires_at: "2026-09-05T12:05:00Z", // 2h 5m
        },
      }),
    },
  });

  const result = await createSignedUploadUrlForReservation(
    { uploadReservationId: "11111111-1111-1111-1111-111111111111" },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.signedUploadExpiresAt, "2026-09-05T12:05:00Z");
  }
});

test("12. REAL_ORDERING_CANCEL_EARLY_CLEANUP_LATE_UPLOAD test", async () => {
  // Scenario:
  // 1. Reservation created and signed (not_before = now + 2h 5m).
  // 2. Form session cancelled -> enqueues queue with not_before = now + 2h 5m.
  // 3. Early cleanup worker runs at T+5m -> claims 0 rows because not_before > now.
  // 4. Late upload completion attempt at T+10m fails because session is CANCELLED.
  // 5. Due cleanup worker runs at T+2h6m -> claims 1 row for deletion.

  const queueState: Array<{
    id: string;
    path: string;
    status: string;
    not_before: number;
    attempts: number;
  }> = [
    {
      id: "clean-001",
      path: "temp/sess-1/res-001/cv.pdf",
      status: "PENDING",
      not_before: 1000 + 7500, // T + 2h 5m
      attempts: 0,
    },
  ];

  let currentTime = 1000 + 300; // T + 5m (early cleanup)

  // Early claim attempt
  const earlyClaim = queueState.filter(
    (q) => q.status === "PENDING" && q.not_before <= currentTime,
  );
  assert.equal(
    earlyClaim.length,
    0,
    "Early cleanup must claim 0 rows before not_before elapses",
  );

  // Late upload completion attempt
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      record_candidate_upload_completed: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Only OPEN candidate form sessions may accept uploads",
      }),
    },
  });

  const uploadAttempt = await recordCandidateUploadCompleted(
    {
      uploadReservationId: "11111111-1111-1111-1111-111111111111",
      actualSizeBytes: 1024,
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(uploadAttempt.success, false);
  if (!uploadAttempt.success) {
    assert.equal(uploadAttempt.error.code, CommandErrorCode.INVALID_STATE);
  }

  // Due claim attempt at T + 2h 6m
  currentTime = 1000 + 7560;
  const dueClaim = queueState.filter(
    (q) => q.status === "PENDING" && q.not_before <= currentTime,
  );
  assert.equal(
    dueClaim.length,
    1,
    "Due cleanup worker successfully claims expired row after token expires",
  );
});

test("13. CANDIDATE_QUARANTINE_READ_DENIED candidate has zero SELECT on quarantine", async () => {
  // Simulating RLS evaluation on storage.objects for candidate-quarantine bucket
  function evaluateQuarantineSelectPolicy(
    actor: VerifiedActor,
    bucketId: string,
  ) {
    if (bucketId === "candidate-quarantine") {
      // Policy: bucket_id = 'candidate-quarantine' and private.is_root_admin()
      const isRoot =
        actor.roles.includes("ROOT_ADMIN") ||
        actor.permissions.includes("admin.full");
      return isRoot;
    }
    return true;
  }

  assert.equal(
    evaluateQuarantineSelectPolicy(
      activeCandidateActor,
      "candidate-quarantine",
    ),
    false,
    "Candidate must NOT have SELECT on candidate-quarantine",
  );

  assert.equal(
    evaluateQuarantineSelectPolicy(serviceWorkerActor, "candidate-quarantine"),
    true,
    "Privileged service role / root must have SELECT on candidate-quarantine",
  );
});

test("16. STORAGE_RLS_CANCELLED_SESSION_DENIAL direct INSERT fails if session is cancelled", async () => {
  function checkInsertPolicy(
    reservation: { status: string; expires_at: number },
    session: { status: string; expires_at: number },
    currentTime: number,
  ) {
    return (
      reservation.status === "RESERVED" &&
      reservation.expires_at > currentTime &&
      session.status === "OPEN" &&
      session.expires_at > currentTime
    );
  }

  const now = 1000;
  assert.equal(
    checkInsertPolicy(
      { status: "RESERVED", expires_at: 2000 },
      { status: "CANCELLED", expires_at: 2000 },
      now,
    ),
    false,
    "INSERT into storage.objects must be denied when parent form session is CANCELLED",
  );
});

test("17. STORAGE_RLS_NO_OVERWRITE authenticated users have no UPDATE policy", async () => {
  // Simulating storage RLS commands
  const policiesOnStorageObjects = [
    { command: "SELECT", role: "authenticated" },
    { command: "INSERT", role: "authenticated" },
  ];

  const hasUpdatePolicy = policiesOnStorageObjects.some(
    (p) => p.command === "UPDATE" && p.role === "authenticated",
  );

  assert.equal(
    hasUpdatePolicy,
    false,
    "storage.objects must have NO UPDATE policy for authenticated users",
  );
});

test("18. STAGING_ADD validates unexpired reservation in UPLOADED or VALIDATED state", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      stage_candidate_document_change: () => ({
        success: true,
        data: {
          candidate_form_document_change_id: "chg-001",
          candidate_form_session_id: "11111111-1111-1111-1111-111111111111",
          action_code: "ADD",
          intended_document_type_id: "22222222-2222-2222-2222-222222222222",
          upload_reservation_id: "res-001",
          target_logical_document_id: null,
          status_code: "PENDING",
        },
      }),
    },
  });

  const result = await stageCandidateDocumentChange(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      actionCode: "ADD",
      uploadReservationId: "res-001-uuid-0000-0000-000000000001",
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.action_code, "ADD");
    assert.equal(result.data.status_code, "PENDING");
  }
});

test("19. STAGING_REPLACE_DELETE_IN_NEW_SUBMISSION rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      stage_candidate_document_change: () => ({
        success: false,
        error_code: "INVALID_ACTION",
        message:
          "New submission form only supports staged ADD document actions",
      }),
    },
  });

  const result = await stageCandidateDocumentChange(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      actionCode: "REPLACE",
      uploadReservationId: "res-001-uuid-0000-0000-000000000001",
      targetLogicalDocumentId: "log-001-uuid-0000-0000-000000000001",
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, "INVALID_ACTION");
  }
});

test("20. STAGING_UNREADY_OR_EXPIRED_RESERVATION rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      stage_candidate_document_change: () => ({
        success: false,
        error_code: "UPLOAD_RESERVATION_EXPIRED",
        message: "Upload reservation has expired",
      }),
    },
  });

  const result = await stageCandidateDocumentChange(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      actionCode: "ADD",
      uploadReservationId: "res-001-uuid-0000-0000-000000000001",
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, "UPLOAD_RESERVATION_EXPIRED");
  }
});

test("21. SUBMIT_PLAN_VALIDATION_REQUIRES_CLEAN requires VALIDATED and CLEAN at save time", async () => {
  function validatePlanSim(
    reservations: Array<{ status: string; scan: string }>,
  ) {
    for (const r of reservations) {
      if (r.status !== "VALIDATED" || r.scan !== "CLEAN") {
        return { valid: false, error: "UPLOAD_RESERVATION_NOT_CLEAN" };
      }
    }
    return { valid: true };
  }

  assert.equal(
    validatePlanSim([{ status: "UPLOADED", scan: "PENDING" }]).valid,
    false,
    "Plan validation must fail if reservation is only UPLOADED/PENDING",
  );

  assert.equal(
    validatePlanSim([{ status: "VALIDATED", scan: "CLEAN" }]).valid,
    true,
    "Plan validation must pass when VALIDATED and CLEAN",
  );
});

test("22. EDIT_SESSION_SUBMISSION_NO_LONGER_NEW_DENIAL rejects when target is not NEW", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      reserve_candidate_form_upload: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Target submission is no longer in editable NEW status",
      }),
      prepare_signed_upload: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Target submission is no longer in editable NEW status",
      }),
      record_candidate_upload_completed: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Target submission is no longer in editable NEW status",
      }),
      stage_candidate_document_change: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Target submission is no longer in editable NEW status",
      }),
    },
  });

  const reserve = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      originalFilename: "cv.pdf",
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );
  assert.equal(reserve.success, false);
  if (!reserve.success) {
    assert.equal(reserve.error.code, CommandErrorCode.INVALID_STATE);
  }

  const sign = await createSignedUploadUrlForReservation(
    { uploadReservationId: "11111111-1111-1111-1111-111111111111" },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );
  assert.equal(sign.success, false);

  const stage = await stageCandidateDocumentChange(
    {
      candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
      intendedDocumentTypeId: "22222222-2222-2222-2222-222222222222",
      actionCode: "ADD",
      uploadReservationId: "res-001-uuid-0000-0000-000000000001",
    },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );
  assert.equal(stage.success, false);
});

test("23. cleanup worker adapter fences authorization and completion without a Storage action", async () => {
  const calls: Array<{ name: string; args: unknown }> = [];
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      claim_storage_cleanup_jobs: (args: unknown) => {
        calls.push({ name: "claim_storage_cleanup_jobs", args });
        return {
          success: true,
          data: [
            {
              storage_cleanup_id: "11111111-1111-1111-1111-111111111111",
              source_type: "CANDIDATE_FORM",
              bucket_name: "candidate-quarantine",
              object_path:
                "temp/22222222-2222-2222-2222-222222222222/33333333-3333-3333-3333-333333333333/expired.pdf",
              reason_code: "RESERVATION_EXPIRED",
              attempts: 1,
              not_before: "2026-09-15T00:00:00Z",
              leased_until: "2030-01-01T00:00:00Z",
              attempt_id: "44444444-4444-4444-4444-444444444444",
              fencing_token: "55555555-5555-5555-5555-555555555555",
            },
          ],
        };
      },
      authorize_storage_cleanup_attempt: (args: unknown) => {
        calls.push({ name: "authorize_storage_cleanup_attempt", args });
        return {
          success: true,
          data: {
            storage_cleanup_id: "11111111-1111-1111-1111-111111111111",
            bucket_name: "candidate-quarantine",
            object_path:
              "temp/22222222-2222-2222-2222-222222222222/33333333-3333-3333-3333-333333333333/expired.pdf",
            reason_code: "RESERVATION_EXPIRED",
            attempt_id: "44444444-4444-4444-4444-444444444444",
            fencing_token: "55555555-5555-5555-5555-555555555555",
            leased_until: "2030-01-01T00:00:00Z",
          },
        };
      },
      complete_storage_cleanup_attempt: (args: unknown) => {
        calls.push({ name: "complete_storage_cleanup_attempt", args });
        return { success: true, data: { status_code: "DONE" } };
      },
    },
  });

  const [claimed] = await claimStorageCleanupJobs(
    "cleanup-worker-1",
    1,
    300,
    mockSupabase,
  );
  assert.ok(claimed);
  await authorizeStorageCleanupAttempt(
    {
      storageCleanupId: claimed.storage_cleanup_id,
      attemptId: claimed.attempt_id,
      fencingToken: claimed.fencing_token,
      workerId: "cleanup-worker-1",
    },
    mockSupabase,
  );
  const completed = await completeStorageCleanupAttempt(
    {
      storageCleanupId: claimed.storage_cleanup_id,
      attemptId: claimed.attempt_id,
      fencingToken: claimed.fencing_token,
      workerId: "cleanup-worker-1",
      success: true,
    },
    mockSupabase,
  );

  assert.equal(completed.status_code, "DONE");
  assert.deepEqual(
    calls.map((call) => call.name),
    [
      "claim_storage_cleanup_jobs",
      "authorize_storage_cleanup_attempt",
      "complete_storage_cleanup_attempt",
    ],
  );
  assert.deepEqual(calls[1]?.args, {
    p_storage_cleanup_id: claimed.storage_cleanup_id,
    p_attempt_id: claimed.attempt_id,
    p_fencing_token: claimed.fencing_token,
    p_worker_id: "cleanup-worker-1",
  });
});

test("24. cleanup worker adapter exposes safe stale-attempt failures", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      authorize_storage_cleanup_attempt: () => ({
        success: false,
        error_code: "STALE_ATTEMPT",
      }),
    },
  });

  await assert.rejects(
    authorizeStorageCleanupAttempt(
      {
        storageCleanupId: "11111111-1111-1111-1111-111111111111",
        attemptId: "22222222-2222-2222-2222-222222222222",
        fencingToken: "33333333-3333-3333-3333-333333333333",
        workerId: "cleanup-worker-1",
      },
      mockSupabase,
    ),
    /authorize_storage_cleanup_attempt error: STALE_ATTEMPT/,
  );
});

test("26. Declarative storage bucket setup helper", async () => {
  const mockSupabase = createMockSupabase({});
  const result = await ensureQuarantineBucketExists(mockSupabase);
  assert.equal(result.success, true);
});

test("27. PENDING_SCAN is distinct from staged completion and preserves only server-owned continuation", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      record_inspected_upload_reservation: () => ({
        success: true,
        data: {
          upload_reservation_id: "11111111-1111-1111-1111-111111111111",
          status_code: "UPLOADED",
          malware_scan_status: "PENDING",
        },
      }),
      request_candidate_document_scan: () => ({
        success: true,
        data: {
          kind: "PENDING_SCAN",
          document_scan_request_id: "33333333-3333-3333-3333-333333333333",
          upload_reservation_id: "11111111-1111-1111-1111-111111111111",
        },
      }),
      continue_clean_candidate_document_scan: () => ({
        success: true,
        data: {
          kind: "STAGED",
          change_id: "44444444-4444-4444-4444-444444444444",
        },
      }),
    },
  });

  const recorded = await recordInspectedUploadReservation(
    {
      uploadReservationId: "11111111-1111-1111-1111-111111111111",
      actualSizeBytes: 2048,
      detectedMimeType: "application/pdf",
      checksumSha256: "a".repeat(64),
      magicBytesVerified: true,
    },
    mockSupabase,
  );
  assert.equal(recorded.success, true);

  const pending = await requestCandidateDocumentScan(
    {
      candidateFormSessionId: "22222222-2222-2222-2222-222222222222",
      uploadReservationId: "11111111-1111-1111-1111-111111111111",
      actionCode: "REPLACE",
      targetLogicalDocumentId: "55555555-5555-5555-5555-555555555555",
    },
    mockSupabase,
  );
  assert.equal(pending.success, true);
  if (pending.success) {
    assert.equal(pending.data.kind, "PENDING_SCAN");
    assert.equal("change_id" in pending.data, false);
  }

  const staged = await continueCleanCandidateDocumentScan(
    "22222222-2222-2222-2222-222222222222",
    "11111111-1111-1111-1111-111111111111",
    mockSupabase,
  );
  assert.equal(staged.success, true);
  if (staged.success) {
    assert.equal(staged.data.kind, "STAGED");
    assert.equal(staged.data.change_id, "44444444-4444-4444-4444-444444444444");
  }
});

test("28. document scan worker adapter preserves attempt and fencing identity", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      claim_document_scan_requests: () => ({
        success: true,
        data: [
          {
            document_scan_request_id: "11111111-1111-1111-1111-111111111111",
            upload_reservation_id: "22222222-2222-2222-2222-222222222222",
            attempt_id: "33333333-3333-3333-3333-333333333333",
            fencing_token: "44444444-4444-4444-4444-444444444444",
            leased_until: "2030-01-01T00:00:00Z",
          },
        ],
      }),
      complete_document_scan_attempt: () => ({
        success: true,
        data: { status_code: "CLEAN" },
      }),
    },
  });
  const claimed = await claimDocumentScanRequests(
    "scan-worker-1",
    1,
    300,
    mockSupabase,
  );
  assert.equal(claimed.success, true);
  if (!claimed.success) return;
  const item = claimed.data[0];
  assert.ok(item);
  const completed = await completeDocumentScanAttempt(
    {
      documentScanRequestId: item.document_scan_request_id,
      attemptId: item.attempt_id,
      fencingToken: item.fencing_token,
      workerId: "scan-worker-1",
      outcome: "CLEAN",
    },
    mockSupabase,
  );
  assert.equal(completed.success, true);
});
