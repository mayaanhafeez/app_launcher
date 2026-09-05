#!/bin/sh
# Build a signed release .app and zip it for attachment to a GitHub release.
#
# Usage:
#   scripts/release.sh
#
# Produces dist/KitsuneLauncher-<version>-macos.zip and prints its sha256,
# which is what Casks/kitsune.rb's `sha256` field needs after you tag a
# release and upload the zip as a release asset.
#
# NOTE: this is an ad-hoc signed build (no Developer ID certificate).
# Gatekeeper will quarantine-block the downloaded zip on a fresh machine;
# see Casks/kitsune.rb's caveats for the `xattr -dr com.apple.quarantine` step
# users (and the cask) need to run after install.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"

APP=$("$ROOT/scripts/build-app.sh" | tail -1)

VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo "0.0.0")
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
printf 'Next steps:\n'
printf '  1. Tag the release, e.g.: git tag v0.1.0 && git push origin v0.1.0\n'
printf '  2. Create a GitHub release and attach %s\n' "$DIST/$ZIP_NAME"
printf '  3. Update Casks/kitsune.rb: version, url (the release asset URL) and sha256 above\n'
