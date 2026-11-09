// Loads the extension's pure scripts (plain browser scripts that attach
// themselves to globalThis) for node --test.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const repository = fileURLToPath(new URL('../../', import.meta.url));

export function load() {
  require('../../Extension/lib/common.js');
  require('../../Extension/lib/protocol.js');
  require('../../Extension/lib/lyrics.js');
  return { C: globalThis.AhenkCommon, P: globalThis.AhenkProtocol, L: globalThis.AhenkLyrics };
}

/** A shared fixture from Tests/Fixtures/bridge (the Swift tests read them too). */
export function fixture(name) {
  return JSON.parse(readFileSync(`${repository}Tests/Fixtures/bridge/${name}.json`, 'utf8'));
}
