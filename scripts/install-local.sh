#!/usr/bin/env bash
# Installs Volume Limiter for the current user without Homebrew.
#
# Everything lives under the app's own Application Support directory, so nothing
# runs out of ~/Documents (which would otherwise trigger macOS privacy prompts):
#   ~/Library/Application Support/VolumeLimiter/bin/volume-limiterd   (daemon)
#   ~/Library/Application Support/VolumeLimiter/bin/volume-limit      (CLI)
#   ~/Library/Application Support/VolumeLimiter/config.json           (settings)
#   ~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist          (auto-start)
#   ~/Library/PreferencePanes/VolumeLimiter.prefPane                  (GUI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.hackwoodl.volumelimiter"
UID_NUM="$(id -u)"
SUPPORT_DIR="$HOME/Library/Application Support/VolumeLimiter"
BIN_DIR="$SUPPORT_DIR/bin"
DAEMON_DEST="$BIN_DIR/volume-limiterd"
CLI_DEST="$BIN_DIR/volume-limit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOCKET="/tmp/volume-limiter-$UID_NUM.sock"

echo "==> Building release binaries"
swift build -c release --product volume-limiterd --product volume-limit

echo "==> Stopping any running daemon"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
for _ in $(seq 1 10); do
  launchctl list 2>/dev/null | grep -q "$LABEL" || break
  sleep 1
done

echo "==> Installing binaries to $BIN_DIR"
mkdir -p "$BIN_DIR"
cp "$ROOT/.build/release/volume-limiterd" "$DAEMON_DEST"
cp "$ROOT/.build/release/volume-limit" "$CLI_DEST"
codesign --force --sign - "$DAEMON_DEST" "$CLI_DEST"

echo "==> Writing LaunchAgent -> $PLIST"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_DEST</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST_EOF

rm -f "$SOCKET"

echo "==> Starting daemon"
# launchctl bootstrap can briefly return EIO right after a bootout; retry.
bootstrapped=0
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then bootstrapped=1; break; fi
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  sleep 2
  rm -f "$SOCKET"
done
if [ "$bootstrapped" != 1 ]; then
  echo "error: could not start the daemon via launchctl" >&2
  exit 1
fi
for _ in $(seq 1 10); do
  [ -S "$SOCKET" ] && break
  sleep 1
done

echo "==> Installing preference pane"
"$ROOT/scripts/install-prefpane.sh" >/dev/null

echo
echo "Installed. Nothing runs from ~/Documents anymore."
echo "  daemon: $DAEMON_DEST"
echo "  cli:    $CLI_DEST"
echo "  config: $SUPPORT_DIR/config.json"
echo "Open System Settings > Volume Limiter to use the GUI."
