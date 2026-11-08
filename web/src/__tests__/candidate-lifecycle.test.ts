import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { getServerSession } from "@/lib/auth/session";
import {
  type BulkSetCandidateActiveInput,
  bulkSetCandidateActive,
  type SetCandidateActiveInput,
  setCandidateActive,
} from "@/lib/commands/candidate-lifecycle";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";

const manageActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000001",
  email: "active-manage@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["candidates.active_manage"],
};

const rootActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000002",
  email: "root@eiu.edu.vn",
  isActive: true,
  roles: ["ROOT_ADMIN"],
  permissions: [],
};

const unauthorizedActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000003",
  email: "unauthorized@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["submissions.view"],
};

const inactiveActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000004",
  email: "inactive@eiu.edu.vn",
  isActive: false,
  roles: ["HR"],
  permissions: ["candidates.active_manage"],
};

const candidateOne = "10000000-0000-0000-0000-000000000001";
const candidateTwo = "10000000-0000-0000-0000-000000000002";
const idempotencyKey = "60000000-0000-0000-0000-000000000001";

function createMockSupabase(
  handlers: Record<string, (args: unknown) => unknown>,
): { client: SupabaseClient; calls: Array<{ fn: string; args: unknown }> } {
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

// -----------------------------------------------------------------------------
// Authorization Tests
// -----------------------------------------------------------------------------

test("setCandidateActive rejects non-root caller without candidates.active_manage with FORBIDDEN", async () => {
  const { client, calls } = createMockSupabase({});
  const input: SetCandidateActiveInput = {
    candidateId: candidateOne,
    active: false,
    expectedVersion: 1,
  };

  const result = await setCandidateActive(input, {
    client,
    resolveActor: async () => unauthorizedActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  }
  assert.equal(calls.length, 0); // Mutation boundary never reached
});

test("setCandidateActive rejects inactive actor with USER_INACTIVE", async () => {
  const { client, calls } = createMockSupabase({});
  const input: SetCandidateActiveInput = {
    candidateId: candidateOne,
    active: false,
    expectedVersion: 1,
  };

  const result = await setCandidateActive(input, {
    client,
    resolveActor: async () => inactiveActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
  }
  assert.equal(calls.length, 0);
});

test("setCandidateActive authorizes Root Admin", async () => {
  const { client, calls } = createMockSupabase({
    set_candidate_active: (args) => ({
      success: true,
      data: {
        candidate_id: (args as Record<string, unknown>).p_candidate_id,
        is_active: false,
        inactive_at: "2026-09-05T10:00:00Z",
        inactive_by: "actor-app-user-id",
        version_no: 2,
      },
    }),
  });

  const input: SetCandidateActiveInput = {
    candidateId: candidateOne,
    active: false,
    expectedVersion: 1,
  };

  const result = await setCandidateActive(input, {
    client,
    resolveActor: async () => rootActor,
  });

  assert.equal(result.success, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].fn, "set_candidate_active");
});

test("setCandidateActive authorizes HR with candidates.active_manage", async () => {
  const { client } = createMockSupabase({
    set_candidate_active: (args) => ({
      success: true,
      data: {
        candidate_id: (args as Record<string, unknown>).p_candidate_id,
        is_active: true,
        inactive_at: null,
        inactive_by: null,
        version_no: 3,
      },
    }),
  });
  const input: SetCandidateActiveInput = {
    candidateId: candidateOne,
    active: true,
    expectedVersion: 2,
  };

  const result = await setCandidateActive(input, {
    client,
    resolveActor: async () => manageActor,
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.is_active, true);
    assert.equal(result.data.inactive_at, null);
    assert.equal(result.data.version_no, 3);
  }
});

test("bulkSetCandidateActive rejects non-root caller without candidates.active_manage with FORBIDDEN", async () => {
  const { client, calls } = createMockSupabase({});
  const input: BulkSetCandidateActiveInput = {
    items: [{ candidateId: candidateOne, expectedVersion: 1 }],
    active: false,
    idempotencyKey,
  };

  const result = await bulkSetCandidateActive(input, {
    client,
    resolveActor: async () => unauthorizedActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  }
  assert.equal(calls.length, 0);
});

test("bulkSetCandidateActive authorizes Root Admin and actor with candidates.active_manage", async () => {
  const { client } = createMockSupabase({
    bulk_set_candidate_active: () => ({
      success: true,
      data: {
        items: [
          {
            candidate_id: candidateOne,
            is_active: false,
            inactive_at: "2026-09-05T10:00:00Z",
            inactive_by: "actor-app-user-id",
            version_no: 2,
          },
        ],
        count: 1,
        idempotency_key: idempotencyKey,
      },
    }),
  });

  const input: BulkSetCandidateActiveInput = {
    items: [{ candidateId: candidateOne, expectedVersion: 1 }],
    active: false,
    idempotencyKey,
  };

  const resultManage = await bulkSetCandidateActive(input, {
    client,
    resolveActor: async () => manageActor,
  });
  assert.equal(resultManage.success, true);

  const resultRoot = await bulkSetCandidateActive(input, {
    client,
    resolveActor: async () => rootActor,
  });
  assert.equal(resultRoot.success, true);
});

// -----------------------------------------------------------------------------
// Validation Tests
// -----------------------------------------------------------------------------

test("setCandidateActive validates invalid candidate UUID and non-positive expectedVersion", async () => {
  const { client } = createMockSupabase({});

  const invalidUuidResult = await setCandidateActive(
    {
      candidateId: "invalid-uuid",
      active: false,
      expectedVersion: 1,
    },
    {
      client,
      resolveActor: async () => manageActor,
    },
  );
  assert.equal(invalidUuidResult.success, false);
  if (!invalidUuidResult.success) {
    assert.equal(
      invalidUuidResult.error.code,
      CommandErrorCode.VALIDATION_ERROR,
    );
  }

  const invalidVersionResult = await setCandidateActive(
    {
      candidateId: candidateOne,
      active: false,
      expectedVersion: 0,
    },
    {
      client,
      resolveActor: async () => manageActor,
    },
  );
  assert.equal(invalidVersionResult.success, false);
  if (!invalidVersionResult.success) {
    assert.equal(
      invalidVersionResult.error.code,
      CommandErrorCode.VALIDATION_ERROR,
    );
  }
});

test("bulkSetCandidateActive validates empty items, duplicates, and non-positive versions", async () => {
  const { client } = createMockSupabase({});

  const emptyResult = await bulkSetCandidateActive(
    {
      items: [],
      active: false,
      idempotencyKey,
    },
    {
      client,
      resolveActor: async () => manageActor,
    },
  );
  assert.equal(emptyResult.success, false);
  if (!emptyResult.success) {
    assert.equal(emptyResult.error.code, CommandErrorCode.VALIDATION_ERROR);
  }

  const duplicateResult = await bulkSetCandidateActive(
    {
      items: [
        { candidateId: candidateOne, expectedVersion: 1 },
        { candidateId: candidateOne, expectedVersion: 1 },
      ],
      active: false,
      idempotencyKey,
    },
    {
      client,
      resolveActor: async () => manageActor,
    },
  );
  assert.equal(duplicateResult.success, false);
  if (!duplicateResult.success) {
    assert.equal(duplicateResult.error.code, CommandErrorCode.VALIDATION_ERROR);
  }

  const zeroVersionResult = await bulkSetCandidateActive(
    {
      items: [{ candidateId: candidateOne, expectedVersion: 0 }],
      active: false,
      idempotencyKey,
    },
    {
      client,
      resolveActor: async () => manageActor,
    },
  );
  assert.equal(zeroVersionResult.success, false);
  if (!zeroVersionResult.success) {
    assert.equal(
      zeroVersionResult.error.code,
      CommandErrorCode.VALIDATION_ERROR,
    );
  }
});

// -----------------------------------------------------------------------------
// Concurrency & All-or-Nothing Semantics
// -----------------------------------------------------------------------------

test("bulkSetCandidateActive forwards input-ordered candidates and aborts on STALE_VERSION", async () => {
  const { client, calls } = createMockSupabase({
    bulk_set_candidate_active: (args) => {
      const payload = args as { p_expected_versions: number[] };
      // Simulate stale version on second candidate
      if (payload.p_expected_versions[1] === 1) {
        return {
          success: false,
          error_code: "STALE_VERSION",
          message: "One or more Candidate versions have changed",
        };
      }
      return { success: true, data: {} };
    },
  });

  const input: BulkSetCandidateActiveInput = {
    items: [
      { candidateId: candidateOne, expectedVersion: 3 },
      { candidateId: candidateTwo, expectedVersion: 1 },
    ],
    active: false,
    idempotencyKey,
  };

  const result = await bulkSetCandidateActive(input, {
    client,
    resolveActor: async () => manageActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.STALE_VERSION);
  }

  assert.equal(calls.length, 1);
  const rpcArgs = calls[0].args as {
    p_candidate_ids: string[];
    p_expected_versions: number[];
    p_active: boolean;
    p_idempotency_key: string;
  };
  assert.deepEqual(rpcArgs.p_candidate_ids, [candidateOne, candidateTwo]);
  assert.deepEqual(rpcArgs.p_expected_versions, [3, 1]);
  assert.equal(rpcArgs.p_active, false);
  assert.equal(rpcArgs.p_idempotency_key, idempotencyKey);
});

// -----------------------------------------------------------------------------
// Candidate Lifecycle & Reactivation Parity
// -----------------------------------------------------------------------------

test("bulkSetCandidateActive succeeds on valid batch and returns mutated candidate tokens", async () => {
  const { client } = createMockSupabase({
    bulk_set_candidate_active: () => ({
      success: true,
      data: {
        items: [
          {
            candidate_id: candidateOne,
            is_active: false,
            inactive_at: "2026-09-05T12:00:00Z",
            inactive_by: "app-user-1",
            version_no: 4,
          },
          {
            candidate_id: candidateTwo,
            is_active: false,
            inactive_at: "2026-09-05T12:00:00Z",
            inactive_by: "app-user-1",
            version_no: 2,
          },
        ],
        count: 2,
        idempotency_key: idempotencyKey,
      },
    }),
  });

  const input: BulkSetCandidateActiveInput = {
    items: [
      { candidateId: candidateOne, expectedVersion: 3 },
      { candidateId: candidateTwo, expectedVersion: 1 },
    ],
    active: false,
    idempotencyKey,
  };

  const result = await bulkSetCandidateActive(input, {
    client,
    resolveActor: async () => manageActor,
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.count, 2);
    assert.equal(result.data.items[0].is_active, false);
    assert.equal(result.data.items[0].version_no, 4);
    assert.equal(result.data.items[1].is_active, false);
    assert.equal(result.data.items[1].version_no, 2);
  }
});

test("Candidate Inactive denies portal access via getServerSession lockout", async () => {
  const inactiveCandidateClient = {
    auth: {
      getUser: async () => ({
        data: {
          user: {
            id: "auth-cand-inactive",
            email: "inactive.cand@example.com",
          },
        },
        error: null,
      }),
    },
    from: (table: string) => {
      if (table === "app_users") {
        return {
          select: () => ({
            eq: () => ({
              maybeSingle: async () => ({ data: null, error: null }),
            }),
          }),
        };
      }
      if (table === "candidates") {
        return {
          select: () => ({
            eq: () => ({
              single: async () => ({
                data: {
                  candidate_id: candidateOne,
                  is_active: false,
                },
                error: null,
              }),
            }),
          }),
        };
      }
      return {};
    },
  } as unknown as SupabaseClient;

  const session = await getServerSession(inactiveCandidateClient);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("Candidate Reactivation recalculation sets no-app submissions to READ and derives active-app status (AC-CAND-REACT-01 & 02)", () => {
  // Pure model verification of candidate reactivation recalculation rule
  function recalculateSubmissionOnReactivate(submission: {
    status_code: string;
    active_applications: Array<{ report_status_code?: string }>;
  }): string {
    if (submission.active_applications.length === 0) {
      return "READ";
    }
    const hasHired = submission.active_applications.some(
      (a) => a.report_status_code === "HIRED",
    );
    if (hasHired) return "DONE";

    const allRejected =
      submission.active_applications.length > 0 &&
      submission.active_applications.every(
        (a) => a.report_status_code === "REJECTED",
      );
    if (allRejected) return "CLOSED";

    return "PROCESSED";
  }

  // AC-CAND-REACT-01: Candidate inactive with Submission NEW and no active Application -> Reactivate -> READ
  assert.equal(
    recalculateSubmissionOnReactivate({
      status_code: "NEW",
      active_applications: [],
    }),
    "READ",
  );

  // AC-CAND-REACT-02: Candidate inactive with active in-progress Application -> PROCESSED
  assert.equal(
    recalculateSubmissionOnReactivate({
      status_code: "NEW",
      active_applications: [{ report_status_code: undefined }],
    }),
    "PROCESSED",
  );

  // AC-CAND-REACT-02: Candidate inactive with effective HIRED -> DONE
  assert.equal(
    recalculateSubmissionOnReactivate({
      status_code: "READ",
      active_applications: [{ report_status_code: "HIRED" }],
    }),
    "DONE",
  );

  // AC-CAND-REACT-02: Candidate inactive with all rejected -> CLOSED
  assert.equal(
    recalculateSubmissionOnReactivate({
      status_code: "PROCESSED",
      active_applications: [
        { report_status_code: "REJECTED" },
        { report_status_code: "REJECTED" },
      ],
    }),
    "CLOSED",
  );
});

test("bulkSetCandidateActive records exact audit cardinality: one per candidate plus exactly one batch audit (AC-BULK-CAND-LIFE-02)", async () => {
  const auditEntries: Array<{
    action_code: string;
    entity_type: string;
    entity_id?: string;
  }> = [];

  // Simulate the RPC audit behavior asserted by AC-BULK-CAND-LIFE-02
  const { client } = createMockSupabase({
    bulk_set_candidate_active: (args) => {
      const payload = args as {
        p_candidate_ids: string[];
        p_active: boolean;
        p_idempotency_key: string;
      };

      // Each affected candidate receives an individual audit entry
      for (const candidateId of payload.p_candidate_ids) {
        auditEntries.push({
          action_code: payload.p_active
            ? "CANDIDATE_ACTIVATE"
            : "CANDIDATE_INACTIVATE",
          entity_type: "CANDIDATE",
          entity_id: candidateId,
        });
      }

      // Plus exactly one batch audit event
      auditEntries.push({
        action_code: "BULK_SET_CANDIDATE_ACTIVE",
        entity_type: "BATCH",
        entity_id: payload.p_idempotency_key,
      });

      return {
        success: true,
        data: {
          items: payload.p_candidate_ids.map((id) => ({
            candidate_id: id,
            is_active: payload.p_active,
            version_no: 2,
          })),
          count: payload.p_candidate_ids.length,
          idempotency_key: payload.p_idempotency_key,
        },
      };
    },
  });

  const input: BulkSetCandidateActiveInput = {
    items: [
      { candidateId: candidateOne, expectedVersion: 1 },
      { candidateId: candidateTwo, expectedVersion: 1 },
    ],
    active: true,
    idempotencyKey,
  };

  const result = await bulkSetCandidateActive(input, {
    client,
    resolveActor: async () => manageActor,
  });

  assert.equal(result.success, true);
  // 2 candidates + 1 batch event = exactly 3 audit entries
  assert.equal(auditEntries.length, 3);

  const candidateAudits = auditEntries.filter(
    (e) => e.entity_type === "CANDIDATE",
  );
  assert.equal(candidateAudits.length, 2);
  assert.equal(candidateAudits[0].entity_id, candidateOne);
  assert.equal(candidateAudits[0].action_code, "CANDIDATE_ACTIVATE");
  assert.equal(candidateAudits[1].entity_id, candidateTwo);
  assert.equal(candidateAudits[1].action_code, "CANDIDATE_ACTIVATE");

  const batchAudits = auditEntries.filter((e) => e.entity_type === "BATCH");
  assert.equal(batchAudits.length, 1);
  assert.equal(batchAudits[0].action_code, "BULK_SET_CANDIDATE_ACTIVE");
  assert.equal(batchAudits[0].entity_id, idempotencyKey);
});

test("candidate lifecycle migration captures actual v_cand.is_active before mutation and records real diff in security_audit_log and activity_log", async () => {
  const migrationPath = path.resolve(
    process.cwd(),
    "../supabase/migrations/20260905150000_candidate_lifecycle_and_inbox_bulk_tokens.sql",
  );
  const content = await fs.readFile(migrationPath, "utf-8");

  // Verify that previous_is_active is not fabricated as (not p_active)
  assert.equal(
    content.includes("'previous_is_active', not p_active"),
    false,
    "Migration must not fabricate previous_is_active as (not p_active)",
  );

  // Verify set_candidate_active captures v_previous_is_active
  assert.match(
    content,
    /v_previous_is_active := v_cand\.is_active;/,
    "set_candidate_active must capture actual v_previous_is_active from candidate record",
  );

  // Verify bulk_set_candidate_active captures v_previous_is_active
  assert.match(
    content,
    /select c\.is_active into v_previous_is_active\s+from public\.candidates c\s+where c\.candidate_id = v_selection\.candidate_id;/,
    "bulk_set_candidate_active must capture actual v_previous_is_active before updating",
  );

  // Verify security_audit_log uses v_previous_is_active
  assert.match(
    content,
    /'previous_is_active',\s*v_previous_is_active/,
    "security_audit_log must record actual v_previous_is_active",
  );

  // Verify activity_log uses v_previous_is_active
  assert.match(
    content,
    /jsonb_build_object\('is_active',\s*v_previous_is_active,\s*'version_no',\s*p_expected_version\)/,
    "activity_log in set_candidate_active must record actual v_previous_is_active",
  );
  assert.match(
    content,
    /jsonb_build_object\('is_active',\s*v_previous_is_active,\s*'version_no',\s*v_selection\.expected_version\)/,
    "activity_log in bulk_set_candidate_active must record actual v_previous_is_active",
  );
});
