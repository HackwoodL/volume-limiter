# Volume Limiter

[简体中文](README.zh-CN.md)

![Volume Limiter prefPane in System Settings](docs/screenshots/prefpane-system-settings.png)

Volume Limiter is a lightweight macOS maximum-volume limiter. A single per-user daemon watches the current output device with Core Audio and immediately pushes volume back down when it exceeds your configured limit. The CLI and GUI are thin clients that talk to the same daemon over a Unix domain socket.

## Features

- Event-driven Core Audio monitoring; no default polling loop.
- Per-user daemon `volume-limiterd` that auto-starts in the background and idles near 0% CPU.
- CLI: `volume-limit`.
- GUI: ad-hoc signed `VolumeLimiter.prefPane` for macOS System Settings, with a master switch to turn limiting on/off.
- The prefPane auto-refreshes while visible and stops refreshing when you leave it.
- Shared config owned by the daemon, so the CLI and GUI stay in sync.
- Optional headphone-only mode for Bluetooth, USB, Type-C, and other headphone-like outputs.
- Per-device caps: a default cap applies to every device, with optional overrides for specific devices.
- Optional macOS notification when volume is capped.
- No kernel extension, no virtual audio driver, no kext — and no paid certificate.

## Install

### Recommended: local install (works today)

```bash
git clone https://github.com/HackwoodL/volume-limiter.git
cd volume-limiter
scripts/install-local.sh
```

`install-local.sh` builds the universal binaries and installs everything into the
app's own `~/Library/Application Support/VolumeLimiter` (with the LaunchAgent and
prefPane under `~/Library`). It registers a LaunchAgent that auto-starts the
daemon, so nothing runs out of your checkout directory. Run
`scripts/install-prefpane.sh` later if you only want to refresh the GUI.

The CLI installs to `~/Library/Application Support/VolumeLimiter/bin`. Add it to
your `PATH` to call `volume-limit` directly:

```bash
echo 'export PATH="$HOME/Library/Application Support/VolumeLimiter/bin:$PATH"' >> ~/.zshrc
```

### Homebrew (planned — not published yet)

Once the personal tap is published, these will work:

```bash
brew install HackwoodL/tap/volume-limiter              # CLI + daemon
brew services start volume-limiter
brew install --cask HackwoodL/tap/volume-limiter-gui   # prefPane GUI
```

### Build from source

```bash
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
```

## CLI

```bash
volume-limit set <0-100>            # set the default cap for all devices
volume-limit on                     # turn the limiter on
volume-limit off                    # turn the limiter off
volume-limit status                 # show the full daemon status and diagnostics
volume-limit device on|off          # enable/disable per-device caps
volume-limit device set <uid> <n>   # cap a specific device by UID
volume-limit device remove <uid>    # remove a device's per-device cap
volume-limit device list            # list per-device caps and connected devices
volume-limit headphone-only on|off  # only limit headphone-like outputs
volume-limit --help                 # show usage
```

If the daemon is not running, the CLI prints:

```text
volume-limiterd is not running.
Start it from System Settings > Volume Limiter, or with Homebrew: brew services start volume-limiter
```

## Architecture

```text
┌────────────────────────────────────────────────────────────┐
│ volume-limiterd                                             │
│ - Core Audio listeners                                      │
│ - volume clamp policy                                       │
│ - config owner                                              │
│ - Unix domain socket server                                 │
└────────────────────────────────────────────────────────────┘
                              ▲
                              │ /tmp/volume-limiter-$UID.sock
                 ┌────────────┴────────────┐
                 │                         │
┌────────────────────────────┐ ┌────────────────────────────┐
│ volume-limit                │ │ VolumeLimiter.prefPane     │
│ CLI thin client             │ │ System Settings thin client│
└────────────────────────────┘ └────────────────────────────┘
```

The daemon is the only process that calls Core Audio to read or set output volume. CLI and GUI clients only send newline-delimited JSON requests over the per-user Unix socket.

## Manual release installation

> Available once a GitHub Release is published. Until then, use the local install above.

Download the release zips from GitHub:

- `volume-limiter-cli-v0.1.0.zip`: universal `arm64`/`x86_64` `volume-limiterd` and `volume-limit`
- `VolumeLimiter-gui-v0.1.0.zip`: `VolumeLimiter.prefPane`
- `SHA256SUMS`

Remove quarantine for unsigned/ad-hoc-signed downloads:

```bash
xattr -cr VolumeLimiter.prefPane volume-limiterd volume-limit
```

Install the prefPane manually:

```bash
mkdir -p ~/Library/PreferencePanes
cp -R VolumeLimiter.prefPane ~/Library/PreferencePanes/
open ~/Library/PreferencePanes/VolumeLimiter.prefPane
```

Because I can't afford an Apple Developer Program membership, releases are ad-hoc signed and not notarized. On first launch macOS may require right-click Open, `xattr -cr`, or approving the pane from System Settings.

## Uninstall

### Local install

Stop the daemon and remove everything it installed:

```bash
launchctl bootout gui/$(id -u)/com.hackwoodl.volumelimiter 2>/dev/null || true
rm -rf ~/Library/Application\ Support/VolumeLimiter \
       ~/Library/PreferencePanes/VolumeLimiter.prefPane \
       ~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist
```

### Homebrew (once published)

```bash
brew uninstall --cask volume-limiter-gui || true
brew services stop volume-limiter || true
brew uninstall volume-limiter || true
```

## Testing

See [`docs/TESTING.md`](docs/TESTING.md). Current coverage includes Core policy tests, notification trigger tests, IPC protocol tests, CLI parser/rendering tests, Unix socket conflict tests, real daemon + CLI smoke tests, prefPane bundle build/sign/load checks, System Settings screenshot, keyboard volume-key latency, Bluetooth reconnect, Type-C wired headset, reboot auto-start, and a short idle resource sample.

Remaining follow-up validation: HDMI/AirPlay/aggregate/unsupported output devices when hardware is available, and Homebrew install/uninstall against the public tap after release SHA values are available.

## Preference pane status

`NSPreferencePane` is deprecated. Volume Limiter keeps it as the preferred v1 GUI because it integrates with System Settings on current macOS versions, but future macOS releases may remove or further restrict third-party preference panes. If that becomes unreliable, the fallback is a SwiftUI menu bar app that still talks to the same daemon.

## Roadmap

- v0.1.x: finish release packaging, tap publication, and manual hardware validation.
- v1.0: stable distribution for both the CLI and the prefPane GUI (Homebrew tap and GitHub Release).
- v2: investigate driver-layer hard interception with a Core Audio HAL virtual device. v1 deliberately does not install drivers, kexts, or virtual audio devices.
