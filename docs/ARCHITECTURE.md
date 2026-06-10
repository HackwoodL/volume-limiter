# Architecture

Volume Limiter follows a single-daemon, thin-client architecture.

## Components

| Component | Role | Core Audio access |
| --- | --- | --- |
| `volume-limiterd` | Owns config, listens to output-device and volume events, clamps volume, serves IPC | Yes |
| `VolumeLimiterCore` | Core Audio abstraction, config store, limiter engine | Yes, through adapter |
| `VolumeLimiterIPC` | Newline-delimited JSON protocol and Unix socket client/server | No |
| `volume-limit` / `vollimit` | CLI thin clients | No |
| `VolumeLimiter.prefPane` | System Settings GUI thin client | No |

## Data flow

```text
User action
  │
  ├─ volume-limit / vollimit ─┐
  └─ VolumeLimiter.prefPane ──┼─ JSON line over /tmp/volume-limiter-$UID.sock
                              │
                              ▼
                       volume-limiterd
                              │
                              ▼
                         Core Audio HAL
```

The daemon creates `/tmp/volume-limiter-$UID.sock` with `0600` permissions. The short `/tmp` path avoids Unix domain socket path-length problems on macOS.

## IPC protocol

Each request and response is one JSON object followed by `\n`.

Request fields:

- `version`: currently `1`
- `id`: caller-generated request ID
- `cmd`: command name
- `value`: optional integer payload
- `enabled`: optional Boolean payload

Response fields:

- `ok`: Boolean success flag
- `id`: request ID
- `error.code` and `error.message` on failure
- status fields for successful status-like commands

Unknown commands, unsupported versions, missing arguments, and invalid arguments are rejected.

## Core Audio strategy

The daemon listens to:

- `kAudioHardwarePropertyDefaultOutputDevice`
- `kAudioDevicePropertyVolumeScalar` on output scope

On default device changes, it re-installs volume listeners and immediately enforces the configured limit. It prefers master output volume; if unavailable, it enumerates output channel elements and applies the limit to writable channels.

No polling timer is enabled by default.

## Singleton behavior

The active Unix socket is the per-user singleton guard. A second daemon instance fails to bind while the first daemon owns the socket. Stale sockets are removed only after a connection attempt proves no daemon is listening.

## GUI strategy

The v1 GUI is `VolumeLimiter.prefPane`, built as a universal `arm64`/`x86_64` bundle with ad-hoc signing. It is deprecated technology, but it gives the closest System Settings integration without a paid Apple Developer account. If future macOS releases break third-party prefPanes, the planned fallback is a SwiftUI menu bar app that keeps the same IPC-only client model.
