// Ahenk browser bridge, background (Chrome's service worker, Firefox's
// event page): keeps one WebSocket to Ahenk on this Mac (127.0.0.1, the
// first port of a small range that answers as Ahenk), reports the music
// tabs, and passes Ahenk's commands and requests to them.
//
// MV3 rules: the worker sleeps when idle, so the socket sends a ping every
// 20 s (Chrome 116+ counts WebSocket traffic as activity), the music tabs
// beat every 20 s, and an alarm wakes the worker every 30 s to reconnect.
'use strict';

if (typeof importScripts === 'function') {
  importScripts('lib/common.js', 'lib/protocol.js');
}

const ext = globalThis.browser || globalThis.chrome;
const P = globalThis.AhenkProtocol;
const C = globalThis.AhenkCommon;

/** tabId → { port, state, site, windowId, active, lastActive, goneTimer } */
const tabs = new Map();
/** request id → { request, tabId, phase, waiting, timer } */
const jobs = new Map();

const bridge = {
  socket: null,
  status: 'idle', // idle, connecting, open
  port: null,
  lastFromApp: 0,
  attempt: 0,
  reconnectTimer: null,
  heartbeat: null,
  lastError: null,
  appVersion: null,
  /** The extension version the connected Ahenk carries, when it is newer than this one. */
  newerVersion: null,
};

const settings = { basePort: P.DEFAULT_PORT, profile: null, loaded: null };

function loadSettings() {
  if (!settings.loaded) {
    settings.loaded = ext.storage.local.get(['profile', 'basePort']).then(async (stored) => {
      settings.basePort = Number.isInteger(stored.basePort) ? stored.basePort : P.DEFAULT_PORT;
      settings.profile = typeof stored.profile === 'string' && stored.profile ? stored.profile : null;
      if (!settings.profile) {
        const bytes = new Uint8Array(12);
        crypto.getRandomValues(bytes);
        settings.profile = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
        await ext.storage.local.set({ profile: settings.profile });
      }
    });
  }
  return settings.loaded;
}

function browserInfo() {
  const data = navigator.userAgentData;
  const brands = data && Array.isArray(data.brands) ? data.brands.map((b) => String(b.brand)) : [];
  const meaningful = brands.filter((b) => !/not.?a.?brand/i.test(b));
  const specific = meaningful.find((b) => !/^chromium$/i.test(b));
  const agent = navigator.userAgent || '';
  let name = specific || meaningful[0] || '';
  if (!name) name = /Firefox\//.test(agent) ? 'Firefox' : /Edg\//.test(agent) ? 'Microsoft Edge' : /Chrome\//.test(agent) ? 'Chromium' : 'Browser';
  const version = (agent.match(/(?:Firefox|Edg|Chrome)\/([\d.]+)/) || [])[1];
  return { name, version, brands: meaningful };
}

// MARK: The socket

function send(message) {
  if (bridge.status !== 'open' || !bridge.socket) return false;
  try {
    bridge.socket.send(JSON.stringify(message));
    return true;
  } catch (_) {
    return false;
  }
}

async function connect() {
  if (bridge.status !== 'idle') return;
  bridge.status = 'connecting';
  clearTimeout(bridge.reconnectTimer);
  await loadSettings();
  const ports = P.ports(settings.basePort);
  const manifest = ext.runtime.getManifest();
  const hello = P.hello({
    extensionVersion: manifest.version,
    extensionOrigin: ext.runtime.getURL('').replace(/\/$/, ''),
    browser: browserInfo(),
    profile: settings.profile,
  });

  const tryPort = (index) => {
    if (index >= ports.length) {
      bridge.status = 'idle';
      scheduleReconnect();
      return;
    }
    let socket;
    try {
      socket = new WebSocket('ws://127.0.0.1:' + ports[index]);
    } catch (_) {
      tryPort(index + 1);
      return;
    }
    let welcomed = false;
    const timeout = setTimeout(() => {
      if (!welcomed) socket.close();
    }, 3000);
    socket.onopen = () => socket.send(JSON.stringify(hello));
    socket.onmessage = (event) => {
      const message = P.parse(event.data);
      if (!message) return;
      bridge.lastFromApp = Date.now();
      if (!welcomed) {
        if (P.acceptsWelcome(message)) {
          welcomed = true;
          clearTimeout(timeout);
          opened(socket, ports[index], message);
        } else if (message.type === 'error') {
          bridge.lastError = String(message.message || message.code || 'refused');
        }
        return;
      }
      fromApp(message);
    };
    socket.onclose = () => {
      clearTimeout(timeout);
      if (welcomed) closed(socket);
      else tryPort(index + 1);
    };
    socket.onerror = () => {};
  };
  tryPort(0);
}

function opened(socket, port, welcome) {
  bridge.socket = socket;
  bridge.status = 'open';
  bridge.port = port;
  bridge.attempt = 0;
  bridge.lastError = null;
  bridge.appVersion = welcome.appVersion || null;
  takeUpNewer(welcome.extensionVersion);
  const every = Math.max(5, Math.min(60, Number(welcome.heartbeat) || P.HEARTBEAT)) * 1000;
  clearInterval(bridge.heartbeat);
  bridge.heartbeat = setInterval(() => {
    if (Date.now() - bridge.lastFromApp > P.SILENCE_LIMIT * 1000) {
      socket.close();
      return;
    }
    send(P.ping());
  }, every);
  send(P.tabs(reportedTabs()));
}

// MARK: A newer extension in Ahenk's folder

/**
 * Ahenk carries the extension in its own folder and says in its welcome
 * which version that is. When it is newer than this one, the browser
 * still runs the scripts it read before Ahenk was updated: the extension
 * takes itself up again, which reads the folder afresh (loaded unpacked)
 * or installs an update the store already has. Once per version: a
 * browser that keeps a copy of its own comes back as old as before, and
 * Ahenk then tells its user to reload the extension by hand.
 */
async function takeUpNewer(shipped) {
  const own = ext.runtime.getManifest().version;
  bridge.newerVersion = C.versionNewer(shipped, own) ? String(shipped) : null;
  if (!bridge.newerVersion) return;
  try {
    const stored = await ext.storage.local.get(['reloadedFor']);
    if (!C.takesUpNewer(shipped, own, stored.reloadedFor)) return;
    await ext.storage.local.set({ reloadedFor: bridge.newerVersion });
    if (typeof ext.runtime.requestUpdateCheck === 'function') {
      try {
        await ext.runtime.requestUpdateCheck();
      } catch (_) {
        // Not from a store, or asked too often.
      }
    }
    ext.runtime.reload();
  } catch (_) {
    // Without storage the reload could repeat forever: left to the user.
  }
}

function closed(socket) {
  if (bridge.socket !== socket) return;
  clearInterval(bridge.heartbeat);
  bridge.socket = null;
  bridge.status = 'idle';
  bridge.port = null;
  // Ahenk went away: a tab it sped up or slowed down (its sound effects)
  // gets the song's own speed back.
  for (const tab of tabs.values()) {
    if (!tab.port) continue;
    try {
      tab.port.postMessage({ kind: 'command', id: 'ahenk-gone', command: 'rate', rate: 1 });
    } catch (_) {
      // The tab is gone too.
    }
  }
  scheduleReconnect();
}

function scheduleReconnect() {
  clearTimeout(bridge.reconnectTimer);
  const delay = C.backoff(bridge.attempt) * 1000;
  bridge.attempt += 1;
  bridge.reconnectTimer = setTimeout(connect, delay);
}

function reconnectNow() {
  bridge.attempt = 0;
  if (bridge.socket) {
    const socket = bridge.socket;
    closed(socket);
    socket.onclose = null;
    socket.close();
  }
  clearTimeout(bridge.reconnectTimer);
  bridge.status = 'idle';
  connect();
}

// MARK: Messages from Ahenk

function fromApp(message) {
  switch (message.type) {
    case 'ping':
      send(P.pong());
      break;
    case 'command':
      forwardCommand(message);
      break;
    case 'request':
      startJob(message);
      break;
    case 'error':
      bridge.lastError = String(message.message || message.code || '');
      break;
    default:
      break;
  }
}

function forwardCommand(message) {
  const tab = tabs.get(message.tabId);
  if (!tab || !tab.port) {
    send(P.result(message.id, false, { error: 'no such tab' }));
    return;
  }
  tab.port.postMessage({ kind: 'command', id: message.id, command: message.command, position: message.position, on: message.on, mode: message.mode, volume: message.volume, rate: message.rate });
}

// MARK: Requests that may navigate (search and play, playlists)

const JOB_TIMEOUT = 22000;

function bestTab(site) {
  let best = null;
  for (const [tabId, tab] of tabs) {
    if (tab.site !== site || !tab.port) continue;
    const score = (tab.state && tab.state.state === 'playing' ? 4 : 0) + (tab.active ? 2 : 0);
    if (!best || score > best.score || (score === best.score && (tab.lastActive || 0) > (best.lastActive || 0))) {
      best = { tabId, score, lastActive: tab.lastActive };
    }
  }
  return best ? best.tabId : null;
}

async function startJob(message) {
  const request = { request: message.request, site: message.site, song: message.song, playlistId: message.playlistId, playlistUrl: message.playlistUrl, index: message.index, volume: message.volume, from: message.from, seconds: message.seconds, videoId: message.videoId };
  let tabId = Number.isInteger(message.tabId) && tabs.has(message.tabId) ? message.tabId : bestTab(message.site);
  const job = { id: message.id, request, tabId, phase: 1, waiting: false, timer: null };
  jobs.set(job.id, job);
  job.timer = setTimeout(() => finishJob(job.id, { ok: false, outcome: 'failed', error: 'timed out' }), JOB_TIMEOUT);

  if (tabId === null) {
    if (request.request !== 'play' && request.request !== 'playPlaylist') {
      finishJob(job.id, { ok: false, outcome: 'noTab', error: 'no tab of the site' });
      return;
    }
    const song = request.song || {};
    let url = null;
    if (request.request === 'playPlaylist') url = request.playlistUrl || C.siteURL(request.site, 'home');
    else if (request.site === 'spotify' && C.spotifyTrackId(song.trackId || song.url || '')) url = C.siteURL('spotify', 'track', C.spotifyTrackId(song.trackId || song.url));
    // A video the site knows by ID opens as that video, not as a search for its title.
    else if ((request.site === 'youtube' || request.site === 'youtubeMusic') && C.youtubeVideoId(song.trackId || '')) url = C.siteURL(request.site, 'track', C.youtubeVideoId(song.trackId));
    else url = C.siteURL(request.site, 'search', C.searchQuery(song));
    if (!url) {
      finishJob(job.id, { ok: false, outcome: 'noTab' });
      return;
    }
    try {
      const created = await ext.tabs.create({ url, active: true });
      job.tabId = created.id;
      job.phase = 2;
      job.waiting = true;
    } catch (error) {
      finishJob(job.id, { ok: false, outcome: 'noTab', error: String(error && error.message) });
    }
    return;
  }
  dispatchJob(job);
}

function dispatchJob(job) {
  const tab = tabs.get(job.tabId);
  if (!tab || !tab.port) {
    job.waiting = true;
    return;
  }
  job.waiting = false;
  tab.port.postMessage({ kind: 'job', id: job.id, job: Object.assign({}, job.request, { phase: job.phase }) });
}

function finishJob(id, answer) {
  const job = jobs.get(id);
  if (!job) return;
  clearTimeout(job.timer);
  jobs.delete(id);
  send(P.result(id, !!answer.ok, Object.assign({}, answer, { tabId: job.tabId === null ? undefined : job.tabId })));
}

// MARK: Tabs

function reportedTabs() {
  const list = [];
  for (const [tabId, tab] of tabs) if (tab.state) list.push(wireState(tabId, tab));
  return list;
}

function wireState(tabId, tab) {
  return Object.assign({}, tab.state, { tabId, active: !!tab.active, lastActive: tab.lastActive || undefined });
}

function removeTab(tabId) {
  for (const job of Array.from(jobs.values())) {
    if (job.tabId === tabId) finishJob(job.id, { ok: false, outcome: 'failed', error: 'the tab closed' });
  }
  const tab = tabs.get(tabId);
  if (!tab) return;
  clearTimeout(tab.goneTimer);
  tabs.delete(tabId);
  if (tab.state) send(P.tabRemoved(tabId));
}

ext.runtime.onConnect.addListener((port) => {
  if (port.name !== 'ahenk-tab' || !port.sender || !port.sender.tab) return;
  const senderTab = port.sender.tab;
  const tabId = senderTab.id;
  const site = C.siteForURL(port.sender.url || senderTab.url || '');
  if (!site) {
    port.disconnect();
    return;
  }
  const existing = tabs.get(tabId);
  if (existing) clearTimeout(existing.goneTimer);
  const tab = existing || { state: null, lastActive: senderTab.active ? Date.now() : 0 };
  tab.port = port;
  tab.site = site;
  tab.windowId = senderTab.windowId;
  tab.active = !!senderTab.active;
  tabs.set(tabId, tab);
  connect();

  port.onMessage.addListener((message) => {
    if (!message || typeof message.kind !== 'string') return;
    switch (message.kind) {
      case 'ready':
        for (const job of jobs.values()) if (job.tabId === tabId && job.waiting) dispatchJob(job);
        break;
      case 'state': {
        const previous = tab.state;
        tab.state = Object.assign({}, message.state, { site });
        if (!previous || C.noticeableChange(previous, tab.state, Date.now()) || tab.state.state === 'playing') {
          send(P.tabUpdate(wireState(tabId, tab)));
        }
        break;
      }
      case 'gone':
        if (tab.state) {
          tab.state = null;
          send(P.tabRemoved(tabId));
        }
        break;
      case 'result':
        if (jobs.has(message.id)) finishJob(message.id, message);
        else send(P.result(message.id, !!message.ok, message.error ? { error: message.error } : undefined));
        break;
      case 'navigating': {
        const job = jobs.get(message.id);
        if (job) {
          job.phase += 1;
          job.waiting = true;
        }
        break;
      }
      case 'lyrics':
        if (Array.isArray(message.lines)) send(P.lyrics(tabId, site, message.song, message.lines, message.heard === true));
        break;
      default:
        break;
    }
  });

  port.onDisconnect.addListener(() => {
    void (ext.runtime && ext.runtime.lastError);
    if (tab.port !== port) return;
    tab.port = null;
    // A job the page was still carrying out goes on in the page that comes
    // next (a click on the site that loaded a new page, not announced).
    for (const job of jobs.values()) {
      if (job.tabId === tabId && !job.waiting) {
        job.waiting = true;
        job.phase += 1;
      }
    }
    // A reload or a navigation brings a new port at once; a closed tab does not.
    tab.goneTimer = setTimeout(() => {
      if (!tab.port) removeTab(tabId);
    }, 4000);
  });
});

ext.tabs.onRemoved.addListener((tabId) => removeTab(tabId));

ext.tabs.onActivated.addListener(({ tabId, windowId }) => {
  for (const [id, tab] of tabs) {
    if (tab.windowId !== windowId) continue;
    const active = id === tabId;
    if (tab.active === active) continue;
    tab.active = active;
    if (active) tab.lastActive = Date.now();
    if (tab.state) send(P.tabUpdate(wireState(id, tab)));
  }
});

// MARK: Waking up

ext.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'ahenk-reconnect') connect();
});

function ensureAlarm() {
  ext.alarms.create('ahenk-reconnect', { periodInMinutes: 0.5 });
}

ext.runtime.onStartup.addListener(() => {
  ensureAlarm();
  connect();
});

let installedNow = false;
ext.runtime.onInstalled.addListener(() => {
  installedNow = true;
  if (ext.storage.session) ext.storage.session.set({ tabsLookedAt: Date.now() }).catch(() => {});
  ensureAlarm();
  connect();
  injectIntoOpenTabs(false);
});

ext.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.basePort) return;
  const value = changes.basePort.newValue;
  settings.basePort = Number.isInteger(value) ? value : P.DEFAULT_PORT;
  reconnectNow();
});

/** Tabs that were open before the extension was installed, updated or
 *  reloaded get its scripts: a page that never had them (it registered its
 *  media handlers already, so commands use its own buttons until it
 *  reloads), and a page that holds the scripts of the extension before,
 *  which step down for these (see page/engine.js and content/relay.js).
 *  With `onlyUnheard`, only tabs no relay has spoken from: the background
 *  woke up and a page's relay did not come back by itself. */
async function injectIntoOpenTabs(onlyUnheard) {
  if (!ext.scripting || !ext.tabs.query) return;
  const manifest = ext.runtime.getManifest();
  const groups = manifest.content_scripts || [];
  const patterns = Array.from(new Set(groups.flatMap((group) => group.matches || [])));
  let open = [];
  try {
    open = await ext.tabs.query({ url: patterns });
  } catch (_) {
    return;
  }
  for (const tab of open) {
    // A tab put to sleep has no page to take them.
    if (tab.discarded) continue;
    if (onlyUnheard && tabs.has(tab.id) && tabs.get(tab.id).port) continue;
    for (const group of groups) {
      try {
        await ext.scripting.executeScript({ target: { tabId: tab.id }, files: group.js, world: group.world === 'MAIN' ? 'MAIN' : 'ISOLATED' });
      } catch (_) {
        // A tab that cannot take scripts (discarded, an error page).
      }
    }
  }
}

// MARK: The popup

ext.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.kind !== 'popup-status') {
    if (message && message.kind === 'popup-reconnect') reconnectNow();
    return undefined;
  }
  loadSettings().then(() => {
    sendResponse({
      status: bridge.status,
      port: bridge.port,
      basePort: settings.basePort,
      appVersion: bridge.appVersion,
      newerVersion: bridge.newerVersion,
      lastError: bridge.lastError,
      tabs: reportedTabs().map((tab) => ({ site: tab.site, title: tab.title, artist: tab.artist, state: tab.state })),
    });
  });
  return true;
});

ensureAlarm();
connect();
// A browser that does not announce a reload or an update (no onInstalled):
// the pages' old relays cannot reach this background, so nothing is heard
// from their tabs. Looked at once per load of the extension (the session's
// storage is emptied with it, and kept while the background only sleeps);
// relays that live come back within a moment.
setTimeout(async () => {
  if (installedNow || !ext.storage.session) return;
  try {
    const stored = await ext.storage.session.get(['tabsLookedAt']);
    if (stored.tabsLookedAt) return;
    await ext.storage.session.set({ tabsLookedAt: Date.now() });
  } catch (_) {
    return;
  }
  if (!installedNow) injectIntoOpenTabs(true);
}, 5000);
