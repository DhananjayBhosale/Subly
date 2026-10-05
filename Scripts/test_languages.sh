#!/bin/bash
# Multi-language end-to-end test. Downloads Apple speech assets as needed.
# Run from the repo, wherever it is cloned.
cd "$(cd "$(dirname "$0")/.." && pwd)"
OUT=build/lang-test
mkdir -p "$OUT"
: > "$OUT/summary.txt"

run() {
  local fixture=$1 lang=$2 outputs=$3 label=$4
  echo "═══ $label ($lang) ═══" | tee -a "$OUT/summary.txt"
  local start=$(date +%s)
  if ./.build/debug/subly-cli generate "$fixture" "$lang" "$outputs" en \
       > "$OUT/$lang.log" 2>&1; then
    local el=$(( $(date +%s) - start ))
    {
      grep -E "^engine:|^words:|^language:|^elapsed:" "$OUT/$lang.log" | sed 's/^/  /'
      grep -E "^(PASS|FAIL|NOTE)" "$OUT/$lang.log" | sed 's/^/  align: /'
      grep -E "^validation:" "$OUT/$lang.log" | sed 's/^/  /'
      echo "  wall: ${el}s"
      echo "  RESULT: OK"
    } | tee -a "$OUT/summary.txt"
  else
    { echo "  RESULT: FAILED"; tail -4 "$OUT/$lang.log" | sed 's/^/  /'; } | tee -a "$OUT/summary.txt"
  fi
  echo "" | tee -a "$OUT/summary.txt"
}

run fixtures/en.wav  en-US original                       "English"
run fixtures/hi.wav  hi-IN original,romanized,translation  "Hindi (flagship, 3 tracks)"
run fixtures/ja2.wav ja-JP original,romanized,translation  "Japanese (CJK)"
run fixtures/zh.wav  zh-CN original,romanized,translation  "Chinese (CJK)"
run fixtures/ko.wav  ko-KR original,romanized,translation  "Korean"
run fixtures/es.wav  es-ES original,translation            "Spanish (Latin)"
run fixtures/ru.wav  ru-RU original,romanized,translation  "Russian (Cyrillic)"
run fixtures/ar.wav  ar-SA original,romanized,translation  "Arabic (RTL)"

echo "════ DONE ════" | tee -a "$OUT/summary.txt"
