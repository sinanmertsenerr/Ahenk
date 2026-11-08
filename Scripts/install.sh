#!/usr/bin/env bash
# Installs Ahenk to /Applications/Ahenk.app as a transaction: build and verify
# a staged copy first, then quit the running Ahenk (and nothing else), swap
# the verified bundle in and roll back if any step fails.
#
#   ./Scripts/install.sh               build, install, relaunch if it was running
#   ./Scripts/install.sh --open        always launch afterwards
#   ./Scripts/install.sh --no-build    install the existing dist/Ahenk.app
#   AHENK_INSTALL_ROOT=/tmp/x ./Scripts/install.sh   rehearse in a temp folder
#
# Only processes named exactly "Ahenk" are ever quit, and only for a real
# install into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Ahenk"
STAGED_APP="dist/$APP_NAME.app"
STABLE_AUTHORITY_PREFIX="Apple Development:"
BUILD=1
LAUNCH="auto"
for argument in "$@"; do
  case "$argument" in
    --no-build) BUILD=0 ;;
    --open) LAUNCH="always" ;;
    --no-open) LAUNCH="never" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

INSTALL_ROOT="${AHENK_INSTALL_ROOT:-/Applications}"
REHEARSAL=0
if [ "$INSTALL_ROOT" != "/Applications" ]; then
  # Alternate roots exist only for rehearsals; keep them inside temp folders.
  [ -d "$INSTALL_ROOT" ] || { echo "ERROR: $INSTALL_ROOT does not exist." >&2; exit 1; }
  INSTALL_ROOT="$(cd "$INSTALL_ROOT" && pwd -P)"
  case "$INSTALL_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) REHEARSAL=1 ;;
    *) echo "ERROR: AHENK_INSTALL_ROOT must be inside a temporary folder." >&2; exit 1 ;;
  esac
fi
INSTALLED_APP="$INSTALL_ROOT/$APP_NAME.app"
INCOMING_APP="$INSTALL_ROOT/.$APP_NAME.app.incoming.$$"
BACKUP_APP="$INSTALL_ROOT/.$APP_NAME.app.backup.$$"

verify_app() {
  local app="$1" authority
  codesign --verify --deep --strict "$app" || { echo "ERROR: signature check failed for $app" >&2; return 1; }
  # awk reads all input (no early exit): under pipefail an early exit would
  # kill codesign with SIGPIPE and abort the script.
  authority="$(codesign -dvv "$app" 2>&1 | awk -F= '$1 == "Authority" && !found { print $2; found = 1 }')"
  if [[ "$authority" != "$STABLE_AUTHORITY_PREFIX"* ]]; then
    if [ "${ALLOW_ADHOC:-0}" = "1" ]; then
      echo "WARNING: $app is not signed with the Apple Development identity (ALLOW_ADHOC=1)." >&2
    else
      echo "ERROR: $app is signed by '${authority:-ad hoc}', not the Apple Development identity." >&2
      echo "       Installing it would reset macOS privacy grants. Set ALLOW_ADHOC=1 to install anyway." >&2
      return 1
    fi
  fi
  echo "    $app: ${authority:-ad hoc}"
}

PHASE="none"
HAD_INSTALLED=0
rollback() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    echo "ERROR: install failed (status $status); rolling back, the installed app is unchanged." >&2
  fi
  if [ "$PHASE" = "swapped" ] || [ "$PHASE" = "moved-old" ]; then
    [ "$PHASE" = "swapped" ] && rm -rf "$INSTALLED_APP"
    if [ "$HAD_INSTALLED" = "1" ] && [ -e "$BACKUP_APP" ]; then
      mv "$BACKUP_APP" "$INSTALLED_APP" && echo "    Restored the previous $INSTALLED_APP" >&2
    fi
  fi
  rm -rf "$INCOMING_APP"
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$BUILD" = "1" ]; then
  echo "==> Building"
  if [ "${ALLOW_ADHOC:-0}" = "1" ]; then
    ./Scripts/make-app.sh
  else
    REQUIRE_STABLE_SIGNING=1 ./Scripts/make-app.sh
  fi
fi
[ -d "$STAGED_APP" ] || { echo "ERROR: $STAGED_APP not found; run without --no-build." >&2; exit 1; }

echo "==> Verifying the staged app"
verify_app "$STAGED_APP"

echo "==> Copying it next to the installed app"
ditto "$STAGED_APP" "$INCOMING_APP"
verify_app "$INCOMING_APP"

WAS_RUNNING=0
if [ "$REHEARSAL" = "0" ] && pgrep -x "$APP_NAME" >/dev/null; then
  WAS_RUNNING=1
  echo "==> Quitting the running $APP_NAME"
  # SIGTERM: Ahenk quits through its normal path and restores the desktop.
  pkill -TERM -x "$APP_NAME" || true
  for _ in $(seq 1 50); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.2
  done
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "    $APP_NAME did not quit in 10 s; forcing it." >&2
    pkill -KILL -x "$APP_NAME" || true
    sleep 1
  fi
fi

echo "==> Swapping in the new version"
if [ -e "$INSTALLED_APP" ]; then
  HAD_INSTALLED=1
  mv "$INSTALLED_APP" "$BACKUP_APP"
  PHASE="moved-old"
fi
mv "$INCOMING_APP" "$INSTALLED_APP"
PHASE="swapped"
verify_app "$INSTALLED_APP"
PHASE="done"
rm -rf "$BACKUP_APP"
trap - EXIT

echo "Installed $INSTALLED_APP"
if [ "$REHEARSAL" = "0" ]; then
  if [ "$LAUNCH" = "always" ] || { [ "$LAUNCH" = "auto" ] && [ "$WAS_RUNNING" = "1" ]; }; then
    echo "==> Launching"
    open "$INSTALLED_APP"
  fi
fi
