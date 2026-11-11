// An extension that is reloaded or updated while a music tab plays, without
// the user's browser and without Ahenk:
//
// 1. A stand-in for Ahenk listens on a spare port (one WebSocket, the
//    bridge's own messages) and welcomes the extension.
// 2. A headless test Chromium (Playwright's own build, a throwaway profile,
//    muted) loads a copy of the unpacked extension and opens the mock music
//    site of e2e.mjs (Tests/Extension/mock); nothing reaches a real site.
// 3. The extension puts its scripts into the open page again, as it does
//    after a reload or an update. The page is not loaded: the scripts that
//    came take over from the ones the page held, the tab is reported
//    again, and a command and a pick are carried out once each.
// 4. The stand-in then says it carries a newer extension: the extension
//    takes itself up again.
//
//   cd Tests/Extension && node takeover.mjs      (Scripts/bridge-e2e.sh runs it after e2e.mjs)
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const mock = fileURLToPath(new URL('./mock/', import.meta.url));
const port = Number(process.env.AHENK_E2E_PORT) || 45_600 + Math.floor(Math.random() * 300);
const own = JSON.parse(readFileSync(join(repository, 'Extension/manifest.json'), 'utf8')).version;

const log = (text) => console.log(`[takeover] ${text}`);
function fail(text) {
  console.error(`[takeover] FAILED: ${text}`);
  process.exitCode = 1;
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(read, timeout, step = 100) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = read();
    if (value || Date.now() >= end) return value;
    await sleep(step);
  }
}

// MARK: A stand-in for Ahenk (the newest connection, text frames)

const seen = { hellos: 0, tab: null, results: new Map(), shipped: own };
let socket = null;

function frame(text) {
  const payload = Buffer.from(text);
  if (payload.length < 126) return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
  return Buffer.concat([Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xff]), payload]);
}
const send = (message) => socket && !socket.destroyed && socket.write(frame(JSON.stringify(message)));

function received(message) {
  if (message.type === 'hello') {
    seen.hellos += 1;
    seen.tab = null;
    send({ type: 'welcome', protocol: 1, app: 'Ahenk', appVersion: 'takeover-check', extensionVersion: seen.shipped, heartbeat: 20 });
  } else if (message.type === 'ping') send({ type: 'pong' });
  else if (message.type === 'tab') seen.tab = message.tab;
  else if (message.type === 'tabs' && message.tabs.length) seen.tab = message.tabs[0];
  else if (message.type === 'tabRemoved' && seen.tab && seen.tab.tabId === message.tabId) seen.tab = null;
  else if (message.type === 'result') seen.results.set(message.id, (seen.results.get(message.id) || []).concat(message));
}

const server = createServer();
server.on('upgrade', (request, connection) => {
  const accept = createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  connection.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket = connection;
  let buffered = Buffer.alloc(0);
  let fragments = [];
  connection.on('error', () => {});
  connection.on('data', (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 2) {
      const fin = (buffered[0] & 0x80) !== 0;
      const opcode = buffered[0] & 0x0f;
      const masked = (buffered[1] & 0x80) !== 0;
      let length = buffered[1] & 0x7f;
      let at = 2;
      if (length === 126) {
        if (buffered.length < 4) return;
        length = buffered.readUInt16BE(2);
        at = 4;
      } else if (length === 127) {
        if (buffered.length < 10) return;
        length = Number(buffered.readBigUInt64BE(2));
        at = 10;
      }
      const need = at + (masked ? 4 : 0) + length;
      if (buffered.length < need) return;
      let payload = Buffer.from(buffered.subarray(at + (masked ? 4 : 0), need));
      if (masked) {
        const mask = buffered.subarray(at, at + 4);
        for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      }
      buffered = buffered.subarray(need);
      if (opcode === 8) return;
      if (opcode === 9 || opcode === 10) continue;
      fragments.push(payload);
      if (!fin) continue;
      const text = Buffer.concat(fragments).toString('utf8');
      fragments = [];
      try {
        received(JSON.parse(text));
      } catch {
        // Not a message of the bridge.
      }
    }
  });
});
await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));

let nextID = 1;
/** Sends a command or a request to the reported tab; the answers that came within `quiet` ms after the first. */
async function ask(body, timeout = 20000, quiet = 1200) {
  const id = `t${nextID++}`;
  send({ id, tabId: seen.tab && seen.tab.tabId, ...body });
  if (!(await until(() => seen.results.get(id), timeout))) return [];
  await sleep(quiet);
  return seen.results.get(id);
}

// MARK: The test browser with the extension

const scratch = mkdtempSync(join(tmpdir(), 'ahenk-takeover-'));
const extension = join(scratch, 'extension');
cpSync(join(repository, 'Extension'), extension, { recursive: true, filter: (path) => !path.includes('/firefox') });
const protocolFile = join(extension, 'lib/protocol.js');
const protocol = readFileSync(protocolFile, 'utf8');
const patched = protocol.replace(/const DEFAULT_PORT = \d+;/, `const DEFAULT_PORT = ${port};`);
if (patched === protocol) throw new Error('lib/protocol.js has no DEFAULT_PORT to change');
writeFileSync(protocolFile, patched);

const context = await chromium.launchPersistentContext(join(scratch, 'profile'), {
  channel: 'chromium',
  headless: true,
  args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`, '--autoplay-policy=no-user-gesture-required', '--mute-audio', '--no-first-run'],
});
const worker = () => context.serviceWorkers()[0];

try {
  await context.route('**/*', async (route) => {
    const url = new URL(route.request().url());
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return route.continue();
    if (url.hostname !== 'music.youtube.com') return route.abort('blockedbyclient');
    if (url.pathname === '/youtubei/v1/browse') return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    if (url.pathname === '/mock-site.js') return route.fulfill({ status: 200, contentType: 'text/javascript', path: join(mock, 'mock-site.js') });
    if (url.pathname.startsWith('/mock-cover/') || url.pathname === '/favicon.ico') return route.fulfill({ status: 404, body: '' });
    return route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', path: join(mock, 'index.html') });
  });
  const page = await context.newPage();
  page.on('pageerror', (error) => log(`page error: ${error.message}`));
  let loads = 0;
  page.on('load', () => { loads += 1; });
  page.on('dialog', (dialog) => dialog.dismiss().catch(() => {}));
  await page.goto('https://music.youtube.com/watch?v=ahenkMock01');
  await page.mouse.click(400, 200);

  if (!(await until(() => seen.tab && seen.tab.title === 'Velvet Harbor Lights' && seen.tab.state === 'playing', 20000))) {
    fail(`the tab was not reported playing (${seen.hellos} hello(s), tab ${JSON.stringify(seen.tab)}, engine ${await page.evaluate(() => typeof window.__ahenkEngine)})`);
  } else {
    log(`extension ${own} reports the tab: “${seen.tab.title}”, ${seen.tab.state}`);

    // 3. The extension's scripts come into the page again, as after a
    //    reload or an update.
    const engineBefore = await page.evaluate(() => window.__ahenkEngine);
    seen.tab = null;
    await worker().evaluate(() => injectIntoOpenTabs(false));
    const back = await until(() => seen.tab && seen.tab.title === 'Velvet Harbor Lights', 10000);
    const replaced = await page.evaluate((before) => window.__ahenkEngine !== before && typeof window.__ahenkEngine.retire === 'function', engineBefore);
    if (!back || !replaced) {
      fail(`the scripts that came again did not take the page over (reported again: ${!!back}, engine replaced: ${replaced})`);
    } else {
      log('the scripts came into the open page again and took it over; the tab is reported by them');
      const paused = await ask({ type: 'command', command: 'pause' });
      const isPaused = await until(() => seen.tab && seen.tab.state === 'paused', 5000);
      if (paused.length !== 1 || !paused[0].ok || !isPaused) fail(`pause after the takeover: ${paused.length} answer(s) ${JSON.stringify(paused[0] || null)}, tab ${seen.tab && seen.tab.state}`);
      else log('a command is carried out, and answered once');

      const picked = await ask({ type: 'request', request: 'play', site: 'youtubeMusic', song: { title: 'Saffron Static', artist: 'Kestrel & Vale', trackId: 'ahenkMock03' } });
      const plays = await until(() => seen.tab && seen.tab.title === 'Saffron Static' && seen.tab.state === 'playing', 8000);
      if (picked.length !== 1 || picked[0].outcome !== 'started' || !plays) fail(`a pick after the takeover: ${picked.length} answer(s) ${JSON.stringify(picked[0] || null)}, tab ${JSON.stringify(seen.tab && [seen.tab.title, seen.tab.state])}`);
      else log('a pick starts, and is answered once');
      if (loads !== 1) fail(`the page was loaded ${loads - 1} more time(s)`);
      else log('all of it in the page that was open');
    }

    // 4. Ahenk carries a newer extension: this one takes itself up again
    //    (a test browser does not bring back an extension named on its
    //    command line, so the reload is seen as the extension going away;
    //    "once per version" is `C.takesUpNewer`, tested in common.test.mjs).
    seen.shipped = '99.0.0';
    const hellosThen = seen.hellos;
    socket.destroy();
    const told = await until(() => seen.hellos > hellosThen, 15000);
    const gone = told && (await until(() => !worker(), 10000));
    if (!told) fail('the extension did not come back to hear of the newer version');
    else if (!gone) fail('told that Ahenk carries a newer extension, this one did not take itself up again');
    else log('told that Ahenk carries a newer extension, it took itself up again');
  }
} finally {
  await context.close().catch(() => {});
  server.close();
  if (socket) socket.destroy();
  rmSync(scratch, { recursive: true, force: true });
}
if (!process.exitCode) log('passed');
