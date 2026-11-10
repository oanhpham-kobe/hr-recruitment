import {
  createEmailDeliveryDbPort,
  runEmailDeliveryBatch,
} from "@/lib/email/delivery-runner";
import { createGmailProvider } from "@/lib/email/gmail";
import { getPublicSupabaseEnv } from "@/lib/env/client";
import { isAuthorizedCron } from "@/lib/security/cron";
import { createStorageCleanupWorkerClient } from "@/lib/storage/cleanup-worker-client";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

/** Delivers queued outbox email through Gmail as the narrow `email_worker`. */
export async function POST(request: Request) {
  if (!isAuthorizedCron(request)) return new Response(null, { status: 401 });

  const workerAccessToken = process.env.EMAIL_WORKER_TOKEN?.trim();
  const clientId = process.env.GOOGLE_CLIENT_ID?.trim();
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET?.trim();
  const refreshToken = process.env.GMAIL_REFRESH_TOKEN?.trim();
  if (!workerAccessToken || !clientId || !clientSecret || !refreshToken)
    return Response.json({ error: "NOT_CONFIGURED" }, { status: 503 });

  const { url, publishableKey } = getPublicSupabaseEnv();
  // The helper is a generic bearer-token PostgREST client despite its name.
  const workerClient = createStorageCleanupWorkerClient({
    supabaseUrl: url,
    apiKey: publishableKey,
    workerAccessToken,
  });
  return Response.json(
    await runEmailDeliveryBatch({
      workerId: `web:${crypto.randomUUID()}`,
      db: createEmailDeliveryDbPort(workerClient),
      provider: createGmailProvider({ clientId, clientSecret, refreshToken }),
    }),
  );
}
