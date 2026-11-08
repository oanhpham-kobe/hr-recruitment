"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useTransition,
} from "react";
import {
  createApplicationAction,
  getAssignmentOptionsAction,
  getDocumentSignedUrlAction,
  getQualificationLevelsAction,
  getRecruitmentSourcesAction,
  getSubmissionDetailAction,
  openSubmissionAction,
  updateSubmissionAggregateAction,
  type updateSubmissionHrNoteAction,
} from "@/app/application-inbox-actions";
import { AttachmentActions } from "@/components/ui/AttachmentActions";
import type { SubmissionStatus } from "@/lib/application-inbox/model";
import type {
  AssignmentOptions,
  SubmissionDetail,
  SubmissionDocumentItem,
} from "@/lib/application-inbox/submission-detail-model";

const useIsomorphicLayoutEffect =
  typeof window !== "undefined" ? useLayoutEffect : useEffect;

export interface SubmissionDetailDrawerProps {
  submissionId: string;
  isOpen: boolean;
  onClose: () => void;
  isExplicitOpen?: boolean;
  onSubmissionUpdated?: (detail: {
    submissionId: string;
    hrNote: string | null;
    versionNo: number;
    status?: SubmissionStatus;
    hasApplication: boolean;
    hasActiveApplication?: boolean;
  }) => void;
  actions?: {
    openSubmission?: typeof openSubmissionAction;
    getSubmissionDetail?: typeof getSubmissionDetailAction;
    updateSubmissionHrNote?: typeof updateSubmissionHrNoteAction;
    updateSubmissionAggregate?: typeof updateSubmissionAggregateAction;
    getRecruitmentSources?: typeof getRecruitmentSourcesAction;
    getQualificationLevels?: typeof getQualificationLevelsAction;
    getDocumentSignedUrl?: typeof getDocumentSignedUrlAction;
    getAssignmentOptions?: typeof getAssignmentOptionsAction;
    createApplication?: typeof createApplicationAction;
  };
}

export function computeAssignmentContextKey(params: {
  submissionId: string;
  unitId: string;
  departmentTeamId?: string | null;
  positionId: string;
  hrOwnerId: string;
}): string {
  return [
    params.submissionId,
    params.unitId,
    params.departmentTeamId ?? "",
    params.positionId,
    params.hrOwnerId,
  ].join("::");
}

function formatDate(value: string | null): string {
  if (!value) return "—";
  const [year, month, day] = value.split("-");
  return year && month && day ? `${day}/${month}/${year}` : value;
}

function formatDateTime(value: string | null): string {
  if (!value) return "—";
  try {
    const date = new Date(value);
    return new Intl.DateTimeFormat("vi-VN", {
      dateStyle: "short",
      timeStyle: "short",
      timeZone: "Asia/Ho_Chi_Minh",
    }).format(date);
  } catch {
    return value;
  }
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function SubmissionDetailDrawer({
  submissionId,
  isOpen,
  onClose,
  isExplicitOpen = true,
  onSubmissionUpdated,
  actions,
}: SubmissionDetailDrawerProps) {
  const [detail, setDetail] = useState<SubmissionDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // Edit Mode state
  const [isEditMode, setIsEditMode] = useState(false);
  const [editedFullName, setEditedFullName] = useState("");
  const [editedPhone, setEditedPhone] = useState("");
  const [editedDateOfBirth, setEditedDateOfBirth] = useState("");
  const [editedGender, setEditedGender] = useState("MALE");
  const [editedAddress, setEditedAddress] = useState("");
  const [editedSourceId, setEditedSourceId] = useState("");
  const [editedHrNote, setEditedHrNote] = useState("");
  const [editedEducation, setEditedEducation] = useState<
    Array<{
      education_id?: string;
      period_text: string;
      institution: string;
      major: string;
      qualification_id: string;
      qualification_name?: string;
    }>
  >([]);
  const [recruitmentSources, setRecruitmentSources] = useState<
    Array<{ recruitment_source_id: string; code: string; name_vi: string }>
  >([]);
  const [qualificationLevels, setQualificationLevels] = useState<
    Array<{ qualification_id: string; code: string; name_vi: string }>
  >([]);
  const [isSavingNote, startSaveNoteTransition] = useTransition();
  const [saveError, setSaveError] = useState<string | null>(null);
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false);
  const [discardAction, setDiscardAction] = useState<
    "exit_edit" | "close_drawer"
  >("close_drawer");
  // Document preview state
  const [previewDoc, setPreviewDoc] = useState<{
    previewUrl: string;
    filename: string;
    mimeType: string;
  } | null>(null);
  const [docActionPending, startDocActionTransition] = useTransition();
  const [docError, setDocError] = useState<string | null>(null);

  // Application creation state
  const [assignmentOptions, setAssignmentOptions] =
    useState<AssignmentOptions | null>(null);
  const [showAssignForm, setShowAssignForm] = useState(false);
  const [optionsLoadError, setOptionsLoadError] = useState<string | null>(null);
  const [isLoadingOptions, setIsLoadingOptions] = useState(false);
  const [selectedUnitId, setSelectedUnitId] = useState("");
  const [selectedTeamId, setSelectedTeamId] = useState("");
  const [selectedPositionId, setSelectedPositionId] = useState("");
  const [selectedHrOwnerId, setSelectedHrOwnerId] = useState("");
  const [assignError, setAssignError] = useState<string | null>(null);
  const [isAssigning, startAssignTransition] = useTransition();
  const [activeDuplicateWarning, setActiveDuplicateWarning] = useState<{
    message: string;
    contextKey: string;
  } | null>(null);
  const [assignIdempotencyKey, setAssignIdempotencyKey] = useState<string>(() =>
    crypto.randomUUID(),
  );

  // Accessibility & Focus refs
  const drawerRef = useRef<HTMLDivElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const editButtonRef = useRef<HTMLButtonElement>(null);
  const hrNoteTextareaRef = useRef<HTMLTextAreaElement>(null);
  const triggerElementRef = useRef<HTMLElement | null>(null);
  const discardDialogRef = useRef<HTMLDivElement>(null);
  const fullNameInputRef = useRef<HTMLInputElement>(null);
  const cancelDiscardBtnRef = useRef<HTMLButtonElement>(null);
  const previewModalRef = useRef<HTMLDivElement>(null);
  const previewCloseBtnRef = useRef<HTMLButtonElement>(null);
  const previewTriggerRef = useRef<HTMLElement | null>(null);
  const focusTargetRef = useRef<
    "editButton" | "hrNoteTextarea" | "fullNameInput" | null
  >(null);
  const prevIsOpenRef = useRef(false);

  // Initial focus enters drawer when opened (post-commit)
  useIsomorphicLayoutEffect(() => {
    if (isOpen && !prevIsOpenRef.current) {
      triggerElementRef.current = document.activeElement as HTMLElement | null;
      if (closeButtonRef.current) {
        closeButtonRef.current.focus();
      } else if (drawerRef.current) {
        drawerRef.current.focus();
      }
    }
    prevIsOpenRef.current = isOpen;
  }, [isOpen]);

  // React post-commit focus transition mechanism (no setTimeout)
  useIsomorphicLayoutEffect(() => {
    if (focusTargetRef.current === "fullNameInput") {
      focusTargetRef.current = null;
      fullNameInputRef.current?.focus();
    } else if (focusTargetRef.current === "hrNoteTextarea") {
      focusTargetRef.current = null;
      hrNoteTextareaRef.current?.focus();
    } else if (focusTargetRef.current === "editButton") {
      focusTargetRef.current = null;
      editButtonRef.current?.focus();
    }
  });

  // Load detail on open
  useEffect(() => {
    if (!isOpen || !submissionId) return;

    let active = true;
    setLoading(true);
    setErrorMessage(null);
    setIsEditMode(false);
    setShowDiscardConfirm(false);
    setSaveError(null);
    setDocError(null);
    setAssignError(null);
    setOptionsLoadError(null);
    setIsLoadingOptions(false);
    setAssignmentOptions(null);
    setShowAssignForm(false);
    setActiveDuplicateWarning(null);

    const openAction = actions?.openSubmission ?? openSubmissionAction;
    const fetchDetail =
      actions?.getSubmissionDetail ?? getSubmissionDetailAction;

    async function load() {
      try {
        if (isExplicitOpen && openAction) {
          try {
            await openAction(submissionId);
          } catch (openErr) {
            console.warn(
              "[SubmissionDetailDrawer] openSubmission warning:",
              openErr,
            );
          }
        }
        if (!active) return;
        const res = await fetchDetail(submissionId);
        if (!active) return;
        if (res.success) {
          setDetail(res.data);
          setEditedHrNote(res.data.hr_note ?? "");
          onSubmissionUpdated?.({
            submissionId: res.data.submission_id,
            hrNote: res.data.hr_note ?? null,
            versionNo: res.data.version_no,
            status: res.data.status_code,
            hasApplication: res.data.applications.length > 0,
            hasActiveApplication: res.data.applications.some(
              (app) => app.is_active,
            ),
          });
        } else {
          setErrorMessage(res.error);
        }
      } catch (err: unknown) {
        if (!active) return;
        setErrorMessage(
          err instanceof Error
            ? err.message
            : "Lỗi không xác định khi tải chi tiết.",
        );
      } finally {
        if (active) setLoading(false);
      }
    }

    load();

    return () => {
      active = false;
    };
  }, [
    isOpen,
    submissionId,
    isExplicitOpen,
    actions?.openSubmission,
    actions?.getSubmissionDetail,
    onSubmissionUpdated,
  ]);

  const isDirty = useMemo(() => {
    if (!isEditMode || !detail) return false;
    if (editedFullName !== detail.full_name) return true;
    if ((detail.phone ?? "") !== editedPhone) return true;
    if ((detail.date_of_birth ?? "") !== editedDateOfBirth) return true;
    if ((detail.gender_code ?? "MALE") !== editedGender) return true;
    if ((detail.current_address ?? "") !== editedAddress) return true;
    if ((detail.recruitment_source_id ?? "") !== editedSourceId) return true;
    if ((detail.hr_note ?? "") !== editedHrNote) return true;
    if (editedEducation.length !== detail.education.length) return true;
    for (let i = 0; i < editedEducation.length; i++) {
      const a = editedEducation[i];
      const b = detail.education[i];
      if (
        (a.period_text ?? "") !== (b.period_text ?? "") ||
        (a.institution ?? "") !== (b.institution ?? "") ||
        (a.major ?? "") !== (b.major ?? "") ||
        (a.qualification_id ?? "") !== (b.qualification_id ?? "")
      ) {
        return true;
      }
    }
    return false;
  }, [
    isEditMode,
    detail,
    editedFullName,
    editedPhone,
    editedDateOfBirth,
    editedGender,
    editedAddress,
    editedSourceId,
    editedHrNote,
    editedEducation,
  ]);

  const handleEnterEditMode = useCallback(() => {
    if (!detail) return;
    setIsEditMode(true);
    setEditedFullName(detail.full_name);
    setEditedPhone(detail.phone ?? "");
    setEditedDateOfBirth(detail.date_of_birth ?? "");
    setEditedGender(detail.gender_code ?? "MALE");
    setEditedAddress(detail.current_address ?? "");
    setEditedSourceId(detail.recruitment_source_id ?? "");
    setEditedHrNote(detail.hr_note ?? "");
    setEditedEducation(
      detail.education.map((e) => ({
        education_id: e.education_id,
        period_text: e.period_text ?? "",
        institution: e.institution ?? "",
        major: e.major ?? "",
        qualification_id: e.qualification_id ?? "",
        qualification_name: e.qualification_name ?? "",
      })),
    );
    setSaveError(null);
    focusTargetRef.current = "hrNoteTextarea";

    const loadSources =
      actions?.getRecruitmentSources ?? getRecruitmentSourcesAction;
    loadSources()
      .then((sources) => {
        if (Array.isArray(sources)) {
          setRecruitmentSources(sources);
        }
      })
      .catch((err) => {
        console.warn("[SubmissionDetailDrawer] getRecruitmentSources:", err);
      });

    const loadQuals =
      actions?.getQualificationLevels ?? getQualificationLevelsAction;
    loadQuals()
      .then((quals) => {
        if (Array.isArray(quals)) {
          setQualificationLevels(quals);
        }
      })
      .catch((err) => {
        console.warn("[SubmissionDetailDrawer] getQualificationLevels:", err);
      });
  }, [detail, actions?.getRecruitmentSources, actions?.getQualificationLevels]);

  const handleAddEducation = useCallback(() => {
    setEditedEducation((prev) => [
      ...prev,
      {
        education_id: crypto.randomUUID(),
        period_text: "",
        institution: "",
        major: "",
        qualification_id: "",
        qualification_name: "",
      },
    ]);
  }, []);

  const handleRemoveEducation = useCallback((index: number) => {
    setEditedEducation((prev) => prev.filter((_, idx) => idx !== index));
  }, []);

  const handleEducationChange = useCallback(
    (
      index: number,
      field: "period_text" | "institution" | "major" | "qualification_id",
      value: string,
    ) => {
      setEditedEducation((prev) =>
        prev.map((item, idx) => {
          if (idx !== index) return item;
          return { ...item, [field]: value };
        }),
      );
    },
    [],
  );

  const handleCancelEdit = useCallback(() => {
    if (isDirty) {
      setDiscardAction("exit_edit");
      setShowDiscardConfirm(true);
      return;
    }
    setIsEditMode(false);
    setSaveError(null);
    focusTargetRef.current = "editButton";
  }, [isDirty]);

  const handleRequestClose = useCallback(() => {
    if (isDirty) {
      setDiscardAction("close_drawer");
      setShowDiscardConfirm(true);
      return;
    }
    setIsEditMode(false);
    onClose();
    // Return focus to trigger (drawer close is only transition restoring focus to external trigger)
    triggerElementRef.current?.focus();
  }, [isDirty, onClose]);
  // Focus trap inside drawer (active when discard dialog and preview modal are closed)
  useEffect(() => {
    if (!isOpen || showDiscardConfirm || previewDoc) return;

    const drawerNode = drawerRef.current;
    if (!drawerNode) return;

    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Tab") {
        const focusable = drawerNode.querySelectorAll<HTMLElement>(
          'button:not([disabled]):not([tabindex="-1"]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        );
        if (focusable.length === 0) return;

        const first = focusable[0];
        const last = focusable[focusable.length - 1];

        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      } else if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        handleRequestClose();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isOpen, showDiscardConfirm, previewDoc, handleRequestClose]);

  const handleCancelDiscard = useCallback(() => {
    setShowDiscardConfirm(false);
    if (isEditMode) {
      focusTargetRef.current = "hrNoteTextarea";
    } else if (editButtonRef.current) {
      editButtonRef.current.focus();
    } else if (drawerRef.current) {
      drawerRef.current.focus();
    }
  }, [isEditMode]);

  // Discard dialog focus trap & Escape dismissal
  useEffect(() => {
    if (!showDiscardConfirm) return;

    const dialogNode = discardDialogRef.current;
    if (!dialogNode) return;

    cancelDiscardBtnRef.current?.focus();

    const handleDiscardKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Tab") {
        const focusable = dialogNode.querySelectorAll<HTMLElement>(
          'button:not([disabled]):not([tabindex="-1"]), [tabindex]:not([tabindex="-1"])',
        );
        if (focusable.length === 0) return;

        const first = focusable[0];
        const last = focusable[focusable.length - 1];

        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      } else if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        handleCancelDiscard();
      }
    };

    window.addEventListener("keydown", handleDiscardKeyDown);
    return () => window.removeEventListener("keydown", handleDiscardKeyDown);
  }, [showDiscardConfirm, handleCancelDiscard]);

  // Preview modal focus trap & Escape dismissal + focus restore
  useEffect(() => {
    if (!previewDoc) return;

    const modalNode = previewModalRef.current;
    if (!modalNode) return;

    previewCloseBtnRef.current?.focus();

    const handlePreviewKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Tab") {
        const focusable = modalNode.querySelectorAll<HTMLElement>(
          'button:not([disabled]):not([tabindex="-1"]), [href], iframe, [tabindex]:not([tabindex="-1"])',
        );
        if (focusable.length === 0) return;

        const first = focusable[0];
        const last = focusable[focusable.length - 1];

        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      } else if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        setPreviewDoc(null);
      }
    };

    window.addEventListener("keydown", handlePreviewKeyDown);
    return () => {
      window.removeEventListener("keydown", handlePreviewKeyDown);
      previewTriggerRef.current?.focus();
    };
  }, [previewDoc]);

  const handleConfirmDiscard = () => {
    setShowDiscardConfirm(false);
    setIsEditMode(false);
    if (detail) {
      setEditedFullName(detail.full_name);
      setEditedPhone(detail.phone ?? "");
      setEditedDateOfBirth(detail.date_of_birth ?? "");
      setEditedGender(detail.gender_code ?? "MALE");
      setEditedAddress(detail.current_address ?? "");
      setEditedSourceId(detail.recruitment_source_id ?? "");
      setEditedHrNote(detail.hr_note ?? "");
      setEditedEducation(
        detail.education.map((e) => ({
          education_id: e.education_id,
          period_text: e.period_text ?? "",
          institution: e.institution ?? "",
          major: e.major ?? "",
          qualification_id: e.qualification_id ?? "",
          qualification_name: e.qualification_name ?? "",
        })),
      );
    }
    setSaveError(null);

    if (discardAction === "close_drawer") {
      onClose();
      triggerElementRef.current?.focus();
    } else {
      // Exit edit mode, keep drawer open! Focus edit button post-commit
      focusTargetRef.current = "editButton";
    }
  };

  const handleSaveHrNote = () => {
    if (!detail) return;
    setSaveError(null);

    const trimmedName = editedFullName.trim();
    if (!trimmedName) {
      setSaveError("Họ và tên không được để trống.");
      return;
    }
    if (trimmedName.length > 200) {
      setSaveError("Họ và tên không được vượt quá 200 ký tự.");
      return;
    }
    const trimmedPhone = editedPhone.trim();
    if (trimmedPhone.length > 32) {
      setSaveError("Số điện thoại không được vượt quá 32 ký tự.");
      return;
    }
    const trimmedAddress = editedAddress.trim();
    if (trimmedAddress.length > 500) {
      setSaveError("Địa chỉ không được vượt quá 500 ký tự.");
      return;
    }

    startSaveNoteTransition(async () => {
      const hasAggregateAction =
        Boolean(actions?.updateSubmissionAggregate) ||
        !actions?.updateSubmissionHrNote;

      if (!hasAggregateAction && actions?.updateSubmissionHrNote) {
        const res = await actions.updateSubmissionHrNote({
          submissionId: detail.submission_id,
          hrNote: editedHrNote.trim() ? editedHrNote.trim() : null,
          expectedVersion: detail.version_no,
        });

        if (res.success) {
          setDetail((prev) =>
            prev
              ? {
                  ...prev,
                  hr_note: res.data.hr_note ?? null,
                  version_no: res.data.version_no,
                }
              : null,
          );
          focusTargetRef.current = "editButton";
          setIsEditMode(false);
          onSubmissionUpdated?.({
            submissionId: detail.submission_id,
            hrNote: res.data.hr_note ?? null,
            versionNo: res.data.version_no,
            status: detail.status_code,
            hasApplication: detail.applications.some((a) => a.is_active),
            hasActiveApplication: detail.applications.some((a) => a.is_active),
          });
        } else {
          if (res.code === "STALE_VERSION") {
            setSaveError(
              "Dữ liệu đã thay đổi bởi người khác (STALE_VERSION). Vui lòng tải lại trang để xem nội dung mới nhất.",
            );
          } else {
            setSaveError(res.error || "Không thể lưu ghi chú HR.");
          }
        }
        return;
      }

      const updateAction =
        actions?.updateSubmissionAggregate ?? updateSubmissionAggregateAction;
      const res = await updateAction({
        submissionId: detail.submission_id,
        expectedVersion: detail.version_no,
        fullName: trimmedName,
        phone: trimmedPhone || null,
        dateOfBirth: editedDateOfBirth || null,
        genderCode: editedGender,
        currentAddress: trimmedAddress || null,
        recruitmentSourceId: editedSourceId || null,
        hrNote: editedHrNote.trim() ? editedHrNote.trim() : null,
        education: editedEducation.map((e) => ({
          periodText: e.period_text || null,
          institutionName: e.institution || null,
          majorName: e.major || null,
          qualificationId: e.qualification_id || null,
        })),
      });

      if (res.success) {
        setIsEditMode(false);
        setSaveError(null);
        focusTargetRef.current = "editButton";
        const fetchDetail =
          actions?.getSubmissionDetail ?? getSubmissionDetailAction;
        const refreshed = await fetchDetail(detail.submission_id);
        if (refreshed.success) {
          setDetail(refreshed.data);
          onSubmissionUpdated?.({
            submissionId: refreshed.data.submission_id,
            hrNote: refreshed.data.hr_note ?? null,
            versionNo: refreshed.data.version_no,
            status: refreshed.data.status_code,
            hasApplication: refreshed.data.applications.some(
              (a) => a.is_active,
            ),
            hasActiveApplication: refreshed.data.applications.some(
              (a) => a.is_active,
            ),
          });
        }
      } else {
        if (res.code === "STALE_VERSION") {
          setSaveError(
            "Dữ liệu đã thay đổi bởi người khác (STALE_VERSION). Vui lòng tải lại trang để xem nội dung mới nhất.",
          );
        } else {
          setSaveError(
            res.error || "Không thể cập nhật thông tin phiếu ứng tuyển.",
          );
        }
      }
    });
  };

  const handleDocumentAction = (
    doc: SubmissionDocumentItem,
    mode: "preview" | "download",
  ) => {
    setDocError(null);
    startDocActionTransition(async () => {
      const getSignedUrl =
        actions?.getDocumentSignedUrl ?? getDocumentSignedUrlAction;
      const res = await getSignedUrl({
        submissionId: doc.document_id ? (detail?.submission_id ?? "") : "",
        documentId: doc.document_id,
        logicalDocumentId: doc.logical_document_id,
        mode,
      });

      if (res.success) {
        if (mode === "preview") {
          previewTriggerRef.current =
            document.activeElement as HTMLElement | null;
          setPreviewDoc({
            previewUrl: res.previewUrl ?? res.signedUrl,
            filename: res.originalFilename,
            mimeType: res.mimeType,
          });
        } else {
          // Trigger download in browser
          const link = document.createElement("a");
          link.href = res.signedUrl;
          link.download = res.originalFilename;
          document.body.appendChild(link);
          link.click();
          document.body.removeChild(link);
        }
      } else {
        setDocError(res.error);
      }
    });
  };

  const handleLoadOptions = async () => {
    setIsLoadingOptions(true);
    try {
      const getOptions =
        actions?.getAssignmentOptions ?? getAssignmentOptionsAction;
      const res = await getOptions();
      if (res.success) {
        setAssignmentOptions(res.data);
        setOptionsLoadError(null);
        setShowAssignForm(true);
      } else {
        setShowAssignForm(false);
        setOptionsLoadError(res.error || "Không thể tải danh mục phân công.");
      }
    } catch (err: unknown) {
      setShowAssignForm(false);
      console.error("[SubmissionDetailDrawer] handleLoadOptions failed:", err);
      setOptionsLoadError("Không thể tải danh mục phân công.");
    } finally {
      setIsLoadingOptions(false);
    }
  };

  const handleOpenAssignForm = () => {
    setAssignError(null);
    setActiveDuplicateWarning(null);
    setAssignIdempotencyKey(crypto.randomUUID());
    if (!assignmentOptions) {
      handleLoadOptions();
    } else {
      setShowAssignForm(true);
    }
  };

  const handleUnitChange = (newUnitId: string) => {
    setSelectedUnitId(newUnitId);
    setSelectedTeamId("");
    setSelectedPositionId("");
    setActiveDuplicateWarning(null);
  };

  const handleTeamChange = (newTeamId: string) => {
    setSelectedTeamId(newTeamId);
    setSelectedPositionId("");
    setActiveDuplicateWarning(null);
  };

  const handlePositionChange = (newPosId: string) => {
    setSelectedPositionId(newPosId);
    setActiveDuplicateWarning(null);
  };

  const handleHrOwnerChange = (newOwnerId: string) => {
    setSelectedHrOwnerId(newOwnerId);
    setActiveDuplicateWarning(null);
  };

  const handleAssignApplication = (forceConfirm = false) => {
    if (
      !detail ||
      !selectedUnitId ||
      !selectedPositionId ||
      !selectedHrOwnerId
    ) {
      setAssignError(
        "Vui lòng chọn đầy đủ Khoa/Phòng, Vị trí và Người phụ trách HR.",
      );
      return;
    }

    setAssignError(null);

    const currentContextKey = computeAssignmentContextKey({
      submissionId: detail.submission_id,
      unitId: selectedUnitId,
      departmentTeamId: selectedTeamId || undefined,
      positionId: selectedPositionId,
      hrOwnerId: selectedHrOwnerId,
    });

    let willConfirmDuplicate = false;
    if (forceConfirm) {
      if (
        !activeDuplicateWarning ||
        activeDuplicateWarning.contextKey !== currentContextKey
      ) {
        setActiveDuplicateWarning(null);
        setAssignError(
          "Thông tin vị trí hoặc người phụ trách đã thay đổi. Vui lòng kiểm tra lại trước khi xác nhận.",
        );
        return;
      }
      willConfirmDuplicate = true;
    }

    // Check if active duplicate in current detail without confirmation
    const existingActive = detail.applications.find(
      (a) =>
        a.is_active &&
        a.unit_id === selectedUnitId &&
        a.position_id === selectedPositionId &&
        (selectedTeamId
          ? a.department_team_id === selectedTeamId
          : !a.department_team_id),
    );

    if (existingActive && !willConfirmDuplicate) {
      setActiveDuplicateWarning({
        message: `Đã tồn tại Application đang hoạt động cho vị trí này (Người phụ trách: ${existingActive.hr_owner_name}). Bạn có muốn cập nhật người phụ trách?`,
        contextKey: currentContextKey,
      });
      return;
    }

    startAssignTransition(async () => {
      const createAction =
        actions?.createApplication ?? createApplicationAction;
      const res = await createAction({
        submissionId: detail.submission_id,
        unitId: selectedUnitId,
        departmentTeamId: selectedTeamId || undefined,
        positionId: selectedPositionId,
        hrOwnerId: selectedHrOwnerId,
        idempotencyKey: assignIdempotencyKey,
        confirmDuplicate: willConfirmDuplicate,
      });

      if (res.success) {
        const fetchDetail =
          actions?.getSubmissionDetail ?? getSubmissionDetailAction;
        const refreshed = await fetchDetail(detail.submission_id);
        if (refreshed.success) {
          setDetail(refreshed.data);
        }
        setShowAssignForm(false);
        setActiveDuplicateWarning(null);
        setSelectedUnitId("");
        setSelectedTeamId("");
        setSelectedPositionId("");
        setSelectedHrOwnerId("");
        setAssignIdempotencyKey(crypto.randomUUID());
        onSubmissionUpdated?.({
          submissionId: detail.submission_id,
          hrNote: detail.hr_note,
          versionNo: detail.version_no,
          status: detail.status_code,
          hasApplication: true,
          hasActiveApplication: true,
        });
      } else {
        if (res.code === "DUPLICATE_APPLICATION") {
          setActiveDuplicateWarning({
            message:
              res.error ||
              "Đã tồn tại Application đang hoạt động cho vị trí này. Bạn có muốn cập nhật người phụ trách?",
            contextKey: currentContextKey,
          });
        } else if (res.code === "ALREADY_EXISTS_INACTIVE") {
          setAssignError(
            "Đã tồn tại Application ở trạng thái không hoạt động cho vị trí này. Vui lòng sử dụng tính năng Kích hoạt lại (Reactivate).",
          );
        } else {
          setAssignError(res.error || "Không thể tạo Application.");
        }
      }
    });
  };

  if (!isOpen) return null;

  // Filter teams and positions based on selections
  const filteredTeams =
    assignmentOptions?.department_teams.filter(
      (t) => t.unit_id === selectedUnitId,
    ) ?? [];
  const filteredPositions =
    assignmentOptions?.positions.filter((p) => {
      if (p.unit_id !== selectedUnitId) return false;
      if (selectedTeamId) return p.department_team_id === selectedTeamId;
      return !p.department_team_id;
    }) ?? [];

  return (
    <div className="submission-drawer-container">
      <button
        type="button"
        className="submission-drawer-backdrop"
        aria-label="Đóng ngăn chi tiết"
        tabIndex={-1}
        onClick={handleRequestClose}
      />
      <div
        ref={drawerRef}
        className="submission-drawer"
        role="dialog"
        aria-modal="true"
        aria-labelledby="submission-drawer-title"
        tabIndex={-1}
      >
        {/* Drawer Header */}
        <header className="submission-drawer__header">
          <div className="submission-drawer__header-info">
            <h2
              id="submission-drawer-title"
              className="submission-drawer__title"
            >
              Chi tiết Phiếu Ứng tuyển
            </h2>
            {detail && (
              <span className="submission-drawer__subtitle">
                {detail.full_name} — Trạng thái: {detail.status_code}
              </span>
            )}
          </div>
          <div className="submission-drawer__header-actions">
            {!loading && detail && !isEditMode && (
              <button
                ref={editButtonRef}
                type="button"
                className="btn-secondary submission-drawer__edit-btn workflow-edit-action"
                onClick={handleEnterEditMode}
              >
                Chỉnh sửa
              </button>
            )}
            {isEditMode && (
              <span className="badge-edit-mode" role="status">
                Đang chỉnh sửa
              </span>
            )}
            <button
              ref={closeButtonRef}
              type="button"
              className="btn-icon submission-drawer__close-btn"
              aria-label="Đóng chi tiết phiếu"
              onClick={handleRequestClose}
            >
              ✕
            </button>
          </div>
        </header>

        {/* Drawer Content */}
        <div className="submission-drawer__content">
          {loading ? (
            <div
              className="submission-drawer__loading"
              role="status"
              aria-live="polite"
            >
              Đang tải chi tiết phiếu...
            </div>
          ) : errorMessage ? (
            <div className="submission-drawer__error" role="alert">
              {errorMessage}
            </div>
          ) : detail ? (
            <>
              {saveError && (
                <div
                  className="submission-drawer__alert submission-drawer__alert--error"
                  role="alert"
                >
                  {saveError}
                </div>
              )}
              {docError && (
                <div
                  className="submission-drawer__alert submission-drawer__alert--error"
                  role="alert"
                >
                  {docError}
                </div>
              )}

              {/* 1. Thông tin chung */}
              <section className="drawer-section" aria-labelledby="sec-general">
                <h3 id="sec-general" className="drawer-section__title">
                  1. Thông tin chung
                </h3>
                <table className="drawer-kv-table">
                  <tbody>
                    <tr>
                      <th scope="row">
                        <label htmlFor="drawer-full-name-input">
                          Họ và tên:
                        </label>
                      </th>
                      <td>
                        {isEditMode ? (
                          <div className="drawer-edit-field">
                            <input
                              ref={fullNameInputRef}
                              id="drawer-full-name-input"
                              className="drawer-input"
                              type="text"
                              value={editedFullName}
                              onChange={(e) =>
                                setEditedFullName(e.target.value)
                              }
                              required
                              maxLength={200}
                              placeholder="Họ và tên ứng viên..."
                            />
                          </div>
                        ) : (
                          detail.full_name
                        )}
                      </td>
                    </tr>
                    <tr>
                      <th scope="row">Email:</th>
                      <td>
                        {detail.email}
                        {isEditMode && (
                          <small className="drawer-immutable-hint">
                            (Email đã xác minh — không thể chỉnh sửa)
                          </small>
                        )}
                      </td>
                    </tr>
                    <tr>
                      <th scope="row">
                        <label htmlFor="drawer-dob-input">Ngày sinh:</label>
                      </th>
                      <td>
                        {isEditMode ? (
                          <div className="drawer-edit-field">
                            <input
                              id="drawer-dob-input"
                              className="drawer-input"
                              type="date"
                              value={editedDateOfBirth}
                              onChange={(e) =>
                                setEditedDateOfBirth(e.target.value)
                              }
                              max={new Date().toISOString().split("T")[0]}
                            />
                          </div>
                        ) : (
                          formatDate(detail.date_of_birth)
                        )}
                      </td>
                    </tr>
                    <tr>
                      <th scope="row">
                        <label htmlFor="drawer-gender-select">Giới tính:</label>
                      </th>
                      <td>
                        {isEditMode ? (
                          <div className="drawer-edit-field">
                            <select
                              id="drawer-gender-select"
                              className="drawer-select"
                              value={editedGender}
                              onChange={(e) => setEditedGender(e.target.value)}
                            >
                              <option value="MALE">Nam</option>
                              <option value="FEMALE">Nữ</option>
                            </select>
                          </div>
                        ) : detail.gender_code === "MALE" ? (
                          "Nam"
                        ) : detail.gender_code === "FEMALE" ? (
                          "Nữ"
                        ) : (
                          "—"
                        )}
                      </td>
                    </tr>
                    <tr>
                      <th scope="row">
                        <label htmlFor="drawer-phone-input">
                          Số điện thoại:
                        </label>
                      </th>
                      <td>
                        {isEditMode ? (
                          <div className="drawer-edit-field">
                            <input
                              id="drawer-phone-input"
                              className="drawer-input"
                              type="tel"
                              value={editedPhone}
                              onChange={(e) => setEditedPhone(e.target.value)}
                              maxLength={32}
                              placeholder="Số điện thoại liên lạc..."
                            />
                          </div>
                        ) : (
                          (detail.phone ?? "—")
                        )}
                      </td>
                    </tr>
                    <tr>
                      <th scope="row">
                        <label htmlFor="drawer-address-input">
                          Địa chỉ hiện tại:
                        </label>
                      </th>
                      <td>
                        {isEditMode ? (
                          <div className="drawer-edit-field">
                            <input
                              id="drawer-address-input"
                              className="drawer-input"
                              type="text"
                              value={editedAddress}
                              onChange={(e) => setEditedAddress(e.target.value)}
                              maxLength={500}
                              placeholder="Địa chỉ cư trú..."
                            />
                          </div>
                        ) : (
                          (detail.current_address ?? "—")
                        )}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </section>

              {/* 2. Education */}
              <section
                className="drawer-section"
                aria-labelledby="sec-education"
              >
                <h3 id="sec-education" className="drawer-section__title">
                  2. Học vấn (Education)
                </h3>
                {isEditMode ? (
                  <div className="drawer-list">
                    {editedEducation.length === 0 ? (
                      <p className="drawer-empty-text">
                        Chưa có thông tin học vấn.
                      </p>
                    ) : (
                      editedEducation.map((edu, idx) => (
                        <div
                          key={edu.education_id || idx}
                          className="drawer-sub-item"
                        >
                          <table className="drawer-kv-table">
                            <tbody>
                              <tr>
                                <th scope="row">
                                  <label htmlFor={`drawer-edu-period-${idx}`}>
                                    Thời gian:
                                  </label>
                                </th>
                                <td>
                                  <input
                                    id={`drawer-edu-period-${idx}`}
                                    className="drawer-input"
                                    type="text"
                                    value={edu.period_text}
                                    onChange={(e) =>
                                      handleEducationChange(
                                        idx,
                                        "period_text",
                                        e.target.value,
                                      )
                                    }
                                    placeholder="Ví dụ: 2013 - 2017"
                                  />
                                </td>
                              </tr>
                              <tr>
                                <th scope="row">
                                  <label htmlFor={`drawer-edu-qual-${idx}`}>
                                    Trình độ / Bằng cấp:
                                  </label>
                                </th>
                                <td>
                                  <select
                                    id={`drawer-edu-qual-${idx}`}
                                    className="drawer-select"
                                    value={edu.qualification_id}
                                    onChange={(e) =>
                                      handleEducationChange(
                                        idx,
                                        "qualification_id",
                                        e.target.value,
                                      )
                                    }
                                  >
                                    <option value="">
                                      -- Chọn trình độ / bằng cấp --
                                    </option>
                                    {qualificationLevels.map((q) => (
                                      <option
                                        key={q.qualification_id}
                                        value={q.qualification_id}
                                      >
                                        {q.name_vi}
                                      </option>
                                    ))}
                                  </select>
                                </td>
                              </tr>
                              <tr>
                                <th scope="row">
                                  <label htmlFor={`drawer-edu-major-${idx}`}>
                                    Chuyên ngành:
                                  </label>
                                </th>
                                <td>
                                  <input
                                    id={`drawer-edu-major-${idx}`}
                                    className="drawer-input"
                                    type="text"
                                    value={edu.major}
                                    onChange={(e) =>
                                      handleEducationChange(
                                        idx,
                                        "major",
                                        e.target.value,
                                      )
                                    }
                                    placeholder="Chuyên ngành đào tạo..."
                                  />
                                </td>
                              </tr>
                              <tr>
                                <th scope="row">
                                  <label htmlFor={`drawer-edu-inst-${idx}`}>
                                    Cơ sở đào tạo:
                                  </label>
                                </th>
                                <td>
                                  <input
                                    id={`drawer-edu-inst-${idx}`}
                                    className="drawer-input"
                                    type="text"
                                    value={edu.institution}
                                    onChange={(e) =>
                                      handleEducationChange(
                                        idx,
                                        "institution",
                                        e.target.value,
                                      )
                                    }
                                    placeholder="Trường / Cơ sở đào tạo..."
                                  />
                                </td>
                              </tr>
                            </tbody>
                          </table>
                          <div className="drawer-edu-actions">
                            <button
                              type="button"
                              className="btn-secondary btn-sm"
                              onClick={() => handleRemoveEducation(idx)}
                              aria-label={`Xóa mục học vấn ${idx + 1}`}
                            >
                              Xóa học vấn
                            </button>
                          </div>
                        </div>
                      ))
                    )}
                    <button
                      type="button"
                      className="btn-secondary btn-sm drawer-add-edu-btn"
                      onClick={handleAddEducation}
                    >
                      + Thêm học vấn
                    </button>
                  </div>
                ) : detail.education.length === 0 ? (
                  <p className="drawer-empty-text">
                    Chưa có thông tin học vấn.
                  </p>
                ) : (
                  <div className="drawer-list">
                    {detail.education.map((edu, idx) => (
                      <table
                        key={edu.education_id || idx}
                        className="drawer-kv-table drawer-sub-item"
                      >
                        <tbody>
                          <tr>
                            <th scope="row">Thời gian:</th>
                            <td>{edu.period_text ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Trình độ / Bằng cấp:</th>
                            <td>{edu.qualification_name ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Chuyên ngành:</th>
                            <td>{edu.major ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Cơ sở đào tạo:</th>
                            <td>{edu.institution ?? "—"}</td>
                          </tr>
                        </tbody>
                      </table>
                    ))}
                  </div>
                )}
              </section>
              {/* 3. Working Experiences (HR only) */}
              <section
                className="drawer-section"
                aria-labelledby="sec-experience"
              >
                <h3 id="sec-experience" className="drawer-section__title">
                  3. Kinh nghiệm làm việc (Working Experiences)
                </h3>
                {detail.work_experiences.length === 0 ? (
                  <p className="drawer-empty-text">
                    Chưa có thông tin kinh nghiệm.
                  </p>
                ) : (
                  <div className="drawer-list">
                    {detail.work_experiences.map((exp, idx) => (
                      <table
                        key={exp.experience_id || idx}
                        className="drawer-kv-table drawer-sub-item"
                      >
                        <tbody>
                          <tr>
                            <th scope="row">Thời gian:</th>
                            <td>
                              {formatDate(exp.start_date)} —{" "}
                              {exp.is_current
                                ? "Hiện tại"
                                : formatDate(exp.end_date)}
                            </td>
                          </tr>
                          <tr>
                            <th scope="row">Đơn vị công tác:</th>
                            <td>{exp.employer ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Vị trí / Chức danh:</th>
                            <td>{exp.job_title ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Mô tả công việc:</th>
                            <td>{exp.job_description ?? "—"}</td>
                          </tr>
                        </tbody>
                      </table>
                    ))}
                  </div>
                )}
              </section>

              {/* 4. Activities (HR only) */}
              <section
                className="drawer-section"
                aria-labelledby="sec-activities"
              >
                <h3 id="sec-activities" className="drawer-section__title">
                  4. Hoạt động (Activities)
                </h3>
                {detail.activities.length === 0 ? (
                  <p className="drawer-empty-text">
                    Chưa có thông tin hoạt động.
                  </p>
                ) : (
                  <div className="drawer-list">
                    {detail.activities.map((act, idx) => (
                      <table
                        key={act.activity_id || idx}
                        className="drawer-kv-table drawer-sub-item"
                      >
                        <tbody>
                          <tr>
                            <th scope="row">Thời gian:</th>
                            <td>{act.period_text ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Tên hoạt động:</th>
                            <td>{act.activity_name ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Vai trò:</th>
                            <td>{act.role_name ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Đơn vị tổ chức:</th>
                            <td>{act.organizer ?? "—"}</td>
                          </tr>
                          <tr>
                            <th scope="row">Mô tả:</th>
                            <td>{act.description ?? "—"}</td>
                          </tr>
                        </tbody>
                      </table>
                    ))}
                  </div>
                )}
              </section>

              {/* 5. Other (HR only) */}
              <section className="drawer-section" aria-labelledby="sec-other">
                <h3 id="sec-other" className="drawer-section__title">
                  5. Thông tin khác (Other)
                </h3>
                <table className="drawer-kv-table">
                  <tbody>
                    <tr>
                      <th scope="row">Thông tin thêm:</th>
                      <td>{detail.other_info ?? "—"}</td>
                    </tr>
                  </tbody>
                </table>
              </section>

              {/* 6. Documents */}
              <section
                className="drawer-section"
                aria-labelledby="sec-documents"
              >
                <h3 id="sec-documents" className="drawer-section__title">
                  6. Tài liệu (Documents)
                </h3>
                {detail.documents.length === 0 ? (
                  <p className="drawer-empty-text">
                    Chưa có tài liệu nào được đính kèm.
                  </p>
                ) : (
                  <div className="drawer-doc-list">
                    {detail.documents.map((doc) => {
                      return (
                        <div key={doc.document_id} className="drawer-doc-item">
                          <div className="drawer-doc-item__info">
                            <strong className="drawer-doc-item__name">
                              {doc.document_type_name ??
                                doc.document_type_code ??
                                "Tài liệu"}
                              : {doc.original_filename}
                            </strong>
                            <span className="drawer-doc-item__meta">
                              {formatFileSize(doc.file_size_bytes)} — Tải lên:{" "}
                              {formatDateTime(doc.uploaded_at)}
                            </span>
                          </div>
                          <AttachmentActions
                            filename={doc.original_filename}
                            mimeType={doc.mime_type}
                            previewable={doc.previewable}
                            pending={docActionPending}
                            onPreview={() =>
                              handleDocumentAction(doc, "preview")
                            }
                            onDownload={() =>
                              handleDocumentAction(doc, "download")
                            }
                          />
                        </div>
                      );
                    })}
                  </div>
                )}
              </section>

              {/* 7. HR Note / Nguồn tuyển dụng */}
              <section className="drawer-section" aria-labelledby="sec-hr-note">
                <h3 id="sec-hr-note" className="drawer-section__title">
                  7. Ghi chú HR / Nguồn tuyển dụng
                </h3>
                <table className="drawer-kv-table">
                  <tbody>
                    <tr>
                      <th scope="row">
                        <label htmlFor="drawer-hr-note-input">
                          Ghi chú HR:
                        </label>
                      </th>
                      <td>
                        {isEditMode ? (
                          <div className="drawer-edit-field">
                            <textarea
                              ref={hrNoteTextareaRef}
                              id="drawer-hr-note-input"
                              className="drawer-textarea"
                              rows={4}
                              value={editedHrNote}
                              onChange={(e) => setEditedHrNote(e.target.value)}
                              placeholder="Nhập ghi chú cho nhân sự..."
                            />
                          </div>
                        ) : (
                          <span className="drawer-hr-note-text">
                            {detail.hr_note ?? "—"}
                          </span>
                        )}
                      </td>
                    </tr>
                    <tr>
                      <th scope="row">
                        <label htmlFor="drawer-source-select">
                          Nguồn tuyển dụng:
                        </label>
                      </th>
                      <td>
                        {isEditMode ? (
                          <div className="drawer-edit-field">
                            <select
                              id="drawer-source-select"
                              className="drawer-select"
                              value={editedSourceId}
                              onChange={(e) =>
                                setEditedSourceId(e.target.value)
                              }
                            >
                              <option value="">
                                -- Chọn nguồn tuyển dụng (Tùy chọn) --
                              </option>
                              {recruitmentSources.map((s) => (
                                <option
                                  key={s.recruitment_source_id}
                                  value={s.recruitment_source_id}
                                >
                                  {s.name_vi}
                                </option>
                              ))}
                            </select>
                          </div>
                        ) : (
                          (detail.recruitment_source_name ?? "—")
                        )}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </section>

              {/* 8. Cập nhật thông tin tuyển dụng */}
              <section
                className="drawer-section"
                aria-labelledby="sec-app-update"
              >
                <div className="drawer-section__header-row">
                  <h3 id="sec-app-update" className="drawer-section__title">
                    8. Cập nhật thông tin tuyển dụng
                  </h3>
                  <span className="drawer-app-status-badge">
                    {detail.applications.length === 0
                      ? "Update"
                      : `Updated (${detail.applications.length})`}
                  </span>
                </div>

                {detail.applications.length > 0 && (
                  <div className="drawer-app-list">
                    {detail.applications.map((app) => (
                      <div key={app.application_id} className="drawer-app-item">
                        <div>
                          <strong>{app.position_name}</strong> — {app.unit_name}
                          {app.department_team_name
                            ? ` / ${app.department_team_name}`
                            : ""}
                        </div>
                        <div className="drawer-app-item__meta">
                          Phụ trách HR: {app.hr_owner_name} | Vòng:{" "}
                          {app.round_count > 0
                            ? `Vòng 1 (tổng ${app.round_count})`
                            : "Chưa có"}{" "}
                          | Ngày gán: {formatDateTime(app.created_at)}
                        </div>
                      </div>
                    ))}
                  </div>
                )}

                {/* Assignment Controls */}
                {!showAssignForm ? (
                  <div className="drawer-assign-trigger">
                    <button
                      type="button"
                      className="btn-secondary"
                      onClick={handleOpenAssignForm}
                      disabled={isLoadingOptions}
                    >
                      {isLoadingOptions
                        ? "Đang tải danh mục..."
                        : "+ Gán vị trí tuyển dụng mới"}
                    </button>
                    {optionsLoadError && (
                      <div
                        className="submission-drawer__alert submission-drawer__alert--error drawer-options-load-error"
                        role="alert"
                      >
                        <p className="drawer-options-load-error__text">
                          {optionsLoadError}
                        </p>
                        <button
                          type="button"
                          className="btn-secondary btn-sm"
                          onClick={handleLoadOptions}
                          disabled={isLoadingOptions}
                        >
                          {isLoadingOptions ? "Đang tải..." : "Thử lại"}
                        </button>
                      </div>
                    )}
                  </div>
                ) : (
                  <div className="drawer-assign-form">
                    <h4>Gán Application cho ứng viên</h4>
                    {assignError && (
                      <div
                        className="submission-drawer__alert submission-drawer__alert--error"
                        role="alert"
                      >
                        {assignError}
                      </div>
                    )}
                    {activeDuplicateWarning && (
                      <div
                        className="submission-drawer__alert submission-drawer__alert--warning"
                        role="alert"
                      >
                        <p>{activeDuplicateWarning.message}</p>
                        <div className="drawer-alert-actions">
                          <button
                            type="button"
                            className="btn-primary btn-sm"
                            onClick={() => handleAssignApplication(true)}
                            disabled={isAssigning}
                          >
                            Xác nhận cập nhật
                          </button>
                          <button
                            type="button"
                            className="btn-secondary btn-sm"
                            onClick={() => setActiveDuplicateWarning(null)}
                          >
                            Hủy
                          </button>
                        </div>
                      </div>
                    )}

                    <div className="form-group">
                      <label htmlFor="assign-unit">Khoa / Phòng *</label>
                      <select
                        id="assign-unit"
                        className="form-select"
                        value={selectedUnitId}
                        onChange={(e) => handleUnitChange(e.target.value)}
                      >
                        <option value="">-- Chọn Khoa / Phòng --</option>
                        {assignmentOptions?.units.map((u) => (
                          <option key={u.unit_id} value={u.unit_id}>
                            {u.name_vi}
                          </option>
                        ))}
                      </select>
                    </div>

                    {filteredTeams.length > 0 && (
                      <div className="form-group">
                        <label htmlFor="assign-team">
                          Ngành / Tổ (tùy chọn)
                        </label>
                        <select
                          id="assign-team"
                          className="form-select"
                          value={selectedTeamId}
                          onChange={(e) => handleTeamChange(e.target.value)}
                        >
                          <option value="">
                            -- Trực thuộc Khoa/Phòng (không có Tổ) --
                          </option>
                          {filteredTeams.map((t) => (
                            <option
                              key={t.department_team_id}
                              value={t.department_team_id}
                            >
                              {t.name_vi}
                            </option>
                          ))}
                        </select>
                      </div>
                    )}

                    <div className="form-group">
                      <label htmlFor="assign-pos">Vị trí tuyển dụng *</label>
                      <select
                        id="assign-pos"
                        className="form-select"
                        value={selectedPositionId}
                        onChange={(e) => handlePositionChange(e.target.value)}
                        disabled={!selectedUnitId}
                      >
                        <option value="">-- Chọn Vị trí --</option>
                        {filteredPositions.map((p) => (
                          <option key={p.position_id} value={p.position_id}>
                            {p.name_vi}
                          </option>
                        ))}
                      </select>
                    </div>

                    <div className="form-group">
                      <label htmlFor="assign-hr">Người phụ trách HR *</label>
                      <select
                        id="assign-hr"
                        className="form-select"
                        value={selectedHrOwnerId}
                        onChange={(e) => handleHrOwnerChange(e.target.value)}
                      >
                        <option value="">-- Chọn Nhân sự phụ trách --</option>
                        {assignmentOptions?.hr_owners.map((hr) => (
                          <option key={hr.app_user_id} value={hr.app_user_id}>
                            {hr.full_name} ({hr.email})
                          </option>
                        ))}
                      </select>
                    </div>
                    <div className="drawer-assign-actions">
                      <button
                        type="button"
                        className="btn-primary"
                        onClick={() => handleAssignApplication(false)}
                        disabled={
                          isAssigning ||
                          !selectedUnitId ||
                          !selectedPositionId ||
                          !selectedHrOwnerId
                        }
                      >
                        {isAssigning ? "Đang xử lý..." : "Tạo Application"}
                      </button>
                      <button
                        type="button"
                        className="btn-secondary"
                        onClick={() => {
                          setShowAssignForm(false);
                          setActiveDuplicateWarning(null);
                          setAssignIdempotencyKey(crypto.randomUUID());
                        }}
                      >
                        Đóng form
                      </button>
                    </div>
                  </div>
                )}
              </section>

              {/* 9. Cập nhật gần nhất */}
              <section
                className="drawer-section drawer-section--last"
                aria-labelledby="sec-last-updated"
              >
                <h3 id="sec-last-updated" className="sr-only">
                  9. Cập nhật gần nhất
                </h3>
                <p className="drawer-last-updated-text">
                  Cập nhật gần nhất: {formatDateTime(detail.updated_at)}
                  {detail.updated_by_name
                    ? ` — bởi ${detail.updated_by_name}`
                    : ""}
                </p>
              </section>
            </>
          ) : null}
        </div>

        {/* Drawer Footer in Edit Mode */}
        {isEditMode && (
          <footer className="submission-drawer__footer">
            <button
              type="button"
              className="btn-secondary"
              onClick={handleCancelEdit}
              disabled={isSavingNote}
            >
              Hủy
            </button>
            <button
              type="button"
              className="btn-primary"
              onClick={handleSaveHrNote}
              disabled={isSavingNote}
            >
              {isSavingNote ? "Đang lưu..." : "Lưu thay đổi"}
            </button>
          </footer>
        )}

        {/* Accessible Discard Confirmation Dialog */}
        {showDiscardConfirm && (
          <div
            className="discard-confirm-overlay"
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="discard-dialog-title"
            aria-describedby="discard-dialog-desc"
          >
            <div
              ref={discardDialogRef}
              className="discard-confirm-dialog"
              tabIndex={-1}
            >
              <h4
                id="discard-dialog-title"
                className="discard-confirm-dialog__title"
              >
                Hủy các thay đổi chưa lưu?
              </h4>
              <p
                id="discard-dialog-desc"
                className="discard-confirm-dialog__desc"
              >
                Bạn có thay đổi ghi chú chưa được lưu. Nếu tiếp tục, các thay
                đổi này sẽ bị hủy bỏ.
              </p>
              <div className="discard-confirm-dialog__actions">
                <button
                  ref={cancelDiscardBtnRef}
                  type="button"
                  className="btn-secondary"
                  onClick={handleCancelDiscard}
                >
                  Tiếp tục chỉnh sửa
                </button>
                <button
                  type="button"
                  className="btn-danger"
                  onClick={handleConfirmDiscard}
                >
                  Hủy thay đổi
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Document Preview Modal */}
        {previewDoc && (
          <div
            className="preview-modal-backdrop"
            role="dialog"
            aria-modal="true"
            aria-labelledby="preview-modal-title"
          >
            <div ref={previewModalRef} className="preview-modal" tabIndex={-1}>
              <header className="preview-modal__header">
                <h4 id="preview-modal-title" className="preview-modal__title">
                  Xem trước: {previewDoc.filename}
                </h4>
                <button
                  ref={previewCloseBtnRef}
                  type="button"
                  className="btn-icon"
                  aria-label="Đóng xem trước"
                  onClick={() => setPreviewDoc(null)}
                >
                  ✕
                </button>
              </header>
              <div className="preview-modal__body">
                {previewDoc.mimeType === "application/pdf" ? (
                  <iframe
                    src={previewDoc.previewUrl}
                    title={previewDoc.filename}
                    className="preview-iframe"
                  />
                ) : (
                  // biome-ignore lint/performance/noImgElement: same-origin private document preview
                  <img
                    src={previewDoc.previewUrl}
                    alt={previewDoc.filename}
                    className="preview-image"
                  />
                )}
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
