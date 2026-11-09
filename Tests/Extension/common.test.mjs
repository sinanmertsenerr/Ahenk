// The extension's site helpers (Extension/lib/common.js). Invented songs,
// artists and IDs only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { load } from './load.mjs';

const { C, P } = load();

test('host names map onto the sites the app knows (as BrowserSite does)', () => {
  const cases = [
    ['music.youtube.com', 'youtubeMusic'], ['www.youtube.com', 'youtube'], ['m.youtube.com', 'youtube'], ['youtu.be', 'youtube'],
    ['open.spotify.com', 'spotify'], ['spotify.com', null], ['soundcloud.com', 'soundCloud'], ['m.soundcloud.com', 'soundCloud'],
    ['music.amazon.com', 'amazonMusic'], ['music.amazon.co.uk', 'amazonMusic'], ['www.amazon.com', null],
    ['www.deezer.com', 'deezer'], ['listen.tidal.com', 'tidal'], ['evil-youtube.com', null], ['youtube.com.evil.example', null],
    ['MUSIC.YOUTUBE.COM', 'youtubeMusic'],
  ];
  for (const [host, site] of cases) assert.equal(C.siteForHost(host), site, host);
  assert.equal(C.siteForURL('https://music.youtube.com/watch?v=ahenkMock01'), 'youtubeMusic');
  assert.equal(C.siteForURL('ftp://music.youtube.com/'), null);
  assert.equal(C.siteForURL('not a url'), null);
  assert.deepEqual([...C.SITES].sort(), ['amazonMusic', 'deezer', 'soundCloud', 'spotify', 'tidal', 'youtube', 'youtubeMusic']);
});

test('clock labels', () => {
  assert.equal(C.parseClock('1:23'), 83);
  assert.equal(C.parseClock(' 1:02:03 '), 3723);
  assert.equal(C.parseClock('-0:12'), 12);
  assert.equal(C.parseClock('−3:05'), 185);
  for (const text of ['45', '1:75', '', 'abc', null, undefined, '1:2:3:4']) assert.equal(C.parseClock(text), null, String(text));

  assert.deepEqual(C.clockPair('1:00', '4:00'), { position: 60, duration: 240 });
  assert.deepEqual(C.clockPair('1:00', '-3:00'), { position: 60, duration: 240 }, 'what is left, not the length');
  assert.deepEqual(C.clockPair('0:05', ''), { position: 5, duration: undefined });
  assert.equal(C.clockPair('LIVE', '4:00'), null);
});

test('the largest cover, square preferred; nothing but web addresses', () => {
  const list = [
    { src: 'https://img.example/96.jpg', sizes: '96x96' },
    { src: 'https://img.example/600.jpg', sizes: '600x600' },
    { src: 'https://img.example/640x600.jpg', sizes: '640x600' },
  ];
  assert.equal(C.bestArtwork(list), 'https://img.example/600.jpg');
  assert.equal(C.bestArtwork([...list, { src: 'https://img.example/1280.jpg', sizes: '1280x720' }]), 'https://img.example/1280.jpg', 'much larger wins');
  assert.equal(C.bestArtwork([{ src: 'data:image/png;base64,AAAA', sizes: '512x512' }]), null);
  assert.equal(C.bestArtwork([{ src: 'blob:https://music.youtube.com/x' }]), null);
  assert.equal(C.bestArtwork([{ src: '/relative.jpg' }]), null);
  assert.equal(C.bestArtwork(null), null);
  assert.equal(C.absoluteHTTP('/cover.jpg', 'https://listen.tidal.com/album/1'), 'https://listen.tidal.com/cover.jpg');
});

test('song IDs from links', () => {
  assert.equal(C.youtubeVideoId('ahenkMock01'), 'ahenkMock01');
  assert.equal(C.youtubeVideoId('https://music.youtube.com/watch?v=ahenkMock01&list=RDAMx'), 'ahenkMock01');
  assert.equal(C.youtubeVideoId('https://youtu.be/ahenkMock01?t=4'), 'ahenkMock01');
  assert.equal(C.youtubeVideoId('https://www.youtube.com/shorts/ahenkMock01'), 'ahenkMock01');
  assert.equal(C.youtubeVideoId('https://www.youtube.com/embed/ahenkMock01'), 'ahenkMock01');
  assert.equal(C.youtubeVideoId('https://example.com/watch?v=ahenkMock01'), null);
  assert.equal(C.youtubeVideoId('too-short'), null);

  assert.equal(C.spotifyTrackId('AhenkMockTrackSpotify1'), 'AhenkMockTrackSpotify1');
  assert.equal(C.spotifyTrackId('spotify:track:AhenkMockTrackSpotify1'), 'AhenkMockTrackSpotify1');
  assert.equal(C.spotifyTrackId('https://open.spotify.com/track/AhenkMockTrackSpotify1?si=x'), 'AhenkMockTrackSpotify1');
  assert.equal(C.spotifyTrackId('/album/AhenkMockAlbumSpotify1?highlight=spotify:track:AhenkMockTrackSpotify1'), 'AhenkMockTrackSpotify1');
  assert.equal(C.spotifyTrackId('https://open.spotify.com/episode/AhenkMockTrackSpotify1'), null);

  assert.equal(C.idAfter('https://www.deezer.com/en/track/918273?autoplay=true', 'track'), '918273');
  assert.equal(C.idAfter('https://listen.tidal.com/track/55/lyrics', 'track'), '55');
  assert.equal(C.idAfter('https://www.deezer.com/en/album/1', 'track'), null);
});

test('titles and names compare without case, accents, tags or the Turkish dotless i', () => {
  assert.equal(C.normalize('Kıyıdan Sesler'), 'kiyidan sesler');
  assert.equal(C.normalize('Café & Co.'), 'cafe and co');
  assert.equal(C.coreTitle('Velvet Harbor Lights (feat. Someone Else)'), 'velvet harbor lights');
  assert.equal(C.coreTitle('Quiet Engines - 2019 Remaster'), 'quiet engines');
  assert.equal(C.coreTitle('Saffron Static [Live at the Pier]'), 'saffron static');
  assert.equal(C.coreTitle('Lanterns Under Ice ft. Nadia Ferro'), 'lanterns under ice');
  assert.equal(C.coreTitle('(Intro)'), 'intro', 'a title that is all tag keeps its words');
});

test('search results: the best match wins, a weak one is refused', () => {
  const wanted = { title: 'Quiet Engines', artist: 'Nadia Ferro', album: 'Low Orbit Letters', duration: 187 };
  const results = [
    { title: 'Quiet Engines (Live)', artist: 'Nadia Ferro', duration: 240 },
    { title: 'Quiet Engines', artist: 'Nadia Ferro', album: 'Low Orbit Letters', duration: 188 },
    { title: 'Quiet', artist: 'Someone Else' },
  ];
  assert.equal(C.pickBest(wanted, results, 0.5), results[1]);
  assert.ok(C.matchScore(wanted, results[1]) > C.matchScore(wanted, results[0]));
  assert.equal(C.pickBest(wanted, [results[2]], 0.5), null);
  assert.equal(C.pickBest(wanted, [], 0.5), null);
  assert.equal(C.matchScore({ title: '', artist: 'x' }, results[1]), 0);
  // An artist written another way ("Nadia Ferro & Band") still counts.
  assert.ok(C.matchScore(wanted, { title: 'Quiet Engines', artist: 'Nadia Ferro & Band', duration: 187 }) >= 0.8);
});

test('where each site searches and plays', () => {
  assert.equal(C.searchQuery({ title: ' Quiet Engines ', artist: 'Nadia Ferro' }), 'Quiet Engines Nadia Ferro');
  assert.equal(C.searchQuery({ title: 'Quiet Engines' }), 'Quiet Engines');
  assert.equal(C.siteURL('youtubeMusic', 'search', 'Kıyıdan Sesler & co'), 'https://music.youtube.com/search?q=K%C4%B1y%C4%B1dan%20Sesler%20%26%20co');
  assert.equal(C.siteURL('spotify', 'track', 'AhenkMockTrackSpotify1'), 'https://open.spotify.com/track/AhenkMockTrackSpotify1');
  assert.equal(C.siteURL('deezer', 'search', 'a b'), 'https://www.deezer.com/search/a%20b/track');
  assert.equal(C.siteURL('tidal', 'home'), 'https://listen.tidal.com/');
  for (const site of C.SITES) {
    assert.equal(C.siteForURL(C.siteURL(site, 'search', 'x')), site, `${site} searches on its own site`);
  }
  assert.equal(C.siteURL('napster', 'search', 'x'), null);
});

test('YouTube: music or a plain video', () => {
  assert.equal(C.youtubeKind({ isAd: true, category: 'Music' }), 'advertisement');
  assert.equal(C.youtubeKind({ musicVideoType: 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE' }), 'podcast');
  assert.equal(C.youtubeKind({ musicVideoType: 'MUSIC_VIDEO_TYPE_ATV' }), 'music');
  assert.equal(C.youtubeKind({ category: 'Music' }), 'music');
  assert.equal(C.youtubeKind({ author: 'Orchid Telemetry - Topic', title: 'Velvet Harbor Lights' }), 'music');
  assert.equal(C.youtubeKind({ author: 'OrchidTelemetryVEVO', title: 'Velvet Harbor Lights' }), 'music');
  assert.equal(C.youtubeKind({ author: 'Orchid Telemetry', title: 'Velvet Harbor Lights (Official Audio)' }), 'music');
  assert.equal(C.youtubeKind({ author: 'Slow Lens', title: 'Harbor walk, rainy evening', category: 'Travel & Events' }), 'video');
  assert.equal(C.youtubeKind({ isLive: true, title: 'Harbor cam' }), 'video');
  assert.equal(C.youtubeKind(null), 'video');

  assert.equal(C.cleanYouTubeArtist('Orchid Telemetry - Topic'), 'Orchid Telemetry');
  assert.equal(C.cleanYouTubeArtist('OrchidTelemetryVEVO'), 'OrchidTelemetry');
  assert.equal(C.cleanYouTubeArtist('Slow Lens'), 'Slow Lens');
});

test("the song's video type: the page's own, else a Topic channel's art track", () => {
  assert.equal(C.musicVideoType({ musicVideoType: 'MUSIC_VIDEO_TYPE_OMV' }), 'MUSIC_VIDEO_TYPE_OMV');
  assert.equal(C.musicVideoType({ musicVideoType: ' MUSIC_VIDEO_TYPE_ATV ', author: 'Orchid Telemetry' }), 'MUSIC_VIDEO_TYPE_ATV');
  assert.equal(C.musicVideoType({ author: 'Orchid Telemetry - Topic' }), 'MUSIC_VIDEO_TYPE_ATV', 'Topic uploads are the cover');
  assert.equal(C.musicVideoType({ musicVideoType: 'MUSIC_VIDEO_TYPE_UGC', author: 'Orchid Telemetry - Topic' }), 'MUSIC_VIDEO_TYPE_UGC', 'the page wins');
  assert.equal(C.musicVideoType({ author: 'Slow Lens' }), undefined);
  assert.equal(C.musicVideoType({ musicVideoType: 'hologram' }), undefined, 'only YouTube\'s own values');
  assert.equal(C.musicVideoType(null), undefined);
  assert.equal(P.tab({ tabId: 1, site: 'youtubeMusic', state: 'playing', musicVideoType: 'MUSIC_VIDEO_TYPE_OMV' }).musicVideoType, 'MUSIC_VIDEO_TYPE_OMV');
  assert.equal(P.tab({ tabId: 1, site: 'youtubeMusic', state: 'playing', musicVideoType: 'omv' }).musicVideoType, undefined);
  const before = { title: 'Saffron Static', state: 'playing', sampledAt: 1000, position: 1 };
  assert.ok(C.noticeableChange(before, Object.assign({}, before, { musicVideoType: 'MUSIC_VIDEO_TYPE_ATV' }), 1000), 'a type that arrives late is sent');
});

test("YouTube Music's bylines", () => {
  assert.deepEqual(C.splitByline('Orchid Telemetry • Tidal Glass • 2021'), ['Orchid Telemetry', 'Tidal Glass', '2021']);
  const plain = { artist: 'Orchid Telemetry', album: 'Tidal Glass', duration: 214 };
  assert.deepEqual(C.ytMusicByline('Orchid Telemetry • Tidal Glass • 3:34'), plain);
  assert.deepEqual(C.ytMusicByline('Song • Orchid Telemetry • Tidal Glass • 3:34'), plain);
  assert.deepEqual(C.ytMusicByline('Şarkı • Orchid Telemetry • Tidal Glass • 3:34'), plain, 'the type in any language');
  assert.deepEqual(C.ytMusicByline('Orchid Telemetry'), { artist: 'Orchid Telemetry', album: '', duration: null });
  assert.deepEqual(C.ytMusicByline(''), { artist: '', album: '', duration: null });
});

test('what is worth telling Ahenk', () => {
  const t = 1_762_700_000_000;
  const base = { title: 'Velvet Harbor Lights', artist: 'Orchid Telemetry', state: 'playing', position: 30, sampledAt: t, rate: 1, duration: 214, can: ['playPause'] };
  const later = (changes) => Object.assign({}, base, { position: 31, sampledAt: t + 1000 }, changes);
  assert.equal(C.noticeableChange(null, base, t), true);
  assert.equal(C.noticeableChange(base, later({}), t + 1000), false, 'only time went on');
  assert.equal(C.noticeableChange(base, later({ position: 60 }), t + 1000), true, 'a seek');
  assert.equal(C.noticeableChange(base, later({ title: 'Quiet Engines' }), t + 1000), true);
  assert.equal(C.noticeableChange(base, later({ state: 'paused' }), t + 1000), true);
  assert.equal(C.noticeableChange(base, later({ can: ['playPause', 'seek'] }), t + 1000), true);
  assert.equal(C.noticeableChange(Object.assign({}, base, { volume: 0.5 }), later({ volume: 0.51 }), t + 1000), false);
  assert.equal(C.noticeableChange(Object.assign({}, base, { volume: 0.5 }), later({ volume: 0.6 }), t + 1000), true);
  const paused = Object.assign({}, base, { state: 'paused' });
  assert.equal(C.noticeableChange(paused, Object.assign({}, paused, { sampledAt: t + 5000 }), t + 5000), false, 'paused stays put');
});

test('reconnect pauses grow and stop growing', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 50].map(C.backoff), [1, 2, 4, 8, 15, 30, 30, 30]);
  assert.equal(C.backoff(-3), 1);
});

test('state attributes that do not depend on the UI language', () => {
  assert.equal(C.repeatFromState('NONE'), 'off');
  assert.equal(C.repeatFromState('ALL'), 'all');
  assert.equal(C.repeatFromState('ONE'), 'one');
  assert.equal(C.repeatFromState('context'), 'all');
  assert.equal(C.repeatFromState('track'), 'one');
  assert.equal(C.repeatFromState('mixed'), 'one');
  assert.equal(C.repeatFromState(undefined), null);
  assert.equal(C.repeatFromState('Tekrarla'), null);
  assert.equal(C.boolAttr('true'), true);
  assert.equal(C.boolAttr(false), false);
  assert.equal(C.boolAttr('mixed'), null);
  assert.equal(C.boolAttr(null), null);
});
