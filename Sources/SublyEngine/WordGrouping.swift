import Foundation
import NaturalLanguage
import SublyCaptions

/// Joins the per-character tokens some recognisers return for Japanese, Chinese and
/// Thai into real words, so captions are cut between words.
///
/// Apple's Japanese recogniser timed each character on its own ("デ", "ィ", "ス"…), and
/// with no word boundaries to go on captions broke in the middle of words:
/// "このiPhoneのディ" | "スプレイは". A language-aware tokenizer finds the words; each
/// takes the time of its first and last character.
public enum WordGrouping {

    public static func group(_ words: [TimedWord], languageCode: String) -> [TimedWord] {
        guard words.count > 1 else { return words }
        // The text, and which token each of its characters came from.
        var text = ""
        var owner: [Int] = []
        for (i, word) in words.enumerated() {
            text += word.text
            owner += Array(repeating: i, count: word.text.utf16.count)
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: languageCode))

        // Each tokenizer word claims the tokens it overlaps; a token split between two
        // words joins them, since its time can't be divided.
        var groups: [ClosedRange<Int>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let ns = NSRange(range, in: text)
            guard ns.length > 0, ns.location + ns.length <= owner.count else { return true }
            let first = owner[ns.location], last = owner[ns.location + ns.length - 1]
            if let previous = groups.last, first <= previous.upperBound {
                groups[groups.count - 1] = previous.lowerBound...max(previous.upperBound, last)
            } else {
                groups.append(first...last)
            }
            return true
        }
        guard !groups.isEmpty else { return words }

        // Tokens no word covered (punctuation, spaces) go with the word before them.
        var out: [TimedWord] = []
        var next = 0
        for g in groups {
            if g.lowerBound > next, !out.isEmpty {
                for i in next..<g.lowerBound { append(words[i], to: &out) }
            } else if g.lowerBound > next {
                // Leading punctuation: keep it as its own token.
                for i in next..<g.lowerBound { out.append(words[i]) }
            }
            let members = words[g]
            out.append(TimedWord(text: members.map(\.text).joined(),
                                 start: members.first!.start, end: members.map(\.end).max()!,
                                 confidence: members.compactMap(\.confidence).min()))
            next = g.upperBound + 1
        }
        for i in next..<words.count { append(words[i], to: &out) }
        return out
    }

    private static func append(_ word: TimedWord, to out: inout [TimedWord]) {
        guard !out.isEmpty else { out.append(word); return }
        out[out.count - 1].text += word.text
        out[out.count - 1].end = max(out[out.count - 1].end, word.end)
    }
}
