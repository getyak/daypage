import { strict as assert } from "node:assert";
import { test } from "node:test";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { previewExchange, contentDigest, sha256, EXCHANGE_LIMITS } from "../src/lib/file-exchange/preview.ts";
import { validateNoteProjection } from "../src/lib/file-exchange/note-projection.ts";

const root = fileURLToPath(new URL("../tests/fixtures/file-exchange-v1/", import.meta.url));
const encode = value => new TextEncoder().encode(JSON.stringify(value));
// Frozen native examples use ordinary fixed decimal clocks; fixture editing
// stays independent of the production Swift-number formatter.
const nativeFixtureJSON = value => Array.isArray(value) ? "[" + value.map(nativeFixtureJSON).join(",") + "]" :
  value && typeof value === "object" ? "{" + Object.keys(value).sort().map(key => nativeFixtureJSON(key) + ":" + nativeFixtureJSON(value[key])).join(",") + "}" :
  JSON.stringify(value).replaceAll("/", "\\/");
async function fixture(directory = root) {
  const files = new Map();
  async function visit(path, prefix = "") {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      if (entry.isDirectory()) await visit(join(path, entry.name), prefix + entry.name + "/");
      else files.set(prefix + entry.name, new Uint8Array(await readFile(join(path, entry.name))));
    }
  }
  await visit(directory);
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
async function editRaw(files, change) {
  const records = JSON.parse(new TextDecoder().decode(files.get("records.json")));
  const note = records.notes[0], path = `${note.namespace ? note.namespace + "/" : ""}raw/${note.day}.md`;
  const bytes = new TextEncoder().encode(change(new TextDecoder().decode(files.get(path))));
  files.set(path, bytes); note.revision = await sha256(bytes);
  files.set("records.json", encode(records)); await rewriteManifest(files);
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
  await editRaw(files, text => text.replace("type: mixed", "type: photo").replace("Synthetic exchange note / 合成笔记", ""));
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
  const files = await fixture(fileURLToPath(new URL("../tests/fixtures/file-exchange-reviews-v1/manual-review-fractional-root/", import.meta.url)));
  const records = JSON.parse(new TextDecoder().decode(files.get("records.json")));
  const note = records.notes[0], raw = `raw/${note.day}.md`, review = records.reviews[0];
  const originalReview = Uint8Array.from(files.get(review.file));
  const originalSources = structuredClone(review.sources);
  const block = new TextDecoder().decode(files.get(raw)).split("\n\n<!-- daypage-memo-separator -->\n\n")[0];
  const body = note.body + " Explicitly edited after the saved review.";
  const changed = new TextEncoder().encode(block.replace(note.body, body));
  files.set(raw, changed); note.body = body; note.revision = await sha256(changed);
  records.notes = [note]; // The second historical source is no longer in this export.
  files.set("records.json", encode(records));
  await rewriteManifest(files, manifest => { manifest.notes_count = 1; });
  const result = await previewExchange(input(files));
  assert.deepEqual(result.reviewSources, [{ generationId: review.generation_id, current: 0, changed: 1, unavailable: 1 }]);
  assert.deepEqual(result.records.reviews[0].sources, originalSources);
  assert.deepEqual(result.files.get(review.file), originalReview);
});

test("the public preview validates both actual Core review exports before any persistence", async () => {
  for (const name of ["manual-review-fractional-root", "manual-review-nested-citations"]) {
    const files = await fixture(fileURLToPath(new URL(`../tests/fixtures/file-exchange-reviews-v1/${name}/`, import.meta.url)));
    const result = await previewExchange(input(files));
    assert.equal(result.records.reviews.length, 1);
    for (const [path, bytes] of result.files) assert.deepEqual(bytes, files.get(path));
    assert.deepEqual(result.reviewSources, [{ generationId: result.records.reviews[0].generation_id, current: 2, changed: 0, unavailable: 0 }]);
  }
});

test("rehashing the public manifest cannot authorize a typed review that contradicts its raw page", async () => {
  const files = await fixture(fileURLToPath(new URL("../tests/fixtures/file-exchange-reviews-v1/manual-review-fractional-root/", import.meta.url)));
  await editRecords(files, records => { records.reviews[0].body = "Forged typed replacement after rehashing."; });
  await assert.rejects(previewExchange(input(files)), /Typed review contradicts/);
});

test("public preview preserves native UUID filename spelling and Swift-equivalent review text", async () => {
  const files = await fixture(fileURLToPath(new URL("../tests/fixtures/file-exchange-reviews-v1/manual-review-fractional-root/", import.meta.url)));
  const records = JSON.parse(new TextDecoder().decode(files.get("records.json"))), review = records.reviews[0];
  const old = review.file, path = `wiki/manual-reviews/${review.generation_id.toLowerCase()}.md`;
  const raw = Uint8Array.from(files.get(old));
  files.set(path, raw); files.delete(old); review.file = path;
  const body = review.body.replace("成", "\u{2F8B2}");
  assert.notEqual(body, review.body); assert.equal(body.normalize("NFC"), review.body.normalize("NFC"));
  review.body = body; files.set("records.json", encode(records));
  await rewriteManifest(files, manifest => { manifest.files.find(file => file.path === old).path = path; });
  const result = await previewExchange(input(files));
  assert.equal(result.records.reviews[0].file, path); assert.equal(result.records.reviews[0].body, body);
  assert.deepEqual(result.files.get(path), raw);
});

test("the native raw review byte limit allows a longer canonical-equivalent typed spelling", async () => {
  const files = await fixture(fileURLToPath(new URL("../tests/fixtures/file-exchange-reviews-v1/manual-review-fractional-root/", import.meta.url)));
  const records = JSON.parse(new TextDecoder().decode(files.get("records.json"))), review = records.reviews[0];
  const raw = new TextDecoder().decode(files.get(review.file));
  const encodedMetadata = raw.split("daypage_review: ")[1].split("\n")[0];
  const metadata = JSON.parse(Buffer.from(encodedMetadata, "base64").toString("utf8"));
  const offset = new TextEncoder().encode(raw.slice(0, raw.indexOf("\n---\n\n") + 6)).length;
  const footer = new TextDecoder().decode(files.get(review.file).slice(offset + metadata.bodyBytes));
  const body = "成".repeat(21845), typed = "\u{2F8B2}".repeat(21845);
  assert.equal(new TextEncoder().encode(body).length, 65535);
  assert.equal(new TextEncoder().encode(typed).length, 87380);
  assert.equal(body.normalize("NFC"), typed.normalize("NFC"));
  metadata.bodyBytes = 65535; metadata.bodyDigest = await sha256(new TextEncoder().encode(body));
  const header = raw.slice(0, raw.indexOf("\n---\n\n") + 6).replace(encodedMetadata, Buffer.from(nativeFixtureJSON(metadata)).toString("base64"));
  files.set(review.file, new TextEncoder().encode(header + body + footer));
  review.body = typed; files.set("records.json", encode(records)); await rewriteManifest(files);
  const result = await previewExchange(input(files));
  assert.equal(result.records.reviews[0].body, typed);
  assert.deepEqual(result.files.get(review.file), files.get(review.file));
});

test("native-equivalent typed timezone spelling is checked without rewriting it", async () => {
  const files = await fixture(fileURLToPath(new URL("../tests/fixtures/file-exchange-reviews-v1/manual-review-fractional-root/", import.meta.url)));
  const records = JSON.parse(new TextDecoder().decode(files.get("records.json"))), review = records.reviews[0];
  const raw = new TextDecoder().decode(files.get(review.file)), encodedMetadata = raw.split("daypage_review: ")[1].split("\n")[0];
  const metadata = JSON.parse(Buffer.from(encodedMetadata, "base64").toString("utf8"));
  metadata.period.timeZoneID = "Pacific/Kwajalein"; metadata.period.start -= 43200; metadata.period.end -= 43200;
  files.set(review.file, new TextEncoder().encode(raw.replace(encodedMetadata, Buffer.from(nativeFixtureJSON(metadata)).toString("base64"))));
  review.time_zone = "Pacific/\u212Awajalein"; review.start = "2026-11-06T12:00:00Z"; review.end = "2026-11-07T12:00:00Z";
  assert.equal(review.time_zone.normalize("NFC"), metadata.period.timeZoneID);
  files.set("records.json", encode(records)); await rewriteManifest(files);
  const result = await previewExchange(input(files));
  assert.equal(result.records.reviews[0].time_zone, review.time_zone);
  assert.deepEqual(result.files.get(review.file), files.get(review.file));
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
  await editRaw(files, text => text.replace('"raw/assets/fixture.txt"', JSON.stringify(path)));
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
  const id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", path = "raw/2026-11-07.md";
  const first = new TextDecoder().decode(files.get(path));
  const second = first.replace("11111111-2222-4333-8444-555555555555", id);
  files.set(path, new TextEncoder().encode(first + "\n\n<!-- daypage-memo-separator -->\n\n" + second));
  const revision = await sha256(new TextEncoder().encode(second));
  await editRecords(files, records => { records.notes.push({ ...records.notes[0], original_id: id, revision }); });
  await rewriteManifest(files, manifest => { manifest.notes_count = 2; });
  const result = await previewExchange(input(files));
  assert.equal(result.records.notes.length, 2);
  assert.equal(result.manifest.files.filter(file => file.kind === "raw").length, 1);
  assert.equal(result.manifest.files.filter(file => file.kind === "asset").length, 1);
  // Each block keeps its own exact revision, independently of the shared file.
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
    const lines = Object.entries(location).map(([key, value]) => `  ${key}: ${typeof value === "string" ? JSON.stringify(value) : value}`).join("\n");
    await editRaw(files, text => text.replace("entity_mentions: []", `location:\n${lines}\nentity_mentions: []`));
    assert.deepEqual((await previewExchange(input(files))).records.notes[0].location, location);
  }
});

test("self-consistent new hashes never authorize typed claims that contradict raw Markdown", async () => {
  for (const change of [
    note => { note.body = "Forged replacement"; },
    note => { note.created_at = "2026-11-07T02:03:05Z"; },
    note => { note.entity_mentions = ["Forged mention"]; },
    note => { note.weather = "Forged metadata"; },
    note => { note.attachments[0].kind = "photo"; },
    note => { note.attachments[0].transcript = "Forged transcript"; },
    note => { note.revision = "0".repeat(64); },
  ]) {
    const files = await fixture(); await editRecords(files, records => change(records.notes[0]));
    await assert.rejects(previewExchange(input(files)), /contradicts/);
  }
});

test("raw timestamps project decimal precision but typed wire claims cannot hide submilliseconds", async () => {
  const files = await fixture();
  await editRaw(files, text => text.replace("2026-11-07T02:03:04Z", "2026-11-07t10:03:04.1235000+08:00"));
  await editRecords(files, records => { records.notes[0].created_at = "2026-11-07t02:03:04.124000z"; });
  assert.equal((await previewExchange(input(files))).records.notes[0].created_at, "2026-11-07t02:03:04.124000z");
  await editRecords(files, records => { records.notes[0].created_at = "2026-11-07T02:03:04.124001Z"; });
  await assert.rejects(previewExchange(input(files)), /timestamp/);
});

test("unknown YAML is preserved while per-block hashes, duplicate IDs and raw UTF-8 stay authoritative", async () => {
  const files = await fixture();
  await editRaw(files, text => text.replace("type: mixed", "future_field: \"preserve exactly\"\ntype: mixed"));
  const result = await previewExchange(input(files));
  assert.deepEqual(result.files.get("raw/2026-11-07.md"), files.get("raw/2026-11-07.md"));
  const path = "raw/2026-11-07.md", original = files.get(path);
  files.set(path, new Uint8Array([...original, 255])); await rewriteManifest(files);
  await assert.rejects(previewExchange(input(files)), /UTF-8/);
  const duplicate = await fixture(), block = new TextDecoder().decode(duplicate.get(path));
  duplicate.set(path, new TextEncoder().encode(block + "\n\n<!-- daypage-memo-separator -->\n\n" + block));
  await rewriteManifest(duplicate);
  await assert.rejects(previewExchange(input(duplicate)), /Duplicate/);
});

test("nonfinite raw decoder values cannot disappear into an otherwise valid typed projection", async () => {
  for (const literal of ["nan", "inf", "1e999", "0x1p1024"]) {
    const files = await fixture();
    await editRaw(files, text => text.replace("entity_mentions: []", `location:\n  name: \"Synthetic place\"\n  lat: ${literal}\n  lng: 0\nentity_mentions: []`));
    await editRecords(files, records => { records.notes[0].location = { name: "Synthetic place" }; });
    await assert.rejects(previewExchange(input(files)), /canonical location number/);
  }
});

test("the fixed asset prefix ends at a native Character boundary without rewriting filenames", async () => {
  const files = await fixture();await renameAsset(files, "raw/assets/\u0301fixture.txt");
  await assert.rejects(previewExchange(input(files)), /Unsafe|canonical attachment/);
});

test("derived text uses native canonical Unicode equality while original bytes and distinct text stay intact", async () => {
  const files = await fixture();
  await editRaw(files, text => text.replace("Synthetic exchange note / 合成笔记", "Synthetic café note"));
  await editRecords(files, records => { records.notes[0].body = "Synthetic cafe\u0301 note"; });
  const original = files.get("raw/2026-11-07.md");
  const result = await previewExchange(input(files));
  assert.deepEqual(result.files.get("raw/2026-11-07.md"), original);
  assert.equal(result.records.notes[0].body, "Synthetic cafe\u0301 note");
  await editRecords(files, records => { records.notes[0].body = "Synthetic CAFÉ note"; });
  await assert.rejects(previewExchange(input(files)), /contradicts/);
});

test("raw attachment limits apply before hashing and shared assets are hashed only once per projection", async () => {
  for (const count of [10, 11]) {
    const files = await fixture(), asset = files.get("raw/assets/fixture.txt");
    const records = JSON.parse(new TextDecoder().decode(files.get("records.json"))), item = records.notes[0].attachments[0];
    const first = new TextDecoder().decode(files.get("raw/2026-11-07.md")).replace(/attachments:\n[\s\S]*?\n---/,
      "attachments:\n" + Array.from({ length: count }, () => `  - file: "${item.file}"\n    kind: ${item.kind}`).join("\n") + "\n---");
    const blocks = [first];
    if (count === 10) {
      const id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
      records.notes[0].attachments = Array.from({ length: count }, () => ({ ...item }));
      blocks.push(first.replace(records.notes[0].original_id, id));
      records.notes.push({ ...records.notes[0], original_id: id });
    }
    for (let i = 0; i < records.notes.length; i++) records.notes[i].revision = await sha256(new TextEncoder().encode(blocks[i]));
    files.set("raw/2026-11-07.md", new TextEncoder().encode(blocks.join("\n\n<!-- daypage-memo-separator -->\n\n")));
    files.set("records.json", encode(records));await rewriteManifest(files, manifest => { manifest.notes_count = records.notes.length; });
    const manifest = JSON.parse(new TextDecoder().decode(files.get("daypage-exchange.json")));
    let assetHashes = 0;
    const hash = async bytes => { if (bytes === asset) assetHashes++; return sha256(bytes); };
    const validating = validateNoteProjection(manifest, records, files, hash);
    if (count === 11) {
      await assert.rejects(validating, /Excessive canonical/);assert.equal(assetHashes, 0);
    } else {
      await validating;assert.equal(assetHashes, 1);assert.equal((await previewExchange(input(files))).records.notes.length, 2);
    }
  }
});

test("cancellation after the last async block validation still refuses to return a preview", async () => {
  const files = await fixture(), controller = new AbortController(), original = crypto.subtle.digest.bind(crypto.subtle);
  let calls = 0;
  crypto.subtle.digest = async (...args) => {
    const result = await original(...args);
    // This four-file golden has six digest boundaries through the final block.
    if (++calls === 6) queueMicrotask(() => queueMicrotask(() => queueMicrotask(() => controller.abort())));
    return result;
  };
  try { await assert.rejects(previewExchange(input(files), controller.signal), { name: "AbortError" }); }
  finally { crypto.subtle.digest = original; }
  assert.equal(controller.signal.aborted, true);
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
