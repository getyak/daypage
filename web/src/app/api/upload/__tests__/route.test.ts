import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { chmod, mkdir, mkdtemp, realpath, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NextRequest } from "next/server";
import { MAX_UPLOAD_BYTES, UPLOAD_OWNERS_DIR } from "@/lib/local-uploads";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mocks = vi.hoisted(() => ({
  auth: vi.fn(),
  resolveUserId: vi.fn(),
}));
vi.mock("@/lib/auth/session", () => mocks);

import { auth, resolveUserId } from "@/lib/auth/session";
import { POST } from "../route";

// ── Fixtures (temp artifacts live under TMPDIR, never cwd/uploads) ────────────

const OWNER_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const ATTACKER_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

const PNG_BYTES = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01, 0x02, 0x03,
]);

function sessionFor(email: string) {
  return {
    user: { id: "auth-user", email, name: null, provider: null },
  } as Awaited<ReturnType<typeof auth>>;
}

function uploadRequest(opts: {
  file?: File | null;
  fields?: Record<string, string>;
}): NextRequest {
  const form = new FormData();
  if (opts.file) form.set("file", opts.file);
  for (const [key, value] of Object.entries(opts.fields ?? {})) {
    form.set(key, value);
  }
  return new NextRequest("http://localhost/api/upload", { method: "POST", body: form });
}

function pngFile(name = "photo.png", type = "image/png"): File {
  return new File([PNG_BYTES], name, { type });
}

let base: string;

beforeEach(async () => {
  base = await realpath(await mkdtemp(join(tmpdir(), "api-upload-test-")));
  vi.spyOn(process, "cwd").mockReturnValue(base);
  vi.clearAllMocks();
  vi.mocked(auth).mockResolvedValue(sessionFor("alice@example.com"));
  vi.mocked(resolveUserId).mockResolvedValue(OWNER_ID);
});

afterEach(async () => {
  vi.restoreAllMocks();
  await rm(base, { recursive: true, force: true });
});

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("POST /api/upload", () => {
  it("returns 401 when unauthenticated", async () => {
    vi.mocked(auth).mockResolvedValue(null);
    const res = await POST(uploadRequest({ file: pngFile() }));
    expect(res.status).toBe(401);
    expect(vi.mocked(resolveUserId)).not.toHaveBeenCalled();
  });

  it("returns 401 when the authenticated email has no internal profile", async () => {
    vi.mocked(resolveUserId).mockResolvedValue(null);
    const res = await POST(uploadRequest({ file: pngFile() }));
    expect(res.status).toBe(401);
  });

  it("returns 201 with exactly the five documented fields and a random server filename", async () => {
    const res = await POST(uploadRequest({ file: pngFile("holiday photo.png", "image/png") }));
    expect(res.status).toBe(201);

    const body = (await res.json()) as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual([
      "filename",
      "mime_type",
      "original_filename",
      "size",
      "url",
    ]);
    expect(body.original_filename).toBe("holiday photo.png");
    expect(body.mime_type).toBe("image/png");
    expect(body.size).toBe(PNG_BYTES.length);

    // Random server-generated UUID basename, never derived from the client
    // name beyond a sanitized extension.
    expect(body.filename).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$/);
    expect(body.url).toBe(`/uploads/${body.filename as string}`);
  });

  it("stores the exact original bytes and binds ownership to the resolved users.id, ignoring forged owner/attachment fields", async () => {
    const res = await POST(
      uploadRequest({
        file: pngFile(),
        fields: {
          // Forged ownership / memo attachment fields: they must never grant
          // or transfer ownership.
          owner_id: ATTACKER_ID,
          user_id: ATTACKER_ID,
          storage_key: "vault/raw/assets/attacker.png",
          memo_id: "memo-forged",
        },
      })
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as { filename: string };

    const blob = await readFile(join(base, "uploads", body.filename));
    expect(Buffer.compare(blob, PNG_BYTES)).toBe(0);

    const sidecar = JSON.parse(
      await readFile(join(base, "uploads", UPLOAD_OWNERS_DIR, `${body.filename}.json`), "utf8")
    ) as Record<string, unknown>;
    expect(sidecar.owner_id).toBe(OWNER_ID);
    expect(sidecar.owner_id).not.toBe(ATTACKER_ID);
    expect(sidecar.size).toBe(PNG_BYTES.length);
  });

  it("resolves the owner from the authenticated email, not from request content", async () => {
    await POST(uploadRequest({ file: pngFile(), fields: { email: "attacker@example.com" } }));
    expect(vi.mocked(resolveUserId)).toHaveBeenCalledWith("alice@example.com");
  });

  it("rejects multipart bodies without a file field", async () => {
    const res = await POST(uploadRequest({ fields: { owner_id: ATTACKER_ID } }));
    expect(res.status).toBe(400);
  });

  it("rejects oversized files with the existing 400 behavior", async () => {
    const big = new File([new Uint8Array(MAX_UPLOAD_BYTES + 1)], "big.png", {
      type: "image/png",
    });
    const res = await POST(uploadRequest({ file: big }));
    expect(res.status).toBe(400);
  });

  it("keeps the existing MIME allow-list behavior", async () => {
    const zip = new File([Buffer.from("PK")], "payload.zip", { type: "application/zip" });
    const res = await POST(uploadRequest({ file: zip }));
    expect(res.status).toBe(400);
  });

  it("fails closed with a generic 500 and logs no paths when storage fails", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    await mkdir(join(base, "uploads"), { recursive: true });
    await chmod(join(base, "uploads"), 0o500);

    try {
      const res = await POST(uploadRequest({ file: pngFile("secret evidence.png") }));
      expect(res.status).toBe(500);
      const body = (await res.json()) as Record<string, unknown>;
      expect(body).toEqual({ error: "Upload failed" });

      for (const call of consoleError.mock.calls) {
        const line = call.map(String).join(" ");
        expect(line).not.toContain("secret");
        expect(line).not.toContain(base);
        expect(line).not.toContain("uploads/");
      }
    } finally {
      await chmod(join(base, "uploads"), 0o700);
    }
  });

  it("sanitizes dangerous client extensions to a safe canonical basename", async () => {
    const res = await POST(
      uploadRequest({ file: new File([PNG_BYTES], "payload.<script>", { type: "image/png" }) })
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as { filename: string };
    expect(body.filename).toMatch(/^[0-9a-f-]{36}$/);
  });
});
