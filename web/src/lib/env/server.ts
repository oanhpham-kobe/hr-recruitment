import "server-only";

export type ServerSupabaseEnv = {
  serviceRoleKey?: string;
};

export function getServerSupabaseEnv(): ServerSupabaseEnv {
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();

  if (process.env.SUPABASE_SERVICE_ROLE_KEY && !serviceRoleKey) {
    throw new Error(
      "SUPABASE_SERVICE_ROLE_KEY must not be empty when configured",
    );
  }

  return { serviceRoleKey };
}
