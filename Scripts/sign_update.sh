#!/bin/bash
# Signs a release so installed copies of Subly will update to it.
#
#   Scripts/sign_update.sh <Subly.dmg> <notes.md> [--version V] [--url U] [--out DIR]
#
# Writes update.json, update.json.sig and SHA256SUMS.txt into DIR (default build/).
# The signature is Ed25519, made with the private key in the login Keychain
# ("Subly update signing key"). The public half is built into the app
# (AppUpdate.publicKey), so a copy of Subly installs only what this key signed.
#
# The key goes from `security` into the signer through a pipe. It is never printed,
# written to a file or passed as an argument. If the Keychain asks, that is the
# only prompt; losing the key means installed copies cannot be updated in the app
# and people must download the next release by hand once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PLIST="$ROOT/build/Subly.app/Contents/Info.plist"
OUT="$ROOT/build"
VERSION=""
URL=""
DMG=""
NOTES=""

usage() { echo "usage: Scripts/sign_update.sh <Subly.dmg> <notes.md> [--version V] [--url U] [--out DIR]"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --url)     URL="${2:?--url needs a value}"; shift 2 ;;
        --out)     OUT="${2:?--out needs a folder}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "✗ unknown option $1" >&2; usage >&2; exit 2 ;;
        *)         if [ -z "$DMG" ]; then DMG="$1"; elif [ -z "$NOTES" ]; then NOTES="$1"
                   else echo "✗ too many arguments" >&2; exit 2; fi
                   shift ;;
    esac
done
[ -n "$DMG" ] && [ -n "$NOTES" ] || { usage >&2; exit 2; }
[ -f "$DMG" ] || { echo "✗ no such disk image: $DMG" >&2; exit 1; }
[ -f "$NOTES" ] || { echo "✗ no such notes file: $NOTES" >&2; exit 1; }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PLIST" 2>/dev/null || true; }
[ -n "$VERSION" ] || VERSION="$(plist_value CFBundleShortVersionString)"
[ -n "$VERSION" ] || { echo "✗ no version: build the app first or pass --version" >&2; exit 1; }
BUILD="$(plist_value CFBundleVersion)"
[ -n "$URL" ] || URL="https://github.com/DhananjayBhosale/Subly/releases/download/v$VERSION/Subly.dmg"

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
SIZE="$(stat -f%z "$DMG")"
mkdir -p "$OUT"

# Built from the app's own AppUpdate.swift, so the manifest and the final check are
# exactly what the app will do.
TOOLS="$(mktemp -d -t subly-sign)"
trap 'rm -rf "$TOOLS"' EXIT
echo "▸ Building the signer…"
swiftc -O -parse-as-library -o "$TOOLS/sign_update" \
    "$ROOT/Scripts/sign_update.swift" "$ROOT/Sources/SublyEngine/AppUpdate.swift"

rm -f "$OUT/update.json" "$OUT/update.json.sig"
"$TOOLS/sign_update" manifest --out "$OUT/update.json" --version "$VERSION" --build "$BUILD" \
    --url "$URL" --sha256 "$SHA" --size "$SIZE" --notes "$NOTES" --minimum-system "26.0"

echo "▸ Signing update.json with the Keychain key…"
if ! /usr/bin/security find-generic-password -s "Subly update signing key" -w \
        | "$TOOLS/sign_update" sign "$OUT/update.json" "$OUT/update.json.sig"; then
    rm -f "$OUT/update.json.sig"
    echo "✗ couldn't sign: is \"Subly update signing key\" in the login Keychain, and unlocked?" >&2
    exit 1
fi

FILE_FLAG=""
case "$URL" in file:*) FILE_FLAG="--allow-file-urls" ;; esac
if ! "$TOOLS/sign_update" verify "$OUT/update.json" "$OUT/update.json.sig" $FILE_FLAG; then
    rm -f "$OUT/update.json.sig"
    echo "✗ the signature does not verify; nothing to upload" >&2
    exit 1
fi

printf '%s  Subly.dmg\n' "$SHA" > "$OUT/SHA256SUMS.txt"

echo "✓ $OUT/update.json"
echo "  $OUT/update.json.sig"
echo "  $OUT/SHA256SUMS.txt"
echo "  version $VERSION, $SIZE bytes, sha256 $SHA"
echo "  url $URL"
