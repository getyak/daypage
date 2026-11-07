import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { validateReviewProjection, swiftJSONNumber } from '../src/lib/file-exchange/review-projection.ts';
import { projectReviewReferenceSeconds } from '../src/lib/file-exchange/timestamp.ts';

const root = new URL('../tests/fixtures/file-exchange-reviews-v1/', import.meta.url);
const encode = text => new TextEncoder().encode(text);
const decode = bytes => new TextDecoder().decode(bytes);
const hash = async bytes => createHash('sha256').update(bytes).digest('hex');
async function fixture(name = 'manual-review-fractional-root') {
  const files = new Map();
  async function visit(folder, prefix = '') {
    for (const item of await readdir(folder, { withFileTypes: true })) {
      if (item.isDirectory()) await visit(new URL(item.name + '/', folder), prefix + item.name + '/');
      else files.set(prefix + item.name, new Uint8Array(await readFile(new URL(item.name, folder))));
    }
  }
  await visit(new URL(name + '/', root));
  return files;
}
function records(files) { return JSON.parse(decode(files.get('records.json'))); }
function rawPage(files) {
  const review = records(files).reviews[0], raw = decode(files.get(review.file));
  const base64 = raw.split('daypage_review: ')[1].split('\n')[0];
  const metadata = Buffer.from(base64, 'base64').toString('utf8');
  return { review, raw, base64, metadata, value: JSON.parse(metadata) };
}
// Test construction is independent of the production formatter. Existing native
// values are fixed decimals; special-number tests supply literal oracle tokens.
function json(value) {
  if (Array.isArray(value)) return '[' + value.map(json).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(k => json(k) + ':' + json(value[k])).join(',') + '}';
  return JSON.stringify(value).replaceAll('/', '\\/');
}
function editMetadata(files, change, changeText = value => value) {
  const page = rawPage(files); change(page.value);
  const metadata = changeText(json(page.value));
  files.set(page.review.file, encode(page.raw.replace(page.base64, Buffer.from(metadata).toString('base64'))));
}
function editTyped(files, change) { const value = records(files); change(value.reviews[0], value); files.set('records.json', encode(JSON.stringify(value))); }
async function setBody(files, body) {
  const page = rawPage(files), headerEnd = page.raw.indexOf('\n---\n\n') + 6;
  const footer = decode(files.get(page.review.file).slice(headerEnd + page.value.bodyBytes));
  page.value.bodyBytes = encode(body).length; page.value.bodyDigest = await hash(encode(body));
  const header = page.raw.slice(0, headerEnd).replace(page.base64, Buffer.from(json(page.value)).toString('base64'));
  files.set(page.review.file, encode(header + body + footer)); editTyped(files, r => { r.body = body; });
}
function lowercaseReviewFile(files) {
  const value = records(files), review = value.reviews[0], original = review.file;
  const pieces = original.split('/'); pieces[pieces.length - 1] = pieces.at(-1).toLowerCase();
  const renamed = pieces.join('/'); files.set(renamed, files.get(original)); files.delete(original); review.file = renamed;
  files.set('records.json', encode(JSON.stringify(value)));
  const manifest = JSON.parse(decode(files.get('daypage-exchange.json'))); manifest.files.find(file => file.path === original).path = renamed;
  files.set('daypage-exchange.json', encode(JSON.stringify(manifest)));
  return { original, renamed };
}
async function input(files) {
  const manifest = JSON.parse(decode(files.get('daypage-exchange.json')));
  for (const file of manifest.files) { file.bytes = files.get(file.path).length; file.sha256 = await hash(files.get(file.path)); }
  const rows = [...manifest.files].sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)))
    .map(f => `${f.path}\0${f.kind}\0${f.bytes}\0${f.sha256}`);
  manifest.content_sha256 = await hash(encode(`daypage-file-exchange-v1\n${manifest.notes_count}\0${manifest.reviews_count}\n${rows.join('\n')}`));
  return { manifest, records: records(files) };
}
async function validate(files, hasher = hash, signal) {
  const value = await input(files);
  await validateReviewProjection(value.manifest, value.records, files, hasher, signal);
}
function setPeriod(files, kind, zone, start, end) {
  const first = Date.parse(start) / 1000 - 978307200, last = Date.parse(end) / 1000 - 978307200;
  editMetadata(files, m => { m.period = { kind, timeZoneID: zone, start: first, end: last }; });
  const page = rawPage(files);
  files.set(page.review.file, encode(page.raw.replace(/^---\ntype: manual_(?:day|week)_review/, `---\ntype: manual_${kind}_review`)));
  editTyped(files, r => { r.period_kind = kind; r.time_zone = zone; r.start = projectReviewReferenceSeconds(first); r.end = projectReviewReferenceSeconds(last); });
}

test('both original Core-generated examples validate without network and retain every byte', async () => {
  const original = globalThis.fetch; globalThis.fetch = () => { throw Error('No request is authorized'); };
  try {
    for (const name of ['manual-review-fractional-root', 'manual-review-nested-citations']) {
      const files = await fixture(name), before = new Map([...files].map(([p, b]) => [p, Buffer.from(b)]));
      const manifest = JSON.parse(decode(files.get('daypage-exchange.json')));
      assert.equal(manifest.content_sha256, name.endsWith('fractional-root')
        ? '093022d69b7dab94724e59da77107612f772145ee2b3c23b358427d1fb09b04f'
        : '0443a2b3a94c0526c22fd0b215e72042a41dca41f7cca2e1587a560e863c30f6');
      for (const file of manifest.files) { assert.equal(await hash(files.get(file.path)), file.sha256); assert.equal(files.get(file.path).length, file.bytes); }
      await validate(files);
      for (const [path, bytes] of before) assert.deepEqual(files.get(path), new Uint8Array(bytes));
    }
  } finally { globalThis.fetch = original; }
});

test('real nested source paths and 169-hour DST ISO week remain intact', async () => {
  const files = await fixture('manual-review-nested-citations'); await validate(files);
  const r = records(files).reviews[0];
  assert.equal((Date.parse(r.end) - Date.parse(r.start)) / 3600000, 169);
  assert.equal(r.time_zone, 'America/New_York');
  assert.match(r.sources[1].namespace, /^imports\/[A-F0-9-]+\/imports\/[A-F0-9-]+$/);
  assert.match(r.body, /## Sources/);
});

test('Swift-equivalent typed Unicode body is accepted without rewriting raw bytes or hashes', async () => {
  const files = await fixture(), raw = rawPage(files), bytes = files.get(raw.review.file).slice();
  // U+2F8B2 is the canonical CJK equivalent of the existing U+6210 in the
  // genuine Core-produced body. No raw fixture or body hash is regenerated.
  editTyped(files, r => { r.body = r.body.replace('成', '\u{2f8b2}'); });
  assert.notEqual(records(files).reviews[0].body, raw.review.body);
  assert.equal(records(files).reviews[0].body.normalize('NFC'), raw.review.body.normalize('NFC'));
  await validate(files); assert.deepEqual(files.get(raw.review.file), bytes);
  const corrupt = await fixture(), page = rawPage(corrupt);
  corrupt.set(page.review.file, encode(page.raw.replace('成', '\u{2f8b2}')));
  await assert.rejects(validate(corrupt), 'Canonical semantic equality does not authorize rewriting hashed raw bytes');
});

test('Core UUID-equivalent lowercase review basename preserves the exact selected path', async () => {
  const files = await fixture(), original = rawPage(files), bytes = files.get(original.review.file).slice();
  const { renamed } = lowercaseReviewFile(files);
  await validate(files); assert.deepEqual(files.get(renamed), bytes);
  assert.equal(records(files).reviews[0].generation_id, original.review.generation_id);
  const wrongPath = await fixture(), paths = lowercaseReviewFile(wrongPath);
  editTyped(wrongPath, r => { r.file = paths.original; });
  await assert.rejects(validate(wrongPath), 'A UUID-equivalent basename does not normalize file lookup keys');
});

test('Swift shortest-number formatting covers zero, exponent thresholds and binary64 extremes', () => {
  const values = [[0, '0'], [-0, '-0'], [1e-4, '0.0001'], [1e-5, '1e-05'], [-1e-7, '-1e-07'],
    [2 ** 53, '9007199254740992'], [2 ** 53 + 2, '9.007199254740994e+15'], [1e20, '1e+20'],
    [Number.MIN_VALUE, '5e-324'], [-Number.MIN_VALUE, '-5e-324'], [Number.MAX_VALUE, '1.7976931348623157e+308']];
  for (const [value, expected] of values) assert.equal(swiftJSONNumber(value), expected);
  for (const value of [NaN, Infinity, -Infinity]) assert.throws(() => swiftJSONNumber(value));
});

test('deterministic actual Swift oracle agrees for all supplied finite bit patterns', { skip: !process.env.DAYPAGE_SWIFT_DOUBLE_ORACLE }, async () => {
  const rows = (await readFile(process.env.DAYPAGE_SWIFT_DOUBLE_ORACLE, 'utf8')).trim().split('\n');
  const view = new DataView(new ArrayBuffer(8));
  for (const row of rows) {
    const [bits, description] = row.split('\t'); view.setBigUint64(0, BigInt('0x' + bits));
    assert.equal(swiftJSONNumber(view.getFloat64(0)), description.endsWith('.0') ? description.slice(0, -2) : description, bits);
  }
  assert.ok(rows.length > 100000);
});

test('near-reference-epoch scientific, negative-zero and subnormal Date fields are not narrowed away', async () => {
  for (const [token, value] of [['0', 0], ['-0', -0], ['1e-07', 1e-7], ['-1e-07', -1e-7], ['5e-324', Number.MIN_VALUE]]) {
    const files = await fixture();
    editMetadata(files, () => {}, text => text.replace(/"created":[^,}]*/, '"created":' + token));
    editTyped(files, r => { r.created_at = projectReviewReferenceSeconds(value); });
    await validate(files);
  }
});

test('actual Core JSONEncoder Double/Date and Date decode/reencode agree for supplied native samples', { skip: !process.env.DAYPAGE_SWIFT_JSON_ORACLE }, async () => {
  const rows = (await readFile(process.env.DAYPAGE_SWIFT_JSON_ORACLE, 'utf8')).trim().split('\n'), view = new DataView(new ArrayBuffer(8));
  for (const row of rows) {
    const [bits, scalar, date, stable] = row.split('\t'); view.setBigUint64(0, BigInt('0x' + bits));
    const expected = '{"created":' + swiftJSONNumber(view.getFloat64(0)) + '}';
    assert.equal(scalar, expected, bits + ' scalar'); assert.equal(date, expected, bits + ' date'); assert.equal(stable, 'true', bits + ' roundtrip');
  }
  assert.ok(rows.length > 100000);
});

test('local calendar periods support DST changes, repeated/skipped midnight and historical second offsets', async () => {
  const cases = [
    ['day', 'America/New_York', '2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z'],
    ['day', 'America/New_York', '2026-11-01T04:00:00Z', '2026-11-02T05:00:00Z'],
    ['day', 'Australia/Lord_Howe', '2026-10-03T13:30:00Z', '2026-10-04T13:00:00Z'],
    ['day', 'America/Sao_Paulo', '2018-11-04T03:00:00Z', '2018-11-05T02:00:00Z'],
    ['day', 'America/Havana', '2026-11-01T04:00:00Z', '2026-11-02T05:00:00Z'],
    ['day', 'Pacific/Apia', '2011-12-29T10:00:00Z', '2011-12-30T10:00:00Z'],
    ['day', 'Europe/Paris', '1899-12-31T23:50:39Z', '1900-01-01T23:50:39Z'],
    ['week', 'America/New_York', '2026-03-02T05:00:00Z', '2026-03-09T04:00:00Z'],
  ];
  for (const [kind, zone, start, end] of cases) {
    const files = await fixture(); setPeriod(files, kind, zone, start, end); await validate(files);
  }
});

test('a wrong local boundary, Sunday week, fixed 168h DST week or unknown zone rejects even after rehash', async () => {
  const cases = [
    ['day', 'America/New_York', '2026-03-08T05:00:01Z', '2026-03-09T04:00:00Z'],
    ['day', 'America/Havana', '2026-11-01T05:00:00Z', '2026-11-02T05:00:00Z'],
    ['week', 'America/New_York', '2026-11-01T04:00:00Z', '2026-11-08T05:00:00Z'],
    ['week', 'America/New_York', '2026-10-26T04:00:00Z', '2026-11-02T04:00:00Z'],
    ['day', 'Not/A_Time_Zone', '2026-11-07T00:00:00Z', '2026-11-08T00:00:00Z'],
    ['day', '+00:00', '2026-11-07T00:00:00Z', '2026-11-08T00:00:00Z'],
  ];
  for (const [kind, zone, start, end] of cases) {
    const files = await fixture(); setPeriod(files, kind, zone, start, end); await assert.rejects(validate(files));
  }
});

test('raw metadata must have exact known shape, types, version, IDs and citation identities', async () => {
  const changes = [
    m => { m.owner = 'untrusted'; }, m => { delete m.sourceDigest; }, m => { m.created = null; },
    m => { m.version = 2; }, m => { m.id = m.id.toLowerCase(); }, m => { m.period.extra = true; },
    m => { m.period.start += 0.001; }, m => { m.citations[0].unknown = 1; },
    m => { m.citations[0].namespace = 'not-a-uuid'; }, m => { m.citations[0].memo_id = 'not-a-uuid'; },
    m => { m.citations[0].id = '/invented/source'; }, m => { m.citations[0].day = '2026-02-30'; },
    m => { m.citations[0].revision = 'wrong'; }, m => { m.citations.push({ ...m.citations[0] }); },
    m => { m.citations = []; }, m => { m.sourceDigest = 'Z'.repeat(64); }, m => { m.bodyBytes = 0; },
    m => { m.bodyBytes = 65537; }, m => { m.bodyDigest = '0'.repeat(64); },
  ];
  for (const change of changes) { const files = await fixture(); editMetadata(files, change); await assert.rejects(validate(files)); }
});

test('duplicate keys, alternative JSON escapes/numbers, whitespace and extra metadata payload fail canonical byte parity', async () => {
  const mutations = [
    text => '{"version":1,' + text.slice(1), text => text + '{}', text => ' ' + text,
    text => text.replace('"version":1', '"version":1.0'), text => text.replace('"created":815753252.627451', '"created":815753252.6274510'),
    text => text.replaceAll('\\/', '/'), text => text.replace('bodyBytes', '\\u0062odyBytes'),
    text => text.replace('"created":815753252.627451', '"created":8.15753252627451e8'),
  ];
  for (const mutation of mutations) { const files = await fixture(); editMetadata(files, () => {}, mutation); await assert.rejects(validate(files)); }
});

test('body length is UTF8 bytes and exact footer/header/payload is required', async () => {
  const cases = [
    files => editMetadata(files, m => { m.bodyBytes++; }),
    files => editMetadata(files, m => { m.bodyBytes = 30; }),
    files => { const bytes = encode(rawPage(files).review.body); editMetadata(files, m => { m.bodyBytes = bytes.indexOf(0xf0) + 1; }); },
    files => { const p = rawPage(files); files.set(p.review.file, encode(p.raw + 'extra')); },
    files => { const p = rawPage(files); files.set(p.review.file, encode(p.raw.replace('## Sources\n- S1:', '## Sources\n- S9:'))); },
    files => { const p = rawPage(files); files.set(p.review.file, encode(p.raw.replace('manual_day_review', 'manual_week_review'))); },
    files => { const p = rawPage(files); files.set(p.review.file, encode('\uFEFF' + p.raw)); },
    files => { const p = rawPage(files), b = files.get(p.review.file).slice(); b[0] = 255; files.set(p.review.file, b); },
  ];
  for (const change of cases) { const files = await fixture(); change(files); await assert.rejects(validate(files)); }
});

test('blank or excessive bodies fail even with a coherent raw digest and typed body', async () => {
  for (const body of [' \t\n\u2003', 'x'.repeat(65537)]) {
    const files = await fixture(); await setBody(files, body); await assert.rejects(validate(files));
  }
});

test('a coherent edited review is a valid file, not a claim of authenticated authorship or current-source truth', async () => {
  const files = await fixture(); await setBody(files, 'An explicitly edited synthetic review body. [S1] [S2]'); await validate(files);
});

test('every typed review field is checked against the raw page after all file hashes are recomputed', async () => {
  const changes = [
    r => { r.body += 'forged'; }, r => { r.source_digest = '0'.repeat(64); }, r => { r.created_at = r.start; },
    r => { r.time_zone = 'UTC'; }, r => { r.period_kind = 'week'; }, r => { r.generation_id = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'; },
    r => { r.namespace = 'imports/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'; },
    r => { r.sources[0].revision = '0'.repeat(64); }, r => { r.sources[0].id = '/forged'; },
    r => { r.sources.reverse(); }, r => { r.extra = 'forged'; }, r => { r.created_at = r.created_at.replace('Z', '000Z'); },
  ];
  for (const change of changes) { const files = await fixture(); editTyped(files, change); await assert.rejects(validate(files)); }
});

test('imported page owner is prepended to nested logical source namespaces while raw historical bytes remain unchanged', async () => {
  const files = await fixture('manual-review-nested-citations'), value = records(files), r = value.reviews[0];
  const prefix = 'imports/CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC', old = r.file, path = prefix + '/' + old;
  files.set(path, files.get(old)); files.delete(old); r.file = path; r.namespace = prefix;
  for (const source of r.sources) { source.namespace = prefix + (source.namespace ? '/' + source.namespace : ''); source.id = `${source.namespace}/${source.day}/${source.memo_id}`; }
  files.set('records.json', encode(JSON.stringify(value)));
  const manifest = JSON.parse(decode(files.get('daypage-exchange.json'))); manifest.files.find(f => f.path === old).path = path;
  files.set('daypage-exchange.json', encode(JSON.stringify(manifest))); await validate(files);
});

test('historical changed or missing sources are retained without pretending they are current', async () => {
  const files = await fixture(); const value = records(files); value.notes = [];
  files.set('records.json', encode(JSON.stringify(value))); await validate(files);
});

test('duplicate review identities and a renamed file cannot replace its raw generation identity', async () => {
  const duplicate = await fixture(), first = await input(duplicate);
  first.manifest.reviews_count = 2; first.manifest.files.push({ ...first.manifest.files.find(f => f.kind === 'review') });
  first.records.reviews.push(structuredClone(first.records.reviews[0]));
  await assert.rejects(validateReviewProjection(first.manifest, first.records, duplicate, hash));
  const files = await fixture(), r = records(files), old = r.reviews[0].file;
  const id = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA', path = 'wiki/manual-reviews/' + id + '.md';
  files.set(path, files.get(old)); files.delete(old); r.reviews[0].file = path; r.reviews[0].generation_id = id;
  files.set('records.json', encode(JSON.stringify(r))); const m = JSON.parse(decode(files.get('daypage-exchange.json')));
  m.files.find(f => f.path === old).path = path; files.set('daypage-exchange.json', encode(JSON.stringify(m))); await assert.rejects(validate(files));
});

test('abort before/during body hash prevents completion and hash failures propagate', async () => {
  const files = await fixture(), before = new AbortController(); before.abort(); let calls = 0;
  await assert.rejects(validate(files, async b => { calls++; return hash(b); }, before.signal), { name: 'AbortError' }); assert.equal(calls, 0);
  const during = new AbortController();
  await assert.rejects(validate(files, async b => { during.abort(); return hash(b); }, during.signal), { name: 'AbortError' });
  const failure = new Error('Synthetic digest failure'); await assert.rejects(validate(files, async () => { throw failure; }), error => error === failure);
});
