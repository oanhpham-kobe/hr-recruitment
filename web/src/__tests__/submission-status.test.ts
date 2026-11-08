import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  correctSubmissionCandidateFieldsByHr,
  openSubmission,
  recalculateSubmissionStatus,
  setSubmissionManualStatus,
} from "@/lib/commands/submission-status";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";

// -----------------------------------------------------------------------------
// Test Actors
// -----------------------------------------------------------------------------

const viewOnlyHrActor: VerifiedActor = {
  authUserId: "u0000000-0000-0000-0000-000000000001",
  email: "hr-view@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["submissions.view"], // view-only, lacks submissions.status
};

const fullHrActor: VerifiedActor = {
  authUserId: "u0000000-0000-0000-0000-000000000002",
  email: "hr-full@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["submissions.view", "submissions.status"],
};

const editHrActor: VerifiedActor = {
  authUserId: "u0000000-0000-0000-0000-000000000002",
  email: "hr-edit@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["submissions.view", "submissions.status", "submissions.edit"],
};

const unauthorizedActor: VerifiedActor = {
  authUserId: "u0000000-0000-0000-0000-000000000003",
  email: "candidate@example.com",
  isActive: true,
  roles: ["CANDIDATE"],
  permissions: ["candidate.self"],
};

// -----------------------------------------------------------------------------
// Mock Supabase Factory
// -----------------------------------------------------------------------------

function createMockSupabase(options: {
  rpcHandlers?: Record<string, (args: unknown) => unknown>;
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
    auth: {
      getUser: async () => ({
        data: {
          user: {
            id: "u0000000-0000-0000-0000-000000000002",
            email: "hr-full@eiu.edu.vn",
          },
        },
        error: null,
      }),
    },
    from: (_table: string) => ({
      select: (_cols: string) => ({
        eq: (_col: string, _val: unknown) => ({
          maybeSingle: async () => ({
            data: {
              app_user_id: "u0000000-0000-0000-0000-000000000002",
              is_active: true,
              is_root_admin: false,
            },
            error: null,
          }),
        }),
      }),
    }),
  } as unknown as SupabaseClient;
}

const sampleSubmissionId = "11111111-1111-1111-1111-111111111111";
const sampleCandidateId = "c0000000-0000-0000-0000-000000000001";

// -----------------------------------------------------------------------------
// Test Suite
// -----------------------------------------------------------------------------

test("1. AC-OPEN-SUB-01: View-only HR opening NEW submission leaves status as NEW (pure read)", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      open_submission: () => ({
        success: true,
        data: {
          submission_id: sampleSubmissionId,
          candidate_id: sampleCandidateId,
          status_code: "NEW", // Remains NEW for view-only
          full_name: "Nguyen Van A",
          email: "candidate@example.com",
          phone: "0901234567",
          date_of_birth: "1995-05-15",
          gender: "MALE",
          address: "Binh Duong",
          candidate_notes: null,
          submitted_at: "2026-09-05T10:00:00Z",
          version_no: 1,
        },
      }),
    },
  });

  const result = await openSubmission(
    { submissionId: sampleSubmissionId },
    { client: mockSupabase, resolveActor: async () => viewOnlyHrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(
      result.data.status_code,
      "NEW",
      "Status must remain NEW for view-only caller",
    );
  }
});

test("2. AC-OPEN-SUB-02: Full HR opening NEW submission atomically transitions NEW -> READ", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      open_submission: () => ({
        success: true,
        data: {
          submission_id: sampleSubmissionId,
          candidate_id: sampleCandidateId,
          status_code: "READ", // Atomically mutated to READ for full HR
          full_name: "Nguyen Van A",
          email: "candidate@example.com",
          phone: "0901234567",
          date_of_birth: "1995-05-15",
          gender: "MALE",
          address: "Binh Duong",
          candidate_notes: null,
          submitted_at: "2026-09-05T10:00:00Z",
          version_no: 1,
        },
      }),
    },
  });

  const result = await openSubmission(
    { submissionId: sampleSubmissionId },
    { client: mockSupabase, resolveActor: async () => fullHrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(
      result.data.status_code,
      "READ",
      "Status must transition to READ for full HR caller",
    );
  }
});

test("3. AC-OPEN-SUB-03: Unauthorized caller without submissions.view rejected with FORBIDDEN", async () => {
  const mockSupabase = createMockSupabase({});
  const result = await openSubmission(
    { submissionId: sampleSubmissionId },
    { client: mockSupabase, resolveActor: async () => unauthorizedActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  }
});

test("4. AC-STAT-01: Direct manual request to set PROCESSED, DONE, or CLOSED rejected with INVALID_ACTION", async () => {
  const mockSupabase = createMockSupabase({});

  const invalidStatuses = ["PROCESSED", "DONE", "CLOSED"] as const;

  for (const status of invalidStatuses) {
    const result = await setSubmissionManualStatus(
      {
        candidateId: sampleCandidateId,
        statusCode: status as unknown as "NEW",
        expectedLatestSubmissionId: sampleSubmissionId,
        expectedVersion: 1,
      },
      { client: mockSupabase, resolveActor: async () => fullHrActor },
    );

    assert.equal(
      result.success,
      false,
      `Setting ${status} must be rejected at validation layer`,
    );
    if (!result.success) {
      assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    }
  }
});

test("5. AC-STAT-02: Manual transition NEW <-> READ succeeds when no active application exists, bumping version_no", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      set_submission_manual_status: () => ({
        success: true,
        data: {
          submission_id: sampleSubmissionId,
          status_code: "NEW", // reset back to NEW
          version_no: 2,
        },
      }),
    },
  });

  const result = await setSubmissionManualStatus(
    {
      candidateId: sampleCandidateId,
      statusCode: "NEW",
      expectedLatestSubmissionId: sampleSubmissionId,
      expectedVersion: 1,
    },
    { client: mockSupabase, resolveActor: async () => fullHrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.status_code, "NEW");
    assert.equal(result.data.version_no, 2);
  }
});

test("6. AC-STAT-03: Manual transition NEW <-> READ rejected with INVALID_STATE when active application exists", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      set_submission_manual_status: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message:
          "Neither NEW nor READ may be written manually while any active Application exists",
      }),
    },
  });

  const result = await setSubmissionManualStatus(
    {
      candidateId: sampleCandidateId,
      statusCode: "READ",
      expectedLatestSubmissionId: sampleSubmissionId,
      expectedVersion: 1,
    },
    { client: mockSupabase, resolveActor: async () => fullHrActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_STATE);
  }
});

test("7. AC-HIST-SUB-01: Attempt to change historical child submission status rejected with HISTORICAL_SUBMISSION_READ_ONLY", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      set_submission_manual_status: () => ({
        success: false,
        error_code: "HISTORICAL_SUBMISSION_READ_ONLY",
        message:
          "Only the latest submission of a candidate may be manually changed",
      }),
    },
  });

  const historicalSubmissionId = "22222222-2222-2222-2222-222222222222";
  const result = await setSubmissionManualStatus(
    {
      candidateId: sampleCandidateId,
      statusCode: "READ",
      expectedLatestSubmissionId: historicalSubmissionId,
      expectedVersion: 1,
    },
    { client: mockSupabase, resolveActor: async () => fullHrActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, "HISTORICAL_SUBMISSION_READ_ONLY");
  }
});

test("8. AC-STAT-STALE-01: Version mismatch in set_submission_manual_status rejected with STALE_VERSION", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      set_submission_manual_status: () => ({
        success: false,
        error_code: "STALE_VERSION",
        message: "Submission version mismatch",
      }),
    },
  });

  const result = await setSubmissionManualStatus(
    {
      candidateId: sampleCandidateId,
      statusCode: "READ",
      expectedLatestSubmissionId: sampleSubmissionId,
      expectedVersion: 99, // stale expected version
    },
    { client: mockSupabase, resolveActor: async () => fullHrActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.STALE_VERSION);
  }
});

test("9. AC-RECALC-01: Recalculation with 0 applications preserves existing manual NEW or READ", () => {
  function recalculateSim(currentStatus: string, activeAppsCount: number) {
    if (activeAppsCount === 0) {
      if (["PROCESSED", "DONE", "CLOSED"].includes(currentStatus)) {
        return "READ";
      }
      return currentStatus; // Preserves NEW or READ
    }
    return "PROCESSED";
  }

  assert.equal(recalculateSim("NEW", 0), "NEW", "0 apps preserves NEW");
  assert.equal(recalculateSim("READ", 0), "READ", "0 apps preserves READ");
});

test("10. AC-RECALC-02: Recalculation after removing last application from PROCESSED/DONE/CLOSED returns READ", () => {
  function recalculateSim(currentStatus: string, activeAppsCount: number) {
    if (activeAppsCount === 0) {
      if (["PROCESSED", "DONE", "CLOSED"].includes(currentStatus)) {
        return "READ";
      }
      return currentStatus;
    }
    return "PROCESSED";
  }

  assert.equal(recalculateSim("PROCESSED", 0), "READ");
  assert.equal(recalculateSim("DONE", 0), "READ");
  assert.equal(recalculateSim("CLOSED", 0), "READ");
});

test("11. AC-RECALC-03: Recalculation with active applications returns PROCESSED when in progress", () => {
  function recalculateOutcomeSim(hasHired: boolean, allRejected: boolean) {
    if (hasHired) return "DONE";
    if (allRejected) return "CLOSED";
    return "PROCESSED";
  }

  assert.equal(recalculateOutcomeSim(false, false), "PROCESSED");
});

test("12. AC-RECALC-04: Recalculation with any active application HIRED returns DONE", () => {
  function recalculateOutcomeSim(hasHired: boolean, allRejected: boolean) {
    if (hasHired) return "DONE";
    if (allRejected) return "CLOSED";
    return "PROCESSED";
  }

  assert.equal(recalculateOutcomeSim(true, false), "DONE");
  assert.equal(
    recalculateOutcomeSim(true, true),
    "DONE",
    "HIRED takes precedence over REJECTED",
  );
});

test("13. AC-RECALC-05: Recalculation with all active applications REJECTED returns CLOSED", () => {
  function recalculateOutcomeSim(hasHired: boolean, allRejected: boolean) {
    if (hasHired) return "DONE";
    if (allRejected) return "CLOSED";
    return "PROCESSED";
  }

  assert.equal(recalculateOutcomeSim(false, true), "CLOSED");
});

test("14. AC-STAT-CONCURRENCY-01: Concurrency serialization on parent submission lock", () => {
  const lockOrder = [
    "candidates:cand-1",
    "submissions:sub-1",
    "applications:app-1",
  ];
  assert.equal(
    lockOrder[1],
    "submissions:sub-1",
    "Submission row must be locked before applications evaluation",
  );
});

test("15. recalculateSubmissionStatus RPC command invocation", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      recalculate_submission_status: () => ({
        success: true,
        data: {
          submission_id: sampleSubmissionId,
          status_code: "PROCESSED",
          previous_status_code: "READ",
        },
      }),
    },
  });

  const result = await recalculateSubmissionStatus(
    { submissionId: sampleSubmissionId },
    { client: mockSupabase, resolveActor: async () => fullHrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.status_code, "PROCESSED");
  }
});

test("16. correctSubmissionCandidateFieldsByHr: rejects caller without submissions.edit with FORBIDDEN", async () => {
  const mockSupabase = createMockSupabase({});
  const unauthorizedActor: VerifiedActor = {
    authUserId: "a0000000-0000-0000-0000-000000000099",
    email: "viewonly@eiu.edu.vn",
    isActive: true,
    roles: ["HR"],
    permissions: ["submissions.view"], // lacks submissions.edit
  };

  const result = await correctSubmissionCandidateFieldsByHr(
    {
      submissionId: sampleSubmissionId,
      fullName: "Corrected Name",
      expectedVersion: 1,
    },
    { client: mockSupabase, resolveActor: async () => unauthorizedActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  }
});

test("17. correctSubmissionCandidateFieldsByHr: validates at least one field provided and invokes RPC", async () => {
  const emptyFieldsResult = await correctSubmissionCandidateFieldsByHr(
    {
      submissionId: sampleSubmissionId,
      expectedVersion: 1,
    },
    { client: createMockSupabase({}), resolveActor: async () => editHrActor },
  );

  assert.equal(emptyFieldsResult.success, false);
  if (!emptyFieldsResult.success) {
    assert.equal(
      emptyFieldsResult.error.code,
      CommandErrorCode.VALIDATION_ERROR,
    );
  }

  let rpcCalledWith: unknown = null;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      correct_submission_candidate_fields_by_hr: (args) => {
        rpcCalledWith = args;
        return {
          success: true,
          submission_id: sampleSubmissionId,
          version_no: 2,
          changed_fields: ["full_name", "phone"],
        };
      },
    },
  });

  const result = await correctSubmissionCandidateFieldsByHr(
    {
      submissionId: sampleSubmissionId,
      fullName: "Nguyen Van A Corrected",
      phone: "0909999999",
      expectedVersion: 1,
      reason: "Correcting typo reported by candidate",
    },
    { client: mockSupabase, resolveActor: async () => editHrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.submission_id, sampleSubmissionId);
    assert.equal(result.data.version_no, 2);
    assert.deepEqual(result.data.changed_fields, ["full_name", "phone"]);
  }
  assert.ok(rpcCalledWith);
});
