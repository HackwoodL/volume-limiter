####
# Homebrew Cask for the GUI install.
#
# DRAFT — pending tap publication. The version/sha256/url point at a GitHub
# Release that doesn't exist yet, and the postflight/uninstall flow must be
# verified end-to-end against the real tap before relying on it.
#
# Design: the cask carries the self-contained VolumeLimiter.prefPane (which
# bundles volume-limiterd + volume-limit), so no separate formula is needed.
# `brew install --cask` installs the pane and starts the per-user LaunchAgent in
# one step; `brew uninstall --cask` stops the service and removes everything.
####
cask "volume-limiter-gui" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

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

    system_command "/bin/launchctl",
                   args: ["bootout", "gui/#{Process.uid}", plist],
                   sudo: false, must_succeed: false
    system_command "/bin/launchctl",
                   args: ["bootstrap", "gui/#{Process.uid}", plist],
                   sudo: false, must_succeed: false
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
