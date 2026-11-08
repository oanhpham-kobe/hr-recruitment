import "server-only";

import { createHash } from "node:crypto";
import {
  CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT,
  extractExtension,
  isAllowedMimeForExtension,
} from "@/lib/storage/buckets";
import { createAdminClient } from "@/lib/supabase/admin";

import { detectUploadMimeType } from "./content-signature";

export { detectUploadMimeType } from "./content-signature";
export type InspectedUpload = {
  actualSizeBytes: number;
  checksumSha256: string;
  detectedMimeType: string;
  magicBytesVerified: boolean;
};

type ScanFailure = {
  success: false;
  code:
    | "MALWARE_SCAN_REQUIRED"
    | "INVALID_CONTENT_SIGNATURE"
    | "UPLOAD_LIMIT_EXCEEDED"
    | "NOT_FOUND"
    | "INTERNAL_ERROR";
  error: string;
};
type ScanSuccess = { success: true; data: InspectedUpload };

export async function inspectUploadReservation(
  reservationId: string,
): Promise<ScanSuccess | ScanFailure> {
  const admin = createAdminClient();
  if (!admin) {
    return {
      success: false,
      code: "MALWARE_SCAN_REQUIRED",
      error: "Trusted upload scanner is not configured",
    };
  }

  const { data: reservation, error: reservationError } = await admin
    .from("upload_reservations")
    .select(
      "temp_bucket, temp_path, original_filename, declared_mime_type, expected_max_size_bytes, status_code",
    )
    .eq("upload_reservation_id", reservationId)
    .maybeSingle();

  if (reservationError || !reservation) {
    return {
      success: false,
      code: "NOT_FOUND" as ScanFailure["code"],
      error: reservationError?.message || "Upload reservation not found",
    };
  }

  if (!["RESERVED", "UPLOADED"].includes(String(reservation.status_code))) {
    return {
      success: false,
      code: "INTERNAL_ERROR",
      error: "Upload reservation is not available for scanning",
    };
  }

  const { data: object, error: downloadError } = await admin.storage
    .from(reservation.temp_bucket)
    .download(reservation.temp_path);
  if (downloadError || !object) {
    return {
      success: false,
      code: "INTERNAL_ERROR",
      error: downloadError?.message || "Uploaded object is not available",
    };
  }

  const bytes = new Uint8Array(await object.arrayBuffer());
  const actualSizeBytes = bytes.byteLength;
  if (
    actualSizeBytes <= 0 ||
    actualSizeBytes > CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT ||
    actualSizeBytes > Number(reservation.expected_max_size_bytes)
  ) {
    return {
      success: false,
      code: "UPLOAD_LIMIT_EXCEEDED",
      error: "Uploaded object exceeds the reserved size limit",
    };
  }

  const extension = extractExtension(reservation.original_filename);
  const detectedMimeType = detectUploadMimeType(bytes) ?? "";
  const magicBytesVerified = Boolean(
    extension &&
      detectedMimeType &&
      isAllowedMimeForExtension(extension, detectedMimeType),
  );
  const checksumSha256 = createHash("sha256").update(bytes).digest("hex");
  return {
    success: true,
    data: {
      actualSizeBytes,
      checksumSha256,
      detectedMimeType,
      magicBytesVerified,
    },
  };
}
