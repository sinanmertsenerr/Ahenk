// The extension's site helpers (Extension/lib/common.js). Invented songs,
// artists and IDs only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { load, fixture } from './load.mjs';

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

test("a video's title that names its artist counts as that artist's song", () => {
  const wanted = { title: 'Quiet Engines', artist: 'Nadia Ferro' };
  // Under a channel with a name of its own, in either order.
  assert.ok(C.matchScore(wanted, { title: 'Nadia Ferro & Kestrel - Quiet Engines (Official Video)', artist: 'Low Orbit Records' }) >= 0.7);
  assert.ok(C.matchScore(wanted, { title: 'Quiet Engines (Old Version) – Nadia Ferro', artist: 'Some Uploader' }) >= 0.7);
  // Another artist's video of that name, or a name inside another word, is not.
  assert.ok(C.matchScore(wanted, { title: 'Kestrel & Vale - Quiet Engines', artist: 'Paper Comets TV' }) < 0.5);
  assert.ok(C.matchScore({ title: 'Quiet Engines', artist: 'Nadia' }, { title: 'Nadiah - Quiet Engines', artist: 'Paper Comets TV' }) < 0.5);
  // A title with a dash that names nobody scores as it is written.
  const dashed = { title: 'Quiet Engines - 2019 Remaster', artist: 'Nadia Ferro', duration: 187 };
  assert.ok(Math.abs(C.matchScore(Object.assign({ duration: 187 }, wanted), dashed) - 0.95) < 1e-9);
  // The channel's own song still wins over a video that only names the artist.
  const results = [
    { title: 'Nadia Ferro - Quiet Engines (Fan Lyric Video)', artist: 'Some Uploader' },
    { title: 'Quiet Engines', artist: 'Nadia Ferro' },
  ];
  assert.equal(C.pickBest(wanted, results, 0.5), results[1]);
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
  assert.equal(C.noticeableChange(base, later({ rate: 1.25, position: 31.25 }), t + 1000), true, 'another speed');
});

test('the speed Ahenk asks a tab for', () => {
  assert.equal(C.playbackRate(1.25), 1.25);
  assert.equal(C.playbackRate('0.85'), 0.85);
  assert.equal(C.playbackRate(1.2549), 1.25, 'two decimals');
  assert.equal(C.playbackRate(9), 4);
  assert.equal(C.playbackRate(0.01), 0.25);
  for (const odd of [NaN, Infinity, 0, -1, 'fast', null, undefined, {}]) assert.equal(C.playbackRate(odd), 1, String(odd));

  // Nothing asked: the tab's own speed is never touched.
  assert.equal(C.rateCorrection(null, 1.5), null);
  assert.equal(C.rateCorrection(undefined, 1), null);
  // The site put a new song back at 1: Ahenk's speed returns.
  assert.equal(C.rateCorrection(1.25, 1), 1.25);
  assert.equal(C.rateCorrection(1.25, 1.25), null);
  assert.equal(C.rateCorrection(1.25, 1.2501), null, 'close enough');
  assert.equal(C.rateCorrection(0.8, NaN), 0.8);
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

test('the page that is shown is the one that was asked for', () => {
  const wanted = C.siteURL('youtubeMusic', 'search', 'Quiet Engines Nadia Ferro');
  // The site writes a space its own way and adds parameters of its own.
  assert.equal(C.sameAddress('https://music.youtube.com/search?q=Quiet+Engines+Nadia+Ferro', wanted), true);
  assert.equal(C.sameAddress('https://music.youtube.com/search?q=Quiet%20Engines%20Nadia%20Ferro&sp=x', wanted), true);
  assert.equal(C.sameAddress('https://music.youtube.com/search?q=Quiet+Engines', wanted), false);
  assert.equal(C.sameAddress('https://www.youtube.com/search?q=Quiet+Engines+Nadia+Ferro', wanted), false);
  assert.equal(C.sameAddress('https://music.youtube.com/watch?v=ahenkMock02&list=RDAMx', 'https://music.youtube.com/watch?v=ahenkMock02'), true);
  assert.equal(C.sameAddress('https://music.youtube.com/watch?v=ahenkMock01', 'https://music.youtube.com/watch?v=ahenkMock02'), false);
  assert.equal(C.sameAddress('https://music.youtube.com/playlist/?list=PLahenkKiyidan', 'https://music.youtube.com/playlist?list=PLahenkKiyidan'), true);
  assert.equal(C.sameAddress('not an address', wanted), false);
  assert.equal(C.sameAddress(wanted, ''), false);
});

test("what YouTube's own page is told to show an address in place", () => {
  // YouTube Music: a video, a search, a playlist.
  assert.deepEqual(C.youtubeEndpoint('youtubeMusic', C.siteURL('youtubeMusic', 'track', 'ahenkMock01')), { watchEndpoint: { videoId: 'ahenkMock01' } });
  assert.deepEqual(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/watch?v=ahenkMock01&list=PLahenkKiyidan'), { watchEndpoint: { videoId: 'ahenkMock01', playlistId: 'PLahenkKiyidan' } });
  assert.deepEqual(C.youtubeEndpoint('youtubeMusic', C.siteURL('youtubeMusic', 'search', 'Marmara Neon Deniz Ulaş Trio')), { searchEndpoint: { query: 'Marmara Neon Deniz Ulaş Trio' } });
  assert.deepEqual(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/playlist?list=PLahenkKiyidan'), { browseEndpoint: { browseId: 'VLPLahenkKiyidan' } });
  // youtube.com also reads the page the command leads to.
  assert.deepEqual(C.youtubeEndpoint('youtube', C.siteURL('youtube', 'track', 'ahenkMock01')), {
    watchEndpoint: { videoId: 'ahenkMock01' },
    commandMetadata: { webCommandMetadata: { url: '/watch?v=ahenkMock01', webPageType: 'WEB_PAGE_TYPE_WATCH', rootVe: 3832 } },
  });
  assert.deepEqual(C.youtubeEndpoint('youtube', C.siteURL('youtube', 'search', 'Quiet Engines')), {
    searchEndpoint: { query: 'Quiet Engines' },
    commandMetadata: { webCommandMetadata: { url: '/results?search_query=Quiet%20Engines', webPageType: 'WEB_PAGE_TYPE_SEARCH', rootVe: 4724 } },
  });
  assert.deepEqual(C.youtubeEndpoint('youtube', 'https://www.youtube.com/playlist?list=PLahenkKiyidan'), {
    browseEndpoint: { browseId: 'VLPLahenkKiyidan' },
    commandMetadata: { webCommandMetadata: { url: '/playlist?list=PLahenkKiyidan', webPageType: 'WEB_PAGE_TYPE_PLAYLIST', rootVe: 5754 } },
  });
  // Anything else is loaded as a page: another site's address, another
  // kind of page, an ID or a query that is not one.
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'https://www.youtube.com/watch?v=ahenkMock01'), null);
  assert.equal(C.youtubeEndpoint('youtube', 'https://music.youtube.com/watch?v=ahenkMock01'), null);
  assert.equal(C.youtubeEndpoint('youtube', 'https://youtu.be/ahenkMock01'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'http://music.youtube.com/watch?v=ahenkMock01'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/watch?v=short'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/watch?v=ahenkMock01&list=a%20b'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/search?q=%20'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/playlist'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'https://music.youtube.com/channel/UCx'), null);
  assert.equal(C.youtubeEndpoint('spotify', 'https://open.spotify.com/track/x'), null);
  assert.equal(C.youtubeEndpoint('youtubeMusic', 'nowhere'), null);
});

test('versions: which is newer, and when the extension takes itself up again', () => {
  assert.deepEqual(C.parseVersion('1.5'), [1, 5, 0]);
  assert.deepEqual(C.parseVersion(' v1.10.3 '), [1, 10, 3]);
  for (const text of ['', 'test', '1.2.3.4', '1..2', '-1.0', '1.x', null, undefined]) assert.equal(C.parseVersion(text), null, String(text));
  assert.equal(C.versionNewer('1.5.0', '1.4.0'), true);
  assert.equal(C.versionNewer('1.10.0', '1.9.9'), true, 'numbers, not text');
  assert.equal(C.versionNewer('2', '1.99.99'), true);
  assert.equal(C.versionNewer('1.5.0', '1.5'), false, 'the same version');
  assert.equal(C.versionNewer('1.4.0', '1.5.0'), false);
  assert.equal(C.versionNewer('newer', '1.0.0'), false, 'an unreadable version is not newer');
  assert.equal(C.versionNewer('1.5.0', undefined), false);
  // Ahenk carries 1.5.0.
  assert.equal(C.takesUpNewer('1.5.0', '1.4.0', undefined), true);
  assert.equal(C.takesUpNewer('1.5.0', '1.4.0', '1.4.0'), true, 'tried for an older version before');
  assert.equal(C.takesUpNewer('1.5.0', '1.4.0', '1.5.0'), false, 'once per version: the browser keeps a copy of its own');
  assert.equal(C.takesUpNewer('1.5.0', '1.5.0', undefined), false);
  assert.equal(C.takesUpNewer('1.5.0', '1.6.0', undefined), false, 'an older Ahenk does not take a newer extension down');
  assert.equal(C.takesUpNewer(undefined, '1.4.0', undefined), false, 'an Ahenk from before it said so');
});

test("YouTube Music's pairing of a video with its song is read from its answer", () => {
  const renderer = (videoId, length) => ({ playlistPanelVideoRenderer: { videoId, title: { runs: [{ text: 'Velvet Harbor Lights' }] }, lengthText: { runs: [{ text: length }] } } });
  const answer = {
    contents: { deep: [{ tabs: [{ panel: { contents: [
      { playlistPanelVideoRenderer: { videoId: 'ahenkMock09' } },
      { playlistPanelVideoWrapperRenderer: {
        primaryRenderer: renderer('ahenkMock0V', '4:22'),
        counterpart: [{
          counterpartRenderer: renderer('ahenkMock01', '3:34'),
          segmentMap: { segment: [
            { primaryVideoStartTimeMilliseconds: '41000', counterpartVideoStartTimeMilliseconds: '613', durationMilliseconds: '120000' },
            { primaryVideoStartTimeMilliseconds: '175500', counterpartVideoStartTimeMilliseconds: '120613', durationMilliseconds: '93000' },
            { primaryVideoStartTimeMilliseconds: 'x', counterpartVideoStartTimeMilliseconds: '0', durationMilliseconds: '5' },
            { primaryVideoStartTimeMilliseconds: '0', counterpartVideoStartTimeMilliseconds: '0', durationMilliseconds: '0' },
          ] },
        }],
      } },
    ] } }] }] },
  };
  const expected = fixture('result-clip').clip;
  assert.deepEqual(C.clipSegments(answer, 'ahenkMock0V'), expected);
  // What Ahenk is told is what the app's fixture says.
  assert.deepEqual(P.result('r14', true, { tabId: 41, clip: C.clipSegments(answer, 'ahenkMock0V') }), fixture('result-clip'));
  // Another video, a listener the site offers no switch to, or no answer at all.
  assert.equal(C.clipSegments(answer, 'ahenkMock01'), null);
  assert.equal(C.clipSegments({ contents: [renderer('ahenkMock0V', '4:22')] }, 'ahenkMock0V'), null);
  assert.equal(C.clipSegments(null, 'ahenkMock0V'), null);
  assert.equal(P.result('r1', true, { clip: { videoId: 'ahenkMock0V', segments: [] } }).clip, undefined);
  assert.ok(P.CAPABILITIES.includes('clip'));
});
