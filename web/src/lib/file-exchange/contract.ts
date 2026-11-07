// Shared v1 wire schema is frozen with GET-442. This validator intentionally
// implements only its small JSON Schema vocabulary and fails on unknown fields.
// It runs without Node APIs in the browser and independently again on the server.
import schema from "./schema.json" with { type: "json" };

export class ExchangeValidationError extends Error {
  readonly code: string;
  constructor(code: string) {
    super(code);
    this.code = code;
    this.name = "ExchangeValidationError";
  }
}

type Rule = {
  $ref?: string; type?: string; const?: unknown; enum?: unknown[];
  required?: string[]; properties?: Record<string, Rule>;
  additionalProperties?: boolean; items?: Rule;
  minLength?: number; maxLength?: number; pattern?: string; format?: string;
  minimum?: number; maximum?: number; minItems?: number; maxItems?: number;
};
const definitions = schema.$defs as Record<string, Rule>;
export function reject(code: string): never { throw new ExchangeValidationError(code); }

export function validDay(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return false;
  const [, y, m, d] = match.map(Number);
  if (y < 1 || m < 1 || m > 12 || d < 1) return false;
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  return d <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
}

function validTimestamp(value: string): boolean {
  const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  return !!match && validDay(match[1]) && +match[2] < 24 && +match[3] < 60 &&
    +match[4] < 60 && (!match[5] || (+match[6] < 24 && +match[7] < 60)) &&
    Number.isFinite(Date.parse(value));
}

function validate(value: unknown, initialRule: Rule): void {
  const rule = initialRule.$ref
    ? definitions[initialRule.$ref.replace(/^#\/\$defs\//, "")]
    : initialRule;
  if (!rule) reject("Unknown schema reference");
  if (Object.hasOwn(rule, "const") && value !== rule.const) reject("Unsupported format version");
  if (rule.enum && !rule.enum.includes(value)) reject("Unsupported field value");
  if (rule.type === "object") {
    if (value === null || typeof value !== "object" || Array.isArray(value) ||
        Object.getPrototypeOf(value) !== Object.prototype) reject("Expected an object");
    const object = value as Record<string, unknown>;
    if (rule.required?.some(key => !Object.hasOwn(object, key))) reject("Missing required field");
    for (const [key, item] of Object.entries(object)) {
      const child = rule.properties?.[key];
      if (child) validate(item, child);
      else if (rule.additionalProperties === false) reject("Unknown field");
    }
  } else if (rule.type === "array") {
    if (!Array.isArray(value)) reject("Expected an array");
    if (value.length < (rule.minItems ?? 0) || value.length > (rule.maxItems ?? Infinity)) reject("Too many or too few records");
    if (rule.items) value.forEach(item => validate(item, rule.items!));
  } else if (rule.type === "string") {
    if (typeof value !== "string") reject("Expected text");
    // UTF-16 length is conservative for the schema's code-point bounds.
    if (value.length < (rule.minLength ?? 0) || value.length > (rule.maxLength ?? Infinity)) reject("Text exceeds format bounds");
    if (rule.pattern && !new RegExp(rule.pattern).test(value)) reject("Invalid field format");
    if (rule.format === "uuid" && !/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(value)) reject("Invalid record identity");
    if (rule.format === "date-time" && !validTimestamp(value)) reject("Invalid timestamp");
  } else if (rule.type === "integer" || rule.type === "number") {
    if (typeof value !== "number" || !Number.isFinite(value) ||
        (rule.type === "integer" && !Number.isSafeInteger(value)) ||
        value < (rule.minimum ?? -Infinity) || value > (rule.maximum ?? Infinity)) reject("Invalid numeric field");
  } else if (!rule.enum && !Object.hasOwn(rule, "const")) {
    reject("Unsupported schema rule");
  }
}

export interface ExchangeFile {
  path: string; bytes: number; sha256: string;
  kind: "records" | "raw" | "asset" | "review";
}
export interface ExchangeManifest {
  version: 1; format: "daypage-file-exchange-v1"; export_id: string;
  created_at: string; notes_count: number; reviews_count: number;
  files: ExchangeFile[]; content_sha256: string;
}
export interface ExchangeAttachment {
  file: string; kind: "photo" | "audio" | "file"; sha256: string; bytes: number;
  duration?: number; transcript?: string; transcription_status?: "pending" | "done" | "failed";
}
export interface ExchangeNote {
  original_id: string; namespace: string; day: string; revision: string;
  type: "text" | "voice" | "photo" | "location" | "mixed";
  body: string; created_at: string; attachments: ExchangeAttachment[];
  entity_mentions: string[]; location?: { name?: string; lat?: number; lng?: number };
  weather?: string; device?: string; mood?: string; margin_note?: string; pinned_at?: string;
}
export interface ExchangeReview {
  generation_id: string; namespace: string; file: string; period_kind: "day" | "week";
  start: string; end: string; time_zone: string; created_at: string;
  source_digest: string; body: string;
  sources: { id: string; namespace: string; memo_id: string; day: string; revision: string }[];
}
export interface ExchangeRecords { version: 1; notes: ExchangeNote[]; reviews: ExchangeReview[] }

export function parseManifest(value: unknown): ExchangeManifest {
  validate(value, definitions.manifest);
  return value as ExchangeManifest;
}
export function parseRecords(value: unknown): ExchangeRecords {
  validate(value, definitions.records);
  return value as ExchangeRecords;
}
