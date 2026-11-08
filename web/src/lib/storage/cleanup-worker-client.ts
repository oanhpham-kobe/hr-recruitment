import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export type StorageCleanupWorkerClientConfig = {
  supabaseUrl: string;
  apiKey: string;
  workerAccessToken: string;
};

/**
 * Creates a server-only PostgREST client whose JWT role claim is expected to be
 * exactly `storage_cleanup_worker`.
 *
 * Token minting/provisioning is intentionally outside this helper. S07-004 does
 * not provision production credentials; disposable local integration may mint a
 * short-lived token with the local Supabase signing configuration.
 */
export function createStorageCleanupWorkerClient(
  config: StorageCleanupWorkerClientConfig,
): SupabaseClient {
  const supabaseUrl = config.supabaseUrl.trim();
  const apiKey = config.apiKey.trim();
  const workerAccessToken = config.workerAccessToken.trim();

  if (!supabaseUrl || !apiKey || !workerAccessToken) {
    throw new Error(
      "Storage cleanup worker client requires URL, API key, and worker access token",
    );
  }

  return createClient(supabaseUrl, apiKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      headers: {
        Authorization: `Bearer ${workerAccessToken}`,
      },
    },
  });
}
