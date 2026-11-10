import { createBrowserClient } from "@/lib/supabase/client";
import { DRIVE_MAX_BYTES, type DriveTransport } from "./drive-protocol";

/**
 * Browser side of the private Drive byte gateway (spec 102). Bytes go straight
 * between the browser and the gateway; the grant and the caller's Supabase
 * token travel in headers only, never in a URL.
 */
export class DriveTransferError extends Error {
  constructor(public readonly code: string) {
    super(driveErrorMessage(code));
  }
}

export function driveErrorMessage(code: string): string {
  const messages: Record<string, string> = {
    UNAUTHENTICATED: "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.",
    INVALID_GRANT: "Phiên truyền tệp đã hết hạn. Vui lòng thử lại.",
    INVALID_CONTENT_SIGNATURE:
      "Nội dung tệp không khớp với định dạng đã chọn / File content does not match its type.",
    INVALID_SIZE: "Tệp rỗng hoặc vượt quá giới hạn 5 MB.",
    DRIVE_FLAGGED_ABUSIVE:
      "Tệp bị từ chối vì lý do bảo mật / File rejected by the security check.",
    DOCUMENT_CHANGED: "Tài liệu đã thay đổi. Vui lòng tải lại trang.",
    FORBIDDEN: "Bạn không có quyền truy cập tài liệu này.",
  };
  return (
    messages[code] ??
    "Không thể truyền tệp lúc này. Vui lòng thử lại / File transfer failed."
  );
}

type DriveClientDeps = {
  fetchFn?: typeof fetch;
  accessToken?: () => Promise<string | null>;
};

async function browserAccessToken(): Promise<string | null> {
  const { data } = await createBrowserClient().auth.getSession();
  return data.session?.access_token ?? null;
}

async function transfer(
  transport: DriveTransport,
  body: Blob | undefined,
  deps: DriveClientDeps,
): Promise<Response> {
  const token = await (deps.accessToken ?? browserAccessToken)();
  if (!token) throw new DriveTransferError("UNAUTHENTICATED");
  let response: Response;
  try {
    response = await (deps.fetchFn ?? fetch)(transport.url, {
      method: transport.method,
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
      headers: {
        Authorization: `Bearer ${token}`,
        "X-Document-Grant": transport.grant,
        ...(body
          ? { "Content-Type": body.type || "application/octet-stream" }
          : {}),
      },
      body,
    });
  } catch {
    throw new DriveTransferError("GATEWAY_UNAVAILABLE");
  }
  if (!response.ok) {
    const payload = (await response.json().catch(() => null)) as {
      error?: unknown;
    } | null;
    throw new DriveTransferError(
      typeof payload?.error === "string"
        ? payload.error
        : "GATEWAY_UNAVAILABLE",
    );
  }
  return response;
}

export async function driveUpload(
  transport: DriveTransport,
  file: Blob,
  deps: DriveClientDeps = {},
): Promise<void> {
  await transfer(transport, file, deps);
}

/** Caller owns the returned bytes: wrap in an object URL and revoke it. */
export async function driveDownload(
  transport: DriveTransport,
  deps: DriveClientDeps = {},
): Promise<Blob> {
  const blob = await (await transfer(transport, undefined, deps)).blob();
  if (blob.size < 1 || blob.size > DRIVE_MAX_BYTES)
    throw new DriveTransferError("INVALID_SIZE");
  return blob;
}
