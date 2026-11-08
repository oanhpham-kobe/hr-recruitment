import { Buffer } from "node:buffer";

import {
  type CookieOptions,
  createServerClient as createSupabaseServerClient,
} from "@supabase/ssr";
import { type NextRequest, NextResponse } from "next/server";

import { getPublicSupabaseEnv } from "@/lib/env/client";

type RequestCookie = {
  name: string;
  value: string;
};

type CookiesToSet = Array<{
  name: string;
  value: string;
  options: CookieOptions;
}>;

type SessionClientFactoryOptions = {
  cookieOptions: CookieOptions;

  cookies: {
    getAll: () => RequestCookie[];
    setAll: (
      cookiesToSet: CookiesToSet,
      headers: Record<string, string>,
    ) => void;
  };
};

type SessionClientFactory = (
  url: string,
  publishableKey: string,
  options: SessionClientFactoryOptions,
) => {
  auth: {
    getUser: () => Promise<unknown>;
  };
};

function createSessionClient(
  url: string,
  publishableKey: string,
  options: SessionClientFactoryOptions,
) {
  return createSupabaseServerClient(url, publishableKey, options);
}

function getSupabaseOrigin(): string | undefined {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;

  if (!supabaseUrl) {
    return undefined;
  }

  try {
    return new URL(supabaseUrl).origin;
  } catch {
    return undefined;
  }
}

function createContentSecurityPolicy(nonce: string): string {
  let gatewayOrigin: string | undefined;
  if (
    process.env.DOCUMENT_STORAGE_PROVIDER === "DRIVE" &&
    process.env.DRIVE_RUNTIME_VERIFIED === "true"
  ) {
    try {
      const url = new URL(process.env.DRIVE_GATEWAY_ORIGIN ?? "");
      if (
        url.protocol === "https:" &&
        url.origin === process.env.DRIVE_GATEWAY_ORIGIN
      )
        gatewayOrigin = url.origin;
    } catch {
      /* Fail closed: no gateway origin in CSP. */
    }
  }
  const connectSources = ["'self'", getSupabaseOrigin(), gatewayOrigin]
    .filter(Boolean)
    .join(" ");

  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    `style-src 'self' 'nonce-${nonce}'`,
    "img-src 'self' data: blob:",
    "frame-src 'self' blob:",
    "font-src 'self'",
    `connect-src ${connectSources}`,
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join("; ");
}

/**
 * Refreshes the cookie session before a route reads it. Updated cookies and
 * cache-control headers must travel with the same response.
 */
export async function refreshSupabaseSession(
  request: NextRequest,
  requestHeaders: Headers,
  sessionClientFactory: SessionClientFactory = createSessionClient,
) {
  const { url, publishableKey } = getPublicSupabaseEnv();
  let response = NextResponse.next({
    request: { headers: requestHeaders },
  });

  const supabase = sessionClientFactory(url, publishableKey, {
    cookieOptions: { secure: process.env.NODE_ENV === "production" },
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }

        requestHeaders.set("cookie", request.cookies.toString());
        response = NextResponse.next({
          request: { headers: requestHeaders },
        });

        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
        for (const [name, value] of Object.entries(headers)) {
          response.headers.set(name, value);
        }
      },
    },
  });

  await supabase.auth.getUser();

  return response;
}

export async function middleware(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const contentSecurityPolicy = createContentSecurityPolicy(nonce);
  const requestHeaders = new Headers(request.headers);

  requestHeaders.set("x-nonce", nonce);
  requestHeaders.set("Content-Security-Policy", contentSecurityPolicy);
  requestHeaders.set("x-pathname", request.nextUrl.pathname);

  const response = await refreshSupabaseSession(request, requestHeaders);

  response.headers.set("Content-Security-Policy", contentSecurityPolicy);
  response.headers.set("x-nonce", nonce);
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  response.headers.set(
    "Permissions-Policy",
    "camera=(), microphone=(), geolocation=()",
  );
  response.headers.set("X-Frame-Options", "DENY");

  return response;
}

export const config = {
  matcher: [
    {
      source: "/((?!_next/static|_next/image|favicon.ico).*)",
      missing: [
        { type: "header", key: "next-router-prefetch" },
        { type: "header", key: "purpose", value: "prefetch" },
      ],
    },
  ],
};
