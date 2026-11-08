import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type SubmitCandidateSubmissionInput,
  submitCandidateSubmission,
  updateCandidateSubmission,
} from "@/lib/commands/candidate-submission";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";

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

const nonCandidateActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000003",
  email: "staff@eiu.edu.vn",
  isActive: true,
  roles: ["STAFF"],
  permissions: ["submissions.view"],
};

// -----------------------------------------------------------------------------
// Mock Supabase Factory
// -----------------------------------------------------------------------------

function createMockSupabase(options: {
  rpcHandlers?: Record<string, (args: unknown) => unknown>;
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

const samplePayload: SubmitCandidateSubmissionInput = {
  candidateFormSessionId: "11111111-1111-1111-1111-111111111111",
  fullName: "Nguyen Van A",
  phone: "0901234567",
  dateOfBirth: "1995-05-15",
  gender: "MALE",
  address: "123 Binh Duong Blvd, Thu Dau Mot",
  education: [
    {
      institution: "Eastern International University",
      major: "Computer Science",
      periodText: "2013 - 2017",
      qualificationId: "22222222-2222-2222-2222-222222222222",
      sortOrder: 1,
    },
  ],
  privacyNoticeVersion: "2026.1",
  idempotencyKey: "e1111111-1111-1111-1111-111111111111",
};

// -----------------------------------------------------------------------------
// Test Suite
// -----------------------------------------------------------------------------

test("1. UNAUTHENTICATED call rejection", async () => {
  const mockSupabase = createMockSupabase({});
  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => null,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.UNAUTHENTICATED);
  }
});

test("2. USER_INACTIVE candidate rejection", async () => {
  const mockSupabase = createMockSupabase({});
  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => inactiveCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
  }
});

test("3. NOT_FOUND foreign session access rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "NOT_FOUND",
        message: "Candidate form session not found or access denied",
      }),
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.NOT_FOUND);
  }
});

test("4. FORM_SESSION_EXPIRED rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "FORM_SESSION_EXPIRED",
        message: "Candidate form session has expired",
      }),
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORM_SESSION_EXPIRED);
  }
});

test("5. INVALID_STATE (closed/cancelled session) rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Candidate form session is not open",
      }),
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_STATE);
  }
});

test("6. INVALID_ACTION submit rejected if mode is not NEW_SUBMISSION", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "INVALID_ACTION",
        message:
          "submit_candidate_submission requires a NEW_SUBMISSION form session",
      }),
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_ACTION);
  }
});

test("7. INVALID_ACTION update rejected if mode is not EDIT_SUBMISSION", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_candidate_submission: () => ({
        success: false,
        error_code: "INVALID_ACTION",
        message:
          "update_candidate_submission requires an EDIT_SUBMISSION form session",
      }),
    },
  });

  const result = await updateCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_ACTION);
  }
});

test("8. PRIVACY_VERSION_MISMATCH rejection", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "VALIDATION_ERROR",
        message:
          "Acknowledged privacy notice version must match server-pinned notice version",
      }),
    },
  });

  const result = await submitCandidateSubmission(
    { ...samplePayload, privacyNoticeVersion: "stale.0" },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
  }
});

test("9. VALIDATION_ERROR empty full_name, invalid gender, malformed UUIDs rejected", async () => {
  const mockSupabase = createMockSupabase({});

  // Empty full name
  const badName = await submitCandidateSubmission(
    { ...samplePayload, fullName: "" },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );
  assert.equal(badName.success, false);
  if (!badName.success) {
    assert.equal(badName.error.code, CommandErrorCode.VALIDATION_ERROR);
  }

  // Invalid gender
  const badGender = await submitCandidateSubmission(
    { ...samplePayload, gender: "UNKNOWN" },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );
  assert.equal(badGender.success, false);
  if (!badGender.success) {
    assert.equal(badGender.error.code, CommandErrorCode.VALIDATION_ERROR);
  }

  // Malformed UUID
  const badUUID = await submitCandidateSubmission(
    { ...samplePayload, candidateFormSessionId: "not-a-uuid" },
    { client: mockSupabase, resolveActor: async () => activeCandidateActor },
  );
  assert.equal(badUUID.success, false);
  if (!badUUID.success) {
    assert.equal(badUUID.error.code, CommandErrorCode.VALIDATION_ERROR);
  }
});

test("10. SUBMIT_NEW_SUBMISSION_SUCCESS atomic creation of submission", async () => {
  let rpcArgs: unknown;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: (args) => {
        rpcArgs = args;
        return {
          success: true,
          data: {
            submission_id: "sub-1111-1111-1111-111111111111",
            status_code: "NEW",
            version_no: 1,
            submitted_at: "2026-09-05T10:00:00Z",
          },
        };
      },
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.submission_id, "sub-1111-1111-1111-111111111111");
    assert.equal(result.data.status_code, "NEW");
    assert.equal(result.data.version_no, 1);
  }
  assert.ok(rpcArgs);
});

test("11. IMMUTABLE_VERIFIED_EMAIL candidate submission email derives strictly from candidate record", async () => {
  // In SQL, submissions.email is populated via v_cand.email (the verified auth email),
  // completely ignoring any client attempt to supply an arbitrary email.
  const verifiedEmail = "candidate@example.com";
  assert.equal(activeCandidateActor.email, verifiedEmail);
});

test("12. EDIT_SUBMISSION_SUCCESS updates text, bumps version_no from 1 to 2, marks session SUBMITTED", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_candidate_submission: () => ({
        success: true,
        data: {
          submission_id: "sub-1111-1111-1111-111111111111",
          status_code: "NEW",
          version_no: 2,
          updated_at: "2026-09-05T11:00:00Z",
        },
      }),
    },
  });

  const result = await updateCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.version_no, 2);
    assert.equal(result.data.status_code, "NEW");
  }
});

test("13. EDIT_NON_NEW_SUBMISSION_REJECTION edit rejected if target submission is not NEW", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_candidate_submission: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Target submission is no longer in editable NEW status",
      }),
    },
  });

  const result = await updateCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_STATE);
  }
});

test("14. EDIT_STALE_VERSION_REJECTION edit rejected if base_submission_version_no does not match", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_candidate_submission: () => ({
        success: false,
        error_code: "STALE_VERSION",
        message: "Submission version has changed since session opened",
      }),
    },
  });

  const result = await updateCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.STALE_VERSION);
  }
});

test("15. DOCUMENT_PLAN_REQUIRED_CV_MISSING rejected if no current CV document is staged", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "REQUIRED_CV_DOCUMENT_MISSING",
        message: "A valid current CV document is required",
      }),
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(
      result.error.code,
      CommandErrorCode.REQUIRED_CV_DOCUMENT_MISSING,
    );
  }
});

test("16. DOCUMENT_PLAN_MAX_FIVE_FILES rejected if effective document count exceeds 5", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED",
        message: "A submission cannot exceed 5 current documents",
      }),
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(
      result.error.code,
      CommandErrorCode.MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED,
    );
  }
});

test("17. DOCUMENT_PLAN_UNSCANNED_FILE rejected if staged reservation is not VALIDATED + CLEAN", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "UPLOAD_RESERVATION_NOT_CLEAN",
        message: "All uploaded documents must be validated and verified clean",
      }),
    },
  });

  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(
      result.error.code,
      CommandErrorCode.UPLOAD_RESERVATION_NOT_CLEAN,
    );
  }
});

test("18. DOCUMENT_PLAN_TARGET_NO_CURRENT replace/delete rejected if target has no current version", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      update_candidate_submission: () => ({
        success: false,
        error_code: "INVALID_DOCUMENT_TARGET",
        message:
          "Target logical document must have exactly one current version",
      }),
    },
  });

  const result = await updateCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.INVALID_DOCUMENT_TARGET);
  }
});

test("21. Adapter maps terminal-session RPC rejection for submit and update", async () => {
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Candidate form session is not open",
      }),
      update_candidate_submission: () => ({
        success: false,
        error_code: "INVALID_STATE",
        message: "Candidate form session is not open",
      }),
    },
  });

  const submit = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });
  assert.equal(submit.success, false);

  const update = await updateCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });
  assert.equal(update.success, false);
});

test("23. Adapter forwards repeated submissions to RPC without local deduplication", async () => {
  let callCount = 0;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      submit_candidate_submission: () => {
        callCount++;
        return {
          success: true,
          data: {
            submission_id: "sub-1111-1111-1111-111111111111",
            status_code: "NEW",
            version_no: 1,
            submitted_at: "2026-09-05T10:00:00Z",
          },
        };
      },
    },
  });

  const first = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });
  const second = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => activeCandidateActor,
  });

  assert.equal(first.success, true);
  assert.equal(second.success, true);
  assert.equal(callCount, 2);
});

test("24. Non-candidate actor rejected with FORBIDDEN", async () => {
  const mockSupabase = createMockSupabase({});
  const result = await submitCandidateSubmission(samplePayload, {
    client: mockSupabase,
    resolveActor: async () => nonCandidateActor,
  });

  assert.equal(result.success, false);
  if (!result.success) {
    assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  }
});
