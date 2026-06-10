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

PREFPANE_VERIFY_PATH="$DEST" swift -e 'import Foundation; import PreferencePanes; let path = ProcessInfo.processInfo.environment["PREFPANE_VERIFY_PATH"]!; guard let bundle = Bundle(path: path), bundle.load(), bundle.principalClass != nil else { fatalError("VolumeLimiter.prefPane failed to load") }; print("Verified prefPane bundle loads: \(String(describing: bundle.principalClass))")'

echo "Installed $DEST"
echo "Open System Settings and look for Volume Limiter near the bottom of the sidebar."
