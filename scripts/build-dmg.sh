#!/usr/bin/env bash
# Builds a drag-to-install DMG containing the self-contained VolumeLimiter.prefPane.
# The pane bundles the daemon + CLI and installs/starts them on first load, so the
# whole product installs by double-clicking the pane inside the DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
OUT_DIR="$ROOT/.build/dmg"
STAGE="$OUT_DIR/stage"
DMG="$OUT_DIR/VolumeLimiter-$VERSION.dmg"

echo "==> Building self-contained preference pane" >&2
PREFPANE="$("$ROOT/scripts/build-prefpane.sh")"

rm -rf "$OUT_DIR"
mkdir -p "$STAGE"
cp -R "$PREFPANE" "$STAGE/VolumeLimiter.prefPane"

cat > "$STAGE/How to install.txt" <<'TXT'
Volume Limiter
==============

Install
  1. Double-click "VolumeLimiter.prefPane".
  2. When System Settings asks, click "Install".
  3. The background service starts automatically — set your volume cap and you're done.

Uninstall
  Open System Settings > Volume Limiter and click "Uninstall".
TXT

echo "==> Creating DMG" >&2
hdiutil create \
  -volname "Volume Limiter" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo "$DMG"
