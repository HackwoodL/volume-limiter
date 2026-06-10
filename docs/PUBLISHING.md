# Publishing checklist

Replace repository and tap names if you choose different GitHub names.

## One-time GitHub setup

```bash
gh repo create HackwoodL/volume-limiter --public --source=. --remote=origin --push
gh repo create HackwoodL/homebrew-tap --public
```

## Validate locally

If Homebrew reports that Command Line Tools are outdated, update them from System Settings or install the CLT version requested by Homebrew before validating Formula/Cask installation.

```bash
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
scripts/build-prefpane.sh
scripts/build-release.sh 0.1.0
```

## Publish v0.1.0

```bash
git status --short
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

The release workflow builds:

- `volume-limiter-cli-v0.1.0.zip`
- `VolumeLimiter-gui-v0.1.0.zip`
- `SHA256SUMS`

## Update Homebrew tap

After GitHub Release assets exist, compute or copy the SHA256 values from `SHA256SUMS`, then update:

- `Formula/volume-limiter.rb`
- `Casks/volume-limiter-gui.rb`

Copy them to the tap:

```bash
git clone git@github.com:HackwoodL/homebrew-tap.git ../homebrew-tap
mkdir -p ../homebrew-tap/Formula ../homebrew-tap/Casks
cp Formula/volume-limiter.rb ../homebrew-tap/Formula/
cp Casks/volume-limiter-gui.rb ../homebrew-tap/Casks/
cd ../homebrew-tap
git add Formula/volume-limiter.rb Casks/volume-limiter-gui.rb
git commit -m "Add Volume Limiter formula and cask"
git push origin main
```

## Test tap install

```bash
brew install HackwoodL/tap/volume-limiter
brew services start volume-limiter
volume-limit status
brew install --cask HackwoodL/tap/volume-limiter-gui
open ~/Library/PreferencePanes/VolumeLimiter.prefPane
```

## Full uninstall test

```bash
brew uninstall --cask volume-limiter-gui
brew services stop volume-limiter
brew uninstall volume-limiter
rm -rf ~/Library/Application\ Support/VolumeLimiter \
       ~/Library/PreferencePanes/VolumeLimiter.prefPane \
       ~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist
```
