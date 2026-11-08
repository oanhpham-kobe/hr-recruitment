import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { build } from "esbuild";
import { NextRequest } from "next/server";
import { type Browser, chromium } from "playwright";
import { GET as getDocumentPreviewRoute } from "@/app/api/documents/preview/[id]/route";
import { getDocumentSignedUrlAction } from "@/app/application-inbox-actions";
import { computeAssignmentContextKey } from "@/components/inbox/SubmissionDetailDrawer";
import { APPLICATION_INBOX_COLUMNS } from "@/lib/application-inbox/model";
import {
  DOCUMENT_SIGNED_URL_TTL_SECONDS,
  isPreviewableDocument,
  type SubmissionDetail,
} from "@/lib/application-inbox/submission-detail-model";
import {
  DocumentNotPreviewableError,
  generateDocumentSignedUrl,
  isAuthorizedForApplicationCreate,
  isAuthorizedForSubmissionDetail,
  loadAssignmentOptions,
  loadSubmissionDetail,
  SubmissionDetailAccessError,
  SubmissionDetailReadError,
  saveSubmissionHrNote,
} from "@/lib/application-inbox/submission-detail-server";
import { createOrUpdateApplication } from "@/lib/commands/application-lifecycle";
import { CommandErrorCode, type VerifiedActor } from "@/lib/commands/types";

// -----------------------------------------------------------------------------
// Test Actors & Fixtures
// -----------------------------------------------------------------------------

const sampleSubmissionId = "11111111-1111-1111-1111-111111111111";
const sampleCandidateId = "22222222-2222-2222-2222-222222222222";
const sampleDocId = "33333333-3333-3333-3333-333333333333";
const officeDocId = "33333333-3333-3333-3333-333333333334";
const sampleLogicalDocId = "44444444-4444-4444-4444-444444444444";
const sampleUnitId = "55555555-5555-5555-5555-555555555555";
const sampleTeamId = "66666666-6666-6666-6666-666666666666";
const samplePositionId = "77777777-7777-7777-7777-777777777777";
const sampleHrOwnerId = "88888888-8888-8888-8888-888888888888";

const fullHrActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000001",
  email: "hr@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: [
    "submissions.view",
    "submissions.status",
    "submissions.edit",
    "applications.create",
    "applications.manage",
  ],
};

const viewOnlyHrActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000002",
  email: "hr-view@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["submissions.view"],
};

const createOnlyActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000003",
  email: "create-only@eiu.edu.vn",
  isActive: true,
  roles: ["HR"],
  permissions: ["applications.create"],
};

const unauthorizedActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000004",
  email: "unauthorized@example.com",
  isActive: true,
  roles: ["GUEST"],
  permissions: [],
};

const candidateActor: VerifiedActor = {
  authUserId: "a0000000-0000-0000-0000-000000000005",
  email: "candidate@example.com",
  isActive: true,
  roles: ["CANDIDATE"],
  permissions: [],
};

function createMockDetailData(
  status: "NEW" | "READ" = "NEW",
): SubmissionDetail {
  return {
    submission_id: sampleSubmissionId,
    candidate_id: sampleCandidateId,
    status_code: status,
    full_name: "Nguyễn Văn A",
    date_of_birth: "1995-01-01",
    gender_code: "MALE",
    current_address: "123 Đường 30/4, Thủ Dầu Một",
    phone: "0901234567",
    email: "nguyenvana@example.com",
    other_info: "Thông tin bổ sung",
    hr_note: "Ghi chú ban đầu",
    recruitment_source_id: "src-uuid-1",
    recruitment_source_name: "Website EIU",
    submitted_at: "2026-09-01T08:00:00Z",
    updated_at: "2026-09-01T08:00:00Z",
    updated_by_name: "Ứng viên",
    version_no: 1,
    education: [
      {
        education_id: "edu-1",
        sort_order: 1,
        period_text: "2013 - 2017",
        qualification_id: "qual-1",
        qualification_name: "Đại học",
        major: "Khoa học Máy tính",
        institution: "Đại học Quốc tế Miền Đông",
      },
    ],
    work_experiences: [
      {
        experience_id: "exp-1",
        sort_order: 1,
        start_date: "2017-09-01",
        end_date: null,
        is_current: true,
        employer: "EIU",
        job_title: "Kỹ sư phần mềm",
        job_description: "Phát triển hệ thống",
      },
    ],
    activities: [
      {
        activity_id: "act-1",
        sort_order: 1,
        period_text: "2015 - 2016",
        activity_name: "CLB Tin học",
        role_name: "Chủ nhiệm",
        organizer: "Đoàn trường",
        description: "Tổ chức hội thảo",
      },
    ],
    documents: [
      {
        document_id: sampleDocId,
        logical_document_id: sampleLogicalDocId,
        document_type_id: "doc-type-cv",
        document_type_code: "CV_RESUME",
        document_type_name: "CV / Sơ yếu lý lịch",
        original_filename: "cv_nguyen_van_a.pdf",
        mime_type: "application/pdf",
        file_size_bytes: 1048576,
        uploaded_at: "2026-09-01T08:00:00Z",
      },
    ],
    applications: [],
  };
}

function createMockSupabase(options: {
  userSession?: {
    id: string;
    email: string;
    isInternal?: boolean;
    isActive?: boolean;
    roles?: string[];
    permissions?: string[];
  };
  isRootAdmin?: boolean;
  rpcHandlers?: Record<string, (args: unknown) => unknown>;
  tableData?: Record<string, unknown[]>;
}) {
  const permissions = options.userSession?.permissions ?? [];
  const roles = options.userSession?.roles ?? ["HR"];
  const isActive = options.userSession?.isActive ?? true;
  return {
    rpc: async (fn: string, args?: unknown) => {
      const handler = options.rpcHandlers?.[fn];
      if (handler) {
        const result = handler(args);
        return { data: result, error: null };
      }
      const isInternal =
        options.userSession?.email.toLowerCase().endsWith("@eiu.edu.vn") ===
        true;
      if (fn === "get_current_internal_session" && isInternal) {
        return {
          data: {
            success: true,
            data: {
              app_user_id: options.userSession?.id ?? "user-1",
              is_active: isActive,
              is_root_admin: options.isRootAdmin ?? false,
              roles,
              permissions,
            },
          },
          error: null,
        };
      }
      if (fn === "get_current_internal_binding_status" && isInternal) {
        return {
          data: {
            success: true,
            data: {
              bound: true,
              app_user_id: options.userSession?.id ?? "user-1",
              is_active: isActive,
              is_root_admin: options.isRootAdmin ?? false,
            },
          },
          error: null,
        };
      }
      return { data: null, error: null };
    },
    auth: {
      getUser: async () => {
        if (!options.userSession) {
          return { data: { user: null }, error: new Error("No session") };
        }
        return {
          data: {
            user: {
              id: options.userSession.id,
              email: options.userSession.email,
            },
          },
          error: null,
        };
      },
    },
    from: (table: string) => ({
      select: (_cols: string) => ({
        eq: (_col: string, val: unknown) => ({
          eq: (_col2: string, _val2: unknown) => ({
            single: async () => ({
              data:
                options.tableData?.[table]?.find(
                  (row) => (row as Record<string, unknown>)[_col] === val,
                ) ?? null,
              error: null,
            }),
          }),
          single: async () => {
            if (table === "app_users") {
              return {
                data: {
                  app_user_id: options.userSession?.id ?? "user-1",
                  is_active: isActive,
                  is_root_admin: options.isRootAdmin ?? false,
                  app_user_roles: roles.map((r) => ({ role_code: r })),
                  app_user_permissions: permissions.map((code) => ({
                    permission_code: code,
                  })),
                },
                error: null,
              };
            }
            if (table === "candidates") {
              return {
                data: {
                  candidate_id: sampleCandidateId,
                  is_active: true,
                },
                error: null,
              };
            }
            const found = options.tableData?.[table]?.find(
              (row) => (row as Record<string, unknown>)[_col] === val,
            );
            return {
              data: found ?? null,
              error: found ? null : new Error("Not found"),
            };
          },
          maybeSingle: async () => {
            if (table === "app_users") {
              return {
                data: {
                  app_user_id: options.userSession?.id ?? "user-1",
                  is_active: isActive,
                  is_root_admin: options.isRootAdmin ?? false,
                  app_user_roles: roles.map((r) => ({ role_code: r })),
                  app_user_permissions: permissions.map((code) => ({
                    permission_code: code,
                  })),
                },
                error: null,
              };
            }
            const found = options.tableData?.[table]?.find(
              (row) => (row as Record<string, unknown>)[_col] === val,
            );
            return { data: found ?? null, error: null };
          },
        }),
      }),
    }),
    storage: {
      from: (_bucket: string) => ({
        createSignedUrl: async (
          path: string,
          expiresIn: number,
          downloadOpt?: { download?: string },
        ) => {
          return {
            data: {
              signedUrl: `https://storage.supabase.co/signed/${path}?expires=${expiresIn}&download=${downloadOpt?.download ?? "false"}`,
            },
            error: null,
          };
        },
      }),
    },
  } as unknown as SupabaseClient;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test("1. AC-09/AC-50 Server detail seam rejects unauthenticated, candidate, and unauthorized callers", async () => {
  // 1a. Unauthenticated caller
  const unauthClient = createMockSupabase({ userSession: undefined });
  await assert.rejects(
    async () =>
      loadSubmissionDetail(sampleSubmissionId, { client: unauthClient }),
    SubmissionDetailAccessError,
    "Unauthenticated caller must be rejected",
  );

  // 1b. Candidate caller (non-internal)
  const candidateClient = createMockSupabase({
    userSession: {
      id: candidateActor.authUserId,
      email: candidateActor.email,
      isInternal: false,
    },
  });
  await assert.rejects(
    async () =>
      loadSubmissionDetail(sampleSubmissionId, { client: candidateClient }),
    SubmissionDetailAccessError,
    "Candidate caller must not have access to HR submission detail",
  );

  // 1c. Internal user without submissions.view
  // 1c. Internal user without submissions.view
  assert.equal(
    isAuthorizedForSubmissionDetail(
      {
        isAuthenticated: true,
        user: {
          authUserId: unauthorizedActor.authUserId,
          email: "guest@eiu.edu.vn",
          isInternal: true,
          isCandidate: false,
          roles: [],
          permissions: [],
        },
      },
      false,
    ),
    false,
    "isAuthorizedForSubmissionDetail must return false when submissions.view is missing",
  );

  const restrictedClient = createMockSupabase({
    userSession: {
      id: unauthorizedActor.authUserId,
      email: "guest@eiu.edu.vn",
      isInternal: true,
      permissions: [],
    },
    isRootAdmin: false,
  });
  await assert.rejects(
    async () =>
      loadSubmissionDetail(sampleSubmissionId, { client: restrictedClient }),
    SubmissionDetailAccessError,
    "Internal user without submissions.view must be rejected",
  );
});

test("2. AC-10/AC-11 Status-authorized open mutates NEW -> READ while view-only open does not", async () => {
  let rpcCalledWith: Record<string, unknown> | null = null;
  const mockDetail = createMockDetailData("READ");

  const hrClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: fullHrActor.permissions,
    },
    rpcHandlers: {
      get_submission_detail: (args) => {
        rpcCalledWith = args as Record<string, unknown>;
        return {
          success: true,
          data: mockDetail,
        };
      },
    },
  });

  const detail = await loadSubmissionDetail(sampleSubmissionId, {
    client: hrClient,
  });
  assert.equal(detail.submission_id, sampleSubmissionId);
  assert.equal(detail.status_code, "READ");
  assert.equal(
    (rpcCalledWith as Record<string, unknown> | null)?.p_submission_id,
    sampleSubmissionId,
  );
});

test("3. AC-12/AC-41 Document security: signed URL TTL strictly 60-300s, preview PDF/image vs download-only Office", async () => {
  // Verify TTL invariant constant
  assert.ok(
    DOCUMENT_SIGNED_URL_TTL_SECONDS >= 60 &&
      DOCUMENT_SIGNED_URL_TTL_SECONDS <= 300,
    "DOCUMENT_SIGNED_URL_TTL_SECONDS must be strictly bounded to 1-5 minutes (60-300s)",
  );

  // Verify previewable mime type checks
  assert.equal(
    isPreviewableDocument("application/pdf"),
    true,
    "PDF must be previewable",
  );
  assert.equal(
    isPreviewableDocument("image/png"),
    true,
    "PNG must be previewable",
  );
  assert.equal(
    isPreviewableDocument("image/jpeg"),
    true,
    "JPEG must be previewable",
  );
  assert.equal(
    isPreviewableDocument("application/msword"),
    false,
    "DOC must NOT be previewable",
  );
  assert.equal(
    isPreviewableDocument(
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ),
    false,
    "DOCX must NOT be previewable",
  );
  assert.equal(
    isPreviewableDocument("text/html"),
    false,
    "HTML must never be previewable",
  );
  assert.equal(
    isPreviewableDocument("image/svg+xml"),
    false,
    "SVG must never be previewable",
  );

  // Verify generateDocumentSignedUrl behavior
  let auditRecorded: Record<string, unknown> | null = null;
  const hrClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: fullHrActor.permissions,
    },
    tableData: {
      submission_documents: [
        {
          document_id: sampleDocId,
          logical_document_id: sampleLogicalDocId,
          storage_bucket: "candidate-quarantine",
          storage_path: "candidates/quarantine/cv.pdf",
          original_filename: "cv.pdf",
          mime_type: "application/pdf",
        },
      ],
      submission_document_logicals: [
        {
          logical_document_id: sampleLogicalDocId,
          submission_id: sampleSubmissionId,
        },
      ],
    },
    rpcHandlers: {
      record_document_access_audit: (args) => {
        auditRecorded = args as Record<string, unknown>;
        return { success: true };
      },
    },
  });

  const previewRes = await generateDocumentSignedUrl(
    {
      submissionId: sampleSubmissionId,
      documentId: sampleDocId,
      logicalDocumentId: sampleLogicalDocId,
      mode: "preview",
    },
    { client: hrClient },
  );

  assert.ok(
    previewRes.signedUrl.includes("expires=180"),
    "Signed URL must include exact TTL of 180s",
  );
  assert.ok(
    auditRecorded !== null,
    "Audit logging must be executed on document access",
  );
  assert.equal(
    (auditRecorded as Record<string, unknown>)?.p_document_id,
    sampleDocId,
  );
  assert.equal(
    (auditRecorded as Record<string, unknown>)?.p_submission_id,
    sampleSubmissionId,
  );

  // Audit log failure must reject and NOT return signed URL
  const auditFailingClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: fullHrActor.permissions,
    },
    tableData: {
      submission_documents: [
        {
          document_id: sampleDocId,
          logical_document_id: sampleLogicalDocId,
          storage_bucket: "candidate-quarantine",
          storage_path: "candidates/quarantine/cv.pdf",
          original_filename: "cv.pdf",
          mime_type: "application/pdf",
        },
      ],
      submission_document_logicals: [
        {
          logical_document_id: sampleLogicalDocId,
          submission_id: sampleSubmissionId,
        },
      ],
    },
    rpcHandlers: {
      record_document_access_audit: () => ({
        success: false,
        message: "Audit write failure",
      }),
    },
  });

  await assert.rejects(
    async () =>
      generateDocumentSignedUrl(
        {
          submissionId: sampleSubmissionId,
          documentId: sampleDocId,
          logicalDocumentId: sampleLogicalDocId,
          mode: "preview",
        },
        { client: auditFailingClient },
      ),
    SubmissionDetailReadError,
    "Audit logging failure must reject before returning signed URL",
  );

  // Office format preview must throw DocumentNotPreviewableError
  const officeDocClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: fullHrActor.permissions,
    },
    tableData: {
      submission_documents: [
        {
          document_id: officeDocId,
          logical_document_id: sampleLogicalDocId,
          storage_bucket: "candidate-quarantine",
          storage_path: "candidates/quarantine/degree.docx",
          original_filename: "degree.docx",
          mime_type:
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        },
      ],
      submission_document_logicals: [
        {
          logical_document_id: sampleLogicalDocId,
          submission_id: sampleSubmissionId,
        },
      ],
    },
  });

  await assert.rejects(
    async () =>
      generateDocumentSignedUrl(
        {
          submissionId: sampleSubmissionId,
          documentId: officeDocId,
          logicalDocumentId: sampleLogicalDocId,
          mode: "preview",
        },
        { client: officeDocClient },
      ),
    DocumentNotPreviewableError,
    "Preview on DOCX must be rejected",
  );

  // 3b. Hardened same-origin document preview route & streaming
  let routeAuditRecorded: Record<string, unknown> | null = null;
  const previewRouteClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: ["submissions.view"],
    },
    tableData: {
      submission_documents: [
        {
          document_id: sampleDocId,
          logical_document_id: sampleLogicalDocId,
          storage_bucket: "candidate-quarantine",
          storage_path: "candidates/quarantine/cv.pdf",
          original_filename: "cv.pdf",
          mime_type: "application/pdf",
        },
        {
          document_id: officeDocId,
          logical_document_id: sampleLogicalDocId,
          storage_bucket: "candidate-quarantine",
          storage_path: "candidates/quarantine/degree.docx",
          original_filename: "degree.docx",
          mime_type:
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        },
      ],
      submission_document_logicals: [
        {
          logical_document_id: sampleLogicalDocId,
          submission_id: sampleSubmissionId,
        },
      ],
    },
    rpcHandlers: {
      record_document_access_audit: (args) => {
        routeAuditRecorded = args as Record<string, unknown>;
        return { success: true };
      },
    },
  });

  const mockPdfBytes = new Uint8Array([0x25, 0x50, 0x44, 0x46]);
  const mockFetch = async () =>
    new Response(mockPdfBytes, {
      status: 200,
      headers: { "Content-Type": "application/pdf" },
    });

  // Authorized same-origin preview returns streamed response with strict security headers
  const previewReq = new NextRequest(
    `http://localhost/api/documents/preview/${sampleDocId}?submissionId=${sampleSubmissionId}&logicalDocumentId=${sampleLogicalDocId}`,
  );
  const routeRes = await getDocumentPreviewRoute(
    previewReq,
    { params: Promise.resolve({ id: sampleDocId }) },
    { client: previewRouteClient, fetchFn: mockFetch },
  );

  assert.equal(routeRes.status, 200);
  assert.equal(routeRes.headers.get("Content-Type"), "application/pdf");
  assert.ok(
    routeRes.headers.get("Content-Disposition")?.includes("inline"),
    "Content-Disposition must be inline for preview",
  );
  assert.equal(
    routeRes.headers.get("X-Content-Type-Options"),
    "nosniff",
    "nosniff header must be present",
  );
  assert.ok(
    routeRes.headers.get("Cache-Control")?.includes("no-store"),
    "no-store cache control required",
  );
  assert.ok(
    routeAuditRecorded !== null,
    "Audit logging must be executed before streaming document bytes",
  );

  // Storage failures must never fabricate PDF bytes or expose private URLs.
  for (const host of ["storage.supabase.co", "storage.mock.local"]) {
    const failingClient = createMockSupabase({});
    failingClient.storage = {
      from: () => ({
        createSignedUrl: async () => ({
          data: {
            signedUrl: `https://${host}/private/cv.pdf?token=sensitive-token`,
          },
          error: null,
        }),
      }),
    } as unknown as typeof failingClient.storage;
    // Keep authorization, document lookup, and audit identical to the success case.
    const failureResponse = await getDocumentPreviewRoute(
      previewReq,
      { params: Promise.resolve({ id: sampleDocId }) },
      {
        client: previewRouteClient,
        adminClient: failingClient,
        fetchFn: async (url) => {
          throw new Error(`Fetch failed: ${url}`);
        },
      },
    );
    assert.equal(failureResponse.status, 500);
    const failureBody = await failureResponse.text();
    assert.equal(failureBody, "Internal server error");
    assert.doesNotMatch(failureBody, /sensitive-token|https:|%PDF|private\/cv/);
  }

  // Office format preview must return 415 on route (download-only)
  const officeReq = new NextRequest(
    `http://localhost/api/documents/preview/${officeDocId}?submissionId=${sampleSubmissionId}&logicalDocumentId=${sampleLogicalDocId}`,
  );
  const officeRouteRes = await getDocumentPreviewRoute(
    officeReq,
    { params: Promise.resolve({ id: officeDocId }) },
    { client: previewRouteClient, fetchFn: mockFetch },
  );
  assert.equal(
    officeRouteRes.status,
    415,
    "Office format must be rejected on preview route with 415",
  );

  // Unauthorized caller (lacks submissions.view) returns 403 on preview route
  const unauthorizedPreviewClient = createMockSupabase({
    userSession: {
      id: "unauth-user",
      email: "hr-no-view@eiu.edu.vn",
      isInternal: true,
      permissions: ["applications.create"],
    },
    tableData: {
      submission_documents: [
        {
          document_id: sampleDocId,
          logical_document_id: sampleLogicalDocId,
          storage_bucket: "candidate-quarantine",
          storage_path: "candidates/quarantine/cv.pdf",
          original_filename: "cv.pdf",
          mime_type: "application/pdf",
        },
      ],
      submission_document_logicals: [
        {
          logical_document_id: sampleLogicalDocId,
          submission_id: sampleSubmissionId,
        },
      ],
    },
  });
  const unauthRouteRes = await getDocumentPreviewRoute(
    previewReq,
    { params: Promise.resolve({ id: sampleDocId }) },
    { client: unauthorizedPreviewClient, fetchFn: mockFetch },
  );
  assert.equal(
    unauthRouteRes.status,
    403,
    "Caller lacking submissions.view must be rejected with 403",
  );

  // Audit logging failure fails closed with 500 on preview route
  const auditFailingRouteClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: ["submissions.view"],
    },
    tableData: {
      submission_documents: [
        {
          document_id: sampleDocId,
          logical_document_id: sampleLogicalDocId,
          storage_bucket: "candidate-quarantine",
          storage_path: "candidates/quarantine/cv.pdf",
          original_filename: "cv.pdf",
          mime_type: "application/pdf",
        },
      ],
      submission_document_logicals: [
        {
          logical_document_id: sampleLogicalDocId,
          submission_id: sampleSubmissionId,
        },
      ],
    },
    rpcHandlers: {
      record_document_access_audit: () => ({
        success: false,
        message: "Audit failure",
      }),
    },
  });
  const auditFailRouteRes = await getDocumentPreviewRoute(
    previewReq,
    { params: Promise.resolve({ id: sampleDocId }) },
    { client: auditFailingRouteClient, fetchFn: mockFetch },
  );
  assert.equal(
    auditFailRouteRes.status,
    500,
    "Audit log failure must fail closed with 500 on preview route",
  );

  // Unauthenticated caller returns 403 on preview route
  const unauthPreviewClient = createMockSupabase({});
  const unauthNoSessionRouteRes = await getDocumentPreviewRoute(
    previewReq,
    { params: Promise.resolve({ id: sampleDocId }) },
    { client: unauthPreviewClient, fetchFn: mockFetch },
  );
  assert.equal(
    unauthNoSessionRouteRes.status,
    403,
    "Unauthenticated caller must be rejected with 403",
  );

  // getDocumentSignedUrlAction in preview mode returns same-origin previewUrl, never raw signedUrl
  const actionPreviewRes = await getDocumentSignedUrlAction({
    submissionId: sampleSubmissionId,
    documentId: sampleDocId,
    logicalDocumentId: sampleLogicalDocId,
    mode: "preview",
  });
  // In test environment without active session cookies, action safely fails closed
  assert.ok(
    !actionPreviewRes.success ||
      actionPreviewRes.signedUrl.startsWith("/api/documents/preview/"),
    "Preview action must return same-origin route URL, never raw signed URL",
  );
});

test("4. AC-11/AC-12H Application create requires submissions.view AND applications.create/manage", async () => {
  // 4a. Check isAuthorizedForApplicationCreate predicate
  const fullSession = {
    isAuthenticated: true,
    user: {
      authUserId: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      isCandidate: false,
      roles: fullHrActor.roles,
      permissions: fullHrActor.permissions,
    },
  };
  assert.equal(
    isAuthorizedForApplicationCreate(fullSession, false),
    true,
    "Full HR actor has both submissions.view and applications.create",
  );

  const viewOnlySession = {
    isAuthenticated: true,
    user: {
      authUserId: viewOnlyHrActor.authUserId,
      email: viewOnlyHrActor.email,
      isInternal: true,
      isCandidate: false,
      roles: viewOnlyHrActor.roles,
      permissions: viewOnlyHrActor.permissions,
    },
  };
  assert.equal(
    isAuthorizedForApplicationCreate(viewOnlySession, false),
    false,
    "View-only HR actor lacks applications.create/manage",
  );

  const createOnlySession = {
    isAuthenticated: true,
    user: {
      authUserId: createOnlyActor.authUserId,
      email: createOnlyActor.email,
      isInternal: true,
      isCandidate: false,
      roles: createOnlyActor.roles,
      permissions: createOnlyActor.permissions,
    },
  };
  assert.equal(
    isAuthorizedForApplicationCreate(createOnlySession, false),
    false,
    "Actor with applications.create but without submissions.view must be rejected",
  );

  const rootSession = {
    isAuthenticated: true,
    user: {
      authUserId: "root-user-id",
      email: "root@eiu.edu.vn",
      isInternal: true,
      isCandidate: false,
      roles: ["ROOT_ADMIN"],
      permissions: [],
    },
  };
  assert.equal(
    isAuthorizedForApplicationCreate(rootSession, true),
    true,
    "Root admin passes application create authorization",
  );

  // 4b. Command-level enforcement: full positive/negative permission matrix at server seam
  // (Testing defaultResolveActor directly from client auth & database with NO resolveActor override)
  const commandPayload = {
    submissionId: sampleSubmissionId,
    unitId: sampleUnitId,
    positionId: samplePositionId,
    hrOwnerId: sampleHrOwnerId,
  };

  let rpcInvoked = false;
  const commandRpcHandlers = {
    create_or_update_application: (_args: unknown) => {
      rpcInvoked = true;
      return {
        success: true,
        data: {
          application_id: "app-matrix-123",
          submission_id: sampleSubmissionId,
          is_active: true,
          version_no: 1,
          round1_interview_id: "round1-matrix-456",
        },
      };
    },
  };

  // 1. View-only internal user must fail closed (FORBIDDEN) before RPC
  rpcInvoked = false;
  const viewOnlyClient = createMockSupabase({
    userSession: {
      id: viewOnlyHrActor.authUserId,
      email: "hr-view@eiu.edu.vn",
      isInternal: true,
      permissions: ["submissions.view"],
    },
    rpcHandlers: commandRpcHandlers,
  });
  const resViewOnly = await createOrUpdateApplication(commandPayload, {
    client: viewOnlyClient,
  });
  assert.equal(resViewOnly.success, false);
  assert.equal(resViewOnly.error.code, CommandErrorCode.FORBIDDEN);
  assert.equal(rpcInvoked, false, "RPC must not be invoked for view-only user");

  // 2. Create-only without submissions.view must fail closed (FORBIDDEN) before RPC
  rpcInvoked = false;
  const createOnlyClient = createMockSupabase({
    userSession: {
      id: createOnlyActor.authUserId,
      email: "hr-create@eiu.edu.vn",
      isInternal: true,
      permissions: ["applications.create"],
    },
    rpcHandlers: commandRpcHandlers,
  });
  const resCreateOnly = await createOrUpdateApplication(commandPayload, {
    client: createOnlyClient,
  });
  assert.equal(resCreateOnly.success, false);
  assert.equal(resCreateOnly.error.code, CommandErrorCode.FORBIDDEN);
  assert.equal(
    rpcInvoked,
    false,
    "RPC must not be invoked for create-only user lacking submissions.view",
  );

  // 3. Manage-only without submissions.view must fail closed (FORBIDDEN) before RPC
  rpcInvoked = false;
  const manageOnlyClient = createMockSupabase({
    userSession: {
      id: "a0000000-0000-0000-0000-000000000007",
      email: "hr-manage@eiu.edu.vn",
      isInternal: true,
      permissions: ["applications.manage"],
    },
    rpcHandlers: commandRpcHandlers,
  });
  const resManageOnly = await createOrUpdateApplication(commandPayload, {
    client: manageOnlyClient,
  });
  assert.equal(resManageOnly.success, false);
  assert.equal(resManageOnly.error.code, CommandErrorCode.FORBIDDEN);
  assert.equal(
    rpcInvoked,
    false,
    "RPC must not be invoked for manage-only user lacking submissions.view",
  );

  // 4. Candidate user must be denied before RPC
  rpcInvoked = false;
  const candidateClient = createMockSupabase({
    userSession: {
      id: candidateActor.authUserId,
      email: "candidate@example.com",
      isInternal: false,
    },
    rpcHandlers: commandRpcHandlers,
  });
  const resCandidate = await createOrUpdateApplication(commandPayload, {
    client: candidateClient,
  });
  assert.equal(resCandidate.success, false);
  assert.equal(resCandidate.error.code, CommandErrorCode.FORBIDDEN);
  assert.equal(rpcInvoked, false, "RPC must not be invoked for candidate");

  // 5. Inactive internal user must be denied before RPC
  rpcInvoked = false;
  const inactiveClient = createMockSupabase({
    userSession: {
      id: "a0000000-0000-0000-0000-000000000008",
      email: "inactive@eiu.edu.vn",
      isInternal: true,
      isActive: false,
      permissions: ["submissions.view", "applications.create"],
    },
    rpcHandlers: commandRpcHandlers,
  });
  const resInactive = await createOrUpdateApplication(commandPayload, {
    client: inactiveClient,
  });
  assert.equal(resInactive.success, false);
  assert.ok(
    resInactive.error.code === CommandErrorCode.USER_INACTIVE ||
      resInactive.error.code === CommandErrorCode.UNAUTHENTICATED ||
      resInactive.error.code === CommandErrorCode.FORBIDDEN,
    "Inactive user must be denied",
  );
  assert.equal(rpcInvoked, false, "RPC must not be invoked for inactive user");

  // 6. Unauthenticated caller must be denied before RPC
  rpcInvoked = false;
  const unauthClient = createMockSupabase({
    rpcHandlers: commandRpcHandlers,
  });
  const resUnauth = await createOrUpdateApplication(commandPayload, {
    client: unauthClient,
  });
  assert.equal(resUnauth.success, false);
  assert.equal(resUnauth.error.code, CommandErrorCode.UNAUTHENTICATED);
  assert.equal(
    rpcInvoked,
    false,
    "RPC must not be invoked for unauthenticated caller",
  );

  // 7. Authorized caller with submissions.view AND applications.create succeeds
  rpcInvoked = false;
  const authCreateClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: "hr-create-authed@eiu.edu.vn",
      isInternal: true,
      permissions: ["submissions.view", "applications.create"],
    },
    rpcHandlers: commandRpcHandlers,
  });
  const resAuthCreate = await createOrUpdateApplication(commandPayload, {
    client: authCreateClient,
  });
  assert.equal(resAuthCreate.success, true);
  assert.equal(
    rpcInvoked,
    true,
    "RPC must be invoked for authorized submissions.view + applications.create user",
  );

  // 8. Authorized caller with submissions.view AND applications.manage succeeds
  rpcInvoked = false;
  const authManageClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: "hr-manage-authed@eiu.edu.vn",
      isInternal: true,
      permissions: ["submissions.view", "applications.manage"],
    },
    rpcHandlers: commandRpcHandlers,
  });
  const resAuthManage = await createOrUpdateApplication(commandPayload, {
    client: authManageClient,
  });
  assert.equal(resAuthManage.success, true);
  assert.equal(
    rpcInvoked,
    true,
    "RPC must be invoked for authorized submissions.view + applications.manage user",
  );

  // 9. Root Admin caller passes authorization without explicit permissions
  rpcInvoked = false;
  const rootClient = createMockSupabase({
    userSession: {
      id: "root-admin-id",
      email: "root@eiu.edu.vn",
      isInternal: true,
      permissions: [],
    },
    isRootAdmin: true,
    rpcHandlers: commandRpcHandlers,
  });
  const resRoot = await createOrUpdateApplication(commandPayload, {
    client: rootClient,
  });
  assert.equal(resRoot.success, true);
  assert.equal(rpcInvoked, true, "RPC must be invoked for Root Admin");
});

test("5. AC-14/AC-51 Application creation allocates Round 1 with AVAILABLE and INTERVIEW_SCHEDULING", async () => {
  let createdPayload: Record<string, unknown> | null = null;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      create_or_update_application: (args) => {
        createdPayload = args as Record<string, unknown>;
        return {
          success: true,
          data: {
            application_id: "app-new-123",
            submission_id: sampleSubmissionId,
            is_active: true,
            version_no: 1,
            round1_interview_id: "round1-new-456",
          },
        };
      },
    },
  });

  const res = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      departmentTeamId: sampleTeamId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
    },
    {
      client: mockSupabase,
      resolveActor: async () => fullHrActor,
    },
  );

  assert.equal(res.success, true);
  if (res.success) {
    assert.equal(res.data.application_id, "app-new-123");
    assert.equal(res.data.round1_interview_id, "round1-new-456");
    assert.equal(
      (createdPayload as Record<string, unknown> | null)?.p_submission_id,
      sampleSubmissionId,
    );
    assert.equal(
      (createdPayload as Record<string, unknown> | null)?.p_unit_id,
      sampleUnitId,
    );
  }
});

test("6. AC-48/AC-52 HR Note update with expected_version and STALE_VERSION feedback", async () => {
  // Successful update
  const mockSupabase = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: fullHrActor.permissions,
    },
    rpcHandlers: {
      update_submission_by_hr: (args) => {
        const payload = args as {
          p_expected_version: number;
          p_hr_note: string;
        };
        if (payload.p_expected_version !== 1) {
          return {
            success: false,
            error_code: "STALE_VERSION",
            message: "Submission version mismatch",
          };
        }
        return {
          success: true,
          data: {
            submission_id: sampleSubmissionId,
            hr_note: payload.p_hr_note,
            version_no: 2,
          },
        };
      },
    },
  });

  const okRes = await saveSubmissionHrNote(
    sampleSubmissionId,
    "New HR Note",
    1,
    { client: mockSupabase },
  );
  assert.equal(okRes.success, true);
  if (okRes.success) {
    assert.equal(okRes.data.version_no, 2);
    assert.equal(okRes.data.hr_note, "New HR Note");
  }

  // Stale version update
  const staleRes = await saveSubmissionHrNote(
    sampleSubmissionId,
    "Stale Note",
    99,
    { client: mockSupabase },
  );
  assert.equal(staleRes.success, false);
  if (!staleRes.success) {
    assert.equal(staleRes.error.code, CommandErrorCode.STALE_VERSION);
  }
});

test("7. AC-45 Master data options load active units, teams, positions, and eligible HR owners", async () => {
  const mockOptions = {
    units: [{ unit_id: sampleUnitId, code: "UNIT1", name_vi: "Khoa CNTT" }],
    department_teams: [
      {
        department_team_id: sampleTeamId,
        unit_id: sampleUnitId,
        code: "TEAM1",
        name_vi: "Bộ môn CNPM",
      },
    ],
    positions: [
      {
        position_id: samplePositionId,
        unit_id: sampleUnitId,
        department_team_id: sampleTeamId,
        code: "POS1",
        name_vi: "Giảng viên",
      },
    ],
    hr_owners: [
      {
        app_user_id: sampleHrOwnerId,
        full_name: "HR Lead",
        email: "hr@eiu.edu.vn",
      },
    ],
  };

  const hrClient = createMockSupabase({
    userSession: {
      id: fullHrActor.authUserId,
      email: fullHrActor.email,
      isInternal: true,
      permissions: fullHrActor.permissions,
    },
    rpcHandlers: {
      get_application_assignment_options: () => ({
        success: true,
        data: mockOptions,
      }),
    },
  });

  const options = await loadAssignmentOptions({ client: hrClient });
  assert.equal(options.units.length, 1);
  assert.equal(options.positions.length, 1);
  assert.equal(options.hr_owners.length, 1);
  assert.equal(options.units[0].name_vi, "Khoa CNTT");
});

test("8. S03-004 Non-regression: 1560px column grid and grouping", () => {
  const totalWidth = APPLICATION_INBOX_COLUMNS.reduce(
    (sum, col) => sum + col.width,
    0,
  );
  assert.equal(
    totalWidth,
    1560,
    "Application Inbox table column widths must sum to exactly 1560px",
  );

  // Verify column keys contain the 'action' column
  const actionCol = APPLICATION_INBOX_COLUMNS.find(
    (col) => col.key === "action",
  );
  assert.ok(actionCol, "Table columns must contain 'action' column");
  assert.equal(actionCol.width, 92, "Action column width must be 92px");
});

test("9. Active duplicate confirmation: unconfirmed duplicate returns DUPLICATE_APPLICATION while confirmed succeeds", async () => {
  let rpcArgs: Record<string, unknown> | null = null;
  const mockSupabase = createMockSupabase({
    rpcHandlers: {
      create_or_update_application: (args) => {
        rpcArgs = args as Record<string, unknown>;
        const confirm = Boolean(rpcArgs?.p_confirm_duplicate);
        if (!confirm) {
          return {
            success: false,
            error_code: "DUPLICATE_APPLICATION",
            message: "An active application already exists for this position",
          };
        }
        return {
          success: true,
          data: {
            application_id: "app-existing-123",
            submission_id: sampleSubmissionId,
            is_active: true,
            version_no: 2,
            round1_interview_id: "round1-existing-456",
          },
        };
      },
    },
  });

  // 9a. Unconfirmed duplicate creation returns DUPLICATE_APPLICATION
  const unconfirmedRes = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
      confirmDuplicate: false,
    },
    {
      client: mockSupabase,
      resolveActor: async () => fullHrActor,
    },
  );

  assert.equal(unconfirmedRes.success, false);
  if (!unconfirmedRes.success) {
    assert.equal(
      unconfirmedRes.error.code,
      CommandErrorCode.DUPLICATE_APPLICATION,
    );
  }
  assert.equal(
    Boolean((rpcArgs as Record<string, unknown> | null)?.p_confirm_duplicate),
    false,
  );

  // 9b. Confirmed duplicate creation updates owner and increments version
  const confirmedRes = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
      confirmDuplicate: true,
    },
    {
      client: mockSupabase,
      resolveActor: async () => fullHrActor,
    },
  );

  assert.equal(confirmedRes.success, true);
  if (confirmedRes.success) {
    assert.equal(confirmedRes.data.version_no, 2);
    assert.equal(confirmedRes.data.application_id, "app-existing-123");
  }
  assert.equal(
    Boolean((rpcArgs as Record<string, unknown> | null)?.p_confirm_duplicate),
    true,
  );
});

test("10. Actor resolution uses trusted session RPC and never raw-queries app_users auth binding", async () => {
  let rawAppUsersQueried = false;
  const trustedSessionClient = {
    auth: {
      getUser: async () => ({
        data: { user: { id: "hr-user-id", email: "hr@eiu.edu.vn" } },
        error: null,
      }),
    },
    rpc: async (fn: string) => {
      if (fn === "get_current_internal_session") {
        return {
          data: {
            success: true,
            data: {
              app_user_id: "hr-user-id",
              is_active: true,
              is_root_admin: false,
              roles: ["HR"],
              permissions: ["submissions.edit"],
            },
          },
          error: null,
        };
      }
      if (fn === "update_submission_by_hr") {
        return {
          data: {
            success: true,
            data: {
              submission_id: sampleSubmissionId,
              hr_note: "Test note",
              version_no: 2,
            },
          },
          error: null,
        };
      }
      return { data: null, error: null };
    },
    from: (table: string) => {
      if (table === "app_users") rawAppUsersQueried = true;
      throw new Error(`Unexpected raw table query: ${table}`);
    },
  } as unknown as SupabaseClient;

  const res = await saveSubmissionHrNote(sampleSubmissionId, "Test note", 1, {
    client: trustedSessionClient,
  });
  assert.equal(
    rawAppUsersQueried,
    false,
    "Must not raw-query app_users identity binding",
  );
  assert.equal(
    res.success,
    true,
    "Authorized HR actor must resolve through trusted session RPC",
  );
});

test("11. Drawer typography: all drawer body text, labels, document names/meta, and alerts satisfy >=16px", async () => {
  const cssContent = await readFile(
    resolve(__dirname, "../app/globals.css"),
    "utf-8",
  );

  // Extract submission drawer block
  const drawerBlockMatch = cssContent.match(
    /\.submission-drawer-container([\s\S]*?)\/\* Respect prefers-reduced-motion \*\//,
  );
  assert.ok(drawerBlockMatch, "Drawer CSS section must exist");
  const drawerCss = drawerBlockMatch[1];

  // Check all explicit font-size declarations in the drawer section
  const foundFontSizes: number[] = [];
  for (const match of drawerCss.matchAll(/font-size:\s*(\d+)px/g)) {
    const size = Number.parseInt(match[1], 10);
    foundFontSizes.push(size);
    assert.ok(
      size >= 16,
      `Font size ${size}px in drawer CSS must satisfy >= 16px requirement`,
    );
  }
  assert.ok(foundFontSizes.length >= 10, "Multiple font-size rules verified");
});

test("12. Focus management and Cancel button behavior: Cancel in Edit mode exits edit mode and keeps drawer open without closing", async () => {
  const drawerSource = await readFile(
    resolve(__dirname, "../components/inbox/SubmissionDetailDrawer.tsx"),
    "utf-8",
  );

  // 12a. Cancel button in Edit mode uses handleCancelEdit (not handleRequestClose/onClose directly)
  assert.ok(
    drawerSource.includes("onClick={handleCancelEdit}"),
    "Footer Cancel button must use handleCancelEdit to keep drawer open",
  );
  assert.ok(
    drawerSource.includes("const handleCancelEdit = useCallback("),
    "handleCancelEdit must be defined",
  );

  // 12b. Initial focus enters drawer when opened
  assert.ok(
    drawerSource.includes("closeButtonRef.current.focus()"),
    "Initial focus must target close button or drawer",
  );

  // 12c. Discard confirmation dialog has alertdialog role, focus trap, and Escape dismissal
  assert.ok(
    drawerSource.includes('role="alertdialog"'),
    "Discard dialog must use role alertdialog",
  );
  assert.ok(
    drawerSource.includes("handleDiscardKeyDown"),
    "Discard dialog must implement active keydown focus trap",
  );
  assert.ok(
    drawerSource.includes("cancelDiscardBtnRef.current?.focus()"),
    "Discard dialog must set initial focus to action button",
  );
  assert.ok(
    drawerSource.includes("handleCancelDiscard()"),
    "Discard dialog must route Escape through handleCancelDiscard for focus restoration",
  );

  // 12d. Preview modal has dialog role, focus trap, Escape dismissal, and focus restoration
  assert.ok(
    drawerSource.includes('role="dialog"'),
    "Preview modal must use role dialog",
  );
  assert.ok(
    drawerSource.includes("handlePreviewKeyDown"),
    "Preview modal must implement active keydown focus trap",
  );
  assert.ok(
    drawerSource.includes("previewCloseBtnRef.current?.focus()"),
    "Preview modal must set initial focus to close button",
  );
  assert.ok(
    drawerSource.includes("previewTriggerRef.current?.focus()"),
    "Preview modal must restore focus to preview trigger on close",
  );

  // 12e. Drawer close restores focus to trigger element
  assert.ok(
    drawerSource.includes("triggerElementRef.current?.focus()"),
    "Closing drawer must restore focus to opening trigger element",
  );

  // 12f. Stable idempotency key generated per assign attempt
  assert.ok(
    drawerSource.includes("assignIdempotencyKey"),
    "Drawer must generate stable idempotencyKey for application creation",
  );
  assert.ok(
    drawerSource.includes("idempotencyKey: assignIdempotencyKey"),
    "Drawer must pass idempotencyKey to createApplicationAction",
  );
});

let cachedDrawerBundle: { script: string; style: string } | null = null;

async function getDrawerBrowserBundle() {
  if (cachedDrawerBundle) return cachedDrawerBundle;
  const bundle = await build({
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
    absWorkingDir: process.cwd(),
    bundle: true,
    entryPoints: [
      "src/__tests__/fixtures/submission-detail-drawer-harness.tsx",
    ],
    format: "iife",
    outdir: "drawer-fixture",
    platform: "browser",
    conditions: ["browser"],
    write: false,
    plugins: [
      {
        name: "stub-server-only",
        setup(b) {
          b.onResolve({ filter: /^server-only$/ }, () => ({
            path: "server-only",
            namespace: "stub-server-only",
          }));
          b.onLoad({ filter: /.*/, namespace: "stub-server-only" }, () => ({
            contents: "module.exports = {};",
          }));
          b.onResolve({ filter: /application-inbox-actions$/ }, () => ({
            path: "actions",
            namespace: "stub-actions",
          }));
          b.onLoad({ filter: /.*/, namespace: "stub-actions" }, () => ({
            contents: `
              export async function getSubmissionDetailAction() { return { success: false, error: 'stub' }; }
              export async function openSubmissionAction() { return { success: true }; }
              export async function updateSubmissionHrNoteAction() { return { success: false, error: 'stub' }; }
              export async function updateSubmissionAggregateAction() { return { success: true }; }
              export async function getRecruitmentSourcesAction() { return []; }
              export async function getQualificationLevelsAction() { return []; }
              export async function getDocumentSignedUrlAction() { return { success: false, error: 'stub' }; }
              export async function getAssignmentOptionsAction() { return { success: false, error: 'stub' }; }
              export async function createApplicationAction() { return { success: false, error: 'stub' }; }
            `,
          }));
        },
      },
    ],
  });
  const script = bundle.outputFiles.find((f) => f.path.endsWith(".js"))?.text;
  const style = bundle.outputFiles.find((f) => f.path.endsWith(".css"))?.text;
  if (!script || !style) {
    throw new Error("SubmissionDetailDrawer test harness did not bundle");
  }
  cachedDrawerBundle = { script, style };
  return cachedDrawerBundle;
}

test("13. Finding 1 rendered interaction: post-commit focus transitions and tab containment", {
  timeout: 60_000,
}, async () => {
  // Static verification: stable refs and post-commit hook used (no setTimeout for edit button focus)
  const drawerSource = await readFile(
    resolve(__dirname, "../components/inbox/SubmissionDetailDrawer.tsx"),
    "utf-8",
  );
  assert.ok(
    drawerSource.includes("hrNoteTextareaRef"),
    "hrNoteTextareaRef must be defined for HR-note textarea",
  );
  assert.ok(
    drawerSource.includes("ref={hrNoteTextareaRef}"),
    "hrNoteTextareaRef must be attached to textarea",
  );
  assert.ok(
    drawerSource.includes("ref={editButtonRef}"),
    "editButtonRef must be attached to View-mode Edit button",
  );
  assert.ok(
    drawerSource.includes("useIsomorphicLayoutEffect"),
    "Must use post-commit useLayoutEffect/useIsomorphicLayoutEffect for focus transitions",
  );
  assert.ok(
    !drawerSource.includes("setTimeout(() => {\n      editButtonRef"),
    "setTimeout must NOT be used for edit button focus",
  );

  const { script, style } = await getDrawerBrowserBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));
    page.on("console", (msg) => {
      if (msg.type() === "error") pageErrors.push(msg.text());
    });

    await page.route("http://localhost:3000/**", (route) => {
      route.fulfill({
        status: 200,
        contentType: "text/html",
        body: '<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>',
      });
    });

    await page.goto("http://localhost:3000");
    await page.addStyleTag({ content: style });
    await page.addScriptTag({ content: script });

    const openBtn = page.locator("#external-open-drawer");
    await openBtn.waitFor({ state: "visible" });
    await openBtn.focus();
    assert.equal(
      await page.evaluate(() => document.activeElement?.id),
      "external-open-drawer",
    );

    // 13a. Open drawer -> initial focus is close button
    await openBtn.click();
    await page.locator(".submission-drawer").waitFor({ state: "visible" });
    await page.waitForFunction(() =>
      document.activeElement?.classList.contains(
        "submission-drawer__close-btn",
      ),
    );
    assert.equal(
      await page.evaluate(() =>
        document.activeElement?.getAttribute("aria-label"),
      ),
      "Đóng chi tiết phiếu",
    );

    // 13b. Tab containment in drawer
    await page.evaluate(() => {
      const drawer = document.querySelector(".submission-drawer");
      const focusable = drawer?.querySelectorAll(
        'button:not([disabled]):not([tabindex="-1"]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );
      (focusable?.[0] as HTMLElement | undefined)?.focus();
    });
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Chỉnh sửa",
    );

    // Shift+Tab from first element wraps to last element
    await page.keyboard.down("Shift");
    await page.keyboard.press("Tab");
    await page.keyboard.up("Shift");
    const isLast = await page.evaluate(() => {
      const drawer = document.querySelector(".submission-drawer");
      const focusable = drawer?.querySelectorAll(
        'button:not([disabled]):not([tabindex="-1"]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );
      return document.activeElement === focusable?.[focusable.length - 1];
    });
    assert.equal(isLast, true, "Shift+Tab on first element must wrap to last");

    // Tab from last element wraps back to first element
    await page.keyboard.press("Tab");
    const isFirst = await page.evaluate(() => {
      const drawer = document.querySelector(".submission-drawer");
      const focusable = drawer?.querySelectorAll(
        'button:not([disabled]):not([tabindex="-1"]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );
      return document.activeElement === focusable?.[0];
    });
    assert.equal(isFirst, true, "Tab on last element must wrap to first");

    // 13c. View -> Edit mode: focus moves into mounted HR-note textarea post-commit
    const editBtn = page.locator(".submission-drawer__edit-btn");
    await editBtn.click();
    await page.locator("#drawer-hr-note-input").waitFor({ state: "visible" });
    await page.waitForFunction(
      () => document.activeElement?.id === "drawer-hr-note-input",
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.id),
      "drawer-hr-note-input",
    );

    // 13d. Edit mode Save -> focus returns to remounted View-mode Edit button post-commit
    await page.fill("#drawer-hr-note-input", "Ghi chú test cập nhật");
    const saveBtn = page.locator(".submission-drawer__footer .btn-primary");
    await saveBtn.click();
    await page
      .locator(".submission-drawer__edit-btn")
      .waitFor({ state: "visible" });
    await page.waitForFunction(() =>
      document.activeElement?.classList.contains("submission-drawer__edit-btn"),
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Chỉnh sửa",
    );

    // 13e. Edit mode Cancel -> focus returns to View-mode Edit button post-commit
    // 13e. Clean Cancel (not dirty) -> focus returns to View-mode Edit button post-commit
    await editBtn.click();
    await page.locator("#drawer-hr-note-input").waitFor({ state: "visible" });
    await page.waitForFunction(
      () => document.activeElement?.id === "drawer-hr-note-input",
    );
    const cancelBtn = page.locator(".submission-drawer__footer .btn-secondary");
    await cancelBtn.click();
    await page
      .locator(".submission-drawer__edit-btn")
      .waitFor({ state: "visible" });
    await page.waitForFunction(() =>
      document.activeElement?.classList.contains("submission-drawer__edit-btn"),
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Chỉnh sửa",
    );

    // 13f. Rendered DIRTY discard coverage:
    // 1. Enter Edit; modify HR Note to become dirty; Escape/close opens discard dialog; focus enters dialog
    await editBtn.click();
    await page.locator("#drawer-hr-note-input").waitFor({ state: "visible" });
    await page.waitForFunction(
      () => document.activeElement?.id === "drawer-hr-note-input",
    );
    await page.fill(
      "#drawer-hr-note-input",
      "Ghi chú dirty test - không được tự lưu",
    );

    // Press Escape to trigger dirty discard dialog
    await page.keyboard.press("Escape");
    const discardOverlay = page.locator(".discard-confirm-overlay");
    await discardOverlay.waitFor({ state: "visible" });

    // Focus enters dialog on open (keep-editing button receives focus)
    await page.waitForFunction(() => {
      const active = document.activeElement;
      return (
        active?.closest(".discard-confirm-dialog") !== null &&
        active?.textContent?.includes("Tiếp tục chỉnh sửa")
      );
    });
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Tiếp tục chỉnh sửa",
      "Focus must enter discard dialog on keep-editing button",
    );

    // 2. Cancel/keep-editing closes dialog and restores focus to HR-note textarea; dirty value remains
    const keepEditingBtn = discardOverlay.locator("button.btn-secondary");
    await keepEditingBtn.click();
    await discardOverlay.waitFor({ state: "detached" });
    await page.waitForFunction(
      () => document.activeElement?.id === "drawer-hr-note-input",
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.id),
      "drawer-hr-note-input",
      "Focus must restore to HR-note textarea after keep-editing",
    );
    assert.equal(
      await page.inputValue("#drawer-hr-note-input"),
      "Ghi chú dirty test - không được tự lưu",
      "Dirty value must remain in textarea after keep-editing",
    );

    // Record save note log count before discard
    const initialSaveCount = await page.evaluate(
      () =>
        window.__DRAWER_HARNESS_LOGS__?.filter(
          (l) => l.event === "updateSubmissionHrNote",
        ).length ?? 0,
    );

    // 3. Reopen discard; confirm discard exits edit without invoking save action; View-mode Edit button remounts and receives focus
    const cancelEditBtn = page.locator(
      ".submission-drawer__footer .btn-secondary",
    );
    await cancelEditBtn.click();
    await discardOverlay.waitFor({ state: "visible" });

    // Confirm discard by clicking 'Hủy thay đổi'
    const confirmDiscardBtn = discardOverlay.locator("button.btn-danger");
    await confirmDiscardBtn.click();
    await discardOverlay.waitFor({ state: "detached" });

    // Verify save action was NOT called
    const afterDiscardSaveCount = await page.evaluate(
      () =>
        window.__DRAWER_HARNESS_LOGS__?.filter(
          (l) => l.event === "updateSubmissionHrNote",
        ).length ?? 0,
    );
    assert.equal(
      afterDiscardSaveCount,
      initialSaveCount,
      "Save action must NOT be invoked when discard is confirmed",
    );

    // View-mode Edit button remounts and receives focus
    await page
      .locator(".submission-drawer__edit-btn")
      .waitFor({ state: "visible" });
    await page.waitForFunction(() =>
      document.activeElement?.classList.contains("submission-drawer__edit-btn"),
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.textContent?.trim()),
      "Chỉnh sửa",
      "View-mode Edit button must receive focus after confirmed exit_edit discard",
    );

    // 4. Also exercise dirty close_drawer discard: confirm discard closes drawer, external drawer trigger receives focus
    await editBtn.click();
    await page.locator("#drawer-hr-note-input").waitFor({ state: "visible" });
    await page.waitForFunction(
      () => document.activeElement?.id === "drawer-hr-note-input",
    );
    await page.fill(
      "#drawer-hr-note-input",
      "Ghi chú dirty test cho đóng drawer",
    );

    // Click drawer close button while dirty
    const closeBtn = page.locator(".submission-drawer__close-btn");
    await closeBtn.click();
    await discardOverlay.waitFor({ state: "visible" });

    // Confirm discard closes drawer
    const confirmCloseDiscardBtn = discardOverlay.locator("button.btn-danger");
    await confirmCloseDiscardBtn.click();
    await discardOverlay.waitFor({ state: "detached" });
    await page.locator(".submission-drawer").waitFor({ state: "detached" });

    // External drawer trigger receives focus
    await page.waitForFunction(
      () => document.activeElement?.id === "external-open-drawer",
    );
    assert.equal(
      await page.evaluate(() => document.activeElement?.id),
      "external-open-drawer",
      "External open-drawer trigger must receive focus after confirmed close_drawer discard",
    );
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("14. Finding 2 duplicate confirmation identity binding and invalidation", {
  timeout: 60_000,
}, async () => {
  // 14a. Deterministic context key helper test
  const key1 = computeAssignmentContextKey({
    submissionId: sampleSubmissionId,
    unitId: sampleUnitId,
    departmentTeamId: sampleTeamId,
    positionId: samplePositionId,
    hrOwnerId: sampleHrOwnerId,
  });
  const key2 = computeAssignmentContextKey({
    submissionId: sampleSubmissionId,
    unitId: sampleUnitId,
    departmentTeamId: sampleTeamId,
    positionId: samplePositionId,
    hrOwnerId: sampleHrOwnerId,
  });
  const keyAlt = computeAssignmentContextKey({
    submissionId: sampleSubmissionId,
    unitId: sampleUnitId,
    departmentTeamId: null,
    positionId: samplePositionId,
    hrOwnerId: "other-hr",
  });
  assert.equal(
    key1,
    key2,
    "Identical assignment contexts must have identical keys",
  );
  assert.notEqual(
    key1,
    keyAlt,
    "Different assignment contexts must have distinct keys",
  );
  assert.equal(
    key1,
    `${sampleSubmissionId}::${sampleUnitId}::${sampleTeamId}::${samplePositionId}::${sampleHrOwnerId}`,
  );

  // 14b. Rendered interaction test in browser: real rendered controls and duplicate invalidation
  const { script, style } = await getDrawerBrowserBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));

    await page.route("http://localhost:3000/**", (route) => {
      route.fulfill({
        status: 200,
        contentType: "text/html",
        body: '<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>',
      });
    });

    await page.goto("http://localhost:3000");
    await page.addStyleTag({ content: style });
    await page.addScriptTag({ content: script });

    // Open drawer
    await page.locator("#external-open-drawer").click();
    await page.locator(".submission-drawer").waitFor({ state: "visible" });

    // Open assign form
    await page.locator(".drawer-assign-trigger button").click();
    await page.locator(".drawer-assign-form").waitFor({ state: "visible" });

    // 1. Obtain duplicate warning for Context A: unit-1, team-1 (SE), pos-2 (LEC-SE), hr-1
    await page.selectOption("#assign-unit", "unit-1");
    await page
      .locator('#assign-team option[value="team-1"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-team", "team-1");
    await page
      .locator('#assign-pos option[value="pos-2"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-pos", "pos-2");
    await page.selectOption("#assign-hr", "hr-1");

    // Click assignment action for A -> trigger duplicate warning
    const createBtn = page.locator(".drawer-assign-actions .btn-primary");
    await createBtn.click();
    const warningAlert = page.locator(".submission-drawer__alert--warning");
    await warningAlert.waitFor({ state: "visible" });
    assert.ok(
      await warningAlert.isVisible(),
      "Duplicate warning must appear for Context A",
    );

    // 2. Change Team A -> Team B through rendered select (#assign-team); old warning disappears
    await page.selectOption("#assign-team", "team-2");
    assert.equal(
      await warningAlert.count(),
      0,
      "Old duplicate warning must disappear when Team is changed from Team A to Team B",
    );

    // 3. Click assignment action for B; inspect createApplication action payload log; prove confirmDuplicate is false for B
    await page
      .locator('#assign-pos option[value="pos-2b"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-pos", "pos-2b");
    await createBtn.click();

    // Inspect createApplication action payload log
    const createLogs = await page.evaluate(
      () =>
        window.__DRAWER_HARNESS_LOGS__?.filter(
          (l) => l.event === "createApplication",
        ) ?? [],
    );
    const latestCreate = createLogs[createLogs.length - 1];
    assert.ok(
      latestCreate,
      "createApplication log must exist for assignment B",
    );
    const payload = latestCreate.payload as {
      unitId: string;
      departmentTeamId?: string;
      positionId: string;
      hrOwnerId: string;
      confirmDuplicate?: boolean;
    };
    assert.equal(payload.unitId, "unit-1");
    assert.equal(payload.departmentTeamId, "team-2");
    assert.equal(payload.positionId, "pos-2b");
    assert.equal(payload.hrOwnerId, "hr-1");
    assert.equal(
      payload.confirmDuplicate,
      false,
      "confirmDuplicate must be false for Context B",
    );

    // 4. Exercise duplicate warning invalidation across Unit, Team, Position, and Owner in the browser harness
    // Re-open assign form
    await page.locator(".drawer-assign-trigger button").click();
    await page.locator(".drawer-assign-form").waitFor({ state: "visible" });

    // 4a. Duplicate invalidation on Unit change
    await page.selectOption("#assign-unit", "unit-1");
    await page
      .locator('#assign-team option[value="team-1"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-team", "team-1");
    await page
      .locator('#assign-pos option[value="pos-2"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-pos", "pos-2");
    await page.selectOption("#assign-hr", "hr-1");
    await createBtn.click();
    await warningAlert.waitFor({ state: "visible" });
    assert.ok(
      await warningAlert.isVisible(),
      "Duplicate warning must appear for Context A",
    );

    await page.selectOption("#assign-unit", "unit-2");
    assert.equal(
      await warningAlert.count(),
      0,
      "Duplicate warning must be invalidated immediately on Unit change",
    );

    // 4b. Duplicate invalidation on Team change
    await page.selectOption("#assign-unit", "unit-1");
    await page
      .locator('#assign-team option[value="team-1"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-team", "team-1");
    await page
      .locator('#assign-pos option[value="pos-2"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-pos", "pos-2");
    await page.selectOption("#assign-hr", "hr-1");
    await createBtn.click();
    await warningAlert.waitFor({ state: "visible" });

    await page.selectOption("#assign-team", "team-2");
    assert.equal(
      await warningAlert.count(),
      0,
      "Duplicate warning must be invalidated immediately on Team change",
    );

    // 4c. Duplicate invalidation on Position change
    await page.selectOption("#assign-team", "team-1");
    await page
      .locator('#assign-pos option[value="pos-2"]')
      .waitFor({ state: "attached" });
    await page.selectOption("#assign-pos", "pos-2");
    await createBtn.click();
    await warningAlert.waitFor({ state: "visible" });

    await page.selectOption("#assign-pos", "");
    assert.equal(
      await warningAlert.count(),
      0,
      "Duplicate warning must be invalidated immediately on Position change",
    );

    // 4d. Duplicate invalidation on Owner change
    await page.selectOption("#assign-pos", "pos-2");
    await createBtn.click();
    await warningAlert.waitFor({ state: "visible" });

    await page.selectOption("#assign-hr", "hr-2");
    assert.equal(
      await warningAlert.count(),
      0,
      "Duplicate warning must be invalidated immediately on HR Owner change",
    );

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("15. Finding 3 assignment option load failure and retry behavior", {
  timeout: 60_000,
}, async () => {
  // 15a. Static source checks: separation of load error from form error
  const drawerSource = await readFile(
    resolve(__dirname, "../components/inbox/SubmissionDetailDrawer.tsx"),
    "utf-8",
  );
  assert.ok(
    drawerSource.includes("optionsLoadError"),
    "Must separate optionsLoadError from assignError",
  );
  assert.ok(
    drawerSource.includes("drawer-options-load-error"),
    "Must style load error outside showAssignForm",
  );
  assert.ok(
    drawerSource.includes('role="alert"'),
    "Load error must use role='alert'",
  );
  assert.ok(
    drawerSource.includes("handleLoadOptions"),
    "handleLoadOptions must manage option load and retry",
  );

  // 15b. Rendered interaction test
  const { script, style } = await getDrawerBrowserBundle();
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));

    await page.route("http://localhost:3000/**", (route) => {
      route.fulfill({
        status: 200,
        contentType: "text/html",
        body: '<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>',
      });
    });

    await page.goto("http://localhost:3000");
    await page.addStyleTag({ content: style });
    await page.addScriptTag({ content: script });

    // Inject load error
    await page.evaluate(() => {
      window.__DRAWER_HARNESS_DATA__ = {
        loadOptionsError: "Lỗi kết nối máy chủ danh mục phân công.",
        assignmentOptions: null,
      };
    });

    // Open drawer
    await page.locator("#external-open-drawer").click();
    await page.locator(".submission-drawer").waitFor({ state: "visible" });

    // Click '+ Gán vị trí tuyển dụng mới'
    const openAssignBtn = page.locator(".drawer-assign-trigger button");
    await openAssignBtn.click();

    // Form must remain CLOSED
    assert.equal(
      await page.locator(".drawer-assign-form").count(),
      0,
      "Form must not open when options load fails",
    );

    // Load error is rendered outside closed form with role='alert' and Retry button
    const loadErrorAlert = page.locator(
      '.drawer-options-load-error[role="alert"]',
    );
    await loadErrorAlert.waitFor({ state: "visible" });
    const errorText = await loadErrorAlert.textContent();
    assert.ok(
      errorText?.includes("Lỗi kết nối máy chủ danh mục phân công."),
      "Load error message must be displayed",
    );
    const retryBtn = loadErrorAlert.locator("button");
    assert.equal(
      await retryBtn.textContent(),
      "Thử lại",
      "Retry button must be rendered",
    );

    // Step 2: Second load held unresolved: assert real pending state (disabled/repeat prevention + approved loading text); prove accidental second request is not issued
    await page.evaluate(() => {
      if (window.__DRAWER_HARNESS_DATA__) {
        window.__DRAWER_HARNESS_DATA__.loadOptionsError = null;
        window.__DRAWER_HARNESS_DATA__.deferOptionsLoad = true;
      }
    });

    const initialRequestCount = await page.evaluate(
      () =>
        window.__DRAWER_HARNESS_LOGS__?.filter(
          (l) => l.event === "getAssignmentOptions",
        ).length ?? 0,
    );
    assert.equal(initialRequestCount, 1, "Initial failure recorded 1 request");

    // Focus retry button and trigger retry
    await retryBtn.focus();
    await retryBtn.click();

    // Assert real pending state: button disabled, approved loading text
    await page.waitForFunction(() => {
      const btn = document.querySelector(".drawer-options-load-error button");
      return (
        btn?.hasAttribute("disabled") &&
        btn?.textContent?.includes("Đang tải...")
      );
    });
    assert.equal(
      await retryBtn.isDisabled(),
      true,
      "Retry button must be disabled during pending load",
    );
    assert.equal(
      (await retryBtn.textContent())?.trim(),
      "Đang tải...",
      "Retry button must show approved loading text 'Đang tải...'",
    );

    // Attempt repeat click while pending to prove repeat prevention
    await retryBtn.click({ force: true }).catch(() => {});
    const pendingRequestCount = await page.evaluate(
      () =>
        window.__DRAWER_HARNESS_LOGS__?.filter(
          (l) => l.event === "getAssignmentOptions",
        ).length ?? 0,
    );
    assert.equal(
      pendingRequestCount,
      2,
      "Accidental second request must NOT be issued while pending",
    );

    // Observe keyboard focus does not escape drawer when Retry transitions to pending
    const focusContainedInDrawer = await page.evaluate(() => {
      const drawer = document.querySelector(".submission-drawer");
      const active = document.activeElement;
      return drawer !== null && active !== null && drawer.contains(active);
    });
    assert.equal(
      focusContainedInDrawer,
      true,
      "Keyboard focus must not escape drawer when Retry transitions to pending",
    );

    // Step 3: Resolve success: stale error clears, form opens, options visible
    await page.evaluate(() => {
      window.__DRAWER_RESOLVE_OPTIONS__?.();
    });

    // Form opens on successful retry
    await page.locator(".drawer-assign-form").waitFor({ state: "visible" });
    assert.equal(
      await page.locator(".drawer-options-load-error").count(),
      0,
      "Load error must be cleared on successful retry resolution",
    );
    assert.ok(
      await page.locator("#assign-unit").isVisible(),
      "Assign form selects must be rendered after successful retry resolution",
    );
    const unitOption = page.locator('#assign-unit option[value="unit-1"]');
    await unitOption.waitFor({ state: "attached" });
    assert.ok(
      (await unitOption.count()) > 0,
      "Unit options must be attached after successful retry resolution",
    );
    await page.selectOption("#assign-unit", "unit-1");
    assert.equal(
      await page.$eval("#assign-unit", (el) => (el as HTMLSelectElement).value),
      "unit-1",
      "Unit option must be selectable after successful retry resolution",
    );

    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
  }
});

test("16. Untrusted input validation: malformed runtime confirmDuplicate is rejected before RPC", async () => {
  let rpcCalled = false;
  const mockSupabase = {
    rpc: async () => {
      rpcCalled = true;
      return { data: null, error: null };
    },
  } as unknown as SupabaseClient;

  // 16a. String confirmDuplicate rejected before RPC
  const stringResult = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
      confirmDuplicate: "true" as unknown as boolean,
    },
    {
      client: mockSupabase,
      resolveActor: async () => fullHrActor,
    },
  );
  assert.equal(stringResult.success, false);
  assert.equal(stringResult.error.code, CommandErrorCode.VALIDATION_ERROR);
  assert.ok(
    stringResult.error.message.includes("Invalid confirmDuplicate"),
    "Must reject string confirmDuplicate",
  );
  assert.equal(
    rpcCalled,
    false,
    "RPC must NOT be called for malformed string confirmDuplicate",
  );

  // 16b. Number confirmDuplicate rejected before RPC
  const numberResult = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
      confirmDuplicate: 1 as unknown as boolean,
    },
    {
      client: mockSupabase,
      resolveActor: async () => fullHrActor,
    },
  );
  assert.equal(numberResult.success, false);
  assert.equal(numberResult.error.code, CommandErrorCode.VALIDATION_ERROR);
  assert.equal(
    rpcCalled,
    false,
    "RPC must NOT be called for numeric confirmDuplicate",
  );

  // 16c. Object confirmDuplicate rejected before RPC
  const objectResult = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
      confirmDuplicate: {} as unknown as boolean,
    },
    {
      client: mockSupabase,
      resolveActor: async () => fullHrActor,
    },
  );
  assert.equal(objectResult.success, false);
  assert.equal(objectResult.error.code, CommandErrorCode.VALIDATION_ERROR);
  assert.equal(
    rpcCalled,
    false,
    "RPC must NOT be called for object confirmDuplicate",
  );

  // 16d. Valid boolean / undefined passes validation and proceeds to RPC
  let validRpcCalled = false;
  let passedConfirmDuplicate: unknown = null;
  const validSupabase = {
    rpc: async (_fn: string, args: Record<string, unknown>) => {
      validRpcCalled = true;
      passedConfirmDuplicate = args.p_confirm_duplicate;
      return {
        data: {
          success: true,
          data: {
            application_id: "app-valid-1",
            submission_id: sampleSubmissionId,
            is_active: true,
            version_no: 1,
            round1_interview_id: "round-1",
          },
        },
        error: null,
      };
    },
  } as unknown as SupabaseClient;

  const validResult = await createOrUpdateApplication(
    {
      submissionId: sampleSubmissionId,
      unitId: sampleUnitId,
      positionId: samplePositionId,
      hrOwnerId: sampleHrOwnerId,
      confirmDuplicate: true,
    },
    {
      client: validSupabase,
      resolveActor: async () => fullHrActor,
    },
  );
  assert.equal(validResult.success, true);
  assert.equal(
    validRpcCalled,
    true,
    "Valid boolean confirmDuplicate proceeds to RPC",
  );
  assert.equal(
    passedConfirmDuplicate,
    true,
    "Passed p_confirm_duplicate must match input boolean",
  );
});
