import { parseManifest, parseRecords, reject, validDay } from "./contract.ts";
import type { ExchangeFile, ExchangeManifest, ExchangeRecords } from "./contract.ts";
import { validateNoteProjection } from "./note-projection.ts";
import { validateReviewProjection } from "./review-projection.ts";
import { hasPrefix } from "./memo-codec.ts";

export const EXCHANGE_LIMITS = Object.freeze({
  manifest: 256 * 1024, records: 16 * 1024 * 1024,
  total: 50 * 1024 * 1024, files: 1000, attachment: 25 * 1024 * 1024,
});
const encoder = new TextEncoder();
export interface ExchangeInputFile {
  path: string;
  size: number;
  read(): Promise<Uint8Array>;
}
export interface ExchangePreview {
  manifest: ExchangeManifest;
  /** Exact selected manifest bytes, including metadata outside content_sha256. */
  manifestBytes: Uint8Array;
  records: ExchangeRecords;
  bytes: number;
  /** Validated bytes only; nothing is uploaded or persisted by this module. */
  files: ReadonlyMap<string, Uint8Array>;
  reviewSources: { generationId: string; current: number; changed: number; unavailable: number }[];
}

function current(signal?: AbortSignal) { signal?.throwIfAborted(); }
export async function sha256(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes).buffer);
  return Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, "0")).join("");
}
function utf8Order(a: string, b: string) {
  const x = encoder.encode(a), y = encoder.encode(b);
  for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i];
  return x.length - y.length;
}
export async function contentDigest(manifest: Pick<ExchangeManifest, "format" | "notes_count" | "reviews_count" | "files">) {
  const lines = [...manifest.files].sort((a, b) => utf8Order(a.path, b.path))
    .map(file => `${file.path}\0${file.kind}\0${file.bytes}\0${file.sha256}`);
  return sha256(encoder.encode(`${manifest.format}\n${manifest.notes_count}\0${manifest.reviews_count}\n${lines.join("\n")}`));
}

function safePath(value: string): boolean {
  return value.length > 0 && value.length <= 512 && encoder.encode(value).byteLength <= 512 && !/[\\\u0000-\u001f\u007f-\u009f]/.test(value) &&
    !value.startsWith("/") && !value.includes(":") &&
    value.split("/").every(part => part !== "" && part !== "." && part !== "..");
}
function namespace(value: string): boolean {
  if (value === "") return true;
  const parts = value.split("/");
  return parts.length % 2 === 0 && parts.every((part, index) => index % 2 === 0 ? part === "imports" : uuid(part));
}
function uuid(value: string) { return /^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(value); }
function prefix(value: string) { return value === "" ? "" : value + "/"; }
function foldedPath(value: string) { return value.normalize("NFC").toLowerCase(); }
function filePath(file: ExchangeFile): boolean {
  if (!safePath(file.path)) return false;
  if (file.kind === "records") return file.path === "records.json";
  const parts = file.path.split("/");
  while (parts[0] === "imports") {
    if (!uuid(parts[1] ?? "")) return false;
    parts.splice(0, 2);
  }
  if (file.kind === "asset") return parts.length >= 3 && parts[0] === "raw" && parts[1] === "assets" && hasPrefix(parts.join("/"), "raw/assets/");
  if (file.kind === "raw") return parts.length === 2 && parts[0] === "raw" && /^\d{4}-\d{2}-\d{2}\.md$/.test(parts[1]) && validDay(parts[1].slice(0, -3));
  return file.kind === "review" && parts.length === 3 && parts[0] === "wiki" && parts[1] === "manual-reviews" && parts[2].endsWith(".md") && uuid(parts[2].slice(0, -3));
}
function decode(bytes: Uint8Array): unknown {
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { return reject("Invalid UTF-8 JSON"); }
}
async function read(file: ExchangeInputFile, limit: number, signal?: AbortSignal) {
  current(signal);
  if (!Number.isSafeInteger(file.size) || file.size < 0 || file.size > limit) reject("File exceeds exchange limit");
  const bytes = await file.read();
  current(signal);
  if (!(bytes instanceof Uint8Array) || bytes.byteLength !== file.size || bytes.byteLength > limit) reject("Selected file changed");
  return bytes;
}

function validateReferences(manifest: ExchangeManifest, records: ExchangeRecords) {
  if (manifest.notes_count !== records.notes.length || manifest.reviews_count !== records.reviews.length ||
      records.notes.length + records.reviews.length === 0) reject("Record counts do not match");
  const listed = new Map(manifest.files.map(file => [file.path, file]));
  const identities = new Set<string>();
  const referenced = { records: new Set(["records.json"]), raw: new Set<string>(), asset: new Set<string>(), review: new Set<string>() };
  for (const note of records.notes) {
    if (!namespace(note.namespace) || !validDay(note.day)) reject("Invalid note source");
    const identity = `note:${note.namespace.toLowerCase()}:${note.original_id.toLowerCase()}`;
    if (identities.has(identity)) reject("Duplicate source identity");
    identities.add(identity);
    const raw = `${prefix(note.namespace)}raw/${note.day}.md`;
    if (listed.get(raw)?.kind !== "raw") reject("Missing canonical note file");
    referenced.raw.add(raw);
    if (encoder.encode(note.body).length > 4 * 1024 * 1024) reject("Note text exceeds exchange limit");
    if (note.location && (note.location.lat === undefined) !== (note.location.lng === undefined)) reject("Invalid location coordinates");
    for (const item of note.attachments) {
      if (item.transcript !== undefined && encoder.encode(item.transcript).length > 4 * 1024 * 1024) reject("Transcript text exceeds exchange limit");
      const file = listed.get(item.file);
      if (!hasPrefix(item.file, `${prefix(note.namespace)}raw/assets/`) || !file || file.kind !== "asset" ||
          file.sha256 !== item.sha256 || file.bytes !== item.bytes) reject("Attachment does not match manifest");
      referenced.asset.add(item.file);
    }
  }
  for (const review of records.reviews) {
    const folder = `${prefix(review.namespace)}wiki/manual-reviews/`;
    const fileID = review.file.startsWith(folder) && review.file.endsWith(".md") ? review.file.slice(folder.length, -3) : "";
    if (!namespace(review.namespace) || !uuid(fileID) || fileID.toLowerCase() !== review.generation_id.toLowerCase() ||
        listed.get(review.file)?.kind !== "review" || Date.parse(review.start) >= Date.parse(review.end)) reject("Invalid review source");
    const identity = `review:${review.namespace.toLowerCase()}:${review.generation_id.toLowerCase()}`;
    if (identities.has(identity)) reject("Duplicate source identity");
    identities.add(identity);
    referenced.review.add(review.file);
    try { new Intl.DateTimeFormat("en", { timeZone: review.time_zone.normalize("NFC") }); }
    catch { reject("Invalid review time zone"); }
    for (const citation of review.sources) {
      if (!namespace(citation.namespace) || !validDay(citation.day) ||
          citation.id !== `${citation.namespace}/${citation.day}/${citation.memo_id}`) reject("Invalid historical citation");
      // A saved review may cite an earlier revision or a now-absent note.
      // Preserve that history; current-source parity is a separate concern.
    }
  }
  for (const kind of ["records", "raw", "asset", "review"] as const) {
    const paths = new Set(manifest.files.filter(file => file.kind === kind).map(file => file.path));
    if (paths.size !== referenced[kind].size || [...referenced[kind]].some(path => !paths.has(path))) reject("Unreferenced or missing typed file");
  }
}

/** Pure local selection/validation. There is deliberately no network adapter. */
export async function previewExchange(input: readonly ExchangeInputFile[], signal?: AbortSignal): Promise<ExchangePreview> {
  current(signal);
  if (input.length > EXCHANGE_LIMITS.files + 1) reject("Too many selected files");
  const selected = new Map<string, ExchangeInputFile>();
  const foldedSelection = new Set<string>();
  for (const file of input) {
    if (!safePath(file.path) || foldedSelection.has(foldedPath(file.path))) reject("Unsafe or duplicate selected path");
    foldedSelection.add(foldedPath(file.path));
    selected.set(file.path, file);
  }
  const source = selected.get("daypage-exchange.json");
  if (!source) reject("Select a folder containing daypage-exchange.json");
  const manifestBytes = await read(source, EXCHANGE_LIMITS.manifest, signal);
  const manifest = parseManifest(decode(manifestBytes));
  const paths = new Set<string>();
  const foldedPaths = new Set<string>();
  let total = 0, recordsFiles = 0;
  for (const file of manifest.files) {
    if (!filePath(file) || foldedPaths.has(foldedPath(file.path))) reject("Unsafe or duplicate manifest path");
    paths.add(file.path);
    foldedPaths.add(foldedPath(file.path));
    if (file.kind === "records") recordsFiles++;
    if (file.kind === "asset" && file.bytes > EXCHANGE_LIMITS.attachment) reject("Attachment exceeds exchange limit");
    total += file.bytes;
    if (total > EXCHANGE_LIMITS.total) reject("Exchange exceeds total byte limit");
    const chosen = selected.get(file.path);
    if (!chosen || chosen.size !== file.bytes) reject("Missing or changed selected file");
  }
  if (recordsFiles !== 1 || selected.size !== paths.size + 1) reject("Unlisted or missing file");
  if (await contentDigest(manifest) !== manifest.content_sha256) reject("Manifest content digest mismatch");
  current(signal);
  const files = new Map<string, Uint8Array>();
  for (const item of manifest.files) {
    const bytes = await read(selected.get(item.path)!, item.kind === "records" ? EXCHANGE_LIMITS.records : EXCHANGE_LIMITS.total, signal);
    if (await sha256(bytes) !== item.sha256) reject("File digest mismatch");
    current(signal);
    files.set(item.path, bytes);
  }
  const records = parseRecords(decode(files.get("records.json")!));
  validateReferences(manifest, records);
  await validateNoteProjection(manifest, records, files, sha256, signal);
  current(signal);
  await validateReviewProjection(manifest, records, files, sha256, signal);
  current(signal);
  const notes = new Map(records.notes.map(note => [`${note.namespace.toLowerCase()}\0${note.original_id.toLowerCase()}`, note]));
  const reviewSources = records.reviews.map(review => {
    const status = { generationId: review.generation_id, current: 0, changed: 0, unavailable: 0 };
    for (const citation of review.sources) {
      const note = notes.get(`${citation.namespace.toLowerCase()}\0${citation.memo_id.toLowerCase()}`);
      if (!note) status.unavailable++;
      else if (note.day !== citation.day || note.revision !== citation.revision) status.changed++;
      else status.current++;
    }
    return status;
  });
  current(signal);
  return { manifest, manifestBytes, records, bytes: total, files, reviewSources };
}
