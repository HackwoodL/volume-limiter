# Publishing checklist

Replace repository and tap names if you choose different GitHub names. The repos
below already exist (`HackwoodL/volume-limiter` and `HackwoodL/homebrew-tap`) and
v0.1.0 / v0.1.1 are published; this is the recurring process for each new version.

## One-time GitHub setup (already done)

```bash
gh repo create HackwoodL/volume-limiter --public --source=. --remote=origin --push
gh repo create HackwoodL/homebrew-tap --public
```

## Validate locally

```bash
VERSION=0.1.1                       # the version you are about to cut
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
scripts/test-launch-agent.sh
scripts/build-dmg.sh "$VERSION"     # -> .build/dmg/VolumeLimiter-$VERSION.dmg
```

Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in
`Sources/PrefPane/Info.plist` to match before tagging.

Then install the built DMG and confirm the full flow: double-click the pane, let
System Settings install it, verify the service starts on its own, and check that
the in-pane **Uninstall** button removes everything.

## Cut a release

```bash
git status --short
git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"
```

`release.yml` runs on the `v*` tag: it builds the DMG via `scripts/build-dmg.sh`,
writes `SHA256SUMS`, and attaches both to the GitHub Release automatically.

## Update the Homebrew tap

The cask is self-contained: the pane bundles `volume-limiterd` and `volume-limit`
and starts the service itself. After the release exists, put the DMG's SHA256 into
`sha256` and the release URL into `url` in `Casks/volume-limiter.rb`, then copy it
to the tap:

```bash
git clone git@github.com:HackwoodL/homebrew-tap.git ../homebrew-tap
mkdir -p ../homebrew-tap/Casks
cp Casks/volume-limiter.rb ../homebrew-tap/Casks/
cd ../homebrew-tap
git add Casks/volume-limiter.rb
git commit -m "Update Volume Limiter cask"
git push origin main
```

## Test the tap

One command installs **and** starts everything:

```bash
brew install --cask HackwoodL/tap/volume-limiter
volume-limit status
```

One command removes it — the cask's `uninstall`/`zap` stop the service and delete
the LaunchAgent, config, and pane:

```bash
brew uninstall --cask HackwoodL/tap/volume-limiter
```
