export type PublicSupabaseEnv = {
  url: string;
  publishableKey: string;
};

function requirePublicSupabaseUrl(): string {
  const value = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();

  if (!value) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL must be configured");
  }

  return value;
}

export function getPublicSupabaseEnv(): PublicSupabaseEnv {
  const publishableKey =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim() ||
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim();

  if (!publishableKey) {
    throw new Error(
      "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY or NEXT_PUBLIC_SUPABASE_ANON_KEY must be configured",
    );
  }

  return {
    url: requirePublicSupabaseUrl(),
    publishableKey,
  };
}
