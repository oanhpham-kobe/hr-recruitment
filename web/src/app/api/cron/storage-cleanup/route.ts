import type { SupabaseClient } from "@supabase/supabase-js";
import { discoverExpiredStorageCleanup } from "@/lib/commands/storage-reservation";
import { getPublicSupabaseEnv } from "@/lib/env/client";
import { isAuthorizedCron } from "@/lib/security/cron";
import {
  createStorageCleanupDbPort,
  runStorageCleanupBatch,
} from "@/lib/storage/cleanup-runner";
import { createStorageCleanupWorkerClient } from "@/lib/storage/cleanup-worker-client";
import {
  createSupabaseStorageCleanupProvider,
  type StorageCleanupProvider,
} from "@/lib/storage/storage-provider";
import { createAdminClient } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";

/**
 * Drains cleanup jobs for objects in Supabase Storage (legacy, unbound
 * identities). Drive-bound jobs are claimed by the gateway worker instead.
 */
export async function POST(
  request: Request,
  _context?: unknown,
  deps: {
    workerClient?: SupabaseClient;
    provider?: StorageCleanupProvider;
  } = {},
) {
  if (!isAuthorizedCron(request)) return new Response(null, { status: 401 });

  let workerClient = deps.workerClient;
  let provider = deps.provider;
  if (!workerClient || !provider) {
    const workerAccessToken = process.env.STORAGE_CLEANUP_WORKER_TOKEN?.trim();
    const admin = createAdminClient();
    if (!workerAccessToken || !admin)
      return Response.json({ error: "NOT_CONFIGURED" }, { status: 503 });
    const { url, publishableKey } = getPublicSupabaseEnv();
    workerClient = createStorageCleanupWorkerClient({
      supabaseUrl: url,
      apiKey: publishableKey,
      workerAccessToken,
    });
    provider = createSupabaseStorageCleanupProvider(admin);
  }

  await discoverExpiredStorageCleanup(50, workerClient);
  const result = await runStorageCleanupBatch({
    workerId: `web:${crypto.randomUUID()}`,
    db: createStorageCleanupDbPort(workerClient),
    provider,
  });
  return Response.json({
    claimed: result.claimedCount,
    done: result.jobs.filter((job) => job.result === "DONE").length,
  });
}
