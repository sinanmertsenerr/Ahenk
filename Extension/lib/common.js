// Ahenk browser bridge: pure helpers shared by the page scripts, the
// background and the tests (node --test). No DOM, no extension APIs.
(function (root) {
  'use strict';

  /** The sites the extension knows, as the app names them (BrowserSite). */
  const SITES = ['youtubeMusic', 'youtube', 'spotify', 'soundCloud', 'amazonMusic', 'deezer', 'tidal'];

  /** The site of a host name, or null (mirrors BrowserSite.site(forHost:)). */
  function siteForHost(rawHost) {
    const host = String(rawHost || '').toLowerCase().replace(/^\.+|\.+$/g, '');
    const is = (domain) => host === domain || host.endsWith('.' + domain);
    if (is('music.youtube.com')) return 'youtubeMusic';
    if (is('youtube.com') || host === 'youtu.be' || is('youtube-nocookie.com')) return 'youtube';
    if (host === 'open.spotify.com') return 'spotify';
    if (is('soundcloud.com')) return 'soundCloud';
    if (host.startsWith('music.amazon.') || host.includes('.music.amazon.')) return 'amazonMusic';
    if (is('deezer.com')) return 'deezer';
    if (host === 'listen.tidal.com') return 'tidal';
    return null;
  }

  function siteForURL(url) {
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null;
      return siteForHost(parsed.hostname);
    } catch (_) {
      return null;
    }
  }

  /** "1:23" → 83, "1:02:03" → 3723, "-0:12" → 12; null for anything else. */
  function parseClock(text) {
    const match = String(text || '').trim().replace(/^[-−–]\s*/, '').match(/^(\d{1,3})(?::(\d{1,2}))?(?::(\d{1,2}))?$/);
    if (!match) return null;
    const parts = [match[1], match[2], match[3]].filter((p) => p !== undefined).map(Number);
    if (parts.length === 1) return null;
    if (parts.slice(1).some((p) => p > 59)) return null;
    return parts.reduce((total, part) => total * 60 + part, 0);
  }

  /** A player's two time labels: the elapsed time and either the length
   *  ("3:45") or what is left ("-1:15"); null without an elapsed time. */
  function clockPair(elapsedText, otherText) {
    const position = parseClock(elapsedText);
    if (position === null) return null;
    const other = parseClock(otherText);
    if (other === null) return { position, duration: undefined };
    const remaining = /^\s*[-−–]/.test(String(otherText || ''));
    return { position, duration: remaining ? position + other : other };
  }

  /** The largest picture of a mediaSession artwork list (square preferred). */
  function bestArtwork(list) {
    if (!list || typeof list.length !== 'number') return null;
    let best = null;
    let bestScore = -1;
    for (const item of Array.from(list)) {
      if (!item || !item.src) continue;
      let width = 0;
      let height = 0;
      for (const size of String(item.sizes || '').split(/\s+/)) {
        const m = size.match(/^(\d+)[xX](\d+)$/);
        if (m && Number(m[1]) * Number(m[2]) > width * height) {
          width = Number(m[1]);
          height = Number(m[2]);
        }
      }
      const area = width * height || 1;
      const square = width && height && Math.abs(width - height) <= Math.max(width, height) * 0.05 ? 1.2 : 1;
      const score = area * square;
      if (score > bestScore) {
        bestScore = score;
        best = item.src;
      }
    }
    return best ? absoluteHTTP(best) : null;
  }

  /** An http(s) URL, or null (data: and blob: covers are not passed on). */
  function absoluteHTTP(src, base) {
    try {
      const url = new URL(src, base || 'https://invalid.example/');
      if (url.hostname === 'invalid.example') return null;
      return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null;
    } catch (_) {
      return null;
    }
  }

  /** A YouTube video ID from an ID, a watch URL, a youtu.be or shorts link. */
  function youtubeVideoId(text) {
    const value = String(text || '').trim();
    const valid = (id) => (/^[A-Za-z0-9_-]{11}$/.test(id || '') ? id : null);
    if (valid(value)) return value;
    let url;
    try {
      url = new URL(value);
    } catch (_) {
      return null;
    }
    const host = url.hostname.toLowerCase();
    if (host === 'youtu.be') return valid(url.pathname.split('/')[1]);
    const site = siteForHost(host);
    if (site !== 'youtube' && site !== 'youtubeMusic') return null;
    const v = url.searchParams.get('v');
    if (v) return valid(v);
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts.length >= 2 && ['shorts', 'embed', 'live'].includes(parts[0])) return valid(parts[1]);
    return null;
  }

  /** A Spotify track ID from an ID, a URI, a /track/ link or ?highlight=. */
  function spotifyTrackId(text) {
    const value = String(text || '').trim();
    const valid = (id) => (/^[A-Za-z0-9]{22}$/.test(id || '') ? id : null);
    if (valid(value)) return value;
    let m = value.match(/spotify:track:([A-Za-z0-9]{22})/);
    if (m) return m[1];
    m = value.match(/\/track\/([A-Za-z0-9]{22})(?:[/?#]|$)/);
    if (m) return m[1];
    return null;
  }

  /** The numeric ID after `/<segment>/` in a path (Deezer, TIDAL tracks). */
  function idAfter(url, segment) {
    const m = String(url || '').match(new RegExp('/' + segment + '/(\\d+)(?:[/?#]|$)'));
    return m ? m[1] : null;
  }

  /** Lower case, no accents, the Turkish ı as i, punctuation as spaces. */
  function normalize(text) {
    return String(text || '')
      .normalize('NFKD')
      .replace(/[̀-ͯ]/g, '')
      .toLowerCase()
      .replace(/ı/g, 'i')
      .replace(/&/g, ' and ')
      .replace(/[^\p{L}\p{N}]+/gu, ' ')
      .trim();
  }

  /** The title without "(feat. …)", "[Remastered]", "- Radio Edit". */
  function coreTitle(title) {
    let text = String(title || '');
    text = text.replace(/\s*[([][^)\]]*[)\]]/g, '');
    text = text.replace(/\s+[-–—]\s+.*(remaster|edit|version|mix|live|mono|stereo|demo|acoustic|bonus).*$/i, '');
    text = text.replace(/\s+(feat\.?|ft\.?|featuring)\s+.*$/i, '');
    const core = normalize(text);
    return core || normalize(title);
  }

  /** A video's title often names its artist itself ("Artist - Song
   *  (Official Video)", or the other way round), under a channel with a
   *  name of its own. The song such a title names, when one of its halves
   *  holds the wanted artist as whole words; null otherwise. */
  function songOfVideoTitle(title, wantedArtist) {
    const artist = normalize(wantedArtist);
    const halves = String(title || '').match(/^(.+?)\s+[-–—]\s+(.+)$/);
    if (!artist || !halves) return null;
    const names = (half) => (' ' + normalize(half) + ' ').includes(' ' + artist + ' ');
    if (names(halves[1])) return { title: halves[2], artist: halves[1] };
    if (names(halves[2])) return { title: halves[1], artist: halves[2] };
    return null;
  }

  /** How well a search result matches the wanted song, 0…1. */
  function matchScore(wanted, candidate) {
    const plain = scoreAsWritten(wanted, candidate);
    const named = songOfVideoTitle(candidate.title, wanted.artist);
    // A little less than the artist's own upload of it would score.
    return named ? Math.max(plain, scoreAsWritten(wanted, Object.assign({}, candidate, named)) - 0.05) : plain;
  }

  function scoreAsWritten(wanted, candidate) {
    const wantedTitle = coreTitle(wanted.title);
    const title = coreTitle(candidate.title);
    if (!wantedTitle || !title) return 0;
    let score = 0;
    if (title === wantedTitle) score += 0.55;
    else if (title.includes(wantedTitle) || wantedTitle.includes(title)) score += 0.35;
    else {
      const a = new Set(wantedTitle.split(' '));
      const b = title.split(' ');
      const common = b.filter((w) => a.has(w)).length;
      score += 0.3 * (common / Math.max(a.size, b.length));
    }
    const wantedArtist = normalize(wanted.artist);
    const artist = normalize(candidate.artist);
    if (wantedArtist && artist) {
      if (artist === wantedArtist) score += 0.3;
      else if (artist.includes(wantedArtist) || wantedArtist.includes(artist)) score += 0.2;
    } else if (!wantedArtist) {
      score += 0.15;
    }
    const wantedAlbum = normalize(wanted.album);
    const album = normalize(candidate.album);
    if (wantedAlbum && album && (album === wantedAlbum || album.includes(wantedAlbum) || wantedAlbum.includes(album))) score += 0.05;
    if (wanted.duration > 0 && candidate.duration > 0) {
      const gap = Math.abs(wanted.duration - candidate.duration);
      score += gap <= 3 ? 0.1 : gap <= 10 ? 0.04 : -0.15;
    }
    return Math.max(0, Math.min(1, score));
  }

  /** The best candidate scoring at least `threshold`, or null. */
  function pickBest(wanted, candidates, threshold) {
    let best = null;
    let bestScore = threshold === undefined ? 0.5 : threshold;
    (candidates || []).forEach((candidate, index) => {
      // A small bonus for the site's own ranking.
      const score = matchScore(wanted, candidate) + Math.max(0, 0.02 - index * 0.004);
      if (score >= bestScore) {
        best = candidate;
        bestScore = score;
      }
    });
    return best;
  }

  /** "Song title" + "Artist" as a search query. */
  function searchQuery(song) {
    return [song.title, song.artist].map((s) => String(s || '').trim()).filter(Boolean).join(' ');
  }

  /** True when the page at `shown` is the one `wanted` names: the same
   *  site and path, with everything `wanted` asks for in its query (a site
   *  adds parameters of its own, and writes a space its own way). */
  function sameAddress(shown, wanted) {
    let a;
    let b;
    try {
      a = new URL(shown);
      b = new URL(wanted);
    } catch (_) {
      return false;
    }
    if (a.origin !== b.origin || a.pathname.replace(/\/+$/, '') !== b.pathname.replace(/\/+$/, '')) return false;
    for (const [name, value] of b.searchParams) if (a.searchParams.get(name) !== value) return false;
    return true;
  }

  /** What YouTube's own page is told to show `address` without loading a
   *  new page (the command a click on one of its links carries): a video, a
   *  search or a playlist of `site`. Null for any other address. */
  function youtubeEndpoint(site, address) {
    if (site !== 'youtube' && site !== 'youtubeMusic') return null;
    let url;
    try {
      url = new URL(address);
    } catch (_) {
      return null;
    }
    if (url.protocol !== 'https:' || siteForHost(url.hostname) !== site || url.hostname.toLowerCase() === 'youtu.be') return null;
    const music = site === 'youtubeMusic';
    const list = url.searchParams.get('list');
    const listOK = /^[A-Za-z0-9_-]{2,}$/.test(list || '');
    let endpoint = null;
    let page = null;
    if (url.pathname === '/watch') {
      const id = youtubeVideoId(url.searchParams.get('v'));
      if (!id || (list && !listOK)) return null;
      endpoint = { watchEndpoint: list ? { videoId: id, playlistId: list } : { videoId: id } };
      page = ['WEB_PAGE_TYPE_WATCH', 3832];
    } else if (url.pathname === (music ? '/search' : '/results')) {
      const query = String(url.searchParams.get(music ? 'q' : 'search_query') || '').trim();
      if (!query) return null;
      endpoint = { searchEndpoint: { query } };
      page = ['WEB_PAGE_TYPE_SEARCH', 4724];
    } else if (url.pathname === '/playlist' && listOK) {
      endpoint = { browseEndpoint: { browseId: 'VL' + list } };
      page = ['WEB_PAGE_TYPE_PLAYLIST', 5754];
    }
    if (!endpoint) return null;
    // youtube.com reads where to go from the command's own page data.
    if (!music) endpoint.commandMetadata = { webCommandMetadata: { url: url.pathname + url.search, webPageType: page[0], rootVe: page[1] } };
    return endpoint;
  }

  /** Where each site searches, plays a track and starts. */
  function siteURL(site, kind, value) {
    const q = encodeURIComponent(value || '');
    switch (site) {
      case 'youtubeMusic':
        if (kind === 'search') return 'https://music.youtube.com/search?q=' + q;
        if (kind === 'track') return 'https://music.youtube.com/watch?v=' + q;
        return 'https://music.youtube.com/';
      case 'youtube':
        if (kind === 'search') return 'https://www.youtube.com/results?search_query=' + q;
        if (kind === 'track') return 'https://www.youtube.com/watch?v=' + q;
        return 'https://www.youtube.com/';
      case 'spotify':
        if (kind === 'search') return 'https://open.spotify.com/search/' + q + '/tracks';
        if (kind === 'track') return 'https://open.spotify.com/track/' + q;
        return 'https://open.spotify.com/';
      case 'soundCloud':
        if (kind === 'search') return 'https://soundcloud.com/search/sounds?q=' + q;
        return 'https://soundcloud.com/';
      case 'amazonMusic':
        if (kind === 'search') return 'https://music.amazon.com/search/' + q + '?filter=IsLibrary%7Cfalse&sc=none';
        return 'https://music.amazon.com/';
      case 'deezer':
        if (kind === 'search') return 'https://www.deezer.com/search/' + q + '/track';
        if (kind === 'track') return 'https://www.deezer.com/track/' + q;
        return 'https://www.deezer.com/';
      case 'tidal':
        if (kind === 'search') return 'https://listen.tidal.com/search/tracks?q=' + q;
        if (kind === 'track') return 'https://listen.tidal.com/track/' + q;
        return 'https://listen.tidal.com/';
      default:
        return null;
    }
  }

  /** YouTube's signals that a video is music (category, channel, title). */
  function youtubeKind(info) {
    if (!info) return 'video';
    if (info.isAd) return 'advertisement';
    if (info.isLive && !info.category) return 'video';
    if (info.musicVideoType) {
      return /PODCAST/i.test(info.musicVideoType) ? 'podcast' : 'music';
    }
    if (info.category && /^music$/i.test(info.category)) return 'music';
    const author = String(info.author || '');
    if (/ - Topic$/.test(author) || /VEVO$/.test(author)) return 'music';
    const title = String(info.title || '').toLowerCase();
    const tags = ['official audio', 'official music video', 'official video', 'lyric video', '(lyrics)', '[lyrics]', '(audio)', 'visualizer'];
    return tags.some((tag) => title.includes(tag)) ? 'music' : 'video';
  }

  /**
   * What the song's video shows, in YouTube's own words (MUSIC_VIDEO_TYPE_OMV
   * an official video, _UGC an upload, _ATV the cover as a still): the page's
   * value when it names one, else an art track for a "- Topic" channel's
   * upload (those are always the cover). Ahenk's live wallpaper shows only
   * real videos.
   */
  function musicVideoType(info) {
    if (!info) return undefined;
    const named = typeof info.musicVideoType === 'string' ? info.musicVideoType.trim() : '';
    if (/^MUSIC_VIDEO_TYPE_[A-Z_]+$/.test(named)) return named;
    if (/ - Topic$/.test(String(info.author || ''))) return 'MUSIC_VIDEO_TYPE_ATV';
    return undefined;
  }

  /** YouTube channel names: "Artist - Topic" → "Artist", "ArtistVEVO" → "Artist". */
  function cleanYouTubeArtist(author) {
    const text = String(author || '').trim();
    if (/ - Topic$/.test(text)) return text.slice(0, -' - Topic'.length);
    if (/VEVO$/.test(text) && text.length > 4) return text.slice(0, -4);
    return text;
  }

  /** "Artist • Album • 2021" (YouTube Music's byline) → parts. */
  function splitByline(text) {
    return String(text || '')
      .split(/\s*[•·]\s*/)
      .map((part) => part.trim())
      .filter(Boolean);
  }

  /** A YouTube Music result's "[Type •] Artist • Album • 3:21": the type
   *  ("Song", "Video", in the site's language) leads only when there are
   *  three parts besides the length. */
  function ytMusicByline(text) {
    const parts = splitByline(text);
    let duration = null;
    if (parts.length && parseClock(parts[parts.length - 1]) !== null) duration = parseClock(parts.pop());
    if (parts.length >= 3) parts.shift();
    return { artist: parts[0] || '', album: parts[1] || '', duration };
  }

  /** Whether a new state is worth telling Ahenk (beyond the position moving on). */
  function noticeableChange(previous, next, now) {
    if (!previous) return true;
    const keys = ['title', 'artist', 'album', 'artwork', 'state', 'liked', 'shuffle', 'repeat', 'trackId', 'trackUrl', 'kind', 'musicVideoType', 'active', 'url'];
    for (const key of keys) if ((previous[key] ?? null) !== (next[key] ?? null)) return true;
    if (Math.abs((previous.duration || 0) - (next.duration || 0)) > 1) return true;
    if (Math.abs((previous.volume ?? -1) - (next.volume ?? -1)) > 0.02) return true;
    if (Math.abs((previous.rate || 1) - (next.rate || 1)) > 0.01) return true;
    if ((previous.can || []).join(',') !== (next.can || []).join(',')) return true;
    // A seek: the position is not where playback would have taken it.
    if (typeof next.position === 'number' && typeof previous.position === 'number') {
      const elapsed = previous.state === 'playing' ? ((now || next.sampledAt) - previous.sampledAt) / 1000 * (previous.rate || 1) : 0;
      if (Math.abs(previous.position + elapsed - next.position) > 1.5) return true;
    } else if ((typeof next.position === 'number') !== (typeof previous.position === 'number')) {
      return true;
    }
    return false;
  }

  /** A playback rate a tab may be given: 0.25…4; anything else is the song's own speed. */
  function playbackRate(value) {
    const rate = Number(value);
    if (value === null || value === undefined || !Number.isFinite(rate) || rate <= 0) return 1;
    return Math.min(4, Math.max(0.25, Math.round(rate * 100) / 100));
  }

  /**
   * The rate to give a media element so it plays at the rate Ahenk asked
   * for, or null to leave it alone (Ahenk asked for nothing, or it already
   * plays at that rate). Sites put the rate back to 1 with every new song.
   */
  function rateCorrection(wanted, current) {
    if (wanted === null || wanted === undefined) return null;
    const target = playbackRate(wanted);
    if (!Number.isFinite(current)) return target;
    return Math.abs(current - target) > 0.005 ? target : null;
  }

  /**
   * Where a song falls in its music video, from YouTube Music's own answer
   * about the video (`/next`): the site keeps, for a listener who may
   * switch between a song and its video, the stretches the two share
   * ("the video from 41.0 s is the song from 0.6 s, for 186 s"). Null when
   * the answer does not pair `videoId` with a song (no video of its own,
   * or a listener the site does not offer the switch to).
   */
  function clipSegments(response, videoId) {
    const clock = (text) => {
      const parts = String(text || '').trim().split(':').map(Number);
      if (parts.length < 2 || parts.length > 3 || parts.some((part) => !Number.isFinite(part) || part < 0)) return undefined;
      return parts.reduce((total, part) => total * 60 + part, 0);
    };
    const seconds = (value) => {
      const number = Number(value);
      return Number.isFinite(number) && number >= 0 ? number / 1000 : null;
    };
    let found = null;
    let visited = 0;
    (function walk(node) {
      if (found || !node || typeof node !== 'object' || (visited += 1) > 200000) return;
      const wrapper = node.playlistPanelVideoWrapperRenderer;
      if (wrapper && typeof wrapper === 'object') {
        const primary = wrapper.primaryRenderer && wrapper.primaryRenderer.playlistPanelVideoRenderer;
        const pair = Array.isArray(wrapper.counterpart) ? wrapper.counterpart[0] : null;
        const other = pair && pair.counterpartRenderer && pair.counterpartRenderer.playlistPanelVideoRenderer;
        const listed = pair && pair.segmentMap && Array.isArray(pair.segmentMap.segment) ? pair.segmentMap.segment : null;
        if (primary && other && listed && primary.videoId === videoId && youtubeVideoId(other.videoId) === other.videoId) {
          const segments = listed
            .map((segment) => ({
              video: seconds(segment.primaryVideoStartTimeMilliseconds),
              song: seconds(segment.counterpartVideoStartTimeMilliseconds),
              duration: seconds(segment.durationMilliseconds),
            }))
            .filter((segment) => segment.video !== null && segment.song !== null && segment.duration > 0)
            .slice(0, 64);
          const length = other.lengthText && Array.isArray(other.lengthText.runs) && other.lengthText.runs[0] ? clock(other.lengthText.runs[0].text) : undefined;
          if (segments.length) found = { videoId, songId: other.videoId, songSeconds: length, segments };
          return;
        }
      }
      if (Array.isArray(node)) for (const child of node) walk(child);
      else for (const key of Object.keys(node)) walk(node[key]);
    })(response);
    return found;
  }

  /** "1.5", "1.5.0" or "v1.10.3" as three numbers; null for anything else. */
  function parseVersion(text) {
    const parts = String(text ?? '').trim().replace(/^v/, '').split('.');
    if (parts.length < 1 || parts.length > 3 || !parts.every((part) => /^\d{1,9}$/.test(part))) return null;
    const numbers = parts.map(Number);
    while (numbers.length < 3) numbers.push(0);
    return numbers;
  }

  /** True when version `a` is newer than `b`; false when either is unreadable. */
  function versionNewer(a, b) {
    const first = parseVersion(a);
    const second = parseVersion(b);
    if (!first || !second) return false;
    for (let i = 0; i < 3; i += 1) if (first[i] !== second[i]) return first[i] > second[i];
    return false;
  }

  /**
   * Whether an extension of version `own` takes itself up again on hearing
   * that Ahenk carries `shipped`: when that is newer, and once per version
   * (`triedFor` is the version it last did so for; a browser that keeps a
   * copy of its own comes back as old as before).
   */
  function takesUpNewer(shipped, own, triedFor) {
    return versionNewer(shipped, own) && String(shipped) !== String(triedFor ?? '');
  }

  /** Seconds to wait before reconnect attempt `n` (0-based). */
  function backoff(attempt) {
    const steps = [1, 2, 4, 8, 15, 30];
    return steps[Math.min(Math.max(0, attempt), steps.length - 1)];
  }

  /** The repeat mode a button shows, from attributes that do not depend on the UI language. */
  function repeatFromState(value) {
    const text = String(value ?? '').toLowerCase();
    if (['none', 'off', 'false', 'repeat_off', 'repeat-off', '0'].includes(text)) return 'off';
    if (['all', 'true', 'repeat_all', 'repeat-all', 'context', 'list', '1'].includes(text)) return 'all';
    if (['one', 'mixed', 'repeat_one', 'repeat-one', 'track', 'single', '2'].includes(text)) return 'one';
    return null;
  }

  /** "true"/"false" attributes as booleans, anything else null. */
  function boolAttr(value) {
    if (value === true || value === 'true') return true;
    if (value === false || value === 'false') return false;
    return null;
  }

  const api = {
    SITES,
    siteForHost,
    siteForURL,
    parseClock,
    clockPair,
    bestArtwork,
    absoluteHTTP,
    youtubeVideoId,
    spotifyTrackId,
    idAfter,
    normalize,
    coreTitle,
    matchScore,
    pickBest,
    searchQuery,
    siteURL,
    sameAddress,
    youtubeEndpoint,
    youtubeKind,
    musicVideoType,
    cleanYouTubeArtist,
    splitByline,
    ytMusicByline,
    noticeableChange,
    playbackRate,
    rateCorrection,
    clipSegments,
    parseVersion,
    versionNewer,
    takesUpNewer,
    backoff,
    repeatFromState,
    boolAttr,
  };
  // The newest scripts win: an updated extension puts its own over the
  // ones a page still holds (a page from before 1.5.0 keeps its own
  // until it loads again).
  try {
    Object.defineProperty(root, 'AhenkCommon', { value: Object.freeze(api), configurable: true, enumerable: false });
  } catch (_) {
    // Held by scripts that cannot be replaced.
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
