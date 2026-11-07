import { strict as assert } from "node:assert";
import { test } from "node:test";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { previewExchange, contentDigest, sha256, EXCHANGE_LIMITS } from "../src/lib/file-exchange/preview.ts";

const root = fileURLToPath(new URL("../tests/fixtures/file-exchange-v1/", import.meta.url));
const encode = value => new TextEncoder().encode(JSON.stringify(value));
async function fixture() {
  const files = new Map();
  async function visit(path, prefix = "") {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      if (entry.isDirectory()) await visit(join(path, entry.name), prefix + entry.name + "/");
      else files.set(prefix + entry.name, new Uint8Array(await readFile(join(path, entry.name))));
    }
  }
  await visit(root);
  return files;
}
function input(files) {
  return Array.from(files, ([path, bytes]) => ({ path, size: bytes.length, read: async () => bytes }));
}
async function rewriteManifest(files, change = () => {}) {
  const manifest = JSON.parse(new TextDecoder().decode(files.get("daypage-exchange.json")));
  for (const item of manifest.files) {
    if (files.has(item.path)) { item.bytes = files.get(item.path).length; item.sha256 = await sha256(files.get(item.path)); }
  }
  change(manifest);
  manifest.content_sha256 = await contentDigest(manifest);
  files.set("daypage-exchange.json", encode(manifest));
}
async function editRecords(files, change) {
  const records = JSON.parse(new TextDecoder().decode(files.get("records.json")));
  change(records);
  files.set("records.json", encode(records));
  await rewriteManifest(files);
}

test("the frozen cross-language fixture preserves exact original bytes without a request", async () => {
  const files = await fixture();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => { throw Error("Preview must not make requests"); };
  try {
    const result = await previewExchange(input(files));
    assert.equal(result.manifest.content_sha256, "89d0622ad0956166629ee3a13c2c86a7755f0fde85267176891aee1d4ccb862d");
    assert.equal(result.records.notes[0].type, "mixed");
    assert.equal(result.records.notes[0].body, "Synthetic exchange note / 合成笔记");
    assert.deepEqual(result.files.get("raw/assets/fixture.txt"), files.get("raw/assets/fixture.txt"));
  } finally { globalThis.fetch = originalFetch; }
});

test("digest ordering follows UTF-8 bytes and never input order", async () => {
  const manifest = JSON.parse(new TextDecoder().decode((await fixture()).get("daypage-exchange.json")));
  assert.equal(await contentDigest(manifest), await contentDigest({ ...manifest, files: [...manifest.files].reverse() }));
  const first = { path: "raw/assets/\uE000.txt", kind: "asset", bytes: 1, sha256: "0".repeat(64) };
  const last = { ...first, path: "raw/assets/\u{10000}.txt" };
  const expected = `daypage-file-exchange-v1\n1\0${0}\n${first.path}\0asset\0${1}\0${first.sha256}\n${last.path}\0asset\0${1}\0${last.sha256}`;
  assert.equal(await contentDigest({ ...manifest, files: [last, first] }), await sha256(new TextEncoder().encode(expected)));
});

test("tampered assets and malformed UTF-8 fail before any network adapter", async () => {
  const files = await fixture();
  files.get("raw/assets/fixture.txt")[0] ^= 1;
  await assert.rejects(previewExchange(input(files)), /File digest mismatch/);
  files.set("daypage-exchange.json", new Uint8Array([255, 254]));
  await assert.rejects(previewExchange(input(files)), /Invalid UTF-8 JSON/);
});

test("every listed byte is bounded before payload files are read", async () => {
  const files = await fixture();
  await rewriteManifest(files, manifest => { manifest.files.find(file => file.kind === "asset").bytes = EXCHANGE_LIMITS.attachment + 1; });
  let reads = 0;
  const selected = input(files).map(file => file.path === "daypage-exchange.json" ? file : { ...file, read: async () => { reads++; return file.read(); } });
  await assert.rejects(previewExchange(selected), /Attachment exceeds exchange limit/);
  assert.equal(reads, 0);
});

test("rejects traversal, duplicate paths, unlisted files and missing originals", async () => {
  const files = await fixture();
  const selected = input(files);
  await assert.rejects(previewExchange([...selected, { path: "../secret", size: 0, read: async () => new Uint8Array() }]), /Unsafe/);
  await assert.rejects(previewExchange([...selected, selected[0]]), /duplicate/);
  const file = path => ({ path, size: 0, read: async () => new Uint8Array() });
  await assert.rejects(previewExchange([...selected, file("raw/assets/A.png"), file("raw/assets/a.png")]), /duplicate/);
  await assert.rejects(previewExchange([...selected, file("raw/assets/\u00e9.png"), file("raw/assets/e\u0301.png")]), /duplicate/);
  await assert.rejects(previewExchange([...selected, { path: "extra.txt", size: 0, read: async () => new Uint8Array() }]), /Unlisted/);
  await assert.rejects(previewExchange(selected.filter(file => file.path !== "raw/assets/fixture.txt")), /Missing/);
  await rewriteManifest(files, manifest => { manifest.files[0].path = "raw/../secret"; });
  await assert.rejects(previewExchange(input(files)), /Unsafe/);
});

test("manifest counts and namespaced record identities are enforced", async () => {
  const files = await fixture();
  await rewriteManifest(files, manifest => { manifest.notes_count++; });
  await assert.rejects(previewExchange(input(files)), /Record counts/);
  await rewriteManifest(files, manifest => { manifest.notes_count = 2; });
  await editRecords(files, records => { records.notes.push({ ...records.notes[0], original_id: records.notes[0].original_id.toUpperCase() }); });
  await assert.rejects(previewExchange(input(files)), /Duplicate source identity/);
});

test("owner fields, invalid calendar dates and dangling attachment descriptors fail closed", async () => {
  for (const mutate of [
    records => { records.notes[0].user_id = "pretend-owner"; },
    records => { records.notes[0].created_at = "2026-02-31T00:00:00Z"; },
    records => { records.notes[0].attachments[0].sha256 = "0".repeat(64); },
  ]) {
    const files = await fixture(); await editRecords(files, mutate);
    await assert.rejects(previewExchange(input(files)));
  }
});

test("image-only empty-body notes remain visible in preview without invented prose", async () => {
  const files = await fixture();
  await editRecords(files, records => { records.notes[0].body = ""; records.notes[0].type = "photo"; });
  const result = await previewExchange(input(files));
  assert.equal(result.records.notes.length, 1);
  assert.equal(result.records.notes[0].body, "");
});

test("multibyte attachment transcripts obey the native UTF-8 budget", async () => {
  const files = await fixture();
  await editRecords(files, records => { records.notes[0].attachments[0].transcript = "字".repeat(1_500_000); });
  await assert.rejects(previewExchange(input(files)), /Transcript text exceeds exchange limit/);
});

test("historical review citations retain changed and unavailable sources", async () => {
  const files = await fixture();
  const id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  const path = `wiki/manual-reviews/${id}.md`;
  files.set(path, new TextEncoder().encode("Synthetic historical review\n"));
  await editRecords(files, records => {
    const note = records.notes[0];
    records.reviews.push({ generation_id: id, namespace: "", file: path, period_kind: "day",
      start: "2026-11-07T00:00:00Z", end: "2026-11-08T00:00:00Z", time_zone: "Asia/Shanghai",
      created_at: "2026-11-07T03:00:00Z", source_digest: "0".repeat(64), body: "Synthetic historical review",
      sources: [
        { id: `/${note.day}/${note.original_id}`, namespace: "", memo_id: note.original_id, day: note.day, revision: "f".repeat(64) },
        { id: `/${note.day}/${id}`, namespace: "", memo_id: id, day: note.day, revision: "f".repeat(64) },
      ] });
  });
  await rewriteManifest(files, manifest => {
    manifest.reviews_count = 1;
    manifest.files.push({ path, kind: "review", bytes: files.get(path).length, sha256: "0".repeat(64) });
  });
  await rewriteManifest(files);
  const result = await previewExchange(input(files));
  assert.deepEqual(result.reviewSources, [{ generationId: id, current: 0, changed: 1, unavailable: 1 }]);
  assert.equal(result.records.reviews[0].sources[0].revision, "f".repeat(64));
});

test("cancellation before selection or during an async read cannot publish a preview", async () => {
  const files = await fixture();
  const aborted = new AbortController(); aborted.abort();
  await assert.rejects(previewExchange(input(files), aborted.signal), { name: "AbortError" });
  const pending = new AbortController();
  const selected = input(files).map(file => ({ ...file, read: async () => { const bytes = await file.read(); pending.abort(); return bytes; } }));
  await assert.rejects(previewExchange(selected, pending.signal), { name: "AbortError" });
});

async function renameAsset(files, path) {
  const old = "raw/assets/fixture.txt";
  files.set(path, files.get(old)); files.delete(old);
  await editRecords(files, records => { records.notes[0].attachments[0].file = path; });
  await rewriteManifest(files, manifest => { manifest.files.find(file => file.path === old).path = path; });
  await rewriteManifest(files);
}

test("typed references cover every listed raw, asset and review without permitting orphans", async () => {
  for (const [path, kind] of [
    ["raw/assets/orphan.txt", "asset"],
    ["raw/2026-11-08.md", "raw"],
    ["wiki/manual-reviews/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.md", "review"],
  ]) {
    const files = await fixture(); files.set(path, new TextEncoder().encode("Synthetic unreferenced file"));
    await rewriteManifest(files, manifest => { manifest.files.push({ path, kind, bytes: 0, sha256: "0".repeat(64) }); });
    await rewriteManifest(files);
    await assert.rejects(previewExchange(input(files)), /referenced|reference/i);
  }
});

test("several typed notes may share one raw day and an original asset", async () => {
  const files = await fixture();
  await editRecords(files, records => { records.notes.push({ ...records.notes[0], original_id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" }); });
  await rewriteManifest(files, manifest => { manifest.notes_count = 2; });
  const result = await previewExchange(input(files));
  assert.equal(result.records.notes.length, 2);
  assert.equal(result.manifest.files.filter(file => file.kind === "raw").length, 1);
  assert.equal(result.manifest.files.filter(file => file.kind === "asset").length, 1);
  // This checks reference topology only; raw/typed semantic parity is separate.
});

test("path capacity counts UTF-8 bytes and preserves valid Unicode filenames", async () => {
  const tooLong = await fixture(); await renameAsset(tooLong, "raw/assets/" + "字".repeat(180) + ".txt");
  await assert.rejects(previewExchange(input(tooLong)), /Unsafe/);
  const bounded = await fixture(), path = "raw/assets/" + "字".repeat(160) + ".txt";
  await renameAsset(bounded, path);
  assert.equal((await previewExchange(input(bounded))).files.has(path), true);
});

test("location coordinates must be paired while named-only and zero coordinates remain valid", async () => {
  for (const location of [{ lat: 12 }, { lng: 34 }]) {
    const files = await fixture(); await editRecords(files, records => { records.notes[0].location = location; });
    await assert.rejects(previewExchange(input(files)), /coordinate|location/i);
  }
  for (const location of [{ name: "Synthetic place" }, { lat: 0, lng: 0 }]) {
    const files = await fixture(); await editRecords(files, records => { records.notes[0].location = location; });
    assert.deepEqual((await previewExchange(input(files))).records.notes[0].location, location);
  }
});

test("physical imports tokens are lowercase and UUID segments remain case-insensitive", async () => {
  for (const token of ["IMPORTS", "imports"]) {
    const files = await fixture(), ns = token + "/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";
    await editRecords(files, records => { records.notes[0].namespace = ns; records.notes[0].attachments[0].file = ns + "/" + records.notes[0].attachments[0].file; });
    await rewriteManifest(files, manifest => {
      for (const file of manifest.files) if (file.kind !== "records") {
        const old = file.path; file.path = ns + "/" + old; files.set(file.path, files.get(old)); files.delete(old);
      }
    });
    await rewriteManifest(files);
    if (token === "IMPORTS") await assert.rejects(previewExchange(input(files)), /Unsafe|namespace|source/);
    else assert.equal((await previewExchange(input(files))).records.notes[0].namespace, ns);
  }
});

test("case-changed physical raw tokens are refused before reading any payload", async () => {
  const files = await fixture(), old = "raw/2026-11-07.md", path = "RAW/2026-11-07.md";
  files.set(path, files.get(old)); files.delete(old);
  await rewriteManifest(files, manifest => { manifest.files.find(file => file.path === old).path = path; });
  await rewriteManifest(files);
  let reads = 0;
  const selected = input(files).map(file => file.path === "daypage-exchange.json" ? file : { ...file, read: async () => { reads++; return file.read(); } });
  await assert.rejects(previewExchange(selected)); assert.equal(reads, 0);
});
