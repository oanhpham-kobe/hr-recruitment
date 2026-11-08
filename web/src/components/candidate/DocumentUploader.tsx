"use client";

import { useEffect, useState } from "react";
import {
  cancelDocumentChangeAction,
  completeAndStageUploadAction,
  continueCleanDocumentScanAction,
  reserveUploadAction,
  stageCandidateDocumentDeleteAction,
} from "@/app/candidate/candidate-actions";
import {
  APPROVED_FILE_EXTENSIONS,
  CANDIDATE_QUARANTINE_BUCKET,
  CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT,
  extractExtension,
  isApprovedExtension,
} from "@/lib/storage/buckets";
import { createBrowserClient } from "@/lib/supabase/client";
export type StagedDocumentItem = {
  changeId?: string;
  reservationId: string;
  documentTypeCode:
    | "CV_RESUME"
    | "DEGREE"
    | "TRANSCRIPT"
    | "CERTIFICATE"
    | "OTHER"
    | string;
  documentTypeName: string;
  filename: string;
  fileSizeBytes: number;
  logicalDocumentId?: string;
  documentTypeId?: string;
  persisted?: boolean;
  isCv: boolean;
};

type PendingDocumentItem = Omit<StagedDocumentItem, "changeId">;

function isTerminalScanError(code: string | undefined): boolean {
  return (
    code === "SCAN_REJECTED" ||
    code === "SCAN_FAILED" ||
    code === "SCAN_CANCELLED"
  );
}

interface DocumentUploaderProps {
  sessionId: string;
  attachedDocs: StagedDocumentItem[];
  documentTypes: Array<{ id: string; code: string; name: string }>;
  onDocsChange: (docs: StagedDocumentItem[]) => void;
  onUploadFile?: (
    file: File,
    docType: { id: string; code: string; name: string },
  ) => Promise<StagedDocumentItem>;
  disabled?: boolean;
}
export function DocumentUploader({
  sessionId,
  attachedDocs,
  documentTypes,
  onDocsChange,
  onUploadFile,
  disabled = false,
}: DocumentUploaderProps) {
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [uploading, setUploading] = useState<boolean>(false);
  const [pendingDocs, setPendingDocs] = useState<PendingDocumentItem[]>([]);
  const [selectedType, setSelectedType] = useState<string>(
    documentTypes.find((d) => d.code === "CV_RESUME")?.id ||
      documentTypes[0]?.id ||
      "",
  );

  const hasCv = attachedDocs.some(
    (d) => d.isCv || d.documentTypeCode === "CV_RESUME",
  );
  const isMaxReached = attachedDocs.length + pendingDocs.length >= 5;

  useEffect(() => {
    if (uploading || pendingDocs.length === 0) return;
    let cancelled = false;
    let checking = false;
    const continuePendingScans = async () => {
      if (checking) return;
      checking = true;
      try {
        const completed: StagedDocumentItem[] = [];
        const resolvedReservationIds = new Set<string>();
        for (const pending of pendingDocs) {
          const continuation = await continueCleanDocumentScanAction(
            sessionId,
            pending.reservationId,
          );
          if (continuation.success) {
            resolvedReservationIds.add(pending.reservationId);
            completed.push({
              ...pending,
              changeId: continuation.data.changeId,
            });
          } else if (isTerminalScanError(continuation.code)) {
            resolvedReservationIds.add(pending.reservationId);
            setUploadError(
              continuation.error || "Không thể hoàn tất kiểm tra bảo mật tệp",
            );
          } else if (continuation.code !== "SCAN_NOT_CLEAN") {
            setUploadError(
              continuation.error || "Không thể kiểm tra trạng thái quét tệp",
            );
          }
        }
        if (!cancelled && resolvedReservationIds.size > 0) {
          if (completed.length > 0) {
            onDocsChange([...attachedDocs, ...completed]);
          }
          setPendingDocs((current) =>
            current.filter(
              (pending) => !resolvedReservationIds.has(pending.reservationId),
            ),
          );
        }
      } finally {
        checking = false;
      }
    };
    void continuePendingScans();
    const timer = setInterval(() => void continuePendingScans(), 1000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [attachedDocs, onDocsChange, pendingDocs, sessionId, uploading]);

  const handleFileSelect = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    setUploadError(null);

    if (isMaxReached) {
      setUploadError(
        "Hồ sơ chỉ được phép đính kèm tối đa 5 tài liệu / Max 5 documents allowed",
      );
      e.target.value = "";
      return;
    }

    if (file.size > CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT) {
      setUploadError(
        "Dung lượng tệp vượt quá giới hạn 5 MB / File size exceeds 5 MB",
      );
      e.target.value = "";
      return;
    }

    const ext = extractExtension(file.name);
    if (!ext || !isApprovedExtension(ext)) {
      setUploadError(
        `Định dạng tệp không được hỗ trợ. Định dạng hợp lệ: ${APPROVED_FILE_EXTENSIONS.join(", ")}`,
      );
      e.target.value = "";
      return;
    }

    const docType = documentTypes.find((d) => d.id === selectedType);
    if (!docType) {
      setUploadError(
        "Vui lòng chọn loại tài liệu / Please select a document type",
      );
      e.target.value = "";
      return;
    }

    setUploading(true);

    try {
      if (onUploadFile) {
        const staged = await onUploadFile(file, docType);
        onDocsChange([...attachedDocs, staged]);
        e.target.value = "";
        return;
      }

      // Authoritative reservation flow:
      // 1. Reserve upload reservation on server
      const reserveRes = await reserveUploadAction({
        sessionId,
        intendedDocumentTypeId: docType.id,
        filename: file.name,
        declaredMimeType: file.type || undefined,
        expectedMaxSize: file.size,
      });

      if (!reserveRes.success || !reserveRes.data) {
        throw new Error(
          reserveRes.error || "Không thể tạo reservation tải tệp",
        );
      }

      const reservation = reserveRes.data;

      // 2. Upload the bytes through the one-use signed token. There is no
      // successful completion path when the browser upload is skipped.
      if (!reservation.tempPath || !reservation.token) {
        throw new Error("Signed upload token is unavailable");
      }
      const { error: storageError } = await createBrowserClient()
        .storage.from(reservation.tempBucket || CANDIDATE_QUARANTINE_BUCKET)
        .uploadToSignedUrl(reservation.tempPath, reservation.token, file, {
          contentType: file.type || undefined,
          upsert: false,
        });

      if (storageError) {
        throw new Error(`Upload failed: ${storageError.message}`);
      }

      // 3. The request path never scans or stages. PENDING_SCAN deliberately
      // has no changeId and must not enter the staged-document collection.
      const scanRequest = await completeAndStageUploadAction({
        sessionId,
        reservationId: reservation.reservationId,
        intendedDocumentTypeId: docType.id,
        actualSize: file.size,
        mimeType: file.type || "application/pdf",
      });

      if (!scanRequest.success || !scanRequest.data) {
        throw new Error(
          scanRequest.error || "Không thể tạo yêu cầu quét bảo mật tệp",
        );
      }
      if (scanRequest.data.kind !== "PENDING_SCAN") {
        throw new Error("Unexpected scan request state");
      }

      // Keep pending work outside the staged-document collection. The effect
      // retries the server-owned continuation until a trusted CLEAN result
      // creates the single staged change.
      setPendingDocs((current) =>
        current.some(
          (pending) => pending.reservationId === reservation.reservationId,
        )
          ? current
          : [
              ...current,
              {
                reservationId: reservation.reservationId,
                documentTypeCode: docType.code,
                documentTypeName: docType.name,
                filename: file.name,
                fileSizeBytes: file.size,
                documentTypeId: docType.id,
                isCv: docType.code === "CV_RESUME",
              },
            ],
      );
      e.target.value = "";
    } catch (err) {
      setUploadError(
        err instanceof Error ? err.message : "Tải tệp thất bại / Upload failed",
      );
    } finally {
      setUploading(false);
    }
  };

  const handleRemove = async (index: number) => {
    const doc = attachedDocs[index];
    if (!doc) return;

    setUploadError(null);
    setUploading(true);
    try {
      if (doc.changeId && !doc.persisted) {
        const result = await cancelDocumentChangeAction(
          sessionId,
          doc.changeId,
        );
        if (!result.success) {
          throw new Error(result.error || "Could not cancel staged document");
        }
      } else if (doc.persisted) {
        if (!doc.logicalDocumentId || !doc.documentTypeId) {
          throw new Error("Persisted document identity is unavailable");
        }
        const result = await stageCandidateDocumentDeleteAction({
          sessionId,
          intendedDocumentTypeId: doc.documentTypeId,
          targetLogicalDocumentId: doc.logicalDocumentId,
        });
        if (!result.success) {
          throw new Error(result.error || "Could not stage document removal");
        }
      }

      onDocsChange(attachedDocs.filter((_, idx) => idx !== index));
    } catch (err) {
      setUploadError(
        err instanceof Error
          ? err.message
          : "Could not remove document / Không thể gỡ tài liệu",
      );
    } finally {
      setUploading(false);
    }
  };

  const formatSize = (bytes: number): string => {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  };

  return (
    <fieldset className="form-fieldset">
      <legend className="form-legend">
        Hồ sơ đính kèm / Document Attachments{" "}
        <span className="required-mark">*</span>
      </legend>

      <p className="file-spec" style={{ marginBottom: "16px" }}>
        Định dạng hỗ trợ: PDF, DOC, DOCX, PPT, PPTX, PNG, JPG. Tối đa 5 MB/tệp.
        Tối đa 5 tài liệu. Bắt buộc phải có <strong>CV / Sơ yếu lý lịch</strong>
        .
      </p>

      {/* CV Requirement Warning if missing */}
      {!hasCv && (
        <div
          role="alert"
          style={{
            backgroundColor: "var(--status-warning-bg)",
            color: "var(--status-warning-text)",
            padding: "10px 14px",
            borderRadius: "6px",
            marginBottom: "16px",
            fontSize: "16px",
            fontWeight: 600,
          }}
        >
          ⚠️ Bắt buộc đính kèm ít nhất 1 tệp CV / Resume trước khi nộp hồ sơ.
        </div>
      )}

      {/* Error Message */}
      {uploadError && (
        <div
          role="alert"
          style={{
            backgroundColor: "var(--status-danger-bg)",
            color: "var(--status-danger-text)",
            padding: "10px 14px",
            borderRadius: "6px",
            marginBottom: "16px",
            fontSize: "16px",
          }}
        >
          {uploadError}
        </div>
      )}

      {/* Upload Controls */}
      <div className="form-grid" style={{ marginBottom: "20px" }}>
        <div className="form-group">
          <label className="form-label" htmlFor="doc-type-select">
            Loại tài liệu / Document Type
          </label>
          <select
            id="doc-type-select"
            className="form-select"
            value={selectedType}
            onChange={(e) => setSelectedType(e.target.value)}
            disabled={disabled || isMaxReached || uploading}
          >
            {documentTypes.map((dt) => (
              <option key={dt.id} value={dt.id}>
                {dt.name}{" "}
                {dt.code === "CV_RESUME" ? "(Bắt buộc)" : "(Tùy chọn)"}
              </option>
            ))}
          </select>
        </div>

        <div className="form-group">
          <label className="form-label" htmlFor="file-input">
            Chọn tệp tải lên / Select File
          </label>
          <input
            id="file-input"
            type="file"
            className="form-input"
            accept=".pdf,.doc,.docx,.ppt,.pptx,.png,.jpg,.jpeg"
            onChange={handleFileSelect}
            disabled={disabled || isMaxReached || uploading}
            style={{ paddingTop: "6px" }}
          />
        </div>
      </div>

      {uploading && (
        <p className="file-spec">Đang xử lý tải lên... / Uploading...</p>
      )}

      {/* Attached Files List */}
      <div className="uploader-box">
        {pendingDocs.map((doc) => (
          <div
            key={doc.reservationId}
            className="upload-card"
            role="status"
            aria-live="polite"
          >
            <div className="upload-meta">
              <div>
                <strong>{doc.documentTypeName}</strong>: {doc.filename} (
                {formatSize(doc.fileSizeBytes)})
                <span style={{ marginLeft: "8px" }}>
                  Đang kiểm tra bảo mật / Security scan pending
                </span>
              </div>
            </div>
          </div>
        ))}
        {attachedDocs.map((doc, idx) => (
          <div
            key={
              doc.logicalDocumentId ||
              doc.changeId ||
              doc.reservationId ||
              `${doc.filename}-${idx}`
            }
            className="upload-card attached"
          >
            <div className="upload-meta">
              <div>
                <strong>{doc.documentTypeName}</strong>: {doc.filename} (
                {formatSize(doc.fileSizeBytes)})
                {doc.isCv && (
                  <span
                    style={{
                      marginLeft: "8px",
                      fontSize: "14px",
                      backgroundColor: "var(--status-info-bg)",
                      color: "var(--eiu-blue)",
                      padding: "2px 6px",
                      borderRadius: "4px",
                    }}
                  >
                    CV Bắt buộc
                  </span>
                )}
              </div>
              <button
                type="button"
                className="btn candidate-btn-danger"
                style={{ minHeight: "44px", padding: "8px 12px" }}
                onClick={() => void handleRemove(idx)}
                disabled={disabled || uploading}
                aria-label={`Xóa tệp ${doc.filename}`}
              >
                Gỡ bỏ / Remove
              </button>
            </div>
          </div>
        ))}
      </div>
    </fieldset>
  );
}
