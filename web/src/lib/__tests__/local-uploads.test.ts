import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHash, randomUUID } from "node:crypto";
import {
  link,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  classifyUploadDelivery,
  createOwnedUpload,
  isCanonicalUploadFilename,
  MAX_UPLOAD_BYTES,
  readOwnedUpload,
  UPLOAD_OWNERS_DIR,
} from "../local-uploads";

const fsHooks = vi.hoisted(() => ({
  beforeOpen: null as ((path: string) => Promise<void>) | null,
}));
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    open: async (...args: Parameters<typeof actual.open>) => {
      await fsHooks.beforeOpen?.(String(args[0]));
      return actual.open(...args);
    },
  };
});

// ── Fixtures (all temp artifacts live under TMPDIR, never cwd/uploads) ────────

const OWNER_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OWNER_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

const PNG_BYTES = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52,
]);
const JPEG_BYTES = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
const SVG_BYTES = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>', "utf8");
const HTML_BYTES = Buffer.from("<html><body><script>alert(1)</script></body></html>", "utf8");

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function makeName(ext = ".png"): string {
  return `${randomUUID()}${ext}`;
}

async function createOk(
  input: Parameters<typeof createOwnedUpload>[0]
): Promise<Extract<Awaited<ReturnType<typeof createOwnedUpload>>, { ok: true }>> {
  const result = await createOwnedUpload(input);
  if (!result.ok) throw new Error(`expected create to succeed, got ${result.code}`);
  return result;
}

async function readOk(
  input: Parameters<typeof readOwnedUpload>[0]
): Promise<Extract<Awaited<ReturnType<typeof readOwnedUpload>>, { ok: true }>> {
  const result = await readOwnedUpload(input);
  if (!result.ok) throw new Error(`expected read to succeed, got ${result.reason}`);
  return result;
}

let base: string;
let root: string;

beforeEach(async () => {
  fsHooks.beforeOpen = null;
  base = await realpath(await mkdtemp(join(tmpdir(), "local-uploads-test-")));
  root = join(base, "uploads");
});

afterEach(async () => {
  fsHooks.beforeOpen = null;
  await rm(base, { recursive: true, force: true });
});

// ── Write path ────────────────────────────────────────────────────────────────

describe("createOwnedUpload", () => {
  it("writes the exact bytes plus a private v1 sidecar and returns the /uploads URL", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    expect(created.url).toBe(`/uploads/${created.record.filename}`);
    expect(created.record.filename).toMatch(/^[0-9a-f-]{36}\.png$/);
    expect(created.record.owner_id).toBe(OWNER_A);
    expect(created.record.size).toBe(PNG_BYTES.length);
    expect(created.record.sha256).toBe(sha256(PNG_BYTES));

    const blob = await readFile(join(root, created.record.filename));
    expect(Buffer.compare(blob, PNG_BYTES)).toBe(0);

    const sidecarRaw = await readFile(
      join(root, UPLOAD_OWNERS_DIR, `${created.record.filename}.json`),
      "utf8"
    );
    const sidecar = JSON.parse(sidecarRaw) as Record<string, unknown>;
    expect(sidecar).toMatchObject({
      version: 1,
      filename: created.record.filename,
      owner_id: OWNER_A,
      size: PNG_BYTES.length,
      sha256: sha256(PNG_BYTES),
      content_type: "image/png",
    });
  });

  it("never lets request content smuggle control characters into the indexed content type", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "text/html\r\nX-Evil: 1",
      declaredFilename: "photo.png",
      root,
    });
    expect(created.record.content_type).toBe("application/octet-stream");

    const sidecarRaw = await readFile(
      join(root, UPLOAD_OWNERS_DIR, `${created.record.filename}.json`),
      "utf8"
    );
    expect(sidecarRaw).not.toContain("\r");
    expect(sidecarRaw.toLowerCase()).not.toContain("x-evil");
  });

  it("strips MIME parameters and lowercases the indexed content type", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "IMAGE/PNG; charset=utf-8",
      declaredFilename: "photo.png",
      root,
    });
    expect(created.record.content_type).toBe("image/png");
  });

  it("keeps only a safe ASCII extension from the client filename", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "my photo.<script>alert(1)</script>",
      root,
    });
    expect(created.record.filename).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("enforces the 10 MB limit in the helper even if a caller skipped its own check", async () => {
    const huge = new Uint8Array(MAX_UPLOAD_BYTES + 1);
    const result = await createOwnedUpload({
      ownerId: OWNER_A,
      bytes: huge,
      declaredMime: "application/pdf",
      declaredFilename: "big.pdf",
      root,
    });
    expect(result).toEqual({ ok: false, code: "invalid-size" });
  });

  it("rejects a non-UUID owner id", async () => {
    const result = await createOwnedUpload({
      ownerId: "../../etc/passwd",
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });
    expect(result).toEqual({ ok: false, code: "invalid-owner" });
  });

  it("refuses generated names that escape the canonical UUID+safe-extension shape", async () => {
    for (const bad of ["../escape.png", "..", ".hidden", "name with space.png", `${randomUUID()}.png/x`]) {
      const result = await createOwnedUpload({
        ownerId: OWNER_A,
        bytes: PNG_BYTES,
        declaredMime: "image/png",
        declaredFilename: "photo.png",
        root,
        generateFilename: () => bad,
      });
      expect(result).toEqual({ ok: false, code: "invalid-filename" });
    }
  });

  it("fails on an exclusive blob collision without touching the older file or creating ownership", async () => {
    const name = makeName();
    await mkdir(root, { recursive: true });
    const existing = join(root, name);
    await writeFile(existing, "keep-me");

    const result = await createOwnedUpload({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
      generateFilename: () => name,
    });

    expect(result).toEqual({ ok: false, code: "collision" });
    expect(await readFile(existing, "utf8")).toBe("keep-me");
    await expect(
      readFile(join(root, UPLOAD_OWNERS_DIR, `${name}.json`))
    ).rejects.toThrow();
  });

  it("cleans up only its just-created blob when the sidecar collides with an older file", async () => {
    const name = makeName();
    await mkdir(join(root, UPLOAD_OWNERS_DIR), { recursive: true });
    const existingSidecar = join(root, UPLOAD_OWNERS_DIR, `${name}.json`);
    await writeFile(existingSidecar, "keep-sidecar");

    const result = await createOwnedUpload({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
      generateFilename: () => name,
    });

    expect(result).toEqual({ ok: false, code: "collision" });
    // The just-created blob is removed; the colliding sidecar is never rewritten.
    await expect(readFile(join(root, name))).rejects.toThrow();
    expect(await readFile(existingSidecar, "utf8")).toBe("keep-sidecar");
  });

  it("removes its fully written blob after a deterministic sidecar-open failure", async () => {
    const name = makeName();
    fsHooks.beforeOpen = async (path) => {
      if (path !== join(root, UPLOAD_OWNERS_DIR, `${name}.json`)) return;
      fsHooks.beforeOpen = null;
      throw Object.assign(new Error("injected storage failure"), { code: "ENOSPC" });
    };
    const result = await createOwnedUpload({ ownerId: OWNER_A, bytes: PNG_BYTES,
      declaredMime: "image/png", declaredFilename: "photo.png", root, generateFilename: () => name });
    expect(result).toEqual({ ok: false, code: "io-error" });
    await expect(readFile(join(root, name))).rejects.toThrow();
  });

  it("rejects a symlinked .owners root instead of writing through it", async () => {
    const elsewhere = join(base, "elsewhere");
    await mkdir(elsewhere, { recursive: true });
    await mkdir(root, { recursive: true });
    await symlink(elsewhere, join(root, UPLOAD_OWNERS_DIR));

    const result = await createOwnedUpload({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    expect(result).toEqual({ ok: false, code: "invalid-root" });
    expect(await readdir(elsewhere)).toEqual([]);
  });

  it("rejects a symlinked uploads root instead of writing through it", async () => {
    const realUp = join(base, "real-uploads");
    await mkdir(realUp, { recursive: true });
    await symlink(realUp, root);

    const result = await createOwnedUpload({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    expect(result).toEqual({ ok: false, code: "invalid-root" });
    expect(await readdir(realUp)).toEqual([]);
  });
  it("rejects ancestor aliases without creating anything in their target", async () => {
    const target = join(base, "target");
    const alias = join(base, "alias");
    await mkdir(target);
    await symlink(target, alias);
    const result = await createOwnedUpload({ ownerId: OWNER_A, bytes: PNG_BYTES,
      declaredMime: "image/png", declaredFilename: "photo.png", root: join(alias, "uploads") });
    expect(result).toEqual({ ok: false, code: "invalid-root" });
    expect(await readdir(target)).toEqual([]);
  });

  it.each(["replacement-inode", "same-inode-content"])("preserves changed blob on failed commit: %s", async (mode) => {
    const name = makeName();
    const blobPath = join(root, name);
    const victim = Buffer.alloc(PNG_BYTES.length, 0x41);
    fsHooks.beforeOpen = async (path) => {
      if (path !== join(root, UPLOAD_OWNERS_DIR, `${name}.json`)) return;
      fsHooks.beforeOpen = null;
      if (mode === "replacement-inode") await rename(blobPath, join(root, "original-blob"));
      await writeFile(blobPath, victim);
      throw Object.assign(new Error("injected sidecar failure"), { code: "ENOSPC" });
    };
    expect(await createOwnedUpload({ ownerId: OWNER_A, bytes: PNG_BYTES, declaredMime: "image/png",
      declaredFilename: "photo.png", root, generateFilename: () => name })).toEqual({ ok: false, code: "io-error" });
    expect(await readFile(blobPath)).toEqual(victim);
    if (mode === "replacement-inode") expect(await readFile(join(root, "original-blob"))).toEqual(PNG_BYTES);
    expect((await readOwnedUpload({ filename: name, requesterId: OWNER_A, root })).ok).toBe(false);
  });

  it("preserves a replacement directory and its victim on failed commit", async () => {
    const name = makeName();
    const oldRoot = join(base, "original-store");
    const victim = Buffer.from("unknown replacement directory victim");
    fsHooks.beforeOpen = async (path) => {
      if (path !== join(root, UPLOAD_OWNERS_DIR, `${name}.json`)) return;
      fsHooks.beforeOpen = null;
      await rename(root, oldRoot);
      await mkdir(join(root, UPLOAD_OWNERS_DIR), { recursive: true });
      await writeFile(join(root, name), victim);
      throw Object.assign(new Error("injected sidecar failure"), { code: "ENOSPC" });
    };
    expect(await createOwnedUpload({ ownerId: OWNER_A, bytes: PNG_BYTES, declaredMime: "image/png",
      declaredFilename: "photo.png", root, generateFilename: () => name })).toEqual({ ok: false, code: "io-error" });
    expect(await readFile(join(root, name))).toEqual(victim);
    expect(await readFile(join(oldRoot, name))).toEqual(PNG_BYTES);
    expect(await readdir(join(root, UPLOAD_OWNERS_DIR))).toEqual([]);
  });
});



// ── Read path ─────────────────────────────────────────────────────────────────

describe("readOwnedUpload", () => {
  it("returns the exact original bytes to the recorded owner", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    const read = await readOk({ filename: created.record.filename, requesterId: OWNER_A, root });
    expect(Buffer.compare(read.bytes, PNG_BYTES)).toBe(0);
    expect(read.record.sha256).toBe(sha256(PNG_BYTES));
    expect(read.record.size).toBe(PNG_BYTES.length);
  });

  it("denies a different account even when it knows the exact filename", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    const denied = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_B,
      root,
    });
    expect(denied).toEqual({ ok: false, reason: "owner-mismatch" });
  });

  it("denies legacy ownerless files that predate the index", async () => {
    await mkdir(root, { recursive: true });
    const name = makeName();
    await writeFile(join(root, name), PNG_BYTES);

    const denied = await readOwnedUpload({ filename: name, requesterId: OWNER_A, root });
    expect(denied).toEqual({ ok: false, reason: "missing" });
  });

  it("denies unknown filenames with the same denial shape", async () => {
    const denied = await readOwnedUpload({ filename: makeName(), requesterId: OWNER_A, root });
    expect(denied).toEqual({ ok: false, reason: "missing" });
  });

  it("denies traversal, dotfile, index, and non-canonical names", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });
    const name = created.record.filename;

    const names = [
      `../${name}`,
      "..",
      ".",
      "",
      ".env",
      UPLOAD_OWNERS_DIR,
      `${UPLOAD_OWNERS_DIR}/${name}.json`,
      `sub/${name}`,
      `sub\\${name}`,
      `${name}\0.png`,
      name.toUpperCase(),
      `${randomUUID()}.${"x".repeat(17)}`,
      "%2e%2e%2fetc%2fpasswd",
      `${name}/`,
    ];
    for (const bad of names) {
      const denied = await readOwnedUpload({ filename: bad, requesterId: OWNER_A, root });
      expect(denied.ok, `expected denial for ${JSON.stringify(bad)}`).toBe(false);
    }
  });

  it("classifies canonical filenames strictly", () => {
    expect(isCanonicalUploadFilename(`${randomUUID()}.png`)).toBe(true);
    expect(isCanonicalUploadFilename(randomUUID())).toBe(true);
    expect(isCanonicalUploadFilename(`${randomUUID()}.png.json`)).toBe(false);
    expect(isCanonicalUploadFilename(`${randomUUID()}.PNG/x`)).toBe(false);
    expect(isCanonicalUploadFilename(".owners")).toBe(false);
    expect(isCanonicalUploadFilename(`${randomUUID()}.`)).toBe(false);
    expect(isCanonicalUploadFilename(`${randomUUID()}.png `)).toBe(false);
  });

  it("denies when the blob bytes no longer match the indexed digest or size", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    await writeFile(join(root, created.record.filename), Buffer.from("swapped bytes"));
    const denied = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(denied).toEqual({ ok: false, reason: "tamper" });
  });

  it("denies when the indexed digest, size, version, filename, or content type is tampered", async () => {
    const fields: Array<[string, (record: Record<string, unknown>) => void]> = [
      ["sha256", (r) => { r.sha256 = sha256(Buffer.from("attacker-controlled")); }],
      ["size", (r) => { r.size = 3; }],
      ["version", (r) => { r.version = 2; }],
      ["filename", (r) => { r.filename = makeName(); }],
      ["content_type", (r) => { r.content_type = "text/html\r\nX: y"; }],
    ];

    for (const [label, mutate] of fields) {
      const created = await createOk({
        ownerId: OWNER_A,
        bytes: PNG_BYTES,
        declaredMime: "image/png",
        declaredFilename: "photo.png",
        root,
      });
      const sidecarPath = join(root, UPLOAD_OWNERS_DIR, `${created.record.filename}.json`);
      const record = JSON.parse(await readFile(sidecarPath, "utf8")) as Record<string, unknown>;
      mutate(record);
      await writeFile(sidecarPath, JSON.stringify(record));

      const denied = await readOwnedUpload({
        filename: created.record.filename,
        requesterId: OWNER_A,
        root,
      });
      expect(denied.ok, `expected denial for tampered ${label}`).toBe(false);
      await rm(join(root, created.record.filename), { force: true });
      await rm(sidecarPath, { force: true });
    }
  });

  it("denies corrupt, oversized, and non-JSON sidecars", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });
    const sidecarPath = join(root, UPLOAD_OWNERS_DIR, `${created.record.filename}.json`);

    await writeFile(sidecarPath, "not json at all {");
    expect(
      await readOwnedUpload({ filename: created.record.filename, requesterId: OWNER_A, root })
    ).toEqual({ ok: false, reason: "tamper" });

    await writeFile(sidecarPath, JSON.stringify({ padding: "x".repeat(8192) }));
    expect(
      await readOwnedUpload({ filename: created.record.filename, requesterId: OWNER_A, root })
    ).toEqual({ ok: false, reason: "tamper" });
  });

  it("denies a symlinked blob even when its bytes are valid", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });
    const blobPath = join(root, created.record.filename);
    const copyPath = join(base, "outside.png");
    await writeFile(copyPath, PNG_BYTES);
    await unlink(blobPath);
    await symlink(copyPath, blobPath);

    const denied = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(denied.ok).toBe(false);
  });

  it("denies hardlinked blobs (nlink > 1)", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });
    await link(join(root, created.record.filename), join(base, "hardlink.png"));

    const denied = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(denied).toEqual({ ok: false, reason: "tamper" });
  });

  it("denies non-regular blob paths", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });
    const blobPath = join(root, created.record.filename);
    await unlink(blobPath);
    await mkdir(blobPath);

    const denied = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(denied.ok).toBe(false);
  });

  it("denies reads through a symlinked uploads root or symlinked .owners root", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    // uploads root replaced by a symlink to the real root.
    const aliasRoot = join(base, "alias-uploads");
    await symlink(root, aliasRoot);
    const viaAlias = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root: aliasRoot,
    });
    expect(viaAlias).toEqual({ ok: false, reason: "invalid-root" });

    // .owners replaced by a symlink to the real owners dir.
    const ownersReal = join(base, "owners-real");
    await rename(join(root, UPLOAD_OWNERS_DIR), ownersReal);
    await symlink(ownersReal, join(root, UPLOAD_OWNERS_DIR));
    const viaOwnersAlias = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(viaOwnersAlias).toEqual({ ok: false, reason: "invalid-root" });
  });

  it("rejects non-UUID requesters", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });
    const denied = await readOwnedUpload({
      filename: created.record.filename,
      requesterId: "not-a-uuid",
      root,
    });
    expect(denied).toEqual({ ok: false, reason: "invalid-requester" });
  });

  it("reloads ownership from disk on every read (restart-safe, no cache)", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: PNG_BYTES,
      declaredMime: "image/png",
      declaredFilename: "photo.png",
      root,
    });

    // A brand-new module instance (simulating a fresh process) reads the index
    // straight from disk.
    vi.resetModules();
    const fresh = await import("../local-uploads");
    const first = await fresh.readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(first.ok).toBe(true);

    // Disk is the source of truth: tampering between calls is observed at once.
    await writeFile(join(root, created.record.filename), Buffer.from("mutated"));
    const second = await fresh.readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(second).toEqual({ ok: false, reason: "tamper" });

    // Ownership removal on disk also takes effect immediately.
    await writeFile(
      join(root, UPLOAD_OWNERS_DIR, `${created.record.filename}.json`),
      JSON.stringify({ ...created.record, owner_id: OWNER_B })
    );
    await writeFile(join(root, created.record.filename), PNG_BYTES);
    const third = await fresh.readOwnedUpload({
      filename: created.record.filename,
      requesterId: OWNER_A,
      root,
    });
    expect(third).toEqual({ ok: false, reason: "owner-mismatch" });
  });

  it("serves empty files as opaque attachments with matching digest", async () => {
    const created = await createOk({
      ownerId: OWNER_A,
      bytes: new Uint8Array(0),
      declaredMime: "text/plain",
      declaredFilename: "empty.txt",
      root,
    });
    const read = await readOk({ filename: created.record.filename, requesterId: OWNER_A, root });
    expect(read.bytes.length).toBe(0);
    expect(read.delivery).toEqual({ kind: "attachment", contentType: "application/octet-stream" });
  });
});

// ── Delivery classification (magic bytes, never claimed MIME) ─────────────────

describe("classifyUploadDelivery", () => {
  it("inlines only magic-byte-validated raster JPEG/PNG", () => {
    expect(classifyUploadDelivery(PNG_BYTES)).toEqual({
      kind: "inline",
      contentType: "image/png",
    });
    expect(classifyUploadDelivery(JPEG_BYTES)).toEqual({
      kind: "inline",
      contentType: "image/jpeg",
    });
  });

  it("forces attachment with an opaque type for active or unvalidated content", () => {
    const attachment = { kind: "attachment", contentType: "application/octet-stream" };
    expect(classifyUploadDelivery(SVG_BYTES)).toEqual(attachment);
    expect(classifyUploadDelivery(HTML_BYTES)).toEqual(attachment);
    expect(classifyUploadDelivery(Buffer.from("plain text", "utf8"))).toEqual(attachment);
    expect(classifyUploadDelivery(Buffer.from("GIF89a...", "utf8"))).toEqual(attachment);
    expect(classifyUploadDelivery(Buffer.from("<script>alert(1)</script>", "utf8"))).toEqual(attachment);
    expect(classifyUploadDelivery(new Uint8Array(0))).toEqual(attachment);
  });

  it("does not treat spoofed extensions or claimed MIME as safe", () => {
    // A file named .png whose bytes are HTML is still forced to attachment.
    const spoofed = classifyUploadDelivery(HTML_BYTES);
    expect(spoofed.kind).toBe("attachment");

    // PNG magic is honored even if the caller claimed text/plain.
    expect(classifyUploadDelivery(PNG_BYTES).kind).toBe("inline");
  });
});


describe("actual directory swaps and FIFO reads", () => {
  it.each(["root", "owners"])("rejects same-content replacement %s directory during read", async (which) => {
    const created = await createOk({ ownerId: OWNER_A, bytes: PNG_BYTES,
      declaredMime: "image/png", declaredFilename: "photo.png", root });
    const name = created.record.filename;
    const sidecar = await readFile(join(root, UPLOAD_OWNERS_DIR, `${name}.json`));
    fsHooks.beforeOpen = async (path) => {
      if (path !== join(root, name)) return;
      fsHooks.beforeOpen = null;
      if (which === "root") {
        await rename(root, join(base, "old-store"));
        await mkdir(join(root, UPLOAD_OWNERS_DIR), { recursive: true });
        await writeFile(join(root, name), PNG_BYTES);
      } else {
        await rename(join(root, UPLOAD_OWNERS_DIR), join(base, "old-owners"));
        await mkdir(join(root, UPLOAD_OWNERS_DIR));
      }
      await writeFile(join(root, UPLOAD_OWNERS_DIR, `${name}.json`), sidecar);
    };
    expect(await readOwnedUpload({ filename: name, requesterId: OWNER_A, root }))
      .toEqual({ ok: false, reason: "invalid-root" });
    expect(await readFile(join(root, name))).toEqual(PNG_BYTES);
    expect(await readFile(join(root, UPLOAD_OWNERS_DIR, `${name}.json`))).toEqual(sidecar);
  });

  it.each(["blob", "sidecar"])("rejects actual %s FIFO without waiting for a writer", async (which) => {
    const created = await createOk({ ownerId: OWNER_A, bytes: PNG_BYTES,
      declaredMime: "image/png", declaredFilename: "photo.png", root });
    const name = created.record.filename;
    const path = which === "blob" ? join(root, name) : join(root, UPLOAD_OWNERS_DIR, `${name}.json`);
    await unlink(path);
    execFileSync("mkfifo", [path]);
    const started = performance.now();
    expect((await readOwnedUpload({ filename: name, requesterId: OWNER_A, root })).ok).toBe(false);
    expect(performance.now() - started).toBeLessThan(1000);
  }, 2000);
});
