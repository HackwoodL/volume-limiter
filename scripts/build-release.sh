#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
RELEASE_DIR="$ROOT/.build/release-artifacts"
UNIVERSAL_BUILD_DIR="$ROOT/.build/release-universal"
CLI_DIR="$RELEASE_DIR/volume-limiter-cli-v$VERSION"
GUI_DIR="$RELEASE_DIR/VolumeLimiter-gui-v$VERSION"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS=(arm64 x86_64)

rm -rf "$RELEASE_DIR" "$UNIVERSAL_BUILD_DIR"
mkdir -p "$CLI_DIR" "$GUI_DIR"

build_arch() {
  local arch="$1"
  local arch_dir="$UNIVERSAL_BUILD_DIR/$arch"

  mkdir -p "$arch_dir/ipc" "$arch_dir/core" "$arch_dir/cli" "$arch_dir/bin"

  (
    cd "$arch_dir/ipc"
    swiftc \
      -target "$arch-apple-macos13.0" \
      -sdk "$SDK" \
      -O \
      -parse-as-library \
      -module-name VolumeLimiterIPC \
      -emit-module \
      -emit-module-path VolumeLimiterIPC.swiftmodule \
      -c \
      "$ROOT/Sources/VolumeLimiterIPC/Protocol.swift" \
      "$ROOT/Sources/VolumeLimiterIPC/UnixSocket.swift"
  )

  (
    cd "$arch_dir/core"
    swiftc \
      -target "$arch-apple-macos13.0" \
      -sdk "$SDK" \
      -O \
      -parse-as-library \
      -module-name VolumeLimiterCore \
      -emit-module \
      -emit-module-path VolumeLimiterCore.swiftmodule \
      -c \
      "$ROOT/Sources/VolumeLimiterCore/AudioHardware.swift" \
      "$ROOT/Sources/VolumeLimiterCore/Config.swift" \
      "$ROOT/Sources/VolumeLimiterCore/CoreAudioHardware.swift" \
      "$ROOT/Sources/VolumeLimiterCore/VolumeLimiterEngine.swift"
  )

  (
    cd "$arch_dir/cli"
    swiftc \
      -target "$arch-apple-macos13.0" \
      -sdk "$SDK" \
      -O \
      -parse-as-library \
      -I "$arch_dir/ipc" \
      -module-name VolumeLimitCLI \
      -emit-module \
      -emit-module-path VolumeLimitCLI.swiftmodule \
      -c \
      "$ROOT/Sources/VolumeLimitCLI/VolumeLimitCLI.swift"
  )

  swiftc \
    -target "$arch-apple-macos13.0" \
    -sdk "$SDK" \
    -O \
    -I "$arch_dir/ipc" \
    -I "$arch_dir/cli" \
    "$arch_dir/cli"/*.o \
    "$arch_dir/ipc"/*.o \
    "$ROOT/Sources/volume-limit/main.swift" \
    -o "$arch_dir/bin/volume-limit"

  swiftc \
    -target "$arch-apple-macos13.0" \
    -sdk "$SDK" \
    -O \
    -I "$arch_dir/ipc" \
    -I "$arch_dir/core" \
    "$arch_dir/core"/*.o \
    "$arch_dir/ipc"/*.o \
    "$ROOT/Sources/volume-limiterd/AppleScriptVolumeLimitNotifier.swift" \
    "$ROOT/Sources/volume-limiterd/VolumeKeyInterceptor.swift" \
    "$ROOT/Sources/volume-limiterd/main.swift" \
    -o "$arch_dir/bin/volume-limiterd"
}

for arch in "${ARCHS[@]}"; do
  build_arch "$arch"
done

lipo -create \
  "$UNIVERSAL_BUILD_DIR/arm64/bin/volume-limiterd" \
  "$UNIVERSAL_BUILD_DIR/x86_64/bin/volume-limiterd" \
  -output "$CLI_DIR/volume-limiterd"

lipo -create \
  "$UNIVERSAL_BUILD_DIR/arm64/bin/volume-limit" \
  "$UNIVERSAL_BUILD_DIR/x86_64/bin/volume-limit" \
  -output "$CLI_DIR/volume-limit"

"$ROOT/scripts/sign.sh" "$CLI_DIR/volume-limiterd" "$CLI_DIR/volume-limit"

PREFPANE="$("$ROOT/scripts/build-prefpane.sh")"
cp -R "$PREFPANE" "$GUI_DIR/VolumeLimiter.prefPane"

(
  cd "$RELEASE_DIR"
  ditto -c -k --sequesterRsrc --keepParent "volume-limiter-cli-v$VERSION" "volume-limiter-cli-v$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "VolumeLimiter-gui-v$VERSION/VolumeLimiter.prefPane" "VolumeLimiter-gui-v$VERSION.zip"
  shasum -a 256 "volume-limiter-cli-v$VERSION.zip" "VolumeLimiter-gui-v$VERSION.zip" > SHA256SUMS
)

echo "$RELEASE_DIR"
