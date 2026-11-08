import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { createCommandRunner } from "@/lib/commands/runner";
import {
  CommandErrorCode,
  CommandExecutionError,
  type CommandResult,
  type TrustedCommandDefinition,
  type VerifiedActor,
} from "@/lib/commands/types";
import { createServerClient } from "@/lib/supabase/server";

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type CandidateFormSessionData = {
  candidate_form_session_id: string;
  mode_code: "NEW_SUBMISSION" | "EDIT_SUBMISSION" | string;
  presented_privacy_notice_version: string;
  status_code: string;
  expires_at: string;
};

export type CancelCandidateFormSessionData = {
  candidate_form_session_id: string;
  status_code: "CANCELLED";
};

export type StartCandidateFormSessionInput = {
  mode: "NEW_SUBMISSION" | "EDIT_SUBMISSION" | string;
  submissionId?: string | null;
};

export type CancelCandidateFormSessionInput = {
  sessionId: string;
};
export type RefreshCandidateFormPrivacyNoticeInput = {
  sessionId: string;
};

export type CandidatePrivacyNoticeData = {
  notice_version: string;
  content_vi: string;
  content_en: string | null;
};

export type RefreshCandidateFormPrivacyNoticeData = {
  candidate_form_session_id: string;
  mode_code: string;
  target_submission_id: string | null;
  base_submission_version_no: number | null;
  presented_privacy_notice_version: string;
  expires_at: string;
  privacy_notice: CandidatePrivacyNoticeData;
};

export type FormSessionCommandDeps = {
  client?: SupabaseClient;
  resolveActor?: () => Promise<VerifiedActor | null>;
};

async function defaultResolveActor(
  client?: SupabaseClient,
): Promise<VerifiedActor | null> {
  const supabase = client ?? (await createServerClient());
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user || !user.email) {
    return null;
  }

  const { data: candidate } = await supabase
    .from("candidates")
    .select("candidate_id, is_active")
    .eq("auth_user_id", user.id)
    .maybeSingle();

  if (!candidate || typeof candidate !== "object") {
    return null;
  }

  const isActive = Boolean(
    "is_active" in candidate && candidate.is_active === true,
  );

  return {
    authUserId: user.id,
    email: user.email,
    isActive,
    roles: ["CANDIDATE"],
    permissions: ["candidate.self"],
  };
}

type ValidatedStartInput = {
  mode: "NEW_SUBMISSION" | "EDIT_SUBMISSION";
  submissionId: string | null;
};

export function createStartCandidateFormSessionCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  StartCandidateFormSessionInput,
  string | undefined,
  ValidatedStartInput,
  CandidateFormSessionData
> {
  return {
    name: "start_candidate_form_session",
    extractTarget(input) {
      return input.submissionId ?? undefined;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");

      if (!isCandidate) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Candidate role required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input || typeof input !== "object") {
        return { success: false, error: "Invalid input payload" };
      }

      if (input.mode !== "NEW_SUBMISSION" && input.mode !== "EDIT_SUBMISSION") {
        return {
          success: false,
          error: "Invalid form session mode",
        };
      }

      if (input.mode === "NEW_SUBMISSION") {
        if (input.submissionId !== undefined && input.submissionId !== null) {
          return {
            success: false,
            error: "p_submission_id must be null for NEW_SUBMISSION",
          };
        }
        return {
          success: true,
          data: {
            mode: "NEW_SUBMISSION",
            submissionId: null,
          },
        };
      }

      if (!input.submissionId || typeof input.submissionId !== "string") {
        return {
          success: false,
          error: "p_submission_id is required for EDIT_SUBMISSION",
        };
      }

      if (!UUID_REGEX.test(input.submissionId.trim())) {
        return {
          success: false,
          error: "Invalid submission ID format",
        };
      }

      return {
        success: true,
        data: {
          mode: "EDIT_SUBMISSION",
          submissionId: input.submissionId.trim(),
        },
      };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "start_candidate_form_session",
        {
          p_mode: validated.mode,
          p_submission_id: validated.submissionId,
        },
      );

      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message || "Failed to start candidate form session",
          error,
        );
      }

      if (!data || typeof data !== "object") {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          "Invalid response from start form session RPC",
        );
      }

      if ("success" in data && data.success === false) {
        const rawCode = "error_code" in data ? String(data.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        const message =
          "message" in data && typeof data.message === "string"
            ? data.message
            : "Failed to start candidate form session";

        return {
          success: false,
          error: {
            code,
            message,
          },
        };
      }

      if ("data" in data && data.data && typeof data.data === "object") {
        return {
          success: true,
          data: data.data as CandidateFormSessionData,
        };
      }

      throw new CommandExecutionError(
        CommandErrorCode.INTERNAL_ERROR,
        "Malformed success payload from start form session RPC",
      );
    },
  };
}

type ValidatedCancelInput = {
  sessionId: string;
};

export function createCancelCandidateFormSessionCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  CancelCandidateFormSessionInput,
  string,
  ValidatedCancelInput,
  CancelCandidateFormSessionData
> {
  return {
    name: "cancel_candidate_form_session",
    extractTarget(input) {
      return input?.sessionId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");

      if (!isCandidate) {
        return {
          authorized: false,
          code: CommandErrorCode.FORBIDDEN,
          reason: "Candidate role required",
        };
      }

      return { authorized: true };
    },
    validate(input) {
      if (!input || typeof input !== "object") {
        return { success: false, error: "Invalid input payload" };
      }

      if (!input.sessionId || typeof input.sessionId !== "string") {
        return {
          success: false,
          error: "Session ID is required",
        };
      }

      if (!UUID_REGEX.test(input.sessionId.trim())) {
        return {
          success: false,
          error: "Invalid session ID format",
        };
      }

      return {
        success: true,
        data: {
          sessionId: input.sessionId.trim(),
        },
      };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "cancel_candidate_form_session",
        {
          p_session_id: validated.sessionId,
        },
      );

      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message || "Failed to cancel candidate form session",
          error,
        );
      }

      if (!data || typeof data !== "object") {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          "Invalid response from cancel form session RPC",
        );
      }

      if ("success" in data && data.success === false) {
        const rawCode = "error_code" in data ? String(data.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        const message =
          "message" in data && typeof data.message === "string"
            ? data.message
            : "Failed to cancel candidate form session";

        return {
          success: false,
          error: {
            code,
            message,
          },
        };
      }

      if ("data" in data && data.data && typeof data.data === "object") {
        return {
          success: true,
          data: data.data as CancelCandidateFormSessionData,
        };
      }

      throw new CommandExecutionError(
        CommandErrorCode.INTERNAL_ERROR,
        "Malformed success payload from cancel form session RPC",
      );
    },
  };
}

// -----------------------------------------------------------------------------
// 3. Refresh Candidate Form Privacy Notice Command
// -----------------------------------------------------------------------------

export function createRefreshCandidateFormPrivacyNoticeCommand(
  supabase: SupabaseClient,
): TrustedCommandDefinition<
  RefreshCandidateFormPrivacyNoticeInput,
  string,
  RefreshCandidateFormPrivacyNoticeInput,
  RefreshCandidateFormPrivacyNoticeData
> {
  return {
    name: "refresh_candidate_form_privacy_notice",
    extractTarget(input) {
      return input?.sessionId;
    },
    authorize(actor) {
      const isCandidate =
        actor.roles.includes("CANDIDATE") ||
        actor.permissions.includes("candidate.self");
      return isCandidate
        ? { authorized: true }
        : {
            authorized: false,
            code: CommandErrorCode.FORBIDDEN,
            reason: "Candidate role required",
          };
    },
    validate(input) {
      if (!input?.sessionId || !UUID_REGEX.test(input.sessionId.trim())) {
        return { success: false, error: "Invalid session ID format" };
      }
      return {
        success: true,
        data: { sessionId: input.sessionId.trim() },
      };
    },
    async execute(_actor, validated) {
      const { data, error } = await supabase.rpc(
        "refresh_candidate_form_privacy_notice",
        { p_session_id: validated.sessionId },
      );
      if (error) {
        throw new CommandExecutionError(
          CommandErrorCode.INTERNAL_ERROR,
          error.message || "Failed to refresh privacy notice",
          error,
        );
      }
      const result = data as {
        success: boolean;
        error_code?: string;
        message?: string;
        data?: RefreshCandidateFormPrivacyNoticeData;
      };
      if (!result.success || !result.data) {
        const rawCode = result.error_code ? String(result.error_code) : "";
        const code =
          CommandErrorCode[rawCode as keyof typeof CommandErrorCode] ??
          CommandErrorCode.INTERNAL_ERROR;
        return {
          success: false,
          error: {
            code,
            message: result.message || "Failed to refresh privacy notice",
          },
        };
      }
      return { success: true, data: result.data };
    },
  };
}

export async function startCandidateFormSession(
  input: StartCandidateFormSessionInput,
  deps?: FormSessionCommandDeps,
): Promise<CommandResult<CandidateFormSessionData>> {
  const supabase = deps?.client ?? (await createServerClient());
  const resolveActor =
    deps?.resolveActor ?? (() => defaultResolveActor(supabase));

  const runner = createCommandRunner({ resolveActor });
  const command = createStartCandidateFormSessionCommand(supabase);

  return runner(command, input);
}

export async function cancelCandidateFormSession(
  input: CancelCandidateFormSessionInput,
  deps?: FormSessionCommandDeps,
): Promise<CommandResult<CancelCandidateFormSessionData>> {
  const supabase = deps?.client ?? (await createServerClient());
  const resolveActor =
    deps?.resolveActor ?? (() => defaultResolveActor(supabase));

  const runner = createCommandRunner({ resolveActor });
  const command = createCancelCandidateFormSessionCommand(supabase);

  return runner(command, input);
}
export async function refreshCandidateFormPrivacyNotice(
  input: RefreshCandidateFormPrivacyNoticeInput,
  deps?: FormSessionCommandDeps,
): Promise<CommandResult<RefreshCandidateFormPrivacyNoticeData>> {
  const supabase = deps?.client ?? (await createServerClient());
  const resolveActor =
    deps?.resolveActor ?? (() => defaultResolveActor(supabase));

  const runner = createCommandRunner({ resolveActor });
  const command = createRefreshCandidateFormPrivacyNoticeCommand(supabase);

  return runner(command, input);
}
