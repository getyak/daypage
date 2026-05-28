import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { writeFile, mkdir } from "fs/promises";
import { join, extname } from "path";
import { randomUUID } from "crypto";

// fs/promises is Node-only; force the Node.js runtime so Next.js does not
// attempt to compile this handler for the Edge runtime (would fail on `fs`).
export const runtime = "nodejs";

const MAX_SIZE_BYTES = 10 * 1024 * 1024; // 10 MB

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

  const userRows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);

  if (!userRows.length) return unauthorized();

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

  const ext = extname(file.name) || "";
  const filename = `${randomUUID()}${ext}`;

  const uploadsDir = join(process.cwd(), "uploads");
  await mkdir(uploadsDir, { recursive: true });

  const destPath = join(uploadsDir, filename);
  const bytes = await file.arrayBuffer();
  await writeFile(destPath, Buffer.from(bytes));

  const url = `/uploads/${filename}`;

  return NextResponse.json(
    {
      url,
      filename,
      original_filename: file.name,
      size: file.size,
      mime_type: mimeType,
    },
    { status: 201 }
  );
}
