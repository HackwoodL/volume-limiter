#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib-build.sh"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_DIR="$ROOT/.build/prefpane"
BUNDLE="$BUILD_DIR/VolumeLimiter.prefPane"
EXECUTABLE="$BUNDLE/Contents/MacOS/VolumeLimiter"
INFO_PLIST="$ROOT/Sources/PrefPane/Info.plist"
SOURCES=(
  "$ROOT/Sources/VolumeLimiterIPC/Protocol.swift"
  "$ROOT/Sources/VolumeLimiterIPC/UnixSocket.swift"
  "$ROOT/Sources/PrefPane/VolumeLimiterPreferencePane.swift"
)
ARCHS=(arm64 x86_64)

rm -rf "$BUNDLE" "$BUILD_DIR/objects"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUILD_DIR/objects"
cp "$INFO_PLIST" "$BUNDLE/Contents/Info.plist"
cp -R "$ROOT/Sources/PrefPane/Resources/"* "$BUNDLE/Contents/Resources/"

ARCH_OUTPUTS=()
for arch in "${ARCHS[@]}"; do
  out="$BUILD_DIR/objects/VolumeLimiter-$arch"
  swiftc \
    -target "$arch-apple-macos13.0" \
    -sdk "$SDK" \
    -parse-as-library \
    -module-name VolumeLimiterPrefPane \
    -framework Cocoa \
    -framework PreferencePanes \
    -emit-library \
    -Xlinker -bundle \
    -Xlinker -undefined \
    -Xlinker dynamic_lookup \
    -o "$out" \
    "${SOURCES[@]}"
  ARCH_OUTPUTS+=("$out")
done

lipo -create "${ARCH_OUTPUTS[@]}" -output "$EXECUTABLE"

# Embed the universal, ad-hoc-signed daemon + CLI so the pane is self-contained:
# on first load it copies the daemon out and starts it (see autoInstallDaemonIfNeeded).
# Set VL_NO_BUNDLED_DAEMON=1 to skip (e.g. for a GUI-only dev build).
if [ "${VL_NO_BUNDLED_DAEMON:-0}" != "1" ]; then
  vl_build_cli_daemon "$BUNDLE/Contents/Resources/bin"
fi

codesign --force --sign - "$BUNDLE" >/dev/null
xattr -cr "$BUNDLE"

echo "$BUNDLE"
