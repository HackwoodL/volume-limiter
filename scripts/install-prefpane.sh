#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$("$ROOT/scripts/build-prefpane.sh")"
DEST_DIR="$HOME/Library/PreferencePanes"
DEST="$DEST_DIR/VolumeLimiter.prefPane"

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$BUNDLE" "$DEST"
xattr -cr "$DEST"

echo "Installed $DEST"
echo "Open System Settings and look for Volume Limiter near the bottom of the sidebar."
