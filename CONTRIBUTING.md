# Contributing

Thanks for helping improve Volume Limiter.

## Development

```bash
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
scripts/build-prefpane.sh
```

Do not add direct Core Audio calls to CLI or GUI code. `volume-limiterd` is the only component that may read or write system audio volume; clients must use `VolumeLimiterIPC`.

## Code style

- Keep changes small and focused.
- Prefer explicit error handling over silent fallback.
- Do not add polling to the daemon unless it is behind an explicit fallback build/configuration path.
- Do not introduce paid signing, Developer ID, notarization, kernel extensions, kexts, or virtual audio drivers for v1.

## Testing expectations

Run the Swift test runner and the daemon/CLI smoke script before opening a pull request. Hardware-dependent results must be reported honestly; do not fabricate screenshots, Bluetooth behavior, reboot results, or latency numbers.
