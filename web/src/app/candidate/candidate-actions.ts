"use server";

import type { StagedDocumentItem } from "@/components/candidate/DocumentUploader";
import type { CandidateSubmissionSummary } from "@/components/candidate/SubmissionsList";
import { provisionCandidateIdentity } from "@/lib/auth/candidate";
import {
  type SubmitCandidateSubmissionInput,
  submitCandidateSubmission,
  type UpdateCandidateSubmissionInput,
  updateCandidateSubmission,
} from "@/lib/commands/candidate-submission";
import {
  cancelCandidateFormSession,
  refreshCandidateFormPrivacyNotice,
  startCandidateFormSession,
} from "@/lib/commands/form-session";
import {
  authorizeCandidateUploadScan,
  cancelCandidateDocumentChange,
  continueCleanCandidateDocumentScan,
  createSignedUploadUrlForReservation,
  recordInspectedUploadReservation,
  requestCandidateDocumentScan,
  reserveCandidateFormUpload,
  stageCandidateDocumentChange,
} from "@/lib/commands/storage-reservation";
import { expectedMimeForFilename } from "@/lib/storage/buckets";
import {
  createDriveTransport,
  driveLocation,
  driveServerConfig,
} from "@/lib/storage/drive-gateway";
import { inspectUploadReservation } from "@/lib/storage/upload-scanner";
import { createAdminClient } from "@/lib/supabase/admin";
import { createServerClient } from "@/lib/supabase/server";

export type CandidatePrivacyNotice = {
  version: string;
  contentVi: string;
  contentEn: string | null;
};

export type CandidateDocumentOption = {
  id: string;
  code: string;
  name: string;
  nameVi: string;
  nameEn: string | null;
};

export type CandidateEditData = {
  initialData: {
    fullName: string;
    phone: string;
    dateOfBirth: string;
    gender: "MALE" | "FEMALE" | "";
    address: string;
    education: Array<{
      periodText: string;
      qualificationId: string;
      major: string;
      institution: string;
    }>;
    documents: StagedDocumentItem[];
  };
  privacyAlreadyAcknowledged: boolean;
  privacyNotice: CandidatePrivacyNotice;
  pinnedPrivacyVersion: string;
  expiresAt: string;
};

export type CandidatePortalInitData = {
  candidateId: string;
  verifiedEmail: string;
  fullName: string;
  phone: string;
  isActive: boolean;
  pinnedPrivacyVersion: string;
  privacyNotice: CandidatePrivacyNotice;
  documentTypes: CandidateDocumentOption[];
  qualificationLevels: CandidateDocumentOption[];
  submissions: CandidateSubmissionSummary[];
};

export async function loadCandidatePortalData(): Promise<
  | { success: true; data: CandidatePortalInitData }
  | { success: false; error: string }
> {
  const supabase = await createServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user?.email) {
    return { success: false, error: "Authentication required" };
  }

  // Provision or resolve candidate identity
  const provisionRes = await provisionCandidateIdentity(supabase);
  if (!provisionRes.success || !provisionRes.data) {
    return {
      success: false,
      error: !provisionRes.success
        ? provisionRes.error.message
        : "Failed to provision candidate identity",
    };
  }

  const candidate = provisionRes.data;
  if (!candidate.is_active) {
    return { success: false, error: "Candidate account is inactive" };
  }

  // Load the immutable current privacy notice content and version.
  const { data: noticeData, error: noticeError } = await supabase
    .from("privacy_notice_versions")
    .select("notice_version, content_vi, content_en")
    .eq("is_current", true)
    .lte("effective_from", new Date().toISOString())
    .order("effective_from", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (
    noticeError ||
    !noticeData?.notice_version ||
    typeof noticeData.content_vi !== "string"
  ) {
    return { success: false, error: "Current privacy notice is unavailable" };
  }

  const pinnedPrivacyVersion = noticeData.notice_version;
  const privacyNotice: CandidatePrivacyNotice = {
    version: pinnedPrivacyVersion,
    contentVi: noticeData.content_vi,
    contentEn: noticeData.content_en,
  };

  // Load active document types with both language labels.
  const { data: docTypesData } = await supabase
    .from("document_types")
    .select("document_type_id, code, name_vi, name_en")
    .eq("is_active", true)
    .order("code");

  const documentTypes: CandidateDocumentOption[] = (docTypesData || []).map(
    (d) => ({
      id: d.document_type_id,
      code: d.code,
      nameVi: d.name_vi,
      nameEn: d.name_en,
      name: d.name_en ? `${d.name_vi} / ${d.name_en}` : d.name_vi,
    }),
  );

  // Load active qualification levels with both language labels.
  const { data: qualData } = await supabase
    .from("qualification_levels")
    .select("qualification_id, code, name_vi, name_en")
    .eq("is_active", true)
    .order("hierarchy_level", { ascending: true });

  const qualificationLevels: CandidateDocumentOption[] = (qualData || []).map(
    (q) => ({
      id: q.qualification_id,
      code: q.code,
      nameVi: q.name_vi,
      nameEn: q.name_en,
      name: q.name_en ? `${q.name_vi} / ${q.name_en}` : q.name_vi,
    }),
  );

  // Load persisted candidate submissions
  const { data: subsData } = await supabase
    .from("submissions")
    .select("submission_id, status_code, submitted_at, version_no")
    .eq("candidate_id", candidate.candidate_id)
    .order("submitted_at", { ascending: false });

  const submissions: CandidateSubmissionSummary[] = (subsData || []).map(
    (s) => ({
      submissionId: s.submission_id,
      submittedAt: s.submitted_at,
      statusCode: s.status_code as CandidateSubmissionSummary["statusCode"],
      versionNo: Number(s.version_no),
    }),
  );

  return {
    success: true,
    data: {
      candidateId: candidate.candidate_id,
      verifiedEmail: candidate.email,
      fullName: candidate.current_full_name || "",
      phone: candidate.current_phone || "",
      isActive: candidate.is_active,
      pinnedPrivacyVersion,
      privacyNotice,
      documentTypes,
      qualificationLevels,
      submissions,
    },
  };
}
export async function resumeFormSessionAction(
  mode: "NEW_SUBMISSION" | "EDIT_SUBMISSION",
  targetSubmissionId?: string,
) {
  const supabase = await createServerClient();
  let query = supabase
    .from("candidate_form_sessions")
    .select(
      "candidate_form_session_id, mode_code, target_submission_id, base_submission_version_no, presented_privacy_notice_version, status_code, expires_at",
    )
    .eq("mode_code", mode)
    .eq("status_code", "OPEN")
    .gt("expires_at", new Date().toISOString());

  query =
    targetSubmissionId === undefined
      ? query.is("target_submission_id", null)
      : query.eq("target_submission_id", targetSubmissionId);

  const { data, error } = await query
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error || !data) {
    return {
      success: false,
      error: error?.message || "No resumable form session",
    };
  }
  return { success: true, data };
}

export async function loadCandidateEditDataAction(
  sessionId: string,
): Promise<
  { success: true; data: CandidateEditData } | { success: false; error: string }
> {
  const supabase = await createServerClient();
  const { data: session, error: sessionError } = await supabase
    .from("candidate_form_sessions")
    .select(
      "target_submission_id, presented_privacy_notice_version, expires_at",
    )
    .eq("candidate_form_session_id", sessionId)
    .eq("status_code", "OPEN")
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();

  if (
    sessionError ||
    !session?.target_submission_id ||
    !session.presented_privacy_notice_version
  ) {
    return { success: false, error: "Editable form session not found" };
  }

  const { data: submission, error: submissionError } = await supabase
    .from("submissions")
    .select(
      "submission_id, full_name, phone, date_of_birth, gender_code, current_address",
    )
    .eq("submission_id", session.target_submission_id)
    .maybeSingle();

  if (submissionError || !submission) {
    return { success: false, error: "Submission not found or access denied" };
  }

  const { data: educationRows } = await supabase
    .from("submission_education")
    .select("sort_order, period_text, qualification_id, major, institution")
    .eq("submission_id", submission.submission_id)
    .order("sort_order", { ascending: true });

  const { data: logicalRows } = await supabase
    .from("submission_document_logicals")
    .select("logical_document_id, document_type_id")
    .eq("submission_id", submission.submission_id);

  const logicalIds = (logicalRows || []).map((row) => row.logical_document_id);
  const typeIds = (logicalRows || []).map((row) => row.document_type_id);
  const [{ data: documentRows }, { data: docTypeRows }] = await Promise.all([
    logicalIds.length > 0
      ? supabase
          .from("submission_documents")
          .select(
            "logical_document_id, original_filename, file_size_bytes, mime_type",
          )
          .eq("is_current", true)
          .in("logical_document_id", logicalIds)
      : Promise.resolve({ data: [] as never[] }),
    typeIds.length > 0
      ? supabase
          .from("document_types")
          .select("document_type_id, code, name_vi, name_en")
          .in("document_type_id", typeIds)
      : Promise.resolve({ data: [] as never[] }),
  ]);

  const docTypesById = new Map(
    (docTypeRows || []).map((row) => [
      row.document_type_id,
      {
        id: row.document_type_id,
        code: row.code,
        name: row.name_en ? `${row.name_vi} / ${row.name_en}` : row.name_vi,
      },
    ]),
  );
  const logicalTypeById = new Map(
    (logicalRows || []).map((row) => [
      row.logical_document_id,
      docTypesById.get(row.document_type_id),
    ]),
  );

  const documents: StagedDocumentItem[] = (documentRows || []).flatMap(
    (row) => {
      const docType = logicalTypeById.get(row.logical_document_id);
      if (!docType) return [];
      return [
        {
          reservationId: "",
          logicalDocumentId: row.logical_document_id,
          documentTypeId: docType.id,
          persisted: true,
          documentTypeCode: docType.code,
          documentTypeName: docType.name,
          filename: row.original_filename,
          fileSizeBytes: Number(row.file_size_bytes),
          isCv: docType.code === "CV_RESUME",
        },
      ];
    },
  );

  let pinnedPrivacyVersion = session.presented_privacy_notice_version;
  let expiresAt = session.expires_at;
  let { data: notice } = await supabase
    .from("privacy_notice_versions")
    .select("notice_version, content_vi, content_en")
    .eq("notice_version", pinnedPrivacyVersion)
    .maybeSingle();

  if (!notice?.notice_version || typeof notice.content_vi !== "string") {
    const refresh = await refreshCandidateFormPrivacyNotice(
      { sessionId },
      { client: supabase },
    );
    if (!refresh.success) {
      return { success: false, error: refresh.error.message };
    }
    pinnedPrivacyVersion = refresh.data.presented_privacy_notice_version;
    expiresAt = refresh.data.expires_at;
    notice = {
      notice_version: refresh.data.privacy_notice.notice_version,
      content_vi: refresh.data.privacy_notice.content_vi,
      content_en: refresh.data.privacy_notice.content_en,
    };
  }

  const { data: acknowledgement, error: acknowledgementError } = await supabase
    .from("privacy_acknowledgements")
    .select("notice_version")
    .eq("submission_id", submission.submission_id)
    .eq("notice_version", pinnedPrivacyVersion)
    .maybeSingle();

  if (acknowledgementError) {
    return { success: false, error: acknowledgementError.message };
  }

  return {
    success: true,
    data: {
      initialData: {
        fullName: submission.full_name || "",
        phone: submission.phone || "",
        dateOfBirth: submission.date_of_birth || "",
        gender:
          submission.gender_code === "MALE" ||
          submission.gender_code === "FEMALE"
            ? submission.gender_code
            : "",
        address: submission.current_address || "",
        education: (educationRows || []).map((row) => ({
          periodText: row.period_text || "",
          qualificationId: row.qualification_id || "",
          major: row.major || "",
          institution: row.institution || "",
        })),
        documents,
      },
      privacyAlreadyAcknowledged: Boolean(acknowledgement),
      pinnedPrivacyVersion,
      expiresAt,
      privacyNotice: {
        version: notice.notice_version,
        contentVi: notice.content_vi,
        contentEn: notice.content_en,
      },
    },
  };
}

export async function resumeFormSessionByIdAction(sessionId: string) {
  const supabase = await createServerClient();
  const { data, error } = await supabase
    .from("candidate_form_sessions")
    .select(
      "candidate_form_session_id, mode_code, target_submission_id, base_submission_version_no, presented_privacy_notice_version, status_code, expires_at",
    )
    .eq("candidate_form_session_id", sessionId)
    .eq("status_code", "OPEN")
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();

  if (error || !data) {
    return {
      success: false,
      error: error?.message || "No resumable form session",
    };
  }
  return { success: true, data };
}

export async function loadCandidateFormPrivacyNoticeAction(sessionId: string) {
  const supabase = await createServerClient();
  const { data: session, error: sessionError } = await supabase
    .from("candidate_form_sessions")
    .select("presented_privacy_notice_version")
    .eq("candidate_form_session_id", sessionId)
    .eq("status_code", "OPEN")
    .maybeSingle();
  if (sessionError || !session?.presented_privacy_notice_version) {
    return {
      success: false,
      error: sessionError?.message || "Form session not found",
    };
  }

  const { data: notice, error: noticeError } = await supabase
    .from("privacy_notice_versions")
    .select("notice_version, content_vi, content_en")
    .eq("notice_version", session.presented_privacy_notice_version)
    .maybeSingle();
  if (
    noticeError ||
    !notice?.notice_version ||
    typeof notice.content_vi !== "string"
  ) {
    return {
      success: false,
      error: noticeError?.message || "Pinned privacy notice is unavailable",
    };
  }
  return {
    success: true,
    data: {
      version: notice.notice_version,
      contentVi: notice.content_vi,
      contentEn: notice.content_en,
    },
  };
}
export async function startFormSessionAction(
  mode: "NEW_SUBMISSION" | "EDIT_SUBMISSION",
  targetSubmissionId?: string,
) {
  const supabase = await createServerClient();
  const result = await startCandidateFormSession(
    {
      mode,
      submissionId: targetSubmissionId,
    },
    { client: supabase },
  );

  if (!result.success) {
    return {
      success: false,
      error: result.error.message,
      code: result.error.code,
    };
  }

  return { success: true, data: result.data };
}

export async function cancelFormSessionAction(sessionId: string) {
  const supabase = await createServerClient();
  const result = await cancelCandidateFormSession(
    { sessionId },
    { client: supabase },
  );
  if (!result.success) {
    return { success: false, error: result.error.message };
  }
  return { success: true };
}
export async function cancelDocumentChangeAction(
  sessionId: string,
  changeId: string,
) {
  const supabase = await createServerClient();
  const result = await cancelCandidateDocumentChange(
    { candidateFormSessionId: sessionId, changeId },
    { client: supabase },
  );
  if (!result.success) {
    return {
      success: false,
      error: result.error.message,
      code: result.error.code,
    };
  }
  return { success: true };
}

export async function refreshCandidatePrivacyNoticeAction(sessionId: string) {
  const supabase = await createServerClient();
  const result = await refreshCandidateFormPrivacyNotice(
    { sessionId },
    { client: supabase },
  );
  if (!result.success) {
    return {
      success: false,
      error: result.error.message,
      code: result.error.code,
    };
  }
  return {
    success: true,
    data: {
      sessionId: result.data.candidate_form_session_id,
      mode: result.data.mode_code,
      targetSubmissionId: result.data.target_submission_id,
      baseSubmissionVersionNo: result.data.base_submission_version_no,
      pinnedPrivacyVersion: result.data.presented_privacy_notice_version,
      expiresAt: result.data.expires_at,
      privacyNotice: {
        version: result.data.privacy_notice.notice_version,
        contentVi: result.data.privacy_notice.content_vi,
        contentEn: result.data.privacy_notice.content_en,
      },
    },
  };
}
export async function stageCandidateDocumentDeleteAction(input: {
  sessionId: string;
  intendedDocumentTypeId: string;
  targetLogicalDocumentId: string;
}) {
  const supabase = await createServerClient();
  const result = await stageCandidateDocumentChange(
    {
      candidateFormSessionId: input.sessionId,
      actionCode: "DELETE",
      intendedDocumentTypeId: input.intendedDocumentTypeId,
      targetLogicalDocumentId: input.targetLogicalDocumentId,
    },
    { client: supabase },
  );
  if (!result.success) {
    return {
      success: false,
      error: result.error.message,
      code: result.error.code,
    };
  }
  return {
    success: true,
    data: { changeId: result.data.candidate_form_document_change_id },
  };
}

export async function reserveUploadAction(input: {
  sessionId: string;
  intendedDocumentTypeId: string;
  filename: string;
  declaredMimeType?: string;
  expectedMaxSize?: number;
}) {
  const supabase = await createServerClient();
  const reserveRes = await reserveCandidateFormUpload(
    {
      candidateFormSessionId: input.sessionId,
      intendedDocumentTypeId: input.intendedDocumentTypeId,
      originalFilename: input.filename,
      declaredMimeType: input.declaredMimeType,
      expectedMaxSize: input.expectedMaxSize,
    },
    { client: supabase },
  );

  if (!reserveRes.success) {
    return { success: false, error: reserveRes.error.message };
  }

  const reservation = reserveRes.data;

  if (driveServerConfig()) {
    const {
      data: { user },
      error,
    } = await supabase.auth.getUser();
    if (error || !user)
      return { success: false, error: "Authentication required" };
    const transport = await createDriveTransport({
      purpose: "upload",
      actor: user.id,
      reservationId: reservation.upload_reservation_id,
      sessionId: input.sessionId,
      bucket: reservation.temp_bucket,
      path: reservation.temp_path,
      filename: reservation.original_filename,
      // The gateway and the seal command both require the type implied by
      // the extension; browsers often declare none for Office files.
      mimeType: expectedMimeForFilename(reservation.original_filename) ?? "",
      maxBytes: reservation.expected_max_size_bytes,
    });
    return {
      success: true,
      data: {
        reservationId: reservation.upload_reservation_id,
        tempBucket: reservation.temp_bucket,
        tempPath: reservation.temp_path,
        signedUrl: "",
        token: "",
        transport,
      },
    };
  }

  // Create signed upload URL
  const signedRes = await createSignedUploadUrlForReservation(
    { uploadReservationId: reservation.upload_reservation_id },
    { client: supabase },
  );

  if (!signedRes.success) {
    return { success: false, error: signedRes.error.message };
  }

  return {
    success: true,
    data: {
      reservationId: reservation.upload_reservation_id,
      tempBucket: reservation.temp_bucket,
      tempPath: reservation.temp_path,
      signedUrl: signedRes.data.signedUrl,
      token: signedRes.data.token,
    },
  };
}

export async function completeAndStageUploadAction(input: {
  sessionId: string;
  reservationId: string;
  intendedDocumentTypeId: string;
  actualSize: number;
  actionCode?: "ADD" | "REPLACE";
  targetLogicalDocumentId?: string;
  checksumSha256?: string;
  mimeType?: string;
}) {
  const supabase = await createServerClient();
  const authorization = await authorizeCandidateUploadScan(
    {
      candidateFormSessionId: input.sessionId,
      uploadReservationId: input.reservationId,
    },
    { client: supabase },
  );
  if (!authorization.success) {
    return {
      success: false,
      error: authorization.error.message,
      code: authorization.error.code,
    };
  }

  // The business request inspects private Storage but never contacts a scanner
  // or supplies a verdict. Durable worker processing begins after commit.
  let driveSealed = false;
  if (driveServerConfig()) {
    const { data: reservation, error } = await supabase
      .from("upload_reservations")
      .select("temp_bucket,temp_path")
      .eq("upload_reservation_id", input.reservationId)
      .single();
    if (error || !reservation)
      return {
        success: false,
        error: "Upload reservation unavailable",
        code: "NOT_FOUND",
      };
    const location = await driveLocation(
      reservation.temp_bucket,
      reservation.temp_path,
    );
    if (location && location.state_code !== "SEALED")
      return {
        success: false,
        error: "Upload inspection incomplete",
        code: "UPLOAD_INSPECTION_REQUIRED",
      };
    driveSealed = location?.state_code === "SEALED";
  }
  if (!driveSealed) {
    const inspected = await inspectUploadReservation(input.reservationId);
    if (!inspected.success) {
      return { success: false, error: inspected.error, code: inspected.code };
    }
    const admin = createAdminClient();
    if (!admin) {
      return {
        success: false,
        error: "Trusted upload inspection is not configured",
        code: "UPLOAD_INSPECTION_REQUIRED",
      };
    }
    const recorded = await recordInspectedUploadReservation(
      {
        uploadReservationId: input.reservationId,
        actualSizeBytes: inspected.data.actualSizeBytes,
        detectedMimeType: inspected.data.detectedMimeType,
        checksumSha256: inspected.data.checksumSha256,
        magicBytesVerified: inspected.data.magicBytesVerified,
      },
      admin,
    );
    if (!recorded.success) {
      return {
        success: false,
        error: recorded.error.message,
        code: recorded.error.code,
      };
    }
  }
  const requested = await requestCandidateDocumentScan(
    {
      candidateFormSessionId: input.sessionId,
      uploadReservationId: input.reservationId,
      actionCode: input.actionCode ?? "ADD",
      targetLogicalDocumentId: input.targetLogicalDocumentId,
    },
    supabase,
  );
  if (!requested.success) {
    return {
      success: false,
      error: requested.error.message,
      code: requested.error.code,
    };
  }
  return {
    success: true as const,
    data: {
      kind: "PENDING_SCAN" as const,
      requestId: requested.data.document_scan_request_id,
      reservationId: input.reservationId,
    },
  };
}

export async function continueCleanDocumentScanAction(
  sessionId: string,
  reservationId: string,
) {
  const supabase = await createServerClient();
  const result = await continueCleanCandidateDocumentScan(
    sessionId,
    reservationId,
    supabase,
  );
  if (!result.success) {
    return {
      success: false as const,
      error: result.error.message,
      code: result.error.code,
    };
  }
  return {
    success: true as const,
    data: { kind: "STAGED" as const, changeId: result.data.change_id },
  };
}

function extractPrivacyNotice(
  details: unknown,
): CandidatePrivacyNotice | undefined {
  if (!details || typeof details !== "object") return undefined;
  const data = details as Record<string, unknown>;
  if (
    typeof data.privacy_notice_version !== "string" ||
    typeof data.content_vi !== "string"
  ) {
    return undefined;
  }
  return {
    version: data.privacy_notice_version,
    contentVi: data.content_vi,
    contentEn: typeof data.content_en === "string" ? data.content_en : null,
  };
}

export async function submitCandidateSubmissionAction(
  input: SubmitCandidateSubmissionInput,
) {
  const supabase = await createServerClient();
  const res = await submitCandidateSubmission(input, { supabase });
  if (!res.success) {
    return {
      success: false,
      error: res.error.message,
      code: res.error.code,
      privacyNotice: extractPrivacyNotice(res.error.details),
    };
  }
  return { success: true, data: res.data };
}

export async function updateCandidateSubmissionAction(
  input: UpdateCandidateSubmissionInput,
) {
  const supabase = await createServerClient();
  const res = await updateCandidateSubmission(input, { supabase });
  if (!res.success) {
    return {
      success: false,
      error: res.error.message,
      code: res.error.code,
      privacyNotice: extractPrivacyNotice(res.error.details),
    };
  }
  return { success: true, data: res.data };
}
