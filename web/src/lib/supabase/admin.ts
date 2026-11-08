import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getPublicSupabaseEnv } from "@/lib/env/client";
import { getServerSupabaseEnv } from "@/lib/env/server";

export function createAdminClient(): SupabaseClient | null {
  const { serviceRoleKey } = getServerSupabaseEnv();
  if (!serviceRoleKey) {
    return null;
  }
  const { url } = getPublicSupabaseEnv();
  return createClient(url, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}
