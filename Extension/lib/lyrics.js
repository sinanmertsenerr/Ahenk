// Ahenk browser bridge: reads the synced lyrics a music site loaded for
// itself (the JSON its own lyrics view fetched). Pure: JSON in, timed lines
// out. Lyrics are passed to Ahenk only; nothing here logs them.
(function (root) {
  'use strict';

  /** Responses worth looking at, per site (the rest are never parsed). */
  const URL_PATTERNS = {
    spotify: [/\/color-lyrics\/v\d+\/track\//, /lyrics/i],
    youtubeMusic: [/\/youtubei\/v1\/browse/],
    deezer: [/pipe\.deezer\.com\/api/, /lyrics/i],
    tidal: [/\/v\d+\/tracks\/\d+\/lyrics/, /lyrics/i],
    amazonMusic: [/lyric/i],
    soundCloud: [],
    youtube: [],
  };

  function wants(site, url) {
    return (URL_PATTERNS[site] || []).some((pattern) => pattern.test(String(url || '')));
  }

  /** LRC text → lines (several stamps on one line give several lines). */
  function parseLRC(text) {
    const lines = [];
    let offset = 0;
    for (const raw of String(text || '').split(/\r?\n/)) {
      const tag = raw.match(/^\s*\[offset:\s*([+-]?\d+)\s*\]\s*$/i);
      if (tag) {
        offset = Number(tag[1]) / 1000;
        continue;
      }
      const stamps = [];
      let rest = raw;
      let m;
      while ((m = rest.match(/^\s*\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/))) {
        const seconds = Number(m[1]) * 60 + Number(m[2].replace(':', '.'));
        if (Number.isFinite(seconds)) stamps.push(seconds);
        rest = rest.slice(m[0].length);
      }
      if (!stamps.length) continue;
      const words = rest.replace(/<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g, '').trim();
      for (const start of stamps) lines.push({ start: Math.max(0, start - offset), text: words });
    }
    return finish(lines);
  }

  /** Sorted, ends filled from the next line, at least two lines with text. */
  function finish(lines) {
    const sorted = lines
      .filter((line) => line && Number.isFinite(line.start) && line.start >= 0 && typeof line.text === 'string')
      .sort((a, b) => a.start - b.start)
      .map((line) => {
        const out = { start: round(line.start), text: line.text.trim() };
        if (Number.isFinite(line.end) && line.end >= line.start) out.end = round(line.end);
        if (Array.isArray(line.words) && line.words.length) out.words = line.words;
        return out;
      });
    return sorted.filter((line) => line.text).length >= 2 ? sorted : null;
  }

  function round(seconds) {
    return Math.round(seconds * 1000) / 1000;
  }

  /** One stamp, "[01:02.50]", "01:02.50" or "1:02", in seconds (NaN if none). */
  function stampSeconds(text) {
    const m = String(text || '').trim().match(/^\[?(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]?$/);
    return m ? Number(m[1]) * 60 + Number(m[2].replace(':', '.')) : NaN;
  }

  function number(value) {
    if (typeof value === 'number') return value;
    if (typeof value === 'string' && /^\s*-?\d+(\.\d+)?\s*$/.test(value)) return Number(value);
    return NaN;
  }

  /** Spotify's color-lyrics: { lyrics: { syncType, lines: [{ startTimeMs, words, endTimeMs }] } }. */
  function fromSpotify(json) {
    const lyrics = json && json.lyrics;
    if (!lyrics || !Array.isArray(lyrics.lines) || !/SYNCED/.test(String(lyrics.syncType || '')) || /UNSYNCED/.test(String(lyrics.syncType))) {
      return null;
    }
    return finish(
      lyrics.lines.map((line) => ({
        start: number(line.startTimeMs) / 1000,
        end: number(line.endTimeMs) > 0 ? number(line.endTimeMs) / 1000 : undefined,
        text: String(line.words ?? ''),
      }))
    );
  }

  /** Deezer: …lyrics.synchronizedLines: [{ milliseconds, duration, line, lrcTimestamp }]. */
  function fromDeezer(json) {
    const found = findKey(json, 'synchronizedLines', 8);
    if (!Array.isArray(found)) return null;
    return finish(
      found.map((line) => {
        let start = number(line.milliseconds) / 1000;
        if (!Number.isFinite(start)) start = stampSeconds(line.lrcTimestamp);
        const duration = number(line.duration) / 1000;
        return { start, end: Number.isFinite(duration) && duration > 0 ? start + duration : undefined, text: String(line.line ?? '') };
      })
    );
  }

  /** TIDAL: { subtitles: "[00:12.34] …" } (LRC). */
  function fromTidal(json) {
    if (!json || typeof json.subtitles !== 'string') return null;
    return parseLRC(json.subtitles);
  }

  /** YouTube Music: timedLyricsData: [{ lyricLine, cueRange: { startTimeMilliseconds, endTimeMilliseconds } }]. */
  function fromYouTubeMusic(json) {
    const found = findKey(json, 'timedLyricsData', 16);
    if (!Array.isArray(found)) return null;
    return finish(
      found.map((item) => {
        const range = item.cueRange || {};
        const end = number(range.endTimeMilliseconds);
        return { start: number(range.startTimeMilliseconds) / 1000, end: end > 0 ? end / 1000 : undefined, text: String(item.lyricLine ?? '') };
      })
    );
  }

  const TEXT_KEYS = ['words', 'text', 'line', 'lyricLine', 'lyric', 'content', 'value'];
  const TIME_KEYS = [
    ['startTimeMs', 1000], ['startTimeMilliseconds', 1000], ['startMs', 1000], ['milliseconds', 1000], ['timeMs', 1000],
    ['startTime', 0], ['start', 0], ['time', 0], ['timestamp', 0], ['offset', 0], ['begin', 0],
  ];

  /** Any array of objects that carry a time and a line (Amazon Music and
   *  others whose shape is not known exactly): the longest such list. */
  function scanTimedLines(json) {
    let best = null;
    let visited = 0;
    function lineOf(item) {
      if (!item || typeof item !== 'object') return null;
      const textKey = TEXT_KEYS.find((key) => typeof item[key] === 'string');
      if (!textKey) return null;
      let time = NaN;
      let divisor = 0;
      for (const [key, unit] of TIME_KEYS) {
        const value = item[key] ?? (item.cueRange && item.cueRange[key]);
        if (Number.isFinite(number(value))) {
          time = number(value);
          divisor = unit;
          break;
        }
        if (typeof value === 'string' && Number.isFinite(stampSeconds(value))) {
          time = stampSeconds(value);
          divisor = 1;
          break;
        }
      }
      return Number.isFinite(time) ? { time, divisor, text: item[textKey] } : null;
    }
    function visit(node, depth) {
      if (!node || typeof node !== 'object' || depth > 14 || visited > 60000) return;
      visited += 1;
      if (Array.isArray(node)) {
        if (node.length >= 3) {
          const lines = node.map(lineOf);
          const good = lines.filter(Boolean);
          if (good.length >= 3 && good.length >= node.length * 0.8 && (!best || good.length > best.length)) {
            const ascending = good.every((line, i) => i === 0 || line.time >= good[i - 1].time);
            if (ascending) best = good;
          }
        }
        for (const child of node) visit(child, depth + 1);
      } else {
        for (const key of Object.keys(node)) visit(node[key], depth + 1);
      }
    }
    visit(json, 0);
    if (!best) return null;
    // Milliseconds when the key says so or the numbers are far beyond a song.
    const last = best[best.length - 1].time;
    const unit = best[0].divisor === 1000 || (best[0].divisor === 0 && last > 3600) ? 1000 : 1;
    return finish(best.map((line) => ({ start: line.time / unit, text: line.text })));
  }

  function findKey(node, key, depth) {
    if (!node || typeof node !== 'object' || depth < 0) return undefined;
    if (!Array.isArray(node) && Object.prototype.hasOwnProperty.call(node, key)) return node[key];
    for (const child of Array.isArray(node) ? node : Object.values(node)) {
      const found = findKey(child, key, depth - 1);
      if (found !== undefined) return found;
    }
    return undefined;
  }

  /**
   * The synced lines in a site's JSON response, with the track it names
   * when the response says (so lyrics loaded ahead for the next song are
   * never shown for this one). Null when there are none.
   */
  function extract(site, url, json) {
    if (!json || typeof json !== 'object') return null;
    let lines = null;
    let trackId = null;
    switch (site) {
      case 'spotify':
        lines = fromSpotify(json);
        trackId = root.AhenkCommon ? root.AhenkCommon.spotifyTrackId(url) : null;
        break;
      case 'deezer':
        lines = fromDeezer(json);
        {
          const track = findKey(json, 'track', 4);
          if (track && (typeof track.id === 'string' || typeof track.id === 'number')) trackId = String(track.id);
        }
        break;
      case 'tidal':
        lines = fromTidal(json);
        {
          const m = String(url || '').match(/\/tracks\/(\d+)\/lyrics/);
          trackId = m ? m[1] : json.trackId != null ? String(json.trackId) : null;
        }
        break;
      case 'youtubeMusic':
        lines = fromYouTubeMusic(json);
        break;
      default:
        break;
    }
    if (!lines) lines = scanTimedLines(json);
    return lines ? { lines, trackId } : null;
  }

  const api = { URL_PATTERNS, wants, parseLRC, stampSeconds, fromSpotify, fromDeezer, fromTidal, fromYouTubeMusic, scanTimedLines, extract };
  if (!root.AhenkLyrics) Object.defineProperty(root, 'AhenkLyrics', { value: Object.freeze(api), configurable: false, enumerable: false });
})(typeof globalThis !== 'undefined' ? globalThis : this);
