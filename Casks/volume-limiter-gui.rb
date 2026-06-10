cask "volume-limiter-gui" do
  version "0.1.0"
  sha256 "REPLACE_WITH_GUI_ZIP_SHA256"

  url "https://github.com/HackwoodL/volume-limiter/releases/download/v#{version}/VolumeLimiter-gui-v#{version}.zip"
  name "Volume Limiter"
  desc "System Settings preference pane for Volume Limiter"
  homepage "https://github.com/HackwoodL/volume-limiter"

  depends_on formula: "volume-limiter"

  prefpane "VolumeLimiter.prefPane"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{Dir.home}/Library/PreferencePanes/VolumeLimiter.prefPane"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/VolumeLimiter",
    "~/Library/PreferencePanes/VolumeLimiter.prefPane",
    "~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist",
  ]
end
