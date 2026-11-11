// The extension's files as one number, with the version they were
// released as (fingerprint.json). A browser that keeps the extension goes
// on running what it read until the version goes up: Ahenk tells an older
// extension apart by its version alone, and can only say "reload it" then.
// So a change to the extension's files without a higher version is refused
// (version.test.mjs).
//
//   node Tests/Extension/fingerprint.mjs            prints the current one
//   node Tests/Extension/fingerprint.mjs --write    records it, once the version was raised
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const folder = join(repository, 'Extension');
export const recordFile = join(repository, 'Tests/Extension/fingerprint.json');

function files(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.name !== '.DS_Store')
    .flatMap((entry) => (entry.isDirectory() ? files(join(directory, entry.name)) : [join(directory, entry.name)]));
}

/** `{ version, sha256 }` of Extension/ as it is now. */
export function current() {
  const hash = createHash('sha256');
  for (const file of files(folder).sort()) {
    hash.update(relative(folder, file));
    hash.update('\0');
    hash.update(readFileSync(file));
    hash.update('\0');
  }
  const version = JSON.parse(readFileSync(join(folder, 'manifest.json'), 'utf8')).version;
  return { version, sha256: hash.digest('hex') };
}

export function recorded() {
  return JSON.parse(readFileSync(recordFile, 'utf8'));
}

/** Numbers of "1.5.0", for comparing. */
export function numbers(version) {
  return String(version).split('.').map(Number);
}

export function isNewer(a, b) {
  const [x, y] = [numbers(a), numbers(b)];
  for (let i = 0; i < 3; i += 1) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  return false;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const now = current();
  if (!process.argv.includes('--write')) {
    console.log(JSON.stringify(now, null, 2));
  } else {
    let before = null;
    try {
      before = recorded();
    } catch {
      // The first record.
    }
    if (before && before.sha256 !== now.sha256 && !isNewer(now.version, before.version)) {
      console.error(`The extension's files changed but its version is still ${now.version}. Raise it first: Extension/manifest.json, Extension/firefox/manifest.json and ExtensionVersion.shipped.`);
      process.exit(1);
    }
    writeFileSync(recordFile, JSON.stringify(now, null, 2) + '\n');
    console.log(`recorded ${now.version} ${now.sha256.slice(0, 12)}`);
  }
}
