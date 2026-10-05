# Engine comparison on a real Hinglish clip

**Clip:** a 58-second, 464×832 vertical phone recording (not included in this repo) —
Hindi/English code-switched speech about the iPhone Duo's display crease.

This was run because the app's output on this clip was unusable. The cause turned out
to be the *language*, not the engine: the project was set to **en-IN**, so an English
recogniser was asked to transcribe Hinglish.

## Measured

| Engine | Words | Latin script | iPhone Duo | crease | nano texture | nahi hai | reflection | brightness |
|---|---:|---:|:-:|:-:|:-:|:-:|:-:|:-:|
| Apple Speech · en-IN *(what the app produced)* | 134 | 100% | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ |
| Apple Dictation · hi-IN | 192 | 12% | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| Whisper large-v3-turbo (q5) | 140 | 48% | ✓ | ✓ | ✗ | ✓ | ✓ | ✓ |
| **Apex Hindi2Hinglish (q5)** | **255** | **100%** | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ |

Marker hits alone overstate Apple en-IN: it "hits" four because it hallucinates English
words that happen to match, not because it heard them.

## What each actually produced (first ~7 seconds)

Ground truth, by agreement of the two models that heard it clearly:
> "iPhone Duo mein crease nahi hai, aise log bol rahe the. Aise kaise possible hai?
> Foldable phone hai, crease to honi chahiye. Chalo check kar lete hain with the
> iPhone Duo that we have."

- **Apple Speech · en-IN** — `iPhone duo make crisinia, SLO bulldra. SAK is a possible,
  er foldable phone, er, Christomhe, so, check with the iPhone duo that we have.`
  Unusable. An English acoustic model forced onto Hindi words invents English that
  sounds vaguely similar.
- **Apple Dictation · hi-IN** — `आईफ़ोन 2 में रस नहीं है लोग बोल रहे थे आया है फोल्ड है तो होनी
  चाहिए चलो चेक कर लाइट हैं` — right language, but "crease"→"रस", "check kar lete hain"→
  "चेक कर लाइट हैं", and the product name is lost. 192 words for 58 s of dense speech.
- **Whisper large-v3-turbo** — `iPhone Duo में crease नहीं है, ऐसे लोग बोल रहे थे...`
  Accurate, and it keeps the English loanwords in Latin where the speaker said them in
  English — genuine code-switched output. But on this clip its greedy pass repeated and
  then skipped a span, losing the nano-texture sentence entirely; beam search (`-bs 8
  -bo 8`) recovered most of it but still dropped that sentence.
- **Apex Hindi2Hinglish** — `Iphone 2 mein crease nahin hai aise log bol rahe the. Aise
  kaise possible hai yaar? Foldable phone hai, crease to honi chaahie. Chalo check kar
  lete hain with the iPhone 2 that we have.`
  The most complete by a wide margin, already in Latin script, and the **only** engine
  that caught `nano texture vaali mac display`. Its one weakness here is the product
  name: it hears "iPhone 2" where large-v3-turbo correctly hears "iPhone Duo".

## Conclusion

For Hinglish, **Apex is the right default** — 33% more words than Apple's Hindi
recogniser, in the script the user actually wants, and the only one to catch domain
vocabulary. Its proper-noun weakness is real but is a one-word fix in the editor,
whereas Apple en-IN's output cannot be repaired by editing at all.

The lesson for the product is not "swap the engine". It is that **the app let a user
caption a Hindi video with an English recogniser and gave no way to change it
afterwards**. Language and engine are now editable in the editor, with re-transcription
in place.
