#!/usr/bin/env bash
# The browser bridge end to end with a headless test browser: Ahenk's live
# bridge check (--smoke --smoke-only bridgeLive) drives a mock music site in
# Playwright's own Chromium with the unpacked extension (Tests/Extension/e2e.mjs).
# Never touches the user's browsers or their profiles; the test browser is
# muted, uses a throwaway profile and is closed at the end.
#
#   ./Scripts/bridge-e2e.sh            uses dist/Ahenk.app (./Scripts/make-app.sh first)
#   ./Scripts/bridge-e2e.sh --build    builds it first
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${1:-}" = "--build" ] && ./Scripts/make-app.sh
command -v node >/dev/null || { echo "ERROR: node is not installed." >&2; exit 1; }
cd Tests/Extension
if [ ! -d node_modules/playwright ]; then
  npm install --no-audit --no-fund
fi
# Playwright's own Chromium build (cached in ~/Library/Caches/ms-playwright).
npx --no-install playwright install chromium
exec node e2e.mjs
