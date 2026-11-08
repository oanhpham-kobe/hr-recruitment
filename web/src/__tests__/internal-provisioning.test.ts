import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type InternalUserIdentity,
  provisionInternalUserIdentity,
} from "@/lib/auth/internal";
import { CommandErrorCode } from "@/lib/commands/types";

function createMockSupabaseClient(rpcResult: {
  data: unknown;
  error: { message: string } | null;
}) {
  return {
    rpc: async (fnName: string) => {
      assert.equal(fnName, "provision_internal_user_identity");
      return rpcResult;
    },
  } as unknown as SupabaseClient;
}

test("provisionInternalUserIdentity: rejects unauthenticated caller with UNAUTHENTICATED", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "UNAUTHENTICATED",
      message: "Authentication required",
    },
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
    assert.equal(result.error.message, "Authentication required");
  }
});

test("provisionInternalUserIdentity: rejects non-EIU email domain with FORBIDDEN", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "FORBIDDEN",
      message: "Only @eiu.edu.vn Google Workspace accounts are permitted",
    },
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
    assert.equal(
      result.error.message,
      "Only @eiu.edu.vn Google Workspace accounts are permitted",
    );
  }
});

test("provisionInternalUserIdentity: rejects unlisted email with NOT_FOUND", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "NOT_FOUND",
      message: "User account not found in internal directory",
    },
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.NOT_FOUND);
    assert.equal(
      result.error.message,
      "User account not found in internal directory",
    );
  }
});

test("provisionInternalUserIdentity: rejects inactive user with USER_INACTIVE", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "USER_INACTIVE",
      message: "User account is inactive",
    },
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
    assert.equal(result.error.message, "User account is inactive");
  }
});

test("provisionInternalUserIdentity: rejects rebind attempt with different auth identity with IDENTITY_REBIND_FORBIDDEN", async () => {
  const client = createMockSupabaseClient({
    data: {
      success: false,
      error_code: "IDENTITY_REBIND_FORBIDDEN",
      message: "Account is already bound to a different identity",
    },
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.IDENTITY_REBIND_FORBIDDEN);
    assert.equal(
      result.error.message,
      "Account is already bound to a different identity",
    );
  }
});

test("provisionInternalUserIdentity: provisions first-time binding successfully with roles and permissions", async () => {
  const expectedData: InternalUserIdentity = {
    app_user_id: "00000000-0000-0000-0000-000000000001",
    auth_user_id: "11111111-1111-1111-1111-111111111111",
    email: "hr.manager@eiu.edu.vn",
    full_name: "HR Manager",
    is_root_admin: false,
    roles: ["HR"],
    permissions: ["submissions.view", "users.directory_read"],
  };

  const client = createMockSupabaseClient({
    data: {
      success: true,
      data: expectedData,
    },
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, true);
  if (result.success) {
    assert.deepEqual(result.data, expectedData);
    assert.equal(
      result.data.auth_user_id,
      "11111111-1111-1111-1111-111111111111",
    );
    assert.deepEqual(result.data.roles, ["HR"]);
  }
});

test("provisionInternalUserIdentity: handles subsequent login with idempotent success", async () => {
  const boundData: InternalUserIdentity = {
    app_user_id: "00000000-0000-0000-0000-000000000001",
    auth_user_id: "11111111-1111-1111-1111-111111111111",
    email: "hr.manager@eiu.edu.vn",
    full_name: "HR Manager",
    is_root_admin: false,
    roles: ["HR"],
    permissions: ["submissions.view", "users.directory_read"],
  };

  const client = createMockSupabaseClient({
    data: {
      success: true,
      data: boundData,
    },
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.app_user_id, boundData.app_user_id);
    assert.equal(result.data.auth_user_id, boundData.auth_user_id);
  }
});

test("provisionInternalUserIdentity: maps unexpected RPC transport error to stable non-leaking INTERNAL_ERROR", async () => {
  const client = createMockSupabaseClient({
    data: null,
    error: { message: "database connection failure" },
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INTERNAL_ERROR);
    assert.equal(result.error.message, "Internal provisioning error");
    assert.equal("details" in result.error, false);
  }
});

test("provisionInternalUserIdentity: maps invalid/malformed response payload to INTERNAL_ERROR", async () => {
  const client = createMockSupabaseClient({
    data: "invalid string payload",
    error: null,
  });

  const result = await provisionInternalUserIdentity(client);

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INTERNAL_ERROR);
    assert.equal(
      result.error.message,
      "Invalid response from provisioning service",
    );
  }
});
