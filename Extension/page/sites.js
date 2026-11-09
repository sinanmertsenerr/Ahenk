// Ahenk browser bridge, page world: what each music site adds to the common
// Media Session reading in page/engine.js. Every reader returns null when its
// control is not on the page, so Ahenk only offers what works right now.
// Selectors rely on structure and state attributes (data-testid, aria-*,
// class names), never on button labels, which follow the site's language.
(function () {
  'use strict';
  if (window.__ahenkSites) return;
  const C = window.AhenkCommon;

  // DOM helpers.
  function $(selectors, root) {
    for (const selector of [].concat(selectors)) {
      try {
        const found = (root || document).querySelector(selector);
        if (found) return found;
      } catch (_) {
        // An unsupported selector in this browser.
      }
    }
    return null;
  }
  function $$(selectors, root) {
    for (const selector of [].concat(selectors)) {
      try {
        const found = Array.from((root || document).querySelectorAll(selector));
        if (found.length) return found;
      } catch (_) {
        // Ignored.
      }
    }
    return [];
  }
  function text(element) {
    return element ? String(element.textContent || '').replace(/\s+/g, ' ').trim() : '';
  }
  function press(element) {
    if (!element) return false;
    element.click();
    return true;
  }
  function attribute(element, name) {
    return element ? element.getAttribute(name) : null;
  }
  function hasClass(element, name) {
    return !!element && element.classList.contains(name);
  }
  function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
  /** Polls `read` until it returns something truthy (or the time is up). */
  async function until(read, timeout, step) {
    const end = Date.now() + (timeout || 6000);
    for (;;) {
      let value = null;
      try {
        value = read();
      } catch (_) {
        value = null;
      }
      if (value && (!Array.isArray(value) || value.length)) return value;
      if (Date.now() >= end) return value;
      await wait(step || 250);
    }
  }
  /** Clicks a toggle until `read` says `want` (at most `tries` clicks). */
  async function toggleTo(button, read, want, tries) {
    for (let i = 0; i < (tries || 1); i += 1) {
      if (read() === want) return true;
      if (!press(button())) return false;
      await wait(350);
    }
    return read() === want;
  }
  function absolute(href) {
    try {
      return new URL(href, location.href).href;
    } catch (_) {
      return null;
    }
  }
  function backgroundImage(element) {
    if (!element) return null;
    const m = String(getComputedStyle(element).backgroundImage || '').match(/url\(["']?(.*?)["']?\)/);
    return m ? C.absoluteHTTP(m[1], location.href) : null;
  }

  // The YouTube player (YouTube and YouTube Music share it).
  function ytPlayer() {
    const player = document.getElementById('movie_player');
    return player && typeof player.getPlayerState === 'function' ? player : null;
  }
  function ytTiming() {
    const player = ytPlayer();
    if (!player) return null;
    const state = player.getPlayerState();
    const duration = Number(player.getDuration && player.getDuration());
    return {
      position: Number(player.getCurrentTime && player.getCurrentTime()),
      duration: Number.isFinite(duration) && duration > 0 ? duration : undefined,
      playing: state === 1 || state === 3,
      known: state !== -1 && state !== 5,
    };
  }
  function ytAPI() {
    return {
      play: () => (ytPlayer() ? (ytPlayer().playVideo(), true) : false),
      pause: () => (ytPlayer() ? (ytPlayer().pauseVideo(), true) : false),
      seek: (seconds) => (ytPlayer() ? (ytPlayer().seekTo(seconds, true), true) : false),
      volume: () => {
        const player = ytPlayer();
        if (!player || typeof player.getVolume !== 'function') return null;
        return player.isMuted && player.isMuted() ? 0 : Math.max(0, Math.min(1, player.getVolume() / 100));
      },
      setVolume: (value) => {
        const player = ytPlayer();
        if (!player || typeof player.setVolume !== 'function') return false;
        if (value > 0 && player.isMuted && player.isMuted()) player.unMute();
        player.setVolume(Math.round(value * 100));
        return true;
      },
    };
  }
  function ytVideoID() {
    const player = ytPlayer();
    const data = player && player.getVideoData ? player.getVideoData() : null;
    return (data && C.youtubeVideoId(data.video_id)) || C.youtubeVideoId(location.href);
  }
  function ytResponse() {
    const player = ytPlayer();
    try {
      return player && player.getPlayerResponse ? player.getPlayerResponse() : null;
    } catch (_) {
      return null;
    }
  }
  function ytIsAd() {
    const player = ytPlayer();
    return !!player && (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'));
  }

  const sites = {};

  // MARK: YouTube Music

  sites.youtubeMusic = {
    id: 'youtubeMusic',
    bar: () => $('ytmusic-player-bar'),
    meta() {
      const bar = this.bar();
      const title = text($(['.title', 'yt-formatted-string.title'], bar));
      if (!title) return null;
      const parts = C.splitByline(text($(['.byline', '.subtitle'], bar)));
      return { title, artist: parts[0] || '', album: parts.length >= 3 ? parts[1] : '' };
    },
    timing: ytTiming,
    api: ytAPI(),
    trackId: ytVideoID,
    trackUrl() {
      const id = ytVideoID();
      return id ? C.siteURL('youtubeMusic', 'track', id) : null;
    },
    kind() {
      if (ytIsAd()) return 'advertisement';
      const details = (ytResponse() || {}).videoDetails || {};
      if (/PODCAST/i.test(String(details.musicVideoType || ''))) return 'podcast';
      return 'music';
    },
    musicVideoType() {
      if (ytIsAd()) return undefined;
      const details = (ytResponse() || {}).videoDetails || {};
      return C.musicVideoType({ musicVideoType: details.musicVideoType });
    },
    likeRenderer() {
      return $(['ytmusic-player-bar ytmusic-like-button-renderer', 'ytmusic-like-button-renderer#like-button-renderer']);
    },
    liked() {
      const status = attribute(this.likeRenderer(), 'like-status');
      if (!status) return null;
      return status === 'LIKE';
    },
    setLiked(on) {
      const renderer = this.likeRenderer();
      return toggleTo(() => $(['#button-shape-like button', '.like button', 'button[aria-pressed]'], renderer), () => this.liked(), on, 1);
    },
    shuffleButton: () => $(['ytmusic-player-bar .shuffle', 'ytmusic-player-bar #shuffle']),
    shuffle() {
      const pressed = C.boolAttr(attribute(this.shuffleButton(), 'aria-pressed'));
      return pressed;
    },
    setShuffle(on) {
      return toggleTo(() => this.shuffleButton(), () => this.shuffle(), on, 1);
    },
    repeat() {
      const bar = this.bar();
      if (!bar) return null;
      const value = bar.repeatMode_ ?? bar.repeatMode ?? attribute(bar, 'repeat-mode_') ?? attribute(bar, 'repeat-mode');
      return C.repeatFromState(value);
    },
    repeatModes: ['off', 'all', 'one'],
    setRepeat(mode) {
      return toggleTo(() => $(['ytmusic-player-bar .repeat', 'ytmusic-player-bar #repeat']), () => this.repeat(), mode, 3);
    },
    buttons: {
      playPause: ['ytmusic-player-bar #play-pause-button', 'ytmusic-player-bar .play-pause-button'],
      next: ['ytmusic-player-bar .next-button'],
      previous: ['ytmusic-player-bar .previous-button'],
    },
    search: {
      onPage: () => location.pathname === '/search',
      results() {
        return $$('ytmusic-shelf-renderer ytmusic-responsive-list-item-renderer, ytmusic-card-shelf-renderer')
          .map((item) => {
            const link = $('a[href*="watch?v="]', item);
            if (!link) return null;
            const byline = C.ytMusicByline(text($(['.secondary-flex-columns', '.subtitle'], item)));
            return {
              title: text($(['.title-column .title', '.title', 'yt-formatted-string a'], item)) || text(link),
              artist: byline.artist,
              album: byline.album,
              duration: byline.duration,
              trackId: C.youtubeVideoId(absolute(link.getAttribute('href'))),
              play: () => press($(['ytmusic-play-button-renderer', '.play-button'], item)) || press(link),
            };
          })
          .filter(Boolean);
      },
    },
    playlists: {
      read() {
        const seen = new Set();
        return $$(['ytmusic-guide-renderer a[href*="playlist?list="]', 'ytmusic-guide-section-renderer a[href*="list="]'])
          .map((link) => {
            const url = absolute(link.getAttribute('href'));
            const id = url ? new URL(url).searchParams.get('list') : null;
            const name = text($(['.title', 'yt-formatted-string'], link)) || text(link) || link.getAttribute('title') || '';
            if (!id || !name || seen.has(id)) return null;
            seen.add(id);
            return { id, name, url };
          })
          .filter(Boolean);
      },
      isOpen: (id) => new URLSearchParams(location.search).get('list') === id && location.pathname === '/playlist',
      link: (id) => $(`ytmusic-guide-renderer a[href*="list=${CSS.escape(id)}"]`),
      rows() {
        return $$(['ytmusic-playlist-shelf-renderer ytmusic-responsive-list-item-renderer', 'ytmusic-section-list-renderer ytmusic-responsive-list-item-renderer'])
          .map((item) => {
            const link = $('a[href*="watch?v="]', item);
            const columns = $$('.secondary-flex-columns yt-formatted-string', item).map(text).filter(Boolean);
            return {
              title: text($(['.title-column .title', '.title'], item)),
              artist: columns[0] || '',
              album: columns[1] || '',
              duration: C.parseClock(text($(['.fixed-column', '.fixed-columns'], item))),
              trackId: link ? C.youtubeVideoId(absolute(link.getAttribute('href'))) : null,
              play: () => press($(['ytmusic-play-button-renderer', '.play-button'], item)) || press(link),
            };
          })
          .filter((row) => row.title);
      },
      playAll: () => press($(['ytmusic-responsive-header-renderer ytmusic-play-button-renderer', 'ytmusic-detail-header-renderer ytmusic-play-button-renderer', '#action-buttons ytmusic-play-button-renderer', '#action-buttons a[href*="watch"]'])),
    },
    queue: {
      items: () => $$(['ytmusic-player-queue ytmusic-player-queue-item', '#queue ytmusic-player-queue-item', 'ytmusic-player-queue-item']),
      read() {
        return this.items().map((item, index) => ({
          index,
          title: text($('.song-title', item)),
          artist: text($('.byline', item)),
          duration: C.parseClock(text($('.duration', item))),
          artwork: C.absoluteHTTP(attribute($('img', item), 'src') || ''),
          current: item.hasAttribute('selected') || attribute(item, 'play-button-state') === 'playing' || attribute(item, 'play-button-state') === 'paused',
        })).filter((row) => row.title);
      },
      play(index) {
        const item = this.items()[index];
        return press($(['ytmusic-play-button-renderer', '.song-info', '.left-items'], item)) || press(item);
      },
      async remove(index) {
        const item = this.items()[index];
        if (!item || !press($(['ytmusic-menu-renderer #button', 'ytmusic-menu-renderer button', '#menu button'], item))) return false;
        const entry = await until(() => $$('ytmusic-menu-service-item-renderer, ytmusic-menu-navigation-item-renderer').find((element) => {
          const data = element.data || element.__data || {};
          return !!(data.serviceEndpoint && data.serviceEndpoint.removeFromQueueEndpoint);
        }), 1500, 100);
        if (!entry) {
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
          return false;
        }
        return press(entry);
      },
    },
  };

  // MARK: YouTube

  sites.youtube = {
    id: 'youtube',
    meta() {
      const player = ytPlayer();
      const data = player && player.getVideoData ? player.getVideoData() : null;
      if (!data || !data.title) return null;
      return { title: data.title, artist: C.cleanYouTubeArtist(data.author), album: '' };
    },
    timing: ytTiming,
    api: Object.assign(ytAPI(), {
      next: () => {
        const player = ytPlayer();
        return player && player.nextVideo ? (player.nextVideo(), true) : false;
      },
      previous: () => {
        const player = ytPlayer();
        return player && player.previousVideo ? (player.previousVideo(), true) : false;
      },
    }),
    trackId: ytVideoID,
    trackUrl() {
      const id = ytVideoID();
      return id ? C.siteURL('youtube', 'track', id) : null;
    },
    kind() {
      const response = ytResponse() || {};
      const micro = (response.microformat || {}).playerMicroformatRenderer || {};
      const details = response.videoDetails || {};
      const player = ytPlayer();
      const data = player && player.getVideoData ? player.getVideoData() : {};
      const genre = attribute($('meta[itemprop="genre"]'), 'content');
      return C.youtubeKind({
        isAd: ytIsAd(),
        isLive: !!details.isLiveContent,
        category: micro.category || genre,
        musicVideoType: details.musicVideoType,
        author: data.author || details.author,
        title: data.title || details.title,
      });
    },
    musicVideoType() {
      if (ytIsAd()) return undefined;
      const details = (ytResponse() || {}).videoDetails || {};
      const player = ytPlayer();
      const data = player && player.getVideoData ? player.getVideoData() : {};
      return C.musicVideoType({ musicVideoType: details.musicVideoType, author: data.author || details.author });
    },
    likeButton: () => $(['like-button-view-model button', '#top-level-buttons-computed like-button-view-model button', 'ytd-toggle-button-renderer#like-button button']),
    liked() {
      return C.boolAttr(attribute(this.likeButton(), 'aria-pressed'));
    },
    setLiked(on) {
      return toggleTo(() => this.likeButton(), () => this.liked(), on, 1);
    },
    shuffle() {
      const button = $('ytd-playlist-panel-renderer #playlist-action-menu ytd-toggle-button-renderer:nth-of-type(2) button');
      return C.boolAttr(attribute(button, 'aria-pressed'));
    },
    setShuffle(on) {
      return toggleTo(() => $('ytd-playlist-panel-renderer #playlist-action-menu ytd-toggle-button-renderer:nth-of-type(2) button'), () => this.shuffle(), on, 1);
    },
    buttons: {
      next: ['.ytp-next-button'],
      previous: ['.ytp-prev-button'],
    },
    search: {
      onPage: () => location.pathname === '/results',
      results() {
        return $$('ytd-search ytd-video-renderer')
          .map((item) => {
            const link = $('a#video-title', item);
            if (!link) return null;
            return {
              title: text(link) || link.getAttribute('title') || '',
              artist: C.cleanYouTubeArtist(text($(['ytd-channel-name a', '#channel-name a'], item))),
              album: '',
              duration: C.parseClock(text($(['ytd-thumbnail-overlay-time-status-renderer', 'badge-shape .badge-shape-wiz__text', '#time-status'], item))),
              trackId: C.youtubeVideoId(absolute(link.getAttribute('href'))),
              play: () => press(link),
            };
          })
          .filter(Boolean);
      },
    },
    playlists: {
      read() {
        const seen = new Set();
        return $$(['ytd-guide-renderer a[href*="list="]', 'ytd-guide-collapsible-section-entry-renderer a[href*="list="]'])
          .map((link) => {
            const url = absolute(link.getAttribute('href'));
            const id = url ? new URL(url).searchParams.get('list') : null;
            const name = text($('.title', link)) || link.getAttribute('title') || text(link);
            if (!id || !name || seen.has(id)) return null;
            seen.add(id);
            return { id, name, url: 'https://www.youtube.com/playlist?list=' + encodeURIComponent(id) };
          })
          .filter(Boolean);
      },
      isOpen: (id) => location.pathname === '/playlist' && new URLSearchParams(location.search).get('list') === id,
      link: (id) => $(`ytd-guide-renderer a[href*="list=${CSS.escape(id)}"]`),
      rows() {
        return $$('ytd-playlist-video-list-renderer ytd-playlist-video-renderer')
          .map((item) => {
            const link = $('a#video-title', item);
            return {
              title: text(link),
              artist: C.cleanYouTubeArtist(text($(['ytd-channel-name a', '#channel-name a'], item))),
              album: '',
              duration: C.parseClock(text($(['ytd-thumbnail-overlay-time-status-renderer', '#time-status'], item))),
              trackId: link ? C.youtubeVideoId(absolute(link.getAttribute('href'))) : null,
              play: () => press(link),
            };
          })
          .filter((row) => row.title);
      },
      playAll: () => press($(['ytd-playlist-header-renderer a[href*="watch"]', 'yt-page-header-view-model a[href*="watch"]', '#play-button a'])),
    },
    queue: {
      items: () => $$('ytd-playlist-panel-renderer #items ytd-playlist-panel-video-renderer'),
      read() {
        return this.items().map((item, index) => ({
          index,
          title: text($('#video-title', item)),
          artist: C.cleanYouTubeArtist(text($('#byline', item))),
          duration: C.parseClock(text($('ytd-thumbnail-overlay-time-status-renderer', item))),
          current: item.hasAttribute('selected'),
        })).filter((row) => row.title);
      },
      play(index) {
        return press($('a#wc-endpoint', this.items()[index]) || this.items()[index]);
      },
    },
  };

  // MARK: Spotify Web Player

  const spotifyBar = () => $(['[data-testid="now-playing-bar"]', 'footer', 'aside[data-testid="now-playing-bar"]']);
  sites.spotify = {
    id: 'spotify',
    widget: () => $(['[data-testid="now-playing-widget"]']),
    meta() {
      const widget = this.widget();
      const title = text($(['[data-testid="context-item-info-title"]', '[data-testid="context-item-link"]'], widget));
      if (!title) return null;
      const artists = $$('[data-testid="context-item-info-artist"]', widget).map(text).filter(Boolean);
      return { title, artist: artists.join(', '), album: '' };
    },
    timing() {
      const bar = spotifyBar();
      const shown = C.clockPair(text($(['[data-testid="playback-position"]'], bar)), text($(['[data-testid="playback-duration"]'], bar)));
      const range = $('[data-testid="playback-progressbar"] input[type="range"]', bar);
      const max = range ? Number(range.max) : NaN;
      const value = range ? Number(range.value) : NaN;
      // The slider counts milliseconds; the labels only whole seconds.
      const precise = Number.isFinite(max) && max > 1000 && Number.isFinite(value);
      if (!shown && !precise) return null;
      return {
        position: precise ? value / 1000 : shown.position,
        duration: precise ? max / 1000 : shown.duration,
        playing: this.isPlaying(),
        known: true,
      };
    },
    isPlaying() {
      const button = $('[data-testid="control-button-playpause"]', spotifyBar());
      // The button offers "pause" while playing; its icon path is not a label.
      const state = attribute(button, 'data-playing') ?? attribute(button, 'aria-pressed');
      if (state !== null) return state === 'true';
      const session = navigator.mediaSession && navigator.mediaSession.playbackState;
      return session === 'playing';
    },
    trackId() {
      const widget = this.widget();
      for (const link of $$(['a[href*="/track/"]', 'a[href*="spotify:track:"]', 'a[data-testid="context-item-link"]'], widget)) {
        const id = C.spotifyTrackId(decodeURIComponent(link.getAttribute('href') || ''));
        if (id) return id;
      }
      return null;
    },
    trackUrl() {
      const id = this.trackId();
      return id ? C.siteURL('spotify', 'track', id) : null;
    },
    kind() {
      const widget = this.widget();
      if ($('a[href*="/episode/"]', widget)) return 'podcast';
      if ($(['[data-testid="context-item-info-ad-title"]', '[data-testid="ad-link"]'], widget)) return 'advertisement';
      return 'music';
    },
    likeButton() {
      return $(['[data-testid="add-button"]', 'button[data-testid="add-button"]'], this.widget());
    },
    liked() {
      return C.boolAttr(attribute(this.likeButton(), 'aria-checked'));
    },
    setLiked(on) {
      return toggleTo(() => this.likeButton(), () => this.liked(), on, 1);
    },
    shuffle() {
      return C.boolAttr(attribute($('[data-testid="control-button-shuffle"]', spotifyBar()), 'aria-checked'));
    },
    setShuffle(on) {
      return toggleTo(() => $('[data-testid="control-button-shuffle"]', spotifyBar()), () => this.shuffle(), on, 2);
    },
    repeat() {
      return C.repeatFromState(attribute($('[data-testid="control-button-repeat"]', spotifyBar()), 'aria-checked'));
    },
    repeatModes: ['off', 'all', 'one'],
    setRepeat(mode) {
      return toggleTo(() => $('[data-testid="control-button-repeat"]', spotifyBar()), () => this.repeat(), mode, 3);
    },
    buttons: {
      playPause: ['[data-testid="control-button-playpause"]'],
      next: ['[data-testid="control-button-skip-forward"]'],
      previous: ['[data-testid="control-button-skip-back"]'],
    },
    volume() {
      const range = $('[data-testid="volume-bar"] input[type="range"]');
      if (!range) return null;
      const max = Number(range.max) || 1;
      return Math.max(0, Math.min(1, Number(range.value) / max));
    },
    playByID(song) {
      const id = C.spotifyTrackId(song.trackId || song.url || '');
      return id ? C.siteURL('spotify', 'track', id) : null;
    },
    trackPageButton: () => $(['[data-testid="action-bar-row"] [data-testid="play-button"]', 'main [data-testid="play-button"]']),
    trackPagePlay() {
      return press(this.trackPageButton());
    },
    search: {
      onPage: () => location.pathname.startsWith('/search/'),
      results() {
        return spotifyRows($('main') || document);
      },
    },
    playlists: {
      read() {
        const seen = new Set();
        return $$(['[data-testid="rootlist"] a[href^="/playlist/"]', 'nav a[href^="/playlist/"]', 'aside a[href^="/playlist/"]'])
          .map((link) => {
            const id = (link.getAttribute('href') || '').split('/')[2];
            const row = link.closest('[role="row"], li, [data-testid="rootlist-item"]') || link;
            const name = text($(['[data-encore-id="listRowTitle"]', '[data-testid="listrow-title"]', 'p span', 'span'], row)) || link.getAttribute('aria-label') || text(link);
            if (!id || !name || seen.has(id)) return null;
            seen.add(id);
            return { id, name, url: 'https://open.spotify.com/playlist/' + id };
          })
          .filter(Boolean);
      },
      isOpen: (id) => location.pathname === '/playlist/' + id,
      link: (id) => $(`a[href="/playlist/${CSS.escape(id)}"]`),
      rows: () => spotifyRows($('main') || document),
      playAll: () => press($(['[data-testid="action-bar-row"] [data-testid="play-button"]', 'main [data-testid="play-button"]'])),
    },
  };
  function spotifyRows(scope) {
    return $$('[data-testid="tracklist-row"]', scope)
      .map((row) => {
        const link = $(['a[data-testid="internal-track-link"]', 'a[href*="/track/"]'], row);
        const title = text($(['a[data-testid="internal-track-link"] div', '[data-encore-id="text"]'], row)) || text(link);
        const artists = $$('a[href^="/artist/"]', row).map(text).filter(Boolean);
        const album = text($('a[href^="/album/"]', row));
        const clock = $$('div', row).map(text).reverse().find((t) => C.parseClock(t) !== null);
        return {
          title,
          artist: Array.from(new Set(artists)).join(', '),
          album,
          duration: clock ? C.parseClock(clock) : null,
          trackId: link ? C.spotifyTrackId(link.getAttribute('href') || '') : null,
          play() {
            const button = $(['button[data-testid="play-button"]', 'button[aria-label][data-encore-id="buttonTertiary"]'], row);
            if (press(button)) return true;
            row.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
            return true;
          },
        };
      })
      .filter((row) => row.title);
  }

  // MARK: SoundCloud

  const scControls = () => $('.playControls');
  sites.soundCloud = {
    id: 'soundCloud',
    meta() {
      const badge = $('.playbackSoundBadge', scControls());
      const link = $('.playbackSoundBadge__titleLink', badge);
      const title = (link && (link.getAttribute('title') || text($('span[aria-hidden="true"]', link)))) || '';
      if (!title) return null;
      return {
        title,
        artist: text($('.playbackSoundBadge__lightLink', badge)) || attribute($('.playbackSoundBadge__lightLink', badge), 'title') || '',
        album: '',
        artwork: backgroundImage($('.playbackSoundBadge .sc-artwork span, .playbackSoundBadge span.image__full', badge)),
      };
    },
    timing() {
      const controls = scControls();
      const shown = C.clockPair(
        text($('.playbackTimeline__timePassed span[aria-hidden="true"]', controls)),
        text($('.playbackTimeline__duration span[aria-hidden="true"]', controls))
      );
      if (!shown) return null;
      return { position: shown.position, duration: shown.duration, playing: hasClass($('.playControls__play', controls), 'playing'), known: true };
    },
    trackUrl() {
      const link = $('.playbackSoundBadge__titleLink', scControls());
      const href = link ? absolute(link.getAttribute('href')) : null;
      return href ? href.split('?')[0] : null;
    },
    trackId() {
      const url = this.trackUrl();
      return url ? new URL(url).pathname.replace(/^\//, '') : null;
    },
    liked() {
      const button = $('.playbackSoundBadge__like', scControls());
      return button ? hasClass(button, 'sc-button-selected') : null;
    },
    setLiked(on) {
      return toggleTo(() => $('.playbackSoundBadge__like', scControls()), () => this.liked(), on, 1);
    },
    shuffle() {
      const button = $('.shuffleControl', scControls());
      return button ? hasClass(button, 'm-shuffling') : null;
    },
    setShuffle(on) {
      return toggleTo(() => $('.shuffleControl', scControls()), () => this.shuffle(), on, 1);
    },
    repeat() {
      const button = $('.repeatControl', scControls());
      if (!button) return null;
      if (hasClass(button, 'm-one')) return 'one';
      if (hasClass(button, 'm-all')) return 'all';
      return 'off';
    },
    repeatModes: ['off', 'one', 'all'],
    setRepeat(mode) {
      return toggleTo(() => $('.repeatControl', scControls()), () => this.repeat(), mode, 3);
    },
    buttons: {
      playPause: ['.playControls__play'],
      next: ['.playControls .skipControl__next'],
      previous: ['.playControls .skipControl__previous'],
    },
    volume() {
      const slider = $('.volume__sliderWrapper[aria-valuenow]');
      if (!slider) return null;
      const value = Number(slider.getAttribute('aria-valuenow'));
      const max = Number(slider.getAttribute('aria-valuemax')) || 1;
      return Number.isFinite(value) ? Math.max(0, Math.min(1, value / max)) : null;
    },
    search: {
      onPage: () => location.pathname.startsWith('/search'),
      results() {
        return $$('.searchList__item, li.searchItem')
          .map((item) => {
            const link = $('.soundTitle__title', item);
            if (!link) return null;
            return {
              title: text(link),
              artist: text($('.soundTitle__username', item)),
              album: '',
              duration: null,
              trackId: (link.getAttribute('href') || '').replace(/^\//, ''),
              play: () => press($(['.sc-button-play', '.soundTitle__playButton button'], item)),
            };
          })
          .filter(Boolean);
      },
    },
    queue: {
      items: () => $$('.queue .queue__itemsContainer .queueItemView'),
      read() {
        return this.items().map((item, index) => ({
          index,
          title: text($('.queueItemView__title a, .queueItemView__title', item)),
          artist: text($('.queueItemView__username', item)),
          current: hasClass(item, 'm-active') || hasClass(item, 'm-playing'),
        })).filter((row) => row.title);
      },
      play(index) {
        return press($('.queueItemView__playButton, .sc-button-play', this.items()[index]) || this.items()[index]);
      },
    },
  };

  // MARK: Deezer

  const dzBar = () => $(['[data-testid="player_bar"]', '.player-bottom', '#player']);
  sites.deezer = {
    id: 'deezer',
    meta() {
      const bar = dzBar();
      const title = text($(['[data-testid="item_title"]', '.track-title .track-link:first-child'], bar));
      if (!title) return null;
      return { title, artist: text($(['[data-testid="item_subtitle"]', '.track-title .track-link:nth-child(2)'], bar)), album: '' };
    },
    timing() {
      const bar = dzBar();
      // The second label is the length, or what is left ("-1:15").
      const shown = C.clockPair(
        text($(['[data-testid="elapsed_time"]', '.slider-counter-current'], bar)),
        text($(['[data-testid="remaining_time"]', '.slider-counter-max'], bar))
      );
      if (!shown) return null;
      return { position: shown.position, duration: shown.duration, playing: navigator.mediaSession && navigator.mediaSession.playbackState === 'playing', known: true };
    },
    trackId() {
      const link = $(['[data-testid="item_title"] a[href*="/track/"]', 'a[href*="/track/"]'], dzBar());
      return link ? C.idAfter(link.getAttribute('href'), 'track') : null;
    },
    trackUrl() {
      const id = this.trackId();
      return id ? C.siteURL('deezer', 'track', id) : null;
    },
    liked() {
      const button = $(['[data-testid="add_to_favorite_button"]', '[data-testid="add_to_favorites_button"]', '[data-testid="favorite_button"]'], dzBar());
      return button ? C.boolAttr(attribute(button, 'aria-checked') ?? attribute(button, 'aria-pressed')) : null;
    },
    setLiked(on) {
      return toggleTo(() => $(['[data-testid="add_to_favorite_button"]', '[data-testid="add_to_favorites_button"]', '[data-testid="favorite_button"]'], dzBar()), () => this.liked(), on, 1);
    },
    shuffle() {
      return C.boolAttr(attribute($('[data-testid="shuffle_button"]', dzBar()), 'aria-checked'));
    },
    setShuffle(on) {
      return toggleTo(() => $('[data-testid="shuffle_button"]', dzBar()), () => this.shuffle(), on, 1);
    },
    repeat() {
      const button = $(['[data-testid="repeat_button"]', '[data-testid="repeat_one_button"]'], dzBar());
      if (!button) return null;
      if (attribute(button, 'data-testid') === 'repeat_one_button') return 'one';
      return C.boolAttr(attribute(button, 'aria-checked')) ? 'all' : 'off';
    },
    repeatModes: ['off', 'all', 'one'],
    setRepeat(mode) {
      return toggleTo(() => $(['[data-testid="repeat_button"]', '[data-testid="repeat_one_button"]'], dzBar()), () => this.repeat(), mode, 3);
    },
    buttons: {
      playPause: ['[data-testid="play_button_pause"]', '[data-testid="play_button_play"]'],
      play: ['[data-testid="play_button_play"]'],
      pause: ['[data-testid="play_button_pause"]'],
      next: ['[data-testid="next_track_button"]'],
      previous: ['[data-testid="previous_track_button"]'],
    },
    search: {
      onPage: () => location.pathname.includes('/search/'),
      results() {
        return $$(['[data-testid="tracklist"] [role="row"]', '[role="rowgroup"] [role="row"]'])
          .map((row) => {
            const title = text($(['[data-testid="title"]', 'a[href*="/track/"]'], row));
            if (!title) return null;
            return {
              title,
              artist: text($(['[data-testid="artist"]', 'a[href*="/artist/"]'], row)),
              album: text($(['[data-testid="album"]', 'a[href*="/album/"]'], row)),
              duration: C.parseClock(text($(['[data-testid="duration"]'], row))),
              play: () => press($(['[data-testid="play_button"]', 'button[data-testid*="play"]'], row)) || (row.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })), true),
            };
          })
          .filter(Boolean);
      },
    },
  };

  // MARK: TIDAL

  const tdFooter = () => $(['[data-test="footer-player"]', '#footerPlayer', 'footer']);
  sites.tidal = {
    id: 'tidal',
    meta() {
      const footer = tdFooter();
      const title = text($(['[data-test="footer-track-title"]'], footer));
      if (!title) return null;
      return {
        title,
        artist: $$(['[data-test="grid-item-detail-text-title-artist"]', '.artist-link a'], footer).map(text).filter(Boolean).join(', '),
        album: '',
      };
    },
    timing() {
      const footer = tdFooter();
      const shown = C.clockPair(text($('[data-test="current-time"]', footer)), text($('[data-test="duration"]', footer)));
      if (!shown) return null;
      return { position: shown.position, duration: shown.duration, playing: !!$('[data-test="pause"]', footer), known: true };
    },
    trackId() {
      const link = $('[data-test="footer-track-title"] a[href*="/track/"]', tdFooter()) || $('[data-test="footer-track-title"] a', tdFooter());
      return link ? C.idAfter(link.getAttribute('href'), 'track') : null;
    },
    trackUrl() {
      const id = this.trackId();
      return id ? C.siteURL('tidal', 'track', id) : null;
    },
    // TIDAL plays songs and music videos only: both are music.
    liked() {
      return C.boolAttr(attribute($(['[data-test="footer-favorite-button"]', '[data-test="favorite-button"]'], tdFooter()), 'aria-checked'));
    },
    setLiked(on) {
      return toggleTo(() => $(['[data-test="footer-favorite-button"]', '[data-test="favorite-button"]'], tdFooter()), () => this.liked(), on, 1);
    },
    shuffle() {
      return C.boolAttr(attribute($('[data-test="shuffle"]', tdFooter()), 'aria-checked'));
    },
    setShuffle(on) {
      return toggleTo(() => $('[data-test="shuffle"]', tdFooter()), () => this.shuffle(), on, 1);
    },
    repeat() {
      const button = $('[data-test="repeat"]', tdFooter());
      if (!button) return null;
      return C.repeatFromState(attribute(button, 'data-type') || attribute(button, 'aria-checked'));
    },
    repeatModes: ['off', 'all', 'one'],
    setRepeat(mode) {
      return toggleTo(() => $('[data-test="repeat"]', tdFooter()), () => this.repeat(), mode, 3);
    },
    buttons: {
      playPause: ['[data-test="pause"]', '[data-test="play"]'],
      play: ['[data-test="play"]'],
      pause: ['[data-test="pause"]'],
      next: ['[data-test="next"]'],
      previous: ['[data-test="previous"]'],
    },
    search: {
      onPage: () => location.pathname.startsWith('/search'),
      results() {
        return $$(['[data-test="tracklist-row"]', '[data-track-id]'])
          .map((row) => {
            const title = text($(['[data-test="table-cell-title"]', '[data-test="table-row-title"]', '.track-name'], row));
            if (!title) return null;
            return {
              title,
              artist: text($(['[data-test="track-row-artist"]', '.artist-link'], row)),
              album: text($(['[data-test="track-row-album"]', '.album-link'], row)),
              duration: C.parseClock(text($(['[data-test="duration"]', 'time'], row))),
              trackId: attribute(row, 'data-track-id'),
              play: () => press($(['[data-test="play-button"]', 'button[data-test*="play"]'], row)) || (row.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })), true),
            };
          })
          .filter(Boolean);
      },
    },
  };

  // MARK: Amazon Music

  sites.amazonMusic = {
    id: 'amazonMusic',
    transport: () => $(['#transport', 'music-horizontal-item[id*="transport"]', '[data-id="transport"]']),
    meta() {
      const transport = this.transport();
      const item = $('music-horizontal-item', transport) || transport;
      const title = attribute(item, 'primary-text') || text($('[slot="primaryText"]', item));
      if (!title) return null;
      return { title, artist: attribute(item, 'secondary-text') || text($('[slot="secondaryText"]', item)), album: '' };
    },
    buttons: {
      playPause: ['#transport music-button[icon-name="play"]', '#transport music-button[icon-name="pause"]'],
      play: ['#transport music-button[icon-name="play"]'],
      pause: ['#transport music-button[icon-name="pause"]'],
      next: ['#transport music-button[icon-name="next"]'],
      previous: ['#transport music-button[icon-name="previous"]'],
    },
    shuffle() {
      const button = $('#transport music-button[icon-name="shuffle"]');
      return button ? attribute(button, 'variant') === 'accent' || C.boolAttr(attribute(button, 'aria-pressed')) === true : null;
    },
    setShuffle(on) {
      return toggleTo(() => $('#transport music-button[icon-name="shuffle"]'), () => this.shuffle(), on, 1);
    },
    repeat() {
      const one = $('#transport music-button[icon-name="repeatOne"], #transport music-button[icon-name="repeat-one"]');
      if (one) return 'one';
      const button = $('#transport music-button[icon-name="repeat"]');
      if (!button) return null;
      return attribute(button, 'variant') === 'accent' ? 'all' : 'off';
    },
    repeatModes: ['off', 'all', 'one'],
    setRepeat(mode) {
      return toggleTo(() => $('#transport music-button[icon-name^="repeat"]'), () => this.repeat(), mode, 3);
    },
    search: {
      onPage: () => location.pathname.startsWith('/search'),
      results() {
        return $$(['music-image-row', 'music-horizontal-item'])
          .map((row) => {
            const title = attribute(row, 'primary-text');
            if (!title) return null;
            return {
              title,
              artist: attribute(row, 'secondary-text-1') || attribute(row, 'secondary-text') || '',
              album: attribute(row, 'secondary-text-2') || '',
              duration: C.parseClock(attribute(row, 'duration') || ''),
              play: () => press($('music-button[icon-name="play"]', row)) || (row.dispatchEvent(new CustomEvent('music-image-row-play', { bubbles: true })), false),
            };
          })
          .filter(Boolean);
      },
    },
  };

  // MARK: Choosing

  function forHost(host) {
    const site = C.siteForHost(host);
    return site ? sites[site] : null;
  }

  Object.defineProperty(window, '__ahenkSites', {
    value: Object.freeze({ sites, forHost, helpers: { $, $$, text, press, wait, until, toggleTo, absolute } }),
    enumerable: false,
    configurable: false,
  });
})();
