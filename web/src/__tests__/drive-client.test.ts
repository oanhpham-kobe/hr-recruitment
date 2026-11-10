import assert from "node:assert/strict";
import { test } from "node:test";
import { expectedMimeForFilename } from "@/lib/storage/buckets";
import {
  DriveTransferError,
  driveDownload,
  driveUpload,
} from "@/lib/storage/drive-client";
import {
  DRIVE_MAX_BYTES,
  type DriveTransport,
} from "@/lib/storage/drive-protocol";

const upload: DriveTransport = {
  provider: "DRIVE",
  url: "https://gateway.example/bytes",
  grant: "payload.signature",
  expiresAt: new Date(Date.now() + 60_000).toISOString(),
  method: "PUT",
};
const read: DriveTransport = { ...upload, method: "GET" };
const accessToken = async () => "user-jwt";

test("expectedMimeForFilename follows the extension, case-insensitively", () => {
  assert.equal(
    expectedMimeForFilename("CV.DOCX"),
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  );
  assert.equal(expectedMimeForFilename("scan.jpeg"), "image/jpeg");
  assert.equal(expectedMimeForFilename("archive.zip"), null);
  assert.equal(expectedMimeForFilename("no-extension"), null);
});

test("upload sends bytes with grant and user token in headers only", async () => {
  const seen: Array<{ url: string; init: RequestInit }> = [];
  const file = new Blob(["%PDF-bytes"], { type: "application/pdf" });
  await driveUpload(upload, file, {
    accessToken,
    fetchFn: async (input, init) => {
      seen.push({ url: String(input), init: init ?? {} });
      return Response.json({ status: "SEALED" });
    },
  });
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, "https://gateway.example/bytes");
  assert.equal(seen[0].init.method, "PUT");
  assert.equal(seen[0].init.body, file);
  assert.equal(seen[0].init.credentials, "omit");
  const headers = new Headers(seen[0].init.headers);
  assert.equal(headers.get("Authorization"), "Bearer user-jwt");
  assert.equal(headers.get("X-Document-Grant"), "payload.signature");
});

test("transfer without a browser session fails before any request", async () => {
  let calls = 0;
  await assert.rejects(
    driveDownload(read, {
      accessToken: async () => null,
      fetchFn: async () => {
        calls++;
        return new Response("x");
      },
    }),
    (error) =>
      error instanceof DriveTransferError && error.code === "UNAUTHENTICATED",
  );
  assert.equal(calls, 0);
});

test("gateway error codes surface as DriveTransferError", async () => {
  await assert.rejects(
    driveUpload(upload, new Blob(["x"]), {
      accessToken,
      fetchFn: async () =>
        Response.json({ error: "INVALID_CONTENT_SIGNATURE" }, { status: 415 }),
    }),
    (error) =>
      error instanceof DriveTransferError &&
      error.code === "INVALID_CONTENT_SIGNATURE",
  );
  await assert.rejects(
    driveDownload(read, {
      accessToken,
      fetchFn: async () => {
        throw new TypeError("network down");
      },
    }),
    (error) =>
      error instanceof DriveTransferError &&
      error.code === "GATEWAY_UNAVAILABLE",
  );
});

test("download returns a typed blob and refuses more than 5 MB", async () => {
  const blob = await driveDownload(read, {
    accessToken,
    fetchFn: async () =>
      new Response("%PDF-bytes", {
        headers: { "Content-Type": "application/pdf" },
      }),
  });
  assert.equal(blob.type, "application/pdf");
  assert.equal(await blob.text(), "%PDF-bytes");
  await assert.rejects(
    driveDownload(read, {
      accessToken,
      fetchFn: async () => new Response(new Uint8Array(DRIVE_MAX_BYTES + 1)),
    }),
    (error) =>
      error instanceof DriveTransferError && error.code === "INVALID_SIZE",
  );
});
