import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

/** The exact snapshot `authorize_email_send` releases for one attempt. */
export type AuthorizedEmail = {
  email_outbox_id: string;
  attempt_id: string;
  environment_code: "TEST" | "PRODUCTION";
  recipients: { to: string[]; cc?: string[] };
  subject: string;
  body_text: string;
  template_version: string;
};

/** The only failure codes `complete_email_attempt` accepts. */
export type EmailFailureCode =
  | "PROVIDER_TEMPORARY"
  | "PROVIDER_REJECTED"
  | "RATE_LIMITED"
  | "NETWORK_ERROR";

export class EmailProviderError extends Error {
  constructor(
    public readonly code: EmailFailureCode,
    public readonly retryable: boolean,
  ) {
    super(code);
  }
}

export interface EmailProvider {
  send(email: AuthorizedEmail): Promise<{ messageId: string }>;
}

type EmailAttempt = {
  emailOutboxId: string;
  attemptId: string;
  workerId: string;
};

export interface EmailDeliveryDbPort {
  claim(
    workerId: string,
    limit: number,
  ): Promise<Array<{ email_outbox_id: string; attempt_id: string }>>;
  authorize(
    attempt: EmailAttempt,
  ): Promise<
    | { success: true; data: AuthorizedEmail }
    | { success: false; error_code?: string }
  >;
  complete(
    input: EmailAttempt & {
      outcome: "SENT" | "RETRYABLE_FAILURE" | "PERMANENT_FAILURE";
      providerMessageId: string | null;
      errorCode: EmailFailureCode | null;
    },
  ): Promise<void>;
}

export function createEmailDeliveryDbPort(
  workerClient: SupabaseClient,
): EmailDeliveryDbPort {
  return {
    async claim(workerId, limit) {
      const { data, error } = await workerClient.rpc("claim_email_outbox", {
        p_worker_id: workerId,
        p_limit: limit,
      });
      if (error || !data?.success) throw new Error("claim_email_outbox failed");
      return data.data;
    },
    async authorize(attempt) {
      const { data, error } = await workerClient.rpc("authorize_email_send", {
        p_email_outbox_id: attempt.emailOutboxId,
        p_attempt_id: attempt.attemptId,
        p_worker_id: attempt.workerId,
      });
      return error || !data ? { success: false } : data;
    },
    async complete(input) {
      const { data, error } = await workerClient.rpc("complete_email_attempt", {
        p_email_outbox_id: input.emailOutboxId,
        p_attempt_id: input.attemptId,
        p_worker_id: input.workerId,
        p_outcome: input.outcome,
        p_provider_message_id: input.providerMessageId,
        p_error_code: input.errorCode,
      });
      if (error || !data?.success)
        throw new Error("complete_email_attempt failed");
    },
  };
}

/**
 * Delivers one claimed batch. Recipients, subject and body come only from the
 * database authorization of that exact attempt; nothing is sent without it.
 * Delivery is at-least-once (spec 43): a completion lost after the provider
 * accepted the message is retried by the database when the lease expires.
 */
export async function runEmailDeliveryBatch(input: {
  workerId: string;
  db: EmailDeliveryDbPort;
  provider: EmailProvider;
  limit?: number;
}): Promise<{
  claimed: number;
  sent: number;
  failed: number;
  withheld: number;
}> {
  const claimed = await input.db.claim(input.workerId, input.limit ?? 10);
  const result = { claimed: claimed.length, sent: 0, failed: 0, withheld: 0 };

  for (const item of claimed) {
    const attempt = {
      emailOutboxId: item.email_outbox_id,
      attemptId: item.attempt_id,
      workerId: input.workerId,
    };
    const authorized = await input.db
      .authorize(attempt)
      .catch(() => ({ success: false as const }));
    if (!authorized.success) {
      result.withheld++;
      continue;
    }

    try {
      const { messageId } = await input.provider.send(authorized.data);
      result.sent++;
      await input.db
        .complete({
          ...attempt,
          outcome: "SENT",
          providerMessageId: messageId,
          errorCode: null,
        })
        .catch(() => {});
    } catch (error) {
      const known = error instanceof EmailProviderError;
      result.failed++;
      await input.db
        .complete({
          ...attempt,
          outcome:
            known && !error.retryable
              ? "PERMANENT_FAILURE"
              : "RETRYABLE_FAILURE",
          providerMessageId: null,
          errorCode: known ? error.code : "NETWORK_ERROR",
        })
        .catch(() => {});
    }
  }
  return result;
}
