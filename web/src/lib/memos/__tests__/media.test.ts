import { describe, it, expect } from "vitest";
import {
  KIND_MIME_PAIRS,
  asciiFallbackFilename,
  classifyAttachment,
  contentDisposition,
  encodeStorageKeyPath,
  isInlinePreviewMime,
  isValidStorageKey,
  rfc5987Filename,
  safeMimeOrOctetStream,
} from "../media";

const UID = "11111111-2222-4333-8444-555555555555";

describe("kind/MIME classification is bound to the nine pairs", () => {
  it("classifies each supported pair", () => {
    expect(KIND_MIME_PAIRS).toHaveLength(9);
    const expectations: Array<[[string, string], string]> = [
      [["photo", "image/jpeg"], "image"],
      [["photo", "image/png"], "image"],
      [["photo", "image/heic"], "image"],
      [["photo", "image/heif"], "image"],
      [["audio", "audio/m4a"], "audio"],
      [["audio", "audio/mp4"], "audio"],
      [["audio", "audio/aac"], "audio"],
      [["file", "application/pdf"], "file"],
      [["file", "video/quicktime"], "video"],
    ];
    for (const [[kind, mime], preview] of expectations) {
      expect(classifyAttachment(kind as never, mime)).toBe(preview);
    }
  });

  it("returns unknown for missing, mismatched or legacy metadata", () => {
    expect(classifyAttachment("photo", null)).toBe("unknown");
    expect(classifyAttachment("photo", "audio/m4a")).toBe("unknown");
    expect(classifyAttachment("audio", "video/quicktime")).toBe("unknown");
    expect(classifyAttachment("file", "image/jpeg")).toBe("unknown");
    expect(classifyAttachment("file", "application/zip")).toBe("unknown");
    expect(classifyAttachment("file", undefined)).toBe("unknown");
  });

  it("allows inline preview only for safe known image/audio/video MIME", () => {
    expect(isInlinePreviewMime("image/png")).toBe(true);
    expect(isInlinePreviewMime("audio/aac")).toBe(true);
    expect(isInlinePreviewMime("video/quicktime")).toBe(true);
    expect(isInlinePreviewMime("application/pdf")).toBe(false);
    expect(isInlinePreviewMime("text/html")).toBe(false);
    expect(isInlinePreviewMime(null)).toBe(false);
    expect(isInlinePreviewMime("image/svg+xml")).toBe(false);
  });

  it("falls back to application/octet-stream for unsafe MIME values", () => {
    expect(safeMimeOrOctetStream("image/png")).toBe("image/png");
    expect(safeMimeOrOctetStream("image/png\r\nX: y")).toBe("application/octet-stream");
    expect(safeMimeOrOctetStream("weird")).toBe("application/octet-stream");
    expect(safeMimeOrOctetStream(null)).toBe("application/octet-stream");
  });
});

describe("storage key validation (trusted metadata, owner-prefixed)", () => {
  it("accepts the v2 owner-prefixed path shape", () => {
    expect(isValidStorageKey(`${UID}/${UID}/abcdef1234.png`, UID)).toBe(true);
  });

  it("rejects traversal, control characters, URLs and foreign owners", () => {
    expect(isValidStorageKey(`${UID}/../../etc/passwd`, UID)).toBe(false);
    expect(isValidStorageKey(`${UID}/a/./b`, UID)).toBe(false);
    expect(isValidStorageKey(`//etc/passwd`, UID)).toBe(false);
    expect(isValidStorageKey(`/${UID}/x.png`, UID)).toBe(false);
    expect(isValidStorageKey(`${UID}/x\u0000.png`, UID)).toBe(false);
    expect(isValidStorageKey(`${UID}\\x.png`, UID)).toBe(false);
    expect(isValidStorageKey("https://evil.example/x.png", UID)).toBe(false);
    expect(isValidStorageKey(`${UID}/x?query=1`, UID)).toBe(false);
    expect(isValidStorageKey(`${UID}/x#frag`, UID)).toBe(false);
    expect(isValidStorageKey(`${UID}/%2e%2e/x`, UID)).toBe(false);
    expect(isValidStorageKey(`22222222-2222-4333-8444-555555555555/x.png`, UID)).toBe(false);
    expect(isValidStorageKey(`${UID}/${"a".repeat(600)}`, UID)).toBe(false);
    expect(isValidStorageKey(null, UID)).toBe(false);
    expect(isValidStorageKey(`${UID}/`, UID)).toBe(false);
  });

  it("percent-encodes each segment without opening traversal", () => {
    expect(encodeStorageKeyPath(`${UID}/a b.png`)).toBe(`${UID}/a%20b.png`);
  });
});

describe("content disposition and filenames", () => {
  it("serves safe known media inline and everything else as attachment", () => {
    expect(contentDisposition("image/jpeg", "p.jpg", "fallback")).toContain("inline;");
    expect(contentDisposition("audio/aac", "a.aac", "fallback")).toContain("inline;");
    expect(contentDisposition("video/quicktime", "m.mov", "fallback")).toContain("inline;");
    expect(contentDisposition("application/pdf", "doc.pdf", "fallback")).toContain("attachment;");
    expect(contentDisposition(null, "mystery.bin", "fallback")).toContain("attachment;");
    expect(contentDisposition("text/html", "x.html", "fallback")).toContain("attachment;");
  });

  it("keeps CRLF and quotes out of both filename forms", () => {
    const evil = 'evil\r\nSet-Cookie: pwn=1";.png';
    const header = contentDisposition("application/pdf", evil, "fallback.pdf");
    expect(header).not.toMatch(/[\r\n]/);
    // The ASCII fallback cannot contain quotes or backslashes.
    const ascii = asciiFallbackFilename(evil, "fallback.pdf");
    expect(ascii).not.toMatch(/["\\\r\n]/);
    // RFC 5987 form percent-encodes the raw input's dangerous characters
    // (control characters are stripped outright).
    const extended = rfc5987Filename(evil, "fallback.pdf");
    expect(extended).not.toMatch(/[\r\n'"()!*]/);
    expect(extended).toContain("%3A");
    expect(extended).toContain("%22");
  });

  it("uses the fallback name when metadata is absent", () => {
    expect(asciiFallbackFilename(null, "attachment-1")).toBe("attachment-1");
    expect(asciiFallbackFilename("照片.jpg", "fallback")).toBe("__.jpg");
    expect(rfc5987Filename("照片.jpg", "fallback")).toBe("%E7%85%A7%E7%89%87.jpg");
    expect(contentDisposition("image/png", null, "attachment-1")).toContain('filename="attachment-1"');
  });
});
