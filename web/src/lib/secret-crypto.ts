// Symmetric encryption for ingest_sources.config (and similar secret-bearing
// jsonb fields). AES-256-GCM with a key derived from INGEST_CONFIG_SECRET.
//
// Storage shape on disk (jsonb): { "_encrypted": "enc:v1:<base64(iv|tag|ct)>" }
// — keeps the column type as jsonb while making it obvious the row is opaque.
// Plaintext rows that pre-date this change are still readable: decryptConfig
// returns them unchanged when the envelope marker is absent.

import { createCipheriv, createDecipheriv, randomBytes, createHash } from "crypto";

const ALGO = "aes-256-gcm";
const IV_LEN = 12;
const TAG_LEN = 16;
const PREFIX = "enc:v1:";
const ENVELOPE_KEY = "_encrypted";

function getKey(): Buffer {
  const raw = process.env.INGEST_CONFIG_SECRET;
  if (!raw) {
    throw new Error(
      "INGEST_CONFIG_SECRET is not set — required to encrypt/decrypt ingest_sources.config"
    );
  }
  // Accept any length; hash to 32 bytes so misconfigured short secrets still
  // produce a usable key. Operators SHOULD provide a strong random secret.
  return createHash("sha256").update(raw).digest();
}

function encryptString(plaintext: string): string {
  const key = getKey();
  const iv = randomBytes(IV_LEN);
  const cipher = createCipheriv(ALGO, key, iv);
  const ct = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return PREFIX + Buffer.concat([iv, tag, ct]).toString("base64");
}

function decryptString(token: string): string {
  if (!token.startsWith(PREFIX)) {
    throw new Error("Not an encrypted envelope");
  }
  const buf = Buffer.from(token.slice(PREFIX.length), "base64");
  if (buf.length <= IV_LEN + TAG_LEN) {
    throw new Error("Ciphertext too short");
  }
  const iv = buf.subarray(0, IV_LEN);
  const tag = buf.subarray(IV_LEN, IV_LEN + TAG_LEN);
  const ct = buf.subarray(IV_LEN + TAG_LEN);
  const key = getKey();
  const decipher = createDecipheriv(ALGO, key, iv);
  decipher.setAuthTag(tag);
  const pt = Buffer.concat([decipher.update(ct), decipher.final()]);
  return pt.toString("utf8");
}

export type ConfigObject = Record<string, unknown>;

export function encryptConfig(config: ConfigObject): ConfigObject {
  const json = JSON.stringify(config ?? {});
  return { [ENVELOPE_KEY]: encryptString(json) };
}

export function decryptConfig(raw: unknown): ConfigObject {
  if (!raw || typeof raw !== "object") return {};
  const obj = raw as Record<string, unknown>;
  const envelope = obj[ENVELOPE_KEY];
  if (typeof envelope === "string" && envelope.startsWith(PREFIX)) {
    try {
      return JSON.parse(decryptString(envelope)) as ConfigObject;
    } catch {
      // Corrupted ciphertext — surface as empty rather than leaking
      // partial data; logging is the caller's responsibility.
      return {};
    }
  }
  // Legacy plaintext row, or env not set when stored — return as-is.
  return obj;
}

// Redact the encrypted envelope before returning a source row to the client.
// Callers should use this whenever they expose a row over the API.
export function redactConfigForClient(raw: unknown): ConfigObject {
  if (!raw || typeof raw !== "object") return {};
  const obj = raw as Record<string, unknown>;
  if (typeof obj[ENVELOPE_KEY] === "string") {
    // Don't ship the ciphertext; tell the client this row has stored secrets.
    return { _encrypted: true };
  }
  return obj;
}
