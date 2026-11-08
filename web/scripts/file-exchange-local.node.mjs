import test from "node:test";
import assert from "node:assert/strict";
import { crc32 } from "node:zlib";
import { projectRealm, makeOwner, ownerKey, assertSameSource, selectionPaths } from "../src/lib/file-exchange-local/model.ts";
import { storeZip, zipLayout } from "../src/lib/file-exchange-local/zip.ts";
import { OwnerEpoch } from "../src/lib/file-exchange-local/epoch.ts";
import { prepareImport } from "../src/lib/file-exchange-local/prepare.ts";
import { localPresentation } from "../src/lib/file-exchange-local/presentation.ts";
import { previewExchange } from "../src/lib/file-exchange/preview.ts";
import { readFile } from "node:fs/promises";

const id = { exportID: "11111111-1111-4111-8111-111111111111", contentDigest: "a".repeat(64),
  manifestDigest: "b".repeat(64), parserVersion: "v1" };
test("project and verified UUID isolate keys without accepting an email identity", () => {
  assert.equal(projectRealm("https://synthetic.supabase.co/"), "https://synthetic.supabase.co");
  const owner = makeOwner("https://synthetic.supabase.co", "22222222-2222-4222-8222-222222222222");
  assert.deepEqual(ownerKey(owner, "namespace"), ["https://synthetic.supabase.co", "22222222-2222-4222-8222-222222222222", "namespace"]);
  assert.throws(() => makeOwner(owner.realm, "synthetic@example.invalid"), /owner/);
  assert.throws(() => projectRealm("https://user:password@example.invalid"), /realm/);
});
test("replay includes original manifest digest and parser, even when content is unchanged", () => {
  assert.doesNotThrow(() => assertSameSource(id, { ...id }));
  for (const key of ["exportID", "contentDigest", "manifestDigest", "parserVersion"]) {
    assert.throws(() => assertSameSource(id, { ...id, [key]: "different" }), /conflict/);
  }
});
test("folder selection removes only the common selected root and preserves Unicode path bytes", () => {
  assert.deepEqual(selectionPaths([{ name: "daypage-exchange.json", webkitRelativePath: "合成/daypage-exchange.json" },
    { name: "é.txt", webkitRelativePath: "合成/raw/assets/é.txt" }]), ["daypage-exchange.json", "raw/assets/é.txt"]);
  assert.throws(() => selectionPaths([{ name: "a", webkitRelativePath: "one/a" }, { name: "b", webkitRelativePath: "two/b" }]), /folder/);
});
test("owner replacement synchronously cancels old leases and active transactions without authorizing the new owner", () => {
  const epoch = new OwnerEpoch();
  assert.throws(() => epoch.lease(), /owner-unverified/);
  epoch.authorize(makeOwner("https://synthetic.supabase.co", "22222222-2222-4222-8222-222222222222"));
  const old = epoch.lease(); let aborts = 0;
  old.track({ abort() { aborts++; } }); epoch.revoke();
  assert.equal(old.signal.aborted, true); assert.equal(aborts, 1);
  assert.throws(() => old.check()); assert.throws(() => epoch.lease(), /owner-unverified/);
  epoch.authorize(makeOwner("https://synthetic.supabase.co", "33333333-3333-4333-8333-333333333333"));
  assert.equal(epoch.lease().owner.uid, "33333333-3333-4333-8333-333333333333"); assert.throws(() => old.check());
});
test("cancel isolates one operation and never revokes another operation or deletes an owner", () => {
  const epoch = new OwnerEpoch(); epoch.authorize(makeOwner("https://synthetic.supabase.co", "22222222-2222-4222-8222-222222222222"));
  const first = epoch.lease(), second = epoch.lease(); first.cancel();
  assert.equal(first.signal.aborted, true); assert.throws(() => first.check());
  assert.equal(second.signal.aborted, false); second.check();
  let aborted = false; const release = second.track({ abort() { aborted = true; } }); release(); second.close();
  assert.equal(aborted, false); assert.equal(epoch.owner.uid, "22222222-2222-4222-8222-222222222222");
});

// Independent ZIP consumer: use central directory, validate local records and
// CRC with Node's zlib, not the writer's checksum/layout helpers.
function unzip(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), end = bytes.length - 22;
  assert.ok(end >= 0, "ZIP needs a complete end record"); assert.equal(view.getUint32(end, true), 0x06054b50);
  const count = view.getUint16(end + 10, true), found = new Map();
  let cursor = view.getUint32(end + 16, true);
  for (let i = 0; i < count; i++) {
    assert.equal(view.getUint32(cursor, true), 0x02014b50); assert.equal(view.getUint16(cursor + 10, true), 0);
    assert.equal(view.getUint16(cursor + 8, true), 0x0800);
    const size = view.getUint32(cursor + 24, true), n = view.getUint16(cursor + 28, true);
    const path = new TextDecoder("utf-8", { fatal: true }).decode(bytes.slice(cursor + 46, cursor + 46 + n));
    const local = view.getUint32(cursor + 42, true); assert.equal(view.getUint32(local, true), 0x04034b50);
    const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
    const data = bytes.slice(start, start + size); assert.equal(data.length, size);
    assert.equal(view.getUint32(cursor + 16, true), crc32(data)); found.set(path, data);
    cursor += 46 + n + view.getUint16(cursor + 30, true) + view.getUint16(cursor + 32, true);
  }
  assert.equal(cursor, end); return found;
}
test("STORE ZIP independently extracts every exact UTF8 original including empty and binary files", () => {
  const entries = [{ path: "daypage-exchange.json", bytes: new TextEncoder().encode("{\n  \"synthetic\": true\n}\n") },
    { path: "raw/assets/合成-é.bin", bytes: new Uint8Array([0, 255, 13, 10, 128]) },
    { path: "raw/assets/empty.txt", bytes: new Uint8Array() }];
  const restored = unzip(storeZip(entries)); assert.equal(restored.size, 3);
  for (const entry of entries) assert.deepEqual(restored.get(entry.path), entry.bytes);
});
test("ZIP rejects traversal, equivalent paths, overlong UTF8 names and too many entries", () => {
  const entry = path => ({ path, bytes: new Uint8Array() });
  for (const path of ["../bad", "/bad", "raw/../bad", "raw\\bad", "raw/" + "界".repeat(180), "raw/assets/" + String.fromCharCode(0xd800)]) {
    assert.throws(() => storeZip([entry(path)]), /path/);
  }
  for (const paths of [["raw/assets/A", "raw/assets/a"], ["raw/assets/é", "raw/assets/e\u0301"], ["raw/assets/ß", "raw/assets/SS"]]) {
    assert.throws(() => storeZip(paths.map(entry)), /path/);
  }
  assert.throws(() => storeZip(Array.from({ length: 1002 }, (_, i) => entry("raw/assets/" + i))), /limit/);
  assert.throws(() => zipLayout([{ path: "raw/assets/large", bytes: { byteLength: 50 * 1024 * 1024 + 256 * 1024 + 1 } }]), /byte-limit/);
});
async function fixturePreview(directory = "file-exchange-v1") {
  const root = new URL(`../tests/fixtures/${directory}/`, import.meta.url);
  const manifestBytes = new Uint8Array(await readFile(new URL("daypage-exchange.json", root)));
  const manifest = JSON.parse(new TextDecoder().decode(manifestBytes));
  const files = new Map([["daypage-exchange.json", manifestBytes]]);
  for (const file of manifest.files) files.set(file.path, new Uint8Array(await readFile(new URL(file.path, root))));
  return previewExchange([...files].map(([path, bytes]) => ({ path, size: bytes.length, read: async () => bytes })));
}
test("confirmation rechecks isolated original-byte copies and original manifest identity without network", async () => {
  const preview = await fixturePreview(), fetch = globalThis.fetch;
  globalThis.fetch = () => { throw Error("Source data must remain local"); };
  try {
    const prepared = await prepareImport(preview);
    assert.equal(prepared.identity.exportID, preview.manifest.export_id.toLowerCase());
    assert.equal(prepared.expected.length, preview.files.size + 1);
    const path = "raw/assets/fixture.txt", before = Uint8Array.from(prepared.originals.get(path));
    preview.files.get(path)[0] ^= 1;
    assert.deepEqual(prepared.originals.get(path), before);
    await assert.rejects(prepareImport(preview), /digest mismatch/);
    const restored = unzip(storeZip([...prepared.originals].map(([path, bytes]) => ({ path, bytes }))));
    for (const [path, bytes] of prepared.originals) assert.deepEqual(restored.get(path), bytes);
  } finally { globalThis.fetch = fetch; }
});
test("cancelled confirmation does not start byte validation or create an import", async () => {
  const preview = await fixturePreview(), controller = new AbortController(); controller.abort();
  await assert.rejects(prepareImport(preview, controller.signal), { name: "AbortError" });
});
test("local preparation and ZIP retain the manual-review fields and original citation files", async () => {
  const directory = "file-exchange-reviews-v1/manual-review-nested-citations";
  const original = await fixturePreview(directory), prepared = await prepareImport(original);
  assert.ok(original.records.reviews.length > 0);
  assert.deepEqual(prepared.preview.records.reviews, original.records.reviews);
  const restored = unzip(storeZip([...prepared.originals].map(([path, bytes]) => ({ path, bytes }))));
  for (const review of original.records.reviews) assert.deepEqual(restored.get(review.file), original.files.get(review.file));
});
test("active markup and unrecognized binaries never become media; UTF8 is only plain text", () => {
  const text = new TextEncoder().encode("<script>synthetic</script>");
  assert.equal(localPresentation("raw/assets/script.svg", text), null);
  assert.equal(localPresentation("raw/assets/page.html", text), null);
  assert.equal(localPresentation("raw/assets/source.txt", text), "text/plain");
  assert.equal(localPresentation("raw/assets/source.txt", new Uint8Array([255])), null);
  assert.equal(localPresentation("raw/assets/renamed.png", new Uint8Array([0, 1, 2])), null);
  assert.equal(localPresentation("raw/assets/photo", new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])), "image/png");
});
