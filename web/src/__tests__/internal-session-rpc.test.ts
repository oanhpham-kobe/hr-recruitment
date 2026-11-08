import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  getCurrentInternalBindingStatus,
  getServerSession,
} from "@/lib/auth/session";

function createInternalRpcClient(payload: unknown): SupabaseClient {
  return {
    auth: {
      getUser: async () => ({
        data: {
          user: {
            id: "auth-internal-s06-002",
            email: "hr.rpc@eiu.edu.vn",
          },
        },
        error: null,
      }),
    },
    rpc: async (functionName: string) => {
      assert.equal(functionName, "get_current_internal_session");
      return { data: payload, error: null };
    },
    from: () => {
      throw new Error(
        "raw app_users fallback must not run for a valid S06-002 RPC payload",
      );
    },
  } as unknown as SupabaseClient;
}

test("getServerSession: resolves internal authorization from minimum-safe S06-002 RPC", async () => {
  const client = createInternalRpcClient({
    success: true,
    data: {
      app_user_id: "70000000-0000-0000-0000-000000000003",
      is_active: true,
      is_root_admin: false,
      roles: ["HR"],
      permissions: ["interviews.view", "interviews.participants"],
    },
  });

  const session = await getServerSession(client);

  assert.equal(session.isAuthenticated, true);
  assert.deepEqual(session.user, {
    authUserId: "auth-internal-s06-002",
    email: "hr.rpc@eiu.edu.vn",
    isInternal: true,
    isCandidate: false,
    appUserId: "70000000-0000-0000-0000-000000000003",
    roles: ["HR"],
    permissions: ["interviews.view", "interviews.participants"],
  });
});

test("getServerSession: Root RPC result keeps implicit Root role without client metadata", async () => {
  const client = createInternalRpcClient({
    success: true,
    data: {
      app_user_id: "70000000-0000-0000-0000-000000000001",
      is_active: true,
      is_root_admin: true,
      roles: [],
      permissions: ["submissions.view", "users.permissions_manage"],
    },
  });

  const session = await getServerSession(client);

  assert.equal(session.isAuthenticated, true);
  assert.ok(session.user?.roles.includes("ROOT_ADMIN"));
  assert.deepEqual(session.user?.permissions, [
    "submissions.view",
    "users.permissions_manage",
  ]);
});

test("getServerSession: trusted RPC denial fails closed without raw-directory fallback", async () => {
  const client = createInternalRpcClient({
    success: false,
    error_code: "USER_INACTIVE",
    message: "User account is inactive",
  });

  const session = await getServerSession(client);

  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("getCurrentInternalBindingStatus: resolves own binding without raw app_users identity reads", async () => {
  const client = {
    rpc: async (functionName: string) => {
      assert.equal(functionName, "get_current_internal_binding_status");
      return {
        data: {
          success: true,
          data: {
            bound: true,
            app_user_id: "70000000-0000-0000-0000-000000000002",
            is_active: false,
            is_root_admin: false,
          },
        },
        error: null,
      };
    },
    from: () => {
      throw new Error("raw app_users auth binding lookup must not run");
    },
  } as unknown as SupabaseClient;

  assert.deepEqual(await getCurrentInternalBindingStatus(client), {
    bound: true,
    appUserId: "70000000-0000-0000-0000-000000000002",
    isActive: false,
    isRootAdmin: false,
  });
});

test("getServerSession: internal RPC transport failure fails closed without raw auth_user_id fallback", async () => {
  const client = {
    auth: {
      getUser: async () => ({
        data: { user: { id: "auth-rpc-error", email: "error@eiu.edu.vn" } },
        error: null,
      }),
    },
    rpc: async () => ({ data: null, error: { message: "rpc unavailable" } }),
    from: () => {
      throw new Error("raw app_users fallback must remain unreachable");
    },
  } as unknown as SupabaseClient;

  assert.deepEqual(await getServerSession(client), {
    user: null,
    isAuthenticated: false,
  });
});
