cask "nicedock" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/farvisun/nicedock/releases/download/v#{version}/NiceDock.zip"
  name "NiceDock"
  desc "Second Dock with native widgets"
  homepage "https://farvisun.github.io/nicedock/"

  # Sparkle updates the app in place.
  auto_updates true
  depends_on macos: :sonoma

  app "NiceDock.app"

  # Ad-hoc signed, not notarized: without this macOS refuses the first launch.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/NiceDock.app"]
  end

  uninstall quit: "app.nicedock.NiceDock"

  zap trash: [
    "~/Library/Application Support/NiceDock",
    "~/Library/Caches/app.nicedock.NiceDock",
    "~/Library/HTTPStorages/app.nicedock.NiceDock",
    "~/Library/Preferences/app.nicedock.NiceDock.plist",
  ]
end
