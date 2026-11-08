import { mutate, ok } from "./store";
export async function reserveUploadAction(input: { filename: string }) {
  const reservationId = crypto.randomUUID();
  mutate("Tệp mẫu: lưu metadata, không quét / Metadata only", (s) => {
    s.uploadNames[reservationId] = input.filename;
  });
  return ok({
    reservationId,
    tempPath: reservationId,
    tempBucket: "synthetic-only",
    token: "synthetic-not-a-credential",
  });
}
export function createBrowserClient() {
  return {
    storage: {
      from: () => ({
        uploadToSignedUrl: async () => ({
          data: { path: "synthetic-only" },
          error: null,
        }),
      }),
    },
  };
}
export async function completeAndStageUploadAction() {
  return ok({ kind: "PENDING_SCAN" });
}
export async function continueCleanDocumentScanAction() {
  return ok({ changeId: crypto.randomUUID() });
}
export async function stageCandidateDocumentDeleteAction() {
  return ok({ changeId: crypto.randomUUID() });
}
export async function cancelDocumentChangeAction() {
  return ok({});
}
