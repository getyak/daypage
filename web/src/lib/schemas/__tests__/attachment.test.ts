import { describe, expect, it } from "vitest";
import {
  ALLOWED_MIME_TYPES,
  MAX_SIZE_BYTES,
  SignAttachmentSchema,
} from "../attachment";

const MEMO_ID = "20000000-0000-4000-8000-000000000001";

// Settled imported-media compatibility slice (issue #884, ADR-0020).
// These must stay in lockstep with the shared v2 schemas and the Swift
// AttachmentManifest/AttachmentFileInspector mappings.
const SETTLED_KIND_MIME: ReadonlyArray<readonly [string, string]> = [
  ["photo", "image/jpeg"],
  ["photo", "image/png"],
  ["photo", "image/heic"],
  ["photo", "image/heif"],
  ["audio", "audio/m4a"],
  ["audio", "audio/mp4"],
  ["audio", "audio/aac"],
  ["file", "application/pdf"],
  ["file", "video/quicktime"],
];

const sign = (kind: string, mime_type: string) =>
  SignAttachmentSchema.safeParse({
    memo_id: MEMO_ID,
    kind,
    mime_type,
    size_bytes: 2048,
  });

describe("SignAttachmentSchema imported-media compatibility", () => {
  it("accepts every settled kind/MIME mapping including AAC and QuickTime MOV", () => {
    for (const [kind, mimeType] of SETTLED_KIND_MIME) {
      const result = sign(kind, mimeType);
      expect(result.success, `${kind}/${mimeType}`).toBe(true);
    }
  });

  it("keeps all seven legacy MIME mappings working", () => {
    for (const [kind, mimeType] of SETTLED_KIND_MIME.filter(([, mime]) =>
      [
        "audio/m4a",
        "audio/mp4",
        "image/jpeg",
        "image/png",
        "image/heic",
        "image/heif",
        "application/pdf",
      ].includes(mime),
    )) {
      expect(sign(kind, mimeType).success, `${kind}/${mimeType}`).toBe(true);
    }
  });

  it("rejects QuickTime MOV as photo and AAC as file", () => {
    expect(sign("photo", "video/quicktime").success).toBe(false);
    expect(sign("file", "audio/aac").success).toBe(false);
  });

  it("rejects every cross-kind MIME pairing", () => {
    const kinds = ["audio", "photo", "file"];
    for (const [kind, mimeType] of SETTLED_KIND_MIME) {
      for (const wrongKind of kinds.filter((candidate) => candidate !== kind)) {
        expect(
          sign(wrongKind, mimeType).success,
          `${wrongKind}/${mimeType} must fail closed`,
        ).toBe(false);
      }
    }
  });

  it("pins ALLOWED_MIME_TYPES to the settled nine-entry list", () => {
    expect([...ALLOWED_MIME_TYPES].sort()).toEqual(
      SETTLED_KIND_MIME.map(([, mime]) => mime).sort(),
    );
  });

  it("keeps the 50 MB per-object ceiling", () => {
    expect(MAX_SIZE_BYTES).toBe(50 * 1024 * 1024);
    const atLimit = SignAttachmentSchema.safeParse({
      memo_id: MEMO_ID,
      kind: "audio",
      mime_type: "audio/aac",
      size_bytes: MAX_SIZE_BYTES,
    });
    expect(atLimit.success).toBe(true);
    const overLimit = SignAttachmentSchema.safeParse({
      memo_id: MEMO_ID,
      kind: "audio",
      mime_type: "audio/aac",
      size_bytes: MAX_SIZE_BYTES + 1,
    });
    expect(overLimit.success).toBe(false);
  });
});
