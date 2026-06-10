# Publishing checklist

Replace repository and tap names if you choose different GitHub names. Publishing
is not done yet — this is the plan for when you are ready.

## One-time GitHub setup

```bash
gh repo create HackwoodL/volume-limiter --public --source=. --remote=origin --push
gh repo create HackwoodL/homebrew-tap --public
```

## Validate locally

```bash
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
scripts/test-launch-agent.sh
scripts/build-dmg.sh 0.1.0        # -> .build/dmg/VolumeLimiter-0.1.0.dmg
```

Then install the built DMG and confirm the full flow: double-click the pane, let
System Settings install it, verify the service starts on its own, and check that
the in-pane **Uninstall** button removes everything.

## Publish v0.1.0

```bash
git status --short
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

Attach `VolumeLimiter-0.1.0.dmg` to the GitHub Release — the cask downloads it.
(GitHub also generates a source tarball automatically, which the optional
CLI-only formula builds from.)

> The cask points at `VolumeLimiter-<version>.dmg`. If you automate the release,
> make sure the workflow builds and uploads that DMG with `scripts/build-dmg.sh`
> (the current `release.yml` predates the DMG and only builds the zips).

## Update the Homebrew tap

The cask is self-contained: the pane bundles `volume-limiterd` and `volume-limit`
and starts the service itself, so it does **not** depend on the formula. After the
release exists:

1. Put the DMG's SHA256 into `sha256` and the release URL into `url` in
   `Casks/volume-limiter-gui.rb`.
2. (Optional) Update `Formula/volume-limiter.rb` only if you also want a
   CLI-only `brew install volume-limiter` for headless users.

```bash
git clone git@github.com:HackwoodL/homebrew-tap.git ../homebrew-tap
mkdir -p ../homebrew-tap/Casks ../homebrew-tap/Formula
cp Casks/volume-limiter-gui.rb ../homebrew-tap/Casks/
cp Formula/volume-limiter.rb  ../homebrew-tap/Formula/   # optional, CLI-only
cd ../homebrew-tap
git add Casks/volume-limiter-gui.rb Formula/volume-limiter.rb
git commit -m "Add Volume Limiter cask"
git push origin main
```

## Test the tap

One command installs **and** starts everything:

```bash
brew install --cask HackwoodL/tap/volume-limiter-gui
volume-limit status
```

One command removes it — the cask's `uninstall`/`zap` stop the service and delete
the LaunchAgent, config, and pane:

```bash
brew uninstall --cask HackwoodL/tap/volume-limiter-gui
```
