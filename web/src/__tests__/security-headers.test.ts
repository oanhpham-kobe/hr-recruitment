import assert from "node:assert/strict";
import test from "node:test";

import { NextRequest } from "next/server";

import { middleware, refreshSupabaseSession } from "@/middleware";

test("middleware creates distinct nonces and complete dynamic security headers", async () => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = "https://project.supabase.co/rest/v1";
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "test-publishable-key";

  const firstResponse = await middleware(
    new NextRequest("https://app.example.test/"),
  );
  const secondResponse = await middleware(
    new NextRequest("https://app.example.test/"),
  );
  const firstNonce = firstResponse.headers.get("x-nonce");
  const secondNonce = secondResponse.headers.get("x-nonce");
  const firstCsp = firstResponse.headers.get("Content-Security-Policy");
  const secondCsp = secondResponse.headers.get("Content-Security-Policy");

  assert.ok(firstNonce);
  assert.ok(secondNonce);
  assert.notEqual(firstNonce, secondNonce);
  assert.match(firstCsp ?? "", new RegExp(`'nonce-${firstNonce}'`));
  assert.match(secondCsp ?? "", new RegExp(`'nonce-${secondNonce}'`));
  assert.match(
    firstCsp ?? "",
    /connect-src 'self' https:\/\/project\.supabase\.co/,
  );
  assert.equal(firstResponse.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(
    firstResponse.headers.get("Referrer-Policy"),
    "strict-origin-when-cross-origin",
  );
  assert.equal(
    firstResponse.headers.get("Permissions-Policy"),
    "camera=(), microphone=(), geolocation=()",
  );
  assert.equal(firstResponse.headers.get("X-Frame-Options"), "DENY");
});

test("session refresh forwards replacement cookies and no-cache headers", async () => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = "https://project.supabase.co";
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "test-publishable-key";
  Object.assign(process.env, { NODE_ENV: "production" });

  const request = new NextRequest("https://app.example.test/protected", {
    headers: { cookie: "preserve=original" },
  });
  let receivedExistingCookie = false;
  let getUserCalled = false;

  const response = await refreshSupabaseSession(
    request,
    new Headers(request.headers),
    (_url, _publishableKey, { cookieOptions, cookies }) => ({
      auth: {
        async getUser() {
          getUserCalled = true;
          receivedExistingCookie = cookies
            .getAll()
            .some(
              ({ name, value }) => name === "preserve" && value === "original",
            );
          assert.equal(cookieOptions.secure, true);
          cookies.setAll(
            [
              {
                name: "sb-project-auth-token",
                value: "rotated-session",
                options: {
                  ...cookieOptions,
                  httpOnly: false,
                  path: "/",
                  sameSite: "lax",
                },
              },
            ],
            {
              "Cache-Control":
                "private, no-cache, no-store, must-revalidate, max-age=0",
              Expires: "0",
              Pragma: "no-cache",
            },
          );
        },
      },
    }),
  );

  assert.ok(getUserCalled);
  assert.ok(receivedExistingCookie);
  assert.equal(
    response.cookies.get("sb-project-auth-token")?.value,
    "rotated-session",
  );
  assert.equal(
    response.headers.get("Cache-Control"),
    "private, no-cache, no-store, must-revalidate, max-age=0",
  );
  assert.equal(response.headers.get("Expires"), "0");
  assert.equal(response.headers.get("Pragma"), "no-cache");
  assert.match(
    response.headers.get("x-middleware-request-cookie") ?? "",
    /sb-project-auth-token=rotated-session/,
  );
});
