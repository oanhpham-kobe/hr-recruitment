"use client";
import { NavigationIcon } from "@/components/shell/NavigationIcon";
import { isPreviewableDocument } from "@/lib/application-inbox/submission-detail-model";
import { Button } from "./Button";

/** Callbacks are supplied only by an existing authorized document read surface. */
export function AttachmentActions({
  filename,
  mimeType,
  previewable,
  pending = false,
  disabled = false,
  locale = "vi",
  onPreview,
  onDownload,
}: {
  filename: string;
  mimeType: string;
  previewable?: boolean;
  pending?: boolean;
  disabled?: boolean;
  locale?: "vi" | "en";
  onPreview?: () => void;
  onDownload?: () => void;
}) {
  const previewLabel = `${locale === "en" ? "Preview" : "Xem trực tuyến"}: ${filename}`;
  const downloadLabel = `${locale === "en" ? "Download" : "Tải xuống"}: ${filename}`;
  return (
    <div className="attachment-actions">
      {onPreview &&
        previewable !== false &&
        isPreviewableDocument(mimeType) && (
          <Button
            type="button"
            variant="ghost"
            className="attachment-actions__button"
            aria-label={previewLabel}
            title={previewLabel}
            pending={pending}
            disabled={disabled}
            onClick={(event) => {
              event.stopPropagation();
              onPreview();
            }}
          >
            <NavigationIcon path="preview" />
          </Button>
        )}
      {onDownload && (
        <Button
          type="button"
          variant="ghost"
          className="attachment-actions__button"
          aria-label={downloadLabel}
          title={downloadLabel}
          pending={pending}
          disabled={disabled}
          onClick={(event) => {
            event.stopPropagation();
            onDownload();
          }}
        >
          <NavigationIcon path="download" />
        </Button>
      )}
    </div>
  );
}
