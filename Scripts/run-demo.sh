#!/usr/bin/env bash
# Builds dist/Ahenk.app and launches it in demo mode: invented songs,
# generated covers, invented lyric lines and a synthetic 120 BPM beat flow
# through the real pipeline, so no music or permissions are needed.
#
#   ./Scripts/run-demo.sh                      build, then launch
#   ./Scripts/run-demo.sh --no-build           launch the existing build
#   ./Scripts/run-demo.sh --settings light     extra arguments go to Ahenk
#
# A running Ahenk is quit first (only Ahenk). Quit the demo with
# `pkill -x Ahenk` or from the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Ahenk.app"
BUILD=1
ARGS=()
for argument in "$@"; do
  if [ "$argument" = "--no-build" ]; then BUILD=0; else ARGS+=("$argument"); fi
done

if [ "$BUILD" = "1" ]; then
  ./Scripts/make-app.sh
fi
[ -d "$APP" ] || { echo "ERROR: $APP not found; run without --no-build." >&2; exit 1; }

if pgrep -x Ahenk >/dev/null; then
  echo "==> Quitting the running Ahenk"
  pkill -TERM -x Ahenk || true
  for _ in $(seq 1 25); do
    pgrep -x Ahenk >/dev/null || break
    sleep 0.2
  done
fi

echo "==> Launching $APP in demo mode"
# Launched through LaunchServices so macOS attributes permissions to Ahenk.
open -n "$APP" --args --demo ${ARGS[@]+"${ARGS[@]}"}
echo "Log: ~/Library/Logs/Ahenk/Ahenk.log"
