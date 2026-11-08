import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { NextRequest } from "next/server";
import { GET as handleCallback } from "@/app/auth/callback/route";
import { POST as handleCandidateVerify } from "@/app/auth/candidate/verify/route";
import { POST as handleSignout } from "@/app/auth/signout/route";
import { getServerSession } from "@/lib/auth/session";

interface MockClientOptions {
  exchangeCodeForSession?: (
    code: string,
  ) => Promise<{ error: { message: string } | null }>;
  verifyOtp?: (params: {
    email: string;
    token: string;
    type: string;
  }) => Promise<{ error: { message: string } | null }>;
  signOut?: () => Promise<{ error: null }>;
  getUser?: () => Promise<{
    data: { user: { id: string; email?: string } | null };
    error: { message: string } | null;
  }>;
  rpc?: (
    fnName: string,
    args?: unknown,
  ) => Promise<{ data: unknown; error: { message: string } | null }>;
  tableData?: Record<string, { data: unknown; error: unknown }>;
}

function createMockClient(options: MockClientOptions = {}) {
  let signOutCalled = false;

  const client = {
    auth: {
      exchangeCodeForSession:
        options.exchangeCodeForSession ?? (async () => ({ error: null })),
      verifyOtp: options.verifyOtp ?? (async () => ({ error: null })),
      signOut: async () => {
        signOutCalled = true;
        if (options.signOut) {
          return options.signOut();
        }
        return { error: null };
      },
      getUser:
        options.getUser ??
        (async () => ({ data: { user: null }, error: null })),
    },
    rpc: options.rpc ?? (async () => ({ data: null, error: null })),
    from: (table: string) => {
      const response = options.tableData?.[table] ?? {
        data: null,
        error: null,
      };
      return {
        select: () => ({
          eq: () => ({
            single: async () => response,
          }),
        }),
      };
    },
    get isSignOutCalled() {
      return signOutCalled;
    },
  };

  return client as unknown as SupabaseClient & { isSignOutCalled: boolean };
}

// ---------------------------------------------------------------------------
// 1. Google OAuth Callback Route Handlers
// ---------------------------------------------------------------------------

test("callback: redirects to /login?error=MISSING_CODE when code parameter is omitted", async () => {
  const request = new NextRequest("https://app.example.test/auth/callback");
  const response = await handleCallback(request);

  assert.equal(response.status, 307);
  assert.equal(
    response.headers.get("location"),
    "https://app.example.test/login?error=MISSING_CODE",
  );
});

test("callback: open redirect defense normalizes //evil.com to /", async () => {
  const client = createMockClient({
    rpc: async (fnName) => {
      assert.equal(fnName, "provision_internal_user_identity");
      return {
        data: {
          success: true,
          data: {
            app_user_id: "u-1",
            auth_user_id: "auth-1",
            email: "staff@eiu.edu.vn",
            full_name: "Staff",
            is_root_admin: false,
            roles: ["HR"],
            permissions: ["candidates.view"],
          },
        },
        error: null,
      };
    },
  });

  const request = new NextRequest(
    "https://app.example.test/auth/callback?code=valid-auth-code&next=//evil.example.test",
  );
  const response = await handleCallback(request, undefined, client);

  assert.equal(response.status, 307);
  assert.equal(response.headers.get("location"), "https://app.example.test/");
});

test("callback: open redirect defense normalizes https://evil.com to /", async () => {
  const client = createMockClient({
    rpc: async () => ({
      data: {
        success: true,
        data: {
          app_user_id: "u-1",
          auth_user_id: "auth-1",
          email: "staff@eiu.edu.vn",
          full_name: "Staff",
          is_root_admin: false,
          roles: ["HR"],
          permissions: [],
        },
      },
      error: null,
    }),
  });

  const request = new NextRequest(
    "https://app.example.test/auth/callback?code=valid-auth-code&next=https://evil.example.test",
  );
  const response = await handleCallback(request, undefined, client);

  assert.equal(response.status, 307);
  assert.equal(response.headers.get("location"), "https://app.example.test/");
});

test("callback: open redirect defense normalizes /\\evil.com backslash bypass to /", async () => {
  const client = createMockClient({
    rpc: async () => ({
      data: {
        success: true,
        data: {
          app_user_id: "u-1",
          auth_user_id: "auth-1",
          email: "staff@eiu.edu.vn",
          full_name: "Staff",
          is_root_admin: false,
          roles: ["HR"],
          permissions: [],
        },
      },
      error: null,
    }),
  });

  const request = new NextRequest(
    "https://app.example.test/auth/callback?code=valid-auth-code&next=/\\evil.example.test",
  );
  const response = await handleCallback(request, undefined, client);

  assert.equal(response.status, 307);
  assert.equal(response.headers.get("location"), "https://app.example.test/");
});

test("callback: open redirect defense preserves valid relative destination", async () => {
  const client = createMockClient({
    rpc: async () => ({
      data: {
        success: true,
        data: {
          app_user_id: "u-1",
          auth_user_id: "auth-1",
          email: "staff@eiu.edu.vn",
          full_name: "Staff",
          is_root_admin: false,
          roles: ["HR"],
          permissions: [],
        },
      },
      error: null,
    }),
  });

  const request = new NextRequest(
    "https://app.example.test/auth/callback?code=valid-auth-code&next=/dashboard/jobs",
  );
  const response = await handleCallback(request, undefined, client);

  assert.equal(response.status, 307);
  assert.equal(
    response.headers.get("location"),
    "https://app.example.test/dashboard/jobs",
  );
});

test("callback: exchange failure redirects to /login?error=AUTH_EXCHANGE_FAILED", async () => {
  const client = createMockClient({
    exchangeCodeForSession: async () => ({
      error: { message: "Invalid authorization code" },
    }),
  });

  const request = new NextRequest(
    "https://app.example.test/auth/callback?code=bad-code",
  );
  const response = await handleCallback(request, undefined, client);

  assert.equal(response.status, 307);
  assert.equal(
    response.headers.get("location"),
    "https://app.example.test/login?error=AUTH_EXCHANGE_FAILED",
  );
});

test("callback: provisioning failure signs out and redirects to /login?error=<code>", async () => {
  const client = createMockClient({
    rpc: async () => ({
      data: {
        success: false,
        error_code: "USER_INACTIVE",
        message: "User account is inactive",
      },
      error: null,
    }),
  });

  const request = new NextRequest(
    "https://app.example.test/auth/callback?code=valid-code",
  );
  const response = await handleCallback(request, undefined, client);

  assert.equal(client.isSignOutCalled, true);
  assert.equal(response.status, 307);
  assert.equal(
    response.headers.get("location"),
    "https://app.example.test/login?error=USER_INACTIVE",
  );
});

// ---------------------------------------------------------------------------
// 2. Candidate OTP Verification Route Handlers
// ---------------------------------------------------------------------------

test("candidate verify: rejects request failing validateSameOrigin with 403 FORBIDDEN", async () => {
  const mismatchedOrigin = new NextRequest(
    "https://recruitment.example.test/auth/candidate/verify",
    {
      method: "POST",
      headers: {
        host: "recruitment.example.test",
        origin: "https://attacker.example.test",
      },
    },
  );
  const response = await handleCandidateVerify(mismatchedOrigin);
  assert.equal(response.status, 403);
  const body = await response.json();
  assert.equal(body.success, false);
  assert.equal(body.error.code, "FORBIDDEN");
});

test("candidate verify: rejects missing origin headers with 403 FORBIDDEN", async () => {
  const missingOrigin = new NextRequest(
    "https://recruitment.example.test/auth/candidate/verify",
    {
      method: "POST",
      headers: { host: "recruitment.example.test" },
    },
  );
  const response = await handleCandidateVerify(missingOrigin);
  assert.equal(response.status, 403);
  const body = await response.json();
  assert.equal(body.success, false);
  assert.equal(body.error.code, "FORBIDDEN");
});

test("candidate verify: rejects invalid JSON body with 400 VALIDATION_ERROR", async () => {
  const request = new NextRequest(
    "https://recruitment.example.test/auth/candidate/verify",
    {
      method: "POST",
      headers: {
        host: "recruitment.example.test",
        origin: "https://recruitment.example.test",
        "content-type": "application/json",
      },
      body: "not-json",
    },
  );
  const response = await handleCandidateVerify(request);
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.equal(body.success, false);
  assert.equal(body.error.code, "VALIDATION_ERROR");
});

test("candidate verify: rejects missing email or token with 400 VALIDATION_ERROR", async () => {
  const request = new NextRequest(
    "https://recruitment.example.test/auth/candidate/verify",
    {
      method: "POST",
      headers: {
        host: "recruitment.example.test",
        origin: "https://recruitment.example.test",
        "content-type": "application/json",
      },
      body: JSON.stringify({ email: "candidate@example.test" }),
    },
  );
  const response = await handleCandidateVerify(request);
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.equal(body.success, false);
  assert.equal(body.error.code, "VALIDATION_ERROR");
});

test("candidate verify: returns 401 UNAUTHENTICATED on invalid OTP", async () => {
  const client = createMockClient({
    verifyOtp: async () => ({
      error: { message: "Invalid or expired OTP token" },
    }),
  });

  const request = new NextRequest(
    "https://recruitment.example.test/auth/candidate/verify",
    {
      method: "POST",
      headers: {
        host: "recruitment.example.test",
        origin: "https://recruitment.example.test",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        email: "candidate@example.test",
        token: "000000",
      }),
    },
  );
  const response = await handleCandidateVerify(request, undefined, client);
  assert.equal(response.status, 401);
  const body = await response.json();
  assert.equal(body.success, false);
  assert.equal(body.error.code, "UNAUTHENTICATED");
});

test("candidate verify: maps provisioning failure to 400 with failure payload", async () => {
  const client = createMockClient({
    rpc: async () => ({
      data: {
        success: false,
        error_code: "USER_INACTIVE",
        message: "Candidate account inactive",
      },
      error: null,
    }),
  });

  const request = new NextRequest(
    "https://recruitment.example.test/auth/candidate/verify",
    {
      method: "POST",
      headers: {
        host: "recruitment.example.test",
        origin: "https://recruitment.example.test",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        email: "candidate@example.test",
        token: "123456",
      }),
    },
  );
  const response = await handleCandidateVerify(request, undefined, client);
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.equal(body.success, false);
  assert.equal(body.error.code, "USER_INACTIVE");
});

test("candidate verify: succeeds on valid OTP and returns provisioned candidate identity", async () => {
  const client = createMockClient({
    rpc: async () => ({
      data: {
        success: true,
        data: {
          candidate_id: "cand-1234",
          auth_user_id: "auth-5678",
          email: "candidate@example.test",
          current_full_name: "Nguyen Van A",
          current_phone: null,
          is_active: true,
        },
      },
      error: null,
    }),
  });

  const request = new NextRequest(
    "https://recruitment.example.test/auth/candidate/verify",
    {
      method: "POST",
      headers: {
        host: "recruitment.example.test",
        origin: "https://recruitment.example.test",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        email: "candidate@example.test",
        token: "123456",
      }),
    },
  );
  const response = await handleCandidateVerify(request, undefined, client);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.success, true);
  assert.equal(body.data.candidate_id, "cand-1234");
});

// ---------------------------------------------------------------------------
// 3. Signout Route Handler
// ---------------------------------------------------------------------------

test("signout: signs out and redirects to /login with HTTP 303 status", async () => {
  const client = createMockClient();
  const request = new NextRequest("https://app.example.test/auth/signout", {
    method: "POST",
  });
  const response = await handleSignout(request, undefined, client);

  assert.equal(client.isSignOutCalled, true);
  assert.equal(response.status, 303);
  assert.equal(
    response.headers.get("location"),
    "https://app.example.test/login",
  );
});

// ---------------------------------------------------------------------------
// 4. Server-Only Session Resolver (getServerSession)
// ---------------------------------------------------------------------------

test("getServerSession: returns unauthenticated when no session exists", async () => {
  const client = createMockClient({
    getUser: async () => ({ data: { user: null }, error: null }),
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("getServerSession: returns unauthenticated when auth error occurs", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: { user: null },
      error: { message: "Invalid JWT token" },
    }),
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("getServerSession: returns unauthenticated when user email is empty", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: { user: { id: "auth-empty", email: "" } },
      error: null,
    }),
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("getServerSession: resolves internal permissions strictly from trusted database RPC, ignoring client claims", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: { user: { id: "auth-internal-1", email: "hr.manager@eiu.edu.vn" } },
      error: null,
    }),
    rpc: async (fnName) => {
      assert.equal(fnName, "get_current_internal_session");
      return {
        data: {
          success: true,
          data: {
            app_user_id: "app-user-999",
            is_active: true,
            is_root_admin: false,
            roles: ["HR"],
            permissions: ["candidates.view", "submissions.evaluate"],
          },
        },
        error: null,
      };
    },
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, true);
  assert.notEqual(session.user, null);
  if (session.user) {
    assert.equal(session.user.authUserId, "auth-internal-1");
    assert.equal(session.user.email, "hr.manager@eiu.edu.vn");
    assert.equal(session.user.isInternal, true);
    assert.equal(session.user.isCandidate, false);
    assert.equal(session.user.appUserId, "app-user-999");
    assert.deepEqual(session.user.roles, ["HR"]);
    assert.deepEqual(session.user.permissions, [
      "candidates.view",
      "submissions.evaluate",
    ]);
  }
});

test("getServerSession: returns unauthenticated if internal user is inactive", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: {
        user: {
          id: "auth-internal-inactive",
          email: "former.staff@eiu.edu.vn",
        },
      },
      error: null,
    }),
    tableData: {
      app_users: {
        data: {
          app_user_id: "app-user-inactive",
          is_active: false,
          is_root_admin: false,
          app_user_roles: [{ role_code: "HR" }],
          app_user_permissions: [],
        },
        error: null,
      },
    },
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("getServerSession: returns unauthenticated if app_users record is not found", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: {
        user: {
          id: "auth-internal-missing",
          email: "unknown.staff@eiu.edu.vn",
        },
      },
      error: null,
    }),
    tableData: {
      app_users: {
        data: null,
        error: { message: "No rows found" },
      },
    },
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("getServerSession: resolves active candidate identity with default candidate permissions", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: {
        user: {
          id: "auth-cand-1",
          email: "applicant@gmail.com",
        },
      },
      error: null,
    }),
    tableData: {
      candidates: {
        data: {
          candidate_id: "cand-uuid-1234",
          is_active: true,
        },
        error: null,
      },
    },
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, true);
  assert.notEqual(session.user, null);
  if (session.user) {
    assert.equal(session.user.authUserId, "auth-cand-1");
    assert.equal(session.user.email, "applicant@gmail.com");
    assert.equal(session.user.isInternal, false);
    assert.equal(session.user.isCandidate, true);
    assert.equal(session.user.candidateId, "cand-uuid-1234");
    assert.deepEqual(session.user.roles, ["CANDIDATE"]);
    assert.deepEqual(session.user.permissions, ["candidate.self"]);
  }
});

test("getServerSession: returns unauthenticated if candidate record is inactive", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: {
        user: {
          id: "auth-cand-inactive",
          email: "suspended.applicant@gmail.com",
        },
      },
      error: null,
    }),
    tableData: {
      candidates: {
        data: {
          candidate_id: "cand-uuid-inactive",
          is_active: false,
        },
        error: null,
      },
    },
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("getServerSession: returns unauthenticated if candidate record is not found", async () => {
  const client = createMockClient({
    getUser: async () => ({
      data: {
        user: {
          id: "auth-cand-missing",
          email: "unregistered.applicant@gmail.com",
        },
      },
      error: null,
    }),
    tableData: {
      candidates: {
        data: null,
        error: { message: "No rows found" },
      },
    },
  });

  const session = await getServerSession(client);
  assert.equal(session.isAuthenticated, false);
  assert.equal(session.user, null);
});

test("callback: decoded control characters cannot turn an internal-looking path into an external redirect", async () => {
  const client = createMockClient({
    rpc: async () => ({
      data: {
        success: true,
        data: {
          app_user_id: "u-1",
          auth_user_id: "auth-1",
          email: "staff@eiu.edu.vn",
          full_name: "Staff",
          is_root_admin: false,
          roles: ["HR"],
          permissions: [],
        },
      },
      error: null,
    }),
  });
  for (const next of [
    "/\n/evil.example.test",
    "/\t/evil.example.test",
    "/\r/evil.example.test",
  ]) {
    const request = new NextRequest(
      `https://app.example.test/auth/callback?code=valid-code&next=${encodeURIComponent(next)}`,
    );
    const response = await handleCallback(request, undefined, client);
    assert.equal(response.headers.get("location"), "https://app.example.test/");
  }
});
