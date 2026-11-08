import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type CancelCandidateFormSessionData,
  type CandidateFormSessionData,
  cancelCandidateFormSession,
  startCandidateFormSession,
} from "@/lib/commands/form-session";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";

const activeCandidateActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000001",
  email: "candidate@example.com",
  isActive: true,
  roles: ["CANDIDATE"],
  permissions: ["candidate.self"],
};

const nonCandidateActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000003",
  email: "staff@eiu.edu.vn",
  isActive: true,
  roles: ["STAFF"],
  permissions: ["submissions.view"],
};

function createMockSupabaseClient(options: {
  rpcResult?: {
    data: unknown;
    error: { message: string } | null;
  };
  userData?: { id: string; email: string } | null;
  candidateData?: { candidate_id: string; is_active: boolean } | null;
  onRpcCall?: (fn: string, args?: unknown) => void;
}) {
  return {
    rpc: async (fn: string, args?: unknown) => {
      options.onRpcCall?.(fn, args);
      return (
        options.rpcResult ?? {
          data: null,
          error: null,
        }
      );
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

// ---------------------------------------------------------------------------
// 1. Boundary Case 1: Unauthenticated call -> UNAUTHENTICATED
// ---------------------------------------------------------------------------

test("startCandidateFormSession: rejects unauthenticated caller with UNAUTHENTICATED", async () => {
  const client = createMockSupabaseClient({ userData: null });
  const result = await startCandidateFormSession(
    { mode: "NEW_SUBMISSION" },
    { client },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
    assert.match(result.error.message, /Authentication required/i);
  }
});

test("cancelCandidateFormSession: rejects unauthenticated caller with UNAUTHENTICATED", async () => {
  const client = createMockSupabaseClient({ userData: null });
  const result = await cancelCandidateFormSession(
    { sessionId: "f0000000-0000-0000-0000-000000000001" },
    { client },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
    assert.match(result.error.message, /Authentication required/i);
  }
});

// ---------------------------------------------------------------------------
// 2. Boundary Case 2: Inactive candidate -> USER_INACTIVE
// ---------------------------------------------------------------------------

test("startCandidateFormSession: rejects inactive candidate with USER_INACTIVE", async () => {
  const client = createMockSupabaseClient({
    candidateData: {
      candidate_id: "c0000000-0000-0000-0000-000000000002",
      is_active: false,
    },
  });

  const result = await startCandidateFormSession(
    { mode: "NEW_SUBMISSION" },
    { client },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
    assert.match(result.error.message, /inactive/i);
  }
});

test("cancelCandidateFormSession: rejects inactive candidate with USER_INACTIVE", async () => {
  const client = createMockSupabaseClient({
    candidateData: {
      candidate_id: "c0000000-0000-0000-0000-000000000002",
      is_active: false,
    },
  });

  const result = await cancelCandidateFormSession(
    { sessionId: "f0000000-0000-0000-0000-000000000001" },
    { client },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
    assert.match(result.error.message, /inactive/i);
  }
});

// ---------------------------------------------------------------------------
// Authorization: Non-candidate role -> FORBIDDEN
// ---------------------------------------------------------------------------

test("startCandidateFormSession: rejects non-candidate actor with FORBIDDEN", async () => {
  const client = createMockSupabaseClient({});
  const result = await startCandidateFormSession(
    { mode: "NEW_SUBMISSION" },
    { client, resolveActor: async () => nonCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
    assert.match(result.error.message, /Candidate role required/i);
  }
});

test("cancelCandidateFormSession: rejects non-candidate actor with FORBIDDEN", async () => {
  const client = createMockSupabaseClient({});
  const result = await cancelCandidateFormSession(
    { sessionId: "f0000000-0000-0000-0000-000000000001" },
    { client, resolveActor: async () => nonCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  }
});

// ---------------------------------------------------------------------------
// 3. Boundary Case 3: Missing active privacy notice -> PRIVACY_NOTICE_UNAVAILABLE
// ---------------------------------------------------------------------------

test("startCandidateFormSession: fails closed when active privacy notice is unavailable", async () => {
  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: false,
        error_code: "PRIVACY_NOTICE_UNAVAILABLE",
        message: "No active privacy notice is available",
      },
      error: null,
    },
  });

  const result = await startCandidateFormSession(
    { mode: "NEW_SUBMISSION" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(
      result.error.code,
      CommandErrorCode.PRIVACY_NOTICE_UNAVAILABLE,
    );
    assert.match(result.error.message, /privacy notice/i);
  }
});

// ---------------------------------------------------------------------------
// 4. Boundary Case 4: NEW_SUBMISSION creates OPEN session with pinned notice and 4-hour expiry
// ---------------------------------------------------------------------------

test("startCandidateFormSession: NEW_SUBMISSION creates OPEN session with pinned notice and 4-hour expiry", async () => {
  let rpcCalledWith: unknown = null;
  const mockSessionData: CandidateFormSessionData = {
    candidate_form_session_id: "f0000000-0000-0000-0000-000000000001",
    mode_code: "NEW_SUBMISSION",
    presented_privacy_notice_version: "2026-09-01-v1",
    status_code: "OPEN",
    expires_at: new Date(Date.now() + 4 * 3600 * 1000).toISOString(),
  };

  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: true,
        data: mockSessionData,
      },
      error: null,
    },
    onRpcCall: (_fn, args) => {
      rpcCalledWith = args;
    },
  });

  const result = await startCandidateFormSession(
    { mode: "NEW_SUBMISSION" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(
      result.data.candidate_form_session_id,
      "f0000000-0000-0000-0000-000000000001",
    );
    assert.equal(result.data.mode_code, "NEW_SUBMISSION");
    assert.equal(result.data.presented_privacy_notice_version, "2026-09-01-v1");
    assert.equal(result.data.status_code, "OPEN");
    assert.ok(new Date(result.data.expires_at).getTime() > Date.now());
  }

  assert.deepEqual(rpcCalledWith, {
    p_mode: "NEW_SUBMISSION",
    p_submission_id: null,
  });
});

// ---------------------------------------------------------------------------
// 5. Boundary Case 5: EDIT_SUBMISSION on foreign or non-existent submission -> NOT_FOUND
// ---------------------------------------------------------------------------

test("startCandidateFormSession: EDIT_SUBMISSION on non-existent or foreign submission returns NOT_FOUND", async () => {
  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: false,
        error_code: "NOT_FOUND",
        message: "Submission not found",
      },
      error: null,
    },
  });

  const result = await startCandidateFormSession(
    {
      mode: "EDIT_SUBMISSION",
      submissionId: "00000000-0000-0000-0000-000000000099",
    },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.NOT_FOUND);
    assert.match(result.error.message, /Submission not found/i);
  }
});

// ---------------------------------------------------------------------------
// 6. Boundary Case 6: EDIT_SUBMISSION on non-NEW submission -> INVALID_STATE
// ---------------------------------------------------------------------------

test("startCandidateFormSession: EDIT_SUBMISSION on non-NEW submission returns INVALID_STATE", async () => {
  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: false,
        error_code: "INVALID_STATE",
        message: "Only submissions with status NEW can be edited",
      },
      error: null,
    },
  });

  const result = await startCandidateFormSession(
    {
      mode: "EDIT_SUBMISSION",
      submissionId: "00000000-0000-0000-0000-000000000001",
    },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_STATE);
    assert.match(result.error.message, /status NEW/i);
  }
});

test("startCandidateFormSession: EDIT_SUBMISSION on valid NEW submission succeeds", async () => {
  const mockEditSessionData: CandidateFormSessionData = {
    candidate_form_session_id: "f0000000-0000-0000-0000-000000000002",
    mode_code: "EDIT_SUBMISSION",
    presented_privacy_notice_version: "2026-09-01-v1",
    status_code: "OPEN",
    expires_at: new Date(Date.now() + 4 * 3600 * 1000).toISOString(),
  };

  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: true,
        data: mockEditSessionData,
      },
      error: null,
    },
  });

  const result = await startCandidateFormSession(
    {
      mode: "EDIT_SUBMISSION",
      submissionId: "00000000-0000-0000-0000-000000000001",
    },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.mode_code, "EDIT_SUBMISSION");
    assert.equal(result.data.status_code, "OPEN");
  }
});

// ---------------------------------------------------------------------------
// Validation tests for startCandidateFormSession
// ---------------------------------------------------------------------------

test("startCandidateFormSession: rejects invalid mode with VALIDATION_ERROR", async () => {
  const client = createMockSupabaseClient({});
  const result = await startCandidateFormSession(
    { mode: "UNKNOWN_MODE" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    assert.match(result.error.message, /mode/i);
  }
});

test("startCandidateFormSession: rejects NEW_SUBMISSION with submissionId with VALIDATION_ERROR", async () => {
  const client = createMockSupabaseClient({});
  const result = await startCandidateFormSession(
    {
      mode: "NEW_SUBMISSION",
      submissionId: "00000000-0000-0000-0000-000000000001",
    },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    assert.match(result.error.message, /p_submission_id must be null/i);
  }
});

test("startCandidateFormSession: rejects EDIT_SUBMISSION without submissionId with VALIDATION_ERROR", async () => {
  const client = createMockSupabaseClient({});
  const result = await startCandidateFormSession(
    { mode: "EDIT_SUBMISSION" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    assert.match(result.error.message, /p_submission_id is required/i);
  }
});

test("startCandidateFormSession: rejects EDIT_SUBMISSION with malformed UUID with VALIDATION_ERROR", async () => {
  const client = createMockSupabaseClient({});
  const result = await startCandidateFormSession(
    { mode: "EDIT_SUBMISSION", submissionId: "not-a-uuid" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    assert.match(result.error.message, /format/i);
  }
});

// ---------------------------------------------------------------------------
// 7. Boundary Case 7: Wall-clock expired session -> FORM_SESSION_EXPIRED
// ---------------------------------------------------------------------------

test("cancelCandidateFormSession: fails closed with FORM_SESSION_EXPIRED when session is expired", async () => {
  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: false,
        error_code: "FORM_SESSION_EXPIRED",
        message: "Form session has expired",
      },
      error: null,
    },
  });

  const result = await cancelCandidateFormSession(
    { sessionId: "f0000000-0000-0000-0000-000000000001" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORM_SESSION_EXPIRED);
    assert.match(result.error.message, /expired/i);
  }
});

// ---------------------------------------------------------------------------
// 8. Boundary Case 8: Cancellation moves OPEN -> CANCELLED & prevents re-cancelling terminal
// ---------------------------------------------------------------------------

test("cancelCandidateFormSession: moves OPEN -> CANCELLED successfully", async () => {
  let rpcCalledWith: unknown = null;
  const mockCancelData: CancelCandidateFormSessionData = {
    candidate_form_session_id: "f0000000-0000-0000-0000-000000000001",
    status_code: "CANCELLED",
  };

  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: true,
        data: mockCancelData,
      },
      error: null,
    },
    onRpcCall: (_fn, args) => {
      rpcCalledWith = args;
    },
  });

  const result = await cancelCandidateFormSession(
    { sessionId: "f0000000-0000-0000-0000-000000000001" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(
      result.data.candidate_form_session_id,
      "f0000000-0000-0000-0000-000000000001",
    );
    assert.equal(result.data.status_code, "CANCELLED");
  }

  assert.deepEqual(rpcCalledWith, {
    p_session_id: "f0000000-0000-0000-0000-000000000001",
  });
});

test("cancelCandidateFormSession: rejects cancellation of terminal session with INVALID_STATE", async () => {
  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: false,
        error_code: "INVALID_STATE",
        message: "Session is in terminal state and cannot be cancelled",
      },
      error: null,
    },
  });

  const result = await cancelCandidateFormSession(
    { sessionId: "f0000000-0000-0000-0000-000000000001" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_STATE);
    assert.match(result.error.message, /terminal state/i);
  }
});

test("cancelCandidateFormSession: rejects foreign or non-existent session with NOT_FOUND", async () => {
  const client = createMockSupabaseClient({
    rpcResult: {
      data: {
        success: false,
        error_code: "NOT_FOUND",
        message: "Form session not found",
      },
      error: null,
    },
  });

  const result = await cancelCandidateFormSession(
    { sessionId: "f0000000-0000-0000-0000-000000000099" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.NOT_FOUND);
    assert.match(result.error.message, /not found/i);
  }
});

// ---------------------------------------------------------------------------
// Validation & Transport Error tests for cancelCandidateFormSession
// ---------------------------------------------------------------------------

test("cancelCandidateFormSession: rejects malformed sessionId with VALIDATION_ERROR", async () => {
  const client = createMockSupabaseClient({});
  const result = await cancelCandidateFormSession(
    { sessionId: "invalid-uuid" },
    { client, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
    assert.match(result.error.message, /format/i);
  }
});

test("cancelCandidateFormSession: maps transport/RPC error to INTERNAL_ERROR", async () => {
  const originalError = console.error;
  console.error = () => {};

  try {
    const client = createMockSupabaseClient({
      rpcResult: {
        data: null,
        error: { message: "database connection failure" },
      },
    });

    const result = await cancelCandidateFormSession(
      { sessionId: "f0000000-0000-0000-0000-000000000001" },
      { client, resolveActor: async () => activeCandidateActor },
    );

    assert.equal(result.success, false);
    if (!result.success) {
      assert.equal(result.error.code, CommandErrorCode.INTERNAL_ERROR);
    }
  } finally {
    console.error = originalError;
  }
});

test("startCandidateFormSession: maps transport/RPC error to INTERNAL_ERROR", async () => {
  const originalError = console.error;
  console.error = () => {};

  try {
    const client = createMockSupabaseClient({
      rpcResult: {
        data: null,
        error: { message: "database connection failure" },
      },
    });

    const result = await startCandidateFormSession(
      { mode: "NEW_SUBMISSION" },
      { client, resolveActor: async () => activeCandidateActor },
    );

    assert.equal(result.success, false);
    if (!result.success) {
      assert.equal(result.error.code, CommandErrorCode.INTERNAL_ERROR);
    }
  } finally {
    console.error = originalError;
  }
});
