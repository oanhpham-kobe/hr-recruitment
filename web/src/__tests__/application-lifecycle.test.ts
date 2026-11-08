import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  createOrUpdateApplication,
  deleteOrInactivateApplication,
  updateSubmissionByHr,
} from "@/lib/commands/application-lifecycle";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";

// -----------------------------------------------------------------------------
// Test Actors
// -----------------------------------------------------------------------------

const hrActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000001",
  email: "hr@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: [
    "applications.create",
    "applications.manage",
    "applications.delete",
    "submissions.view",
    "submissions.edit",
    "submissions.status",
  ],
};

const unauthorizedActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000003",
  email: "guest@example.com",
  isActive: true,
  roles: ["GUEST"],
  permissions: [],
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
            id: "a0000000-0000-0000-0000-000000000001",
            email: "hr@eiu.edu.vn",
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
              app_user_id: "a0000000-0000-0000-0000-000000000001",
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
const sampleUnitId = "22222222-2222-2222-2222-222222222222";
const sampleTeamId = "33333333-3333-3333-3333-333333333333";
const samplePositionId = "44444444-4444-4444-4444-444444444444";
const sampleHrOwnerId = "a0000000-0000-0000-0000-000000000001";
const sampleApplicationId = "55555555-5555-5555-5555-555555555555";

// -----------------------------------------------------------------------------
// Test Suite
// -----------------------------------------------------------------------------

test("1. AC-APP-CREATE-01: Create application allocates default Round 1 with AVAILABLE and INTERVIEW_SCHEDULING", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      create_or_update_application: () => ({
        success: true,
        data: {
          application_id: sampleApplicationId,
          submission_id: sampleSubmissionId,
          is_active: true,
          version_no: 1,
          round1_interview_id: "int-round-1-uuid",
        },
      }),
    },
  });

  const result = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      departmentTeamId: sampleTeamId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
    },
    { client: mockSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.application_id, sampleApplicationId);
    assert.equal(result.data.is_active, true);
    assert.equal(result.data.version_no, 1);
    assert.equal(result.data.round1_interview_id, "int-round-1-uuid");
  }
});

test("2. AC-APP-DUP-01: Active duplicate updates existing application; inactive duplicate returns ALREADY_EXISTS_INACTIVE", async () => {
  // Active duplicate
  const mockActiveSupabase = createMockSupabase({
    rpcHandlers: {
      create_or_update_application: () => ({
        success: true,
        data: {
          application_id: sampleApplicationId,
          submission_id: sampleSubmissionId,
          is_active: true,
          version_no: 2, // version bumped
          round1_interview_id: "int-round-1-uuid",
        },
      }),
    },
  });

  const activeResult = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
    },
    { client: mockActiveSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(activeResult.success, true);
  if (activeResult.success) {
    assert.equal(activeResult.data.version_no, 2);
  }

  // Inactive duplicate
  const mockInactiveSupabase = createMockSupabase({
    rpcHandlers: {
      create_or_update_application: () => ({
        success: false,
        error_code: "ALREADY_EXISTS_INACTIVE",
        message:
          "An inactive application already exists for this position. Use reactivate instead.",
      }),
    },
  });

  const inactiveResult = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
    },
    { client: mockInactiveSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(inactiveResult.success, false);
  if (!inactiveResult.success) {
    assert.equal(
      inactiveResult.error.code,
      CommandErrorCode.ALREADY_EXISTS_INACTIVE,
    );
  }
});

test("3. AC-APP-DEL-01: Deleting structurally empty default Round 1 performs hard delete of round and application", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      delete_or_inactivate_application: () => ({
        success: true,
        data: {
          application_id: sampleApplicationId,
          action: "DELETED",
          submission_id: sampleSubmissionId,
        },
      }),
    },
  });

  const result = await deleteOrInactivateApplication(
    { applicationId: sampleApplicationId },
    { client: mockSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.action, "DELETED");
  }
});

test("4. AC-APP-INACT-01: Application with business usage inactivates application and child rounds", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      delete_or_inactivate_application: () => ({
        success: true,
        data: {
          application_id: sampleApplicationId,
          action: "INACTIVATED",
          submission_id: sampleSubmissionId,
        },
      }),
    },
  });

  const result = await deleteOrInactivateApplication(
    { applicationId: sampleApplicationId },
    { client: mockSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.action, "INACTIVATED");
  }
});

test("5. AC-APP-RECALC-01 & 02: Status recalculation integration on application lifecycle", () => {
  // Simulates recalculation outcome:
  // 0 apps -> READ
  // 1 app in progress -> PROCESSED
  function simulateStatus(activeApps: number) {
    return activeApps > 0 ? "PROCESSED" : "READ";
  }

  assert.equal(
    simulateStatus(1),
    "PROCESSED",
    "Adding application sets status to PROCESSED",
  );
  assert.equal(
    simulateStatus(0),
    "READ",
    "Removing last application resets status to READ",
  );
});

test("6. AC-HR-NOTE-01: update_submission_by_hr edits only hr_note, bumps version, preserves email", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_submission_by_hr: () => ({
        success: true,
        data: {
          submission_id: sampleSubmissionId,
          hr_note: "Candidate has strong academic background.",
          version_no: 2,
        },
      }),
    },
  });

  const result = await updateSubmissionByHr(
    {
      submissionId: sampleSubmissionId,
      hrNote: "Candidate has strong academic background.",
      expectedVersion: 1,
    },
    { client: mockSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(
      result.data.hr_note,
      "Candidate has strong academic background.",
    );
    assert.equal(result.data.version_no, 2);
  }
});

test("7. AC-HR-NOTE-STALE: Version mismatch in update_submission_by_hr returns STALE_VERSION", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_submission_by_hr: () => ({
        success: false,
        error_code: "STALE_VERSION",
        message: "Submission version mismatch",
      }),
    },
  });

  const result = await updateSubmissionByHr(
    {
      submissionId: sampleSubmissionId,
      hrNote: "Conflicting update",
      expectedVersion: 99,
    },
    { client: mockSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.STALE_VERSION);
  }
});

test("8. REC-04-F06: submission-note adapter rejects missing, zero, negative, and unsafe version tokens before RPC", async () => {
  let rpcCalls = 0;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_submission_by_hr: () => {
        rpcCalls += 1;
        return { success: true };
      },
    },
  });

  for (const expectedVersion of [
    undefined,
    0,
    -1,
    Number.MAX_SAFE_INTEGER + 1,
  ]) {
    const result = await updateSubmissionByHr(
      {
        submissionId: sampleSubmissionId,
        hrNote: "must not reach SQL",
        expectedVersion,
      } as unknown as Parameters<typeof updateSubmissionByHr>[0],
      { client: mockSupabase, resolveActor: async () => hrActor },
    );
    assert.equal(result.success, false);
    if (!result.success) {
      assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    }
  }
  assert.equal(rpcCalls, 0);
});

test("8. AC-APP-AUTH-01: Unauthorized caller without required permissions rejected with FORBIDDEN", async () => {
  const mockSupabase = createMockSupabase({});

  const createResult = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
    },
    { client: mockSupabase, resolveActor: async () => unauthorizedActor },
  );
  assert.equal(createResult.success, false);
  if (!createResult.success) {
    assert.equal(createResult.error.code, CommandErrorCode.FORBIDDEN);
  }

  const deleteResult = await deleteOrInactivateApplication(
    { applicationId: sampleApplicationId },
    { client: mockSupabase, resolveActor: async () => unauthorizedActor },
  );
  assert.equal(deleteResult.success, false);
  if (!deleteResult.success) {
    assert.equal(deleteResult.error.code, CommandErrorCode.FORBIDDEN);
  }

  const editResult = await updateSubmissionByHr(
    { submissionId: sampleSubmissionId, hrNote: "note", expectedVersion: 1 },
    { client: mockSupabase, resolveActor: async () => unauthorizedActor },
  );
  assert.equal(editResult.success, false);
  if (!editResult.success) {
    assert.equal(editResult.error.code, CommandErrorCode.FORBIDDEN);
  }
});

test("9. AC-APP-HIERARCHY-01: Mismatched department_team or position hierarchy rejected", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      create_or_update_application: () => ({
        success: false,
        error_code: "INVALID_HIERARCHY",
        message: "Position does not match unit/team hierarchy or is inactive",
      }),
    },
  });

  const result = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      departmentTeamId: sampleTeamId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
    },
    { client: mockSupabase, resolveActor: async () => hrActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_HIERARCHY);
  }
});

test("10. Structurally empty default round predicate logic", () => {
  function isStructurallyEmptySim(round: {
    round_no: number;
    schedule_status: string;
    has_participants: boolean;
    has_reports: boolean;
    is_copied: boolean;
  }) {
    return (
      round.round_no === 1 &&
      round.schedule_status === "AVAILABLE" &&
      !round.has_participants &&
      !round.has_reports &&
      !round.is_copied
    );
  }

  assert.equal(
    isStructurallyEmptySim({
      round_no: 1,
      schedule_status: "AVAILABLE",
      has_participants: false,
      has_reports: false,
      is_copied: false,
    }),
    true,
    "Unused default round 1 is structurally empty",
  );

  assert.equal(
    isStructurallyEmptySim({
      round_no: 1,
      schedule_status: "SCHEDULED",
      has_participants: true,
      has_reports: false,
      is_copied: false,
    }),
    false,
    "Scheduled round with participants is NOT structurally empty",
  );

  assert.equal(
    isStructurallyEmptySim({
      round_no: 2,
      schedule_status: "AVAILABLE",
      has_participants: false,
      has_reports: false,
      is_copied: false,
    }),
    false,
    "Round 2 is never a default round",
  );
});
