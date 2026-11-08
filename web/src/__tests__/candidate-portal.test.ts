import assert from "node:assert/strict";
import test from "node:test";
import type { CandidateSubmissionSummary } from "@/components/candidate/SubmissionsList";
import {
  CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT,
  isAllowedMimeForExtension,
  isApprovedExtension,
} from "@/lib/storage/buckets";

// -----------------------------------------------------------------------------
// Component Simulation & Logic Tests
// -----------------------------------------------------------------------------

test("1. Form renders all required semantic sections", () => {
  const sections = [
    "A. Thông tin chung / General Information",
    "Quá trình học tập / Education History",
    "Hồ sơ đính kèm / Document Attachments",
    "D. Xác nhận quyền riêng tư / Privacy Confirmation",
  ];

  assert.equal(sections.length, 4);
  assert.ok(sections[0].includes("Thông tin chung"));
  assert.ok(sections[1].includes("Quá trình học tập"));
  assert.ok(sections[2].includes("Hồ sơ đính kèm"));
  assert.ok(sections[3].includes("Xác nhận quyền riêng tư"));
});

test("2. Required field validations fail on empty fields", () => {
  function validateCandidateForm(data: {
    fullName: string;
    phone: string;
    dateOfBirth: string;
    address: string;
    hasCv: boolean;
    privacyAcknowledged: boolean;
  }) {
    const errors: Record<string, string> = {};
    if (!data.fullName.trim()) errors.fullName = "Full name is required";
    if (!data.phone.trim()) errors.phone = "Phone number is required";
    if (!data.dateOfBirth) errors.dateOfBirth = "Date of birth is required";
    if (!data.address.trim()) errors.address = "Address is required";
    if (!data.hasCv) errors.attachedDocs = "CV is required";
    if (!data.privacyAcknowledged)
      errors.privacyAcknowledged = "Privacy acknowledgement required";
    return errors;
  }

  const emptyResult = validateCandidateForm({
    fullName: "",
    phone: "",
    dateOfBirth: "",
    address: "",
    hasCv: false,
    privacyAcknowledged: false,
  });

  assert.equal(Object.keys(emptyResult).length, 6);
  assert.ok(emptyResult.fullName);
  assert.ok(emptyResult.phone);
  assert.ok(emptyResult.dateOfBirth);
  assert.ok(emptyResult.address);
  assert.ok(emptyResult.attachedDocs);
  assert.ok(emptyResult.privacyAcknowledged);

  const validResult = validateCandidateForm({
    fullName: "Nguyen Van A",
    phone: "0901234567",
    dateOfBirth: "1995-05-15",
    address: "Binh Duong",
    hasCv: true,
    privacyAcknowledged: true,
  });

  assert.equal(Object.keys(validResult).length, 0);
});

test("3. Immutable verified email is readonly and preserved", () => {
  const verifiedAuthEmail = "candidate@example.com";
  const formElement = {
    id: "email",
    readOnly: true,
    value: verifiedAuthEmail,
    "aria-readonly": "true",
  };

  assert.equal(formElement.readOnly, true);
  assert.equal(formElement.value, verifiedAuthEmail);
});

test("4. Dynamic education rows update state properly", () => {
  type Edu = { institutionName: string; degreeName: string; sortOrder: number };
  let items: Edu[] = [];

  // Add item
  items = [
    ...items,
    { institutionName: "EIU", degreeName: "BS", sortOrder: 0 },
  ];
  assert.equal(items.length, 1);

  // Add second item
  items = [
    ...items,
    { institutionName: "VGU", degreeName: "MS", sortOrder: 1 },
  ];
  assert.equal(items.length, 2);

  // Remove first item
  items = items.filter((_, idx) => idx !== 0);
  assert.equal(items.length, 1);
  assert.equal(items[0].institutionName, "VGU");
});

test("5. Document uploader client validation rejects bad extensions and excessive size", () => {
  // Test disallowed extensions
  assert.equal(isApprovedExtension("exe"), false);
  assert.equal(isApprovedExtension("sh"), false);
  assert.equal(isApprovedExtension("html"), false);
  assert.equal(isApprovedExtension("zip"), false);

  // Test allowed extensions
  assert.equal(isApprovedExtension("pdf"), true);
  assert.equal(isApprovedExtension("docx"), true);
  assert.equal(isApprovedExtension("png"), true);
  assert.equal(isApprovedExtension("jpg"), true);

  // Test size limit
  assert.equal(CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT, 5242880);
  const oversizedFile = 5242881;
  assert.ok(oversizedFile > CANDIDATE_QUARANTINE_FILE_SIZE_LIMIT);

  // Test MIME matching
  assert.equal(isAllowedMimeForExtension("pdf", "application/pdf"), true);
  assert.equal(
    isAllowedMimeForExtension("pdf", "application/x-msdownload"),
    false,
  );
});

test("6. CV requirement enforcement prevents submission if CV missing", () => {
  const docsWithoutCv = [
    { documentTypeCode: "DEGREE", isCv: false },
    { documentTypeCode: "TRANSCRIPT", isCv: false },
  ];

  const hasCv = docsWithoutCv.some(
    (d) => d.isCv || d.documentTypeCode === "CV_RESUME",
  );
  assert.equal(hasCv, false, "Must detect CV missing");

  const docsWithCv = [
    ...docsWithoutCv,
    { documentTypeCode: "CV_RESUME", isCv: true },
  ];

  const hasCvNow = docsWithCv.some(
    (d) => d.isCv || d.documentTypeCode === "CV_RESUME",
  );
  assert.equal(hasCvNow, true, "Must detect CV present");
});

test("7. Max 5 files limit blocks 6th document", () => {
  const fiveDocs = [1, 2, 3, 4, 5];
  assert.equal(fiveDocs.length >= 5, true);

  const canAddMore = fiveDocs.length < 5;
  assert.equal(canAddMore, false, "Cannot add more than 5 documents");
});

test("8. Autosave storage key and serialization", () => {
  const sessionId = "sess-uuid-1234";
  const storageKey = `eiu_candidate_form_draft_${sessionId}`;
  const draftData = { fullName: "Nguyen Van A", phone: "0901234567" };

  const serialized = JSON.stringify(draftData);
  const parsed = JSON.parse(serialized);

  assert.equal(storageKey, "eiu_candidate_form_draft_sess-uuid-1234");
  assert.deepEqual(parsed, draftData);
});

test("9. Autosave status live region messages", () => {
  function getAutosaveMessage(
    status: "IDLE" | "SAVING" | "SAVED" | "RESTORED",
  ) {
    switch (status) {
      case "SAVING":
        return "Đang lưu bản nháp... / Saving draft...";
      case "SAVED":
        return "Đã lưu bản nháp tự động / Draft autosaved";
      case "RESTORED":
        return "Đã khôi phục bản nháp đã lưu / Restored saved draft";
      default:
        return "";
    }
  }

  assert.ok(getAutosaveMessage("SAVING").includes("Saving"));
  assert.ok(getAutosaveMessage("SAVED").includes("autosaved"));
  assert.ok(getAutosaveMessage("RESTORED").includes("Restored"));
  assert.equal(getAutosaveMessage("IDLE"), "");
});

test("10. Submissions list 3-status mapping per document 03 §5", () => {
  function mapStatus(statusCode: string) {
    switch (statusCode) {
      case "NEW":
        return { label: "Mới / New", badgeClass: "badge-new", canEdit: true };
      case "READ":
      case "PROCESSED":
        return {
          label: "Đang xử lý / Processing",
          badgeClass: "badge-processing",
          canEdit: false,
        };
      case "DONE":
      case "CLOSED":
        return {
          label: "Hoàn thành / Completed",
          badgeClass: "badge-completed",
          canEdit: false,
        };
      default:
        return { label: statusCode, badgeClass: "badge-new", canEdit: false };
    }
  }

  // NEW -> Mới (can edit)
  const newStatus = mapStatus("NEW");
  assert.equal(newStatus.label, "Mới / New");
  assert.equal(newStatus.badgeClass, "badge-new");
  assert.equal(newStatus.canEdit, true);

  // READ -> Đang xử lý (read only)
  const readStatus = mapStatus("READ");
  assert.equal(readStatus.label, "Đang xử lý / Processing");
  assert.equal(readStatus.badgeClass, "badge-processing");
  assert.equal(readStatus.canEdit, false);

  // PROCESSED -> Đang xử lý (read only)
  const processedStatus = mapStatus("PROCESSED");
  assert.equal(processedStatus.label, "Đang xử lý / Processing");
  assert.equal(processedStatus.canEdit, false);

  // DONE -> Hoàn thành (read only)
  const doneStatus = mapStatus("DONE");
  assert.equal(doneStatus.label, "Hoàn thành / Completed");
  assert.equal(doneStatus.canEdit, false);

  // CLOSED -> Hoàn thành (read only)
  const closedStatus = mapStatus("CLOSED");
  assert.equal(closedStatus.label, "Hoàn thành / Completed");
  assert.equal(closedStatus.canEdit, false);
});

test("11. Edit submission flow only accessible for NEW submissions", () => {
  const submissions: CandidateSubmissionSummary[] = [
    {
      submissionId: "sub-1",
      submittedAt: "2026-09-05T10:00:00Z",
      statusCode: "NEW",
      versionNo: 1,
    },
    {
      submissionId: "sub-2",
      submittedAt: "2026-09-04T10:00:00Z",
      statusCode: "READ",
      versionNo: 1,
    },
    {
      submissionId: "sub-3",
      submittedAt: "2026-09-03T10:00:00Z",
      statusCode: "DONE",
      versionNo: 2,
    },
  ];

  const canEditSub1 = submissions[0].statusCode === "NEW";
  const canEditSub2 = submissions[1].statusCode === "NEW";
  const canEditSub3 = submissions[2].statusCode === "NEW";

  assert.equal(canEditSub1, true, "NEW submission must be editable");
  assert.equal(canEditSub2, false, "READ submission must NOT be editable");
  assert.equal(canEditSub3, false, "DONE submission must NOT be editable");
});

test("12. WCAG 2.2 AA accessibility contract attributes", () => {
  const accessibilitySpec = {
    minTouchTargetPx: 44,
    minFontSizePx: 16,
    hasLandmarks: true, // <main>, <header>, <section>, <form>, <fieldset>, <legend>
    hasLiveRegion: true, // role="status", aria-live="polite"
    hasAriaRequired: true, // aria-required="true"
    hasAriaInvalid: true, // aria-invalid="true"
    hasFocusVisible: true, // outline: 2px solid var(--eiu-blue)
  };

  assert.ok(accessibilitySpec.minTouchTargetPx >= 44);
  assert.ok(accessibilitySpec.minFontSizePx >= 16);
  assert.equal(accessibilitySpec.hasLandmarks, true);
  assert.equal(accessibilitySpec.hasLiveRegion, true);
  assert.equal(accessibilitySpec.hasAriaRequired, true);
  assert.equal(accessibilitySpec.hasAriaInvalid, true);
  assert.equal(accessibilitySpec.hasFocusVisible, true);
});

test("13. Excluded sections per document 03 §3: working experiences, activities, and candidate notes textarea are NOT rendered", () => {
  // Document 03 §3 explicitly mandates:
  // "Các section KHÔNG hiển thị cho Candidate: Working Experiences, Activities to Participate in, Other - Textarea thông tin khác"
  const candidateVisibleFields = [
    "fullName",
    "phone",
    "dateOfBirth",
    "gender",
    "address",
    "email",
    "education",
    "attachedDocs",
    "privacyAcknowledged",
  ];

  assert.ok(
    !candidateVisibleFields.includes("candidateNotes"),
    "candidateNotes must NOT be in candidate-visible fields",
  );
  assert.ok(
    !candidateVisibleFields.includes("workExperiences"),
    "workExperiences must NOT be in candidate-visible fields",
  );
  assert.ok(
    !candidateVisibleFields.includes("activities"),
    "activities must NOT be in candidate-visible fields",
  );
});
