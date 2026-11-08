export enum CommandErrorCode {
  UNAUTHENTICATED = "UNAUTHENTICATED",
  FORBIDDEN = "FORBIDDEN",
  NOT_FOUND = "NOT_FOUND",
  INVALID_STATE = "INVALID_STATE",
  VALIDATION_ERROR = "VALIDATION_ERROR",
  STALE_VERSION = "STALE_VERSION",
  FORM_SESSION_EXPIRED = "FORM_SESSION_EXPIRED",
  UPLOAD_RESERVATION_EXPIRED = "UPLOAD_RESERVATION_EXPIRED",
  DUPLICATE_APPLICATION = "DUPLICATE_APPLICATION",
  APPLICATION_DURABLE_IDENTITY_IMMUTABLE = "APPLICATION_DURABLE_IDENTITY_IMMUTABLE",
  PRIVACY_NOTICE_UNAVAILABLE = "PRIVACY_NOTICE_UNAVAILABLE",
  PRIVACY_NOTICE_CHANGED = "PRIVACY_NOTICE_CHANGED",
  SCHEDULE_CONFLICT_CANDIDATE = "SCHEDULE_CONFLICT_CANDIDATE",
  SCHEDULE_CONFLICT_INTERVIEWER = "SCHEDULE_CONFLICT_INTERVIEWER",
  SCHEDULE_CONFLICT_ROOM = "SCHEDULE_CONFLICT_ROOM",
  LATEST_ROUND_REQUIRED = "LATEST_ROUND_REQUIRED",
  ROOT_ADMIN_PROTECTED = "ROOT_ADMIN_PROTECTED",
  IDENTITY_REBIND_FORBIDDEN = "IDENTITY_REBIND_FORBIDDEN",
  USER_INACTIVE = "USER_INACTIVE",
  UPLOAD_LIMIT_EXCEEDED = "UPLOAD_LIMIT_EXCEEDED",
  UNSUPPORTED_FILE_TYPE = "UNSUPPORTED_FILE_TYPE",
  MALWARE_SCAN_REQUIRED = "MALWARE_SCAN_REQUIRED",
  IDEMPOTENCY_REPLAY = "IDEMPOTENCY_REPLAY",
  INVALID_PERMISSION_DEPENDENCY = "INVALID_PERMISSION_DEPENDENCY",
  INACTIVE_DOCUMENT_TYPE = "INACTIVE_DOCUMENT_TYPE",
  INVALID_DOCUMENT_TYPE = "INVALID_DOCUMENT_TYPE",
  INVALID_FILE_TYPE = "INVALID_FILE_TYPE",
  FILE_SIZE_EXCEEDED = "FILE_SIZE_EXCEEDED",
  INVALID_ACTION = "INVALID_ACTION",
  INVALID_CONTENT_SIGNATURE = "INVALID_CONTENT_SIGNATURE",
  INVALID_MIME_TYPE = "INVALID_MIME_TYPE",
  INVALID_DOCUMENT_TARGET = "INVALID_DOCUMENT_TARGET",
  UPLOAD_RESERVATION_NOT_CLEAN = "UPLOAD_RESERVATION_NOT_CLEAN",
  MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED = "MAX_FIVE_CURRENT_DOCUMENTS_EXCEEDED",
  REQUIRED_CV_DOCUMENT_MISSING = "REQUIRED_CV_DOCUMENT_MISSING",
  HISTORICAL_SUBMISSION_READ_ONLY = "HISTORICAL_SUBMISSION_READ_ONLY",
  ALREADY_EXISTS_INACTIVE = "ALREADY_EXISTS_INACTIVE",
  INVALID_HIERARCHY = "INVALID_HIERARCHY",
  INTERNAL_ERROR = "INTERNAL_ERROR",
}

export type CommandError = {
  code: CommandErrorCode;
  message: string;
  details?: unknown;
};

export class CommandExecutionError extends Error {
  public readonly code: CommandErrorCode;
  public readonly details?: unknown;

  constructor(code: CommandErrorCode, message: string, details?: unknown) {
    super(message);
    this.name = "CommandExecutionError";
    this.code = code;
    this.details = details;
  }
}

export type CommandResult<T> =
  | { success: true; data: T }
  | { success: false; error: CommandError };

export type VerifiedActor = {
  authUserId: string;
  email: string;
  isActive: boolean;
  roles: string[];
  permissions: string[];
};

export type AuthorizationResult =
  | { authorized: true }
  | { authorized: false; reason?: string; code?: CommandErrorCode };

export type TrustedCommandDefinition<
  TRawInput,
  TTarget,
  TValidatedInput,
  TOutput,
> = {
  name: string;
  extractTarget?: (rawInput: TRawInput) => TTarget;
  authorize: (
    actor: VerifiedActor,
    target?: TTarget,
  ) => Promise<AuthorizationResult> | AuthorizationResult;
  validate: (
    rawInput: TRawInput,
  ) =>
    | { success: true; data: TValidatedInput }
    | { success: false; error: string; details?: unknown };
  execute: (
    actor: VerifiedActor,
    input: TValidatedInput,
  ) =>
    | Promise<TOutput | CommandResult<TOutput>>
    | TOutput
    | CommandResult<TOutput>;
};
