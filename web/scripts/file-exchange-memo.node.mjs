import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {parseCanonicalMemo, canonicalMemoBlocks, unquoteMemoScalar} from '../src/lib/file-exchange/memo-codec.ts';
import {sha256} from '../src/lib/file-exchange/preview.ts';

const header='---\nid: 11111111-2222-4333-8444-555555555555\ntype: mixed\ncreated: 2026-11-07T02:03:04Z\n';
const block=(body='',extra='')=>header+extra+'---\n\n'+body;

test('the cross-language raw fixture decodes to its declared memo without changing its original block revision',async()=>{
  const bytes=new Uint8Array(await readFile(new URL('../tests/fixtures/file-exchange-v1/raw/2026-11-07.md',import.meta.url)));
  const records=JSON.parse(await readFile(new URL('../tests/fixtures/file-exchange-v1/records.json',import.meta.url),'utf8'));
  const memo=parseCanonicalMemo(new TextDecoder().decode(bytes)),note=records.notes[0];
  assert.equal(memo.id,note.original_id);assert.equal(memo.type,note.type);assert.equal(memo.created,note.created_at);
  assert.equal(memo.body,note.body);assert.equal(await sha256(bytes),note.revision);
  assert.deepEqual(memo.attachments,[{file:note.attachments[0].file,kind:note.attachments[0].kind}]);
});

test('DayDocument separates real memo blocks while preserving a horizontal rule inside one body',()=>{
  const first=block('First\n\n---\n\nStill first'),second=block('Second').replace('11111111-2222-4333-8444-555555555555','aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
  assert.deepEqual(canonicalMemoBlocks(first),[first]);assert.equal(parseCanonicalMemo(first).body,'First\n\n---\n\nStill first');
  assert.deepEqual(canonicalMemoBlocks(first+'\n\n<!-- daypage-memo-separator -->\n\n'+second),[first,second]);
  const legacyFirst=block('Legacy first');
  assert.deepEqual(canonicalMemoBlocks(legacyFirst+'\n\n---\n\n'+second),[legacyFirst,second]);
  assert.deepEqual(canonicalMemoBlocks(''),[]);
});

test('quoted metadata preserves newline, literal backslash and unknown escapes using the native subset',()=>{
  assert.equal(unquoteMemoScalar('"line\\nnext\\\\n\\q\\\""'),'line\nnext\\n\\q"');
  const original=block('Original text','unknown_future_key: "preserved raw only"\nweather: "rain\\nwind"\ndevice: "Phone\\\\work"\nmood: "calm"\nmargin_note: "quote \\""\nentity_mentions:\n  - "Project A"\n  - "literal\\\\n"\n');
  const memo=parseCanonicalMemo(original);
  assert.equal(memo.weather,'rain\nwind');assert.equal(memo.device,'Phone\\work');
  assert.deepEqual(memo.entityMentions,['Project A','literal\\n']);assert.equal(memo.body,'Original text');
  assert.ok(original.includes('unknown_future_key: "preserved raw only"'));
  assert.equal(Object.hasOwn(memo,'unknown_future_key'),false);
});

test('empty body, all attachment fields and optional coordinates preserve native interpretation',()=>{
  const memo=parseCanonicalMemo(block('', 'location:\n  name: "Place"\n  lat: 12.25\n  lng: -5.5\nattachments:\n  - file: "voice.m4a"\n    kind: audio\n    duration: 1.25\n    transcript: "synthetic\\nwords"\n    transcription_status: done\n'));
  assert.equal(memo.body,'');assert.deepEqual(memo.location,{name:'Place',lat:12.25,lng:-5.5});
  assert.deepEqual(memo.attachments,[{file:'voice.m4a',kind:'audio',duration:1.25,transcript:'synthetic\nwords',transcriptionStatus:'done'}]);
  assert.equal(parseCanonicalMemo(block('Body','type: invalid\n')).type,'mixed','the first scalar wins like Core');
  assert.equal(parseCanonicalMemo('ordinary Markdown'),undefined);
  assert.equal(parseCanonicalMemo(block('Body').replace('id: 11111111-2222-4333-8444-555555555555','id: invalid')),undefined);
});

test('native Double fields retain hexadecimal values and nonfinite values for later explicit rejection',()=>{
  const memo=parseCanonicalMemo(block('Body','location:\n  lat: 0x1.8p1\n  lng: 0x1.c6p4\nattachments:\n  - file: "a.txt"\n    duration: 1e999\n  - file: "b.txt"\n    duration: nan(payload)\n'));
  assert.deepEqual(memo.location,{lat:3,lng:28.375});
  assert.equal(memo.attachments[0].duration,Infinity);
  assert.equal(Number.isNaN(memo.attachments[1].duration),true);
});

test('native Character scanning preserves an unknown escape containing a combining mark',()=>{
  assert.equal(unquoteMemoScalar('"\\n\u0301"'),'\\n\u0301');
  assert.equal(unquoteMemoScalar('"a\\nnext"'),'a\nnext');
  assert.equal(unquoteMemoScalar('"\u0301literal"'),'"\u0301literal"');
  assert.equal(unquoteMemoScalar('"literal\u0600"'),'"literal\u0600"');
  assert.equal(parseCanonicalMemo(block('Body','mood: \u0301calm\n')).mood,undefined);
  assert.equal(parseCanonicalMemo(block('Body').replace(/^---/,'---\u0301')),undefined);
});

test('hexadecimal conversion rounds once to IEEE binary64, including ties, overflow and signed-zero underflow',()=>{
  const read=value=>parseCanonicalMemo(block('Body',`attachments:\n  - file: a.txt\n    duration: ${value}\n`)).attachments[0].duration;
  for(const [source,expected] of [
    ['0x1.25e4',1.14801025390625],
    ['0x1.d4',1.828125],
    ['0x1.00000000000008p0',1],
    ['0x1.0000000000000801p0',1+Number.EPSILON],
    ['0x1.00000000000018p0',1+2*Number.EPSILON],
    ['0x0.00000000000008p-1022',0],
    ['0x0.0000000000000801p-1022',Number.MIN_VALUE],
    ['0x1.fffffffffffffp1023',Number.MAX_VALUE],
    ['0x1.fffffffffffff8p1023',Infinity],
    ['0x1p-99999',0],
  ])assert.equal(read(source),expected,source);
  assert.equal(Object.is(read('-0x0.00000000000008p-1022'),-0),true);
  assert.equal(Object.is(read('-0x1p-99999'),-0),true);
  assert.equal(read('snan(payload)'),undefined,'the pinned Swift stub recognizes bare snan only');
  assert.equal(Number.isNaN(read('nan((payload)')),true);
  assert.equal(read('nan((payload))'),undefined,'trailing bytes after the first closing parenthesis are invalid');
  assert.equal(read('1\u0000ignored'),1);
});

test('native split skips leading empty colon components without consuming its one split',()=>{
  const memo=parseCanonicalMemo(block('Body','location:\n  :lat: 12.25\n  :lng: -5.5\nattachments:\n  - :file: "a.txt"\n    :kind: file\n'));
  assert.deepEqual(memo.location,{lat:12.25,lng:-5.5});
  assert.deepEqual(memo.attachments,[{file:'a.txt',kind:'file'}]);
  const marked=parseCanonicalMemo(block('Body','location:\n  name:\u0301Place\nattachments:\n  - file:\u0301a.txt\n'));
  assert.equal(marked.location,undefined);assert.deepEqual(marked.attachments,[]);
});

