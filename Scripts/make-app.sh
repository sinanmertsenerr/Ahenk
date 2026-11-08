#!/usr/bin/env bash
# Builds Ahenk and assembles a signed dist/Ahenk.app:
#   Contents/MacOS/Ahenk                     the SwiftPM executable
#   Contents/Info.plist                      Packaging/Info.plist + version, build, commit
#   Contents/Resources/Ahenk_AhenkApp.bundle UI strings and shader sources
#   Contents/Resources/<lang>.lproj          localized permission texts
#   Contents/Resources/adapter/              mediaremote-adapter script + framework + LICENSE
#   Contents/Resources/LICENSE, THIRD_PARTY_NOTICES.md
#
# Signing: the stable "Apple Development" identity below, so macOS privacy
# grants (system audio, Automation) survive rebuilds. If it is missing the
# app is signed ad hoc with a loud warning (grants then reset every build).
#
#   ./Scripts/make-app.sh                    release build
#   CONFIG=debug ./Scripts/make-app.sh       faster debug build
#   SIGN_ID=<sha1|name> ./Scripts/make-app.sh
#   REQUIRE_STABLE_SIGNING=1 ./Scripts/make-app.sh   fail instead of signing ad hoc
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Ahenk"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
STAGING="$DIST/.$APP_NAME.app.staging"

# Apple Development certificate of the maintainer (SHA-1 of the signing identity).
STABLE_IDENTITY_SHA1="5977683A720BD3729B68F45D1780461EB8B8B19A"

ADAPTER_SRC="Vendor/mediaremote-adapter"
ADAPTER_SCRIPT="$ADAPTER_SRC/bin/mediaremote-adapter.pl"
ADAPTER_FW="$ADAPTER_SRC/build/MediaRemoteAdapter.framework"

warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Resolve the signing identity before building anything -----------------
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -n "${SIGN_ID:-}" ]; then
  if [ "$SIGN_ID" != "-" ] && ! printf '%s\n' "$IDENTITIES" | grep -F "$SIGN_ID" >/dev/null; then
    fail "SIGN_ID '$SIGN_ID' is not a valid code-signing identity on this Mac."
  fi
elif printf '%s\n' "$IDENTITIES" | grep "$STABLE_IDENTITY_SHA1" >/dev/null; then
  SIGN_ID="$STABLE_IDENTITY_SHA1"
else
  SIGN_ID="-"
fi
if [ "$SIGN_ID" = "-" ] && [ "${REQUIRE_STABLE_SIGNING:-0}" = "1" ]; then
  fail "The stable Apple Development identity ($STABLE_IDENTITY_SHA1) is not installed; nothing was built."
fi
SIGN_NAME="$(printf '%s\n' "$IDENTITIES" | grep -F "$SIGN_ID" | head -n1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/' || true)"

# --- Adapter framework -------------------------------------------------------
needs_adapter_build=0
if [ ! -f "$ADAPTER_FW/Versions/A/MediaRemoteAdapter" ]; then
  needs_adapter_build=1
elif [ -n "$(find "$ADAPTER_SRC/src" "$ADAPTER_SRC/include" -newer "$ADAPTER_FW/Versions/A/MediaRemoteAdapter" -type f -print -quit)" ]; then
  needs_adapter_build=1
fi
if [ "$needs_adapter_build" = "1" ]; then
  ./Scripts/build-adapter.sh
fi

# --- Build -------------------------------------------------------------------
echo "==> Building $APP_NAME ($CONFIG)"
swift build -c "$CONFIG" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)"
RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_AhenkApp.bundle"
[ -x "$BIN_DIR/$APP_NAME" ] || fail "Executable not found at $BIN_DIR/$APP_NAME"
[ -d "$RESOURCE_BUNDLE" ] || fail "Resource bundle not found at $RESOURCE_BUNDLE"

if git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
  BUILD="${BUILD:-$(git rev-list --count HEAD)}"
  COMMIT="$(git rev-parse --short HEAD)"
  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
else
  BUILD="${BUILD:-1}"
  COMMIT="unknown"
fi

# --- Assemble in a staging folder, then swap ---------------------------------
echo "==> Assembling $APP"
rm -rf "$STAGING"
S="$STAGING/Contents"
mkdir -p "$S/MacOS" "$S/Resources/adapter"
cp "$BIN_DIR/$APP_NAME" "$S/MacOS/$APP_NAME"
ditto "$RESOURCE_BUNDLE" "$S/Resources/$(basename "$RESOURCE_BUNDLE")"

cp Packaging/Info.plist "$S/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$S/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$S/Info.plist"
plutil -replace AhenkGitCommit -string "$COMMIT" "$S/Info.plist"
plutil -lint -s "$S/Info.plist"
printf 'APPL????' > "$S/PkgInfo"
for lproj in Packaging/*.lproj; do
  ditto "$lproj" "$S/Resources/$(basename "$lproj")"
done

cp "$ADAPTER_SCRIPT" "$S/Resources/adapter/"
cp "$ADAPTER_SRC/LICENSE" "$S/Resources/adapter/LICENSE"
ditto "$ADAPTER_FW" "$S/Resources/adapter/MediaRemoteAdapter.framework"
cp LICENSE THIRD_PARTY_NOTICES.md "$S/Resources/"

# --- Sign: nested framework first, then the app ------------------------------
codesign --force --sign "$SIGN_ID" --timestamp=none "$S/Resources/adapter/MediaRemoteAdapter.framework"
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime \
  --entitlements Packaging/Ahenk.entitlements "$STAGING"
codesign --verify --deep --strict "$STAGING"

rm -rf "$APP"
mv "$STAGING" "$APP"
cp Packaging/Ahenk.entitlements "$DIST/Ahenk.entitlements"

echo "==> Signature"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|CodeDirectory)' | sed 's/^/    /' || true
if [ "$SIGN_ID" = "-" ]; then
  warn "############################################################################"
  warn "WARNING: $APP is signed AD HOC. The Apple Development identity"
  warn "         $STABLE_IDENTITY_SHA1 is not installed, so macOS forgets the"
  warn "         system-audio and Automation permissions after every rebuild."
  warn "############################################################################"
else
  echo "    Signed with: ${SIGN_NAME:-$SIGN_ID}"
fi
echo "Built $APP ($VERSION, build $BUILD, $COMMIT)"
echo "Run it:  open -n $APP --args --demo"
