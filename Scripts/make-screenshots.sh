#!/usr/bin/env bash
# Draws the README's pictures into docs/screenshots from Ahenk's own views,
# offscreen, with the demo's invented songs and generated covers: a smoke
# run with snapshots, then the gallery check composes them. Nothing of the
# screen is captured and nothing appears on it.
#
#   ./Scripts/make-screenshots.sh            use the existing dist/Ahenk.app
#   ./Scripts/make-screenshots.sh --build    build it first
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Ahenk.app"
OUT="docs/screenshots"
if [ "${1:-}" = "--build" ]; then ./Scripts/make-app.sh; fi
[ -d "$APP" ] || { echo "ERROR: $APP not found; run ./Scripts/make-app.sh first." >&2; exit 1; }

SNAPSHOTS="$(mktemp -d)"
trap 'rm -rf "$SNAPSHOTS"' EXIT
mkdir -p "$OUT"
REPORT="$HOME/Library/Logs/Ahenk/smoke.json"
rm -f "$REPORT"
open -W -n "$APP" --args --smoke --smoke-only nowPlaying,lyrics,onboarding,settingsWindow,gallery \
  --snapshots "$SNAPSHOTS" --gallery "$PWD/$OUT"
[ -f "$REPORT" ] || { echo "ERROR: $REPORT was not written." >&2; exit 1; }
/usr/bin/plutil -p "$REPORT" | grep -B2 -A1 '"gallery"' || true
[ "$(/usr/bin/plutil -extract ok raw -o - "$REPORT")" = "true" ] || { echo "ERROR: the gallery run failed (see $REPORT)." >&2; exit 1; }
# The app icon, as make-app.sh drew it.
if [ -f dist/.icon/AppIcon.png ]; then
  sips -z 256 256 dist/.icon/AppIcon.png --out "$OUT/icon.png" >/dev/null
fi
ls -l "$OUT"
