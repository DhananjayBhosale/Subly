#!/bin/bash
# Makes the test clips in fixtures/ on this Mac, with macOS's own voices (`say`) and
# ffmpeg. They are not in git: recordings of Apple's system voices may be used on your
# own Mac but not shared publicly. Needs the voices below (System Settings ›
# Accessibility › Spoken Content › System Voice › Manage Voices) and ffmpeg.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p fixtures
cd fixtures
command -v ffmpeg >/dev/null || { echo "✗ ffmpeg is needed (brew install ffmpeg)"; exit 1; }

speak() {  # name voice text — writes <name>.wav, 16 kHz mono 16-bit
    local name=$1 voice=$2 text=$3
    if ! say -v "$voice" -o "${name}_raw.aiff" "$text" 2>/dev/null; then
        echo "  skipped $name: the voice \"$voice\" is not installed"; return
    fi
    afconvert -f WAVE -d LEI16@16000 -c 1 "${name}_raw.aiff" "$name.wav"
    rm -f "${name}_raw.aiff"
    echo "  $name.wav"
}

video() {  # name audio size [codec options…] — a plain coloured picture with the audio
    local name=$1 audio=$2 size=$3; shift 3
    [ -f "$audio" ] || return 0
    local codec=("$@")
    [ ${#codec[@]} -eq 0 ] && codec=(-c:v libx264 -pix_fmt yuv420p)
    ffmpeg -loglevel error -y -f lavfi -i "color=c=0x24405a:s=$size:r=30" -i "$audio" \
        "${codec[@]}" -c:a aac -b:a 96k -shortest "$name"
    echo "  $name"
}

echo "▸ Speech"
speak en Samantha "Here there are far fewer reflections. At high brightness it feels crease free. The camera shoots at f one point four eight and the display is incredibly bright."
speak hi Lekha "आप कैसे हो। यह iPhone का display बहुत अच्छा है। camera की quality भी शानदार है।"
speak es Mónica "Hola, este teléfono tiene una pantalla excelente y la cámara es muy buena."
speak ja Kyoko "こんにちは。この iPhone のディスプレイはとても綺麗です。"
speak ja2 Kyoko "こんにちは。この iPhone のディスプレイはとても綺麗です。カメラの画質も素晴らしい。"
speak ko Yuna "안녕하세요. 이 폰은 디스플레이가 훌륭하고 카메라도 아주 좋습니다."
speak zh Tingting "你好。这个手机的屏幕非常好，相机也很棒。"
speak ru Milena "Здравствуйте. Этот телефон имеет отличный дисплей и очень хорошую камеру."
speak ar Majed "مرحبا. هذا الهاتف لديه شاشة ممتازة والكاميرا جيدة جدا."
# About five minutes of English, for the long-file and cancel tests.
LONG=""
for _ in $(seq 1 24); do
    LONG+="Here there are far fewer reflections. At high brightness it feels crease free. "
    LONG+="The camera shoots at f one point four eight and the display is incredibly bright. [[slnc 1500]] "
done
speak en_long Samantha "$LONG"

echo "▸ Video"
video en_video.mp4 en.wav 1920x1080
video hi_video.mp4 hi.wav 1080x1920
video es_video.mp4 es.wav 1280x720
video ja_video.mp4 ja.wav 1080x1920
video en_hevc10.mp4 en.wav 1280x720 -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1

echo "▸ Edge cases"
ffmpeg -loglevel error -y -f lavfi -i "color=c=black:s=640x360:r=30:d=3" -c:v libx264 -pix_fmt yuv420p silent_video.mp4
ffmpeg -loglevel error -y -f lavfi -i "testsrc=s=320x240:r=30:d=2" -f lavfi -i "sine=f=440:d=2" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest test.mkv
head -c 2048 /dev/urandom > corrupt.mp4
echo "✓ fixtures ready"
