import Foundation

/// How one person likes words spelled, learned from the corrections they make.
///
/// Romanized Hindi has no single spelling: one creator writes "yah", another "ye",
/// another "yeh". When someone changes a word in a caption, the pair is remembered
/// for that caption language and used on every caption Subly makes afterwards.
public struct SpellingPreferences: Codable, Sendable, Equatable {

    /// Language tag of the track (e.g. "hi-Latn") → heard word, lowercased → preferred.
    public private(set) var rules: [String: [String: String]] = [:]

    public init() {}

    public struct Correction: Hashable, Sendable {
        public var heard: String
        public var preferred: String
    }

    public var isEmpty: Bool { rules.values.allSatisfy(\.isEmpty) }

    /// Respellings between two versions of a caption: "yah achchha hai" →
    /// "ye achha hai" gives yah → ye and achchha → achha.
    ///
    /// Only a word that sounds the same counts — the same consonants once vowels and
    /// "h" are ignored — so "is" → "was" or "good" → "great" is an edit, not a
    /// spelling, and is never learned. Inserted, deleted and reworded stretches are
    /// ignored, and so are changes of punctuation or of capitals alone, except a word's
    /// own capitals ("iphone" → "iPhone"). `respellings: false` keeps only those
    /// capitals: in a transcript or a translation a different word means something
    /// different.
    public static func corrections(from old: String, to new: String,
                                   respellings: Bool = true) -> [Correction] {
        let a = words(old), b = words(new)
        let ka = a.map { key($0) }, kb = b.map { key($0) }
        // Longest common subsequence of the words, then read the gaps between matches.
        var lcs = Array(repeating: Array(repeating: 0, count: kb.count + 1), count: ka.count + 1)
        for i in stride(from: ka.count - 1, through: 0, by: -1) {
            for j in stride(from: kb.count - 1, through: 0, by: -1) {
                lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var found: [Correction] = []
        var i = 0, j = 0, gapA: [String] = [], gapB: [String] = []
        func closeGap() {
            // Word for word, and every pair must sound alike ("yah achchha" →
            // "ye achha"), not a rewording ("main ghar" → "hum office").
            if respellings, gapA.count == gapB.count, !gapA.isEmpty,
               zip(gapA, gapB).allSatisfy({ soundsAlike($0, $1) }) {
                let start = j - gapB.count
                found += zip(gapA, gapB).enumerated().compactMap { k, pair in
                    correction(heard: pair.0, preferred: pair.1, sentenceStart: startsSentence(b, at: start + k))
                }
            }
            gapA = []; gapB = []
        }
        while i < ka.count || j < kb.count {
            if i < ka.count, j < kb.count, ka[i] == kb[j] {
                closeGap()
                // The same word with its own capitals now ("iphone" → "iPhone").
                if strip(a[i]) != strip(b[j]), hasOwnCapitals(strip(b[j])),
                   let c = correction(heard: a[i], preferred: b[j], sentenceStart: false) { found.append(c) }
                i += 1; j += 1
            } else if j < kb.count, i == ka.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                gapB.append(b[j]); j += 1
            } else {
                gapA.append(a[i]); i += 1
            }
        }
        closeGap()
        return found
    }

    private static func correction(heard: String, preferred: String, sentenceStart: Bool) -> Correction? {
        let h = strip(heard), p = strip(preferred)
        let letters = { (w: String) in String(w.filter(\.isLetter)).lowercased() }
        guard !h.isEmpty, !p.isEmpty, h.count <= 40, p.count <= 40,
              h.contains(where: \.isLetter), p.contains(where: \.isLetter),
              !h.contains(where: \.isNumber), !p.contains(where: \.isNumber),
              // Punctuation inside the word ("can't" → "can’t") is not a spelling.
              letters(h) != letters(p) || (h != p && hasOwnCapitals(p)) else { return nil }
        // A capital the sentence gave the word ("teh" → "The" first in a caption) is
        // not part of its spelling; a word's own capitals ("iPhone") are.
        let stored = sentenceStart && !hasOwnCapitals(p) ? p.lowercased() : p
        return Correction(heard: h, preferred: stored)
    }

    private static func startsSentence(_ words: [String], at index: Int) -> Bool {
        guard index > 0 else { return true }
        return words[index - 1].last.map { ".!?…।".contains($0) } ?? false
    }

    /// The same word spelled another way: equal consonants once vowels and "h" are
    /// dropped and doubled letters merged ("yah" / "ye" / "yeh", "achchha" / "achha",
    /// "bahut" / "bohot"). Two-letter pairs are left alone: "ka" → "ki" is grammar.
    private static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = key(a), y = key(b)
        guard x.count + y.count > 4 || max(x.count, y.count) > 2 else { return false }
        func skeleton(_ w: String) -> String {
            var out = ""
            for ch in w where ch.isLetter && !"aeiouh".contains(ch) {
                let c: Character = ch == "w" ? "v" : ch
                if out.last != c { out.append(c) }
            }
            return out
        }
        let sx = skeleton(x)
        return !sx.isEmpty && sx == skeleton(y)
    }

    /// Remember these corrections for captions in `languageTag`. A later change wins
    /// for every word that led to the old spelling (yah → ye, then ye → yeh, makes
    /// yah → yeh), and changing a word back forgets it instead of storing a loop.
    public mutating func learn(_ corrections: [Correction], languageTag: String) {
        var map = rules[languageTag] ?? [:]
        for c in corrections {
            let heard = c.heard.lowercased()
            if heard == c.preferred.lowercased(), !Self.hasOwnCapitals(c.preferred) { continue }
            for (k, v) in map where v.lowercased() == heard { map[k] = c.preferred }
            map[heard] = c.preferred
            for (k, v) in map where v.lowercased() == k && !Self.hasOwnCapitals(v) { map[k] = nil }
        }
        rules[languageTag] = map.isEmpty ? nil : map
    }

    /// Everything learned for one caption language, to put back exactly as it was.
    public func rules(for languageTag: String) -> [String: String] { rules[languageTag] ?? [:] }
    public mutating func setRules(_ map: [String: String], for languageTag: String) {
        rules[languageTag] = map.isEmpty ? nil : map
    }

    public mutating func forget(heard: String, languageTag: String) {
        rules[languageTag]?[heard.lowercased()] = nil
        if rules[languageTag]?.isEmpty == true { rules[languageTag] = nil }
    }

    public mutating func forgetAll() { rules = [:] }

    /// The caption with every learned word in the person's spelling. Punctuation stays
    /// where it was, and a capital at the start of a word is kept.
    public func apply(to text: String, languageTag: String) -> String {
        guard let map = rules[languageTag], !map.isEmpty else { return text }
        var out = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            out += replace(token, map: map)
            token = ""
        }
        for ch in text {
            if ch.isWhitespace { flush(); out.append(ch) } else { token.append(ch) }
        }
        flush()
        return out
    }

    public func apply(to track: SubtitleTrack) -> SubtitleTrack {
        guard !track.isReference, rules[track.languageTag]?.isEmpty == false else { return track }
        var t = track
        for c in t.cues.indices {
            t.cues[c].lines = t.cues[c].lines.map { apply(to: $0, languageTag: track.languageTag) }
        }
        return t
    }

    /// How many words in `track` a learned spelling would change.
    public func changes(in track: SubtitleTrack) -> Int {
        guard let map = rules[track.languageTag], !map.isEmpty else { return 0 }
        return track.cues.reduce(0) { sum, cue in
            sum + cue.lines.flatMap(Self.words).filter { word in
                guard let preferred = map[key(word)] else { return false }
                return Self.strip(word) != preferred
            }.count
        }
    }

    // MARK: - Words

    /// Capitals after the first letter, as in "iPhone" or "YouTube".
    private static func hasOwnCapitals(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    private static func key(_ word: String) -> String { strip(word).lowercased() }
    private func key(_ word: String) -> String { Self.key(word) }

    private func replace(_ token: String, map: [String: String]) -> String {
        let core = Self.strip(token)
        guard !core.isEmpty, let preferred = map[core.lowercased()], preferred != core,
              let range = token.range(of: core) else { return token }
        return token.replacingCharacters(in: range, with: matchCase(preferred, like: core))
    }

    /// "Yah" → "Ye" at the start of a sentence, "YAH" → "YE"; a spelling the person
    /// typed with its own capitals ("iPhone") is kept as typed.
    private func matchCase(_ preferred: String, like heard: String) -> String {
        if Self.hasOwnCapitals(preferred) { return preferred }
        if heard.count > 1, heard == heard.uppercased(), heard != heard.lowercased() {
            return preferred.uppercased()
        }
        if let first = heard.first, first.isUppercase {
            return preferred.prefix(1).uppercased() + preferred.dropFirst()
        }
        return preferred
    }
}
