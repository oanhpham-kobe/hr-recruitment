import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type BulkCreateOrUpdateApplicationsInput,
  bulkCreateOrUpdateApplications,
} from "@/lib/commands/application-lifecycle";
import {
  type BulkSetLatestSubmissionManualStatusInput,
  bulkSetLatestSubmissionManualStatus,
} from "@/lib/commands/submission-status";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";

const statusActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000001",
  email: "status@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["submissions.status"],
};

const applicationActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000002",
  email: "applications@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["applications.manage", "submissions.view"],
};

const rootActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000003",
  email: "root@eiu.edu.vn",
  isActive: true,
  roles: ["ROOT_ADMIN"],
  permissions: [],
};

const viewOnlyActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000004",
  email: "view@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["submissions.view"],
};

const manageOnlyActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000005",
  email: "manage@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["applications.manage"],
};

const createOnlyActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000006",
  email: "create@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["applications.create"],
};
const hrOnlyActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000007",
  email: "hr-only@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: [],
};

const candidateOne = "10000000-0000-0000-0000-000000000001";
const candidateTwo = "10000000-0000-0000-0000-000000000002";
const submissionOne = "20000000-0000-0000-0000-000000000001";
const submissionTwo = "20000000-0000-0000-0000-000000000002";
const unitId = "30000000-0000-0000-0000-000000000001";
const positionId = "40000000-0000-0000-0000-000000000001";
const hrOwnerId = "50000000-0000-0000-0000-000000000001";
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

const bulkStatusInput: BulkSetLatestSubmissionManualStatusInput = {
  items: [
    {
      candidateId: candidateTwo,
      expectedLatestSubmissionId: submissionTwo,
      expectedVersion: 4,
    },
    {
      candidateId: candidateOne,
      expectedLatestSubmissionId: submissionOne,
      expectedVersion: 2,
    },
  ],
  statusCode: "READ",
  idempotencyKey,
};

const bulkApplicationInput: BulkCreateOrUpdateApplicationsInput = {
  submissionIds: [submissionTwo, submissionOne],
  unitId,
  departmentTeamId: null,
  positionId,
  hrOwnerId,
  idempotencyKey,
};

test("bulk latest status forwards an input-ordered selection and returns the RPC pairing", async () => {
  const { client, calls } = createMockSupabase({
    bulk_set_latest_submission_manual_status: () => ({
      success: true,
      data: {
        items: [
          {
            candidate_id: candidateTwo,
            submission_id: submissionTwo,
            status_code: "READ",
            version_no: 5,
          },
          {
            candidate_id: candidateOne,
            submission_id: submissionOne,
            status_code: "READ",
            version_no: 3,
          },
        ],
        count: 2,
        idempotency_key: idempotencyKey,
      },
    }),
  });

  const result = await bulkSetLatestSubmissionManualStatus(bulkStatusInput, {
    client,
    resolveActor: async () => statusActor,
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.deepEqual(
      result.data.items.map((item) => item.candidate_id),
      [candidateTwo, candidateOne],
    );
    assert.equal(result.data.items[0]?.version_no, 5);
  }
  assert.deepEqual(calls, [
    {
      fn: "bulk_set_latest_submission_manual_status",
      args: {
        p_candidate_ids: [candidateTwo, candidateOne],
        p_status_code: "READ",
        p_expected_latest_submission_ids: [submissionTwo, submissionOne],
        p_expected_versions: [4, 2],
        p_idempotency_key: idempotencyKey,
      },
    },
  ]);
});
test("bulk latest status permits Root Admin", async () => {
  const { client, calls } = createMockSupabase({
    bulk_set_latest_submission_manual_status: () => ({
      success: true,
      data: {
        items: [
          {
            candidate_id: candidateTwo,
            submission_id: submissionTwo,
            status_code: "READ",
            version_no: 5,
          },
          {
            candidate_id: candidateOne,
            submission_id: submissionOne,
            status_code: "READ",
            version_no: 3,
          },
        ],
        count: 2,
        idempotency_key: idempotencyKey,
      },
    }),
  });

  const result = await bulkSetLatestSubmissionManualStatus(bulkStatusInput, {
    client,
    resolveActor: async () => rootActor,
  });

  assert.equal(result.success, true);
  assert.equal(calls.length, 1);
});

test("bulk wrappers deny an HR-role-only actor", async () => {
  const statusClient = createMockSupabase({});
  const statusResult = await bulkSetLatestSubmissionManualStatus(
    bulkStatusInput,
    {
      client: statusClient.client,
      resolveActor: async () => hrOnlyActor,
    },
  );
  assert.equal(statusResult.success, false);
  if (!statusResult.success)
    assert.equal(statusResult.error.code, CommandErrorCode.FORBIDDEN);
  assert.equal(statusClient.calls.length, 0);

  const applicationClient = createMockSupabase({});
  const applicationResult = await bulkCreateOrUpdateApplications(
    bulkApplicationInput,
    {
      client: applicationClient.client,
      resolveActor: async () => hrOnlyActor,
    },
  );
  assert.equal(applicationResult.success, false);
  if (!applicationResult.success)
    assert.equal(applicationResult.error.code, CommandErrorCode.FORBIDDEN);
  assert.equal(applicationClient.calls.length, 0);
});

test("bulk latest status denies a view-only actor before malformed input validation", async () => {
  const { client, calls } = createMockSupabase({});
  const result = await bulkSetLatestSubmissionManualStatus(
    { ...bulkStatusInput, items: [] },
    { client, resolveActor: async () => viewOnlyActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  }
  assert.equal(calls.length, 0);
});

test("bulk latest status rejects duplicate candidates and maps atomic RPC failures", async () => {
  const duplicateClient = createMockSupabase({});
  const duplicateResult = await bulkSetLatestSubmissionManualStatus(
    {
      ...bulkStatusInput,
      items: [
        {
          candidateId: candidateTwo,
          expectedLatestSubmissionId: submissionTwo,
          expectedVersion: 4,
        },
        {
          candidateId: candidateTwo,
          expectedLatestSubmissionId: submissionTwo,
          expectedVersion: 4,
        },
      ],
    },
    { client: duplicateClient.client, resolveActor: async () => statusActor },
  );
  assert.equal(duplicateResult.success, false);
  if (!duplicateResult.success) {
    assert.equal(duplicateResult.error.code, CommandErrorCode.VALIDATION_ERROR);
  }
  assert.equal(duplicateClient.calls.length, 0);

  const staleClient = createMockSupabase({
    bulk_set_latest_submission_manual_status: () => ({
      success: false,
      error_code: "STALE_VERSION",
      message: "Latest Submission identity or version changed",
    }),
  });
  const staleResult = await bulkSetLatestSubmissionManualStatus(
    bulkStatusInput,
    {
      client: staleClient.client,
      resolveActor: async () => statusActor,
    },
  );
  assert.equal(staleResult.success, false);
  if (!staleResult.success) {
    assert.equal(staleResult.error.code, CommandErrorCode.STALE_VERSION);
  }
});

test("bulk application assignment forwards exact submissions and exposes created default rounds", async () => {
  const { client, calls } = createMockSupabase({
    bulk_create_or_update_applications: () => ({
      success: true,
      data: {
        items: [
          {
            submission_id: submissionTwo,
            application_id: "70000000-0000-0000-0000-000000000002",
            action: "CREATED",
            version_no: 1,
            round1_interview_id: "80000000-0000-0000-0000-000000000002",
          },
          {
            submission_id: submissionOne,
            application_id: "70000000-0000-0000-0000-000000000001",
            action: "UPDATED",
            version_no: 3,
            round1_interview_id: "80000000-0000-0000-0000-000000000001",
          },
        ],
        count: 2,
        idempotency_key: idempotencyKey,
      },
    }),
  });

  const result = await bulkCreateOrUpdateApplications(bulkApplicationInput, {
    client,
    resolveActor: async () => applicationActor,
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.deepEqual(
      result.data.items.map((item) => item.submission_id),
      [submissionTwo, submissionOne],
    );
    assert.equal(
      result.data.items[0]?.round1_interview_id,
      "80000000-0000-0000-0000-000000000002",
    );
  }
  assert.deepEqual(calls, [
    {
      fn: "bulk_create_or_update_applications",
      args: {
        p_submission_ids: [submissionTwo, submissionOne],
        p_unit_id: unitId,
        p_department_team_id: null,
        p_position_id: positionId,
        p_hr_owner_id: hrOwnerId,
        p_idempotency_key: idempotencyKey,
      },
    },
  ]);
});

test("bulk application assignment requires both permissions or Root Admin", async () => {
  for (const actor of [viewOnlyActor, manageOnlyActor, createOnlyActor]) {
    const { client, calls } = createMockSupabase({});
    const result = await bulkCreateOrUpdateApplications(bulkApplicationInput, {
      client,
      resolveActor: async () => actor,
    });
    assert.equal(result.success, false);
    if (!result.success) {
      assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
    }
    assert.equal(calls.length, 0);
  }

  const rootClient = createMockSupabase({
    bulk_create_or_update_applications: () => ({
      success: true,
      data: { items: [], count: 0, idempotency_key: idempotencyKey },
    }),
  });
  const rootResult = await bulkCreateOrUpdateApplications(
    bulkApplicationInput,
    {
      client: rootClient.client,
      resolveActor: async () => rootActor,
    },
  );
  assert.equal(rootResult.success, true);
  assert.equal(rootClient.calls.length, 1);
});

test("bulk application assignment rejects malformed selections and maps inactive identity failures", async () => {
  const duplicateClient = createMockSupabase({});
  const duplicateResult = await bulkCreateOrUpdateApplications(
    { ...bulkApplicationInput, submissionIds: [submissionOne, submissionOne] },
    {
      client: duplicateClient.client,
      resolveActor: async () => applicationActor,
    },
  );
  assert.equal(duplicateResult.success, false);
  if (!duplicateResult.success) {
    assert.equal(duplicateResult.error.code, CommandErrorCode.VALIDATION_ERROR);
  }
  assert.equal(duplicateClient.calls.length, 0);

  const inactiveClient = createMockSupabase({
    bulk_create_or_update_applications: () => ({
      success: false,
      error_code: "ALREADY_EXISTS_INACTIVE",
      message:
        "An inactive Application already exists for a selected durable identity",
    }),
  });
  const inactiveResult = await bulkCreateOrUpdateApplications(
    bulkApplicationInput,
    {
      client: inactiveClient.client,
      resolveActor: async () => applicationActor,
    },
  );
  assert.equal(inactiveResult.success, false);
  if (!inactiveResult.success) {
    assert.equal(
      inactiveResult.error.code,
      CommandErrorCode.ALREADY_EXISTS_INACTIVE,
    );
  }
});
