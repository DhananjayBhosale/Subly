# Extended Engine — model selection

A research log, last updated 2026-10-05. Later sections update earlier ones.
**Both packs are provisional candidates, not validated choices.**

## Current packs

| Role | Model | Format | Size | Licence | Status |
|---|---|---|---|---|---|
| General multilingual | `openai/whisper-large-v3-turbo` | GGML q5_0 | 547 MiB | MIT | Provisional |
| Hindi / Hinglish | `Oriserve/Whisper-Hindi2Hinglish-Apex` | GGML q5_0 | ~574 MB | apache-2.0 tag only — see risk below | **Experimental** |

Runtime: whisper.cpp v1.9.4 (see `Scripts/build_engine.sh`) built with `-DBUILD_SHARED_LIBS=OFF
-DGGML_BACKEND_DL=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON`, so the binary is
self-contained with Metal embedded. No Python, no Homebrew, nothing for the user to
install. About 4.4 MB, built into `Resources/engine/whisper-cli` and shipped inside the
app at `Contents/Helpers/whisper-cli`.

## Why Apex is interesting

It writes **romanised Hinglish directly from audio**, removing the transliteration step
entirely for the flagship language. On our Hindi fixture it matched ground truth exactly
where the Apple + ICU pipeline lost *kaise*, dropped *ka*, and dropped *camera*.

## Why that is not yet enough

**One 5.3-second synthetic `say` clip is an integration smoke test, not a model
evaluation.** It proves the converted model runs, produces the desired romanised style,
and handles English insertions in one clean sentence. It says nothing about real creator
footage, accents, microphones, background music, overlapping speech, hesitations,
long-form consistency, or hallucination behaviour. Synthetic TTS should discount the
result almost entirely for selection purposes.

The model card is also weaker evidence than it first looks:

- Results are self-reported, and ground truth was automatically transliterated before
  scoring.
- Absolute WER is still high: 35.96 Common Voice, 29.79 FLEURS, 47.64 IndicVoices.
- Oriserve's own **Prime** model beats Apex on Common Voice and FLEURS; Apex wins only
  IndicVoices.
- "SOTA", "42% improvement" and "ranked #1" must not be repeated as fact.

**So: ship Apex as an experimental Hindi/Hinglish option. Do not claim it was selected
for accuracy until a real benchmark exists.**

### What a sound evaluation requires

3–5 hours of manually transcribed real creator footage, stratified by region, speaker,
recording quality, background music, and Hindi/English mixing ratio. Compare Apex q5,
generic turbo q5, and the Apple pipeline on: normalised WER **and** CER; Hindi-word and
English-word error rates separately; names, numbers and product terms; hallucination
during silence and music; timestamp accuracy; long-file stability; speed, memory and
energy. Report paired confidence intervals, not one aggregate number.

## Translation: keep it separate — confirmed correct

`large-v3-turbo`'s extra fine-tuning used multilingual transcription data and
**excluded translation data**; OpenAI explicitly warns translation quality is not
expected to be good. So: transcribe with turbo, translate the text separately (the app
uses Apple's Translation framework). Do **not** ship `large-v3` (1.1 GiB) merely to
recover Whisper's speech-to-English translation — only ship it if it proves materially
better at *transcription* on target languages. Note turbo has documented larger
degradation on Thai and Cantonese, so a blanket "minor accuracy loss" claim would be
overstated.

## Alternatives worth benchmarking before freezing the general pack

| Model | Size | Licence | Notes |
|---|---|---|---|
| **Meta Omnilingual ASR 300M CTC INT8** | 348 MB | Apache-2.0 | 1,600+ languages, runs via sherpa-onnx which ships a native Swift package. The clearest compact commercially usable challenger. Do not inherit the 7B model's headline numbers |
| **Dolphin small INT8** | ~239 MB | Apache-2.0 | Covers Bengali, Tamil, Telugu, Marathi, Gujarati, Punjabi, Urdu — but **not Kannada or Malayalam**. Published average WER is not clearly better |
| AI4Bharat IndicConformer | 600M | MIT | All 22 official Indian languages, but the official path is Python/NeMo. Third-party ONNX exports exist and are less mature |
| Qwen3-ASR | 0.6B / 1.7B | Apache-2.0 | Modern, but Hindi is its only Indic language and the official runtime is Python |

Both Omnilingual INT8 and Dolphin are credible **size** reductions; neither is a
demonstrated **quality** upgrade. Benchmark before switching.

## Download size

~1.15 GB if a user installs both, which they should rarely need. Acceptable for optional
desktop models **because each pack downloads independently** and the app shows exact
sizes before starting. Keeping q5_0: `medium-q5_0` saves too little to matter, and q4 or
whisper-small would compress hardest exactly where low-resource languages need the most
headroom. Splitting one multilingual checkpoint per language is not practical.

## Licence risk — act on this before selling anything

- **whisper.cpp (MIT) and whisper-large-v3-turbo (MIT): clean.** Closed-source
  commercial redistribution is fine with notices preserved.
- **Apex needs care.** Its model page states Apache-2.0 (see below), but the
  repository contains **no `LICENSE` and no `NOTICE` file**, and the card states its ~700 training
  hours combine unspecified open-source and proprietary datasets. That is not a
  prohibition, but it is inadequate provenance for a paid product.

Before distributing, get written confirmation from Oriserve that the weights may be
redistributed commercially, that their proprietary-data rights permit it, that
Apache-2.0 genuinely applies to the weights, and whether any NOTICE text is required.
For the quantised file, preserve the Apache licence, OpenAI's underlying MIT notice,
attribution, and a statement that the weights were converted and quantised.
**Downloading after install rather than bundling does not remove these obligations.**

## Disqualified

- `distil-whisper/*` — English only.
- `nvidia/canary-*`, `nvidia/parakeet-*` — no Hindi, cc-by-4.0.
- `facebook/mms-*`, `seamless-m4t-*` — cc-by-nc-4.0, non-commercial.
- `ai4bharat/IndicXlit` — fairseq only, no official ONNX/CoreML export for
  indic→roman. Apex removes the need for it in Hindi; ICU covers other scripts.

## Measured on this machine (Apple M4, 16 GB)

| Case | Result |
|---|---|
| Hindi 5.3 s, Apex q5_0, Metal | 3.2× realtime |
| English 5 min, Apple Speech | 79× realtime, 58 MB peak RSS |
| Metal backend | Active. Core ML / ANE **not** enabled — needs `-DWHISPER_COREML=1` and a per-model `.mlmodelc`, which could speed the encoder further |

Unverified: any M4 real-time factor for turbo (only Apex was run), long-form Extended
Engine behaviour, and every accuracy claim on real footage.

---

# Model review — September 2026

Asked whether anything better than the two shipped models exists on Hugging Face.
Short answer: **the models are right; the runtime is a version behind.**

## The constraint that rules out most candidates

Word-level timings come from `whisper-cli -dtw <preset>`, and the presets are fixed to
Whisper architectures: `tiny`, `base`, `small.en`, `medium`, `large.v1/v2/v3`,
`large.v3.turbo`. Any model of a different architecture cannot produce the per-word
timings the spine is built from, so adopting one means adding a second runtime, not
swapping a file. That excludes Parakeet, Canary, Moonshine and everything else
non-Whisper regardless of their benchmark scores.

## Verified: both shipped models are large-v3-turbo

The Apex model card says it is fine-tuned from `whisper-large-v3`, which would make our
`dtwPreset: "large.v3.turbo"` wrong and the word timings subtly misaligned. Reading the
GGML headers directly settles it — both files report `n_text_layer: 4`, which is turbo
(large-v3 has 32), with different SHA-256s. The preset is correct and the card is loose.

## Apex is the right Hinglish model, and it is licensed cleanly

| Model | Base | Common Voice | FLEURS | Indic-Voices |
|---|---|---:|---:|---:|
| Whisper large-v3 (baseline) | — | 61.94 | 50.84 | 82.56 |
| Oriserve Prime | large-v3 (2B) | **32.43** | **28.68** | 60.82 |
| **Oriserve Apex** (shipped) | large-v3-turbo (0.8B) | 35.96 | 29.79 | **47.64** |

Prime wins on Common Voice and FLEURS — both *read* speech. Apex wins Indic-Voices by
13 points, and Indic-Voices is spontaneous, noisy, accented speech, which is what a
creator talking to a camera actually is. Oriserve themselves mark Apex as superseding
Prime. The model page states **Apache-2.0**. Subly downloads the weights from their
host rather than bundling them; written confirmation is still worth getting before any
commercial redistribution (see the licence note above).

`shunyalabs/zero-stt-hinglish` was considered and rejected: Whisper *Medium* base,
`openrail` licence, no published WER, no GGML build, and it emits mixed
Devanagari+Latin rather than the Latin-only Hinglish this app wants.

## Tested and rejected: q8_0 quantisation

The common advice is that q5_0 degrades lower-resource languages and multilingual work
should use q8_0 or f16. Tested on the 58-second Hinglish clip rather than taken on
trust:

| | words | Devanagari | Latin | domain terms found |
|---|---:|---:|---:|---|
| q5_0 (574 MB, shipped) | 140 | 274 | 252 | 6 of 7 |
| q8_0 (874 MB) | 139 | 276 | 244 | 6 of 7 |

One phrase improved (`crease नहीं ही चीए` → `crease नहीं है`); everything else is a
wash, and neither caught `nano texture`, which only Apex does. Not worth 300 MB a
model. Rejected on evidence, not on the general advice.

## The actual finding: the runtime is behind

At the time, the bundled runtime was **whisper.cpp v1.8.4**; Subly now ships **v1.9.4**
(11 Sept 2026).
Relevant to this app:

- Metal flash-attention tuning for M1–M5 — this app targets Apple Silicon, so the
  speed-up applies directly.
- A UTF-8 fix in the text-length handling. This app already works around a related
  defect with `-sow`, added after `-ml 1` cut Devanagari characters mid-sequence and
  produced JSON that would not decode.
- Decoder reseeding between calls, an uninitialised read in `whisper_mel`, and assorted
  memory-leak fixes.

Upgrading is a build-script change, not a model change, and it is the one improvement
here with a clear benefit. It needs re-running the language sweep and real-video
regressions afterwards, because the decoder fixes can shift output.

## Supply chain, noted

The Apex GGML we download is `Marquestra/Whisper-Hindi2Hinglish-Apex-GGML`, a
third-party conversion, not an Oriserve artefact — Oriserve publish PyTorch weights
only. The download is pinned by SHA-256 and verified before use, so a substituted file
fails closed, but the conversion itself is trusted rather than reproduced. Converting
from Oriserve's own weights with `whisper.cpp/models/convert-h5-to-ggml.py` would
remove that dependency.

## Recommendation

1. Upgrade whisper.cpp to v1.9.4 and re-run the sweeps. Clear benefit, no model change.
2. Keep Apex and large-v3-turbo q5_0. Both are the right choice on this evidence.
3. Optionally convert Apex from Oriserve's weights to drop the third-party conversion.
4. Revisit non-Whisper models only if a second runtime is ever justified on other
   grounds; today they cannot produce the word timings this app is built on.


---

# Model catalogue — September 2026

The engine picker now offers six models rather than two, so someone short of disk or
memory has somewhere to go, and marks one as recommended per language.

| Model | Download | Memory | Speed | Notes |
|---|---:|---:|---:|---|
| **Apex** | 574 MB | ~1.1 GB | 6× | Hindi/Hinglish only. Recommended for Hindi. |
| **Whisper** (large-v3-turbo) | 574 MB | ~1.1 GB | 6× | Recommended everywhere else. ~99 languages. |
| Whisper Large (large-v3) | 1.08 GB | ~1.9 GB | 1× | Most accurate, far slower — 32 decoder layers against turbo's 4. |
| Whisper Medium | 539 MB | ~900 MB | 3× | Half the memory of the default. |
| Whisper Small | 190 MB | ~400 MB | 12× | Noticeably worse on accented and mixed-language speech. |
| Whisper Base | 60 MB | ~200 MB | 24× | Last resort. Frequent mistakes on real audio. |

Sizes and SHA-256s were read from the Hugging Face API, not estimated; the turbo hash
matches the file already shipped. Every model is checksum-verified on download.

## Why there is no per-language specialist beyond Hindi

The obvious next step is a fine-tune per language — Spanish, Japanese, Arabic. Having
looked, that is not justified today:

- Most language fine-tunes on Hugging Face are built on `large-v2` or `medium`, which
  are weaker starting points than `large-v3-turbo`.
- Most are trained on Common Voice, which is *read* speech. They tend to score well on
  Common Voice and worse than the general model on spontaneous, noisy, accented audio —
  which is what this app actually gets.
- Few publish GGML builds, so each would need converting and then verifying.

Apex earns its place because it is measured against the general model on Indic-Voices
(spontaneous, noisy) and wins by 13 WER points, it is Apache-2.0, and it is available in
GGML. That is the bar for adding another specialist; the code supports it via
`specialisedFor`, so adding one is a single entry in `allPacks`.

Recommending a model per language without having tested it would be worse than saying
nothing, so `recommended(for:)` returns the general model unless there is evidence.

## Non-determinism worth knowing about

On the 58-second Hinglish clip, general `large-v3-turbo` returns a different word count
run to run — 119 to 142 across five runs of the same input and version. Apex returns
253 words and 50 slots every time. That instability is a further reason Apex is the
right default for code-switched speech, and it is why a version-to-version comparison
of that model's word counts proves nothing.

## Language packs, 2026-10-06 (updates "Why there is no per-language specialist" above)

A wider search found specialists that clear the bar set above: published as GGML, under
a permissive licence, with published evidence against general Whisper. They live in
`Sources/SublyEngine/LanguagePacks.swift`. Every size and SHA-256 was read from the
Hugging Face API and re-checked against the code, then each was downloaded and run
(see "Tested before 1.3" below). The full research, with every candidate and
source, is in `build/research/models-*.md` (not committed).

A specialist is *recommended* only where `evidence` is set; the others are offered.
"Reported" means by the model's makers unless it says otherwise.

| Language | Pack | Base · size | Licence | Evidence | Recommended |
|---|---|---|---|---|---|
| Mandarin | Belle (BELLE-2) turbo-zh | turbo · 574 MB | Apache-2.0 | ⅓–⅔ fewer character errors than turbo on 5 Mandarin sets; adds punctuation | Yes |
| Mandarin | Belle large-v3-zh-punct | large-v3 · 1.08 GB | Apache-2.0 | More accurate than Belle turbo, much slower | — |
| Taiwanese Mandarin | Breeze-ASR-25 (MediaTek) | large-v2 · 1.08 GB | Apache-2.0 | About half large-v3's errors on Mandarin–English mixing | Offered (Belle wins for "zh") |
| Cantonese | alvanlii whisper-small-cantonese | small · 488 MB f16 | Apache-2.0 | 7.9% CER on CV yue; large-v3 12.9% (independent) | Yes |
| Korean | royshilkrot turbo-korean | turbo · 574 MB | Apache-2.0 | ~16 vs ~24 WER, unnamed set, read speech | — |
| Swedish | KB-Whisper Large (KBLab) | large-v3 · 1.08 GB | Apache-2.0 | FLEURS 5.4 vs 7.8 (large-v3) | Yes |
| Norwegian | NB-Whisper Large (Nat. Library) | large-v3 · 1.08 GB | Apache-2.0 | FLEURS Bokmål 6.6 vs 10.4 (paper) | Yes |
| German | primeline turbo-german | turbo · 574 MB | Apache-2.0 | ~⅕ fewer errors than large-v3 on 4 sets | Yes |
| Russian | bond005 podlodka-turbo | turbo · 574 MB | Apache-2.0 | Beats turbo on all 7 sets (CV 5.2 vs 6.6) | Yes |
| Croatian | GoranS turbo-hr-parla | turbo · 574 MB | Apache-2.0 | FLEURS 8.7 vs 12.7; independent turbo 12.5 | Yes |
| French | bofenghuang large-v3-french | large-v3 · 1.08 GB | MIT | FLEURS 4.84 vs 5.39, different normalisers | — |
| Latvian | AiLab IMCS UL large-v3-lv | large-v3 · 1.08 GB | Apache-2.0 | Not on a shared test set | — |
| English | medium.en / small.en / base.en | 539 / 190 / 60 MB | MIT | Better than same-size multilingual (OpenAI) | — |
| Thai | Pathumma large-v3 (NECTEC) | large-v3 · 1.66 GB q8 | Apache-2.0 | Beats large-v3 on 4 Thai sets (FLEURS 15.7 vs 24.1) | Yes |
| Thai | Thonburian medium (biodatlab) | medium · 539 MB | Apache-2.0 | Beats large-v3 on GigaSpeech2 and CV17 (third-party card) | — |
| Vietnamese | PhoWhisper-large (VinAI) | large-v2 · 1.66 GB q8 | BSD-3-Clause | GigaSpeech2-vi 10.0 vs 17.9 (different teams) | Yes |
| Vietnamese | PhoWhisper-small (VinAI) | small · 488 MB f16 | BSD-3-Clause | Lighter, less accurate | — |
| Hebrew | ivrit-ai large-v3-turbo | turbo · 574 MB | Apache-2.0 | ~half stock turbo's errors on 6 sets (ivrit.ai leaderboard) | Yes |
| Arabic (dialects) | oddadmix turbo-arabic-dialectal-v2 | turbo · 574 MB | Apache-2.0 | Per-dialect WER for 13 dialects; no stock baseline | — |
| Persian | SadeghK large-v3-turbo-fa | turbo · 1.62 GB f16 | MIT | CV17 9.6, Common Voice only | — |
| Bengali | tugstugi Bengali.AI medium | medium · 587 MB q5_1 | Apache-2.0 | 15.9 WER in whisper.cpp (FLEURS, converter); stock large-v3 55 on CV | — (runs with -nt) |
| Tamil | vasista22 medium (IIT Madras) | medium · 587 MB q5_1 | Apache-2.0 | 20.3 WER in whisper.cpp (FLEURS, converter) | — (runs with -nt) |
| Swedish | KB-Whisper Medium / Small (KBLab) | 539 / 175 MB | Apache-2.0 | FLEURS 6.6 / 7.3, both better than OpenAI large-v3 (7.8) | — (Large is) |
| Norwegian | NB-Whisper Medium | medium · 539 MB | Apache-2.0 | Lighter NB-Whisper | — |
| Finnish | Finnish-NLP large-finnish-v3 | large-v3 · 1.08 GB | Apache-2.0 | CV11 8.2 vs 10.8, FLEURS 8.2 vs 9.6 (large-v3) | Yes |
| Finnish | mozilla-ai turbo-fi | turbo · 574 MB | Apache-2.0 | CV22 orthographic 15.9 vs 20.3 (turbo) | — |
| Turkish | TurkMedSTT large-v3-turkish-general | large-v3 · 1.08 GB | Apache-2.0 | 7.9 vs 12.1 on 320 unpublished clips | — |
| Estonian | TalTech turbo-et-verbatim | turbo · 574 MB q5_k | MIT | 10.9 WER measured in whisper.cpp (converter); sibling 9.7 vs large-v3 26.6 | — |
| Azerbaijani | LocalDoc turbo | turbo · 1.62 GB f16 | Apache-2.0 | FLEURS 13.2 vs 23.0 turbo, but FLEURS-az was in its training data | — |
| Icelandic | Reykjavik Univ. LVL whisper-large | large-v1 · 1.08 GB | CC-BY-4.0 | Samromur 7.8; large-v2 FLEURS is 38.2 (different sets) | — |
| Uzbek | rubaiSTT v2 medium | medium · 539 MB | Apache-2.0 | ~17 on its own set; large-v2 FLEURS is 90.2 | — (runs with -nt) |

Considered and **not** added:

- **Japanese, kotoba-whisper v2.0:** an independent benchmark has large-v3-turbo equal or
  better on FLEURS, JSUT and ReazonSpeech, long-form is worse, and its 2 decoder layers
  have no DTW preset. Japanese gains need a non-Whisper model (ReazonSpeech k2,
  Parakeet-ja, SenseVoice) and a second runtime.
- **distil-large-v3.5 (English):** about turbo's accuracy, 1.5x the speed, but GGML only at
  f16 (1.5 GB) and no DTW preset.
- **Spanish, Italian, Portuguese, Dutch, Polish, Ukrainian, Turkish, Greek, Czech,
  Romanian, Catalan:** general Whisper is already 2.5–5.5% WER on FLEURS; no fine-tune
  has broad evidence of beating it.
- **Licence:** CrisperWhisper, Swiss German (Flurin17) and hviske Danish are
  non-commercial; several Russian and European Portuguese fine-tunes state no licence.
- **Danish roest-v3, Lithuanian, Basque:** real gains, but no q5 GGML, a custom licence,
  or hallucination in silence. Each needs work before it can ship.
- **Taiwanese Hokkien (Breeze-ASR-26):** usable, but Subly has no Hokkien language to
  attach it to.

More considered and not added (Southeast Asia, South Asia, Middle East, Africa):

- **Typhoon Whisper (Thai):** the strongest Thai numbers, but its card adds the
  OpenTyphoon terms to MIT and it was trained partly on non-commercial data.
- **Singlish (mjwong turbo-singlish, MIT):** 13.4 vs 27.6 WER on SASRBench, but no GGML
  yet — needs converting. **Javanese (BuzzASR):** CER 5.2 vs 25.1, also needs converting.
- **Indonesian, Malay, Tagalog:** general large-v3 already beats the fine-tunes on FLEURS.
- **Burmese, Khmer, Lao:** nothing Whisper-based is ready; general Whisper is over 100% WER.
- **Telugu, Gujarati, Marathi, Kannada:** measured 31–51% WER inside whisper.cpp. **Urdu:**
  a real-world YouTube set showed almost no gain over turbo. **Hindi in Devanagari
  (Vaani):** timestamps untested and Apple already writes Devanagari.
- **Trelis Hinglish, Vaani Odia, Mesolitica Malay, BuzzASR Burmese/Khmer/Lao:** change the
  vocabulary size, so whisper.cpp decodes them wrongly.
- **Sunbird 51 African languages:** the GGML copy has no licence and its upstream is gated.
- **Georgian:** no published numbers (stock Whisper is unusable, 105% on FLEURS) — test
  in house first. **Bulgarian:** a small gain on the set it was trained on. **Tatar:** Subly
  has no Tatar language. **Belarusian:** its author found whisper.cpp keeps only the first
  sentence of each window. Worth converting and hosting: Slovak (KInIT, 9.3 vs 29.2 turbo),
  Kazakh (11.8 vs 19.8), Galician (7.9 vs 25.0), Tajik, Maltese, Serbian, Sorani Kurdish.

Runtime facts that shaped the entries:

- Many Indic fine-tunes were trained with timestamps off; asked for timestamps,
  whisper.cpp loses a third or more of their accuracy. They run with `-nt`
  (`noTimestamps`). Checked on turbo: `-nt` leaves DTW's per-word times exactly as they
  were and only scrambles segment offsets, which word timing already caps.
- whisper.cpp knows Filipino as `tl` and Javanese as `jw`. The app sent `fil` and `jv`,
  which whisper-cli rejects, so **those two languages failed on every Whisper model**
  before this change (`whisperCode(for:pack:)`).

- `-l yue` on any vocabulary older than large-v3 lands on `<|translate|>`; the Cantonese
  pack runs as `zh` (`whisperLanguage`).
- Many repositories name their file `ggml-model-q5_0.bin`, and four of these are the same
  size, so packs from the catalogue are saved as `<id>.bin` (`localFilename`).

**Before release:** download each recommended pack once, run it on a real clip in its
language, and confirm captions, word timings and the language code.
`Scripts/smoke_language_packs.sh [lang …]` does the mechanical part for every downloaded
pack: it speaks a sentence with the macOS voice for that language (19 of the languages
have one), runs `subly-cli pack-smoke` — the app's own engine path, with the pack's code,
`-nt` and preset — and prints the transcript and word times beside the sentence. It
downloads nothing and skips packs that are not installed. Until then they are
candidates with published evidence, like Apex was.

### Next steps that need the owner's approval (nothing below has been downloaded)

1. **Test the recommended packs.** Download them in the app (Speech Models) and run
   `Scripts/smoke_language_packs.sh`: Belle Mandarin 574 MB, Whisper Cantonese 488 MB,
   KB-Whisper Swedish 1.08 GB, NB-Whisper Norwegian 1.08 GB, Whisper German 574 MB, Whisper
   Russian 574 MB, Whisper Croatian 574 MB, Whisper Finnish 1.08 GB, Pathumma Thai
   1.66 GB, PhoWhisper Vietnamese 1.66 GB, ivrit.ai Hebrew 574 MB — about 9.9 GB in all.
   The Bengali and Tamil packs (587 MB each) are the first run with `-nt`; test those too.
2. **A second runtime, sherpa-onnx** (Apache-2.0, `build/research/runtimes.md` §11):
   source tag v1.13.8 from GitHub, an ONNX Runtime static library (20.3 MB, SHA-256
   pinned) and small CMake dependencies, built into a self-contained
   `sherpa-onnx-offline` helper (~30 MB, estimated). It would add, with word timestamps,
   Parakeet-TDT-0.6B-v3 (25 European languages), ReazonSpeech and Parakeet for Japanese,
   and SenseVoice for Mandarin, Cantonese, Japanese and Korean. Packs become multi-file.
3. **Converting fine-tunes that have no GGML** — Singlish (mjwong turbo-singlish, MIT),
   Javanese (BuzzASR), Bengali turbo (mozilla-ai), Urdu turbo (kingabzpro), AI4Bharat
   IndicWhisper for Marathi, Gujarati, Punjabi and Malayalam. Each needs its weights
   downloaded, converted with whisper.cpp's script, quantised, and **hosted somewhere**
   (for instance the owner's own Hugging Face account), which is publishing.

### Tested before 1.3 (2026-10-08)

`Scripts/smoke_language_packs.sh --download-each` downloaded every language pack in turn
with the app's own downloader (size and SHA-256 checked), ran it through `subly-cli
pack-smoke` — the app's engine path with the pack's language code, `-nt` and preset — on
one sentence spoken by the macOS voice for its language, and deleted it. Results are in
`build/smoke/results.txt`.

- **34 passed:** each loaded, wrote the right language and script, and gave ordered word
  times. Sentences came back essentially right, with small slips typical of synthetic
  speech ("iPhone too" → "iPhone 2", Cantonese "iPhone" misheard, a stray "." or "?" at
  the start of one French and one Cantonese line). Latvian, Persian, Estonian, Azerbaijani,
  Icelandic and Uzbek have no macOS voice and were run on the English sentence: that only
  shows they load and run.
- **2 taken out:** Edda (Danish) repeated one word over and over, with and without `-nt` —
  its GGML copy looks broken. The Armenian turbo (f16) returned text that was not valid
  UTF-8.
- **Seen in passing, not new:** for languages written without spaces (Chinese, Cantonese,
  Thai) whisper.cpp's `-sow` keeps a whole sentence as one segment, so word-by-word timing
  inside it comes from the segment, not per character. General Whisper has always done
  this; Breeze and Pathumma, which put spaces between words, are timed per word.

Synthetic speech is an integration test, not an accuracy measurement.
