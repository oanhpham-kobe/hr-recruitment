import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type CandidateIdentity,
  provisionCandidateIdentity,
} from "@/lib/auth/candidate";
import { CommandErrorCode } from "@/lib/commands/types";

function createMockSupabaseClient(rpcResult: {
  data: unknown;
  error: { message: string } | null;
}) {
  return {
    rpc: async (fnName: string) => {
      assert.equal(fnName, "provision_candidate_identity");
      return rpcResult;
    },
  } as unknown as SupabaseClient;
}

test("provisionCandidateIdentity: rejects unauthenticated caller with UNAUTHENTICATED", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "UNAUTHENTICATED",
      message: "Authentication required",
    },
    error: null,
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
    assert.equal(result.error.message, "Authentication required");
  }
});

test("provisionCandidateIdentity: rejects missing verified email with UNAUTHENTICATED", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "UNAUTHENTICATED",
      message: "Verified email required",
    },
    error: null,
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
    assert.equal(result.error.message, "Verified email required");
  }
});

test("provisionCandidateIdentity: rejects inactive candidate with USER_INACTIVE", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "USER_INACTIVE",
      message: "Candidate account is inactive",
    },
    error: null,
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
    assert.equal(result.error.message, "Candidate account is inactive");
  }
});

test("provisionCandidateIdentity: provisions first-time new candidate registration successfully", async () => {
  const expectedData: CandidateIdentity = {
    candidate_id: "c0000000-0000-0000-0000-000000000001",
    auth_user_id: "a0000000-0000-0000-0000-000000000001",
    email: "candidate.one@example.com",
    current_full_name: null,
    current_phone: null,
    is_active: true,
  };

  const client = createMockSupabaseClient({
    data: {
      success: true,
      data: expectedData,
    },
    error: null,
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, true);
  if (result.success) {
    assert.deepEqual(result.data, expectedData);
    assert.equal(
      result.data.candidate_id,
      "c0000000-0000-0000-0000-000000000001",
    );
    assert.equal(result.data.email, "candidate.one@example.com");
    assert.equal(result.data.is_active, true);
  }
});

test("provisionCandidateIdentity: handles subsequent login with same auth_user_id as idempotent success", async () => {
  const existingData: CandidateIdentity = {
    candidate_id: "c0000000-0000-0000-0000-000000000001",
    auth_user_id: "a0000000-0000-0000-0000-000000000001",
    email: "candidate.one@example.com",
    current_full_name: "Nguyen Van A",
    current_phone: "0901234567",
    is_active: true,
  };

  const client = createMockSupabaseClient({
    data: {
      success: true,
      data: existingData,
    },
    error: null,
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, true);
  if (result.success) {
    assert.deepEqual(result.data, existingData);
    assert.equal(result.data.current_full_name, "Nguyen Van A");
  }
});

test("provisionCandidateIdentity: handles recreated auth session with safe rebind without duplicate candidate", async () => {
  const reboundData: CandidateIdentity = {
    candidate_id: "c0000000-0000-0000-0000-000000000001",
    auth_user_id: "a0000000-0000-0000-0000-000000000002", // Rebound new auth identity
    email: "candidate.one@example.com",
    current_full_name: "Nguyen Van A",
    current_phone: "0901234567",
    is_active: true,
  };

  const client = createMockSupabaseClient({
    data: {
      success: true,
      data: reboundData,
    },
    error: null,
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(
      result.data.candidate_id,
      "c0000000-0000-0000-0000-000000000001",
    );
    assert.equal(
      result.data.auth_user_id,
      "a0000000-0000-0000-0000-000000000002",
    );
    assert.equal(result.data.email, "candidate.one@example.com");
  }
});

test("provisionCandidateIdentity: maps unexpected RPC transport error to INTERNAL_ERROR", async () => {
  const client = createMockSupabaseClient({
    data: null,
    error: { message: "database connection failure" },
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INTERNAL_ERROR);
    assert.equal(result.error.message, "database connection failure");
  }
});

test("provisionCandidateIdentity: maps invalid/malformed response payload to INTERNAL_ERROR", async () => {
  const client = createMockSupabaseClient({
    data: "invalid string payload",
    error: null,
  });

  const result = await provisionCandidateIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INTERNAL_ERROR);
    assert.equal(
      result.error.message,
      "Invalid response from provisioning service",
    );
  }
});
