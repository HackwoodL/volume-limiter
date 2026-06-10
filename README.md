# Volume Limiter

[简体中文](README.zh-CN.md)

[![Latest release](https://img.shields.io/github/v/release/HackwoodL/volume-limiter)](https://github.com/HackwoodL/volume-limiter/releases/latest)
[![Download DMG](https://img.shields.io/badge/Download-.dmg-2ea44f?logo=apple&logoColor=white)](https://github.com/HackwoodL/volume-limiter/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![Volume Limiter prefPane in System Settings](docs/screenshots/prefpane-system-settings.png)

Volume Limiter is a lightweight macOS app that caps your maximum output volume. I built it to stop a newly-connected headset from suddenly blasting audio and hurting your ears: it holds every output device to a maximum volume you choose, and pushes the volume back down the moment it goes above that limit. Control it from a pane in System Settings, or from a small command-line tool.

**[⬇ Download the latest release](https://github.com/HackwoodL/volume-limiter/releases/latest)** — open the DMG and double-click `VolumeLimiter.prefPane` to install, or run `brew install --cask HackwoodL/tap/volume-limiter-gui`.

**Requirements:** macOS 13 (Ventura) or later, on Apple Silicon or Intel.

## Features

- Caps the maximum output volume — turn it up past the limit and it snaps back.
- A default cap for every device, plus optional per-device caps.
- Headphone-only mode: only limit headphone-like outputs (Bluetooth, USB, Type-C).
- Optional notification when the volume is capped.
- A System Settings GUI and a `volume-limit` command line, always in sync.

## Install

### Easiest: double-click install from a DMG (recommended)

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

Once the personal tap is published, one command installs **and** starts everything
(the cask carries the self-contained pane, which bundles the service and CLI):

```bash
brew install --cask HackwoodL/tap/volume-limiter-gui
```

Uninstalling is also one command — it stops the service and removes the agent,
config, and pane:

```bash
brew uninstall --cask HackwoodL/tap/volume-limiter-gui
```

## GUI

The main interface is a pane in **System Settings ▸ Volume Limiter**:

- A master switch to turn limiting on or off.
- A default cap slider that applies to every device.
- Per-device caps — add specific devices and give each its own cap.
- Toggles for headphone-only mode and limit notifications.
- A one-click **Uninstall** button.

It shows the current volume and output device live, and the background service
keeps your cap enforced even when the pane is closed.

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
Open System Settings > Volume Limiter to start it.
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
brew uninstall --cask HackwoodL/tap/volume-limiter-gui
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

## License

Released under the [MIT License](LICENSE).
