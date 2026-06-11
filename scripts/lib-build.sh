#!/usr/bin/env bash
# Shared build helpers for Volume Limiter packaging scripts.

# Builds universal (arm64 + x86_64) volume-limiterd and volume-limit, ad-hoc
# signed, into the destination directory passed as $1.
#
# Usage: vl_build_cli_daemon <dest_dir>
vl_build_cli_daemon() {
  local dest="$1"
  local root sdk build_dir
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  build_dir="$root/.build/universal-bin"
  local archs=(arm64 x86_64)

  rm -rf "$build_dir"
  for arch in "${archs[@]}"; do
    local d="$build_dir/$arch"
    mkdir -p "$d/ipc" "$d/core" "$d/cli" "$d/bin"

    ( cd "$d/ipc"
      swiftc -target "$arch-apple-macos13.0" -sdk "$sdk" -O -parse-as-library \
        -module-name VolumeLimiterIPC \
        -emit-module -emit-module-path VolumeLimiterIPC.swiftmodule -c \
        "$root/Sources/VolumeLimiterIPC/Protocol.swift" \
        "$root/Sources/VolumeLimiterIPC/UnixSocket.swift" )

    ( cd "$d/core"
      swiftc -target "$arch-apple-macos13.0" -sdk "$sdk" -O -parse-as-library \
        -module-name VolumeLimiterCore \
        -emit-module -emit-module-path VolumeLimiterCore.swiftmodule -c \
        "$root/Sources/VolumeLimiterCore/AudioHardware.swift" \
        "$root/Sources/VolumeLimiterCore/Config.swift" \
        "$root/Sources/VolumeLimiterCore/CoreAudioHardware.swift" \
        "$root/Sources/VolumeLimiterCore/VolumeLimiterEngine.swift" )

    ( cd "$d/cli"
      swiftc -target "$arch-apple-macos13.0" -sdk "$sdk" -O -parse-as-library \
        -I "$d/ipc" -module-name VolumeLimitCLI \
        -emit-module -emit-module-path VolumeLimitCLI.swiftmodule -c \
        "$root/Sources/VolumeLimitCLI/VolumeLimitCLI.swift" )

    swiftc -target "$arch-apple-macos13.0" -sdk "$sdk" -O \
      -I "$d/ipc" -I "$d/cli" \
      "$d/cli"/*.o "$d/ipc"/*.o \
      "$root/Sources/volume-limit/main.swift" \
      -o "$d/bin/volume-limit"

    swiftc -target "$arch-apple-macos13.0" -sdk "$sdk" -O \
      -I "$d/ipc" -I "$d/core" \
      "$d/core"/*.o "$d/ipc"/*.o \
      "$root/Sources/volume-limiterd/AppleScriptVolumeLimitNotifier.swift" \
      "$root/Sources/volume-limiterd/VolumeKeyInterceptor.swift" \
      "$root/Sources/volume-limiterd/main.swift" \
      -o "$d/bin/volume-limiterd"
  done

  mkdir -p "$dest"
  lipo -create "$build_dir/arm64/bin/volume-limiterd" "$build_dir/x86_64/bin/volume-limiterd" \
    -output "$dest/volume-limiterd"
  lipo -create "$build_dir/arm64/bin/volume-limit" "$build_dir/x86_64/bin/volume-limit" \
    -output "$dest/volume-limit"
  codesign --force --sign - "$dest/volume-limiterd" "$dest/volume-limit"
}
