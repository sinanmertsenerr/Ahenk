// A stand-in for a music site (see index.html): a small single-page app
// with the site's element names, a player API object, Media Session
// handlers and an <audio> element that plays a quiet generated tone (the
// test browser is muted as well). Songs, artists, playlists and lyric lines
// are invented.
'use strict';

const SONGS = {
  ahenkMock01: { title: 'Velvet Harbor Lights', artist: 'Orchid Telemetry', album: 'Tidal Glass', duration: 214 },
  ahenkMock02: { title: 'Quiet Engines', artist: 'Nadia Ferro', album: 'Low Orbit Letters', duration: 187 },
  ahenkMock03: { title: 'Saffron Static', artist: 'Kestrel & Vale', album: 'Paper Comets', duration: 236 },
  ahenkMock04: { title: 'Lanterns Under Ice', artist: 'Mirela Stoica', album: 'Northbound Postcards', duration: 223 },
  ahenkMock05: { title: 'Marmara Neon', artist: 'Deniz Ulaş Trio', album: 'Kıyıdan Sesler', duration: 201 },
  ahenkMock06: { title: 'Lanterns Under Ice (Slowed)', artist: 'Night Desk Edits', album: 'Edits Vol. 2', duration: 268 },
};
const PLAYLISTS = {
  PLahenkNightShift: { name: 'Night Shift Mix', songs: ['ahenkMock03', 'ahenkMock05', 'ahenkMock02'] },
  PLahenkKiyidan: { name: 'Kıyıdan Sesler', songs: ['ahenkMock05', 'ahenkMock01'] },
};
const START_QUEUE = ['ahenkMock01', 'ahenkMock02', 'ahenkMock03', 'ahenkMock05'];

const $ = (selector, root) => (root || document).querySelector(selector);
const clock = (seconds) => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
const cover = (id) => `https://music.youtube.com/mock-cover/${id}.png`;

// MARK: The player

const player = { queue: START_QUEUE.slice(), index: 0, list: null, playing: false, position: 0, since: 0, volume: 70, liked: {}, repeat: 'NONE' };
const audio = $('#tone');
audio.src = toneURL();
audio.volume = 0.2;

function current() {
  return player.queue[player.index];
}

function position() {
  const song = SONGS[current()];
  const now = player.playing ? player.position + (Date.now() - player.since) / 1000 : player.position;
  return Math.min(song ? song.duration : 0, now);
}

function load(queue, index, { list = null, play = true } = {}) {
  player.queue = queue.slice();
  player.index = index;
  player.list = list;
  player.position = 0;
  player.since = Date.now();
  const params = new URLSearchParams({ v: current() });
  if (list) params.set('list', list);
  if (location.pathname !== '/watch' || new URLSearchParams(location.search).get('v') !== current()) {
    history.pushState(null, '', '/watch?' + params);
    render();
  }
  showSong();
  if (play) setPlaying(true);
  // The site loads the song's lyrics a moment later (its lyrics view is open).
  const id = current();
  setTimeout(() => fetchLyrics(id), 300);
}

function setPlaying(on) {
  if (on === player.playing) return;
  player.position = position();
  player.since = Date.now();
  player.playing = on;
  if (on) audio.play().catch(() => {});
  else audio.pause();
  navigator.mediaSession.playbackState = on ? 'playing' : 'paused';
  updatePositionState();
}

function seek(seconds) {
  player.position = Math.max(0, Math.min(SONGS[current()].duration, seconds));
  player.since = Date.now();
  updatePositionState();
  audio.dispatchEvent(new Event('seeked'));
}

function skip(step) {
  const next = player.index + step;
  if (next < 0 || next >= player.queue.length) return;
  load(player.queue, next, { list: player.list });
}

function updatePositionState() {
  const song = SONGS[current()];
  if (!song) return;
  navigator.mediaSession.setPositionState({ duration: song.duration, position: position(), playbackRate: 1 });
}

// The page's own report to the system, as every music site makes it.
function showSong() {
  const song = SONGS[current()];
  navigator.mediaSession.metadata = new MediaMetadata({
    title: song.title, artist: song.artist, album: song.album,
    artwork: [{ src: cover(current()), sizes: '544x544', type: 'image/png' }],
  });
  $('ytmusic-player-bar .title').textContent = song.title;
  $('ytmusic-player-bar .byline').textContent = `${song.artist} • ${song.album} • 2025`;
  const status = player.liked[current()] ? 'LIKE' : 'INDIFFERENT';
  $('ytmusic-like-button-renderer').setAttribute('like-status', status);
  $('#button-shape-like button').setAttribute('aria-pressed', String(status === 'LIKE'));
  updatePositionState();
  renderQueue();
}

navigator.mediaSession.setActionHandler('play', () => setPlaying(true));
navigator.mediaSession.setActionHandler('pause', () => setPlaying(false));
navigator.mediaSession.setActionHandler('nexttrack', () => skip(1));
navigator.mediaSession.setActionHandler('previoustrack', () => skip(-1));
navigator.mediaSession.setActionHandler('seekto', (details) => seek(details.seekTime));

// The site's player API object (what its own scripts use).
Object.assign($('#movie_player'), {
  getPlayerState: () => (current() ? (player.playing ? 1 : 2) : -1),
  getCurrentTime: () => position(),
  getDuration: () => (SONGS[current()] || {}).duration || 0,
  playVideo: () => setPlaying(true),
  pauseVideo: () => setPlaying(false),
  seekTo: (seconds) => seek(seconds),
  getVolume: () => player.volume,
  setVolume: (value) => {
    player.volume = Math.max(0, Math.min(100, value));
    audio.volume = 0.2 * (player.volume / 100);
  },
  isMuted: () => false,
  unMute: () => {},
  getVideoData: () => {
    const song = SONGS[current()] || {};
    return { video_id: current(), title: song.title, author: song.artist };
  },
  getPlayerResponse: () => ({ videoDetails: { videoId: current(), musicVideoType: 'MUSIC_VIDEO_TYPE_ATV' } }),
});

// MARK: The bar's buttons

$('#play-pause-button').addEventListener('click', () => setPlaying(!player.playing));
$('ytmusic-player-bar .next-button').addEventListener('click', () => skip(1));
$('ytmusic-player-bar .previous-button').addEventListener('click', () => skip(-1));
$('#button-shape-like button').addEventListener('click', () => {
  player.liked[current()] = !player.liked[current()];
  showSong();
});
$('ytmusic-player-bar .shuffle').addEventListener('click', (event) => {
  const on = event.currentTarget.getAttribute('aria-pressed') !== 'true';
  event.currentTarget.setAttribute('aria-pressed', String(on));
});
$('ytmusic-player-bar .repeat').addEventListener('click', () => {
  player.repeat = { NONE: 'ALL', ALL: 'ONE', ONE: 'NONE' }[player.repeat];
  $('ytmusic-player-bar').setAttribute('repeat-mode', player.repeat);
});

// MARK: Pages

function row(id, { byline, onPlay }) {
  const song = SONGS[id];
  const item = document.createElement('ytmusic-responsive-list-item-renderer');
  item.innerHTML = `
    <ytmusic-play-button-renderer>▶</ytmusic-play-button-renderer>
    <div class="title-column"><a class="title" href="/watch?v=${id}"></a></div>
    <div class="secondary-flex-columns"></div>
    <div class="fixed-column"></div>`;
  $('.title', item).textContent = song.title;
  if (byline) {
    $('.secondary-flex-columns', item).textContent = byline;
  } else {
    for (const text of [song.artist, song.album]) {
      const part = document.createElement('yt-formatted-string');
      part.textContent = text;
      $('.secondary-flex-columns', item).append(part);
    }
    $('.fixed-column', item).textContent = clock(song.duration);
  }
  $('ytmusic-play-button-renderer', item).addEventListener('click', onPlay);
  $('a', item).addEventListener('click', (event) => {
    event.preventDefault();
    onPlay();
  });
  return item;
}

function render() {
  const content = $('#content');
  content.textContent = '';
  const params = new URLSearchParams(location.search);
  if (location.pathname === '/search') {
    // Results with a near miss first (the site's own ranking is not ours).
    const words = (params.get('q') || '').toLowerCase().split(/\s+/).filter(Boolean);
    const found = Object.keys(SONGS)
      .map((id) => ({ id, hits: words.filter((w) => `${SONGS[id].title} ${SONGS[id].artist}`.toLowerCase().includes(w)).length }))
      .filter((entry) => entry.hits > 0)
      .sort((a, b) => (SONGS[b.id].title.length - SONGS[a.id].title.length) || b.hits - a.hits);
    const shelf = document.createElement('ytmusic-shelf-renderer');
    for (const { id } of found) {
      const song = SONGS[id];
      shelf.append(row(id, { byline: `Song • ${song.artist} • ${song.album} • ${clock(song.duration)}`, onPlay: () => load([id], 0) }));
    }
    content.append(shelf);
  } else if (location.pathname === '/playlist' && PLAYLISTS[params.get('list')]) {
    const id = params.get('list');
    const list = PLAYLISTS[id];
    const header = document.createElement('ytmusic-responsive-header-renderer');
    header.innerHTML = '<h1></h1><ytmusic-play-button-renderer>▶ Play</ytmusic-play-button-renderer>';
    $('h1', header).textContent = list.name;
    $('ytmusic-play-button-renderer', header).addEventListener('click', () => load(list.songs, 0, { list: id }));
    const shelf = document.createElement('ytmusic-playlist-shelf-renderer');
    list.songs.forEach((song, index) => shelf.append(row(song, { onPlay: () => load(list.songs, index, { list: id }) })));
    content.append(header, shelf);
  } else {
    content.textContent = 'Home';
  }
}

function renderGuide() {
  const guide = $('#guide');
  for (const [id, list] of Object.entries(PLAYLISTS)) {
    const link = document.createElement('a');
    link.href = `/playlist?list=${id}`;
    link.innerHTML = '<yt-formatted-string class="title"></yt-formatted-string>';
    $('.title', link).textContent = list.name;
    // The site opens pages without reloading.
    link.addEventListener('click', (event) => {
      event.preventDefault();
      history.pushState(null, '', link.href);
      render();
    });
    guide.append(link);
  }
}

function renderQueue() {
  const queue = $('#queue');
  queue.textContent = '';
  player.queue.forEach((id, index) => {
    const song = SONGS[id];
    const item = document.createElement('ytmusic-player-queue-item');
    if (index === player.index) {
      item.setAttribute('selected', '');
      item.setAttribute('play-button-state', player.playing ? 'playing' : 'paused');
    }
    item.innerHTML = `
      <img src="${cover(id)}" alt="">
      <ytmusic-play-button-renderer>▶</ytmusic-play-button-renderer>
      <div class="song-info"><div class="song-title"></div><div class="byline"></div></div>
      <div class="duration"></div>
      <ytmusic-menu-renderer><button id="button">⋯</button></ytmusic-menu-renderer>`;
    $('.song-title', item).textContent = song.title;
    $('.byline', item).textContent = song.artist;
    $('.duration', item).textContent = clock(song.duration);
    $('ytmusic-play-button-renderer', item).addEventListener('click', () => load(player.queue, index, { list: player.list }));
    $('#button', item).addEventListener('click', () => openMenu(index));
    queue.append(item);
  });
}

// The queue item's menu: its entries carry their action as data, as the
// site's do.
function openMenu(index) {
  for (const old of document.querySelectorAll('ytmusic-menu-service-item-renderer')) old.remove();
  const remove = document.createElement('ytmusic-menu-service-item-renderer');
  remove.textContent = 'Remove from queue';
  remove.data = { serviceEndpoint: { removeFromQueueEndpoint: { index } } };
  remove.addEventListener('click', () => {
    remove.remove();
    if (index === player.index) return;
    player.queue.splice(index, 1);
    if (index < player.index) player.index -= 1;
    renderQueue();
  });
  const share = document.createElement('ytmusic-menu-service-item-renderer');
  share.textContent = 'Share';
  share.data = { serviceEndpoint: { shareEndpoint: {} } };
  document.body.append(share, remove);
}

// MARK: Lyrics (the test server answers with invented timed lines)

function fetchLyrics(id) {
  fetch('/youtubei/v1/browse?prettyPrint=false', { method: 'POST', body: JSON.stringify({ browseId: 'MPLYt_' + id }) })
    .then((response) => response.json())
    .catch(() => null);
}

// MARK: A quiet tone (one second of a sine, looped)

function toneURL() {
  const rate = 22050;
  const samples = rate;
  const buffer = new ArrayBuffer(44 + samples * 2);
  const view = new DataView(buffer);
  const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
  text(0, 'RIFF'); view.setUint32(4, 36 + samples * 2, true); text(8, 'WAVE');
  text(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  text(36, 'data'); view.setUint32(40, samples * 2, true);
  for (let i = 0; i < samples; i += 1) view.setInt16(44 + i * 2, Math.round(Math.sin((2 * Math.PI * 220 * i) / rate) * 1200), true);
  return URL.createObjectURL(new Blob([buffer], { type: 'audio/wav' }));
}

// MARK: Start

renderGuide();
window.addEventListener('popstate', render);
render();
const params = new URLSearchParams(location.search);
if (location.pathname === '/watch' && SONGS[params.get('v')]) {
  const list = PLAYLISTS[params.get('list')];
  const queue = list ? list.songs : START_QUEUE;
  load(queue, Math.max(0, queue.indexOf(params.get('v'))), { list: list ? params.get('list') : null });
}
