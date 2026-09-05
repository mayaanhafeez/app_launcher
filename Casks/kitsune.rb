# Homebrew Cask template for KitsuneLauncher.
#
# This is NOT published to homebrew/cask (it wouldn't pass their review: the
# app is ad-hoc signed, not notarized, and this cask works around Gatekeeper
# quarantine to install it anyway). It's meant for a personal tap, e.g.:
#
#   brew tap mayaanhafeez/kitsune https://github.com/mayaanhafeez/app_launcher
#   brew install --cask kitsune
#
# (that requires this file to live at Casks/kitsune.rb in the tap repo, which
# it already does here).
#
# After each `scripts/release.sh`, fill in:
#   - version:  the tag you cut (without the leading "v")
#   - sha256:   printed by scripts/release.sh
cask "kitsune" do
  version "0.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_scripts_release_sh"

  url "https://github.com/mayaanhafeez/app_launcher/releases/download/v#{version}/KitsuneLauncher-v#{version}-macos.zip"
  name "KitsuneLauncher"
  desc "Resident keyboard launcher and nested command menu, driven by Lua"
  homepage "https://github.com/mayaanhafeez/app_launcher"

  # No Developer ID certificate: every release is signed ad-hoc
  # (`codesign --force --sign -`), which Gatekeeper treats as untrusted.
  # Without this, macOS refuses to open the app at all ("KitsuneLauncher.app
  # is damaged and can't be opened" / "cannot verify developer"). Casks
  # for notarized apps don't need this — this one does because there is no
  # Developer ID to notarize with.
  postflight do
    system_command "/usr/bin/xattr",
                    args: ["-dr", "com.apple.quarantine", "#{appdir}/KitsuneLauncher.app"]
  end

  app "KitsuneLauncher.app"

  zap trash: [
    "~/Library/Containers/com.kitsune.launcher",
    "~/.config/kitsune",
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
