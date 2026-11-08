import {
  DriveError,
  readBounded,
  sha256,
} from "../../../web/src/lib/storage/drive-protocol";

export interface Env {
  APP_ORIGIN: string;
  GATEWAY_ORIGIN: string;
  DRIVE_ENABLED: string;
  DRIVE_SCHEDULES_VERIFIED?: string;
  DRIVE_GRANT_SECRET: string;
  SUPABASE_URL: string;
  SUPABASE_API_KEY: string;
  DRIVE_WORKER_TOKEN: string;
  SCAN_WORKER_TOKEN: string;
  CLEANUP_WORKER_TOKEN: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  GOOGLE_REFRESH_TOKEN: string;
  GOOGLE_PRIVATE_FOLDER_ID: string;
  SCANNER_URL: string;
  SCANNER_TOKEN: string;
}
export type Location = {
  provider_file_id: string;
  state_code?: string;
  checksum_sha256: string;
  actual_size_bytes: number;
  detected_mime_type?: string;
  mime_type?: string;
  original_filename?: string;
};
export type Fetcher = typeof fetch;
export function configured(env: Env): void {
  if (
    env.DRIVE_ENABLED !== "true" ||
    Object.values({
      app: env.APP_ORIGIN,
      gateway: env.GATEWAY_ORIGIN,
      supabase: env.SUPABASE_URL,
      api: env.SUPABASE_API_KEY,
      drive: env.DRIVE_WORKER_TOKEN,
      scan: env.SCAN_WORKER_TOKEN,
      cleanup: env.CLEANUP_WORKER_TOKEN,
      client: env.GOOGLE_CLIENT_ID,
      secret: env.GOOGLE_CLIENT_SECRET,
      refresh: env.GOOGLE_REFRESH_TOKEN,
      folder: env.GOOGLE_PRIVATE_FOLDER_ID,
      scanner: env.SCANNER_URL,
      scannerToken: env.SCANNER_TOKEN,
    }).some((value) => !value) ||
    !env.DRIVE_GRANT_SECRET ||
    env.DRIVE_GRANT_SECRET.length < 32
  )
    throw new DriveError("NOT_CONFIGURED");
  for (const url of [
    env.APP_ORIGIN,
    env.GATEWAY_ORIGIN,
    env.SUPABASE_URL,
    env.SCANNER_URL,
  ]) {
    if (new URL(url).protocol !== "https:")
      throw new DriveError("NOT_CONFIGURED");
  }
}
/** Timeout covers response consumption, not merely receipt of headers. */
export async function boundedFetch<T>(
  fetcher: Fetcher,
  url: string,
  init: RequestInit,
  consume: (response: Response) => Promise<T>,
  timeout = 15_000,
): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new DriveError("PROVIDER_TIMEOUT"));
    }, timeout);
  });
  try {
    return await Promise.race([
      fetcher(url, {
        ...init,
        redirect: "error",
        signal: controller.signal,
      }).then(consume),
      deadline,
    ]);
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}
export async function rpc<T>(
  env: Env,
  token: string,
  name: string,
  args: Record<string, unknown>,
  fetcher: Fetcher = fetch,
): Promise<T> {
  return boundedFetch(
    fetcher,
    `${env.SUPABASE_URL}/rest/v1/rpc/${name}`,
    {
      method: "POST",
      headers: {
        apikey: env.SUPABASE_API_KEY,
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args),
    },
    async (response) => {
      const data = await response.json();
      if (!response.ok) {
        const code =
          typeof data.message === "string" && /^[A-Z_]+$/.test(data.message)
            ? data.message
            : "RPC_DENIED";
        throw new DriveError(code, 403);
      }
      if (data?.success === false)
        throw new DriveError(data.error_code ?? "RPC_DENIED", 403);
      return (data?.success === true ? data.data : data) as T;
    },
  );
}
export async function authenticate(
  request: Request,
  env: Env,
  fetcher: Fetcher,
): Promise<string> {
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ") || authorization.length > 8192)
    throw new DriveError("UNAUTHENTICATED", 401);
  return boundedFetch(
    fetcher,
    `${env.SUPABASE_URL}/auth/v1/user`,
    { headers: { apikey: env.SUPABASE_API_KEY, Authorization: authorization } },
    async (response) => {
      if (!response.ok) throw new DriveError("UNAUTHENTICATED", 401);
      const user = (await response.json()) as { id?: string };
      if (!user.id) throw new DriveError("UNAUTHENTICATED", 401);
      return user.id;
    },
  );
}
export async function googleToken(env: Env, fetcher: Fetcher): Promise<string> {
  return boundedFetch(
    fetcher,
    "https://oauth2.googleapis.com/token",
    {
      method: "POST",
      body: new URLSearchParams({
        grant_type: "refresh_token",
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        refresh_token: env.GOOGLE_REFRESH_TOKEN,
      }),
    },
    async (response) => {
      if (!response.ok) throw new DriveError("OAUTH_UNAVAILABLE");
      const result = (await response.json()) as { access_token?: string };
      if (!result.access_token) throw new DriveError("OAUTH_UNAVAILABLE");
      return result.access_token;
    },
  );
}
export class GoogleDrive {
  constructor(
    private env: Env,
    private token: string,
    private fetcher: Fetcher,
  ) {}
  private headers() {
    return { Authorization: `Bearer ${this.token}` };
  }
  async generateId(): Promise<string> {
    return boundedFetch(
      this.fetcher,
      "https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive&type=files",
      { headers: this.headers() },
      async (response) => {
        if (!response.ok) throw new DriveError("DRIVE_UNAVAILABLE");
        const result = (await response.json()) as { ids?: string[] };
        const id = result.ids?.[0];
        if (!id || !/^[A-Za-z0-9_-]{10,200}$/.test(id))
          throw new DriveError("DRIVE_UNAVAILABLE");
        return id;
      },
    );
  }
  async read(id: string): Promise<Uint8Array> {
    return boundedFetch(
      this.fetcher,
      `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(id)}?alt=media`,
      { headers: this.headers() },
      async (response) => {
        if (!response.ok)
          throw new DriveError(
            response.status === 404
              ? "DRIVE_NOT_FOUND_UNPROVEN"
              : "DRIVE_UNAVAILABLE",
          );
        return readBounded(response.body);
      },
    );
  }
  async verified(location: Location): Promise<Uint8Array> {
    const bytes = await this.read(location.provider_file_id);
    if (
      bytes.byteLength !== Number(location.actual_size_bytes) ||
      (await sha256(bytes)) !== location.checksum_sha256
    )
      throw new DriveError("FINGERPRINT_MISMATCH", 409);
    return bytes;
  }
  async create(
    id: string,
    bytes: Uint8Array,
    mime: string,
    deadline: number,
  ): Promise<void> {
    const timeout = Math.min(15_000, deadline - Date.now() - 1000);
    if (timeout <= 0) throw new DriveError("WRITE_DEADLINE", 409);
    const boundary = `eiu_${crypto.randomUUID()}`;
    const metadata = {
      id,
      name: id,
      parents: [this.env.GOOGLE_PRIVATE_FOLDER_ID],
      mimeType: mime,
    };
    const body = new Blob([
      `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n--${boundary}\r\nContent-Type: ${mime}\r\n\r\n`,
      Uint8Array.from(bytes),
      `\r\n--${boundary}--`,
    ]);
    await boundedFetch(
      this.fetcher,
      "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id",
      {
        method: "POST",
        headers: {
          ...this.headers(),
          "Content-Type": `multipart/related; boundary=${boundary}`,
        },
        body,
      },
      async (response) => {
        if (!response.ok) throw new DriveError("DRIVE_CREATE_UNCONFIRMED");
        const result = (await response.json()) as { id?: string };
        if (result.id !== id) throw new DriveError("DRIVE_CREATE_UNCONFIRMED");
      },
      timeout,
    );
  }
  async remove(id: string): Promise<void> {
    // An authenticated successful DELETE is proof. A generic 404 is deliberately
    // left retryable: Drive hides permissions behind the same response.
    await boundedFetch(
      this.fetcher,
      `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(id)}`,
      { method: "DELETE", headers: this.headers() },
      async (response) => {
        if (response.status !== 204) throw new DriveError("DELETE_UNCONFIRMED");
      },
    );
  }
}
