/** Shared browser-safe types and Web Crypto primitives. No runtime credentials. */
export const DRIVE_MAX_BYTES = 5 * 1024 * 1024;
export type DriveTransport = {
  provider: "DRIVE";
  url: string;
  grant: string;
  expiresAt: string;
  method: "PUT" | "GET";
};
export type DriveGrant = {
  version: 1;
  actor: string;
  audience: string;
  origin: string;
  issuedAt: number;
  expiresAt: number;
} & (
  | {
      purpose: "upload";
      reservationId: string;
      sessionId: string;
      bucket: string;
      path: string;
      filename: string;
      mimeType: string;
      maxBytes: number;
    }
  | {
      purpose: "preview" | "download";
      submissionId: string;
      logicalDocumentId: string;
      documentId: string;
      filename: string;
      mimeType: string;
    }
);
export class DriveError extends Error {
  constructor(
    public readonly code: string,
    public readonly status = 503,
  ) {
    super(code);
  }
}
const encoder = new TextEncoder();
function encode(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}
function decode(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value))
    throw new DriveError("INVALID_GRANT", 403);
  return Uint8Array.from(
    atob(value.replaceAll("-", "+").replaceAll("_", "/")),
    (c) => c.charCodeAt(0),
  );
}
async function key(secret: string) {
  if (secret.length < 32) throw new DriveError("NOT_CONFIGURED");
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}
export async function signDriveGrant(
  grant: DriveGrant,
  secret: string,
): Promise<string> {
  const payload = encode(encoder.encode(JSON.stringify(grant)));
  return `${payload}.${encode(new Uint8Array(await crypto.subtle.sign("HMAC", await key(secret), encoder.encode(payload))))}`;
}
export async function verifyDriveGrant(
  token: string,
  secret: string,
  audience: string,
  origin: string,
  now = Date.now(),
): Promise<DriveGrant> {
  try {
    if (token.length > 8192) throw new Error();
    const parts = token.split(".");
    if (
      parts.length !== 2 ||
      !(await crypto.subtle.verify(
        "HMAC",
        await key(secret),
        Uint8Array.from(decode(parts[1])),
        encoder.encode(parts[0]),
      ))
    )
      throw new Error();
    const grant = JSON.parse(
      new TextDecoder().decode(decode(parts[0])),
    ) as DriveGrant;
    if (
      grant.version !== 1 ||
      grant.audience !== audience ||
      grant.origin !== origin ||
      !grant.actor ||
      !Number.isSafeInteger(grant.issuedAt) ||
      !Number.isSafeInteger(grant.expiresAt) ||
      grant.issuedAt > now ||
      grant.expiresAt <= now ||
      grant.expiresAt - grant.issuedAt > 60_000 ||
      !["upload", "preview", "download"].includes(grant.purpose)
    )
      throw new Error();
    return grant;
  } catch {
    throw new DriveError("INVALID_GRANT", 403);
  }
}
export async function sha256(bytes: Uint8Array): Promise<string> {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes)),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}
export async function readBounded(
  body: ReadableStream<Uint8Array> | null,
  limit = DRIVE_MAX_BYTES,
  timeoutMs = 15_000,
): Promise<Uint8Array> {
  if (
    !body ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > DRIVE_MAX_BYTES
  )
    throw new DriveError("INVALID_SIZE", 413);
  const reader = body.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      void reader.cancel().catch(() => {});
      reject(new DriveError("PROVIDER_TIMEOUT"));
    }, timeoutMs);
  });
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await Promise.race([reader.read(), timeout]);
      if (done) break;
      length += value.byteLength;
      if (length > limit) {
        await reader.cancel();
        throw new DriveError("INVALID_SIZE", 413);
      }
      chunks.push(value);
    }
  } finally {
    clearTimeout(timer);
    reader.releaseLock();
  }
  if (!length) throw new DriveError("INVALID_SIZE", 413);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}
