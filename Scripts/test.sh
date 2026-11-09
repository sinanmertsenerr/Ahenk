#!/usr/bin/env bash
# Runs every check that needs no app launch: plist and strings lint, script
# syntax, the browser extension's own tests (node --test), then the unit
# tests (including the localization coverage tests).
# Extra arguments go to `swift test` (e.g. --filter AppSettings).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Lint property lists and strings"
plutil -lint -s Packaging/Info.plist Packaging/Ahenk.entitlements Packaging/*.lproj/InfoPlist.strings \
  Sources/AhenkApp/Resources/*.lproj/*.strings

echo "==> Check script syntax"
for script in Scripts/*.sh; do
  bash -n "$script"
done

echo "==> Browser extension: script syntax and node --test"
if command -v node >/dev/null; then
  for script in Extension/*.js Extension/*/*.js; do
    node --check "$script"
  done
  for manifest in Extension/manifest.json Extension/firefox/manifest.json Extension/_locales/*/messages.json; do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$manifest"
  done
  node --test "Tests/Extension/*.test.mjs"
else
  echo "node is not installed; the extension's tests were skipped." >&2
fi

echo "==> swift test"
# swift-testing lives in the active developer directory. A full Xcode finds it
# on its own; a Command Line Tools install needs the search paths added.
DEV="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
if [[ "$DEV" == *CommandLineTools* ]] && [ -d "$FW/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" "$@"
else
  exec swift test "$@"
fi
