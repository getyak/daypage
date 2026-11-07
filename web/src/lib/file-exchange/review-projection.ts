import { reject, validDay } from "./contract.ts";
import type { ExchangeManifest, ExchangeRecords, ExchangeReview } from "./contract.ts";
import { parseWireTimestamp, projectReviewReferenceSeconds } from "./timestamp.ts";

type Hash = (bytes: Uint8Array) => Promise<string>;
type ObjectValue = Record<string, unknown>;
interface Citation { id: string; namespace: string; memo_id: string; day: string; revision: string }
interface Period { kind: "day" | "week"; timeZoneID: string; start: number; end: number }
interface Metadata {
  version: 1; id: string; created: number; period: Period; citations: Citation[];
  sourceDigest: string; bodyBytes: number; bodyDigest: string;
}
const encoder = new TextEncoder();
const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const digest = /^[a-f0-9]{64}$/;
const dayMilliseconds = 86_400_000;

/** SwiftDtoa chooses the same shortest/nearest/even significand as ECMAScript.
 * Its presentation differs: exponent < -4 or magnitude > 2^53 uses scientific
 * form, with a signed, >=2-digit exponent. JSONEncoder removes a final .0.
 * See swift-6.0-RELEASE/stdlib/public/runtime/SwiftDtoa.cpp, finishFormatting.
 */
export function swiftJSONNumber(value: number): string {
  if (!Number.isFinite(value)) return reject("Nonfinite review metadata number");
  if (value === 0) return Object.is(value, -0) ? "-0" : "0";
  const sign = value < 0 ? "-" : "", magnitude = Math.abs(value);
  const [digits, power] = magnitude.toExponential().split("e"), exponent = Number(power);
  if (exponent < -4 || magnitude > 2 ** 53) {
    return sign + digits + "e" + (exponent < 0 ? "-" : "+") + String(Math.abs(exponent)).padStart(2, "0");
  }
  return sign + magnitude.toString();
}

function canonical(value: unknown): string {
  if (typeof value === "number") return swiftJSONNumber(value);
  if (typeof value === "string") return JSON.stringify(value).replaceAll("/", "\\/");
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (value !== null && typeof value === "object") {
    const object = value as ObjectValue;
    return "{" + Object.keys(object).sort().map(key => canonical(key) + ":" + canonical(object[key])).join(",") + "}";
  }
  return reject("Unsupported review metadata value");
}

function object(value: unknown, fields: string[]): ObjectValue {
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      Object.getPrototypeOf(value) !== Object.prototype) return reject("Invalid review metadata object");
  const item = value as ObjectValue, keys = Object.keys(item);
  if (keys.length !== fields.length || !fields.every(key => Object.hasOwn(item, key))) reject("Unknown or missing review metadata field");
  return item;
}
function text(value: unknown): string {
  if (typeof value !== "string") return reject("Invalid review metadata text");
  return value;
}
function date(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value) || !projectReviewReferenceSeconds(value)) {
    return reject("Invalid review metadata clock");
  }
  return value;
}
function logical(value: unknown): string {
  const path = text(value);
  if (path !== "" && (path.split("/").length > 16 || !path.split("/").every(part => uuid.test(part)))) {
    reject("Invalid logical review namespace");
  }
  return path;
}
function physical(value: string): string {
  const path = value === "" ? "" : value.split("/").map(part => "imports/" + part).join("/");
  if (encoder.encode(path).length > 400) reject("Review namespace exceeds format limit");
  return path;
}
function sourceNamespace(path: string): string {
  if (path === "") return "";
  const pieces = path.split("/");
  if (pieces.length % 2 !== 0 || pieces.length > 32 || encoder.encode(path).length > 400 ||
      pieces.some((part, i) => i % 2 === 0 ? part !== "imports" : !uuid.test(part))) {
    return reject("Invalid physical review namespace");
  }
  return pieces.filter((_, i) => i % 2 === 1).join("/");
}
function metadata(value: unknown): Metadata {
  const m = object(value, ["version", "id", "created", "period", "citations", "sourceDigest", "bodyBytes", "bodyDigest"]);
  const id = text(m.id), sourceDigest = text(m.sourceDigest), bodyDigest = text(m.bodyDigest);
  if (m.version !== 1 || !uuid.test(id) || id !== id.toUpperCase() || !digest.test(sourceDigest) || !digest.test(bodyDigest) ||
      !Number.isSafeInteger(m.bodyBytes) || (m.bodyBytes as number) < 1 || (m.bodyBytes as number) > 64 * 1024) reject("Invalid review metadata bounds");
  const p = object(m.period, ["kind", "timeZoneID", "start", "end"]);
  if (p.kind !== "day" && p.kind !== "week") reject("Invalid review period kind");
  const timeZoneID = text(p.timeZoneID);
  if (!/^[A-Za-z][A-Za-z0-9_+:/.-]{0,127}$/.test(timeZoneID)) reject("Invalid review time zone");
  const period: Period = { kind: p.kind, timeZoneID, start: date(p.start), end: date(p.end) };
  if (!Number.isSafeInteger(period.start) || !Number.isSafeInteger(period.end) || period.start >= period.end) reject("Invalid review calendar interval");
  if (!Array.isArray(m.citations) || m.citations.length < 1 || m.citations.length > 12) reject("Invalid review citation count");
  const ids = new Set<string>();
  const citations = m.citations.map(value => {
    const c = object(value, ["id", "namespace", "memo_id", "day", "revision"]);
    const namespace = logical(c.namespace), memoID = text(c.memo_id), day = text(c.day), revision = text(c.revision), id = text(c.id);
    if (!uuid.test(memoID) || memoID !== memoID.toUpperCase() || !validDay(day) || !digest.test(revision) ||
        id !== `${namespace}/${day}/${memoID}` || ids.has(id)) reject("Invalid or duplicate raw review citation");
    ids.add(id);
    return { id, namespace, memo_id: memoID, day, revision };
  });
  return { version: 1, id, created: date(m.created), period, citations, sourceDigest,
    bodyBytes: m.bodyBytes as number, bodyDigest };
}
function decode(bytes: Uint8Array): string {
  try { return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch { return reject("Invalid UTF-8 review page"); }
}
function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}
function base64(value: string): Uint8Array {
  if (value.length % 4 !== 0) return reject("Invalid review metadata base64");
  let decoded: string;
  try { decoded = atob(value); }
  catch { return reject("Invalid review metadata base64"); }
  if (btoa(decoded) !== value) reject("Noncanonical review metadata base64");
  return Uint8Array.from(decoded, char => char.charCodeAt(0));
}

interface Civil { year: number; month: number; day: number; hour: number; minute: number; second: number }
function civilDate(year: number, month: number, day: number): number {
  const date = new Date(0); date.setUTCFullYear(year, month - 1, day); date.setUTCHours(0, 0, 0, 0);
  return date.getTime();
}

/** Bounded ICU calendar checks, including repeated and skipped midnight. No
 * fixed 24h day or 168h week is assumed. Boundary results are cached per import.
 */
class CalendarBoundary {
  private formatters = new Map<string, Intl.DateTimeFormat>();
  private boundaries = new Map<string, number | null>();
  private local(milliseconds: number, zone: string): Civil {
    let formatter = this.formatters.get(zone);
    if (!formatter) {
      try {
        formatter = new Intl.DateTimeFormat("en-US-u-ca-iso8601-nu-latn", { calendar: "iso8601", numberingSystem: "latn",
          timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23", era: "short" });
      } catch { return reject("Unsupported review time zone"); }
      if (formatter.resolvedOptions().calendar !== "iso8601" || formatter.resolvedOptions().numberingSystem !== "latn" ||
          formatter.resolvedOptions().hourCycle !== "h23") reject("Unsupported review calendar formatter");
      this.formatters.set(zone, formatter);
    }
    const values = Object.fromEntries(formatter.formatToParts(new Date(milliseconds)).map(part => [part.type, part.value]));
    const year = Number(values.year) * (values.era === "BC" ? -1 : 1) + (values.era === "BC" ? 1 : 0);
    return { year, month: Number(values.month), day: Number(values.day), hour: Number(values.hour), minute: Number(values.minute), second: Number(values.second) };
  }
  private ordinal(value: Civil): number { return civilDate(value.year, value.month, value.day); }
  private boundary(civil: number, zone: string): number | null {
    const key = zone + ":" + civil;
    if (this.boundaries.has(key)) return this.boundaries.get(key)!;
    const offsets = new Set<number>(), samples: { utc: number; day: number }[] = [];
    // Actual IANA offset states around the boundary, with a 72h bounded window.
    for (let hour = -36; hour <= 36; hour++) {
      const utc = civil + hour * 3_600_000, value = this.local(utc, zone);
      offsets.add(this.ordinal(value) + (value.hour * 3600 + value.minute * 60 + value.second) * 1000 - utc);
      samples.push({ utc, day: this.ordinal(value) });
    }
    const candidates: number[] = [];
    for (const offset of offsets) {
      const utc = civil - offset, value = this.local(utc, zone);
      if (this.ordinal(value) === civil && value.hour === 0 && value.minute === 0 && value.second === 0) candidates.push(utc);
    }
    // A local midnight may not exist. Find the first actual instant of the day
    // across each sampled transition, rather than normalizing it to 00:00 UTC.
    if (!candidates.length) {
      for (let i = 1; i < samples.length; i++) {
        if (samples[i - 1].day >= civil || samples[i].day < civil) continue;
        let lo = samples[i - 1].utc, hi = samples[i].utc;
        while (hi - lo > 1) {
          const mid = Math.floor((lo + hi) / 2);
          if (this.ordinal(this.local(mid, zone)) >= civil) hi = mid; else lo = mid;
        }
        if (this.ordinal(this.local(hi, zone)) === civil) candidates.push(hi);
      }
    }
    const result = candidates.length ? Math.min(...candidates) : null;
    this.boundaries.set(key, result);
    return result;
  }
  private nextExisting(civil: number, zone: string): number {
    for (let skipped = 0; skipped < 3; skipped++) {
      const value = this.boundary(civil + skipped * dayMilliseconds, zone);
      if (value !== null) return value;
    }
    return reject("Unsupported review calendar discontinuity");
  }
  validate(period: Period): void {
    const start = (period.start + 978307200) * 1000, end = (period.end + 978307200) * 1000;
    const local = this.local(start, period.timeZoneID), day = this.ordinal(local);
    const weekday = (new Date(day).getUTCDay() + 6) % 7;
    const first = period.kind === "day" ? day : day - weekday * dayMilliseconds;
    const last = first + (period.kind === "day" ? 1 : 7) * dayMilliseconds;
    if (this.nextExisting(first, period.timeZoneID) !== start || this.nextExisting(last, period.timeZoneID) !== end) {
      reject("Review interval is not its local calendar day or ISO week");
    }
  }
}

function same(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  // Swift Equatable strings use canonical Unicode equality. This is only a
  // comparison of derived claims; raw bytes, digests and map keys stay exact.
  if (typeof a === "string" && typeof b === "string") return a.normalize("NFC") === b.normalize("NFC");
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a) || Array.isArray(b)) return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((value, i) => same(value, b[i]));
  const x = a as ObjectValue, y = b as ObjectValue, keys = Object.keys(x);
  return keys.length === Object.keys(y).length && keys.every(key => Object.hasOwn(y, key) && same(x[key], y[key]));
}

/** Verify the native raw review envelope and its entire typed projection.
 * Historical citations need not name a current/unchanged note: they confer no
 * account, source-auth or current-revision authority. Original bytes stay intact.
 */
export async function validateReviewProjection(manifest: ExchangeManifest, records: ExchangeRecords,
  files: ReadonlyMap<string, Uint8Array>, hash: Hash, signal?: AbortSignal): Promise<void> {
  signal?.throwIfAborted();
  const actual = new Map<string, ExchangeReview>(), identities = new Set<string>(), calendar = new CalendarBoundary();
  const listed = manifest.files.filter(file => file.kind === "review");
  if (listed.length > 100 || listed.length !== records.reviews.length || manifest.reviews_count !== listed.length) reject("Canonical review counts do not match");
  for (const file of listed) {
    signal?.throwIfAborted();
    const selected = files.get(file.path);
    if (!selected || selected.length > 96 * 1024 || selected.length !== file.bytes) reject("Missing or excessive raw review page");
    const bytes = Uint8Array.from(selected), raw = decode(bytes);
    const header = /^---\ntype: manual_(day|week)_review\ndaypage_review: ([A-Za-z0-9+/]+={0,2})\n---\n\n/.exec(raw);
    if (!header || header[0].length - 6 >= 24 * 1024) reject("Invalid canonical review header");
    const metadataText = decode(base64(header[2]));
    let decoded: unknown;
    try { decoded = JSON.parse(metadataText); } catch { return reject("Invalid review metadata JSON"); }
    const m = metadata(decoded);
    // Exact re-encoding rejects duplicate keys, whitespace, alternative escapes,
    // unknown payload and noncanonical numeric forms, not merely their meaning.
    if (canonical(m) !== metadataText || header[1] !== m.period.kind) reject("Noncanonical raw review metadata");
    const offset = encoder.encode(header[0]).length, bodyBytes = bytes.slice(offset, offset + m.bodyBytes), body = decode(bodyBytes);
    if (bodyBytes.length !== m.bodyBytes || !/[^\p{White_Space}]/u.test(body)) reject("Invalid raw review body bounds");
    const footer = "\n\n## Sources\n" + m.citations.map((citation, i) => {
      const prefix = citation.namespace ? physical(citation.namespace) + "/" : "";
      return `- S${i + 1}: [${citation.day}](../../${prefix}raw/${citation.day}.md) · ${citation.memo_id}\n`;
    }).join("");
    if (!equalBytes(bytes, encoder.encode(header[0] + body + footer))) reject("Raw review footer or payload differs");
    if (await hash(bodyBytes) !== m.bodyDigest) reject("Raw review body digest mismatch");
    signal?.throwIfAborted();
    calendar.validate(m.period);
    const parts = file.path.split("/"), namespace = parts.slice(0, -3).join("/"), owner = sourceNamespace(namespace);
    const filename = parts.at(-1) ?? "", basename = filename.endsWith(".md") ? filename.slice(0, -3) : "";
    if (parts.slice(-3, -1).join("/") !== "wiki/manual-reviews" || !uuid.test(basename) || basename.toUpperCase() !== m.id) reject("Raw review identity differs from its file");
    const sources = m.citations.map(citation => {
      const combined = owner ? owner + (citation.namespace ? "/" + citation.namespace : "") : citation.namespace;
      const namespace = physical(logical(combined));
      return { ...citation, namespace, id: `${namespace}/${citation.day}/${citation.memo_id}` };
    });
    const identity = namespace.toLowerCase() + "\0" + m.id;
    if (actual.has(file.path) || identities.has(identity)) reject("Duplicate canonical review identity");
    identities.add(identity);
    actual.set(file.path, { generation_id: m.id, namespace, file: file.path, period_kind: m.period.kind,
      start: projectReviewReferenceSeconds(m.period.start), end: projectReviewReferenceSeconds(m.period.end), time_zone: m.period.timeZoneID,
      created_at: projectReviewReferenceSeconds(m.created), source_digest: m.sourceDigest, sources, body });
  }
  const seen = new Set<string>();
  for (const review of records.reviews) {
    signal?.throwIfAborted();
    if (seen.has(review.file)) reject("Duplicate typed review file");
    seen.add(review.file);
    for (const clock of [review.start, review.end, review.created_at]) {
      if (parseWireTimestamp(clock)?.canonical !== clock) reject("Noncanonical typed review clock");
    }
    const normalized = { ...review, generation_id: review.generation_id.toUpperCase(),
      sources: review.sources.map(source => ({ ...source, memo_id: source.memo_id.toUpperCase() })) };
    if (!same(actual.get(review.file), normalized)) reject("Typed review contradicts its canonical page");
  }
  signal?.throwIfAborted();
}
