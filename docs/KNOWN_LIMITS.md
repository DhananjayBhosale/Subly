# Known limits

What Subly does not do yet, or does not do well. Plain and current as of version 1.4.

## Installing

- **Not notarized.** The download is ad-hoc signed, so macOS asks you to allow it once
  in System Settings › Privacy & Security › Open Anyway.
- **Apple Silicon and macOS 26 only.** Subly depends on the macOS 26 Speech and
  Translation frameworks. There is no Intel or older-macOS build.

## Privacy

- **Not sandboxed.** The no-upload promise holds by design — the only network requests
  are the model downloads you start, macOS's own speech and translation downloads, and
  the update check — but the operating system does not enforce it, and no automated test
  checks it.
- **The update check is a request to GitHub once a day.** It is a plain request for a small
  signed file: nothing about you or your videos is sent. It can be turned off in
  Settings › General. An update is installed only if our own signature on it verifies;
  macOS cannot check it, because the app is not notarized.
- **macOS can download speech files when you make captions.** The size is shown first,
  but Make Captions does not ask a second time.

## Accuracy

- **Not measured on real-world audio.** There are no reference transcripts, so the word
  error rate on noisy, multi-speaker or music-heavy footage is unknown. Check the
  captions before you publish.
- **Speech recognition is not deterministic.** Two runs on the same file can differ.
- **Very fast speech** can't always fit the caption length rules. Subly keeps every word
  and lists those captions under "Things to check".
- **Romanization is basic for Japanese, Chinese and Korean.** Hindi and other Indic
  languages are better, but schwa deletion (e.g. "kamal" vs "kamala") is not solved.

## Models

- **Apex (Hinglish) is experimental.** It was compared with the other engines on one
  real clip and one synthetic clip, which is not a benchmark. Its model page states
  Apache-2.0; get written confirmation from its authors before commercial
  redistribution. See [MODEL_RESEARCH.md](MODEL_RESEARCH.md).

- **Language models are checked, not measured.** Each of the 34 models made for one
  language was downloaded and run once on synthetic speech before release (six only
  checked to load, having no macOS voice). "Recommended" rests on the numbers its makers
  or an independent benchmark published, not on tests of real creator videos.
- **Chinese, Cantonese and Thai through Whisper** light up a phrase at a time, not each
  word: those languages are written without spaces and whisper.cpp keeps the phrase whole.

## Editing

- **Learned spellings are whole words in English letters.** Changing "yah" to "ye"
  teaches Subly; rewording, grammar fixes and changes in a transcript or translation
  don't (only a word's own capitals, like "iPhone", are learned there). Replace All does
  not teach it either.
- **No per-track caption length.** All tracks share one set of caption rules.
- **Gradient Pop's font covers basic Latin only.** Accented letters used in Croatian,
  Turkish, Latvian, Polish or Vietnamese fall back to another font inside the word.
- **The extra caption fonts are macOS system fonts that cover Latin letters.** Other
  scripts (Devanagari, Arabic, Chinese and so on) fall back to a system font, which may not
  match the chosen font's look.
- **Reference subtitles** load only when an `.srt` or `.vtt` with the same name sits
  next to the video.
- **Accessibility is incomplete.** VoiceOver labels exist for the main controls, but the
  caption list and timeline need more keyboard and VoiceOver work.
