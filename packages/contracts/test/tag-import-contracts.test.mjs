import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";

// Standalone tag-import contract tests. No dependencies beyond the existing Ajv.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const load = async (relativePath) =>
  JSON.parse(await readFile(resolve(root, relativePath), "utf8"));

function contractAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  ajv.addKeyword({
    keyword: "x-daypage-maxUtf8Bytes",
    schemaType: "number",
    type: "string",
    validate: (maximum, value) => Buffer.byteLength(value, "utf8") <= maximum,
  });
  ajv.addKeyword({
    keyword: "x-daypage-uniqueProperties",
    schemaType: "array",
    type: "array",
    validate: (properties, values) => {
      const seen = new Set();
      for (const item of values) {
        if (item === null || typeof item !== "object") continue;
        const key = JSON.stringify(properties.map((property) => property === "memo_id" && typeof item[property] === "string" ? item[property].toLowerCase() : item[property]));
        if (seen.has(key)) return false;
        seen.add(key);
      }
      return true;
    },
  });
  return ajv;
}

async function compiled(schemaPath) {
  const ajv = contractAjv();
  const schema = await load(schemaPath);
  if (schemaPath !== payloadSchemaPath) {
    // Snapshot schema references the payload schema across files.
    ajv.addSchema(await load(payloadSchemaPath));
  }
  return ajv.compile(schema);
}

const payloadSchemaPath = "schemas/tag-import-payload-v1.schema.json";
const resultSchemaPath = "schemas/tag-import-result-v1.schema.json";
const snapshotSchemaPath = "schemas/tag-import-snapshot-v1.schema.json";

test("rich payload fixture conforms: nested + comma + Unicode + unused catalog + outside-catalog + zero-tags", async () => {
  const validate = await compiled(payloadSchemaPath);
  const payload = await load("fixtures/tag-import-payload-v1.json");
  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));
  // Duplicate label tokens inside one memo stay legal: the raw snapshot retains
  // token duplicates while the database stores one association.
  assert.equal(payload.memos[1].tags.length, 3);
  assert.equal(new Set(payload.memos[1].tags).size, 2);
  assert.equal(payload.memos[2].tags.length, 0);
});

test("result fixture conforms and its receipt counts match the payload fixture", async () => {
  const validate = await compiled(resultSchemaPath);
  const result = await load("fixtures/tag-import-result-v1.json");
  const payload = await load("fixtures/tag-import-payload-v1.json");
  assert.equal(validate(result), true, JSON.stringify(validate.errors, null, 2));

  // Count semantics (ADR-0023): receipts describe the import snapshot.
  const memberships = new Set();
  const allLabels = new Set(payload.catalog);
  for (const memo of payload.memos) {
    for (const tag of memo.tags) {
      allLabels.add(tag);
      memberships.add(`${memo.memo_id}\u0000${tag}`);
    }
  }
  assert.equal(result.catalog_labels, payload.catalog.length);
  assert.equal(result.distinct_labels, allLabels.size);
  assert.equal(result.memos, payload.memos.length);
  assert.equal(result.memberships, memberships.size);
});

test("snapshot fixture conforms and embeds the exact payload fixture", async () => {
  const validate = await compiled(snapshotSchemaPath);
  const snapshot = await load("fixtures/tag-import-snapshot-v1.json");
  const payload = await load("fixtures/tag-import-payload-v1.json");
  assert.equal(validate(snapshot), true, JSON.stringify(validate.errors, null, 2));
  assert.deepEqual(snapshot.payload, payload);
  assert.equal(snapshot.version, 1);
});

test("snapshot created_at accepts PostgREST offset and fractional-second forms", async () => {
  const validate = await compiled(snapshotSchemaPath);
  const snapshot = await load("fixtures/tag-import-snapshot-v1.json");
  const accepted = [
    "2026-10-16T12:34:56+00:00",
    "2026-10-16T12:34:56.123+08:00",
    "2026-10-16T12:34:56.123456+00:00",
    "2026-10-16T12:34:56.123456-05:00",
    "2026-10-16T12:34:56Z",
    "2026-10-16T12:34:56.123456Z",
  ];
  for (const created_at of accepted) {
    assert.equal(
      validate({ ...snapshot, created_at }),
      true,
      `expected ${created_at} to validate: ${JSON.stringify(validate.errors)}`,
    );
  }
  const rejected = ["2026-10-16", "2026-10-16T12:34:56", "2026-10-16 12:34:56.123456+00:00", "not-a-timestamp"];
  for (const created_at of rejected) {
    assert.equal(validate({ ...snapshot, created_at }), false, `expected ${created_at} to be rejected`);
  }
});

test("payload_hash is an opaque lowerhex server-side jsonb::text fingerprint, not a portable JSON digest", async () => {
  const snapshot = await load("fixtures/tag-import-snapshot-v1.json");
  assert.match(snapshot.payload_hash, /^[0-9a-f]{64}$/);
  // Consumers must not guess a Swift/JS JSON serialization hash: pin that the
  // stored fingerprint is not any naive wire-JSON digest.
  const naiveDigests = [
    JSON.stringify(snapshot.payload),
    JSON.stringify(snapshot.payload, null, 2),
  ].map((text) => createHash("sha256").update(text, "utf8").digest("hex"));
  for (const digest of naiveDigests) {
    assert.notEqual(snapshot.payload_hash, digest);
  }
});

test("every invalid fixture is rejected by its strict schema", async () => {
  const entries = (await readdir(resolve(root, "fixtures"))).filter((name) =>
    name.startsWith("tag-import-") && name.includes(".invalid"),
  );
  assert.equal(entries.length >= 15, true, "expected invalid fixtures to cover all fault classes");
  for (const name of entries) {
    const schemaPath = name.startsWith("tag-import-payload-")
      ? payloadSchemaPath
      : name.startsWith("tag-import-result-")
        ? resultSchemaPath
        : snapshotSchemaPath;
    const validate = await compiled(schemaPath);
    assert.equal(
      validate(await load(`fixtures/${name}`)),
      false,
      `expected ${name} to be rejected`,
    );
  }
});

test("label rules: exact input preserved, only controls/DEL/shape/size bounded", async () => {
  const validate = await compiled(payloadSchemaPath);
  const withLabels = (labels) => ({
    version: 1,
    catalog: labels,
    memos: [{ memo_id: "88400000-0000-4000-8000-000000000001", tags: [] }],
  });
  const accepted = [
    "#a",
    "#a, b",
    "#a/b/c",
    "#标签/子",
    "#emoji🎉",
    "#tag#tag",
    "# leading space",
    "#вёрстка",
    "#" + "x".repeat(1023),
  ];
  for (const label of accepted) {
    assert.equal(validate(withLabels([label])), true, `expected ${JSON.stringify(label)} to validate`);
  }
  const rejected = [
    "#",
    "no-hash",
    "#a\nb",
    "#a\u007fb",
    "#a\u0001b",
    "#a\u0000b",
    "#" + "x".repeat(1024),
  ];
  for (const label of rejected) {
    assert.equal(validate(withLabels([label])), false, `expected ${JSON.stringify(label)} to be rejected`);
  }
});

test("strictness and limit boundaries", async () => {
  const validate = await compiled(payloadSchemaPath);
  const memoId = "88400000-0000-4000-8000-000000000001";

  // Boundary: exactly 200 labels per memo and 20000 catalog labels are valid.
  const twoHundred = Array.from({ length: 200 }, (_unused, index) => `#t${index}`);
  assert.equal(
    validate({ version: 1, catalog: [], memos: [{ memo_id: memoId, tags: twoHundred }] }),
    true,
  );
  const twentyThousand = Array.from({ length: 20000 }, (_unused, index) => `#t${index}`);
  assert.equal(validate({ version: 1, catalog: twentyThousand, memos: [] }), true);

  // Version is exactly 1 (type and value).
  for (const version of [0, 2, "1", 1.5, null, true]) {
    assert.equal(
      validate({ version, catalog: [], memos: [] }),
      false,
      `expected version ${JSON.stringify(version)} to be rejected`,
    );
  }

  // memo_id must be a canonical UUID; the nil UUID is not accepted.
  for (const bad of ["not-a-uuid", "88400000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000000"]) {
    assert.equal(
      validate({ version: 1, catalog: [], memos: [{ memo_id: bad, tags: [] }] }),
      false,
      `expected memo_id ${bad} to be rejected`,
    );
  }

  // Root and memo objects are closed to unknown keys (no note body can leak in).
  assert.equal(
    validate({ version: 1, catalog: [], memos: [], status: "imported" }),
    false,
  );
  assert.equal(
    validate({ version: 1, catalog: [], memos: [{ memo_id: memoId, tags: [], body: "#private note" }] }),
    false,
  );
});


test("UUID aliases are duplicate memo identities and result version is mandatory", async () => {
  const validate = await compiled(payloadSchemaPath);
  const first = "884abcde-0000-4000-8000-000000000001";
  assert.equal(validate({ version: 1, catalog: [], memos: [
    { memo_id: first, tags: [] }, { memo_id: first.toUpperCase(), tags: [] },
  ] }), false);
  const resultValidate = await compiled(resultSchemaPath);
  const result = await load("fixtures/tag-import-result-v1.json");
  const { version: _version, ...unversioned } = result;
  assert.equal(resultValidate(unversioned), false);
  assert.equal(resultValidate({ ...result, catalog_labels: 20000, distinct_labels: 70000, memberships: 50000 }), true);
  assert.equal(resultValidate({ ...result, distinct_labels: 70001 }), false);
});
