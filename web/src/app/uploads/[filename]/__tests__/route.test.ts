import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdir, mkdtemp, realpath, readFile, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NextRequest } from "next/server";
import { createOwnedUpload, UPLOAD_OWNERS_DIR } from "@/lib/local-uploads";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mocks = vi.hoisted(() => ({
  auth: vi.fn(),
  resolveUserId: vi.fn(),
  dbSelect: vi.fn(() => {
    throw new Error("upload serving must never consult the database for ownership");
  }),
}));
vi.mock("@/lib/auth/session", () => ({ auth: mocks.auth, resolveUserId: mocks.resolveUserId }));
// Ownership must come only from the private local index. If anyone ever adds a
// memo_attachments/storage_key join to this route, this mock makes it throw.
vi.mock("@/lib/db/client", () => ({ db: { select: mocks.dbSelect } }));

import { auth, resolveUserId } from "@/lib/auth/session";
import { GET } from "../route";

// ── Fixtures (temp artifacts live under TMPDIR, never cwd/uploads) ────────────

const OWNER_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

const PNG_BYTES = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x05, 0x06, 0x07,
]);
const JPEG_BYTES = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
const SVG_BYTES = Buffer.from('<svg onload="alert(1)"></svg>', "utf8");
const HTML_BYTES = Buffer.from("<html><script>alert(1)</script></html>", "utf8");
const TEXT_BYTES = Buffer.from("hello, world\n", "utf8");

function sessionFor(email: string) {
  return {
    user: { id: "auth-user", email, name: null, provider: null },
  } as Awaited<ReturnType<typeof auth>>;
}

function getRequest(filename: string): NextRequest {
  return new NextRequest(`http://localhost/uploads/${filename}`);
}

function routeContext(filename: string) {
  return { params: Promise.resolve({ filename }) };
}

async function seedUpload(opts: {
  ownerId: string;
  bytes: Uint8Array;
  declaredMime: string;
  declaredFilename: string;
}): Promise<string> {
  const created = await createOwnedUpload({ ...opts, root: join(base, "uploads") });
  if (!created.ok) throw new Error(`seed failed: ${created.code}`);
  return created.record.filename;
}

let base: string;

beforeEach(async () => {
  base = await realpath(await mkdtemp(join(tmpdir(), "uploads-route-test-")));
  vi.spyOn(process, "cwd").mockReturnValue(base);
  vi.clearAllMocks();
  vi.mocked(auth).mockResolvedValue(sessionFor("alice@example.com"));
  vi.mocked(resolveUserId).mockResolvedValue(OWNER_ID);
});

afterEach(async () => {
  vi.restoreAllMocks();
  await rm(base, { recursive: true, force: true });
});

// ── Auth and ownership ────────────────────────────────────────────────────────

describe("GET /uploads/[filename] — auth and ownership", () => {
  it("returns 401 when unauthenticated", async () => {
    vi.mocked(auth).mockResolvedValue(null);
    const res = await GET(getRequest("whatever.png"), routeContext("whatever.png"));
    expect(res.status).toBe(401);
    expect(res.headers.get("Cache-Control")).toBe("private, no-store");
    expect(res.headers.get("X-Content-Type-Options")).toBe("nosniff");
  });

  it("returns a uniform 404 when the authenticated email has no internal profile", async () => {
    vi.mocked(resolveUserId).mockResolvedValue(null);
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
    });
    const res = await GET(getRequest(name), routeContext(name));
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "Not found" });
  });

  it("serves the exact original bytes to the recorded owner", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
    });
    const res = await GET(getRequest(name), routeContext(name));

    expect(res.status).toBe(200);
    const body = new Uint8Array(await res.arrayBuffer());
    expect(Buffer.compare(Buffer.from(body), PNG_BYTES)).toBe(0);
  });

  it("denies another account that knows the filename, with no database/memo-attachment lookup", async () => {
    // Forged-attachment scenario: the other account references this file's
    // storage_key from its own memo attachments. Ownership must still fail.
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
    });
    vi.mocked(resolveUserId).mockResolvedValue(OTHER_ID);

    const res = await GET(getRequest(name), routeContext(name));
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "Not found" });
    expect(mocks.dbSelect).not.toHaveBeenCalled();
  });

  it("denies legacy ownerless files with the same uniform 404", async () => {
    await mkdir(join(base, "uploads"), { recursive: true });
    const name = `${crypto.randomUUID()}.png`;
    await writeFile(join(base, "uploads", name), PNG_BYTES);

    const res = await GET(getRequest(name), routeContext(name));
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "Not found" });
  });
});

// ── Path safety ───────────────────────────────────────────────────────────────

describe("GET /uploads/[filename] — path safety", () => {
  it("denies traversal, dotfile, and ownership-index names uniformly", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
    });

    const names = [
      `../${name}`,
      "..",
      ".env",
      UPLOAD_OWNERS_DIR,
      `${UPLOAD_OWNERS_DIR}/${name}.json`,
      `${UPLOAD_OWNERS_DIR}/${name}.json/..`,
      `sub/${name}`,
      name.toUpperCase(),
    ];
    for (const bad of names) {
      const res = await GET(getRequest(bad), routeContext(bad));
      expect(res.status, `expected 404 for ${JSON.stringify(bad)}`).toBe(404);
      expect(await res.json()).toEqual({ error: "Not found" });
    }
  });

  it("never serves the ownership index even when its exact path is requested", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
    });

    const res = await GET(
      getRequest(`${UPLOAD_OWNERS_DIR}/${name}.json`),
      routeContext(`${UPLOAD_OWNERS_DIR}/${name}.json`)
    );
    expect(res.status).toBe(404);
    const body = await res.text();
    expect(body).not.toContain(OWNER_ID);
    expect(body).not.toContain("sha256");
    expect(body).not.toContain(name);
  });

  it("denies a symlinked blob even when its bytes are valid", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
    });
    const outside = join(base, "outside.png");
    await writeFile(outside, PNG_BYTES);
    await unlink(join(base, "uploads", name));
    await symlink(outside, join(base, "uploads", name));

    const res = await GET(getRequest(name), routeContext(name));
    expect(res.status).toBe(404);
  });

  it("denies tampered content and tampered index records uniformly", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
    });
    await writeFile(join(base, "uploads", name), Buffer.from("swapped"));
    let res = await GET(getRequest(name), routeContext(name));
    expect(res.status).toBe(404);

    await writeFile(join(base, "uploads", name), PNG_BYTES);
    const sidecarPath = join(base, "uploads", UPLOAD_OWNERS_DIR, `${name}.json`);
    const record = JSON.parse(await readFile(sidecarPath, "utf8")) as Record<string, unknown>;
    record.owner_id = OTHER_ID;
    await writeFile(sidecarPath, JSON.stringify(record));

    // The recorded owner no longer matches; the previous owner is denied.
    res = await GET(getRequest(name), routeContext(name));
    expect(res.status).toBe(404);
  });
});

// ── Response hardening ────────────────────────────────────────────────────────

describe("GET /uploads/[filename] — response headers", () => {
  it("inlines magic-byte-validated PNG as image/png despite a claimed text/plain MIME", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: PNG_BYTES,
      declaredMime: "text/plain",
      declaredFilename: "photo.png",
    });
    const res = await GET(getRequest(name), routeContext(name));

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/png");
    expect(res.headers.get("Content-Disposition")).toBe(`inline; filename="${name}"`);
    expect(res.headers.get("Cache-Control")).toBe("private, no-store");
    expect(res.headers.get("Vary")).toBe("Cookie");
    expect(res.headers.get("X-Content-Type-Options")).toBe("nosniff");
  });

  it("inlines magic-byte-validated JPEG as image/jpeg", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: JPEG_BYTES,
      declaredMime: "application/pdf",
      declaredFilename: "scan.pdf",
    });
    const res = await GET(getRequest(name), routeContext(name));

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/jpeg");
    expect(res.headers.get("Content-Disposition")).toBe(`inline; filename="${name}"`);
  });

  it("forces attachment + sandbox CSP + opaque type for SVG", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: SVG_BYTES,
      declaredMime: "image/svg+xml",
      declaredFilename: "logo.svg",
    });
    const res = await GET(getRequest(name), routeContext(name));

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(res.headers.get("Content-Disposition")).toBe(`attachment; filename="${name}"`);
    expect(res.headers.get("Content-Security-Policy")).toBe("sandbox");
    expect(res.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(res.headers.get("Cache-Control")).toBe("private, no-store");
    expect(res.headers.get("Vary")).toBe("Cookie");
  });

  it("forces attachment + sandbox CSP for HTML and text bytes", async () => {
    for (const bytes of [HTML_BYTES, TEXT_BYTES]) {
      const name = await seedUpload({
        ownerId: OWNER_ID,
        bytes,
        declaredMime: "text/plain",
        declaredFilename: "notes.txt",
      });
      const res = await GET(getRequest(name), routeContext(name));

      expect(res.status).toBe(200);
      expect(res.headers.get("Content-Type")).toBe("application/octet-stream");
      expect(res.headers.get("Content-Disposition")).toBe(`attachment; filename="${name}"`);
      expect(res.headers.get("Content-Security-Policy")).toBe("sandbox");
    }
  });

  it("never trusts a spoofed .png extension for inline rendering of active content", async () => {
    const name = await seedUpload({
      ownerId: OWNER_ID,
      bytes: HTML_BYTES,
      declaredMime: "image/png",
      declaredFilename: "evil.png",
    });
    const res = await GET(getRequest(name), routeContext(name));

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(res.headers.get("Content-Disposition")).toBe(`attachment; filename="${name}"`);
    expect(res.headers.get("Content-Security-Policy")).toBe("sandbox");
  });
});
