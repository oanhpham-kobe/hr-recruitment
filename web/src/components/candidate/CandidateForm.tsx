"use client";

import { useEffect, useState } from "react";
import {
  DocumentUploader,
  type StagedDocumentItem,
} from "@/components/candidate/DocumentUploader";
import {
  EducationSection,
  type QualificationLevelOption,
} from "@/components/candidate/EducationSection";
import { useAutosave } from "@/hooks/useAutosave";
import type { EducationItem } from "@/lib/commands/candidate-submission";

type CandidatePrivacyNotice = {
  version: string;
  contentVi: string;
  contentEn: string | null;
};
export interface CandidateFormData {
  fullName: string;
  phone: string;
  dateOfBirth: string;
  gender: "MALE" | "FEMALE" | "";
  address: string;
  education: EducationItem[];
  attachedDocs: StagedDocumentItem[];
  privacyAcknowledged: boolean;
  acknowledgedPrivacyVersion: string | null;
}

interface CandidateFormProps {
  sessionId: string;
  mode: "NEW_SUBMISSION" | "EDIT_SUBMISSION";
  verifiedEmail: string;
  pinnedPrivacyVersion: string;
  expiresAt: string;
  privacyNotice: CandidatePrivacyNotice;
  privacyAlreadyAcknowledged?: boolean;
  initialData?: Partial<CandidateFormData>;
  documentTypes: Array<{ id: string; code: string; name: string }>;
  qualificationLevels?: QualificationLevelOption[];
  onSubmit: (data: CandidateFormData) => Promise<{
    success: boolean;
    error?: string;
    privacyNotice?: CandidatePrivacyNotice;
  }>;
  onCancel: () => Promise<void>;
}

export function CandidateForm({
  sessionId,
  mode,
  verifiedEmail,
  pinnedPrivacyVersion,
  expiresAt,
  privacyNotice,
  privacyAlreadyAcknowledged = false,
  initialData,
  documentTypes,
  qualificationLevels = [],
  onSubmit,
  onCancel,
}: CandidateFormProps) {
  const privacyNoticeVersion = privacyNotice.version || pinnedPrivacyVersion;
  const [formData, setFormData] = useState<CandidateFormData>({
    fullName: initialData?.fullName ?? "",
    phone: initialData?.phone ?? "",
    dateOfBirth: initialData?.dateOfBirth ?? "",
    gender: initialData?.gender ?? "MALE",
    address: initialData?.address ?? "",
    education: initialData?.education ?? [],
    attachedDocs: initialData?.attachedDocs ?? [],
    privacyAcknowledged: Boolean(privacyAlreadyAcknowledged),
    acknowledgedPrivacyVersion: privacyAlreadyAcknowledged
      ? privacyNoticeVersion
      : null,
  });

  useEffect(() => {
    setFormData((prev) =>
      prev.acknowledgedPrivacyVersion === privacyNoticeVersion
        ? prev
        : {
            ...prev,
            privacyAcknowledged: false,
            acknowledgedPrivacyVersion: null,
          },
    );
  }, [privacyNoticeVersion]);

  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState<boolean>(false);
  const [serverError, setServerError] = useState<string | null>(null);

  const { statusMessage, clearDraft } = useAutosave({
    sessionId,
    expiresAt,
    data: formData,
    onRestore: (restored) => {
      const acknowledgementMatchesNotice =
        restored.privacyAcknowledged &&
        restored.acknowledgedPrivacyVersion === privacyNoticeVersion;
      setFormData((prev) => ({
        ...prev,
        ...restored,
        privacyAcknowledged: acknowledgementMatchesNotice,
        acknowledgedPrivacyVersion: acknowledgementMatchesNotice
          ? privacyNoticeVersion
          : null,
      }));
    },
  });

  const handleFieldChange = (
    field: keyof CandidateFormData,
    value: unknown,
  ) => {
    setFormData((prev) => ({
      ...prev,
      [field]: value,
    }));
    if (errors[field]) {
      setErrors((prev) => {
        const next = { ...prev };
        delete next[field];
        return next;
      });
    }
  };

  const validateForm = (): boolean => {
    const errs: Record<string, string> = {};

    const name = formData.fullName?.trim();
    if (!name) {
      errs.fullName = "Họ và tên là bắt buộc / Full name is required";
    } else if (name.length > 200) {
      errs.fullName = "Họ và tên không được vượt quá 200 ký tự / Max 200 chars";
    }

    const phone = formData.phone?.trim();
    if (!phone) {
      errs.phone = "Số điện thoại là bắt buộc / Phone number is required";
    } else if (phone.length > 32) {
      errs.phone = "Số điện thoại không được vượt quá 32 ký tự / Max 32 chars";
    }

    const dob = formData.dateOfBirth?.trim();
    if (!dob) {
      errs.dateOfBirth = "Ngày sinh là bắt buộc / Date of birth is required";
    } else if (dob < "1900-01-01") {
      errs.dateOfBirth = "Ngày sinh phải từ 01/01/1900 / Min 1900-01-01";
    } else {
      const today = new Date().toISOString().split("T")[0];
      if (dob > today) {
        errs.dateOfBirth =
          "Ngày sinh không được ở tương lai / Cannot be future";
      }
    }

    if (!formData.gender || !["MALE", "FEMALE"].includes(formData.gender)) {
      errs.gender =
        "Giới tính phải là Nam hoặc Nữ / Gender must be MALE or FEMALE";
    }

    const address = formData.address?.trim();
    if (!address) {
      errs.address = "Địa chỉ là bắt buộc / Address is required";
    } else if (address.length > 500) {
      errs.address = "Địa chỉ không được vượt quá 500 ký tự / Max 500 chars";
    }

    const hasCv = formData.attachedDocs.some(
      (d) => d.isCv || d.documentTypeCode === "CV_RESUME",
    );
    if (!hasCv) {
      errs.attachedDocs = "Bắt buộc phải đính kèm tệp CV / CV is required";
    }

    if (
      !formData.privacyAcknowledged ||
      formData.acknowledgedPrivacyVersion !== privacyNoticeVersion
    ) {
      errs.privacyAcknowledged =
        "Bạn phải đồng ý với Thông báo quyền riêng tư / You must agree to the Privacy Notice";
    }

    setErrors(errs);
    return Object.keys(errs).length === 0;
  };

  const handlePrivacyAcknowledgementChange = (acknowledged: boolean) => {
    setFormData((prev) => ({
      ...prev,
      privacyAcknowledged: acknowledged,
      acknowledgedPrivacyVersion: acknowledged ? privacyNoticeVersion : null,
    }));
    if (errors.privacyAcknowledged) {
      setErrors((prev) => {
        const next = { ...prev };
        delete next.privacyAcknowledged;
        return next;
      });
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setServerError(null);

    if (!validateForm()) {
      return;
    }

    setSubmitting(true);
    try {
      const result = await onSubmit(formData);
      if (result.success) {
        clearDraft();
      } else {
        if (result.privacyNotice) {
          setFormData((prev) => ({
            ...prev,
            privacyAcknowledged: false,
            acknowledgedPrivacyVersion: null,
          }));
        }
        setServerError(
          result.error || "Gửi hồ sơ thất bại / Submission failed",
        );
      }
    } catch (err) {
      setServerError(
        err instanceof Error
          ? err.message
          : "Đã xảy ra lỗi / An error occurred",
      );
    } finally {
      setSubmitting(false);
    }
  };

  const handleCancelClick = async () => {
    clearDraft();
    await onCancel();
  };

  const today = new Date().toISOString().split("T")[0];

  return (
    <form className="candidate-form" onSubmit={handleSubmit} noValidate>
      {serverError && (
        <div role="alert" className="form-server-error">
          {serverError}
        </div>
      )}

      {/* Section A: Thông tin chung */}
      <fieldset className="form-fieldset">
        <legend className="form-legend">
          A. Thông tin chung / General Information
        </legend>

        <div className="form-grid">
          {/* Full Name */}
          <div className="form-group">
            <label className="form-label" htmlFor="fullName">
              Họ và tên / Full Name <span className="required-mark">*</span>
            </label>
            <input
              id="fullName"
              name="fullName"
              type="text"
              className="form-input"
              value={formData.fullName}
              onChange={(e) => handleFieldChange("fullName", e.target.value)}
              aria-required="true"
              aria-invalid={Boolean(errors.fullName)}
              aria-describedby={errors.fullName ? "fullName-error" : undefined}
              placeholder="Nguyễn Văn A"
              maxLength={200}
              disabled={submitting}
            />
            {errors.fullName && (
              <span id="fullName-error" className="field-error">
                {errors.fullName}
              </span>
            )}
          </div>

          {/* Phone */}
          <div className="form-group">
            <label className="form-label" htmlFor="phone">
              Số điện thoại / Phone <span className="required-mark">*</span>
            </label>
            <input
              id="phone"
              name="phone"
              type="tel"
              className="form-input"
              value={formData.phone}
              onChange={(e) => handleFieldChange("phone", e.target.value)}
              aria-required="true"
              aria-invalid={Boolean(errors.phone)}
              aria-describedby={errors.phone ? "phone-error" : undefined}
              placeholder="0901234567"
              maxLength={32}
              disabled={submitting}
            />
            {errors.phone && (
              <span id="phone-error" className="field-error">
                {errors.phone}
              </span>
            )}
          </div>

          {/* Date of Birth */}
          <div className="form-group">
            <label className="form-label" htmlFor="dateOfBirth">
              Ngày sinh / Date of Birth <span className="required-mark">*</span>
            </label>
            <input
              id="dateOfBirth"
              name="dateOfBirth"
              type="date"
              className="form-input"
              value={formData.dateOfBirth}
              onChange={(e) => handleFieldChange("dateOfBirth", e.target.value)}
              required
              min="1900-01-01"
              max={today}
              aria-invalid={Boolean(errors.dateOfBirth)}
              aria-describedby={
                errors.dateOfBirth ? "dateOfBirth-error" : undefined
              }
              disabled={submitting}
            />
            {errors.dateOfBirth && (
              <span id="dateOfBirth-error" className="field-error">
                {errors.dateOfBirth}
              </span>
            )}
          </div>

          {/* Gender */}
          <div className="form-group">
            <label className="form-label" htmlFor="gender">
              Giới tính / Gender <span className="required-mark">*</span>
            </label>
            <select
              id="gender"
              name="gender"
              className="form-select"
              value={formData.gender}
              onChange={(e) =>
                handleFieldChange("gender", e.target.value as "MALE" | "FEMALE")
              }
              aria-required="true"
              aria-invalid={Boolean(errors.gender)}
              aria-describedby={errors.gender ? "gender-error" : undefined}
              disabled={submitting}
            >
              <option value="MALE">Nam / Male</option>
              <option value="FEMALE">Nữ / Female</option>
            </select>
            {errors.gender && (
              <span id="gender-error" className="field-error">
                {errors.gender}
              </span>
            )}
          </div>

          {/* Email (Readonly) */}
          <div className="form-group">
            <label className="form-label" htmlFor="email">
              Email (Xác thực / Verified)
            </label>
            <input
              id="email"
              name="email"
              type="email"
              className="form-input"
              value={verifiedEmail}
              readOnly
            />
            <span className="file-spec">
              Email xác thực từ phiên đăng nhập, không thể thay đổi.
            </span>
          </div>

          {/* Address */}
          <div className="form-group">
            <label className="form-label" htmlFor="address">
              Địa chỉ hiện tại / Address{" "}
              <span className="required-mark">*</span>
            </label>
            <input
              id="address"
              name="address"
              type="text"
              className="form-input"
              value={formData.address}
              onChange={(e) => handleFieldChange("address", e.target.value)}
              aria-required="true"
              aria-invalid={Boolean(errors.address)}
              aria-describedby={errors.address ? "address-error" : undefined}
              placeholder="Thủ Dầu Một, Bình Dương"
              maxLength={500}
              disabled={submitting}
            />
            {errors.address && (
              <span id="address-error" className="field-error">
                {errors.address}
              </span>
            )}
          </div>
        </div>
      </fieldset>

      {/* Section B: Quá trình học tập */}
      <EducationSection
        items={formData.education}
        onChange={(education) => handleFieldChange("education", education)}
        qualificationLevels={qualificationLevels}
        disabled={submitting}
      />

      {/* Section C: Hồ sơ đính kèm */}
      <DocumentUploader
        sessionId={sessionId}
        attachedDocs={formData.attachedDocs}
        documentTypes={documentTypes}
        onDocsChange={(docs) => handleFieldChange("attachedDocs", docs)}
        disabled={submitting}
      />
      {errors.attachedDocs && (
        <span className="field-error field-error-spacing">
          {errors.attachedDocs}
        </span>
      )}

      {/* Section D: Xác nhận quyền riêng tư */}
      <fieldset className="form-fieldset">
        <legend className="form-legend">
          D. Xác nhận quyền riêng tư / Privacy Confirmation{" "}
          <span className="required-mark">*</span>
        </legend>

        <div className="privacy-box">
          <input
            id="privacyAcknowledged"
            type="checkbox"
            className="privacy-checkbox"
            checked={formData.privacyAcknowledged}
            onChange={(event) =>
              handlePrivacyAcknowledgementChange(event.target.checked)
            }
            aria-required="true"
            aria-invalid={Boolean(errors.privacyAcknowledged)}
            aria-describedby={
              errors.privacyAcknowledged ? "privacy-error" : undefined
            }
            disabled={submitting}
          />
          <label htmlFor="privacyAcknowledged" className="privacy-text">
            Tôi xác nhận đã đọc, hiểu rõ và đồng ý với{" "}
            <strong>
              Thông báo về quyền riêng tư của EIU (Phiên bản{" "}
              {privacyNoticeVersion})
            </strong>
            . Dữ liệu của tôi sẽ được lưu trữ và xử lý bảo mật phục vụ công tác
            tuyển dụng.
          </label>
          <details>
            <summary>Đọc toàn văn / Read the full Privacy Notice</summary>
            <div id="privacy-notice-content" className="privacy-notice-content">
              <p>{privacyNotice.contentVi}</p>
              {privacyNotice.contentEn && <p>{privacyNotice.contentEn}</p>}
            </div>
          </details>
        </div>
        {errors.privacyAcknowledged && (
          <span id="privacy-error" className="field-error field-error-block">
            {errors.privacyAcknowledged}
          </span>
        )}
      </fieldset>

      {/* Footer & Action Bar */}
      <div className="form-footer">
        <div className="autosave-status" role="status" aria-live="polite">
          {statusMessage}
        </div>

        <div className="action-buttons">
          <button
            type="button"
            className="btn btn-secondary"
            onClick={handleCancelClick}
            disabled={submitting}
          >
            Hủy / Cancel
          </button>

          <button
            type="submit"
            className="btn btn-primary"
            disabled={submitting}
          >
            {submitting
              ? "Đang gửi... / Submitting..."
              : mode === "EDIT_SUBMISSION"
                ? "Lưu thay đổi / Save Edit"
                : "Nộp hồ sơ / Submit Application"}
          </button>
        </div>
      </div>
    </form>
  );
}
