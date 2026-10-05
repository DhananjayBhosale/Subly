import Foundation

/// Deterministic script → Latin conversion. PRD §11.
///
/// Pipeline: ICU transliteration → per-language orthography rules → protected-term
/// restoration. A Foundation-model rerank may refine the result afterwards, but it can
/// only ever *edit* this output, never originate it — so Romanization stays reproducible
/// and testable.
public struct Romanizer: Sendable {

    /// Per-token cache for the ICU transform plus orthography. Real speech repeats
    /// words heavily, and each miss costs an ICU round trip — romanizing a
    /// 57-minute transcript was 42 ms without it.
    private final class TokenCache: @unchecked Sendable {
        private var store: [String: String] = [:]
        private let lock = NSLock()
        static let shared = TokenCache()

        func value(_ key: String, _ make: () -> String) -> String {
            lock.lock()
            if let hit = store[key] { lock.unlock(); return hit }
            lock.unlock()
            let made = make()
            lock.lock()
            // Bounded so a very long session cannot grow without limit.
            if store.count > 20_000 { store.removeAll(keepingCapacity: true) }
            store[key] = made
            lock.unlock()
            return made
        }
    }


    public struct Result: Sendable {
        public var text: String
        /// True when the output looks unreliable and should be flagged for review.
        public var lowConfidence: Bool
        public var note: String?
    }

    /// ICU transform chain per language. Generic `Any-Latin` is WRONG for Japanese:
    /// it applies Chinese pinyin to kanji (元気 → "yuán qì"), so Japanese needs an
    /// explicit chain and still carries a caveat for kanji.
    static func transformChain(for language: String) -> String {
        switch language {
        // No trailing Any-Latin: it applies CHINESE pinyin to kanji (画質 → "hua zhi").
        // Kana romanise correctly; kanji are left as-is and the result is flagged.
        case "ja": return "Hiragana-Latin; Katakana-Latin"
        case "ko": return "Hangul-Latin"
        case "zh", "yue", "wuu": return "Han-Latin"
        case "th": return "Thai-Latin"
        case "el": return "Greek-Latin"
        case "ru", "uk", "bg", "sr", "mk", "be": return "Cyrillic-Latin"
        case "ar", "fa", "ur", "ps": return "Arabic-Latin"
        case "he", "yi": return "Hebrew-Latin"
        default: return "Any-Latin"
        }
    }

    /// Languages where the deterministic pipeline is known to produce output a native
    /// speaker would accept. Everything else is offered at reduced confidence.
    /// PRD §6.2 tier gate.
    // Deliberately excludes zh/yue/ja: ICU produces syllable-spaced pinyin/romaji with
    // no word boundaries, which is not what a reader expects. Also excludes mr, which
    // no engine on any tested Mac offers.
    public static let reviewedLanguages: Set<String> = ["hi", "ko", "el", "ru", "uk"]

    /// Scripts whose unvocalised orthography makes Romanization unreliable.
    public static let unreliableLanguages: Set<String> = ["ar", "he", "fa", "ur", "yi", "ps"]

    public init() {}

    /// Single source of truth for romanization tiering — it lives here with the
    /// implementation, not in the engine layer.
    public static func isReviewed(_ code: String) -> Bool { reviewedLanguages.contains(code) }
    public static func isUnreliable(_ code: String) -> Bool { unreliableLanguages.contains(code) }

    // MARK: - Public entry point

    public func romanize(_ text: String, language: String, protectedTerms: [String] = []) -> Result {
        let lang = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(text: "", lowConfidence: false, note: nil) }

        // Already Latin: Romanization is a no-op, not an error. PRD §10.6.
        if ScriptProfile.forLanguage(language).romanizable == false {
            return Result(text: trimmed, lowConfidence: false, note: "Source is already Latin script")
        }

        // Japanese by word, with readings for kanji: kana-only transliteration left
        // kanji in place and ran every word together ("Kamerano画質mo素晴rashii").
        if lang == "ja" {
            return Result(text: tidy(Self.japaneseRomaji(trimmed)), lowConfidence: false,
                          note: "Kanji readings come from macOS and may not match how they were said")
        }

        let chain = Self.transformChain(for: lang)
        guard let transform = StringTransform(rawValue: chain) as StringTransform? else {
            return Result(text: trimmed, lowConfidence: true,
                          note: "No transliteration available for this script")
        }

        let lexicon = Self.lexicon(adding: protectedTerms)

        // Token-wise so an already-Latin word is never transliterated or schwa-stripped.
        // This is what keeps embedded English terms intact (PRD ASR-05) and stops
        // `camera` becoming `camer`.
        var pieces: [String] = []
        var anyTransliterated = false
        for token in trimmed.split(separator: " ", omittingEmptySubsequences: false) {
            let word = String(token)
            if word.isEmpty { pieces.append(word); continue }
            if Self.isAlreadyLatin(word) { pieces.append(word); continue }

            anyTransliterated = true
            // Cache key must include the language: the transform chain and the
            // orthography rules both differ by language.
            let cacheKey = lang + "\u{1}" + word
            var w = TokenCache.shared.value(cacheKey) {
                guard let base = word.applyingTransform(transform, reverse: false) else {
                    return word
                }
                return applyOrthography(base, language: lang)
            }

            // Protected-term lookup runs BEFORE schwa deletion, because the lexicon
            // keys are the full transliterated forms (`aaeefona`, not `aaeefon`).
            if let restored = Self.restore(w, lexicon: lexicon) {
                pieces.append(restored)
                continue
            }
            if Self.indicLanguages.contains(lang) {
                w = deleteFinalSchwa(w)
                w = Self.deleteMedialSchwa(w)
                w = Self.collapseFinalLongA(w)
                w = Self.shortenFinalVowels(w)
                if let typed = Self.commonSpellings[w.lowercased()] { w = typed }
            }
            pieces.append(w)
        }

        var out = tidy(pieces.joined(separator: " "))
        if !anyTransliterated {
            out = tidy(trimmed)
            return Result(text: out, lowConfidence: false,
                          note: "Source is already Latin script")
        }

        let low = Self.unreliableLanguages.contains(lang) || !Self.reviewedLanguages.contains(lang)
        var note: String?
        if Self.unreliableLanguages.contains(lang) {
            note = "This script omits vowels, so Romanization is approximate"
        } else if !Self.reviewedLanguages.contains(lang) {
            note = "Romanization for this language has not been quality-reviewed"
        } else if lang == "ja" {
            note = "Kanji are left in place — only kana are romanized"
        } else if lang == "zh" || lang == "yue" {
            note = "Pinyin is produced syllable by syllable, without word boundaries"
        }
        return Result(text: out, lowConfidence: low, note: note)
    }

    /// Hepburn-style romaji, one word at a time, using the readings macOS's Japanese
    /// tokenizer knows for kanji. Particles are spelled as they are said.
    static func japaneseRomaji(_ text: String) -> String {
        let ns = text as NSString
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: ns.length),
                                                kCFStringTokenizerUnitWordBoundary,
                                                Locale(identifier: "ja") as CFLocale)
        let particles = ["は": "wa", "へ": "e", "を": "o"]
        let punctuation: [Character: String] = ["。": ".", "、": ",", "！": "!", "？": "?", "「": "\"", "」": "\"", "・": " "]
        var words: [String] = []
        var cursor = 0
        func gap(_ upTo: Int) {
            guard upTo > cursor else { return }
            let between = ns.substring(with: NSRange(location: cursor, length: upTo - cursor))
            let mapped = between.map { punctuation[$0] ?? String($0) }.joined()
                .trimmingCharacters(in: .whitespaces)
            if mapped.isEmpty { return }
            if words.isEmpty { words.append(mapped) } else { words[words.count - 1] += mapped }
        }
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            gap(range.location)
            let token = ns.substring(with: NSRange(location: range.location, length: range.length))
            cursor = range.location + range.length
            if let particle = particles[token] { words.append(particle); continue }
            if token.allSatisfy({ punctuation[$0] != nil }) {
                let mapped = token.map { punctuation[$0] ?? "" }.joined()
                if words.isEmpty { words.append(mapped) } else { words[words.count - 1] += mapped }
                continue
            }
            if isAlreadyLatin(token) { words.append(token); continue }
            let latin = (CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String)
                ?? token.applyingTransform(StringTransform(rawValue: "Hiragana-Latin; Katakana-Latin"), reverse: false)
                ?? token
            words.append(latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin)
        }
        gap(ns.length)
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let indicLanguages: Set<String> = [
        "hi", "mr", "ne", "sa", "bn", "gu", "pa", "ta", "te", "kn", "ml", "si", "as", "or",
    ]

    /// True when a token needs no transliteration — it is already Latin (or digits and
    /// punctuation). Anything below U+0370 is Latin, Latin-Extended, IPA or combining
    /// marks; every script we transliterate sits above that.
    static func isAlreadyLatin(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy { scalar in
            // Latin, Latin-Extended, IPA, spacing modifiers and combining marks.
            if scalar.value < 0x0370 { return true }
            // General Punctuation and friends: curly quotes, dashes, ellipsis. These
            // are ordinary in English text — treating `don’t` or `“camera”` as
            // non-Latin sent them through Devanagari schwa deletion.
            if (0x2000...0x206F).contains(scalar.value) { return true }   // punctuation
            if (0x20A0...0x20BF).contains(scalar.value) { return true }   // currency
            if (0x2100...0x214F).contains(scalar.value) { return true }   // letterlike
            return false
        }
    }

    /// Word-final long `aa` reads wrong to a native writer: ICU gives `acchaa` for
    /// `अच्छा`, but people type `accha`.
    /// The silent middle vowel. Hindi drops an inherent "a" between two single
    /// consonants when vowels sit on both sides (करता is "karta", not "karata"; आपको
    /// "aapko"), working from the end of the word, and never in the first syllable.
    /// A heard vowel is kept: कमल stays "kamal", समझ "samajh".
    static func deleteMedialSchwa(_ token: String) -> String {
        var core = token, head = "", tail = ""
        while let last = core.last, !last.isLetter { tail = String(last) + tail; core.removeLast() }
        while let first = core.first, !first.isLetter { head += String(first); core.removeFirst() }
        guard core.count >= 5 else { return token }

        // Split into vowel and consonant units, digraphs as one unit.
        let vowels = ["aa", "ee", "oo", "ai", "au", "a", "e", "i", "o", "u"]
        let digraphs = ["chh", "kh", "gh", "ch", "jh", "th", "dh", "ph", "bh", "sh", "ng", "ny"]
        var units: [(text: String, vowel: Bool)] = []
        var rest = Substring(core)
        while !rest.isEmpty {
            let lower = rest.lowercased()
            if let v = vowels.first(where: { lower.hasPrefix($0) }) {
                units.append((String(rest.prefix(v.count)), true)); rest = rest.dropFirst(v.count)
            } else if let d = digraphs.first(where: { lower.hasPrefix($0) }) {
                units.append((String(rest.prefix(d.count)), false)); rest = rest.dropFirst(d.count)
            } else {
                units.append((String(rest.prefix(1)), false)); rest = rest.dropFirst()
            }
        }
        var i = units.count - 3
        while i >= 2 {
            if units[i].vowel, units[i].text.lowercased() == "a",
               !units[i - 1].vowel, units[i - 2].vowel,
               !units[i + 1].vowel, units[i + 2].vowel {
                units.remove(at: i)
                i -= 2          // the syllable before can no longer lose its vowel
            } else {
                i -= 1
            }
        }
        return head + units.map(\.text).joined() + tail
    }

    /// Word-final long vowels the way people type them: "bhee" is "bhi", "kitnee"
    /// "kitni", "naheen" "nahin".
    static func shortenFinalVowels(_ token: String) -> String {
        var core = token, tail = ""
        while let last = core.last, !last.isLetter { tail = String(last) + tail; core.removeLast() }
        if core.count >= 4, core.lowercased().hasSuffix("een") {
            return String(core.dropLast(3)) + "in" + tail
        }
        if core.count >= 3, core.lowercased().hasSuffix("ee") {
            return String(core.dropLast(2)) + "i" + tail
        }
        return token
    }

    /// Everyday words whose usual spelling no rule produces.
    static let commonSpellings: [String: String] = [
        "men": "mein", "hain": "hain", "mai": "main", "ham": "hum",
    ]

    static func collapseFinalLongA(_ token: String) -> String {
        var core = token, tail = ""
        while let last = core.last, !last.isLetter {
            tail = String(last) + tail; core.removeLast()
        }
        guard core.count > 3, core.hasSuffix("aa") else { return token }
        return String(core.dropLast()) + tail
    }

    // MARK: - Orthography

    /// ICU emits academic transliteration (IAST for Indic: `āpa kaisē hō`). Creators
    /// write `aap kaise ho`. This converts scholarly output into the conventional
    /// Roman spelling people actually type.
    func applyOrthography(_ s: String, language: String) -> String {
        switch language {
        case "hi", "mr", "ne", "sa", "bn", "gu", "pa", "ta", "te", "kn", "ml", "si":
            return indicOrthography(s)
        case "ru", "uk", "bg", "sr", "mk", "be":
            return cyrillicOrthography(s)
        case "ja":
            return stripDiacritics(s)
        case "zh", "yue", "wuu":
            // Pinyin without tone marks is what most readers expect in subtitles.
            return stripDiacritics(s).replacingOccurrences(of: "  ", with: " ")
        default:
            return stripDiacritics(s)
        }
    }

    private func stripDiacritics(_ s: String) -> String {
        s.applyingTransform(.stripDiacritics, reverse: false) ?? s
    }

    /// IAST → Hinglish conventions, then schwa deletion.
    private func indicOrthography(_ input: String) -> String {
        var s = input

        // IAST writes च as "c" and छ as "ch"; Hinglish writes them "ch" and "chh".
        // A placeholder keeps the second step from touching the first's output
        // ("chalo" came out as "calo", "check" as "cek").
        s = s.replacingOccurrences(of: "ch", with: "\u{1}", options: [.literal])
            .replacingOccurrences(of: "c", with: "ch", options: [.literal])
            .replacingOccurrences(of: "\u{1}", with: "chh", options: [.literal])
        // Chandrabindu (ँ) is a nasal vowel, written "n": हूँ is "hoon", not "hoom".
        s = s.replacingOccurrences(of: "m\u{0310}", with: "n", options: [.literal])

        // Retroflex and sibilant consonants first (order matters: digraphs before singles).
        // Two rules govern this table:
        //  1. Every multi-character sequence must precede the single characters it
        //     contains.
        //  2. Every replacement uses `.literal`. Swift's default string matching
        //     applies Unicode canonical equivalence, under which ṝ (U+1E5D) matches
        //     the two-scalar sequence `r` + `ā` — which silently turned `kaimarā`
        //     (camera) into `kaimari`.
        //
        // ICU renders the Devanagari flaps ड़/ढ़ as ṛ/ṛh, and the Sanskrit vocalic
        // ऋ as r̥ — three different things. Mapping ṛ to "ri" (as if it were the
        // vocalic r) corrupted every common word with a flap: लड़का → "Lariaka".
        let consonants: [(String, String)] = [
            ("ṛh", "dh"), ("ṝ", "ri"), ("r̥", "ri"),      // flap-aspirate, then vocalic r
            ("ṭh", "th"), ("ḍh", "dh"), ("ṭ", "t"), ("ḍ", "d"),
            ("ś", "sh"), ("ṣ", "sh"), ("ṇ", "n"), ("ṅ", "ng"), ("ñ", "ny"),
            ("ṛ", "d"),                                    // ड़ — a flap, not a vowel
            ("ṟ", "r"), ("ḷ", "l"), ("ḥ", "h"), ("ṃ", "n"), ("ṁ", "n"),
            ("k͟h", "kh"), ("ġ", "g"), ("ź", "z"), ("f̱", "f"),
        ]
        for (a, b) in consonants { s = s.replacingOccurrences(of: a, with: b, options: [.literal]) }

        // Long vowels: creators double them. `āp` reads as "ap"; `aap` reads correctly.
        let vowels: [(String, String)] = [
            ("ā", "aa"), ("ī", "ee"), ("ū", "oo"),
            ("ē", "e"), ("ō", "o"),
        ]
        for (a, b) in vowels { s = s.replacingOccurrences(of: a, with: b, options: [.literal]) }

        // ICU inserts an apostrophe at vowel junctions (ā'ī). Drop it.
        s = s.replacingOccurrences(of: "'", with: "", options: [.literal])
        // Any remaining combining marks.
        return stripDiacritics(s)
    }

    /// Devanagari carries an inherent /a/ on every consonant, which ICU renders
    /// literally: `आप` → `āpa`. In speech that final vowel is dropped, so
    /// `aapa` → `aap`. This is the single highest-impact Hinglish rule.
    /// Latin loanwords whose final `a` IS pronounced. The pipeline normally never
    /// passes these here — `isAlreadyLatin` catches them first — but this keeps the
    /// function correct when called directly, and these are exactly the tech words
    /// this app's audience uses. The trade-off is accepted: a Devanagari source
    /// spelling one of these would keep its final vowel, which reads fine.
    static let finalVowelPronounced: Set<String> = [
        "camera", "data", "extra", "alpha", "beta", "delta", "media", "area", "idea",
        "opera", "formula", "agenda", "arena", "cinema", "drama", "era", "sofa", "villa",
        "pizza", "yoga", "soda", "antenna", "schema", "quota", "replica", "via", "ultra",
        "mega", "giga", "tera", "java", "aroma", "plasma", "comma", "gamma", "sigma",
        // ("aura" is not here: और is the far more common word, and it is "aur".)
        "omega", "persona", "saga", "visa", "zebra", "pasta", "plaza", "vista",
        "dilemma", "enigma", "stigma", "trauma", "magma", "panorama", "guerrilla",
        "formula", "nebula", "peninsula", "capsula", "retina", "lambda", "stanza",
    ]

    func deleteFinalSchwa(_ s: String) -> String {
        // Only a vowel before the final `a` blocks deletion outright.
        // `y`/`w` are handled separately below: `kya` must stay, but `samaya`
        // (समय) should become `samay`.
        let blockers = Set("aeiouAEIOU")
        let tokens = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let fixed = tokens.map { token -> String in
            // Peel trailing punctuation so `bahuta.` still gets treated as word-final.
            var core = token
            var head = ""
            var tail = ""
            while let last = core.last, !last.isLetter {
                tail = String(last) + tail
                core.removeLast()
            }
            while let first = core.first, !first.isLetter {
                head += String(first)
                core.removeFirst()
            }
            guard core.count >= 3, core.hasSuffix("a") else { return token }
            guard !Self.finalVowelPronounced.contains(core.lowercased()) else { return token }
            _ = head
            let withoutA = String(core.dropLast())
            // Only delete when a consonant precedes it — never break `kya`→`ky`,
            // and never strip a doubled `aa`.
            guard let prev = withoutA.last, !blockers.contains(prev) else { return token }
            // A glide directly after another consonant carries the vowel: `kya`,
            // `pyaar`. A glide after a vowel does not: `samaya` → `samay`.
            if prev == "y" || prev == "w" || prev == "Y" || prev == "W" {
                let beforeGlide = withoutA.dropLast().last
                if let b = beforeGlide, !blockers.contains(b) { return token }
                if beforeGlide == nil { return token }
            }
            // Keep at least a CV syllable.
            guard withoutA.count >= 2 else { return token }
            return head + withoutA + tail
        }
        return fixed.joined(separator: " ")
    }

    private func cyrillicOrthography(_ input: String) -> String {
        var s = input
        // ICU emits ISO-9 diacritics; map to the spellings readers expect.
        let map: [(String, String)] = [
            ("â", "ya"), ("Â", "Ya"), ("û", "yu"), ("Û", "Yu"),
            ("è", "e"), ("È", "E"), ("ë", "yo"), ("Ë", "Yo"),
            ("ž", "zh"), ("Ž", "Zh"), ("č", "ch"), ("Č", "Ch"),
            ("š", "sh"), ("Š", "Sh"), ("ŝ", "shch"), ("Ŝ", "Shch"),
            // `ú` is a STRESSED Cyrillic `у` (/u/), not `ы`. Mapping it to "y"
            // turned `rúka` into `ryka`.
            ("ú", "u"), ("Ú", "U"), ("ы", "y"), ("Ы", "Y"),
        ]
        for (a, b) in map { s = s.replacingOccurrences(of: a, with: b, options: [.literal]) }
        s = s.replacingOccurrences(of: "ʹ", with: "", options: [.literal])
            .replacingOccurrences(of: "ʺ", with: "", options: [.literal])
        return stripDiacritics(s)
    }

    // MARK: - Protected terms

    /// English loanwords come back from the recogniser in the source script
    /// (iPhone → आईफ़ोन → `aaeefona`). This restores the English spelling, which is
    /// what a creator actually writes. PRD §11 step 3.
    static let defaultLexicon: [String: String] = {
        let pairs: [(String, String)] = [
            // Devices and brands
            ("aaeefona", "iPhone"), ("aaifona", "iPhone"), ("aiphona", "iPhone"),
            ("endroid", "Android"), ("aendrooid", "Android"),
            ("samasang", "Samsung"), ("saimasang", "Samsung"),
            ("gogal", "Google"), ("googal", "Google"), ("yootyoob", "YouTube"),
            ("instaagraam", "Instagram"), ("phesabuk", "Facebook"),
            ("maikrosopht", "Microsoft"), ("vinddoj", "Windows"),
            ("laipatoop", "laptop"), ("maikabuk", "MacBook"),
            // Hardware / spec vocabulary
            ("disple", "display"), ("dispale", "display"), ("displee", "display"),
            ("kaimaraa", "camera"), ("kaimara", "camera"), ("kemaraa", "camera"),
            ("kvaaliti", "quality"), ("kvaalitee", "quality"), ("kvaliti", "quality"),
            ("baitaree", "battery"), ("baitari", "battery"),
            ("charjing", "charging"), ("chaarjing", "charging"),
            ("praisesar", "processor"), ("prosesar", "processor"),
            ("braaitanes", "brightness"), ("braitanes", "brightness"),
            ("rijolyooshan", "resolution"), ("pikchar", "picture"),
            ("vidiyo", "video"), ("vidio", "video"), ("audiyo", "audio"),
            ("saphtaveyar", "software"), ("haardaveyar", "hardware"),
            ("apadet", "update"), ("aipadet", "update"), ("phechar", "feature"),
            ("parphormens", "performance"), ("gemin", "gaming"),
            ("prais", "price"), ("maarket", "market"), ("revyoo", "review"),
            ("chainal", "channel"), ("sabaskraib", "subscribe"), ("laik", "like"),
            ("kament", "comment"), ("shear", "share"), ("phalo", "follow"),
            ("cheka", "check"), ("chek", "check"), ("aaeephona", "iPhone"),
        ]
        return Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    }()

    /// Build the effective lexicon: defaults plus the user's own protected terms.
    static func lexicon(adding extra: [String]) -> [String: String] {
        var lexicon = defaultLexicon
        for term in extra {
            let key = term.lowercased().replacingOccurrences(of: " ", with: "")
            lexicon[key] = term
            // Also index the schwa-extended form, since ICU appends the inherent vowel.
            lexicon[key + "a"] = term
        }
        return lexicon
    }

    /// Exact-token lookup, preserving any trailing punctuation.
    static func restore(_ token: String, lexicon: [String: String]) -> String? {
        var core = token, head = "", tail = ""
        while let last = core.last, !last.isLetter && !last.isNumber {
            tail = String(last) + tail; core.removeLast()
        }
        // Leading punctuation matters too: an opening quote or bracket used to stop
        // `“आईफ़ोन”` from ever matching `iPhone`.
        while let first = core.first, !first.isLetter && !first.isNumber {
            head += String(first); core.removeFirst()
        }
        guard !core.isEmpty, let replacement = lexicon[core.lowercased()] else { return nil }
        return head + replacement + tail
    }

    // MARK: - Tidy

    private func tidy(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Sentence-initial capital, which ICU does not provide — but never on a word
        // that has capitals of its own ("iPhone" became "IPhone").
        let firstWord = out.prefix(while: { !$0.isWhitespace })
        if let first = out.first, first.isLowercase, !firstWord.dropFirst().contains(where: \.isUppercase) {
            out.replaceSubrange(out.startIndex...out.startIndex, with: first.uppercased())
        }
        return out
    }
}
