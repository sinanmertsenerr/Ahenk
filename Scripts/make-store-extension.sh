#!/usr/bin/env bash
# Packs the Chromium extension for the Chrome Web Store:
# dist/Ahenk-extension-chrome-<version>.zip, with manifest.json at the top.
#
# The store refuses a manifest with a `key` (it signs the extension with its
# own key and gives it its own ID), so the copy in the archive has none. The
# `key` stays in Extension/manifest.json for folders loaded unpacked.
#
#   ./Scripts/make-store-extension.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -f Extension/manifest.json ] || fail "Extension/manifest.json not found"
VERSION="$(/usr/bin/plutil -extract version raw -o - Extension/manifest.json)"
OUT="$PWD/dist/Ahenk-extension-chrome-$VERSION.zip"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

rsync -a --exclude 'firefox/' --exclude '.DS_Store' Extension/ "$STAGING/"
# The key is one line of its own; dropping the line keeps the rest as written.
grep -v '^  "key": ' Extension/manifest.json > "$STAGING/manifest.json"
/usr/bin/plutil -extract manifest_version raw -o /dev/null "$STAGING/manifest.json" || fail "the manifest without its key is not valid JSON"
! /usr/bin/plutil -extract key raw -o /dev/null "$STAGING/manifest.json" 2>/dev/null || fail "the manifest still has a key"

mkdir -p dist
rm -f "$OUT"
(cd "$STAGING" && zip -q -r -X "$OUT" .)
echo "Built $OUT"
unzip -l "$OUT" | tail -1 | sed 's/^/    /'
