#!/usr/bin/env bash
# Launches dist/Ahenk.app with --smoke, waits for it to exit and prints
# ~/Library/Logs/Ahenk/smoke.json. Exits non-zero when any subsystem failed.
#
#   ./Scripts/smoke.sh                 smoke the existing dist/Ahenk.app
#   ./Scripts/smoke.sh --build         build first
#   ./Scripts/smoke.sh --snapshots     also save PNGs of every Settings pane
#                                      in ~/Library/Logs/Ahenk/snapshots
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Ahenk.app"
REPORT="$HOME/Library/Logs/Ahenk/smoke.json"
ARGS=()
for argument in "$@"; do
  case "$argument" in
    --build) ./Scripts/make-app.sh ;;
    *) ARGS+=("$argument") ;;
  esac
done
[ -d "$APP" ] || { echo "ERROR: $APP not found; run ./Scripts/make-app.sh first." >&2; exit 1; }

rm -f "$REPORT"
echo "==> open -W -n $APP --args --smoke ${ARGS[*]+"${ARGS[*]}"}"
open -W -n "$APP" --args --smoke ${ARGS[@]+"${ARGS[@]}"}

[ -f "$REPORT" ] || { echo "ERROR: $REPORT was not written." >&2; exit 1; }
/usr/bin/plutil -p "$REPORT" | sed -n '/subsystems/,$p'
if [ "$(/usr/bin/plutil -extract ok raw -o - "$REPORT")" = "true" ]; then
  echo "Smoke test passed."
else
  echo "Smoke test FAILED (see $REPORT)." >&2
  exit 1
fi
