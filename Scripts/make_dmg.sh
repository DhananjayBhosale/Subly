#!/bin/bash
# Builds Subly.app and wraps it in a disk image people can download: open it, drag
# Subly to Applications. Output: build/Subly-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Scripts/build_app.sh" release

APP="$ROOT/build/Subly.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/Subly-$VERSION.dmg"
STAGE="$(mktemp -d -t subly-dmg)"
trap 'rm -rf "$STAGE"' EXIT

echo "▸ Making disk image…"
ditto "$APP" "$STAGE/Subly.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Subly $VERSION" -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
hdiutil verify -quiet "$DMG"

echo "✓ $DMG"
echo "  size: $(du -h "$DMG" | cut -f1)"
echo "  sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
