#!/bin/sh
# Point Casks/kitsune.rb at a release: rewrite its `version` and `sha256`.
#
# Usage:
#   scripts/bump-cask.sh <version> <sha256>     # version without the leading "v"
#
# The release workflow runs this after uploading the zip, then commits the cask to
# main. This repo *is* the tap, so that commit is the whole of publishing: the next
# `brew update` sees the new version and `brew upgrade` installs it. The cask's `url`
# is derived from `version`, so these two lines are the only ones that change.
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <version> <sha256>" >&2; exit 2; }
VERSION=$1
SHA256=$2
CASK=${CASK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/Casks/kitsune.rb}

# A "v" here would become "vv1.0.0" in the download URL, and a pre-release must never
# reach the cask: every tap user would be upgraded onto it.
case $VERSION in
  v*) echo "version must not start with v: $VERSION" >&2; exit 1 ;;
  *-*) echo "refusing to publish a pre-release to the cask: $VERSION" >&2; exit 1 ;;
esac
printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' || { echo "not a sha256: $SHA256" >&2; exit 1; }

sed -i '' \
  -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"$/  sha256 \"$SHA256\"/" \
  "$CASK"

# sed exits 0 when nothing matched, which would publish an unchanged cask.
grep -q "^  version \"$VERSION\"$" "$CASK" || { echo "version line not rewritten in $CASK" >&2; exit 1; }
grep -q "^  sha256 \"$SHA256\"$" "$CASK" || { echo "sha256 line not rewritten in $CASK" >&2; exit 1; }
