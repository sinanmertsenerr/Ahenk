// Ahenk browser bridge: the toolbar popup (connection status, the music
// tabs Ahenk sees, the port).
'use strict';
const ext = globalThis.browser || globalThis.chrome;
const t = (key, ...values) => ext.i18n.getMessage(key, values.map(String)) || key;

const SITE_NAMES = {
  youtubeMusic: 'YouTube Music',
  youtube: 'YouTube',
  spotify: 'Spotify',
  soundCloud: 'SoundCloud',
  amazonMusic: 'Amazon Music',
  deezer: 'Deezer',
  tidal: 'TIDAL',
};

for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = t(element.dataset.i18n);
document.documentElement.lang = ext.i18n.getUILanguage();

function render(status) {
  const dot = document.getElementById('dot');
  dot.className = 'dot ' + (status ? status.status : 'idle');
  const title = document.getElementById('statusTitle');
  const detail = document.getElementById('statusDetail');
  if (status && status.status === 'open') {
    title.textContent = t('statusOpen');
    detail.textContent = status.newerVersion ? t('newerVersion', status.newerVersion) : t('listeningOn', status.port);
  } else if (status && status.status === 'connecting') {
    title.textContent = t('statusConnecting');
    detail.textContent = '';
  } else {
    title.textContent = t('statusIdle');
    detail.textContent = t('hintIdle');
  }
  const list = document.getElementById('tabs');
  list.textContent = '';
  const tabs = (status && status.tabs) || [];
  if (!tabs.length) {
    const empty = document.createElement('li');
    empty.className = 'empty';
    empty.textContent = t('noTabs');
    list.append(empty);
  }
  for (const tab of tabs) {
    const item = document.createElement('li');
    const song = document.createElement('span');
    song.className = 'song';
    song.textContent = [tab.title, tab.artist].filter(Boolean).join(' — ');
    const meta = document.createElement('span');
    meta.className = 'meta';
    meta.textContent = [SITE_NAMES[tab.site] || tab.site, t(tab.state === 'playing' ? 'playing' : 'paused')].join(' · ');
    item.append(song, meta);
    list.append(item);
  }
  const port = document.getElementById('port');
  if (status && document.activeElement !== port) port.value = status.basePort;
}

function refresh() {
  ext.runtime.sendMessage({ kind: 'popup-status' }).then(render).catch(() => render(null));
}

document.getElementById('portForm').addEventListener('submit', (event) => {
  event.preventDefault();
  const value = Number(document.getElementById('port').value);
  if (!Number.isInteger(value) || value < 1024 || value > 49151) return;
  ext.storage.local.set({ basePort: value }).then(() => setTimeout(refresh, 600));
});
document.getElementById('retry').addEventListener('click', () => {
  ext.runtime.sendMessage({ kind: 'popup-reconnect' }).catch(() => {});
  setTimeout(refresh, 800);
});

refresh();
setInterval(refresh, 1500);
