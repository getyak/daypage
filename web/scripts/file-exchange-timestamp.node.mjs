import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {projectRawTimestamp, parseWireTimestamp, projectReviewReferenceSeconds} from '../src/lib/file-exchange/timestamp.ts';

const golden=JSON.parse(await readFile(new URL('../tests/fixtures/exchange-timestamp-projection-v1.json',import.meta.url),'utf8'));

test('raw source projection preserves all shared decimal/offset/carry golden meanings',()=>{
  assert.equal(golden.version,1);
  for(const sample of golden.raw)assert.equal(projectRawTimestamp(sample.value),sample.projected??null,sample.value);
});

test('typed wire time refuses hidden submilliseconds and matches the shared canonical golden',()=>{
  for(const sample of golden.typed){
    const actual=parseWireTimestamp(sample.value);
    assert.equal(actual!==null,sample.accepted,sample.value);
    if(actual)assert.equal(actual.canonical,sample.projected,sample.value);
  }
});

test('review JSON Date uses the shared binary64 reference-seconds projection',()=>{
  for(const sample of golden.review_dates)assert.equal(projectReviewReferenceSeconds(sample.reference_seconds),sample.projected,String(sample.reference_seconds));
});

test('decimal source rounding keeps exact half decisions across long fractions and negative offsets',()=>{
  const pairs=[
    ['1969-12-31T23:59:59.999499999999999999999999Z','1969-12-31T23:59:59.999Z'],
    ['1969-12-31T23:59:59.998500000000000000000000Z','1969-12-31T23:59:59.998Z'],
    ['1969-12-31T23:59:59.998500000000000000000001Z','1969-12-31T23:59:59.999Z'],
    ['1970-01-01T00:00:00.000499999999999999999999Z','1970-01-01T00:00:00Z'],
    ['1970-01-01T00:00:00.000500000000000000000000Z','1970-01-01T00:00:00.001Z'],
    ['1969-12-31T23:00:00.0005-01:00','1970-01-01T00:00:00.001Z'],
    ['1970-01-01T01:00:00.0005+01:01','1969-12-31T23:59:00Z'],
  ];
  for(const [raw,want]of pairs)assert.equal(projectRawTimestamp(raw),want,raw);
  assert.equal(projectRawTimestamp('1970-01-01T00:00:00.0005'+'0'.repeat(40000)+'1Z'),'1970-01-01T00:00:00.001Z');
});

test('typed parsing preserves the exact safe integer millisecond and canonicalizes zero-only extra precision',()=>{
  assert.deepEqual(parseWireTimestamp('1970-01-01t01:00:00.001000000z'),{milliseconds:3600001,canonical:'1970-01-01T01:00:00.001Z'});
  assert.deepEqual(parseWireTimestamp('1969-12-31T23:59:59.999Z'),{milliseconds:-1,canonical:'1969-12-31T23:59:59.999Z'});
  assert.deepEqual(parseWireTimestamp('1970-01-01T00:00:00.000000Z'),{milliseconds:0,canonical:'1970-01-01T00:00:00Z'});
  assert.equal(parseWireTimestamp('1970-01-01T00:00:00.000000000000000000001Z'),null);
});

test('calendar/grammar/offset/range validation refuses normalization and out-of-domain UTC',()=>{
  const invalid=['',' 2026-11-07T02:03:04Z','2026-11-07T02:03:04Z\n','2026-11-07T02:03:04Z\u0000junk','2026-11-07 02:03:04Z','2026-11-07T02:03:04.Z','2026-11-07T02:03:04+0800','2026-11-07T02:03:04+24:00','2026-11-07T02:03:04-00:60','2026-00-01T00:00:00Z','2026-13-01T00:00:00Z','2026-04-31T00:00:00Z','1900-02-29T00:00:00Z','2100-02-29T00:00:00Z','2026-11-07T24:00:00Z','2026-11-07T02:03:60Z','0000-01-01T00:00:00Z','10000-01-01T00:00:00Z','0001-01-01T00:00:00+00:01','9999-12-31T23:59:59-00:01','9999-12-31T23:59:59.9995Z'];
  for(const raw of invalid){assert.equal(projectRawTimestamp(raw),null,raw);assert.equal(parseWireTimestamp(raw),null,raw);}
  assert.equal(projectRawTimestamp('2000-02-29T23:59:59.9995Z'),'2000-03-01T00:00:00Z');
  assert.equal(projectRawTimestamp('0099-12-31T23:59:59.9995001Z'),'0100-01-01T00:00:00Z');
  assert.deepEqual(parseWireTimestamp('0001-01-01T00:00:00Z'),{milliseconds:-62135596800000,canonical:'0001-01-01T00:00:00Z'});
  assert.deepEqual(parseWireTimestamp('9999-12-31T23:59:59.999Z'),{milliseconds:253402300799999,canonical:'9999-12-31T23:59:59.999Z'});
});

test('review projection rounds negative half away from zero and rejects nonfinite/out-of-range clocks',()=>{
  assert.equal(projectReviewReferenceSeconds(-978307200.0625),'1969-12-31T23:59:59.937Z');
  assert.equal(projectReviewReferenceSeconds(-978307199.9375),'1970-01-01T00:00:00.063Z');
  assert.equal(projectReviewReferenceSeconds(0),'2001-01-01T00:00:00Z');
  for(const value of [NaN,Infinity,-Infinity,Number.MAX_VALUE,-Number.MAX_VALUE])assert.equal(projectReviewReferenceSeconds(value),'');
});
