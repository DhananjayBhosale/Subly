#!/bin/bash
# Real-footage tests: 4K, HEVC, vertical, and long-form.
# Run from the repo, wherever it is cloned.
cd "$(cd "$(dirname "$0")/.." && pwd)"
D="${1:-$HOME/Downloads}"; OUT=build/realvideo; mkdir -p "$OUT"; : > "$OUT/report.txt"
log() { echo "$1" | tee -a "$OUT/report.txt"; }

log "REAL VIDEO TESTS — $(date '+%H:%M')"
log "================================"
log ""

run() {
  local file="$1" lang="$2" outs="$3" label="$4"
  [ -f "$file" ] || { log "### $label — FILE MISSING"; return; }
  local info
  info=$(ffprobe -v error -show_entries format=duration:stream=codec_name,width,height -of csv=p=0 "$file" 2>/dev/null | tr '\n' ' ')
  local size; size=$(ls -lh "$file" | awk '{print $5}')
  log "### $label"
  log "    file: $(basename "$file") · $size · $info"
  local start; start=$(date +%s)
  local slug; slug=$(echo "$label" | tr ' /' '__')
  if /usr/bin/time -l ./.build/debug/subly-cli generate "$file" "$lang" "$outs" en \
       > "$OUT/$slug.log" 2> "$OUT/$slug.time"; then
    local el=$(( $(date +%s) - start ))
    grep -E "^engine:|^words:|^language:|^elapsed:|^mean confidence" "$OUT/$slug.log" | sed 's/^/    /' | tee -a "$OUT/report.txt"
    grep -E "^(PASS|FAIL|NOTE) " "$OUT/$slug.log" | sed 's/^/    align: /' | tee -a "$OUT/report.txt"
    grep -E "^validation:" "$OUT/$slug.log" | sed 's/^/    /' | tee -a "$OUT/report.txt"
    local rss; rss=$(grep "maximum resident" "$OUT/$slug.time" | awk '{print int($1/1048576)"MB"}')
    log "    peak memory: $rss"
    log "    wall: ${el}s"
    log "    RESULT: OK"
  else
    log "    RESULT: FAILED"
    tail -3 "$OUT/$slug.log" | sed 's/^/    /' | tee -a "$OUT/report.txt"
  fi
  log ""
}

# Runs over whatever real footage is in the folder, rather than naming specific files.
# The point of this script is footage the synthetic `say` fixtures cannot represent:
# long recordings, vertical phone video, 4K HEVC, real room noise. Supply your own.
#
#   ./Scripts/test_real_videos.sh ~/Videos      # or any folder
#   SUBLY_LANG=hi-IN ./Scripts/test_real_videos.sh ~/Videos
shopt -s nullglob nocaseglob
found=0
for f in "$D"/*.mp4 "$D"/*.mov "$D"/*.m4v "$D"/*.m4a; do
  size=$(stat -f%z "$f")
  [ "$size" -lt 100000 ] && continue        # skip thumbnails and stubs
  run "$f" "${SUBLY_LANG:-en-US}" original "$(basename "$f")"
  found=$((found + 1))
  [ "$found" -ge "${SUBLY_MAX_VIDEOS:-4}" ] && break
done

if [ "$found" -eq 0 ]; then
  log "No media found in $D"
  log "Pass a folder: ./Scripts/test_real_videos.sh ~/Videos"
  exit 1
fi

log "REAL VIDEO TESTS COMPLETE"
