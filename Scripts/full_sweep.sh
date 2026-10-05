#!/bin/bash
# Full verification sweep: every installed language, both engines, all headless paths.
# Run from the repo, wherever it is cloned.
cd "$(cd "$(dirname "$0")/.." && pwd)"
OUT=build/sweep; mkdir -p "$OUT"; : > "$OUT/report.txt"
say_() { echo "$1" | tee -a "$OUT/report.txt"; }

say_ "SUBLY FULL SWEEP — $(date '+%Y-%m-%d %H:%M')"
say_ "=========================================="
say_ ""
say_ "--- unit tests ---"
swift test 2>&1 | tail -1 | tee -a "$OUT/report.txt"
say_ ""
say_ "--- capability registry ---"
./.build/debug/subly-cli caps 2>&1 | head -4 | tee -a "$OUT/report.txt"
TOTAL=$(./.build/debug/subly-cli caps 2>&1 | grep -cE "^  [a-z]")
say_ "total languages offered: $TOTAL"
say_ ""
say_ "--- locale reservation pool ---"
./.build/debug/subly-cli pool 2>&1 | tee -a "$OUT/report.txt"
say_ ""

run() {
  local fixture=$1 lang=$2 outs=$3 label=$4
  say_ "### $label ($lang) outputs=$outs"
  if ./.build/debug/subly-cli generate "$fixture" "$lang" "$outs" en > "$OUT/$lang.log" 2>&1; then
    grep -E "^engine:|^words:|^elapsed:|^mean confidence" "$OUT/$lang.log" | sed 's/^/    /' | tee -a "$OUT/report.txt"
    grep -E "^(PASS|FAIL|NOTE) " "$OUT/$lang.log" | sed 's/^/    align: /' | tee -a "$OUT/report.txt"
    grep -E "^validation:|^export check:" "$OUT/$lang.log" | sed 's/^/    /' | tee -a "$OUT/report.txt"
    grep -A3 "^=== FAILURES" "$OUT/$lang.log" | grep -E "^  " | sed 's/^/    /' | tee -a "$OUT/report.txt"
    say_ "    RESULT: OK"
  else
    say_ "    RESULT: FAILED"
    tail -2 "$OUT/$lang.log" | sed 's/^/    /' | tee -a "$OUT/report.txt"
  fi
  say_ ""
}

say_ "=== APPLE ENGINES ==="
./.build/debug/subly-cli ext off hi >/dev/null 2>&1
run fixtures/en.wav       en-US original            "English (SpeechTranscriber)"
run fixtures/hi.wav       hi-IN original,romanized  "Hindi flagship (DictationTranscriber)"
run fixtures/ja2.wav      ja-JP original,romanized  "Japanese CJK"
run fixtures/zh.wav       zh-CN original,romanized  "Chinese CJK"
run fixtures/ko.wav       ko-KR original,romanized  "Korean"
run fixtures/es.wav       es-ES original            "Spanish Latin"
run fixtures/ru.wav       ru-RU original,romanized  "Russian Cyrillic"
run fixtures/ar.wav       ar-SA original,romanized  "Arabic RTL"
run fixtures/en_hevc10.mp4 en-US original           "HEVC 10-bit video"
run fixtures/hi_video.mp4 hi-IN original,romanized  "Hindi vertical 1080x1920 video"

say_ "=== EXTENDED ENGINE (downloaded models) ==="
./.build/debug/subly-cli ext on hi >/dev/null 2>&1
run fixtures/hi.wav       hi-IN romanized           "Hindi via Apex (writes Hinglish from audio)"
./.build/debug/subly-cli ext off hi >/dev/null 2>&1

say_ "=== pool after sweep ==="
./.build/debug/subly-cli pool 2>&1 | tee -a "$OUT/report.txt"
say_ ""
say_ "SWEEP COMPLETE"
