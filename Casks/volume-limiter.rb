####
# Homebrew Cask for the GUI install.
#
# The url/sha256 point at the published v0.1.2 GitHub Release. Verified end to
# end on macOS 26: `brew install --cask` installs the self-contained pane and
# starts the LaunchAgent; `brew uninstall --cask` stops the service and removes
# everything.
#
# The cask carries the self-contained VolumeLimiter.prefPane (which bundles
# volume-limiterd + volume-limit), so no separate formula is needed.
####
cask "volume-limiter" do
  version "0.1.2"
  sha256 "6f1636ec1a3a0a9d731a433e6b6631e8d977fe47ea18350c250352600c380862"

  url "https://github.com/HackwoodL/volume-limiter/releases/download/v#{version}/VolumeLimiter-#{version}.dmg"
  name "Volume Limiter"
  desc "Maximum output volume limiter for macOS (System Settings pane + CLI)"
  homepage "https://github.com/HackwoodL/volume-limiter"

  prefpane "VolumeLimiter.prefPane"

  # Install and start the background service so a single `brew install --cask`
  # leaves the limiter running, matching the pane's own first-load behaviour.
  postflight do
    require "fileutils"

    pane    = "#{Dir.home}/Library/PreferencePanes/VolumeLimiter.prefPane"
    src_bin = "#{pane}/Contents/Resources/bin"
    dst_bin = "#{Dir.home}/Library/Application Support/VolumeLimiter/bin"
    plist   = "#{Dir.home}/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist"
    label   = "com.hackwoodl.volumelimiter"

    system_command "/usr/bin/xattr", args: ["-cr", pane], sudo: false

    FileUtils.mkdir_p(dst_bin)
    FileUtils.cp("#{src_bin}/volume-limiterd", "#{dst_bin}/volume-limiterd")
    FileUtils.cp("#{src_bin}/volume-limit", "#{dst_bin}/volume-limit")

    File.write(plist, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key><string>#{label}</string>
          <key>ProgramArguments</key><array><string>#{dst_bin}/volume-limiterd</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
      </dict>
      </plist>
    PLIST

    # Start the LaunchAgent. Boot out any stale instance quietly, then retry
    # bootstrap a few times — launchctl can briefly return EIO after a bootout.
    start_script = <<~SH
      target="gui/#{Process.uid}"
      plist="#{plist}"
      label="#{label}"
      /bin/launchctl bootout "$target/$label" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        if /bin/launchctl bootstrap "$target" "$plist" 2>/dev/null; then
          exit 0
        fi
        /bin/launchctl bootout "$target/$label" 2>/dev/null || true
        sleep 1
      done
      /bin/launchctl bootstrap "$target" "$plist"
    SH
    system_command "/bin/sh", args: ["-c", start_script], sudo: false
  end

  uninstall launchctl: "com.hackwoodl.volumelimiter",
            delete:    [
              "~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist",
              "~/Library/Application Support/VolumeLimiter",
            ]

  zap trash: [
    "~/Library/Application Support/VolumeLimiter",
    "~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist",
  ]
end
