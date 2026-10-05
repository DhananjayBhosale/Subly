#!/bin/bash
# Builds the whisper.cpp runtime that ships inside Subly.app.
#
# The binary itself is not in git (Resources/engine/ is ignored), so this script is
# the record of how to reproduce it. Pin the version here, not in a commit message.
set -euo pipefail

WHISPER_VERSION="v1.9.4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/whisper.cpp"
OUT="$ROOT/Resources/engine"

if [ ! -d "$SRC/.git" ]; then
    echo "▸ Cloning whisper.cpp…"
    mkdir -p "$ROOT/vendor"
    git clone --quiet https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi

echo "▸ Checking out $WHISPER_VERSION…"
git -C "$SRC" fetch --tags --quiet origin
git -C "$SRC" checkout --quiet "$WHISPER_VERSION"

# GGML_BACKEND_DL=OFF and the embedded Metal library are what make the result
# self-contained: nothing is dlopened from Homebrew at runtime, which the app depends
# on because it ships to machines that have never seen a package manager.
# The prefix map writes source paths as "whisper.cpp/…" instead of this Mac's folder,
# which assert messages would otherwise carry into the shipped binary.
MAP="-ffile-prefix-map=$SRC=whisper.cpp"
echo "▸ Configuring…"
rm -rf "$SRC/build-engine"
cmake -B "$SRC/build-engine" -S "$SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$MAP" -DCMAKE_CXX_FLAGS="$MAP" -DCMAKE_OBJC_FLAGS="$MAP" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON > /dev/null

echo "▸ Building…"
cmake --build "$SRC/build-engine" --config Release -j"$(sysctl -n hw.ncpu)" > /dev/null

mkdir -p "$OUT"
cp "$SRC/build-engine/bin/whisper-cli" "$OUT/whisper-cli"
chmod +x "$OUT/whisper-cli"
strip -S -x "$OUT/whisper-cli"

if strings -a "$OUT/whisper-cli" | grep -q "$HOME"; then
    echo "✗ the binary still contains paths from this Mac"
    exit 1
fi

# Fail loudly if anything outside the system crept into the link. A Homebrew dylib
# here would break the app on any machine but this one.
echo "▸ Checking the binary is self-contained…"
if otool -L "$OUT/whisper-cli" | tail -n +2 | grep -vE "^\s+(/System/|/usr/lib/)"; then
    echo "✗ links something outside the system — the bundle would not be portable"
    exit 1
fi

echo "✓ $OUT/whisper-cli  ($WHISPER_VERSION, $(du -h "$OUT/whisper-cli" | cut -f1))"
