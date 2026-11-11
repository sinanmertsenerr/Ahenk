// Ahenk browser bridge, page world: reads what the tab plays (the site's
// Media Session data, its media elements and the site profile in
// page/sites.js), reports changes to the extension, and carries out
// Ahenk's commands and requests. Talks to content/relay.js through
// window.postMessage; never to the network.
//
// An updated extension puts its scripts into the pages that are open (see
// background.js): the engine that ran here steps down (`retire`) and this
// one goes on with the page's hooks, so a tab that plays needs no reload.
(function () {
  'use strict';
  const before = window.__ahenkEngine;
  // An engine from before 1.5.0 cannot step down: the page keeps its
  // scripts until it loads again.
  if (before === true || !window.__ahenkHooks || !window.__ahenkSites || !window.AhenkCommon) return;
  if (before && typeof before.retire === 'function') {
    try {
      before.retire();
    } catch (_) {
      // It is gone either way: its messages are no longer answered.
    }
  }
  const C = window.AhenkCommon;
  const L = window.AhenkLyrics;
  const S = window.AhenkSound;
  const hooks = window.__ahenkHooks;
  const profile = window.__ahenkSites.forHost(location.hostname);
  if (!profile) return;
  const { $, until, wait } = window.__ahenkSites.helpers;
  const site = profile.id;

  // The speed Ahenk asked this tab to play at (its sound effects); null
  // when it asked for none, and the tab's own speed is left alone.
  let wantedRate = null;

  // MARK: Messages to the extension

  /** True once a newer engine took this page over. */
  let retired = false;

  function post(message) {
    if (retired) return;
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
    if (element) {
      // The site starts every song at its own speed again: put Ahenk's back.
      const correction = C.rateCorrection(wantedRate, element.playbackRate);
      if (correction !== null) call(() => { element.playbackRate = correction; }, null);
      // Whatever told the position, the element knows how fast it moves.
      const actual = element.playbackRate;
      if (rate === 1 && Number.isFinite(actual) && actual > 0) rate = actual;
    }

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
    if (element) can.push('rate');
    if (heldSound(element)) can.push('sound');
    if (profile.clip && profile.network && call(() => profile.network(), null)) can.push('clip');

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
    if (retired) return;
    const state = read();
    const now = Date.now();
    if (!state) {
      if (reported) post({ kind: 'gone' });
      reported = false;
      last = null;
      return;
    }
    captions(state);
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
    if (retired) return;
    const playing = last && last.state === 'playing';
    timer = setTimeout(() => {
      report(false);
      schedule();
    }, playing ? 1000 : document.hidden ? 5000 : 2000);
  }

  let pending = false;
  const unsubscribe = hooks.subscribe(() => {
    if (pending) return;
    pending = true;
    setTimeout(() => {
      pending = false;
      report(false);
    }, 120);
  });
  const onVisibility = () => schedule();
  document.addEventListener('visibilitychange', onVisibility);

  // MARK: Lyrics the site loads for itself

  const onJSON = {
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
  hooks.state.onJSON = onJSON;

  // MARK: A video's own captions as lyrics

  // YouTube and YouTube Music: a music video often carries captions its
  // uploader wrote, timed for this very video (the lyrics catalogs time
  // the album's recording, which a video with an intro runs ahead of).
  // Asked once per video, from the player's own data; nothing is clicked.
  let captionsFor = null;

  function captions(state) {
    if (site !== 'youtubeMusic' && site !== 'youtube') return;
    if (!state || !state.trackId || state.kind !== 'music' || captionsFor === state.trackId) return;
    const player = document.getElementById('movie_player');
    const response = player && typeof player.getPlayerResponse === 'function' ? call(() => player.getPlayerResponse(), null) : null;
    // The player still shows the video before: the next report asks again.
    if (!response || !response.videoDetails || response.videoDetails.videoId !== state.trackId) return;
    captionsFor = state.trackId;
    const list = response.captions && response.captions.playerCaptionsTracklistRenderer && response.captions.playerCaptionsTracklistRenderer.captionTracks;
    // Captions somebody wrote are the lyrics; automatic ones only say
    // when each word is sung (Ahenk times the real lyrics with them).
    const written = L.pickCaptionTrack(list, navigator.language);
    const track = written || L.pickHeardTrack(list);
    if (!track) return;
    const heard = !written;
    const asked = state.trackId;
    fetch(track.baseUrl + (track.baseUrl.indexOf('?') === -1 ? '?' : '&') + 'fmt=json3', { credentials: 'include' })
      .then((answer) => (answer.ok ? answer.json() : null))
      .then((json) => {
        const lines = json && (heard ? L.fromYouTubeAutoCaptions(json) : L.fromYouTubeCaptions(json));
        const current = read() || last;
        if (!lines || !current || current.trackId !== asked) return;
        const lastLine = lines[lines.length - 1];
        if (current.duration && lastLine && lastLine.start > current.duration + 2) return;
        post({
          kind: 'lyrics',
          heard: heard || undefined,
          song: { title: current.title, artist: current.artist, album: current.album, duration: current.duration, trackId: current.trackId },
          lines,
        });
      })
      .catch(() => {});
  }

  // MARK: The sound the player holds ahead

  /** The audio stream the tab's player was handed for what it plays (see
   *  page/hooks.js), or null: another site, a page that loaded before the
   *  extension, a stream whose beginning is not known. */
  function heldSound(element) {
    if (!S || !hooks.sound || (site !== 'youtubeMusic' && site !== 'youtube')) return null;
    return call(() => hooks.sound.held(element), null);
  }

  /** The stream as 16 kHz mono samples from its `start`. Decoded by the
   *  browser, and again only once more of it arrived. */
  async function heldSamples(held) {
    const known = held.decoded;
    if (known && known.run === held.run && known.bytes === held.bytes) return known.samples;
    const run = held.run;
    const bytes = held.bytes;
    const context = new OfflineAudioContext({ numberOfChannels: 1, length: 1, sampleRate: S.RATE });
    const buffer = await context.decodeAudioData(S.stream(held).buffer);
    const channels = [];
    for (let i = 0; i < buffer.numberOfChannels; i += 1) channels.push(buffer.getChannelData(i));
    const samples = S.mono(channels);
    held.decoded = { run, bytes, samples };
    return samples;
  }

  /** `job.seconds` of the playing video's sound from `job.from` (seconds
   *  of the video), or from where the held stream begins. Without
   *  `samples` in the answer the player does not hold that much yet. */
  async function readSound(job) {
    const now = read();
    const wanted = job.song && job.song.trackId;
    if (!now || (wanted && String(wanted) !== String(now.trackId || ''))) return { ok: false, error: 'another song plays' };
    const element = activeElement();
    const held = heldSound(element);
    if (!held) return { ok: false, error: 'no sound is held here' };
    // An advertisement plays through the same player.
    if (now.kind === 'advertisement' || $('.html5-video-player.ad-showing')) return { ok: true, sound: {} };
    const seconds = Math.max(1, Math.min(15, Number(job.seconds) || 10));
    const from = Math.max(Number(job.from) || 0, held.start);
    const sound = { from: held.start, until: held.until };
    if (held.until < from + seconds - 0.05) return { ok: true, sound };
    const run = held.run;
    const samples = await heldSamples(held);
    // A seek while it was decoded: what was read is of another stretch.
    if (held.run !== run) return { ok: true, sound: {} };
    const piece = S.cut(held.start, samples, from, seconds);
    if (!piece) return { ok: true, sound };
    return { ok: true, sound: Object.assign(sound, { start: piece.start, rate: S.RATE, samples: S.pcm16(piece.samples) }) };
  }

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

  /** Plays at `value` times the song's speed; 1 gives the tab its own speed back. */
  function setRate(value) {
    const rate = C.playbackRate(value);
    const element = activeElement();
    if (!element) return false;
    // Keep it over song changes, until Ahenk asks for the song's own speed.
    wantedRate = rate === 1 ? null : rate;
    element.playbackRate = rate;
    schedule();
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
      case 'rate':
        return setRate(message.rate);
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

  /** Shows `url` in this page, without loading a new one, where the site
   *  can (`profile.show`): what plays goes on, the site has nothing to ask
   *  before leaving, and the browser lets the next song start by itself (a
   *  newly loaded page may play only after a click in it). True once the
   *  page is at that address. */
  async function showInPage(url) {
    if (!profile.show || !url || !call(() => profile.show(url), false)) return false;
    return !!(await until(() => C.sameAddress(location.href, url), 3000, 100));
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
    // The site's own page opens the song it knows by ID, in place.
    let waited = false;
    if (phase === 1 && song.trackId && profile.show && (await showInPage(C.siteURL(site, 'track', song.trackId)))) {
      waited = true;
      const answer = await confirmStarted(song);
      if (answer.ok) return answer;
      // An advertisement first: the song follows it. Anything else (the
      // video is gone, or not for this listener): the site's search.
      if ((read() || {}).kind === 'advertisement') return { ok: true, outcome: 'opened' };
    }
    // The page already shows that very song (a tab opened on it, or a pick
    // repeated while it loads): it only has to start.
    if (!waited && song.trackId && profile.trackId && String(call(() => profile.trackId(), '') || '') === String(song.trackId)) {
      const answer = await confirmStarted(song);
      if (answer.ok || phase > 1) return answer;
    }
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
    let best = null;
    if (phase === 1 && !C.sameAddress(location.href, expected)) {
      if (!(await showInPage(expected))) return { navigate: expected };
      // The page before may have been a search too: its rows stay until
      // the new ones arrive, so only a row that matches is waited for.
      best = await until(() => C.pickBest(song, profile.search.results() || [], 0.5), 10000, 300);
    } else {
      const results = await until(() => profile.search.results(), 10000, 300);
      best = C.pickBest(song, results || [], 0.5);
    }
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
          const lists = profile.playlists;
          // In place: the rows of a list shown before do not count.
          const inPlace = !!job.playlistUrl && phase === 1 && (await showInPage(job.playlistUrl));
          if (job.playlistUrl && phase === 1 && !inPlace) return { navigate: job.playlistUrl };
          if (!(await until(() => (!inPlace || !lists.isOpen || lists.isOpen(job.playlistId)) && lists.rows().length > 0, 8000))) return { ok: false, outcome: 'notFound' };
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
      case 'sound':
        return readSound(job);
      case 'clip': {
        if (!profile.clip) return { ok: false, error: 'the site pairs no songs with videos' };
        const clip = await profile.clip(String(job.videoId || ''));
        return clip ? { ok: true, clip } : { ok: false, outcome: 'notFound' };
      }
      default:
        return { ok: false, error: 'unknown request' };
    }
  }

  // MARK: Messages from the extension

  function onMessage(event) {
    if (retired || event.source !== window || !event.data || event.data.__ahenk !== 'ext') return;
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
          if (retired) return;
          post({ kind: 'result', id: message.id, ok: !!ok });
          setTimeout(() => report(false), 150);
        });
      return;
    }
    if (message.kind === 'job') {
      Promise.resolve(runRequest(message.job || {}))
        .catch((error) => ({ ok: false, outcome: 'failed', error: String((error && error.message) || error) }))
        .then((answer) => {
          // A newer engine took the page over meanwhile: this answer is
          // nobody's, and no page is loaded for it.
          if (retired) return;
          if (answer && answer.navigate) {
            post({ kind: 'navigating', id: message.id });
            setTimeout(() => {
              // Ahenk's user picked this: the site does not ask about it.
              if (hooks.leaveQuietly) hooks.leaveQuietly();
              location.assign(answer.navigate);
            }, 50);
            return;
          }
          post(Object.assign({ kind: 'result', id: message.id }, answer));
          setTimeout(() => report(false), 150);
        });
    }
  }
  window.addEventListener('message', onMessage);

  /** Steps down for the engine of an updated extension: nothing is read,
   *  reported or answered from here on. What the page plays is untouched. */
  function retire() {
    retired = true;
    clearTimeout(timer);
    window.removeEventListener('message', onMessage);
    document.removeEventListener('visibilitychange', onVisibility);
    if (typeof unsubscribe === 'function') unsubscribe();
    if (hooks.state.onJSON === onJSON) hooks.state.onJSON = null;
  }

  Object.defineProperty(window, '__ahenkEngine', { value: Object.freeze({ retire }), enumerable: false, configurable: true });
  post({ kind: 'ready', site });
  report(true);
  schedule();
})();
