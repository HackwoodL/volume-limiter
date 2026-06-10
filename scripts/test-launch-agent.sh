#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.hackwoodl.volumelimiter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOCKET="/tmp/volume-limiter-$(id -u).sock"
DAEMON="$ROOT/.build/debug/volume-limiterd"
CLI="$ROOT/.build/debug/volume-limit"

if [ -e "$PLIST" ]; then
  echo "Refusing to overwrite existing LaunchAgent: $PLIST" >&2
  exit 2
fi

swift build --package-path "$ROOT" >/dev/null

cleanup() {
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  if [ -S "$SOCKET" ]; then
    rm -f "$SOCKET"
  fi
}
trap cleanup EXIT

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DAEMON</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"

for _ in $(seq 1 80); do
  if [ -S "$SOCKET" ]; then
    break
  fi
  sleep 0.1
done

if [ ! -S "$SOCKET" ]; then
  echo "LaunchAgent did not create $SOCKET" >&2
  exit 1
fi

"$CLI" status
echo "launch-agent-test=passed"
