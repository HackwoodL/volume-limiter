#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
RELEASE_DIR="$ROOT/.build/release-artifacts"
CLI_DIR="$RELEASE_DIR/volume-limiter-cli-v$VERSION"
GUI_DIR="$RELEASE_DIR/VolumeLimiter-gui-v$VERSION"

rm -rf "$RELEASE_DIR"
mkdir -p "$CLI_DIR" "$GUI_DIR"

swift build -c release --package-path "$ROOT"

cp "$ROOT/.build/release/volume-limiterd" "$CLI_DIR/"
cp "$ROOT/.build/release/volume-limit" "$CLI_DIR/"
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
