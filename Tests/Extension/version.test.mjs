// A change to the extension goes out under a higher version (see
// fingerprint.mjs for why).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { current, recorded, isNewer } from './fingerprint.mjs';

const repository = fileURLToPath(new URL('../../', import.meta.url));

test("the extension's files are the ones recorded for its version", () => {
  const now = current();
  const before = recorded();
  if (now.sha256 === before.sha256) {
    assert.equal(now.version, before.version, 'the version changed without the record: node Tests/Extension/fingerprint.mjs --write');
    return;
  }
  assert.ok(
    isNewer(now.version, before.version),
    `The extension's files changed but its version is still ${now.version}: browsers that have it would keep the old scripts and Ahenk could not tell. `
      + 'Raise the version in Extension/manifest.json, Extension/firefox/manifest.json and ExtensionVersion.shipped, then run: node Tests/Extension/fingerprint.mjs --write',
  );
  assert.fail(`Version ${now.version} is not recorded yet: node Tests/Extension/fingerprint.mjs --write`);
});

test('both manifests carry the same version', () => {
  const chromium = JSON.parse(readFileSync(`${repository}Extension/manifest.json`, 'utf8'));
  const firefox = JSON.parse(readFileSync(`${repository}Extension/firefox/manifest.json`, 'utf8'));
  assert.equal(chromium.version, firefox.version);
  assert.deepEqual(chromium.content_scripts, firefox.content_scripts, 'the same scripts in the same pages');
});
