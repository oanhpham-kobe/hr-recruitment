import type { SupabaseClient } from "@supabase/supabase-js";
import { type NextRequest, NextResponse } from "next/server";
import {
  DocumentNotPreviewableError,
  getDocumentPreviewStream,
  SubmissionDetailAccessError,
  SubmissionDetailNotFoundError,
} from "@/lib/application-inbox/submission-detail-server";

export const dynamic = "force-dynamic";

export async function GET(
  request: NextRequest,
  context: { params: Promise<{ id: string }> },
  deps?: {
    client?: SupabaseClient;
    adminClient?: SupabaseClient;
    fetchFn?: typeof fetch;
  },
) {
  const { id: documentId } = await context.params;
  const searchParams =
    request.nextUrl?.searchParams ?? new URL(request.url).searchParams;
  const submissionId = searchParams.get("submissionId") ?? undefined;
  const logicalDocumentId = searchParams.get("logicalDocumentId") ?? undefined;

  try {
    const { stream, mimeType, filename } = await getDocumentPreviewStream(
      {
        documentId,
        submissionId,
        logicalDocumentId,
      },
      deps,
    );

    return new NextResponse(stream, {
      status: 200,
      headers: {
        "Content-Type": mimeType,
        "Content-Disposition": `inline; filename="${encodeURIComponent(filename)}"`,
        "Cache-Control": "private, no-cache, no-store, must-revalidate",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy":
          "default-src 'none'; style-src 'unsafe-inline'; sandbox",
      },
    });
  } catch (error) {
    if (error instanceof DocumentNotPreviewableError) {
      return new NextResponse(error.message, { status: 415 });
    }
    if (error instanceof SubmissionDetailAccessError) {
      return new NextResponse(error.message, { status: 403 });
    }
    if (error instanceof SubmissionDetailNotFoundError) {
      return new NextResponse(error.message, { status: 404 });
    }
    return new NextResponse("Internal server error", { status: 500 });
  }
}
