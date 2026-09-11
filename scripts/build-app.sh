#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# `--dev` emits `Kitsune (Dev).app` instead: a separate bundle id, so a separate
# container, so its own IPC socket and its own TCC grants. That is the whole point --
# the two builds are meant to be resident side by side without one silently shadowing
# the other's socket, and it stays obvious which one is answering.
#
# The host derives its socket path from `Bundle.main.bundleIdentifier`, so nothing in
# the Swift needs to know which variant this is. `kitsunectl` still defaults to the main
# app; reach a dev build with KITSUNE_BUNDLE_ID=com.kitsune.launcher.dev.
VARIANT=main
[ "${1:-}" = "--dev" ] && VARIANT=dev

if [ "$VARIANT" = dev ]; then
  APP="$ROOT/.build/Kitsune (Dev).app"
  BUNDLE_ID=com.kitsune.launcher.dev
  BUNDLE_NAME="Kitsune (Dev)"
  EXECUTABLE=KitsuneLauncherDev
else
  APP="$ROOT/.build/KitsuneLauncher.app"
  BUNDLE_ID=com.kitsune.launcher
  BUNDLE_NAME=KitsuneLauncher
  EXECUTABLE=KitsuneLauncher
fi

swift build -c release --package-path "$ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/KitsuneLauncher" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Version stamping: derived from git, never hand-edited into the checked-in
# plist. `git describe` degrades gracefully when there are no tags yet (falls
# back to an abbreviated commit hash via --always); CFBundleVersion uses the
# commit count so it only ever increases build over build.
SHORT_VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo "0.0.0")
BUILD_VERSION=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo "0")
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$PLIST"

# Identity. Stamped rather than kept in a second checked-in plist, so the two variants
# cannot drift apart: `Resources/Info.plist` stays the single source for everything else
# (LSUIElement, minimum system version, the icon name).
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $BUNDLE_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$PLIST"

# App icon: build the .icns from the committed iconset (regenerate the
# iconset itself with scripts/generate-icon.py) and drop it where
# CFBundleIconFile in Info.plist expects it.
ICONSET="$ROOT/Resources/AppIcon.iconset"
if [ -d "$ICONSET" ]; then
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Menu bar glyph: a template image (black + alpha), which the status item loads
# by name at runtime and macOS retints for the light and dark menu bar.
for TEMPLATE in "$ROOT"/Resources/MenuBarIconTemplate*.png; do
  [ -f "$TEMPLATE" ] && cp "$TEMPLATE" "$APP/Contents/Resources/"
done

# Sign last: any edit to the bundle's contents after signing invalidates the
# signature, so the plist and icon must land before codesign runs.
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
