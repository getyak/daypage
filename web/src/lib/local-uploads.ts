// Private local-upload ownership index.
//
// `POST /api/upload` stores blobs under `uploads/` with a server-generated
// `randomUUID()` basename. Previously nothing recorded who uploaded the file,
// so no safe GET was possible. This module adds a private v1 sidecar index at
// `uploads/.owners/<filename>.json` binding the exact filename to the trusted
// internal `users.id` (resolved server-side from the authenticated email), the
// byte size, the SHA256 of the content, and a sanitized content type.
//
// Safety rules enforced here (see docs/engineering/web-upload-ownership.md):
// - The owner comes only from the caller-resolved `users.id`; no request field,
//   memo attachment `storage_key`, or join is ever consulted for ownership.
// - Blobs and sidecars are created exclusively (`O_EXCL`) for a fresh generated
//   UUID; partial/crash failures fail closed and clean up ONLY files created by
//   the current call. Older, unowned, or colliding paths are never touched.
// - Reads validate the canonical generated basename (UUID + safe extension),
//   reject traversal/dotfiles/index paths/symlinks/non-regular files/hardlinks,
//   open with `O_NOFOLLOW`, enforce bounded sizes, and verify the indexed size
//   and SHA256 against the actual bytes before anything is served.
// - There is no module-level owner cache: every read consults the disk index,
//   so a process restart cannot serve stale ownership.
// - Nothing in this module is reachable from an HTTP caller directly; the
//   optional `root`/`generateFilename` overrides exist only so tests can run
//   against trusted temporary directories.

import { createHash, randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import { mkdir, lstat, open, realpath, unlink } from "node:fs/promises";
import { basename, dirname, extname, join, resolve } from "node:path";

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
export const UPLOAD_OWNERS_DIR = ".owners";
export const OWNERSHIP_INDEX_VERSION = 1;

/** Upper bound for the serialized sidecar; larger files are treated as tampered. */
const MAX_INDEX_BYTES = 4096;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CANONICAL_FILENAME_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?:\.[A-Za-z0-9]{1,16})?$/;
const SAFE_EXTENSION_PATTERN = /^\.[A-Za-z0-9]{1,16}$/;
const SAFE_CONTENT_TYPE_PATTERN = /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/;
const SHA256_HEX_PATTERN = /^[0-9a-f]{64}$/;

const FALLBACK_CONTENT_TYPE = "application/octet-stream";

/** Trusted v1 ownership record persisted at `uploads/.owners/<filename>.json`. */
export interface OwnedUploadRecord {
  version: typeof OWNERSHIP_INDEX_VERSION;
  filename: string;
  owner_id: string;
  size: number;
  sha256: string;
  content_type: string;
}

/**
 * Delivery decision for served bytes. Only magic-byte-validated raster
 * JPEG/PNG may be inlined; everything else (including SVG/HTML/text and any
 * content whose bytes do not match a safe raster signature) is served as a
 * forced download with a sandbox CSP and a generic binary content type.
 */
export type UploadDelivery =
  | { kind: "inline"; contentType: "image/jpeg" | "image/png" }
  | { kind: "attachment"; contentType: "application/octet-stream" };

export type CreateOwnedUploadErrorCode =
  | "invalid-owner"
  | "invalid-size"
  | "invalid-filename"
  | "invalid-root"
  | "collision"
  | "io-error";

export type CreateOwnedUploadResult =
  | { ok: true; record: OwnedUploadRecord; url: string }
  | { ok: false; code: CreateOwnedUploadErrorCode };

export type ReadOwnedUploadDenialReason =
  | "invalid-filename"
  | "invalid-requester"
  | "invalid-root"
  | "missing"
  | "tamper"
  | "owner-mismatch"
  | "io-error";

export type ReadOwnedUploadResult =
  | { ok: true; record: OwnedUploadRecord; bytes: Buffer; delivery: UploadDelivery }
  | { ok: false; reason: ReadOwnedUploadDenialReason };

export interface CreateOwnedUploadInput {
  /** Trusted internal `users.id` resolved server-side from the session email. */
  ownerId: string;
  bytes: Uint8Array;
  /** Claimed client MIME; sanitized before it is recorded, never trusted for delivery. */
  declaredMime: string;
  /** Client filename; only a safe ASCII extension suffix is ever reused. */
  declaredFilename: string;
  /** Trusted test-only override for the uploads directory. HTTP callers cannot choose this. */
  root?: string;
  /** Trusted test-only filename generator (for collision tests). HTTP callers cannot choose this. */
  generateFilename?: () => string;
}

export interface ReadOwnedUploadInput {
  /** Raw route parameter; must be the strict canonical generated basename. */
  filename: string;
  /** Trusted internal `users.id` of the requester. */
  requesterId: string;
  /** Trusted test-only override for the uploads directory. HTTP callers cannot choose this. */
  root?: string;
}

interface UploadPaths {
  root: string;
  ownersRoot: string;
  blobPath: string;
  ownersPath: string;
}

// ── Validation helpers ────────────────────────────────────────────────────────

function isUuid(value: string): boolean {
  return UUID_PATTERN.test(value);
}

export function isCanonicalUploadFilename(filename: string): boolean {
  return (
    filename === basename(filename) &&
    filename !== "." &&
    filename !== ".." &&
    !filename.startsWith(".") &&
    !filename.includes("\0") &&
    CANONICAL_FILENAME_PATTERN.test(filename)
  );
}

/** Only `.<alnum 1-16>` extensions survive; anything else is dropped. */
function safeExtensionSuffix(declaredFilename: string): string {
  const ext = extname(declaredFilename);
  return SAFE_EXTENSION_PATTERN.test(ext) ? ext : "";
}

/** Lowercased, parameter-stripped MIME that must match a safe token shape. */
function sanitizeContentType(declaredMime: string): string {
  const base = declaredMime.split(";", 1)[0].trim().toLowerCase();
  return SAFE_CONTENT_TYPE_PATTERN.test(base) ? base : FALLBACK_CONTENT_TYPE;
}

function isSafeContentType(value: unknown): value is string {
  return typeof value === "string" && SAFE_CONTENT_TYPE_PATTERN.test(value);
}

function isSha256Hex(value: unknown): value is string {
  return typeof value === "string" && SHA256_HEX_PATTERN.test(value);
}

function parseIndexRecord(raw: string, filename: string): OwnedUploadRecord | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const candidate = parsed as Record<string, unknown>;
  if (candidate.version !== OWNERSHIP_INDEX_VERSION) return null;
  if (candidate.filename !== filename) return null;
  if (typeof candidate.owner_id !== "string" || !isUuid(candidate.owner_id)) return null;
  if (
    typeof candidate.size !== "number" ||
    !Number.isSafeInteger(candidate.size) ||
    candidate.size < 0 ||
    candidate.size > MAX_UPLOAD_BYTES
  ) {
    return null;
  }
  if (!isSha256Hex(candidate.sha256)) return null;
  if (!isSafeContentType(candidate.content_type)) return null;
  return {
    version: OWNERSHIP_INDEX_VERSION,
    filename: candidate.filename,
    owner_id: candidate.owner_id,
    size: candidate.size,
    sha256: candidate.sha256,
    content_type: candidate.content_type,
  };
}

// ── Filesystem helpers ────────────────────────────────────────────────────────

function uploadPathsFor(root: string, filename: string): UploadPaths {
  const resolvedRoot = resolve(root);
  return {
    root: resolvedRoot,
    ownersRoot: join(resolvedRoot, UPLOAD_OWNERS_DIR),
    blobPath: join(resolvedRoot, filename),
    ownersPath: join(resolvedRoot, UPLOAD_OWNERS_DIR, `${filename}.json`),
  };
}

interface DirectoryIdentity { path: string; dev: number; ino: number }
interface StoreIdentity {
  parent: DirectoryIdentity;
  root: DirectoryIdentity;
  owners: DirectoryIdentity;
}
interface CreatedFileIdentity { dev: number; ino: number; size: number; sha256: string }
const READ_FLAGS = fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | fsConstants.O_NONBLOCK;

// Reject aliases in ancestor components as well as the final component.
async function directoryIdentity(path: string): Promise<DirectoryIdentity | null> {
  let fd: FileHandle | undefined;
  try {
    if (await realpath(path) !== path) return null;
    const entry = await lstat(path);
    if (!entry.isDirectory()) return null;
    fd = await open(path, READ_FLAGS);
    const actual = await fd.stat();
    if (!actual.isDirectory() || actual.dev !== entry.dev || actual.ino !== entry.ino) return null;
    if (await realpath(path) !== path) return null;
    return { path, dev: actual.dev, ino: actual.ino };
  } catch {
    return null;
  } finally {
    await fd?.close().catch(() => undefined);
  }
}

async function sameDirectory(expected: DirectoryIdentity): Promise<boolean> {
  const now = await directoryIdentity(expected.path);
  return now !== null && now.dev === expected.dev && now.ino === expected.ino;
}

async function sameStore(store: StoreIdentity): Promise<boolean> {
  return await sameDirectory(store.parent) && await sameDirectory(store.root) && await sameDirectory(store.owners);
}

type RootState = "dir" | "missing" | "hostile";

async function rootEntryState(path: string): Promise<RootState> {
  try {
    const st = await lstat(path);
    return st.isDirectory() ? "dir" : "hostile";
  } catch (err) {
    return (err as NodeJS.ErrnoException | null)?.code === "ENOENT" ? "missing" : "hostile";
  }
}

/**
 * Symlinked (or otherwise non-directory) roots are hostile and fail closed;
 * an absent store simply has nothing indexed yet.
 */
async function captureStore(paths: UploadPaths, create: boolean): Promise<StoreIdentity | "missing" | "invalid-root"> {
  const parent = await directoryIdentity(dirname(paths.root));
  if (!parent) return "invalid-root";
  async function child(path: string, ancestor: DirectoryIdentity) {
    const state = await rootEntryState(path);
    if (state === "hostile") return "invalid-root" as const;
    if (state === "missing") {
      if (!create) return "missing" as const;
      if (!await sameDirectory(ancestor)) return "invalid-root" as const;
      try {
        await mkdir(path, { mode: 0o700 });
      } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code !== "EEXIST") throw error;
      }
    }
    const identity = await directoryIdentity(path);
    if (!identity || !await sameDirectory(ancestor)) return "invalid-root" as const;
    return identity;
  }
  const root = await child(paths.root, parent);
  if (typeof root === "string") return root;
  const owners = await child(paths.ownersRoot, root);
  if (typeof owners === "string") return owners;
  const store = { parent, root, owners };
  return await sameStore(store) ? store : "invalid-root";
}

function isContained(paths: UploadPaths, filename: string): boolean {
  return (
    dirname(paths.blobPath) === paths.root &&
    dirname(paths.ownersPath) === paths.ownersRoot &&
    basename(paths.blobPath) === filename &&
    resolve(paths.blobPath).startsWith(paths.root) &&
    resolve(paths.ownersPath).startsWith(paths.ownersRoot)
  );
}

async function syncDirectory(dir: DirectoryIdentity): Promise<void> {
  const handle = await open(dir.path, READ_FLAGS);
  try {
    const actual = await handle.stat();
    if (!actual.isDirectory() || actual.dev !== dir.dev || actual.ino !== dir.ino) throw new Error("store changed");
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function writeAll(handle: FileHandle, data: Uint8Array): Promise<void> {
  let written = 0;
  while (written < data.length) {
    const res = await handle.write(data, written, data.length - written, null);
    if (res.bytesWritten <= 0) throw new Error("short write");
    written += res.bytesWritten;
  }
}

/** Read exactly `size` bytes at position 0 and require EOF there. */
async function readExact(handle: FileHandle, size: number): Promise<Buffer | null> {
  const buf = Buffer.alloc(size);
  let read = 0;
  while (read < size) {
    const res = await handle.read(buf, read, size - read, read);
    if (res.bytesRead <= 0) return null;
    read += res.bytesRead;
  }
  const tail = Buffer.alloc(1);
  const extra = await handle.read(tail, 0, 1, size);
  return extra.bytesRead === 0 ? buf : null;
}

async function safeUnlinkOwned(path: string, proof: CreatedFileIdentity, store: StoreIdentity): Promise<void> {
  let fd: FileHandle | undefined;
  try {
    if (!await sameStore(store)) return;
    const entry = await lstat(path);
    if (!entry.isFile() || entry.dev !== proof.dev || entry.ino !== proof.ino || entry.nlink !== 1 || entry.size !== proof.size) return;
    fd = await open(path, READ_FLAGS);
    const actual = await fd.stat();
    if (!actual.isFile() || actual.dev !== proof.dev || actual.ino !== proof.ino || actual.nlink !== 1 || actual.size !== proof.size) return;
    const bytes = await readExact(fd, proof.size);
    if (!bytes || createHash("sha256").update(bytes).digest("hex") !== proof.sha256) return;
    await fd.close();
    fd = undefined;
    if (!await sameStore(store)) return;
    const current = await lstat(path);
    if (!current.isFile() || current.dev !== proof.dev || current.ino !== proof.ino || current.nlink !== 1 || current.size !== proof.size) return;
    await unlink(path);
  } catch {
    // Keep unproven, changed or partially written files. This is not atomic
    // unlink-by-inode against hostile concurrent filesystem writers: the store
    // must remain private to the trusted server process.
  } finally {
    await fd?.close().catch(() => undefined);
  }
}

function errorCode(err: unknown): CreateOwnedUploadErrorCode {
  const code = (err as NodeJS.ErrnoException | null)?.code;
  return code === "EEXIST" ? "collision" : "io-error";
}

// ── Delivery classification (magic bytes only) ────────────────────────────────

function detectRasterType(bytes: Uint8Array): "image/jpeg" | "image/png" | null {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return "image/png";
  }
  if (
    bytes.length >= 3 &&
    bytes[0] === 0xff &&
    bytes[1] === 0xd8 &&
    bytes[2] === 0xff
  ) {
    return "image/jpeg";
  }
  return null;
}

/**
 * Decide how bytes may be delivered. Only magic-byte-validated raster JPEG/PNG
 * is inlined; claimed client MIME and file extensions are never consulted.
 */
export function classifyUploadDelivery(bytes: Uint8Array): UploadDelivery {
  const raster = detectRasterType(bytes);
  if (raster) return { kind: "inline", contentType: raster };
  return { kind: "attachment", contentType: FALLBACK_CONTENT_TYPE };
}

// ── Write path ────────────────────────────────────────────────────────────────

/**
 * Exclusively create a new blob + ownership sidecar and fsync both before the
 * caller may report success. Failures fail closed and clean up only files this
 * call created; colliding or older paths are never deleted or rewritten.
 */
export async function createOwnedUpload(
  input: CreateOwnedUploadInput
): Promise<CreateOwnedUploadResult> {
  if (!isUuid(input.ownerId)) return { ok: false, code: "invalid-owner" };
  if (input.bytes.length > MAX_UPLOAD_BYTES) {
    return { ok: false, code: "invalid-size" };
  }

  const filename = input.generateFilename
    ? input.generateFilename()
    : `${randomUUID()}${safeExtensionSuffix(input.declaredFilename)}`;
  if (!isCanonicalUploadFilename(filename)) {
    return { ok: false, code: "invalid-filename" };
  }

  const paths = uploadPathsFor(input.root ?? join(process.cwd(), "uploads"), filename);
  if (!isContained(paths, filename)) return { ok: false, code: "invalid-filename" };

  let store: StoreIdentity;
  try {
    const captured = await captureStore(paths, true);
    if (typeof captured === "string") return { ok: false, code: "invalid-root" };
    store = captured;
  } catch {
    return { ok: false, code: "io-error" };
  }

  const record: OwnedUploadRecord = {
    version: OWNERSHIP_INDEX_VERSION,
    filename,
    owner_id: input.ownerId,
    size: input.bytes.length,
    sha256: createHash("sha256").update(input.bytes).digest("hex"),
    content_type: sanitizeContentType(input.declaredMime),
  };

  let blobProof: CreatedFileIdentity | undefined;
  let ownersProof: CreatedFileIdentity | undefined;
  const indexBytes = Buffer.from(`${JSON.stringify(record)}\n`, "utf8");

  try {
    // Blob first: `O_EXCL` guarantees we never adopt or overwrite a colliding
    // path, and `O_NOFOLLOW` refuses a symlink planted at the destination.
    if (!await sameStore(store)) throw new Error("store changed");
    const blob = await open(
      paths.blobPath,
      fsConstants.O_WRONLY |
        fsConstants.O_CREAT |
        fsConstants.O_EXCL |
        fsConstants.O_NOFOLLOW,
      0o600
    );
    try {
      const st = await blob.stat();
      blobProof = { dev: st.dev, ino: st.ino, size: input.bytes.length, sha256: record.sha256 };
      await writeAll(blob, input.bytes);
      await blob.sync();
    } finally {
      await blob.close();
    }

    // Ownership record second, also exclusively.
    if (!await sameStore(store)) throw new Error("store changed");
    const owners = await open(
      paths.ownersPath,
      fsConstants.O_WRONLY |
        fsConstants.O_CREAT |
        fsConstants.O_EXCL |
        fsConstants.O_NOFOLLOW,
      0o600
    );
    try {
      const st = await owners.stat();
      ownersProof = { dev: st.dev, ino: st.ino, size: indexBytes.length, sha256: createHash("sha256").update(indexBytes).digest("hex") };
      await writeAll(owners, indexBytes);
      await owners.sync();
    } finally {
      await owners.close();
    }

    // Directory entries must be durable before the caller may return success.
    if (!await sameStore(store)) throw new Error("store changed");
    await syncDirectory(store.root);
    await syncDirectory(store.owners);
    if (!await sameStore(store)) throw new Error("store changed");

    return { ok: true, record, url: `/uploads/${filename}` };
  } catch (err) {
    // Fail closed. Clean up ONLY just-created, still-owned files; never delete
    // or rewrite older/unowned/colliding paths.
    if (ownersProof) await safeUnlinkOwned(paths.ownersPath, ownersProof, store);
    if (blobProof) await safeUnlinkOwned(paths.blobPath, blobProof, store);
    return { ok: false, code: errorCode(err) };
  }
}

// ── Read path ─────────────────────────────────────────────────────────────────

/**
 * Serve a stored upload to its recorded owner only. Every failure mode returns
 * `{ ok: false }` so HTTP callers can answer with one uniform 404.
 */
export async function readOwnedUpload(
  input: ReadOwnedUploadInput
): Promise<ReadOwnedUploadResult> {
  const { filename, requesterId } = input;
  if (!isCanonicalUploadFilename(filename)) {
    return { ok: false, reason: "invalid-filename" };
  }
  if (!isUuid(requesterId)) return { ok: false, reason: "invalid-requester" };

  const paths = uploadPathsFor(input.root ?? join(process.cwd(), "uploads"), filename);
  if (!isContained(paths, filename)) return { ok: false, reason: "invalid-filename" };
  const store = await captureStore(paths, false);
  if (typeof store === "string") return { ok: false, reason: store };

  // Ownership index first: bounded read, `O_NOFOLLOW`, strict schema.
  let record: OwnedUploadRecord | null = null;
  try {
    if (!await sameStore(store)) return { ok: false, reason: "invalid-root" };
    const owners = await open(paths.ownersPath, READ_FLAGS);
    try {
      const st = await owners.stat();
      if (!st.isFile() || st.nlink !== 1 || st.size <= 0 || st.size > MAX_INDEX_BYTES) {
        return { ok: false, reason: "tamper" };
      }
      const raw = await readExact(owners, st.size);
      if (raw === null) return { ok: false, reason: "tamper" };
      record = parseIndexRecord(raw.toString("utf8"), filename);
    } finally {
      await owners.close();
    }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | null)?.code;
    return { ok: false, reason: code === "ENOENT" ? "missing" : "io-error" };
  }
  if (!record) return { ok: false, reason: "tamper" };

  // Ownership is exactly the recorded trusted profile id; nothing else (memo
  // attachments, storage keys, request fields) can ever grant access.
  if (record.owner_id !== requesterId) return { ok: false, reason: "owner-mismatch" };

  // Blob next: regular file only, single link, indexed size and digest must
  // match the actual bytes read through the `O_NOFOLLOW` descriptor.
  let bytes: Buffer;
  try {
    if (!await sameStore(store)) return { ok: false, reason: "invalid-root" };
    const blob = await open(paths.blobPath, READ_FLAGS);
    try {
      const st = await blob.stat();
      if (
        !st.isFile() ||
        st.nlink !== 1 ||
        st.size > MAX_UPLOAD_BYTES ||
        st.size !== record.size
      ) {
        return { ok: false, reason: "tamper" };
      }
      const read = await readExact(blob, record.size);
      if (read === null) return { ok: false, reason: "tamper" };
      const digest = createHash("sha256").update(read).digest("hex");
      if (digest !== record.sha256) return { ok: false, reason: "tamper" };
      bytes = read;
    } finally {
      await blob.close();
    }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | null)?.code;
    return { ok: false, reason: code === "ENOENT" ? "missing" : "io-error" };
  }

  // Re-verify root containment after the descriptor reads; a root swapped for a
  // symlink mid-request must fail closed.
  if (!await sameStore(store)) return { ok: false, reason: "invalid-root" };

  return { ok: true, record, bytes, delivery: classifyUploadDelivery(bytes) };
}
