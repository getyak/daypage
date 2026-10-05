import { NextRequest, NextResponse } from "next/server";
import { auth, resolveUserId } from "@/lib/auth/session";
import { createOwnedUpload, MAX_UPLOAD_BYTES } from "@/lib/local-uploads";

// local-uploads is Node-only (fs/crypto); force the Node.js runtime so Next.js
// does not attempt to compile this handler for the Edge runtime.
export const runtime = "nodejs";

const MAX_SIZE_BYTES = MAX_UPLOAD_BYTES; // 10 MB

const ALLOWED_MIME_PREFIXES = [
  "image/",
  "audio/",
  "application/pdf",
  "text/",
];

function isAllowedMime(mime: string): boolean {
  return ALLOWED_MIME_PREFIXES.some((prefix) => mime.startsWith(prefix));
}

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

// POST /api/upload — accept multipart/form-data, store file locally
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  // Owner is the internal users.id resolved from the authenticated email.
  // Request-supplied owner/memo attachment fields are never trusted.
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  let formData: FormData;
  try {
    formData = await req.formData();
  } catch {
    return badRequest("Expected multipart/form-data");
  }

  const file = formData.get("file");
  if (!file || !(file instanceof File)) {
    return badRequest("Missing 'file' field in form data");
  }

  if (file.size > MAX_SIZE_BYTES) {
    return badRequest(`File exceeds 10 MB limit (${file.size} bytes)`);
  }

  const mimeType = file.type || "application/octet-stream";
  if (!isAllowedMime(mimeType)) {
    return badRequest(
      `File type '${mimeType}' is not allowed. Permitted: images, audio, PDF, text.`
    );
  }

  const bytes = new Uint8Array(await file.arrayBuffer());

  // Exclusive blob + private ownership sidecar, fsynced before 201. Partial
  // failure fails closed and cleans up only just-created files (never older or
  // colliding paths).
  const created = await createOwnedUpload({
    ownerId: userId,
    bytes,
    declaredMime: mimeType,
    declaredFilename: file.name,
  });

  if (!created.ok) {
    // Log only a stable error code — no filenames, paths, or content.
    console.error(`[api/upload] local upload creation failed (${created.code})`);
    return NextResponse.json({ error: "Upload failed" }, { status: 500 });
  }

  return NextResponse.json(
    {
      url: created.url,
      filename: created.record.filename,
      original_filename: file.name,
      size: file.size,
      mime_type: mimeType,
    },
    { status: 201 }
  );
}
