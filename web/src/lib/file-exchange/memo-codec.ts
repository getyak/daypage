// The production DayPageCore Memo decoder uses a small line-oriented YAML
// subset, rather than general YAML. Keep the same interpretation here so a
// records.json claim cannot silently replace its canonical Markdown source.
// Unknown lines are never rewritten: callers retain the original block bytes.
export interface CanonicalMemo {
  id: string;
  type: "text" | "voice" | "photo" | "location" | "mixed";
  created: string | undefined;
  pinnedAt: string | undefined;
  body: string;
  location?: { name?: string; lat?: number; lng?: number };
  weather?: string;
  device?: string;
  mood?: string;
  marginNote?: string;
  entityMentions: string[];
  attachments: { file: string; kind: string; duration?: number; transcript?: string; transcriptionStatus?: string }[];
}

const whitespace = /^\p{White_Space}+|\p{White_Space}+$/gu;
// Foundation's .whitespaces excludes newline characters. Parsing has already
// split LF lines; preserve CR as the native horizontal trim does.
const trimHorizontal = (value: string) => value.replace(/^[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+|[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+$/gu, "");
const trim = (value: string) => value.replace(whitespace, "");
const id = (value?: string) => value && /^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(value) ? value.toLowerCase() : undefined;
let characterSegmenter: Intl.Segmenter | undefined;
const characters = (value: string) => (characterSegmenter ??= new Intl.Segmenter("und", { granularity: "grapheme" })).segment(value);
export function hasPrefix(value: string, prefix: string): boolean {
  if (!value.startsWith(prefix)) return false;
  const last = characters(value).containing(prefix.length - 1);
  return last !== undefined && last.index + last.segment.length === prefix.length;
}
function colonPair(value: string): [string, string] | undefined {
  // Swift split omits leading empty components before counting maxSplits: 1.
  // A colon carrying a combining mark is a different Character, not a separator.
  let start = 0;
  for (const character of characters(value)) {
    if (character.segment !== ":") continue;
    if (character.index === start) { start++; continue; }
    return character.index < value.length - 1 ? [value.slice(start, character.index), value.slice(character.index + 1)] : undefined;
  }
  return undefined;
}

export function unquoteMemoScalar(value: string): string {
  if (value.length < 2 || !hasPrefix(value, '"') || characters(value).containing(value.length - 1)?.segment !== '"') return value;
  const inner = value.slice(1, -1);
  const iterator = characters(inner)[Symbol.iterator]();
  let output = "", copiedThrough = 0;
  while (true) {
    const current = iterator.next();
    if (current.done) break;
    if (current.value.segment !== "\\") continue;
    output += inner.slice(copiedThrough, current.value.index);
    const next = iterator.next();
    if (next.done) { output += "\\"; copiedThrough = inner.length; break; }
    switch (next.value.segment) {
      case "n": output += "\n"; break;
      case "r": output += "\r"; break;
      case "t": output += "\t"; break;
      case '"': output += '"'; break;
      case "\\": output += "\\"; break;
      default: output += "\\" + next.value.segment;
    }
    copiedThrough = next.value.index + next.value.segment.length;
  }
  return output + inner.slice(copiedThrough);
}

function numeric(value?: string): number | undefined {
  if (value === undefined) return undefined;
  // The owning Swift initializer passes a C string to its locale-fixed parser.
  // Preserve that decoder's embedded-NUL behavior, rather than inventing a
  // different projection. Nonfinite results must be refused by admission.
  value = value.split("\u0000", 1)[0];
  if (/^[+-]?inf(?:inity)?$/i.test(value)) return value.startsWith("-") ? -Infinity : Infinity;
  if (/^[+-]?(?:snan|nan(?:\([^)]*\))?)$/i.test(value)) return Number.NaN;
  if (/^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(value)) return Number(value);
  const hex = /^([+-]?)0x((?:[\da-f]+\.?[\da-f]*|\.[\da-f]+))(?:p([+-]?\d+))?$/i.exec(value);
  if (!hex) return undefined;
  const negative = hex[1] === "-", point = hex[2].indexOf(".");
  const digits = hex[2].replace(".", "").replace(/^0+/, "");
  if (!digits) return negative ? -0 : 0;
  const bits = (digits.length - 1) * 4 + Math.floor(Math.log2(parseInt(digits[0], 16))) + 1;
  const exponent = Number(hex[3] ?? 0) - (point < 0 ? 0 : (hex[2].length - point - 1) * 4);
  const highest = bits - 1 + exponent;
  if (highest > 1023) return negative ? -Infinity : Infinity;
  if (highest < -1075) return negative ? -0 : 0;
  // Round once at the IEEE binary64 quantum, including the subnormal boundary.
  const unit = Math.max(exponent, highest - 52, -1074), shift = BigInt(unit - exponent);
  const integer = BigInt("0x" + digits);
  let rounded = integer >> shift;
  if (shift > BigInt(0)) {
    const remainder = integer - (rounded << shift), halfway = BigInt(1) << (shift - BigInt(1));
    if (remainder > halfway || (remainder === halfway && (rounded & BigInt(1)) === BigInt(1))) rounded++;
  }
  const result = Number(rounded) * 2 ** unit;
  return negative ? -result : result;
}

export function parseCanonicalMemo(block: string): CanonicalMemo | undefined {
  const text = trim(block);
  if (!hasPrefix(text, "---")) return undefined;
  const lines = text.split("\n");
  const closing = lines.findIndex((line, index) => index > 0 && trimHorizontal(line) === "---");
  if (closing < 1) return undefined;
  const frontmatter = lines.slice(1, closing);
  const scalar = (key: string): string | undefined => {
    for (const line of frontmatter) {
      const trimmed = trimHorizontal(line);
      if (!hasPrefix(trimmed, "-") && hasPrefix(trimmed, key + ": ")) return unquoteMemoScalar(trimmed.slice(key.length + 2));
    }
    return undefined;
  };
  const memoID = id(scalar("id"));
  if (!memoID) return undefined;
  const mapping = (key: string): Record<string, string> | undefined => {
    const start = frontmatter.findIndex(line => trimHorizontal(line) === key + ":");
    if (start < 0) return undefined;
    const map: Record<string, string> = Object.create(null);
    for (const line of frontmatter.slice(start + 1)) {
      if (!hasPrefix(line, "  ") || hasPrefix(line, "   ")) break;
      const pair = colonPair(trimHorizontal(line));
      if (pair) map[pair[0]] = unquoteMemoScalar(trimHorizontal(pair[1]));
    }
    return Object.keys(map).length ? map : undefined;
  };
  const sequence = (key: string): string[] => {
    for (let i = 0; i < frontmatter.length; i++) {
      const line = trimHorizontal(frontmatter[i]);
      if (line === key + ": []") return [];
      if (line !== key + ":") continue;
      const values: string[] = [];
      for (const item of frontmatter.slice(i + 1)) {
        if (!hasPrefix(item, "  - ")) break;
        values.push(unquoteMemoScalar(trimHorizontal(item.slice(4))));
      }
      return values;
    }
    return [];
  };
  const maps: Record<string, string>[] = [];
  const attachmentStart = frontmatter.findIndex(line => trimHorizontal(line) === "attachments:");
  if (attachmentStart >= 0) {
    let current: Record<string, string> = Object.create(null);
    for (const line of frontmatter.slice(attachmentStart + 1)) {
      if (hasPrefix(line, "  - ")) {
        if (Object.keys(current).length) maps.push(current);
        current = Object.create(null);
      } else if (!hasPrefix(line, "    ")) break;
      const pair = colonPair(trimHorizontal(hasPrefix(line, "  - ") ? line.slice(4) : line));
      if (pair) current[pair[0]] = unquoteMemoScalar(trimHorizontal(pair[1]));
    }
    if (Object.keys(current).length) maps.push(current);
  }
  const bodyLines = lines.slice(closing + 1);
  const first = bodyLines.findIndex(line => trimHorizontal(line) !== "");
  const locationMap = mapping("location");
  const location = locationMap ? {
    ...(locationMap.name !== undefined ? { name: locationMap.name } : {}),
    ...(numeric(locationMap.lat) !== undefined ? { lat: numeric(locationMap.lat) } : {}),
    ...(numeric(locationMap.lng) !== undefined ? { lng: numeric(locationMap.lng) } : {}),
  } : undefined;
  const type = scalar("type");
  return {
    id: memoID,
    type: type && ["text", "voice", "photo", "location", "mixed"].includes(type) ? type as CanonicalMemo["type"] : "text",
    created: scalar("created"), pinnedAt: scalar("pinned_at"),
    body: first < 0 ? "" : bodyLines.slice(first).join("\n"),
    ...(location ? { location } : {}),
    ...(scalar("weather") !== undefined ? { weather: scalar("weather") } : {}),
    ...(scalar("device") !== undefined ? { device: scalar("device") } : {}),
    ...(scalar("mood") !== undefined ? { mood: scalar("mood") } : {}),
    ...(scalar("margin_note") !== undefined ? { marginNote: scalar("margin_note") } : {}),
    entityMentions: sequence("entity_mentions"),
    attachments: maps.filter(item => item.file !== undefined).map(item => ({
      file: item.file, kind: item.kind ?? "photo",
      ...(numeric(item.duration) !== undefined ? { duration: numeric(item.duration) } : {}),
      ...(item.transcript !== undefined ? { transcript: item.transcript } : {}),
      ...(["pending", "done", "failed"].includes(item.transcription_status) ? { transcriptionStatus: item.transcription_status } : {}),
    })),
  };
}

export function canonicalMemoBlocks(text: string): string[] {
  const modern = "\n\n<!-- daypage-memo-separator -->\n\n", legacy = "\n\n---\n\n";
  if (text.includes(modern)) return text.split(modern);
  if (text.includes(legacy)) {
    const candidates = text.split(legacy), nonempty = candidates.filter(block => trim(block) !== "");
    if (nonempty.length && nonempty.every(block => parseCanonicalMemo(block))) return candidates;
  }
  return text === "" ? [] : [text];
}
