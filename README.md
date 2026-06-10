# Volume Limiter

[简体中文](README.zh-CN.md)

![Volume Limiter prefPane in System Settings](docs/screenshots/prefpane-system-settings.png)

Volume Limiter is a lightweight macOS maximum-volume limiter. A single per-user daemon watches the current output device with Core Audio and immediately pushes volume back down when it exceeds your configured limit. The CLI and GUI are thin clients that talk to the same daemon over a Unix domain socket.

## Features

- Event-driven Core Audio monitoring; no default polling loop.
- Per-user daemon `volume-limiterd` that auto-starts in the background and idles near 0% CPU.
- CLI: `volume-limit`.
- GUI: ad-hoc signed `VolumeLimiter.prefPane` for macOS System Settings, with a master switch to turn limiting on/off.
- Drag-to-install DMG: the pane bundles the daemon and CLI and starts the service on first load — double-click to install.
- The prefPane auto-refreshes while visible and stops refreshing when you leave it.
- Shared config owned by the daemon, so the CLI and GUI stay in sync.
- Optional headphone-only mode for Bluetooth, USB, Type-C, and other headphone-like outputs.
- Per-device caps: a default cap applies to every device, with optional overrides for specific devices.
- Optional macOS notification when volume is capped.
- One-click Uninstall button in the pane that removes the service, config, and pane in one step.
- No kernel extension, no virtual audio driver, no kext — and no paid certificate.

## Install

### Easiest: drag-to-install DMG (recommended)

Open `VolumeLimiter-<version>.dmg`, then **double-click `VolumeLimiter.prefPane`**
inside it. Click **Install** when System Settings asks. The background service
starts automatically — set your cap and you're done. No Terminal, clone, or
Homebrew required.

To uninstall, open System Settings ▸ Volume Limiter and click **Uninstall**.

> Prebuilt DMGs aren't published to Releases yet. Until then, build one locally
> with `scripts/build-dmg.sh` (it prints the path to the `.dmg`), or use the
> one-command source install below.
>
> Because I can't afford an Apple Developer Program membership, the build is
> ad-hoc signed and not notarized. After downloading a published DMG, macOS may
> ask you to approve the pane in System Settings ▸ Privacy & Security, or to
> right-click ▸ Open it the first time.

### From source

```bash
git clone https://github.com/HackwoodL/volume-limiter.git
cd volume-limiter
scripts/install-local.sh     # one-command install (daemon + CLI + prefPane)
```

`install-local.sh` builds the universal binaries and installs everything into
`~/Library/Application Support/VolumeLimiter`, with the LaunchAgent and prefPane
under `~/Library`, so nothing runs out of your checkout directory. Prefer a DMG?
Run `scripts/build-dmg.sh` instead and double-click the pane inside it.

The CLI installs to `~/Library/Application Support/VolumeLimiter/bin`. Add it to
your `PATH` to call `volume-limit` directly:

```bash
echo 'export PATH="$HOME/Library/Application Support/VolumeLimiter/bin:$PATH"' >> ~/.zshrc
```

For development you can also build and test without installing:

```bash
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
```

### Homebrew (planned — not published yet)

Once the personal tap is published, these will work:

```bash
brew install HackwoodL/tap/volume-limiter              # CLI + daemon
brew services start volume-limiter
brew install --cask HackwoodL/tap/volume-limiter-gui   # prefPane GUI
```

> If you install with Homebrew, **uninstall with Homebrew** (`brew uninstall` /
> `brew services stop`). Homebrew tracks its own files and runs the daemon under
> a separate `brew services` agent, so the in-pane **Uninstall** button and the
> Terminal uninstall below apply to the DMG/source install, not to a Homebrew
> one.

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

## Uninstall

### Easiest: the Uninstall button (GUI)

Open System Settings ▸ Volume Limiter and click **Uninstall** at the bottom of
the pane. It stops the background service and removes the LaunchAgent, the saved
configuration, and the preference pane itself in one step. Quit and reopen
System Settings afterwards to clear it from the sidebar.

### Local install (Terminal)

Equivalent to the button, if you prefer the command line:

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

## Testing

See [`docs/TESTING.md`](docs/TESTING.md). Current coverage includes Core policy tests, notification trigger tests, IPC protocol tests, CLI parser/rendering tests, Unix socket conflict tests, real daemon + CLI smoke tests, prefPane bundle build/sign/load checks, System Settings screenshot, keyboard volume-key latency, Bluetooth reconnect, Type-C wired headset, reboot auto-start, and a short idle resource sample.

Remaining follow-up validation: HDMI/AirPlay/aggregate/unsupported output devices when hardware is available, and Homebrew install/uninstall against the public tap after release SHA values are available.

## Preference pane status

`NSPreferencePane` is deprecated. Volume Limiter keeps it as the preferred v1 GUI because it integrates with System Settings on current macOS versions, but future macOS releases may remove or further restrict third-party preference panes. If that becomes unreliable, the fallback is a SwiftUI menu bar app that still talks to the same daemon.

## Roadmap

- v0.1.x: finish release packaging, tap publication, and manual hardware validation.
- v1.0: stable distribution for both the CLI and the prefPane GUI (Homebrew tap and GitHub Release).
- v2: investigate driver-layer hard interception with a Core Audio HAL virtual device. v1 deliberately does not install drivers, kexts, or virtual audio devices.
