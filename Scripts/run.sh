#!/bin/bash
# Build and launch Subly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Scripts/build_app.sh" release
echo "▸ Launching…"
open "$ROOT/build/Subly.app"
