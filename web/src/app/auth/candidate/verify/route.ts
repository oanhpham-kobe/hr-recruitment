import type { SupabaseClient } from "@supabase/supabase-js";
import { type NextRequest, NextResponse } from "next/server";
import { provisionCandidateIdentity } from "@/lib/auth/candidate";
import { validateSameOrigin } from "@/lib/security/origin";
import { createServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function POST(
  request: NextRequest,
  _context?: unknown,
  clientOverride?: SupabaseClient,
) {
  if (!validateSameOrigin(request)) {
    return NextResponse.json(
      {
        success: false,
        error: {
          code: "FORBIDDEN",
          message: "Cross-origin request rejected",
        },
      },
      { status: 403 },
    );
  }

  let body: { email?: unknown; token?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      {
        success: false,
        error: {
          code: "VALIDATION_ERROR",
          message: "Invalid JSON request body",
        },
      },
      { status: 400 },
    );
  }

  const { email, token } = body ?? {};
  if (
    !email ||
    !token ||
    typeof email !== "string" ||
    typeof token !== "string"
  ) {
    return NextResponse.json(
      {
        success: false,
        error: {
          code: "VALIDATION_ERROR",
          message: "Email and OTP token are required",
        },
      },
      { status: 400 },
    );
  }

  const supabase = clientOverride ?? (await createServerClient());
  const { error: otpError } = await supabase.auth.verifyOtp({
    email,
    token,
    type: "email",
  });
  if (otpError) {
    return NextResponse.json(
      {
        success: false,
        error: {
          code: "UNAUTHENTICATED",
          message: "Invalid or expired OTP code",
        },
      },
      { status: 401 },
    );
  }

  const provisionResult = await provisionCandidateIdentity(supabase);
  return NextResponse.json(provisionResult, {
    status: provisionResult.success ? 200 : 400,
  });
}
