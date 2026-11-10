// Reading the synced lyrics a site loaded for itself (Extension/lib/lyrics.js).
// The response shapes are invented stand-ins with invented lines.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { load } from './load.mjs';

const { L } = load();

const texts = (lines) => lines.map((line) => line.text);
const starts = (lines) => lines.map((line) => line.start);

test('LRC: stamps, several stamps on one line, an offset, word stamps', () => {
  const lines = L.parseLRC([
    '[ti:Lanterns Under Ice]',
    '[offset:+500]',
    '[00:04.20]Frost on the ferry rails',
    '[00:08.90][01:10.00]We <00:09.40>counted <00:09.90>every light',
    '[00:13.00]',
    'no stamp here',
  ].join('\n'));
  assert.deepEqual(starts(lines), [3.7, 8.4, 12.5, 69.5]);
  assert.deepEqual(texts(lines), ['Frost on the ferry rails', 'We counted every light', '', 'We counted every light']);
  assert.equal(L.parseLRC('[00:01.00]Only one line'), null, 'one line is not lyrics');
  assert.equal(L.parseLRC(''), null);

  assert.equal(L.stampSeconds('[01:02.50]'), 62.5);
  assert.equal(L.stampSeconds('01:02:50'), 62.5, 'a colon before the hundredths');
  assert.equal(L.stampSeconds('1:02'), 62);
  assert.ok(Number.isNaN(L.stampSeconds('[ar:Someone]')));
  assert.ok(Number.isNaN(L.stampSeconds('')));
});

test("Spotify's own lyrics: synced only", () => {
  const json = { lyrics: { syncType: 'LINE_SYNCED', lines: [
    { startTimeMs: '4200', words: 'Frost on the ferry rails', endTimeMs: '0' },
    { startTimeMs: '8900', words: 'We counted every light', endTimeMs: '12500' },
    { startTimeMs: '13000', words: '♪' },
  ] } };
  const lines = L.fromSpotify(json);
  assert.deepEqual(starts(lines), [4.2, 8.9, 13]);
  assert.equal(lines[0].end, undefined);
  assert.equal(lines[1].end, 12.5);
  assert.equal(L.fromSpotify({ lyrics: { syncType: 'UNSYNCED', lines: json.lyrics.lines } }), null);
  assert.equal(L.fromSpotify({}), null);

  const found = L.extract('spotify', 'https://spclient.example/color-lyrics/v2/track/AhenkMockTrackSpotify1/image/x', json);
  assert.equal(found.trackId, 'AhenkMockTrackSpotify1', 'the song the response belongs to');
  assert.equal(found.lines.length, 3);
});

test("Deezer's and TIDAL's own lyrics", () => {
  const deezer = { results: { data: { track: { id: 918273, lyrics: { synchronizedLines: [
    { milliseconds: 4200, duration: 3000, line: 'Salt on the window' },
    { lrcTimestamp: '[00:09.50]', line: 'Every lantern hums' },
    { milliseconds: 14000, line: 'We row the harbor home' },
  ] } } } } };
  const lines = L.fromDeezer(deezer);
  assert.deepEqual(starts(lines), [4.2, 9.5, 14]);
  assert.equal(lines[0].end, 7.2);
  assert.equal(L.extract('deezer', 'https://pipe.deezer.com/api', deezer).trackId, '918273');

  const tidal = { trackId: 55, subtitles: '[00:02.00] Marmara neon at midnight\n[00:06.50] Gulls above the ferry\n' };
  assert.deepEqual(texts(L.fromTidal(tidal)), ['Marmara neon at midnight', 'Gulls above the ferry']);
  assert.equal(L.extract('tidal', 'https://listen.tidal.com/v1/tracks/55/lyrics?countryCode=TR', tidal).trackId, '55');
  assert.equal(L.fromTidal({ lyrics: 'plain words' }), null);
});

test("YouTube Music's own lyrics, deep in its response", () => {
  const json = { contents: { sectionListRenderer: { contents: [{ timedLyricsRenderer: { timedLyricsData: [
    { lyricLine: 'Velvet harbor, velvet lights', cueRange: { startTimeMilliseconds: '5000', endTimeMilliseconds: '9000' } },
    { lyricLine: 'Every rope remembers', cueRange: { startTimeMilliseconds: '9500', endTimeMilliseconds: '0' } },
  ] } }] } } };
  const lines = L.fromYouTubeMusic(json);
  assert.deepEqual(starts(lines), [5, 9.5]);
  assert.equal(lines[0].end, 9);
  assert.equal(lines[1].end, undefined);
  assert.equal(L.extract('youtubeMusic', 'https://music.youtube.com/youtubei/v1/browse', json).lines.length, 2);
});

test('An unknown shape (Amazon Music): the longest ascending list of timed lines', () => {
  const milliseconds = { payload: { meta: { id: 'x' }, lyricsData: { lines: [
    { startTime: 1500, text: 'Northbound postcards' },
    { startTime: 5200, text: 'Folded in the glovebox' },
    { startTime: 9100, text: 'Northbound, northbound' },
    { startTime: 12800, text: 'Until the road runs out' },
  ] }, other: [{ time: 1, text: 'a' }, { time: 2, text: 'b' }] } };
  const lines = L.scanTimedLines(milliseconds);
  assert.deepEqual(starts(lines), [1.5, 5.2, 9.1, 12.8], 'times past an hour read as milliseconds');
  assert.equal(L.extract('amazonMusic', 'https://music.amazon.example/lyrics', milliseconds).lines.length, 4);

  const seconds = { lines: [{ start: 1.5, line: 'One' }, { start: 4, line: 'Two' }, { start: 7.25, line: 'Three' }] };
  assert.deepEqual(starts(L.scanTimedLines(seconds)), [1.5, 4, 7.25]);
  const stamps = { list: [{ timestamp: '00:01.50', content: 'One' }, { timestamp: '00:04.00', content: 'Two' }, { timestamp: '00:07.25', content: 'Three' }] };
  assert.deepEqual(starts(L.scanTimedLines(stamps)), [1.5, 4, 7.25]);
  assert.equal(L.scanTimedLines({ lines: [{ start: 9, text: 'b' }, { start: 1, text: 'a' }, { start: 5, text: 'c' }] }), null, 'not in order');
  assert.equal(L.scanTimedLines({ title: 'no lines here' }), null);
});

test('only responses that may hold lyrics are read', () => {
  assert.equal(L.wants('spotify', 'https://spclient.example/color-lyrics/v2/track/AhenkMockTrackSpotify1'), true);
  assert.equal(L.wants('youtubeMusic', 'https://music.youtube.com/youtubei/v1/browse?prettyPrint=false'), true);
  assert.equal(L.wants('youtubeMusic', 'https://music.youtube.com/youtubei/v1/player'), false);
  assert.equal(L.wants('tidal', 'https://listen.tidal.com/v1/tracks/55/lyrics'), true);
  assert.equal(L.wants('soundCloud', 'https://api.soundcloud.example/lyrics'), false, 'SoundCloud has none');
  assert.equal(L.wants('youtube', 'https://www.youtube.com/youtubei/v1/browse'), false);
  assert.equal(L.wants('napster', 'https://x/lyrics'), false);
  assert.equal(L.extract('spotify', 'https://x', null), null);
  assert.equal(L.extract('spotify', 'https://x', { nothing: true }), null);
});

test('YouTube captions: the written track in the sung language, as timed lines', () => {
  const tracks = [
    { baseUrl: 'https://x/de', languageCode: 'de' },
    { baseUrl: 'https://x/tr', languageCode: 'tr' },
    { baseUrl: 'https://x/asr', languageCode: 'tr', kind: 'asr' },
  ];
  assert.equal(L.pickCaptionTrack(tracks).baseUrl, 'https://x/tr', 'the automatic track names the sung language');
  assert.equal(L.pickCaptionTrack([tracks[2]]), null, 'automatic captions alone are not lyrics');
  assert.equal(L.pickCaptionTrack([tracks[0]]).baseUrl, 'https://x/de', 'the only written track');
  assert.equal(L.pickCaptionTrack([tracks[0], tracks[1]], 'tr-TR').baseUrl, 'https://x/tr', "else the listener's language");
  assert.equal(L.pickCaptionTrack([tracks[0], tracks[1]], 'fr'), null);
  assert.equal(L.pickCaptionTrack(null), null);

  const lines = L.fromYouTubeCaptions({ events: [
    { tStartMs: 1309, dDurationMs: 4000, segs: [{ utf8: '[Music]' }] },
    { tStartMs: 19112, dDurationMs: 2000, segs: [{ utf8: '\u266A Lanterns under ice \u266A' }] },
    { tStartMs: 21143, dDurationMs: 2500, segs: [{ utf8: 'We counted\n' }, { utf8: 'every light' }] },
    { tStartMs: 24000, segs: [{ utf8: '\n' }] },
    { tStartMs: 26000 },
  ] });
  assert.deepEqual(texts(lines), ['Lanterns under ice', 'We counted every light']);
  assert.deepEqual(starts(lines), [19.112, 21.143]);
  assert.equal(lines[0].end, 21.112);
  assert.equal(L.fromYouTubeCaptions({ events: [] }), null);
  assert.equal(L.fromYouTubeCaptions(null), null);
});

test('YouTube automatic captions: heard words with their own times', () => {
  assert.equal(L.pickHeardTrack([{ baseUrl: 'https://x/tr', languageCode: 'tr' }]), null);
  assert.equal(L.pickHeardTrack([{ baseUrl: 'https://x/asr', languageCode: 'tr', kind: 'asr' }]).baseUrl, 'https://x/asr');
  const lines = L.fromYouTubeAutoCaptions({ events: [
    { tStartMs: 1309, segs: [{ utf8: '[music]' }] },
    { tStartMs: 75280, segs: [{ utf8: '>> Lanterns' }, { utf8: ' under', tOffsetMs: 600 }, { utf8: ' [music] ice', tOffsetMs: 1100 }] },
    { tStartMs: 78680, segs: [{ utf8: 'we' }, { utf8: ' counted', tOffsetMs: 400 }] },
  ] });
  assert.equal(lines.length, 2);
  assert.deepEqual(lines[0].words, [{ start: 75.28, text: 'Lanterns' }, { start: 75.88, text: 'under' }, { start: 76.38, text: 'ice' }]);
  assert.equal(lines[1].text, 'we counted');
  assert.equal(L.fromYouTubeAutoCaptions({ events: [{ tStartMs: 1, segs: [{ utf8: '[music]' }] }] }), null);
});
