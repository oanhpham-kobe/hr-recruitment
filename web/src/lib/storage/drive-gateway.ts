import "server-only";
import {
  DriveError,
  type DriveGrant,
  type DriveTransport,
  signDriveGrant,
} from "./drive-protocol";

export type DriveServerConfig = {
  origin: string;
  appOrigin: string;
  secret: string;
  supabaseUrl: string;
  apiKey: string;
  workerToken: string;
};
export function driveServerConfig(): DriveServerConfig | null {
  if (process.env.DOCUMENT_STORAGE_PROVIDER !== "DRIVE") return null;
  const config = {
    origin: process.env.DRIVE_GATEWAY_ORIGIN ?? "",
    appOrigin: process.env.APP_ORIGIN ?? "",
    secret: process.env.DRIVE_GRANT_SECRET ?? "",
    supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL ?? "",
    apiKey: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "",
    workerToken: process.env.DRIVE_WORKER_TOKEN ?? "",
  };
  // This explicit release gate is set only after OAuth, scanner, schedules and
  // deployed gateway verification. Plugin credentials are not runtime config.
  if (
    process.env.DRIVE_RUNTIME_VERIFIED !== "true" ||
    Object.values(config).some((value) => !value) ||
    config.secret.length < 32
  )
    throw new DriveError("DRIVE_NOT_CONFIGURED");
  for (const origin of [config.origin, config.appOrigin, config.supabaseUrl]) {
    const url = new URL(origin);
    if (url.protocol !== "https:" || url.origin !== origin)
      throw new DriveError("DRIVE_NOT_CONFIGURED");
  }
  return config;
}
export async function driveServerRpc<T>(
  name: string,
  args: Record<string, unknown>,
  config = driveServerConfig(),
): Promise<T> {
  if (!config) throw new DriveError("DRIVE_NOT_CONFIGURED");
  const response = await fetch(`${config.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    cache: "no-store",
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
    headers: {
      apikey: config.apiKey,
      Authorization: `Bearer ${config.workerToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!response.ok) throw new DriveError("DRIVE_AUTHORIZATION_DENIED", 403);
  return (await response.json()) as T;
}
export async function driveLocation(
  bucket: string,
  path: string,
): Promise<{ state_code: string } | null> {
  return driveServerRpc("resolve_drive_object_location", {
    p_bucket_name: bucket,
    p_object_path: path,
  });
}
type GrantInput = DriveGrant extends infer G
  ? G extends DriveGrant
    ? Omit<G, "version" | "audience" | "origin" | "issuedAt" | "expiresAt">
    : never
  : never;
export async function createDriveTransport(
  input: GrantInput,
  config = driveServerConfig(),
): Promise<DriveTransport> {
  if (!config) throw new DriveError("DRIVE_NOT_CONFIGURED");
  const now = Date.now();
  const grant = {
    ...input,
    version: 1,
    audience: config.origin,
    origin: config.appOrigin,
    issuedAt: now,
    expiresAt: now + 60_000,
  } as DriveGrant;
  return {
    provider: "DRIVE",
    url: `${config.origin}/bytes`,
    grant: await signDriveGrant(grant, config.secret),
    expiresAt: new Date(grant.expiresAt).toISOString(),
    method: grant.purpose === "upload" ? "PUT" : "GET",
  };
}
