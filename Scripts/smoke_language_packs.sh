#!/bin/zsh
# Smoke-test the language models that are downloaded on this Mac.
#
#   Scripts/smoke_language_packs.sh                  every downloaded language model
#   Scripts/smoke_language_packs.sh sv de            only the models for these languages
#   Scripts/smoke_language_packs.sh --download-each  download each model in turn with the
#                                                    app's own downloader (checksum checked),
#                                                    test it, delete it, then the next one
#
# For each model it speaks one sentence in the model's language with a macOS voice,
# runs the model exactly as the app does (subly-cli pack-smoke: language code, -nt,
# alignment preset), and prints the transcript and word times next to the sentence.
# Without --download-each it downloads nothing: a model that is not downloaded is
# skipped — download it in Subly › Speech Models. A language with no macOS voice is run
# on the English clip instead: that proves the model loads and times words, not more. Synthetic speech proves the model loads, gets the language
# and script right and times its words; it says little about accuracy on real videos.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DOWNLOAD=0
if [[ "${1:-}" == "--download-each" ]]; then DOWNLOAD=1; shift; fi
OUT="$ROOT/build/smoke"
mkdir -p "$OUT"
swift build --product subly-cli > /dev/null
CLI="$ROOT/.build/debug/subly-cli"

# language | macOS voice | sentence
typeset -A VOICE TEXT
VOICE[en]=Samantha; TEXT[en]="The battery lasts five to six days, and it works with the iPhone too."
VOICE[sv]=Alva;     TEXT[sv]="Batteriet räcker i fem till sex dagar och fungerar även med iPhone."
VOICE[nb]=Nora;     TEXT[nb]="Batteriet varer i fem til seks dager, og det fungerer også med iPhone."
VOICE[da]=Sara;     TEXT[da]="Batteriet holder fem til seks dage, og det virker også med iPhone."
VOICE[fi]=Satu;     TEXT[fi]="Akku kestää viidestä kuuteen päivää, ja se toimii myös iPhonen kanssa."
VOICE[de]=Anna;     TEXT[de]="Der Akku hält fünf bis sechs Tage, und er funktioniert auch mit dem iPhone."
VOICE[fr]=Thomas;   TEXT[fr]="La batterie dure cinq à six jours et fonctionne aussi avec l'iPhone."
VOICE[ru]=Milena;   TEXT[ru]="Батарея работает пять-шесть дней, и она работает даже с айфоном."
VOICE[hr]=Lana;     TEXT[hr]="Baterija traje pet do šest dana i radi i s iPhoneom."
VOICE[tr]=Yelda;    TEXT[tr]="Pil beş ila altı gün dayanıyor ve iPhone ile de çalışıyor."
VOICE[he]=Carmit;   TEXT[he]="הסוללה מחזיקה חמישה עד שישה ימים, והיא עובדת גם עם אייפון."
VOICE[ar]=Majed;    TEXT[ar]="تدوم البطارية من خمسة إلى ستة أيام، وتعمل أيضاً مع الآيفون."
VOICE[th]=Kanya;    TEXT[th]="แบตเตอรี่ใช้งานได้ห้าถึงหกวัน และใช้กับไอโฟนได้ด้วย"
VOICE[vi]=Linh;     TEXT[vi]="Pin dùng được năm đến sáu ngày và cũng hoạt động với iPhone."
VOICE[zh]=Tingting; TEXT[zh]="电池可以用五到六天，也可以在苹果手机上使用。"
VOICE[yue]=Sinji;   TEXT[yue]="部電話嘅電池可以用五至六日，喺iPhone都用得。"
VOICE[ko]=Yuna;     TEXT[ko]="배터리는 오일에서 육일 동안 지속되고 아이폰에서도 작동합니다."
VOICE[bn]=Piya;     TEXT[bn]="ব্যাটারি পাঁচ থেকে ছয় দিন চলে, আর আইফোনেও কাজ করে।"
VOICE[ta]=Vani;     TEXT[ta]="பேட்டரி ஐந்து முதல் ஆறு நாட்கள் வரை நீடிக்கும், ஐபோனிலும் வேலை செய்யும்."

# pack id and its first language, from the catalogue.
PACKS=$(grep -E 'id: "[^"]+", name:' Sources/SublyEngine/LanguagePacks.swift \
    | sed -E 's/.*id: "([^"]+)".*languages: \["([^"]+)".*/\1 \2/')

typeset -i ran=0 skipped=0 failed=0
while read -r id lang; do
    [[ -z "$id" ]] && continue
    if (( $# > 0 )) && [[ ${@[(Ie)$lang]} -eq 0 ]]; then continue; fi
    speak=$lang
    [[ -z "${VOICE[$lang]:-}" ]] && speak=en          # no voice: load-and-run check only
    clip="$OUT/$speak.wav"
    if [[ ! -f "$clip" ]]; then
        say -v "${VOICE[$speak]}" -o "$OUT/$speak.aiff" "${TEXT[$speak]}"
        afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/$speak.aiff" "$clip"
    fi
    echo "== $id ($lang)$([[ $speak != $lang ]] && echo ' — no voice, English clip, load check only')"
    echo "   said: ${TEXT[$speak]}"
    fetched=0
    if (( DOWNLOAD )); then
        free=$(df -k "$HOME" | awk 'NR==2 {print $4}')
        if (( free < 6000000 )); then echo "   STOPPED: under 6 GB free"; break; fi
        # Delete afterwards only what this run downloaded, never a model already here.
        had=0; [[ -f "$HOME/Library/Application Support/Subly/Engines/$id.bin" ]] && had=1
        if out=$("$CLI" pack-install "$id" 2>&1); then (( had )) || fetched=1; echo "   $out"
        else echo "   $(echo "$out" | tail -1)"; failed+=1; continue; fi
    fi
    if result=$("$CLI" pack-smoke "$id" "$clip" "$lang" 2>&1); then
        echo "$result" | sed 's/^/   /'
        ran+=1
    else
        echo "$result" | tail -1 | sed 's/^/   /'
        if (( DOWNLOAD )); then failed+=1; else skipped+=1; fi
    fi
    (( fetched )) && echo "   $("$CLI" pack-delete "$id" 2>&1 | tail -1)"
done <<< "$PACKS"
echo "ran $ran, failed $failed, skipped $skipped"
