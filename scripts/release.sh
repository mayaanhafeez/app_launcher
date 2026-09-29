#!/bin/sh
# Build a signed release .app and zip it for attachment to a GitHub release.
#
# Usage:
#   scripts/release.sh
#
# Produces dist/KitsuneLauncher-<version>-macos.zip and prints its sha256. The
# release workflow runs this on a tag push and hands the sha256 to
# scripts/bump-cask.sh; running it by hand is for trying a build locally.
#
# NOTE: this is an ad-hoc signed build (no Developer ID certificate).
# Gatekeeper will quarantine-block the downloaded zip on a fresh machine;
# the cask strips the flag in its postflight_steps; a direct download needs
# `xattr -dr com.apple.quarantine` by hand.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"

APP=$("$ROOT/scripts/build-app.sh" | tail -1)

VERSION=${KITSUNE_VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo "0.0.0")}
ZIP_NAME="KitsuneLauncher-$VERSION-macos.zip"

rm -rf "$DIST"
mkdir -p "$DIST"

# ditto (not zip) preserves the app bundle's resource forks and extended
# attributes, which is what keeps the ad-hoc code signature intact inside
# the archive.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP_NAME"

SHA256=$(shasum -a 256 "$DIST/$ZIP_NAME" | awk '{print $1}')

printf 'version:  %s\n' "$VERSION"
printf 'archive:  %s\n' "$DIST/$ZIP_NAME"
printf 'sha256:   %s\n' "$SHA256"
printf '\n'
printf 'Normally you do not run this by hand: pushing a v* tag runs it in CI\n'
printf '(.github/workflows/release.yml), which also publishes the release and the cask.\n'
