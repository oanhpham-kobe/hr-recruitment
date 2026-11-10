import "server-only";

import { createHash, timingSafeEqual } from "node:crypto";

/**
 * Authorizes a scheduled caller (the Cloudflare cron) of /api/cron/* by the
 * shared CRON_SECRET. Fails closed when the secret is unset or too short.
 */
export function isAuthorizedCron(request: Request): boolean {
  const secret = process.env.CRON_SECRET ?? "";
  if (secret.length < 32) return false;
  // Hashing gives equal-length inputs, so the comparison leaks no length.
  const digest = (value: string) => createHash("sha256").update(value).digest();
  return timingSafeEqual(
    digest(request.headers.get("Authorization") ?? ""),
    digest(`Bearer ${secret}`),
  );
}
