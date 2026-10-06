import { NextRequest, NextResponse } from "next/server";
import { auth, resolveUserId } from "@/lib/auth/session";
import { readOwnedUpload } from "@/lib/local-uploads";

// Private owner-index reads use fs/crypto; force the Node.js runtime.
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ filename: string }> };

const BASE_HEADERS = {
  "Cache-Control": "private, no-store",
  Vary: "Cookie",
  "X-Content-Type-Options": "nosniff",
} as const;

function unauthorized() {
  return NextResponse.json(
    { error: "Unauthorized" },
    { status: 401, headers: BASE_HEADERS }
  );
}

// Uniform denial: unknown profile, no record, tamper, and path mismatch all
// answer the same way so callers cannot probe for existing filenames.
function notFound() {
  return NextResponse.json(
    { error: "Not found" },
    { status: 404, headers: BASE_HEADERS }
  );
}

// GET /uploads/[filename] — serve an upload to its recorded owner only.
export async function GET(_req: NextRequest, { params }: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return notFound();

  const { filename } = await params;

  // Ownership comes only from the private disk index bound to the trusted
  // profile id; memo attachment storage_key/join values never grant access.
  const result = await readOwnedUpload({ filename, requesterId: userId });
  if (!result.ok) return notFound();

  const headers = new Headers(BASE_HEADERS);
  headers.set("Content-Disposition", `${result.delivery.kind}; filename="${result.record.filename}"`);
  if (result.delivery.kind === "inline") {
    // Magic-byte-validated raster JPEG/PNG only.
    headers.set("Content-Type", result.delivery.contentType);
  } else {
    // Everything else (SVG/HTML/text/mismatched bytes) is a forced download.
    headers.set("Content-Type", "application/octet-stream");
    headers.set("Content-Security-Policy", "sandbox");
  }

  // Copy into an ArrayBuffer-backed view for the fetch Response body.
  return new Response(new Uint8Array(result.bytes), { status: 200, headers });
}
