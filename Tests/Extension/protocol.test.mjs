// The extension's side of the wire protocol (Extension/lib/protocol.js),
// checked against the fixtures the app's tests decode
// (Tests/Fixtures/bridge, BridgeProtocolTests.swift).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { load, fixture } from './load.mjs';

const { P } = load();

test('the ports both sides try', () => {
  assert.deepEqual(P.ports(42617), [42617, 42618, 42619, 42620]);
  assert.deepEqual(P.ports(65534), [65534, 65535]);
  assert.deepEqual(P.ports(80), P.ports(P.DEFAULT_PORT), 'a privileged port falls back to the default');
  assert.deepEqual(P.ports('42617'), P.ports(P.DEFAULT_PORT));
  assert.equal(P.DEFAULT_PORT, 42617, "the app's default (SourceSettings.browserBridgePort)");
  assert.equal(P.PORT_COUNT, 4, 'BridgeProtocol.portCount');
  assert.equal(P.HEARTBEAT, 20, 'BridgeProtocol.heartbeatInterval');
  assert.ok(P.SILENCE_LIMIT > 2 * P.HEARTBEAT && P.SILENCE_LIMIT < 65, 'gives up before the app does (idleTimeout 65 s)');
});

test('what the extension sends is exactly what the app decodes', () => {
  const hello = fixture('hello');
  assert.deepEqual(P.hello({
    extensionVersion: '1.0.0', extensionOrigin: hello.extensionOrigin,
    browser: { name: 'Microsoft Edge', version: '142.0.0.0', brands: ['Microsoft Edge', 'Chromium'] }, profile: hello.profile,
  }), hello);
  assert.deepEqual(P.tabs(fixture('tabs').tabs), fixture('tabs'));
  assert.deepEqual(P.tabUpdate(fixture('tab').tab), fixture('tab'));
  assert.deepEqual(P.tabRemoved(77), fixture('tab-removed'));
  assert.deepEqual(P.ping(), fixture('ping'));
  for (const name of ['result-play', 'result-playlists', 'result-queue']) {
    const expected = fixture(name);
    assert.deepEqual(P.result(expected.id, expected.ok, expected), expected, name);
  }
  const lyrics = fixture('lyrics').lyrics;
  assert.deepEqual(P.lyrics(lyrics.tabId, lyrics.site, lyrics.song, lyrics.lines), fixture('lyrics'));
});

test('a tab report drops what the app would not read', () => {
  const tab = P.tab({
    tabId: 9, site: 'youtube', title: '  Harbor walk  ', artist: 'Slow Lens', duration: Infinity, position: -4,
    state: 'dancing', can: ['seek', 'teleport', 'playPause'], repeat: 'sometimes', volume: 7, kind: 'hologram', rate: 40,
    liked: 'yes', artwork: 'https://img.example/x.jpg',
  });
  assert.equal(tab.title, 'Harbor walk');
  assert.equal(tab.duration, undefined);
  assert.equal(tab.position, 0);
  assert.equal(tab.state, 'paused');
  assert.deepEqual(tab.can, ['playPause', 'seek']);
  assert.equal(tab.repeat, undefined);
  assert.equal(tab.volume, 1);
  assert.equal(tab.kind, 'unknown');
  assert.equal(tab.rate, 16);
  assert.equal(tab.liked, undefined);
  assert.ok(tab.sampledAt > 0, 'stamped when missing');
  assert.ok(!('album' in tab) || tab.album === '');
  const long = P.tab({ tabId: 1, site: 'spotify', title: 'x'.repeat(900), state: 'playing' });
  assert.equal(long.title.length, 500);
});

test('frames from Ahenk', () => {
  assert.deepEqual(P.parse('{"type":"welcome","protocol":1,"app":"Ahenk"}'), { type: 'welcome', protocol: 1, app: 'Ahenk' });
  for (const text of ['', 'not json', '[1,2]', '{"kind":"welcome"}', 'null', '{"type":5}', 42]) assert.equal(P.parse(text), null, String(text));
  assert.equal(P.parse('{"type":"x","pad":"' + 'a'.repeat(1 << 20) + '"}'), null, 'too large');

  assert.equal(P.acceptsWelcome({ type: 'welcome', app: 'Ahenk', protocol: 1 }), true);
  assert.equal(P.acceptsWelcome({ type: 'welcome', app: 'Ahenk', protocol: 2 }), false, 'a version this extension does not speak');
  assert.equal(P.acceptsWelcome({ type: 'welcome', app: 'Other', protocol: 1 }), false, 'not Ahenk on that port');
  assert.equal(P.acceptsWelcome({ type: 'error', code: 'incompatible' }), false);
});

test('results carry only known extras', () => {
  assert.deepEqual(P.result('r1', true), { type: 'result', id: 'r1', ok: true });
  assert.deepEqual(P.result('r2', 0, { error: 'x'.repeat(300), volume: 1.4, tabId: 3 }), { type: 'result', id: 'r2', ok: false, error: 'x'.repeat(200), volume: 1, tabId: 3 });
  const songs = P.result('r3', true, { songs: [{ title: 'Quiet Engines', artist: 'Nadia Ferro', duration: 0, trackId: 'ahenkMock02', extra: 1 }] }).songs;
  assert.deepEqual(songs, [{ title: 'Quiet Engines', artist: 'Nadia Ferro', trackId: 'ahenkMock02' }]);
});
