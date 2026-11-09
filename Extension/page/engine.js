// Ahenk browser bridge, page world: reads what the tab plays (the site's
// Media Session data, its media elements and the site profile in
// page/sites.js), reports changes to the extension, and carries out
// Ahenk's commands and requests. Talks to content/relay.js through
// window.postMessage; never to the network.
(function () {
  'use strict';
  if (window.__ahenkEngine || !window.__ahenkHooks || !window.__ahenkSites || !window.AhenkCommon) return;
  const C = window.AhenkCommon;
  const L = window.AhenkLyrics;
  const hooks = window.__ahenkHooks;
  const profile = window.__ahenkSites.forHost(location.hostname);
  if (!profile) return;
  const { $, until, wait } = window.__ahenkSites.helpers;
  const site = profile.id;

  // MARK: Messages to the extension

  function post(message) {
    window.postMessage({ __ahenk: 'page', message }, location.origin);
  }

  // MARK: Reading

  function sessionMetadata() {
    const metadata = navigator.mediaSession && navigator.mediaSession.metadata;
    if (!metadata || !metadata.title) return null;
    return {
      title: String(metadata.title || ''),
      artist: String(metadata.artist || ''),
      album: String(metadata.album || ''),
      artwork: C.bestArtwork(metadata.artwork),
    };
  }

  function mediaElements() {
    const known = hooks.state.media.slice();
    for (const element of document.querySelectorAll('video, audio')) if (!known.includes(element)) known.unshift(element);
    return known.filter((element) => element.isConnected || hooks.state.media.includes(element));
  }

  /** The element that plays (or played last). */
  function activeElement() {
    const elements = mediaElements();
    const playing = elements.filter((element) => !element.paused && !element.ended && element.readyState > 0);
    if (playing.length) return playing[playing.length - 1];
    const used = hooks.state.media.slice().reverse().find((element) => element.currentSrc || element.src);
    return used || null;
  }

  function call(fn, fallback) {
    try {
      const value = fn();
      return value === undefined ? fallback : value;
    } catch (_) {
      return fallback;
    }
  }

  function has(handler) {
    return hooks.state.handlers.has(handler);
  }

  function control(name) {
    const selectors = profile.buttons && profile.buttons[name];
    return selectors ? $(selectors) : null;
  }

  function read() {
    const now = Date.now();
    const session = sessionMetadata();
    const own = profile.meta ? call(() => profile.meta(), null) : null;
    const meta = session || own;
    if (!meta || !meta.title) return null;
    if (session && own) {
      meta.artist = meta.artist || own.artist;
      meta.album = meta.album || own.album;
    }
    if (!meta.artwork && own && own.artwork) meta.artwork = own.artwork;

    const element = activeElement();
    const timing = profile.timing ? call(() => profile.timing(), null) : null;
    const sessionState = navigator.mediaSession ? navigator.mediaSession.playbackState : 'none';
    const positionState = hooks.state.position;
    const isYouTube = site === 'youtube' || site === 'youtubeMusic';
    let position;
    let duration;
    let rate = 1;
    // Whether it plays: the media element knows best, then the site's own
    // report to the system, then the site's controls.
    let playing;
    if (element && element.readyState > 0) playing = !element.paused && !element.ended;
    else if (sessionState === 'playing' || sessionState === 'paused') playing = sessionState === 'playing';
    else playing = !!(timing && timing.playing);
    // Where it is: YouTube's player API; else the site's setPositionState()
    // for this song; else the element when it holds just this song; else
    // the site's time display.
    if (isYouTube && timing && timing.known && Number.isFinite(timing.position)) {
      position = timing.position;
      duration = timing.duration;
      playing = !!timing.playing;
    } else if (positionState && positionState.duration > 0 && hooks.state.positionAt >= hooks.state.metadataAt - 1000) {
      const elapsed = playing ? ((now - hooks.state.positionAt) / 1000) * (positionState.playbackRate || 1) : 0;
      position = Math.min(positionState.duration, positionState.position + elapsed);
      duration = positionState.duration;
      rate = positionState.playbackRate || 1;
    } else if (element && Number.isFinite(element.duration) && element.duration > 0
      && (!timing || !timing.duration || Math.abs(element.duration - timing.duration) < 2.5)) {
      position = element.currentTime;
      duration = element.duration;
      rate = element.playbackRate || 1;
    } else if (timing && Number.isFinite(timing.position)) {
      position = timing.position;
      duration = timing.duration;
    }
    if (duration === undefined && timing && timing.duration) duration = timing.duration;

    const can = [];
    if (has('play') || has('pause') || (profile.api && profile.api.play) || control('playPause') || element) can.push('playPause');
    if (has('nexttrack') || control('next') || (profile.api && profile.api.next)) can.push('next');
    if (has('previoustrack') || control('previous') || (profile.api && profile.api.previous)) can.push('previous');
    if (has('seekto') || (profile.api && profile.api.seek) || (element && Number.isFinite(element.duration))) can.push('seek');
    const liked = profile.liked ? call(() => profile.liked(), null) : null;
    const shuffle = profile.shuffle ? call(() => profile.shuffle(), null) : null;
    const repeat = profile.repeat ? call(() => profile.repeat(), null) : null;
    if (shuffle !== null) can.push('shuffle');
    if (repeat !== null) {
      can.push('repeat');
      if ((profile.repeatModes || []).includes('one')) can.push('repeatOne');
    }
    if (liked !== null) can.push('like', 'unlike');
    if (profile.search) can.push('search');
    if (profile.playlists) can.push('playlists');
    if (profile.queue) {
      can.push('queue');
      if (profile.queue.remove) can.push('queueEdit');
    }
    const volume = readVolume(element);
    if (volume !== null) can.push('volume');

    return {
      site,
      url: location.href,
      title: meta.title,
      artist: meta.artist,
      album: meta.album,
      artwork: meta.artwork || undefined,
      duration: Number.isFinite(duration) && duration > 0 ? duration : undefined,
      position: Number.isFinite(position) ? Math.max(0, position) : undefined,
      sampledAt: now,
      rate: playing ? rate : 0,
      state: playing ? 'playing' : 'paused',
      liked: liked === null ? undefined : liked,
      shuffle: shuffle === null ? undefined : shuffle,
      repeat: repeat === null ? undefined : repeat,
      trackId: (profile.trackId && call(() => profile.trackId(), null)) || undefined,
      trackUrl: (profile.trackUrl && call(() => profile.trackUrl(), null)) || undefined,
      kind: profile.kind ? call(() => profile.kind(meta), 'music') : 'music',
      musicVideoType: (profile.musicVideoType && call(() => profile.musicVideoType(), null)) || undefined,
      can,
      volume: volume === null ? undefined : volume,
    };
  }

  function readVolume(element) {
    if (profile.api && profile.api.volume) {
      const value = call(() => profile.api.volume(), null);
      if (value !== null) return value;
    }
    if (profile.volume) {
      const value = call(() => profile.volume(), null);
      if (value !== null) return value;
    }
    return null;
  }

  // MARK: Reporting

  let last = null;
  let lastSentAt = 0;
  let reported = false;
  let timer = null;

  function report(force) {
    const state = read();
    const now = Date.now();
    if (!state) {
      if (reported) post({ kind: 'gone' });
      reported = false;
      last = null;
      return;
    }
    const due = state.state === 'playing' && now - lastSentAt > 30000;
    if (force || !reported || due || C.noticeableChange(last, state, now)) {
      post({ kind: 'state', state });
      last = state;
      lastSentAt = now;
      reported = true;
    }
  }

  function schedule() {
    clearTimeout(timer);
    const playing = last && last.state === 'playing';
    timer = setTimeout(() => {
      report(false);
      schedule();
    }, playing ? 1000 : document.hidden ? 5000 : 2000);
  }

  let pending = false;
  hooks.subscribe(() => {
    if (pending) return;
    pending = true;
    setTimeout(() => {
      pending = false;
      report(false);
    }, 120);
  });
  document.addEventListener('visibilitychange', () => schedule());

  // MARK: Lyrics the site loads for itself

  hooks.state.onJSON = {
    wants: (url) => L.wants(site, url),
    deliver(url, json) {
      const found = L.extract(site, url, json);
      // What plays right now (the last report may still name the song
      // before: a site loads the new song's lyrics as soon as it changes).
      const current = read() || last;
      if (!found || !current) return;
      if (found.trackId && current.trackId && String(found.trackId) !== String(current.trackId)) return;
      const lastLine = found.lines[found.lines.length - 1];
      if (current.duration && lastLine && lastLine.start > current.duration + 2) return;
      post({
        kind: 'lyrics',
        song: { title: current.title, artist: current.artist, album: current.album, duration: current.duration, trackId: current.trackId },
        lines: found.lines,
      });
    },
  };

  // MARK: Commands

  function invoke(action, details) {
    const handler = hooks.state.handlers.get(action);
    if (!handler) return false;
    try {
      handler(Object.assign({ action }, details || {}));
      return true;
    } catch (_) {
      return false;
    }
  }

  async function setPlaying(on) {
    const now = read();
    if (now && (now.state === 'playing') === on) return true;
    if (invoke(on ? 'play' : 'pause')) return true;
    if (profile.api && (on ? profile.api.play : profile.api.pause) && call(() => (on ? profile.api.play() : profile.api.pause()), false)) return true;
    const specific = control(on ? 'play' : 'pause');
    if (specific && (specific.click(), true)) return true;
    const toggle = control('playPause');
    if (toggle) {
      toggle.click();
      return true;
    }
    const element = activeElement();
    if (!element) return false;
    try {
      if (on) await element.play();
      else element.pause();
      return true;
    } catch (_) {
      return false;
    }
  }

  function skip(forward) {
    if (invoke(forward ? 'nexttrack' : 'previoustrack')) return true;
    const button = control(forward ? 'next' : 'previous');
    if (button) {
      button.click();
      return true;
    }
    const api = profile.api && (forward ? profile.api.next : profile.api.previous);
    return api ? call(api, false) : false;
  }

  function seek(seconds) {
    if (!Number.isFinite(seconds)) return false;
    const target = Math.max(0, seconds);
    if (invoke('seekto', { seekTime: target, fastSeek: false })) return true;
    if (profile.api && profile.api.seek && call(() => profile.api.seek(target), false)) return true;
    const element = activeElement();
    if (element && Number.isFinite(element.duration)) {
      element.currentTime = Math.min(target, element.duration);
      return true;
    }
    return false;
  }

  async function setVolume(value) {
    const volume = Math.max(0, Math.min(1, Number(value)));
    if (!Number.isFinite(volume)) return false;
    if (profile.api && profile.api.setVolume && call(() => profile.api.setVolume(volume), false)) return true;
    if (profile.setVolume && (await profile.setVolume(volume))) return true;
    const element = activeElement();
    if (!element) return false;
    element.volume = volume;
    return true;
  }

  async function runCommand(message) {
    switch (message.command) {
      case 'play':
        return setPlaying(true);
      case 'pause':
        return setPlaying(false);
      case 'toggle': {
        const now = read();
        return setPlaying(!(now && now.state === 'playing'));
      }
      case 'next':
        return skip(true);
      case 'previous':
        return skip(false);
      case 'seek':
        return seek(Number(message.position));
      case 'shuffle':
        return profile.setShuffle ? !!(await profile.setShuffle(!!message.on)) : false;
      case 'repeat':
        return profile.setRepeat ? !!(await profile.setRepeat(String(message.mode || 'off'))) : false;
      case 'like':
        return profile.setLiked ? !!(await profile.setLiked(!!message.on)) : false;
      case 'volume':
        return setVolume(message.volume);
      default:
        return false;
    }
  }

  // MARK: Requests

  /** True once the tab plays something that matches `song`. */
  function playsSong(song) {
    const now = read();
    if (!now) return false;
    if (song.trackId && now.trackId && String(song.trackId) === String(now.trackId)) return true;
    return C.matchScore(song, now) >= 0.5;
  }

  async function confirmStarted(song) {
    const matched = await until(() => playsSong(song), 10000, 250);
    if (!matched) return { ok: false, outcome: 'failed', error: 'another song plays' };
    let playing = await until(() => (read() || {}).state === 'playing', 2500, 200);
    if (!playing) {
      await setPlaying(true);
      playing = await until(() => (read() || {}).state === 'playing', 2500, 200);
    }
    return playing ? { ok: true, outcome: 'started' } : { ok: true, outcome: 'opened' };
  }

  function rowSong(row) {
    const trackUrl = row.url || (row.trackId ? C.siteURL(site, 'track', row.trackId) : undefined);
    return { title: row.title, artist: row.artist || '', album: row.album || undefined, duration: row.duration || undefined, trackId: row.trackId || undefined, url: trackUrl || undefined, artwork: row.artwork || undefined };
  }

  async function playSong(job) {
    const song = job.song || {};
    if (!song.title) return { ok: false, outcome: 'failed', error: 'no song' };
    if (playsSong(song) && (read() || {}).state === 'playing') return { ok: true, outcome: 'started' };
    const phase = job.phase || 1;
    const direct = profile.playByID ? call(() => profile.playByID(song), null) : null;
    if (direct) {
      if (location.href.split('?')[0] !== direct.split('?')[0]) {
        if (phase > 2) return { ok: false, outcome: 'failed', error: 'the track page did not open' };
        return { navigate: direct };
      }
      // The song's own page: wait for its play button, then press it.
      if (profile.trackPageButton) await until(() => profile.trackPageButton(), 8000);
      if (profile.trackPagePlay) profile.trackPagePlay();
      return confirmStarted(song);
    }
    if (!profile.search) return { ok: false, outcome: 'failed', error: 'the site cannot search' };
    const expected = C.siteURL(site, 'search', C.searchQuery(song));
    if (phase === 1 && location.href !== expected) return { navigate: expected };
    const results = await until(() => profile.search.results(), 10000, 300);
    const best = C.pickBest(song, results || [], 0.5);
    if (!best) return { ok: false, outcome: 'notFound' };
    best.play();
    return confirmStarted(Object.assign({}, song, { trackId: best.trackId || song.trackId }));
  }

  async function openPlaylist(job) {
    const lists = profile.playlists;
    if (lists.isOpen && lists.isOpen(job.playlistId)) return true;
    const link = lists.link ? lists.link(job.playlistId) : null;
    if (!link) return false;
    link.click();
    return !!(await until(() => lists.isOpen(job.playlistId) && lists.rows().length > 0, 8000, 250));
  }

  async function runRequest(job) {
    switch (job.request) {
      case 'play':
        return playSong(job);
      case 'playlists': {
        if (!profile.playlists) return { ok: false, error: 'no playlists here' };
        const lists = (await until(() => profile.playlists.read(), 2500, 250)) || [];
        return { ok: true, playlists: lists };
      }
      case 'playlistSongs': {
        if (!profile.playlists) return { ok: false, error: 'no playlists here' };
        if (!(await openPlaylist(job))) return { ok: false, error: 'the playlist is not reachable from this page' };
        return { ok: true, songs: profile.playlists.rows().slice(0, 200).map(rowSong) };
      }
      case 'playPlaylist': {
        if (!profile.playlists) return { ok: false, outcome: 'failed', error: 'no playlists here' };
        if (!(await openPlaylist(job))) {
          const phase = job.phase || 1;
          if (job.playlistUrl && phase === 1) return { navigate: job.playlistUrl };
          if (!(await until(() => profile.playlists.rows().length > 0, 8000))) return { ok: false, outcome: 'notFound' };
        }
        const rows = profile.playlists.rows();
        const row = Number.isInteger(job.index) ? rows[job.index] : null;
        if (row) row.play();
        else if (!profile.playlists.playAll()) return { ok: false, outcome: 'failed', error: 'no play button' };
        const started = await until(() => (read() || {}).state === 'playing', 8000, 250);
        return started ? { ok: true, outcome: 'started' } : { ok: true, outcome: 'opened' };
      }
      case 'queue': {
        if (!profile.queue) return { ok: false, error: 'no queue here' };
        const items = profile.queue.read().slice(0, 200);
        return { ok: true, queue: items.map((item) => ({ index: item.index, current: !!item.current, song: rowSong(item) })) };
      }
      case 'playQueueItem':
        return { ok: !!(profile.queue && Number.isInteger(job.index) && (await profile.queue.play(job.index))) };
      case 'removeQueueItem':
        return { ok: !!(profile.queue && profile.queue.remove && Number.isInteger(job.index) && (await profile.queue.remove(job.index))) };
      case 'volume': {
        const volume = readVolume(activeElement());
        return volume === null ? { ok: false } : { ok: true, volume };
      }
      case 'setVolume':
        return { ok: await setVolume(job.volume) };
      default:
        return { ok: false, error: 'unknown request' };
    }
  }

  // MARK: Messages from the extension

  window.addEventListener('message', (event) => {
    if (event.source !== window || !event.data || event.data.__ahenk !== 'ext') return;
    const message = event.data.message || {};
    if (message.kind === 'resync') {
      post({ kind: 'ready', site });
      report(true);
      return;
    }
    if (message.kind === 'command') {
      Promise.resolve(runCommand(message))
        .catch(() => false)
        .then((ok) => {
          post({ kind: 'result', id: message.id, ok: !!ok });
          setTimeout(() => report(false), 150);
        });
      return;
    }
    if (message.kind === 'job') {
      Promise.resolve(runRequest(message.job || {}))
        .catch((error) => ({ ok: false, outcome: 'failed', error: String((error && error.message) || error) }))
        .then((answer) => {
          if (answer && answer.navigate) {
            post({ kind: 'navigating', id: message.id });
            setTimeout(() => location.assign(answer.navigate), 50);
            return;
          }
          post(Object.assign({ kind: 'result', id: message.id }, answer));
          setTimeout(() => report(false), 150);
        });
    }
  });

  Object.defineProperty(window, '__ahenkEngine', { value: true, enumerable: false });
  post({ kind: 'ready', site });
  report(true);
  schedule();
})();
