import type { SupabaseClient } from "@supabase/supabase-js";

export const CANDIDATE_QUARANTINE_BUCKET = "candidate-quarantine";
export const CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT = 5242880; // 5 MB

export const CANDIDATE_QUARANTINE_ALLOWED_MIME_TYPES = [
  "application/pdf",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "image/png",
  "image/jpeg",
] as const;

export const APPROVED_FILE_EXTENSIONS = [
  "pdf",
  "doc",
  "docx",
  "ppt",
  "pptx",
  "png",
  "jpg",
  "jpeg",
] as const;

export type ApprovedFileExtension = (typeof APPROVED_FILE_EXTENSIONS)[number];

const EXTENSION_MIME_MAP: Record<ApprovedFileExtension, readonly string[]> = {
  pdf: ["application/pdf"],
  doc: ["application/msword"],
  docx: [
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ],
  ppt: ["application/vnd.ms-powerpoint"],
  pptx: [
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ],
  png: ["image/png"],
  jpg: ["image/jpeg"],
  jpeg: ["image/jpeg"],
};

export function extractExtension(filename: string): string | null {
  if (!filename || typeof filename !== "string") {
    return null;
  }
  const parts = filename.trim().split(".");
  if (parts.length < 2) {
    return null;
  }
  const ext = parts.pop()?.toLowerCase() ?? null;
  return ext && ext.length > 0 ? ext : null;
}

export function isApprovedExtension(ext: string): ext is ApprovedFileExtension {
  return (APPROVED_FILE_EXTENSIONS as readonly string[]).includes(
    ext.toLowerCase(),
  );
}

export function isAllowedMimeForExtension(
  extension: string,
  mimeType: string,
): boolean {
  const normalizedExt = extension.toLowerCase();
  if (!isApprovedExtension(normalizedExt)) {
    return false;
  }
  const allowed = EXTENSION_MIME_MAP[normalizedExt];
  return allowed.includes(mimeType.toLowerCase());
}

/**
 * Ensures the candidate-quarantine bucket exists in private storage.
 * Per 49_TECHNICAL_REVIEW_VERCEL_SUPABASE.md:116, this uses the Storage API,
 * never SQL writes directly to storage.buckets.
 */
export async function ensureQuarantineBucketExists(
  supabaseAdmin: SupabaseClient,
): Promise<{ success: boolean; error?: string }> {
  try {
    const { data: bucket, error: getError } =
      await supabaseAdmin.storage.getBucket(CANDIDATE_QUARANTINE_BUCKET);

    if (bucket && !getError) {
      return { success: true };
    }

    const { error: createError } = await supabaseAdmin.storage.createBucket(
      CANDIDATE_QUARANTINE_BUCKET,
      {
        public: false,
        fileSizeLimit: CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT,
        allowedMimeTypes: [...CANDIDATE_QUARANTINE_ALLOWED_MIME_TYPES],
      },
    );

    if (createError && !createError.message.includes("already exists")) {
      return { success: false, error: createError.message };
    }

    return { success: true };
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
