# Homebrew cask for KitsuneLauncher, served from this repo as a personal tap:
#
#   brew tap mayaanhafeez/kitsune https://github.com/mayaanhafeez/app_launcher
#   brew install --cask kitsune
#
# It is NOT published to homebrew/cask (it wouldn't pass their review: the app is
# ad-hoc signed, not notarized, and this cask works around Gatekeeper quarantine to
# install it anyway).
#
# Do not edit `version` or `sha256` by hand. Pushing a `v*` tag runs
# .github/workflows/release.yml, which builds the zip, attaches it to the GitHub
# release and rewrites both lines here (scripts/bump-cask.sh) on main — that commit
# is what `brew upgrade` picks up.
cask "kitsune" do
  version "0.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_scripts_release_sh"

  url "https://github.com/mayaanhafeez/app_launcher/releases/download/v#{version}/KitsuneLauncher-v#{version}-macos.zip"
  name "KitsuneLauncher"
  desc "Resident keyboard launcher and nested command menu, driven by Lua"
  homepage "https://github.com/mayaanhafeez/app_launcher"

  # Pre-releases are never written into this file, so the latest *release* is the
  # right thing for `brew livecheck` to compare against.
  livecheck do
    url :url
    strategy :github_latest
  end

  # LSMinimumSystemVersion in Resources/Info.plist.
  depends_on macos: :ventura

  app "KitsuneLauncher.app"
  binary "#{appdir}/KitsuneLauncher.app/Contents/MacOS/kitsunectl"

  # No Developer ID certificate: every release is signed ad-hoc
  # (`codesign --force --sign -`), which Gatekeeper treats as untrusted.
  # Without this, macOS refuses to open the app at all ("KitsuneLauncher.app
  # is damaged and can't be opened" / "cannot verify developer"). Casks
  # for notarized apps don't need this — this one does because there is no
  # Developer ID to notarize with.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/KitsuneLauncher.app"]
  end

  zap trash: [
    "~/.config/kitsune",
    "~/Library/Containers/com.kitsune.launcher",
  ]

  caveats <<~EOS
    KitsuneLauncher is signed ad-hoc, not with a Developer ID certificate:
      - This cask strips the quarantine flag after install so Gatekeeper
        doesn't block the first launch. That is a deliberate workaround,
        not a security guarantee -- only install builds you trust.
      - Every release has a different signature (ad-hoc signing is
        content-dependent). macOS ties TCC grants (Accessibility, for the
        global hotkey; Automation, for AppleScript-driven actions) to that
        signature, so upgrading to a new version WILL re-prompt for both
        permissions. This is expected, not a bug.
      - There is no auto-update mechanism. Re-run
        `brew upgrade --cask kitsune` to get new releases.

    On first launch, grant KitsuneLauncher access under:
      System Settings > Privacy & Security > Accessibility
      System Settings > Privacy & Security > Automation
  EOS
end
