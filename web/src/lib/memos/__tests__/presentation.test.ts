import { describe, it, expect } from "vitest";
import { importedMediaDisplayBody } from "../presentation";
import type { AttachmentRow } from "../types";

// ---------------------------------------------------------------------------
// SYNTHETIC public-API tests for the pure imported-media presentation helper
// (ADR-0026). No real vault/account data: every body, name, hash and id below
// is fabricated. The helper returns the ORIGINAL body for any uncertainty and
// the empty display body only for the exact generated placeholder set.
// ---------------------------------------------------------------------------

const OWNER = "11111111-2222-4333-8444-555555555555";
const OTHER_OWNER = "22222222-2222-4333-8444-555555555555";
const MEMO = "a1111111-0000-4000-8000-000000000001";
const OTHER_MEMO = "b2222222-0000-4000-8000-000000000002";
const SHA = "ab".repeat(32);
const SHA_B = "cd".repeat(32);
const SHA_C = "ef".repeat(32);

function genLine(label: string, name: string, target: string): string {
  return `[${label} attachment: ${name}](${target})`;
}

function flomo(sha: string, ext: string): string {
  return `raw/assets/flomo/${sha}.${ext}`;
}

function row(args: {
  id?: string;
  kind: string;
  name: string | null;
  sha: string;
  storageExt: string;
  position: number | null;
  memoId?: string;
  ownerPrefix?: string;
  storageKey?: string;
}): AttachmentRow {
  return {
    id: args.id ?? "at111111-0000-4000-8000-000000000001",
    memo_id: args.memoId ?? MEMO,
    kind: args.kind,
    storage_key: args.storageKey ?? `${args.ownerPrefix ?? OWNER}/${args.memoId ?? MEMO}/${args.sha}.${args.storageExt}`,
    filename: args.name,
    mime_type: null,
    size_bytes: 1,
    duration_sec: null,
    duration_ms: null,
    position: args.position,
    ocr_text: null,
    transcript: null,
  } as unknown as AttachmentRow;
}

function photo(sha: string, storageExt: string, name: string, position = 0): AttachmentRow {
  return row({ kind: "photo", name, sha, storageExt, position });
}

function display(
  body: string,
  attachments: readonly AttachmentRow[],
  ownerUserId: string = OWNER,
  memoId: string = MEMO,
): string {
  return importedMediaDisplayBody({ body, attachments, ownerUserId, memoId });
}

describe("importedMediaDisplayBody — validated generated-only case", () => {
  it("hides a single photo placeholder (png/jpg)", () => {
    expect(display(genLine("Photo", "a.png", flomo(SHA, "png")), [photo(SHA, "png", "a.png")])).toBe("");
    expect(display(genLine("Photo", "a.jpg", flomo(SHA, "jpg")), [photo(SHA, "jpg", "a.jpg")])).toBe("");
  });

  it("hides audio (m4a/aac) and file (MOV) placeholders", () => {
    expect(
      display(genLine("Audio", "v.m4a", flomo(SHA, "m4a")), [
        row({ kind: "audio", name: "v.m4a", sha: SHA, storageExt: "m4a", position: 0 }),
      ]),
    ).toBe("");
    expect(
      display(genLine("Audio", "v.aac", flomo(SHA, "aac")), [
        row({ kind: "audio", name: "v.aac", sha: SHA, storageExt: "aac", position: 0 }),
      ]),
    ).toBe("");
    expect(
      display(genLine("File", "c.mov", flomo(SHA, "mov")), [
        row({ kind: "file", name: "c.mov", sha: SHA, storageExt: "mov", position: 0 }),
      ]),
    ).toBe("");
  });

  it("hides the full ordered photo+audio+MOV set (positions 0..N-1)", () => {
    const body = [
      genLine("Photo", "p.png", flomo(SHA, "png")),
      genLine("Audio", "v.m4a", flomo(SHA_B, "m4a")),
      genLine("File", "c.mov", flomo(SHA_C, "mov")),
    ].join("\n");
    expect(
      display(body, [
        photo(SHA, "png", "p.png", 0),
        row({ kind: "audio", name: "v.m4a", sha: SHA_B, storageExt: "m4a", position: 1 }),
        row({ kind: "file", name: "c.mov", sha: SHA_C, storageExt: "mov", position: 2 }),
      ]),
    ).toBe("");
  });

  it("maps a .jpeg original to the canonical .jpg cloud key (and .jpg keeps .jpg)", () => {
    expect(
      display(genLine("Photo", "s.jpeg", flomo(SHA, "jpeg")), [photo(SHA, "jpg", "s.jpeg")]),
    ).toBe("");
    expect(display(genLine("Photo", "s.jpg", flomo(SHA, "jpg")), [photo(SHA, "jpg", "s.jpg")])).toBe("");
    // Either jpg/jpeg original spelling maps to the same canonical .jpg key.
    expect(
      display(genLine("Photo", "s.jpeg", flomo(SHA, "jpg")), [photo(SHA, "jpg", "s.jpeg")]),
    ).toBe("");
    // A non-canonical .jpeg storage key never corresponds to the cloud.
    expect(
      display(genLine("Photo", "s.jpeg", flomo(SHA, "jpeg")), [photo(SHA, "jpeg", "s.jpeg")]),
    ).toBe(genLine("Photo", "s.jpeg", flomo(SHA, "jpeg")));
  });

  it("accepts Unicode, combining-mark and emoji basenames byte-exactly", () => {
    const names = [
      "café.png", // NFC
      "cafe\u0301.png", // NFD (bytes differ from NFC — must match an NFD row)
      "😀.png",
      "❤️.png", // emoji + variation selector (Mn) in NAME is fine
      "日本語 の 写真.png",
      "a](b (1).png", // brackets/parens are legitimate name characters
      "tab inside.png",
    ];
    for (const name of names) {
      expect(display(genLine("Photo", name, flomo(SHA, "png")), [photo(SHA, "png", name)]), name).toBe("");
    }
    // Canonical-equivalent spellings are byte-distinct: no cross-matching.
    expect(
      display(genLine("Photo", "café.png", flomo(SHA, "png")), [photo(SHA, "png", "cafe\u0301.png")]),
    ).toBe(genLine("Photo", "café.png", flomo(SHA, "png")));
  });

  it("trims the whole body's edge whitespace before matching", () => {
    const line = genLine("Photo", "a.png", flomo(SHA, "png"));
    expect(display(`\n ${line} \n`, [photo(SHA, "png", "a.png")])).toBe("");
  });

  it("accepts a basename of exactly 255 UTF-8 bytes", () => {
    const exact = "é".repeat(125) + "x.png"; // 250 + 5 = 255 bytes
    expect(Buffer.byteLength(exact, "utf8")).toBe(255);
    expect(display(genLine("Photo", exact, flomo(SHA, "png")), [photo(SHA, "png", exact)])).toBe("");
  });

  it("is pure: frozen inputs are never mutated", () => {
    const frozenRow = Object.freeze(photo(SHA, "png", "a.png"));
    const frozenArgs = Object.freeze({
      body: genLine("Photo", "a.png", flomo(SHA, "png")),
      attachments: Object.freeze([frozenRow]) as readonly AttachmentRow[],
      ownerUserId: OWNER,
      memoId: MEMO,
    });
    expect(importedMediaDisplayBody(frozenArgs)).toBe("");
  });
});

describe("importedMediaDisplayBody — uncertainty preserves the original body", () => {
  const line = genLine("Photo", "photo.png", flomo(SHA, "png"));
  const matching = () => [photo(SHA, "png", "photo.png")];

  it("returns the body untouched for prose, code and link bodies", () => {
    const bodies = [
      `preface\n${line}`,
      `${line}\npostscript`,
      `see\n${line}\n!`,
      "```\n" + line + "\n```",
      "```\n" + line + "\n```\n" + line, // fenced copy plus real line — still not whole-body
      `# heading\n${line}`,
      `[Photo attachment: photo.png](https://example.com/${SHA}.png)`, // remote link body
      `${line} trailing text`,
      `leading text ${line}`,
    ];
    for (const body of bodies) {
      expect(display(body, matching()), body).toBe(body);
    }
  });

  it("returns the body untouched when there is nothing to present", () => {
    expect(display(line, [])).toBe(line); // no attachments
    expect(display("", matching())).toBe(""); // empty body
    expect(display("  \n\t ", matching())).toBe("  \n\t "); // whitespace-only body
  });

  it("preserves missing, extra and duplicated placeholder lines", () => {
    const two = [photo(SHA, "png", "photo.png", 0), photo(SHA_B, "png", "other.png", 1)];
    expect(display(line, two)).toBe(line); // missing second line
    expect(display(`${line}\n${line}\n${genLine("Photo", "x.png", flomo(SHA_C, "png"))}`, two)).toBe(
      `${line}\n${line}\n${genLine("Photo", "x.png", flomo(SHA_C, "png"))}`,
    ); // extra line
    expect(display(`${line}\n${line}`, two)).toBe(`${line}\n${line}`); // duplicated line
  });

  it("preserves wrong line order", () => {
    const body = [
      genLine("Photo", "a.png", flomo(SHA, "png")),
      genLine("Photo", "b.png", flomo(SHA_B, "png")),
    ].join("\n");
    const swapped = [photo(SHA_B, "png", "b.png", 0), photo(SHA, "png", "a.png", 1)];
    expect(display(body, swapped)).toBe(body);
  });

  it("preserves wrong labels and kinds (exact ASCII only)", () => {
    const variants = [
      genLine("photo", "photo.png", flomo(SHA, "png")),
      genLine("Image", "photo.png", flomo(SHA, "png")),
      genLine("Picture", "photo.png", flomo(SHA, "png")),
      genLine("Photo attachment", "photo.png", flomo(SHA, "png")),
      genLine("File", "photo.png", flomo(SHA, "png")), // label/kind mismatch
      genLine("Audio", "photo.png", flomo(SHA, "png")),
    ];
    for (const body of variants) {
      expect(display(body, matching()), body).toBe(body);
    }
    // Unknown/unsupported row kinds can never match.
    for (const kind of ["video", "document", "", "Photo"]) {
      const unknown = [photo(SHA, "png", "photo.png")];
      (unknown[0] as { kind: string }).kind = kind;
      expect(display(line, unknown), kind).toBe(line);
    }
  });

  it("preserves wrong, empty and unbounded basenames", () => {
    const wrongNames = [
      " photo.png", // edge whitespace
      "photo.png ",
      "photo.png\n",
      "pho\u200Bto.png", // ZWSP (Cf)
      "pho\u200Dto.png", // ZWJ (Cf)
      "pho\u00ADto.png", // soft hyphen (Cf)
      "\uFEFFphoto.png", // BOM (Cf)
      "pho\u202Eto.png", // RLO (Cf)
      "pho\u0007to.png", // BEL (Cc)
      "pho\u001Fto.png", // unit separator (Cc)
      "pho\u007Fto.png", // DEL (Cc)
      "pho/to.png", // separator
      "pho\\to.png", // separator
    ];
    for (const name of wrongNames) {
      const body = genLine("Photo", name, flomo(SHA, "png"));
      expect(display(body, [photo(SHA, "png", name)]), name).toBe(body);
    }
    // Case differences against the trusted row are byte-distinct names.
    for (const name of ["Photo.png", "photo.PNG"]) {
      const body = genLine("Photo", name, flomo(SHA, "png"));
      expect(display(body, matching()), name).toBe(body);
    }
    // Empty link text and a name that mismatches the trusted row.
    expect(display(genLine("Photo", "", flomo(SHA, "png")), matching())).toBe(
      genLine("Photo", "", flomo(SHA, "png")),
    );
    expect(display(genLine("Photo", "other.png", flomo(SHA, "png")), matching())).toBe(
      genLine("Photo", "other.png", flomo(SHA, "png")),
    );
  });

  it("preserves oversized basenames (>255 UTF-8 bytes) even when they match", () => {
    const name = `${"é".repeat(128)}.png`; // 256 + 4 = 260 bytes
    const body = genLine("Photo", name, flomo(SHA, "png"));
    expect(display(body, [photo(SHA, "png", name)])).toBe(body);
    const justOver = `${"é".repeat(126)}.png`; // 252 + 4 = 256 bytes
    expect(Buffer.byteLength(justOver, "utf8")).toBe(256);
    const bodyOver = genLine("Photo", justOver, flomo(SHA, "png"));
    expect(display(bodyOver, [photo(SHA, "png", justOver)])).toBe(bodyOver);
  });

  it("preserves non-64-hex and variation-selector glyph hashes", () => {
    const badHashes = [
      SHA.toUpperCase(),
      SHA.slice(0, 63),
      `${SHA}a`,
      `${"a".repeat(63)}g`,
      `a\uFE0F${"b".repeat(62)}c`, // glyph-lookalike with variation selector
      `${"a".repeat(63)}\uFE0F`,
      `０${SHA.slice(1)}`, // fullwidth zero
      "ab".repeat(31),
    ];
    for (const hash of badHashes) {
      const body = genLine("Photo", "photo.png", flomo(hash, "png"));
      expect(display(body, matching()), hash).toBe(body);
    }
  });

  it("preserves alias, traversal, query and remote targets", () => {
    const targets = [
      `raw/assets/flomo/./${SHA}.png`,
      `raw/assets/flomo/../${SHA}.png`,
      `raw//assets/flomo/${SHA}.png`,
      `./raw/assets/flomo/${SHA}.png`,
      `/raw/assets/flomo/${SHA}.png`,
      `raw\\assets\\flomo\\${SHA}.png`,
      `RAW/ASSETS/FLOMO/${SHA}.png`,
      `raw/assets/flomo/${SHA}.png?raw=1`,
      `raw/assets/flomo/${SHA}.png#x`,
      `raw/assets/flomo/%61b${SHA.slice(2)}.png`,
      `https://example.com/${SHA}.png`,
      `//example.com/${SHA}.png`,
      `raw/assets/sync/${SHA}-photo.png`, // production sync mapping is NOT accepted
      `raw/assets/flomo/${SHA}.png.png`,
      `raw/assets/flomo/${SHA}.`,
      `raw/assets/flomo/${SHA}`,
      `raw/assets/flomo/${SHA}.PNG`,
    ];
    for (const target of targets) {
      const body = genLine("Photo", "photo.png", target);
      expect(display(body, matching()), target).toBe(body);
    }
  });

  it("preserves extension/kind and link/storage mismatches", () => {
    const cases: Array<{ body: string; rows: AttachmentRow[] }> = [
      // photo with a mov/m4a target extension
      { body: genLine("Photo", "c.mov", flomo(SHA, "mov")), rows: [photo(SHA, "mov", "c.mov")] },
      { body: genLine("Photo", "v.m4a", flomo(SHA, "m4a")), rows: [photo(SHA, "m4a", "v.m4a")] },
      // audio/file with photo extensions
      {
        body: genLine("Audio", "a.png", flomo(SHA, "png")),
        rows: [row({ kind: "audio", name: "a.png", sha: SHA, storageExt: "png", position: 0 })],
      },
      {
        body: genLine("File", "a.jpg", flomo(SHA, "jpg")),
        rows: [row({ kind: "file", name: "a.jpg", sha: SHA, storageExt: "jpg", position: 0 })],
      },
      // .jpeg link but non-canonical storage extension
      { body: genLine("Photo", "s.jpeg", flomo(SHA, "jpeg")), rows: [photo(SHA, "jpeg", "s.jpeg")] },
      // .jpeg link but storage keeps a different SHA
      { body: genLine("Photo", "s.jpeg", flomo(SHA, "jpeg")), rows: [photo(SHA_B, "jpg", "s.jpeg")] },
      // link/storage extension disagreement
      { body: genLine("Photo", "s.jpeg", flomo(SHA, "jpeg")), rows: [photo(SHA, "png", "s.jpeg")] },
    ];
    for (const testCase of cases) {
      expect(display(testCase.body, testCase.rows), testCase.body).toBe(testCase.body);
    }
  });

  it("preserves wrong owner, memo and SHA correspondences", () => {
    expect(display(line, [photo(SHA, "png", "photo.png")], OTHER_OWNER)).toBe(line);
    expect(display(line, [photo(SHA, "png", "photo.png")], OWNER, OTHER_MEMO)).toBe(line);
    // Positive control: the exact correspondence hides.
    expect(display(line, [photo(SHA, "png", "photo.png")])).toBe("");
    expect(
      display(line, [
        row({ kind: "photo", name: "photo.png", sha: SHA, storageExt: "png", position: 0, memoId: OTHER_MEMO }),
      ]),
    ).toBe(line);
    // Storage key with wrong owner/memo/SHA/path spelling.
    const badKeys = [
      `${OTHER_OWNER}/${MEMO}/${SHA}.png`,
      `${OWNER}/${OTHER_MEMO}/${SHA}.png`,
      `${OWNER}/${MEMO}/${SHA_B}.png`,
      `${OWNER}/${MEMO}/${SHA}.jpeg`,
      `${OWNER}/${MEMO}/${SHA}.jpg`, // .jpeg original must map to .jpg, not vice versa
      `${OWNER}//${SHA}.png`,
      `legacy-bucket-key.png`,
      `${OWNER}/${MEMO}/${SHA}.png?x=1`,
    ];
    for (const storageKey of badKeys) {
      const rows = [
        row({ kind: "photo", name: "photo.png", sha: SHA, storageExt: "png", position: 0, storageKey }),
      ];
      expect(display(line, rows), storageKey).toBe(line);
    }
  });

  it("preserves non-contiguous, duplicated, offset and unordered positions", () => {
    const body = [
      genLine("Photo", "a.png", flomo(SHA, "png")),
      genLine("Photo", "b.png", flomo(SHA_B, "png")),
    ].join("\n");
    const a0 = photo(SHA, "png", "a.png", 0);
    const b1 = photo(SHA_B, "png", "b.png", 1);
    expect(display(body, [photo(SHA, "png", "a.png", 1), photo(SHA_B, "png", "b.png", 2)])).toBe(body); // offset 1..N
    expect(display(body, [a0, photo(SHA_B, "png", "b.png", 0)])).toBe(body); // duplicate positions
    expect(display(body, [a0, photo(SHA_B, "png", "b.png", 2)])).toBe(body); // gap
    expect(display(body, [b1, a0])).toBe(body); // rows not in position order
  });

  it("preserves unknown, null and legacy metadata", () => {
    const legacyRows = [
      row({ kind: "photo", name: null, sha: SHA, storageExt: "png", position: 0 }),
      row({ kind: "photo", name: "photo.png", sha: SHA, storageExt: "png", position: null }),
      row({ kind: "photo", name: "photo.png", sha: SHA, storageExt: "png", position: 0, storageKey: "" }),
      row({ kind: "photo", name: "photo.png", sha: SHA, storageExt: "png", position: 0, storageKey: "assets/old.png" }),
    ];
    for (const rows of legacyRows) {
      expect(display(line, [rows]), rows.storage_key).toBe(line);
    }
  });

  it("keeps the original body byte-identical for every uncertain input", () => {
    const messy = `${line}\r\n${line}  \n\n`;
    expect(display(messy, matching())).toBe(messy);
    // Whole-body trimming covers Unicode whitespace edges (as the native
    // helper's whitespaces-and-newlines trim does).
    expect(display(` ${line}\u00A0`, matching())).toBe("");
  });
});
