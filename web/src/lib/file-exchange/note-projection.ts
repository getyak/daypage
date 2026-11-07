import { reject } from "./contract.ts";
import type { ExchangeManifest, ExchangeNote, ExchangeRecords } from "./contract.ts";
import { canonicalMemoBlocks, hasPrefix, parseCanonicalMemo } from "./memo-codec.ts";
import { parseWireTimestamp, projectRawTimestamp } from "./timestamp.ts";

type Hash = (bytes: Uint8Array) => Promise<string>;
const encoder = new TextEncoder();
const identity = (note: Pick<ExchangeNote, "namespace" | "original_id">) =>
  note.namespace.toLowerCase() + "\0" + note.original_id.toLowerCase();

function same(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  // Swift String equality accepts canonical Unicode spellings. This compares
  // derived claims only; original bytes, file lookups and revisions stay exact.
  if (typeof a === "string" && typeof b === "string") return a.normalize("NFC") === b.normalize("NFC");
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((item, i) => same(item, b[i]));
  }
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  const keys = Object.keys(x);
  return keys.length === Object.keys(y).length && keys.every(key => Object.hasOwn(y, key) && same(x[key], y[key]));
}

/** Validate the complete known note projection against each exact original block.
 * The file/record limits and manifest references are checked by the caller first.
 * Unknown YAML remains in the original file; it never gains typed authority.
 */
export async function validateNoteProjection(manifest: ExchangeManifest, records: ExchangeRecords,
  files: ReadonlyMap<string, Uint8Array>, hash: Hash, signal?: AbortSignal): Promise<void> {
  const actual = new Map<string, ExchangeNote>();
  const listed = new Map(manifest.files.map(file => [file.path, file]));
  const assetDigests = new Map<string, string>();
  for (const file of manifest.files) {
    if (file.kind !== "raw") continue;
    signal?.throwIfAborted();
    const bytes = files.get(file.path);
    if (!bytes) reject("Missing canonical note file");
    let text: string;
    try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
    catch { return reject("Invalid UTF-8 note file"); }
    const pieces = file.path.split("/"), namespace = pieces.slice(0, -2).join("/");
    const day = pieces[pieces.length - 1].slice(0, -3), prefix = namespace ? namespace + "/" : "";
    for (const block of canonicalMemoBlocks(text)) {
      signal?.throwIfAborted();
      if (/^\p{White_Space}*$/u.test(block)) continue;
      const memo = parseCanonicalMemo(block);
      if (!memo) reject("Invalid canonical note block");
      if (actual.size >= 500 || memo.attachments.length > 10) reject("Excessive canonical notes or attachments");
      const created = memo.created === undefined ? null : projectRawTimestamp(memo.created);
      const pinned = memo.pinnedAt === undefined ? undefined : projectRawTimestamp(memo.pinnedAt);
      if (created === null || pinned === null) reject("Invalid canonical note timestamp");
      if (memo.location && [memo.location.lat, memo.location.lng].some(value => value !== undefined && !Number.isFinite(value))) {
        reject("Invalid canonical location number");
      }
      const attachments: ExchangeNote["attachments"] = [];
      for (const item of memo.attachments) {
        const path = prefix + (hasPrefix(item.file, "raw/assets/") ? item.file : "raw/assets/" + item.file);
        const data = files.get(path), descriptor = listed.get(path);
        if (!data || descriptor?.kind !== "asset" || !["photo", "audio", "file"].includes(item.kind) ||
            (item.duration !== undefined && (!Number.isFinite(item.duration) || item.duration < 0))) reject("Invalid canonical attachment");
        let digest = assetDigests.get(path);
        if (digest === undefined) {
          digest = await hash(data);signal?.throwIfAborted();assetDigests.set(path, digest);
        }
        attachments.push({ file: path, kind: item.kind as "photo" | "audio" | "file", bytes: data.length,
          sha256: digest,
          ...(item.duration !== undefined ? { duration: item.duration } : {}),
          ...(item.transcript !== undefined ? { transcript: item.transcript } : {}),
          ...(item.transcriptionStatus !== undefined ? { transcription_status: item.transcriptionStatus as "pending" | "done" | "failed" } : {}),
        });
        signal?.throwIfAborted();
      }
      const note: ExchangeNote = {
        original_id: memo.id, namespace, day, revision: await hash(encoder.encode(block)), type: memo.type,
        body: memo.body, created_at: created, entity_mentions: memo.entityMentions, attachments,
        ...(memo.location !== undefined ? { location: memo.location } : {}),
        ...(memo.weather !== undefined ? { weather: memo.weather } : {}),
        ...(memo.device !== undefined ? { device: memo.device } : {}),
        ...(memo.mood !== undefined ? { mood: memo.mood } : {}),
        ...(memo.marginNote !== undefined ? { margin_note: memo.marginNote } : {}),
        ...(pinned !== undefined ? { pinned_at: pinned } : {}),
      };
      signal?.throwIfAborted();
      const key = identity(note);
      if (actual.has(key) || actual.size >= 500) reject("Duplicate or excessive canonical notes");
      actual.set(key, note);
    }
  }
  if (actual.size !== records.notes.length) reject("Canonical note counts do not match");
  for (const note of records.notes) {
    const created = parseWireTimestamp(note.created_at), pinned = note.pinned_at === undefined ? undefined : parseWireTimestamp(note.pinned_at);
    if (!created || pinned === null) reject("Invalid typed note timestamp");
    const normalized = { ...note, original_id: note.original_id.toLowerCase(), created_at: created.canonical,
      ...(pinned !== undefined ? { pinned_at: pinned.canonical } : {}) };
    if (!same(actual.get(identity(note)), normalized)) reject("Typed note contradicts its canonical block");
  }
}
