class VolumeLimiter < Formula
  desc "Per-user macOS maximum output volume limiter"
  homepage "https://github.com/HackwoodL/volume-limiter"
  url "https://github.com/HackwoodL/volume-limiter/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_TARBALL_SHA256"
  license "MIT"

  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/volume-limiterd"
    bin.install ".build/release/volume-limit"
  end

  service do
    run [opt_bin/"volume-limiterd"]
    keep_alive true
    log_path var/"log/volume-limiterd.log"
    error_log_path var/"log/volume-limiterd.log"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/volume-limit --help")
  end
end
