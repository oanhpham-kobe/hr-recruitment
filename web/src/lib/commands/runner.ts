import "server-only";

import { logError } from "@/lib/logging/logger";

import {
  CommandErrorCode,
  type CommandResult,
  type TrustedCommandDefinition,
  type VerifiedActor,
} from "./types";

export function createCommandRunner(deps: {
  resolveActor: () => Promise<VerifiedActor | null>;
}) {
  return async function executeCommand<
    TRawInput,
    TTarget,
    TValidatedInput,
    TOutput,
  >(
    command: TrustedCommandDefinition<
      TRawInput,
      TTarget,
      TValidatedInput,
      TOutput
    >,
    rawInput: TRawInput,
  ): Promise<CommandResult<TOutput>> {
    try {
      const actor = await deps.resolveActor();

      if (!actor) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.UNAUTHENTICATED,
            message: "Authentication required",
          },
        };
      }

      if (!actor.isActive) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.USER_INACTIVE,
            message: "User account is inactive",
          },
        };
      }

      const target = command.extractTarget?.(rawInput);
      const authorization = await command.authorize(actor, target);

      if (!authorization.authorized) {
        return {
          success: false,
          error: {
            code: authorization.code ?? CommandErrorCode.FORBIDDEN,
            message: authorization.reason ?? "Insufficient permissions",
          },
        };
      }

      const validation = command.validate(rawInput);

      if (!validation.success) {
        return {
          success: false,
          error: {
            code: CommandErrorCode.VALIDATION_ERROR,
            message: validation.error,
            details: validation.details,
          },
        };
      }

      const executionResult = await command.execute(actor, validation.data);

      if (
        executionResult !== null &&
        typeof executionResult === "object" &&
        "success" in executionResult &&
        typeof executionResult.success === "boolean"
      ) {
        return executionResult as CommandResult<TOutput>;
      }

      return {
        success: true,
        data: executionResult as TOutput,
      };
    } catch (error) {
      if (
        error !== null &&
        typeof error === "object" &&
        "code" in error &&
        typeof error.code === "string" &&
        error.code in CommandErrorCode
      ) {
        const message =
          "message" in error && typeof error.message === "string"
            ? error.message
            : "Command execution failed";
        const details = "details" in error ? error.details : undefined;
        return {
          success: false,
          error: {
            code: error.code as CommandErrorCode,
            message,
            details,
          },
        };
      }

      logError(error);

      return {
        success: false,
        error: {
          code: CommandErrorCode.INTERNAL_ERROR,
          message: "Internal command error",
        },
      };
    }
  };
}
