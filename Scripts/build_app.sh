#!/bin/bash
# Assembles Subly.app from the SPM executable. No Xcode project required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Subly.app"
BUNDLE_ID="com.subly.local"
VERSION="1.1"
# The commit's date, so each release build is numbered higher than the last.
BUILD="$(git -C "$ROOT" log -1 --format=%cd --date=format:%Y%m%d.%H%M 2>/dev/null || date +%Y%m%d.%H%M)"
# Set SIGN_IDENTITY to a "Developer ID Application: …" certificate for a release that
# can be notarized. Without it the bundle is signed ad hoc, for this Mac only.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▸ Building ($CONFIG)…"
cd "$ROOT"
# The compiler's exit status decides. This used to pipe the build through `grep ...
# || true`, which discarded it: a failing build printed its error and the script went
# on to sign and announce a bundle built from the PREVIOUS binary still sitting at the
# bin path. Every "build succeeded" after a broken edit was a lie.
LOG="$(mktemp -t subly-build)"
if ! swift build -c "$CONFIG" --product SublyApp > "$LOG" 2>&1; then
    echo "✗ build failed:"
    grep -E "error:" "$LOG" | head -20 || tail -20 "$LOG"
    rm -f "$LOG"
    exit 1
fi
grep -E "warning: will never be executed" "$LOG" || true
rm -f "$LOG"
BIN="$(swift build -c "$CONFIG" --product SublyApp --show-bin-path)/SublyApp"
[ -f "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Subly"
# Drop the debug map: it lists every object file by its path on this Mac.
strip -S -x "$APP/Contents/MacOS/Subly"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Required: without NSPrincipalClass, AppKit never initialises and the
       SwiftUI WindowGroup produces no window at all. -->
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleName</key><string>Subly</string>
  <key>CFBundleDisplayName</key><string>Subly</string>
  <key>CFBundleExecutable</key><string>Subly</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Dhananjay Bhosale. MIT licence.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Subly transcribes the audio of files you choose. Recognition runs entirely on this Mac.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Subly opens the videos you choose and saves subtitle files and captioned videos where you ask.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Subly opens the videos you choose and saves subtitle files and captioned videos where you ask.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Subly opens the videos you choose and saves subtitle files and captioned videos where you ask.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Subly opens videos you choose from external drives.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Movie</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string><string>public.audio</string>
        <string>public.mpeg-4</string><string>com.apple.quicktime-movie</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Bundle the statically linked whisper.cpp runtime for the optional Extended Engine.
# Built with -DGGML_BACKEND_DL=OFF so Metal is embedded and nothing is loaded from
# Homebrew at runtime — the bundle is self-contained (PRD EXT-05).
# A helper executable lives in Contents/Helpers, where code signing and notarization
# expect nested code. In Resources it was left with only the linker's signature.
if [ -f "$ROOT/Resources/engine/whisper-cli" ]; then
  mkdir -p "$APP/Contents/Helpers"
  cp "$ROOT/Resources/engine/whisper-cli" "$APP/Contents/Helpers/whisper-cli"
  chmod +x "$APP/Contents/Helpers/whisper-cli"
  echo "▸ Engine runtime bundled ($(du -sh "$ROOT/Resources/engine/whisper-cli" | awk '{print $1}'))"
fi

# Licences for what ships inside the app, shown from Settings › About.
{
  echo "Subly"; echo; cat "$ROOT/LICENSE"; echo; echo "----"; echo
  # Only when the runtime ships; a checkout without it builds the Apple-only app.
  if [ -f "$APP/Contents/Helpers/whisper-cli" ]; then
    echo "whisper.cpp v1.9.4 (bundled as the speech runtime) — https://github.com/ggml-org/whisper.cpp"; echo
    if [ -f "$ROOT/vendor/whisper.cpp/LICENSE" ]; then cat "$ROOT/vendor/whisper.cpp/LICENSE"
    else echo "MIT License. Copyright (c) 2023-2026 The ggml authors. See https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE"; fi
    echo; echo "----"; echo
  fi
  echo "Speech models (downloaded only when you choose to):"
  echo "• OpenAI Whisper models, GGML conversions from the whisper.cpp project — MIT licence."
  echo "• Whisper-Hindi2Hinglish-Apex by Oriserve, GGML conversion by Marquestra — Apache-2.0, as stated on the model page. The weights were converted and quantised; OpenAI's MIT notice for the underlying Whisper model applies."
} > "$APP/Contents/Resources/Acknowledgements.txt"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "▸ Icon embedded"
fi

cat > "$ROOT/build/Subly.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><false/>
</dict>
</plist>
ENT

# Inside out: the helper first, then the app around it. A signing failure stops the
# build — it used to be hidden by "|| true".
TIMESTAMP=""
[ "$SIGN_IDENTITY" != "-" ] && TIMESTAMP="--timestamp"
echo "▸ Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo "ad hoc" || echo "$SIGN_IDENTITY"))…"
if [ -f "$APP/Contents/Helpers/whisper-cli" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP "$APP/Contents/Helpers/whisper-cli"
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP \
  --entitlements "$ROOT/build/Subly.entitlements" "$APP"

codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -2
echo "✓ $APP"
du -sh "$APP" | awk '{print "  size: "$1}'
