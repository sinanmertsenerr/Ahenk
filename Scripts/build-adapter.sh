#!/usr/bin/env bash
# Builds MediaRemoteAdapter.framework from the vendored sources with clang
# (no CMake or Xcode project needed).
#
# Why: since macOS 15.4 only Apple-signed processes may read MediaRemote's
# now-playing data. The vendored perl script runs under /usr/bin/perl (an
# Apple binary) and loads this framework with DynaLoader, so Ahenk bundles it
# (Contents/Resources/adapter) but never links against it.
#
#   ./Scripts/build-adapter.sh            # host architecture
#   ARCHS="arm64 x86_64" ./Scripts/build-adapter.sh
#
# Output: Vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Vendor/mediaremote-adapter"
OUT="$SRC/build"
NAME="MediaRemoteAdapter"
FW="$OUT/$NAME.framework"
MIN_MACOS="${MIN_MACOS:-14.2}"
ARCHS="${ARCHS:-$(uname -m)}"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(-arch "$arch"); done

SOURCES=("$SRC"/src/adapter/*.m "$SRC"/src/private/*.m "$SRC"/src/utility/*.m)

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources"

echo "==> Compiling $NAME ($ARCHS, macOS $MIN_MACOS+)"
clang -dynamiclib \
  "${ARCH_FLAGS[@]}" \
  -mmacosx-version-min="$MIN_MACOS" \
  -fobjc-arc -fobjc-weak \
  -Wno-deprecated-declarations \
  -I "$SRC/src" -I "$SRC/include" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name "@rpath/$NAME.framework/Versions/A/$NAME" \
  -current_version 0.1.0 -compatibility_version 0.1 \
  -o "$FW/Versions/A/$NAME" \
  "${SOURCES[@]}"

cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

ln -sfn A "$FW/Versions/Current"
ln -sfn "Versions/Current/$NAME" "$FW/$NAME"
ln -sfn Versions/Current/Resources "$FW/Resources"

# Ad-hoc signature so dyld loads it on Apple silicon; make-app.sh re-signs
# the bundled copy with the app's identity.
codesign --force --sign - --timestamp=none "$FW" >/dev/null

echo "Built $FW"
file "$FW/Versions/A/$NAME" | sed 's/^/    /'
