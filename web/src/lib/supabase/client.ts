import { createBrowserClient as createSupabaseBrowserClient } from "@supabase/ssr";

import { getPublicSupabaseEnv } from "@/lib/env/client";

export function createBrowserClient() {
  const { url, publishableKey } = getPublicSupabaseEnv();

  return createSupabaseBrowserClient(url, publishableKey);
}
