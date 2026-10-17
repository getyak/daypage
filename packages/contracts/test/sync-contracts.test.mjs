import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";
import { attachmentManifestHash } from "../manifest-hash.mjs";
import { systemActionPayloadHash } from "../system-action-hash.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const load = async (relativePath) =>
  JSON.parse(await readFile(resolve(root, relativePath), "utf8"));

function contractAjv(options = {}) {
  const ajv = new Ajv2020({ allErrors: true, strict: true, ...options });
  ajv.addKeyword({
    keyword: "x-daypage-maxUtf8Bytes",
    schemaType: "number",
    type: "string",
    validate: (maximum, value) => Buffer.byteLength(value, "utf8") <= maximum,
  });
  ajv.addKeyword({
    keyword: "x-daypage-after",
    schemaType: "string",
    type: "string",
    validate: (field, value, _parentSchema, context) => {
      const other = context?.parentData?.[field];
      return typeof other === "string" && Date.parse(value) > Date.parse(other);
    },
  });
  ajv.addKeyword({
    keyword: "x-daypage-canonicalTimestamp",
    schemaType: "boolean",
    type: "string",
    validate: (_enabled, value) => {
      const parsed = new Date(value);
      return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
    },
  });
  return ajv;
}

const cases = [
  ["sync push", "schemas/sync-push-v1.schema.json", "fixtures/sync-push-v1.json"],
  ["sync push result", "schemas/sync-push-result-v1.schema.json", "fixtures/sync-push-result-v1.json"],
  ["sync pull request", "schemas/sync-pull-request-v1.schema.json", "fixtures/sync-pull-request-v1.json"],
  ["sync pull page", "schemas/sync-pull-page-v1.schema.json", "fixtures/sync-pull-page-v1.json"],
  ["sync push v2", "schemas/sync-push-v2.schema.json", "fixtures/sync-push-v2.json"],
  ["sync push result v2", "schemas/sync-push-result-v2.schema.json", "fixtures/sync-push-result-v2.json"],
  ["sync pull page v2", "schemas/sync-pull-page-v2.schema.json", "fixtures/sync-pull-page-v2.json"],
  ["imported media push v2", "schemas/sync-push-v2.schema.json", "fixtures/imported-media-aac-quicktime-v2.json"],
  ["attachment upload prepare v2", "schemas/attachment-upload-prepare-v2.schema.json", "fixtures/attachment-upload-prepare-v2.json"],
  ["attachment upload prepared v2", "schemas/attachment-upload-prepared-v2.schema.json", "fixtures/attachment-upload-prepared-v2.json"],
  ["system action proposal v1", "schemas/system-action-proposal-v1.schema.json", "fixtures/system-action-proposal-v1.json"],
  ["system action approval v1", "schemas/system-action-approval-v1.schema.json", "fixtures/system-action-approval-v1.json"],
  ["system action receipt v1", "schemas/system-action-receipt-v1.schema.json", "fixtures/system-action-receipt-v1.json"],
  ["system action capability policy v1", "schemas/system-action-capability-policy-v1.schema.json", "fixtures/system-action-capability-policy-v1.json"],
  ["system action push result v1", "schemas/system-action-push-result-v1.schema.json", "fixtures/system-action-push-result-v1.json"],
  ["system action pull page v1", "schemas/system-action-pull-page-v1.schema.json", "fixtures/system-action-pull-page-v1.json"],
  ["system action execution claim v1", "schemas/system-action-execution-claim-v1.schema.json", "fixtures/system-action-execution-claim-v1.json"],
];

for (const [name, schemaPath, fixturePath] of cases) {
  test(`${name} fixture conforms to its canonical schema`, async () => {
    const ajv = contractAjv();
    const validate = ajv.compile(await load(schemaPath));
    const valid = validate(await load(fixturePath));
    assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  });
}

const invalidSystemActionCases = [
  ["proposal rejects a mismatched kind/payload", "system-action-proposal-v1"],
  ["approval rejects an invalid decision and hash", "system-action-approval-v1"],
  ["receipt rejects raw external identifiers and inconsistent success", "system-action-receipt-v1"],
  ["policy rejects synchronized OS authorization", "system-action-capability-policy-v1"],
  ["push result rejects unrecognized status and cursor zero", "system-action-push-result-v1"],
  ["pull page excludes execution leases", "system-action-pull-page-v1"],
  ["claim enforces claimed lease evidence", "system-action-execution-claim-v1"],
];

for (const [name, base] of invalidSystemActionCases) {
  test(name, async () => {
    const validate = contractAjv().compile(
      await load(`schemas/${base}.schema.json`),
    );
    assert.equal(validate(await load(`fixtures/${base}.invalid.json`)), false);
  });
}

test("every system action proposal payload kind matches the proposal kind", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.kind = "reminder";
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("creating-device proposals require the creator device hash", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.target_device_preference = "creating_device";
  fixture.creator_device_id_hash = null;
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("MCP proposals are private until native approval", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.redaction_level = "sensitive";
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("route proposals accept an address without pre-resolved coordinates", async () => {
  const fixture = await load("fixtures/system-action-route-address-v1.json");
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), true);
  assert.equal(fixture.payload_hash, systemActionPayloadHash(fixture.payload));
});

test("route proposals reject a half coordinate pair", async () => {
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(await load("fixtures/system-action-route-half-coordinates-v1.invalid.json")), false);
});

test("route proposals reject address and coordinates together", async () => {
  const fixture = await load("fixtures/system-action-route-address-v1.json");
  fixture.payload.destination_latitude = 31.2304;
  fixture.payload.destination_longitude = 121.4737;
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("route proposals reject a whitespace-only address", async () => {
  const fixture = await load("fixtures/system-action-route-address-v1.json");
  fixture.payload.destination_address = "   ";
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("system action timestamps require the canonical UTC millisecond wire form", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.payload.start_at = "2026-08-27T09:00:00+08:00";
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("calendar proposals require an end strictly after the start", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.payload.end_at = fixture.payload.start_at;
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("proposal text limits count UTF-8 bytes, not Unicode scalars", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.title = "🙂".repeat(41);
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(fixture.title.length <= 160, true);
  assert.equal(validate(fixture), false);
});

test("moment location disclosure cannot disagree with place presence", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.kind = "moment";
  fixture.payload = {
    kind: "moment",
    captured_at: "2026-08-27T01:00:00.000Z",
    title: null,
    place_label: null,
    people_refs: [],
    include_one_shot_location: true,
  };
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("capture and moment titles are required nullable hash fields", async () => {
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.kind = "capture";
  fixture.payload = {
    kind: "capture",
    mode: "scan",
    destination: "new_memo",
    suggested_title: "Bound title",
  };
  assert.equal(validate(fixture), true, JSON.stringify(validate.errors, null, 2));
  delete fixture.payload.suggested_title;
  assert.equal(validate(fixture), false);

  fixture.kind = "moment";
  fixture.payload = {
    kind: "moment",
    captured_at: "2026-08-27T01:00:00.000Z",
    title: "Bound moment",
    place_label: "Current place",
    people_refs: [],
    include_one_shot_location: true,
  };
  assert.equal(validate(fixture), true, JSON.stringify(validate.errors, null, 2));
  fixture.payload.place_label = "   ";
  assert.equal(validate(fixture), false);
});

test("proposal source references are unique", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.source_refs.push(structuredClone(fixture.source_refs[0]));
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("local context requires observed_at and summary-only disclosure", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.kind = "local_context_attachment";
  fixture.payload = {
    kind: "local_context_attachment",
    context_kind: "weather_summary",
    local_reference: "22222222-2222-4222-8222-222222222222",
    disclosure: "local_only",
  };
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("focus sessions require the end-alert decision in the approved hash", async () => {
  const fixture = await load("fixtures/system-action-proposal-v1.json");
  fixture.kind = "focus_session";
  fixture.payload = {
    kind: "focus_session",
    title: "Deep work",
    duration_seconds: 1_500,
    allow_live_activity: true,
  };
  const validate = contractAjv().compile(
    await load("schemas/system-action-proposal-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("sync operation results cannot echo arbitrary record keys", async () => {
  const fixture = await load("fixtures/system-action-push-result-v1.json");
  fixture.accepted[0].record.raw_external_identifier = "calendar-secret";
  const validate = contractAjv().compile(
    await load("schemas/system-action-push-result-v1.schema.json"),
  );
  assert.equal(validate(fixture), false);
});

test("system action fixtures bind approvals and receipts to the canonical payload hash", async () => {
  const proposal = await load("fixtures/system-action-proposal-v1.json");
  const approval = await load("fixtures/system-action-approval-v1.json");
  const receipt = await load("fixtures/system-action-receipt-v1.json");
  const expected = systemActionPayloadHash(proposal.payload);
  assert.equal(proposal.payload_hash, expected);
  assert.equal(approval.payload_hash, expected);
  assert.equal(receipt.payload_hash, expected);
});

test("approval replacement invariant is expressible in ordinary JSON Schema", async () => {
  const schema = await load("schemas/system-action-approval-v1.schema.json");
  const validate = contractAjv().compile(schema);
  const approval = await load("fixtures/system-action-approval-v1.json");
  approval.has_replacement = true;
  assert.equal(validate(approval), false, "approve cannot carry replacement");

  approval.decision = "reject";
  assert.equal(validate(approval), true, JSON.stringify(validate.errors, null, 2));
  approval.has_replacement = "yes";
  assert.equal(validate(approval), false, "replacement marker must be boolean");
});

test("system action coordinate hashes use the cross-platform fixed-point vector", () => {
  const payload = {
    kind: "route",
    destination_label: "Tiny",
    destination_latitude: 0.000001,
    destination_longitude: -0.000001,
    transport: "walking",
  };
  assert.equal(
    systemActionPayloadHash(payload),
    "0daab34946dd400a4389a48450bc75f500670c92983d722170361bc5119338df",
  );
  assert.throws(
    () => systemActionPayloadHash({ ...payload, destination_latitude: 0.0000001 }),
    /six decimal places/,
  );
});

test("attempt-2 receipt operations retain the proposal revision in their envelope", async () => {
  const receipt = await load("fixtures/system-action-receipt-v1.json");
  receipt.attempt = 2;
  const validate = contractAjv().compile(
    await load("schemas/system-action-receipt-v1.schema.json"),
  );
  assert.equal(validate(receipt), true, JSON.stringify(validate.errors, null, 2));

  const operation = {
    entity_type: "receipt",
    revision: receipt.proposal_revision,
    record: receipt,
  };
  assert.equal(operation.revision, operation.record.proposal_revision);
  assert.notEqual(operation.revision, operation.record.attempt);
});

test("terminal claim retries carry receipt evidence and no executable lease", async () => {
  const claim = await load("fixtures/system-action-execution-claim-v1.json");
  claim.status = "attempt_completed";
  claim.lease_id = null;
  claim.issued_at = null;
  claim.expires_at = null;
  claim.receipt_id = "44444444-4444-4444-8444-444444444444";
  const validate = contractAjv().compile(
    await load("schemas/system-action-execution-claim-v1.schema.json"),
  );
  assert.equal(validate(claim), true, JSON.stringify(validate.errors, null, 2));
  claim.receipt_id = null;
  assert.equal(validate(claim), false);
});

test("capability policy deny and privacy downgrade are fail-closed", async () => {
  const validate = contractAjv().compile(
    await load("schemas/system-action-capability-policy-v1.schema.json"),
  );
  const policy = await load("fixtures/system-action-capability-policy-v1.json");
  policy.is_offered = false;
  policy.sync_enabled = false;
  policy.disclosure_level = "private";
  assert.equal(validate(policy), true, JSON.stringify(validate.errors, null, 2));

  policy.sync_enabled = true;
  policy.disclosure_level = "full_proposal";
  assert.equal(validate(policy), false);
});

test("delete operations cannot smuggle an upsert payload", async () => {
  const fixture = await load("fixtures/sync-push-v1.json");
  fixture.p_operations[1].payload = fixture.p_operations[0].payload;
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/sync-push-v1.schema.json")
  );
  assert.equal(validate(fixture), false);
});

test("upserts require a non-empty body and a content hash", async () => {
  const fixture = await load("fixtures/sync-push-v1.json");
  fixture.p_operations[0].payload.body = "";
  delete fixture.p_operations[0].content_hash;
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/sync-push-v1.schema.json")
  );
  assert.equal(validate(fixture), false);
});

test("pull fixture preserves a strict monotonic cursor", async () => {
  const page = await load("fixtures/sync-pull-page-v1.json");
  const after = 40;
  const sequences = page.changes.map((change) => change.change_sequence);
  assert.deepEqual(sequences, [...sequences].sort((a, b) => a - b));
  assert.equal(new Set(sequences).size, sequences.length);
  assert.ok(sequences.every((sequence) => sequence > after));
  assert.equal(page.next_cursor, sequences.at(-1));
});

test("v2 fixture carries its canonical attachment manifest hash", async () => {
  const fixture = await load("fixtures/sync-push-v2.json");
  const operation = fixture.p_operations[0];
  assert.equal(
    attachmentManifestHash(operation.payload.attachments),
    operation.attachment_manifest_hash
  );
});

test("v2 delete cannot smuggle attachment durability", async () => {
  const fixture = await load("fixtures/sync-push-v2.json");
  fixture.p_operations[1].attachment_manifest_hash = fixture.p_operations[0].attachment_manifest_hash;
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/sync-push-v2.schema.json")
  );
  assert.equal(validate(fixture), false);
});

test("v2 attachment path and MIME restrictions fail closed", async () => {
  const fixture = await load("fixtures/sync-push-v2.json");
  const attachment = fixture.p_operations[0].payload.attachments[0];
  attachment.object_key = "../other-user/photo.jpg";
  attachment.mime_type = "application/x-executable";
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/sync-push-v2.schema.json")
  );
  assert.equal(validate(fixture), false);
});

// Settled imported-media compatibility slice (issue #884, ADR-0020):
// AAC is always kind audio; QuickTime MOV is always kind file.
const settledAttachmentMappings = [
  ["photo", "image/jpeg", "jpg"],
  ["photo", "image/png", "png"],
  ["photo", "image/heic", "heic"],
  ["photo", "image/heif", "heif"],
  ["audio", "audio/m4a", "m4a"],
  ["audio", "audio/mp4", "mp4"],
  ["audio", "audio/aac", "aac"],
  ["file", "application/pdf", "pdf"],
  ["file", "video/quicktime", "mov"],
];

test("imported media fixtures carry their canonical attachment manifest hash", async () => {
  for (const base of [
    "imported-media-aac-quicktime-v2",
    "imported-media-mov-photo-v2.invalid",
    "imported-media-aac-file-v2.invalid",
    "imported-media-renamed-extension-v2.invalid",
  ]) {
    const fixture = await load(`fixtures/${base}.json`);
    const operation = fixture.p_operations[0];
    assert.equal(
      attachmentManifestHash(operation.payload.attachments),
      operation.attachment_manifest_hash,
      base,
    );
  }
});

test("imported media wrong-kind and renamed fixtures fail closed", async () => {
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/sync-push-v2.schema.json"),
  );
  for (const base of [
    "imported-media-mov-photo-v2.invalid",
    "imported-media-aac-file-v2.invalid",
    "imported-media-renamed-extension-v2.invalid",
  ]) {
    assert.equal(
      validate(await load(`fixtures/${base}.json`)),
      false,
      base,
    );
  }
});

test("v2 schema binds kind, MIME, and extension for every settled mapping", async () => {
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/sync-push-v2.schema.json"),
  );
  const template = await load("fixtures/sync-push-v2.json");
  for (const [kind, mimeType, extension] of settledAttachmentMappings) {
    const fixture = structuredClone(template);
    const attachment = fixture.p_operations[0].payload.attachments[0];
    attachment.kind = kind;
    attachment.mime_type = mimeType;
    attachment.object_key = attachment.object_key.replace(/\.[a-z0-9]+$/, `.${extension}`);
    attachment.original_filename = `sample.${extension}`;
    assert.equal(
      validate(fixture),
      true,
      `${kind}/${mimeType}/${extension}: ${JSON.stringify(validate.errors, null, 2)}`,
    );

    const wrongKind = kind === "audio" ? "file" : "audio";
    fixture.p_operations[0].payload.attachments[0].kind = wrongKind;
    assert.equal(
      validate(fixture),
      false,
      `${wrongKind}/${mimeType}/${extension} must fail closed`,
    );
  }
});

test("QuickTime MOV is never a photo and AAC is never a file on the wire", async () => {
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/sync-push-v2.schema.json"),
  );
  const template = await load("fixtures/imported-media-aac-quicktime-v2.json");

  const movAsPhoto = structuredClone(template);
  movAsPhoto.p_operations[0].payload.attachments[1].kind = "photo";
  assert.equal(validate(movAsPhoto), false);

  const aacAsFile = structuredClone(template);
  aacAsFile.p_operations[0].payload.attachments[0].kind = "file";
  assert.equal(validate(aacAsFile), false);
});

test("attachment upload preparation v2 binds MIME to the canonical extension", async () => {
  const validate = contractAjv({ strict: false }).compile(
    await load("schemas/attachment-upload-prepare-v2.schema.json"),
  );
  const template = await load("fixtures/attachment-upload-prepare-v2.json");
  for (const [, mimeType, extension] of settledAttachmentMappings) {
    const fixture = structuredClone(template);
    fixture.mime_type = mimeType;
    fixture.extension = extension;
    assert.equal(
      validate(fixture),
      true,
      `${mimeType}/${extension}: ${JSON.stringify(validate.errors, null, 2)}`,
    );
    fixture.extension = extension === "pdf" ? "jpg" : "pdf";
    assert.equal(validate(fixture), false, `${mimeType} with a valid but wrong extension`);
  }
});
