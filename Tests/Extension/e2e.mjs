// The browser bridge end to end, without the user's browser:
//
// 1. Ahenk runs `--smoke --smoke-only bridgeLive` on a spare port: its own
//    bridge server and hub, waiting for a browser (BridgeCheck.runLive).
// 2. A headless test Chromium (Playwright's own build, a throwaway profile,
//    muted) loads a copy of the unpacked extension whose default port is
//    that spare port, so it can never reach an Ahenk the user runs.
// 3. The test browser opens music.youtube.com; every request is answered
//    here from Tests/Extension/mock (a stand-in with invented songs), and
//    every other host is refused: nothing reaches the real site.
// 4. Ahenk sees the song, then drives the tab: pause, play, seek, like,
//    shuffle, repeat, next, previous, the site's lyrics, volume, the queue,
//    playlists, search and play. Its report says how it went.
// 5. All of that happened in the one page that was opened: no other page
//    was loaded and the site never asked whether to leave. A page Ahenk
//    does load over one that plays is not asked about either, while one
//    anybody else loads still is.
//
//   cd Tests/Extension && npm install && node e2e.mjs      (Scripts/bridge-e2e.sh does this)
//   AHENK_APP=/path/Ahenk.app AHENK_E2E_PORT=45210 node e2e.mjs
//   AHENK_E2E_SHOTS=/tmp/shots node e2e.mjs   also a picture of the extension's popup
//                              (in the test browser; in the Mac's language)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const mock = fileURLToPath(new URL('./mock/', import.meta.url));
const app = process.env.AHENK_APP || join(repository, 'dist/Ahenk.app');
const port = Number(process.env.AHENK_E2E_PORT) || 45_100 + Math.floor(Math.random() * 400);
const waitForBrowser = 60;
const shots = process.env.AHENK_E2E_SHOTS;
const extensionID = 'goajefoldohohgnmcfkpkembdpjbpfde';
const report = join(homedir(), 'Library/Logs/Ahenk/smoke.json');
const LYRICS = [
  [5, 'Salt on the window, morning in the wires'],
  [9.5, 'Every lantern hums a borrowed tune'],
  [14, 'We row the harbor home'],
  [19, 'Paper boats and porch lights'],
];

function log(text) {
  console.log(`[e2e] ${text}`);
}

function fail(text) {
  console.error(`[e2e] FAILED: ${text}`);
  process.exitCode = 1;
}

if (!existsSync(join(app, 'Contents/MacOS/Ahenk'))) {
  console.error(`[e2e] ${app} not found; run ./Scripts/make-app.sh first.`);
  process.exit(1);
}
if (port >= 42_617 && port <= 42_620) {
  console.error('[e2e] pick a port outside the default range (42617–42620).');
  process.exit(1);
}

// The extension, with the test port as its default.
const scratch = mkdtempSync(join(tmpdir(), 'ahenk-e2e-'));
const extension = join(scratch, 'extension');
const profile = join(scratch, 'profile');
cpSync(join(repository, 'Extension'), extension, { recursive: true, filter: (path) => !path.includes('/firefox') });
const protocolFile = join(extension, 'lib/protocol.js');
const protocol = readFileSync(protocolFile, 'utf8');
const patched = protocol.replace(/const DEFAULT_PORT = \d+;/, `const DEFAULT_PORT = ${port};`);
if (patched === protocol) throw new Error('lib/protocol.js has no DEFAULT_PORT to change');
writeFileSync(protocolFile, patched);

// The test browser first (if it cannot start, no Ahenk waits for it).
let context;
try {
  context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium', // the full browser in its new headless mode, which loads extensions
    headless: true,
    args: [
      `--disable-extensions-except=${extension}`,
      `--load-extension=${extension}`,
      '--autoplay-policy=no-user-gesture-required',
      '--mute-audio',
      '--no-first-run',
    ],
  });
} catch (error) {
  rmSync(scratch, { recursive: true, force: true });
  throw error;
}

// Ahenk's side.
const before = existsSync(report) ? statSync(report).mtimeMs : 0;
log(`Ahenk: ${app} --smoke --smoke-only bridgeLive --bridge-port ${port}`);
const ahenk = spawn('/usr/bin/open', ['-W', '-n', app, '--args', '--smoke', '--smoke-only', 'bridgeLive', '--bridge-port', String(port), '--bridge-wait', String(waitForBrowser)], { stdio: 'inherit' });
const ahenkDone = new Promise((resolve) => ahenk.on('exit', resolve));

try {
  await context.route('**/*', async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    // The extension's own pages load their files; the web is refused.
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return route.continue();
    if (url.hostname !== 'music.youtube.com') return route.abort('blockedbyclient');
    if (url.pathname === '/youtubei/v1/browse') {
      const browseId = JSON.parse(request.postData() || '{}').browseId || '';
      const lines = LYRICS.map(([start, line], i) => ({
        lyricLine: line,
        cueRange: { startTimeMilliseconds: String(start * 1000), endTimeMilliseconds: String((LYRICS[i + 1] ? LYRICS[i + 1][0] : start + 4) * 1000) },
      }));
      const body = browseId.startsWith('MPLYt_') ? { contents: { sectionListRenderer: { contents: [{ timedLyricsRenderer: { timedLyricsData: lines } }] } } } : {};
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
    }
    if (url.pathname === '/mock-site.js') return route.fulfill({ status: 200, contentType: 'text/javascript', path: join(mock, 'mock-site.js') });
    if (url.pathname.startsWith('/mock-cover/') || url.pathname === '/favicon.ico') return route.fulfill({ status: 404, body: '' });
    return route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', path: join(mock, 'index.html') });
  });

  const page = await context.newPage();
  page.on('pageerror', (error) => log(`page error: ${error.message}`));
  page.on('console', (message) => {
    if (message.type() === 'error' && !/Failed to load resource/.test(message.text())) log(`page console: ${message.text()}`);
  });
  // Pages loaded, and the times the site asked whether to leave (answered
  // with "stay", so a question also keeps the page).
  let loads = 0;
  let questions = 0;
  page.on('load', () => { loads += 1; });
  page.on('dialog', (dialog) => {
    if (dialog.type() === 'beforeunload') questions += 1;
    dialog.dismiss().catch(() => {});
  });
  await page.goto('https://music.youtube.com/watch?v=ahenkMock01');
  // A browser asks before leaving only a page that was clicked in.
  await page.mouse.click(400, 200);
  log('the mock site is open in the test browser');
  const pictured = shots ? picturePopup() : Promise.resolve();

  const limit = (waitForBrowser + 90) * 1000;
  const finished = await Promise.race([ahenkDone.then(() => true), new Promise((resolve) => setTimeout(() => resolve(false), limit))]);
  if (!finished) fail(`Ahenk did not finish within ${limit / 1000} s`);
  log(`the page ends on ${page.url()}`);
  if (finished) {
    if (loads !== 1 || questions !== 0) fail(`Ahenk's picks loaded ${loads - 1} more page(s) and the site asked to leave ${questions} time(s); expected neither`);
    else log('every pick was shown in the one page; the site never asked whether to leave');
    // The site does ask about a page somebody else loads over it …
    await page.evaluate(() => { location.assign('/search?q=asked'); });
    await page.waitForTimeout(1500);
    if (questions !== 1 || loads !== 1) fail(`the mock site did not ask before leaving (${questions} question(s), ${loads} load(s)); the check above proves nothing`);
    // … and not about one Ahenk's engine says it loads.
    await page.evaluate(() => { window.__ahenkHooks.leaveQuietly(); location.assign('/search?q=quiet'); });
    await page.waitForURL('**/search?q=quiet', { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(500);
    if (questions !== 1 || loads !== 2 || !page.url().endsWith('/search?q=quiet')) fail(`a page Ahenk loads was held up (${questions} question(s), ${loads} load(s), at ${page.url()})`);
    else log('a page Ahenk loads is not asked about; one loaded by anybody else is');
  }
  await pictured;
} finally {
  await context.close().catch(() => {});
  rmSync(scratch, { recursive: true, force: true });
}

// The toolbar popup, opened as a page of its own once the tab is reported.
async function picturePopup() {
  await new Promise((resolve) => setTimeout(resolve, 1200));
  const popup = await context.newPage();
  await popup.setViewportSize({ width: 300, height: 400 });
  await popup.goto(`chrome-extension://${extensionID}/popup/popup.html`);
  await popup.waitForTimeout(400);
  await popup.locator('details').evaluate((element) => { element.open = true; });
  const file = join(shots, 'popup.png');
  await popup.screenshot({ path: file, fullPage: true });
  log(`popup pictured: ${file}`);
  await popup.close();
}

// Ahenk's report.
if (!existsSync(report) || statSync(report).mtimeMs <= before) {
  fail(`${report} was not written`);
} else {
  const result = JSON.parse(readFileSync(report, 'utf8'));
  const live = (result.subsystems || []).find((entry) => entry.name === 'bridgeLive');
  if (!live) {
    fail('the report has no bridgeLive entry');
  } else {
    log(`bridgeLive: ${live.status} (${Math.round(live.milliseconds)} ms)`);
    for (const step of String(live.detail).split('; ')) log(`  ${step}`);
    if (live.status !== 'ok') fail('the live bridge check failed');
  }
}
if (!process.exitCode) log('passed');
