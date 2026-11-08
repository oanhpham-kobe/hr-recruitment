import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { CommandErrorCode, type CommandResult } from "@/lib/commands/types";
import { logError } from "@/lib/logging/logger";
import { createServerClient } from "@/lib/supabase/server";

export type CandidateIdentity = {
  candidate_id: string;
  auth_user_id: string;
  email: string;
  current_full_name: string | null;
  current_phone: string | null;
  is_active: boolean;
};

type ProvisionRpcSuccess = {
  success: true;
  data: CandidateIdentity;
};

type ProvisionRpcFailure = {
  success: false;
  error_code: string;
  message: string;
};

type ProvisionRpcResponse = ProvisionRpcSuccess | ProvisionRpcFailure;

export async function provisionCandidateIdentity(
  client?: SupabaseClient,
): Promise<CommandResult<CandidateIdentity>> {
  try {
    const supabase = client ?? (await createServerClient());
    const { data, error } = await supabase.rpc("provision_candidate_identity");

    if (error) {
      logError(error);
      return {
        success: false,
        error: {
          code: CommandErrorCode.INTERNAL_ERROR,
          message:
            error.message || "Failed to execute candidate provisioning RPC",
          details: error,
        },
      };
    }

    if (!data || typeof data !== "object") {
      logError(
        new Error("Invalid response format from candidate provisioning RPC"),
      );
      return {
        success: false,
        error: {
          code: CommandErrorCode.INTERNAL_ERROR,
          message: "Invalid response from provisioning service",
        },
      };
    }

    const payload = data as ProvisionRpcResponse;

    if (!payload.success) {
      const code =
        CommandErrorCode[payload.error_code as keyof typeof CommandErrorCode] ??
        CommandErrorCode.INTERNAL_ERROR;

      return {
        success: false,
        error: {
          code,
          message: payload.message,
        },
      };
    }

    return {
      success: true,
      data: payload.data,
    };
  } catch (error) {
    logError(error);

    return {
      success: false,
      error: {
        code: CommandErrorCode.INTERNAL_ERROR,
        message: "Internal provisioning error",
      },
    };
  }
}
