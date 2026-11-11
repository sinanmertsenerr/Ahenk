// Ahenk browser bridge: the messages the extension and Ahenk exchange over
// the local WebSocket (the app's side is Sources/AhenkKit/Bridge/
// BridgeProtocol.swift; the shared fixtures in Tests/Fixtures/bridge keep
// both sides honest). One JSON object per text frame, `type` first.
(function (root) {
  'use strict';

  const VERSION = 1;
  const MIN_VERSION = 1;
  /** Seconds between pings (also keeps the MV3 service worker alive). */
  const HEARTBEAT = 20;
  /** Ahenk is dead to us after this long without a message from it. */
  const SILENCE_LIMIT = 50;
  const DEFAULT_PORT = 42617;
  const PORT_COUNT = 4;
  /** Base64 characters of sound in one answer (15 s at 16 kHz, 16 bits). */
  const MAX_SOUND = 640000;

  const CAPABILITIES = ['playPause', 'next', 'previous', 'seek', 'shuffle', 'repeat', 'repeatOne', 'like', 'unlike', 'search', 'playlists', 'queue', 'queueEdit', 'volume', 'rate', 'sound', 'clip'];
  const KINDS = ['music', 'video', 'podcast', 'advertisement', 'unknown'];
  const STATES = ['playing', 'paused', 'stopped'];
  const REPEATS = ['off', 'all', 'one'];

  function ports(base, count) {
    const first = Number.isInteger(base) && base >= 1024 && base <= 65535 ? base : DEFAULT_PORT;
    const result = [];
    for (let i = 0; i < (count || PORT_COUNT); i += 1) if (first + i <= 65535) result.push(first + i);
    return result;
  }

  function finite(value, min, max) {
    if (typeof value !== 'number' || !Number.isFinite(value)) return undefined;
    let v = value;
    if (min !== undefined) v = Math.max(min, v);
    if (max !== undefined) v = Math.min(max, v);
    return v;
  }

  function str(value, limit) {
    if (typeof value !== 'string') return undefined;
    const text = value.trim();
    return text ? text.slice(0, limit || 500) : undefined;
  }

  function bool(value) {
    return typeof value === 'boolean' ? value : undefined;
  }

  /** Drops undefined fields so the JSON stays small and stable. */
  function compact(object) {
    const out = {};
    for (const key of Object.keys(object)) if (object[key] !== undefined) out[key] = object[key];
    return out;
  }

  function hello({ extensionVersion, extensionOrigin, browser, profile }) {
    return compact({
      type: 'hello',
      protocol: VERSION,
      minProtocol: MIN_VERSION,
      extensionVersion: String(extensionVersion || ''),
      extensionOrigin: str(extensionOrigin),
      browser: compact({ name: String((browser && browser.name) || ''), version: str(browser && browser.version), brands: browser && Array.isArray(browser.brands) ? browser.brands.map(String) : undefined }),
      profile: String(profile || ''),
    });
  }

  /** A tab's report in wire form (unknown values dropped, numbers clamped). */
  function tab(state) {
    return compact({
      tabId: state.tabId,
      site: String(state.site || ''),
      url: str(state.url, 2000),
      title: str(state.title) || '',
      artist: str(state.artist) || '',
      album: str(state.album) || '',
      artwork: str(state.artwork, 2000),
      duration: finite(state.duration, 0),
      position: finite(state.position, 0),
      sampledAt: finite(state.sampledAt, 0) || Date.now(),
      rate: finite(state.rate, 0, 16),
      state: STATES.includes(state.state) ? state.state : 'paused',
      liked: bool(state.liked),
      shuffle: bool(state.shuffle),
      repeat: REPEATS.includes(state.repeat) ? state.repeat : undefined,
      trackId: str(state.trackId, 200),
      trackUrl: str(state.trackUrl, 2000),
      kind: KINDS.includes(state.kind) ? state.kind : 'unknown',
      musicVideoType: typeof state.musicVideoType === 'string' && /^MUSIC_VIDEO_TYPE_[A-Z_]{1,40}$/.test(state.musicVideoType) ? state.musicVideoType : undefined,
      can: (state.can || []).filter((c) => CAPABILITIES.includes(c)).sort(),
      volume: finite(state.volume, 0, 1),
      active: bool(state.active),
      lastActive: finite(state.lastActive, 0),
    });
  }

  function tabs(list) {
    return { type: 'tabs', tabs: (list || []).map(tab) };
  }

  function tabUpdate(state) {
    return { type: 'tab', tab: tab(state) };
  }

  function tabRemoved(tabId) {
    return { type: 'tabRemoved', tabId };
  }

  function song(value) {
    if (!value) return undefined;
    return compact({
      title: str(value.title) || '',
      artist: str(value.artist) || '',
      album: str(value.album),
      duration: finite(value.duration, 0) || undefined,
      trackId: str(value.trackId, 200),
      url: str(value.url, 2000),
      artwork: str(value.artwork, 2000),
    });
  }

  function lyrics(tabId, site, current, lines, heard) {
    const body = {
      tabId,
      site,
      song: song(current),
      lines: (lines || []).map((line) => compact({ start: finite(line.start, 0), end: finite(line.end, 0), text: String(line.text || ''), words: line.words })),
    };
    // Automatic captions: heard words with their times, not lyrics.
    if (heard) body.heard = true;
    return { type: 'lyrics', lyrics: body };
  }

  /** A stretch of the sound a tab's player holds (16-bit PCM in base64),
   *  or only how far it holds (`from`, `until`) when it has no more yet. */
  function sound(value) {
    if (!value || typeof value !== 'object') return undefined;
    const samples = typeof value.samples === 'string' && value.samples.length > 0 && value.samples.length <= MAX_SOUND ? value.samples : undefined;
    return compact({
      from: finite(value.from, 0),
      until: finite(value.until, 0),
      start: samples ? finite(value.start, 0) : undefined,
      rate: samples ? finite(value.rate, 8000, 48000) : undefined,
      samples,
    });
  }

  /** Where a song falls in its video (`C.clipSegments`), numbers checked. */
  function clip(value) {
    if (!value || typeof value !== 'object' || !Array.isArray(value.segments)) return undefined;
    const segments = value.segments
      .map((segment) => ({ video: finite(segment && segment.video, 0), song: finite(segment && segment.song, 0), duration: finite(segment && segment.duration, 0) }))
      .filter((segment) => segment.video !== undefined && segment.song !== undefined && segment.duration > 0)
      .slice(0, 64);
    if (!segments.length || !str(value.videoId, 20)) return undefined;
    return compact({ videoId: str(value.videoId, 20), songId: str(value.songId, 20), songSeconds: finite(value.songSeconds, 0), segments });
  }

  /** The answer to a command or request; `extra` adds playlists, songs, queue, volume, sound, clip. */
  function result(id, ok, extra) {
    const base = { type: 'result', id, ok: !!ok };
    if (!extra) return base;
    return compact({
      ...base,
      outcome: extra.outcome,
      error: str(extra.error, 200),
      tabId: extra.tabId,
      playlists: extra.playlists ? extra.playlists.map((p) => compact({ id: String(p.id), name: String(p.name || ''), url: str(p.url, 2000), count: Number.isInteger(p.count) ? p.count : undefined, artwork: str(p.artwork, 2000) })) : undefined,
      songs: extra.songs ? extra.songs.map(song) : undefined,
      queue: extra.queue ? extra.queue.map((item) => compact({ index: item.index, song: song(item.song), current: !!item.current })) : undefined,
      volume: finite(extra.volume, 0, 1),
      sound: sound(extra.sound),
      clip: clip(extra.clip),
    });
  }

  function ping() {
    return { type: 'ping' };
  }

  function pong() {
    return { type: 'pong' };
  }

  /** A frame from Ahenk as an object with a string `type`, or null. */
  function parse(text) {
    if (typeof text !== 'string' || text.length > 1 << 20) return null;
    try {
      const message = JSON.parse(text);
      return message && typeof message === 'object' && typeof message.type === 'string' ? message : null;
    } catch (_) {
      return null;
    }
  }

  /** A welcome we can live with: Ahenk's name and a version we speak. */
  function acceptsWelcome(message) {
    return !!message && message.type === 'welcome' && message.app === 'Ahenk' && Number.isInteger(message.protocol)
      && message.protocol >= MIN_VERSION && message.protocol <= VERSION;
  }

  const api = { VERSION, MIN_VERSION, HEARTBEAT, SILENCE_LIMIT, DEFAULT_PORT, PORT_COUNT, CAPABILITIES, ports, hello, tab, tabs, tabUpdate, tabRemoved, lyrics, result, ping, pong, parse, acceptsWelcome, song };
  // The newest scripts win: an updated extension puts its own over the
  // ones a page still holds (a page from before 1.5.0 keeps its own
  // until it loads again).
  try {
    Object.defineProperty(root, 'AhenkProtocol', { value: Object.freeze(api), configurable: true, enumerable: false });
  } catch (_) {
    // Held by scripts that cannot be replaced.
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
