// The sound a player holds ahead of what it plays (Extension/lib/sound.js).
// Every stream here is made up: a few bytes shaped like WebM or MP4.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { load, fixture } from './load.mjs';

const { S, P } = load();

const bytes = (...parts) => Uint8Array.from(parts.flatMap((part) => Array.from(part)));
/** A WebM header: the EBML magic, a timecode scale of a millisecond, padding. */
const webmHeader = () => bytes([0x1a, 0x45, 0xdf, 0xa3], [0x9f, 0x42, 0x86], [0x2a, 0xd7, 0xb1, 0x83, 0x0f, 0x42, 0x40], [1, 2, 3]);
/** A cluster that starts at `milliseconds`, with `payload` bytes of sound. */
const cluster = (milliseconds, payload = 6) => bytes(
  [0x1f, 0x43, 0xb6, 0x75], [0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
  [0xe7, 0x84, (milliseconds >>> 24) & 0xff, (milliseconds >>> 16) & 0xff, (milliseconds >>> 8) & 0xff, milliseconds & 0xff],
  Array.from({ length: payload }, (_, i) => 0xa0 + (i % 16)),
);
const box = (type, body) => bytes(
  [((body.length + 8) >>> 24) & 0xff, ((body.length + 8) >>> 16) & 0xff, ((body.length + 8) >>> 8) & 0xff, (body.length + 8) & 0xff],
  Array.from(type, (c) => c.charCodeAt(0)), body,
);
const joined = (...arrays) => bytes(...arrays);

test('a stream\'s header is told from its sound', () => {
  const header = webmHeader();
  assert.equal(S.container(header), 'webm');
  assert.equal(S.headerLength(header), header.length, 'no cluster yet: all of it');
  assert.equal(S.headerLength(joined(header, cluster(0))), header.length, 'up to the first cluster');
  const mp4 = joined(box('ftyp', [1, 2, 3, 4]), box('moov', box('mdhd', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xbb, 0x80])));
  assert.equal(S.container(mp4), 'mp4');
  assert.equal(S.headerLength(joined(mp4, box('sidx', [0]), box('moof', [0]))), mp4.length, 'ftyp and moov');
  assert.equal(S.headerLength(cluster(0)), 0, 'a piece of sound is no header');
  assert.equal(S.headerLength(bytes([1, 2, 3])), 0);
});

test('a piece of sound says where in the video it starts', () => {
  const header = webmHeader();
  assert.equal(S.pieceTime(cluster(20000), 'webm', header), 20);
  assert.equal(S.pieceTime(cluster(1500), 'webm', null), 1.5, 'a millisecond scale when none is stated');
  const checked = joined(bytes([0x1f, 0x43, 0xb6, 0x75], [0x84], [0xbf, 0x84, 9, 9, 9, 9], [0xe7, 0x82, 0x27, 0x10]));
  assert.equal(S.pieceTime(checked, 'webm', header), 10, 'a checksum may come first');
  assert.equal(S.pieceTime(bytes([9, 9, 9, 9, 9, 9, 9, 9, 9]), 'webm', header), null, 'the middle of a cluster says nothing');
  const moov = joined(box('ftyp', [1, 2, 3, 4]), box('moov', box('mdhd', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xbb, 0x80])));
  const moof = box('moof', box('tfdt', [1, 0, 0, 0, 0, 0, 0, 0, 0, 0x0e, 0xa6, 0x00]));
  assert.equal(S.pieceTime(moof, 'mp4', moov), 20, '960000 at 48000 a second');
  assert.equal(S.pieceStart(joined(bytes([7, 7, 7]), cluster(0)), 'webm'), 3);
  assert.equal(S.pieceStart(joined(bytes([7, 7, 7]), moof), 'mp4'), 3);
});

test('what an append added to the buffer', () => {
  assert.deepEqual(S.added([], [[0, 10]]), [[0, 10]]);
  assert.deepEqual(S.added([[0, 10]], [[0, 20]]), [[10, 20]]);
  assert.deepEqual(S.added([[0, 20]], [[0, 20], [150, 160]]), [[150, 160]]);
  assert.deepEqual(S.added([[0, 20]], [[0, 20]]), []);
  assert.deepEqual(S.added([[5, 10]], [[0, 12]]), [[0, 5], [10, 12]]);
});

test('a song played from its start is held from 0 as far as the buffer goes', () => {
  const held = S.capture('audio/webm; codecs="opus"');
  const header = webmHeader();
  const first = cluster(0);
  // The header and the piece's first bytes, cut before its time.
  let count = S.append(held, joined(header, first.subarray(0, 10)), 0);
  S.settle(held, [], [], count, 0);
  assert.equal(held.start, null);
  count = S.append(held, first.subarray(10, 20), 0);
  S.settle(held, [], [], count, 0);
  assert.equal(held.start, 0, 'the stream says where it begins');
  assert.equal(held.until, null, 'nothing of it is in the buffer yet');
  count = S.append(held, first.subarray(20), 0);
  S.settle(held, [], [[0, 10]], count, 0);
  const second = cluster(10000);
  count = S.append(held, second, 0);
  S.settle(held, [[0, 10]], [[0, 20]], count, 0);
  assert.deepEqual([held.start, held.until, held.run], [0, 20, 1]);
  assert.deepEqual(Array.from(S.stream(held)), Array.from(joined(header, first, second)), 'the stream as it was handed over');
  // What the page appended is copied: changing it later changes nothing here.
  second.fill(0);
  assert.notEqual(S.stream(held).at(-1), 0);
});

test('a seek begins a new stretch with its first whole piece', () => {
  const held = S.capture('audio/webm');
  const header = webmHeader();
  let count = S.append(held, joined(header, cluster(0)), 0);
  S.settle(held, [], [[0, 10]], count, 0);
  count = S.append(held, cluster(10000), 0);
  S.settle(held, [[0, 10]], [[0, 20]], count, 0);
  // Part of the next piece arrived, then the listener jumped far ahead.
  count = S.append(held, cluster(20000).subarray(0, 14), 0);
  S.settle(held, [[0, 20]], [[0, 20]], count, 0);
  const far = cluster(150000);
  count = S.append(held, far, 0);
  S.settle(held, [[0, 20]], [[0, 20], [150, 160]], count, 0);
  assert.deepEqual([held.start, held.until, held.run], [150, 160, 2]);
  assert.deepEqual(Array.from(S.stream(held)), Array.from(joined(header, far)), 'nothing of the stretch before');
  // The page's own listener may append again before the last append is counted.
  const next = cluster(160000);
  S.append(held, next, 0);
  S.settle(held, [[0, 20], [150, 160]], [[0, 20], [150, 170]], held.media.length - 1, 0);
  assert.deepEqual([held.start, held.until, held.media.length, held.counted], [150, 170, 2, 1]);
});

test('a new stream replaces the one before; one re-sent over held sound waits for the buffer', () => {
  const held = S.capture('audio/webm');
  let count = S.append(held, joined(webmHeader(), cluster(0)), 0);
  S.settle(held, [], [[0, 40]], count, 0);
  // Another quality from 0:20 on, where the buffer already holds sound.
  count = S.append(held, joined(webmHeader(), cluster(20000)), 0);
  S.settle(held, [[0, 40]], [[0, 40]], count, 0);
  assert.deepEqual([held.start, held.until, held.run], [20, null, 2], 'begins at 0:20; how far is not known yet');
  count = S.append(held, cluster(40000), 0);
  S.settle(held, [[0, 40]], [[0, 50]], count, 0);
  assert.deepEqual([held.start, held.until], [20, 50]);
  // A buffer that shifts its stream's times.
  const shifted = S.capture('audio/webm');
  S.append(shifted, joined(webmHeader(), cluster(0)), 300);
  assert.equal(shifted.start, 300);
});

test('a long video keeps its beginning; a seek after that is lost', () => {
  const held = S.capture('audio/webm');
  let count = S.append(held, joined(webmHeader(), cluster(0)), 0);
  S.settle(held, [], [[0, 10]], count, 0);
  const big = cluster(10000, S.LIMIT);
  count = S.append(held, big, 0);
  assert.equal(held.full, true);
  assert.equal(held.media.length, 1, 'the piece over the limit is not kept');
  S.settle(held, [[0, 10]], [[0, 400]], count, 0);
  count = S.append(held, cluster(900000), 0);
  S.settle(held, [[0, 400]], [[0, 400], [900, 910]], count, 0);
  assert.equal(held.lost, true);
  assert.equal(held.start, null);
});

test('a stretch of the samples, where they are held', () => {
  const samples = Float32Array.from({ length: S.RATE * 30 }, (_, i) => i);
  const piece = S.cut(20, samples, 30, 10);
  assert.equal(piece.start, 30);
  assert.equal(piece.samples.length, S.RATE * 10);
  assert.equal(piece.samples[0], S.RATE * 10);
  assert.equal(S.cut(20, samples, 0, 10).start, 20, 'from where the stretch begins');
  assert.equal(S.cut(20, samples, 45, 10), null, 'not held that far yet');
  const short = samples.subarray(0, S.RATE * 30 - 104);
  assert.equal(S.cut(20, short, 40, 10).samples.length, S.RATE * 10 - 104, 'a decoder may drop a few milliseconds');
});

test('samples travel as 16-bit PCM', () => {
  const text = S.pcm16(Float32Array.from([0, 1, -1, 0.5, -0.5, 7]));
  const raw = Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
  const values = Array.from(new Int16Array(raw.buffer));
  assert.deepEqual(values, [0, 32767, -32768, 16384, -16384, 32767]);
  assert.deepEqual(Array.from(S.mono([Float32Array.from([1, 0]), Float32Array.from([0, 0.5])])), [0.5, 0.25]);
  const one = Float32Array.from([0.25]);
  assert.equal(S.mono([one]), one);
});

test('the answer with sound is what the app decodes', () => {
  const expected = fixture('result-sound');
  assert.deepEqual(P.result(expected.id, expected.ok, expected), expected);
  const waiting = P.result('r1', true, { sound: { from: 0, until: 12.5 } });
  assert.deepEqual(waiting.sound, { from: 0, until: 12.5 }, 'how far it holds, without sound');
  const huge = P.result('r2', true, { sound: { from: 0, until: 30, start: 0, rate: 16000, samples: 'A'.repeat(700000) } });
  assert.deepEqual(huge.sound, { from: 0, until: 30 }, 'more than a frame may carry is dropped');
  assert.ok(P.tab({ tabId: 1, site: 'youtubeMusic', title: 'Harbor walk', can: ['sound', 'seek'] }).can.includes('sound'));
});
