import Testing
import Foundation
@testable import SublyEngine
@testable import SublyCaptions

/// `SublyEngine` had no tests at all, which meant the two fixes that came out of
/// real-footage testing — the word-duration clamp and the punctuation fold — were
/// uncovered. Both are exercised here directly.
@Suite("Timing repair")
struct TranscriptionRepairTests {

    @Test("An implausibly long word is clamped, not trusted")
    func clampsLongWord() {
        // Observed on real footage: the recogniser gave one isolated token a 9.9 s
        // range, which became a caption that sat on screen for 9.9 s.
        let words = [TimedWord(text: "Come", start: 49.1, end: 59.0)]
        let repaired = TranscriptionService.repairTimings(words, duration: 3434)
        #expect(repaired.count == 1)
        let duration = repaired[0].end - repaired[0].start
        #expect(duration <= TranscriptionService.maxPlausibleWordDuration + 1e-9,
                "word still spans \(duration)s")
        // The start is when speech began and must be preserved.
        #expect(abs(repaired[0].start - 49.1) < 1e-9)
    }

    @Test("Words collapsed onto the end of the clip are spread back at a speaking pace")
    func spreadsTailAtEndOfClip() {
        // Real Apex output: the last 28 words of a 68.265 s clip all at 68.265.
        var words = (0..<20).map { TimedWord(text: "w\($0)", start: 50 + Double($0) * 0.4,
                                             end: 50 + Double($0) * 0.4 + 0.35) }
        words += (0..<28).map { _ in TimedWord(text: "t", start: 68.265, end: 68.265) }
        let repaired = TranscriptionService.repairTimings(words, duration: 68.265)
        #expect(repaired.count == 48)
        let tail = repaired.suffix(28)
        #expect((tail.last?.end ?? 0) <= 68.265 + 1e-9)
        #expect((tail.first?.start ?? 99) < 68.265 - 28 * 0.25, "tail still crammed at the end")
        for (a, b) in zip(repaired, repaired.dropFirst()) {
            #expect(b.start >= a.end - 1e-9, "timings out of order")
        }
    }

    @Test("Fast speech before a collapsed ending keeps its own timings")
    func fastSpeechIsNotFlattened() {
        // Hinglish at ~0.25 s a word is faster than the 0.3 s repair pace. The repair
        // used to walk back over every word and space all 260 words of a 68 s clip
        // exactly 0.26 s apart, so no caption matched its speech.
        var words: [TimedWord] = (0..<80).map { (i: Int) -> TimedWord in
            let start: Double = Double(i) * 0.25 + Double(i % 3) * 0.03
            return TimedWord(text: "w\(i)", start: start, end: start + 0.15)
        }
        words += (0..<5).map { _ in TimedWord(text: "t", start: 20.64, end: 20.64) }
        let repaired = TranscriptionService.repairTimings(words, duration: 20.65)
        for i in 0..<70 {
            #expect(abs(repaired[i].start - words[i].start) < 1e-9, "word \(i) moved")
        }
        #expect(repaired.suffix(5).allSatisfy { $0.end - $0.start > 0.05 })
    }

    @Test("Words stamped past the end of the audio are spread back, not stacked")
    func spreadsWordsPastTheEnd() {
        var words = (0..<20).map { TimedWord(text: "w\($0)", start: 50 + Double($0) * 0.4,
                                             end: 50 + Double($0) * 0.4 + 0.35) }
        words += (0..<12).map { k in TimedWord(text: "t", start: 68.5 + Double(k) * 0.2,
                                                end: 68.6 + Double(k) * 0.2) }
        let repaired = TranscriptionService.repairTimings(words, duration: 68.265)
        let tail = repaired.suffix(12)
        #expect(tail.allSatisfy { $0.end - $0.start > 0.1 }, "tail words still have no time")
        #expect((tail.last?.end ?? 99) <= 68.265 + 1e-9)
    }

    @Test("Normal word durations are left alone")
    func leavesNormalWords() {
        let words = [TimedWord(text: "Hello", start: 0, end: 0.42),
                     TimedWord(text: "there", start: 0.42, end: 1.10)]
        let repaired = TranscriptionService.repairTimings(words, duration: 2)
        #expect(abs(repaired[0].end - 0.42) < 1e-9)
        #expect(abs(repaired[1].end - 1.10) < 1e-9)
    }

    @Test("Punctuation-only tokens never become their own word")
    func foldsPunctuation() {
        // Real footage produced cues reading `,,,,,,` because each comma arrived as
        // its own token with its own long time range.
        let words = [TimedWord(text: "Hello", start: 0, end: 0.4),
                     TimedWord(text: ",", start: 0.4, end: 9.0),
                     TimedWord(text: ",", start: 9.0, end: 14.0),
                     TimedWord(text: "there", start: 14.0, end: 14.4)]
        let repaired = TranscriptionService.repairTimings(words, duration: 20)
        for word in repaired {
            let isPunctuationOnly = word.text.allSatisfy { !$0.isLetter && !$0.isNumber }
            #expect(!isPunctuationOnly, "'\(word.text)' survived as its own word")
        }
        #expect(repaired.first?.text == "Hello,,")
        #expect(repaired.count == 2)
    }

    @Test("A spine that is only punctuation yields nothing rather than junk")
    func allPunctuationYieldsNothing() {
        let words = [TimedWord(text: ",", start: 0, end: 1),
                     TimedWord(text: ".", start: 1, end: 2)]
        #expect(TranscriptionService.repairTimings(words, duration: 3).isEmpty)
    }

    @Test("Collapsed trailing timestamps are spread out, not left stacked")
    func spreadsCollapsedTail() {
        // whisper.cpp reports the tail of a clip with identical timestamps.
        let words = [TimedWord(text: "one", start: 0, end: 1.0),
                     TimedWord(text: "two", start: 5.29, end: 5.29),
                     TimedWord(text: "three", start: 5.29, end: 5.29)]
        let repaired = TranscriptionService.repairTimings(words, duration: 6.0)
        #expect(repaired.count == 3)
        for i in repaired.indices where i + 1 < repaired.count {
            #expect(repaired[i].start <= repaired[i + 1].start + 1e-9,
                    "timings are not monotonic")
        }
        #expect(repaired.allSatisfy { $0.end <= 6.0 + 1e-9 }, "clamped to media duration")
    }

    @Test("Timings are monotonic and never exceed the media length")
    func monotonicAndClamped() {
        let words = [TimedWord(text: "a", start: 5.0, end: 2.0),     // end before start
                     TimedWord(text: "b", start: 1.0, end: 3.0),     // out of order
                     TimedWord(text: "c", start: 0.5, end: 99.0)]    // past the end
        let repaired = TranscriptionService.repairTimings(words, duration: 10)
        for word in repaired {
            #expect(word.end >= word.start, "'\(word.text)' ends before it starts")
            #expect(word.end <= 10 + 1e-9, "'\(word.text)' runs past the media")
            #expect(word.start >= 0)
        }
        for i in repaired.indices where i + 1 < repaired.count {
            #expect(repaired[i].end <= repaired[i + 1].start + 1e-9, "overlap at \(i)")
        }
    }
}

@Suite("Locale routing")
struct LocaleRoutingTests {

    /// `supportedLocale(equivalentTo:)` happily returns a locale whose asset does not
    /// exist, so routing must match on `supportedLocales` membership instead.
    @Test("Region preference order is honoured")
    func regionPreference() {
        let supported = [Locale(identifier: "en_ZA"), Locale(identifier: "en_US"),
                         Locale(identifier: "en_GB"), Locale(identifier: "en_IN")]
        // An explicit region wins.
        #expect(TranscriptionService.pick(supported, Locale(identifier: "en_GB"))?
            .identifier(.bcp47) == "en-GB")
        // A bare language must not land on whatever enumerated first (en-ZA).
        let bare = TranscriptionService.pick(supported, Locale(identifier: "en"))?
            .identifier(.bcp47)
        #expect(bare != "en-ZA", "bare 'en' fell back to enumeration order")
        #expect(bare == "en-US" || bare == "en-IN", "got \(bare ?? "nil")")
    }

    @Test("An unsupported language routes nowhere")
    func unsupportedLanguage() {
        let supported = [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")]
        #expect(TranscriptionService.pick(supported, Locale(identifier: "hi_IN")) == nil)
    }

    @Test("Routing is deterministic across calls")
    func deterministic() {
        let supported = [Locale(identifier: "de_AT"), Locale(identifier: "de_CH"),
                         Locale(identifier: "de_DE")]
        let first = TranscriptionService.pick(supported, Locale(identifier: "de"))
        for _ in 0..<20 {
            #expect(TranscriptionService.pick(supported, Locale(identifier: "de"))?
                .identifier(.bcp47) == first?.identifier(.bcp47))
        }
    }
}

@Suite("Timing repair — real clip")
struct TailCollapseRealClipTests {
    /// Apex on a 9.42 s Hindi clip: the last 15 words all stamped 9.42–9.42.
    @Test("Collapsed words at the very end of a short clip are spread back")
    func shortClipTail() {
        var words: [TimedWord] = [
            .init(text: "Namaste", start: 0, end: 0.46), .init(text: "doston,", start: 0.46, end: 1.07),
            .init(text: "aaj", start: 1.07, end: 1.20), .init(text: "ham", start: 1.20, end: 1.42),
            .init(text: "ek", start: 1.42, end: 1.54), .init(text: "naya", start: 1.54, end: 1.86),
            .init(text: "phone", start: 1.86, end: 2.25), .init(text: "dekhenge.", start: 2.25, end: 3.24),
            .init(text: "Iski", start: 3.24, end: 4.13), .init(text: "battery", start: 4.13, end: 6.11),
            .init(text: "bahut", start: 6.11, end: 7.52), .init(text: "achchhi", start: 7.52, end: 9.42),
        ]
        words += (0..<14).map { _ in TimedWord(text: "w", start: 9.42, end: 9.42) }
        // The real last word ended 1 ms later, at the true end of the audio.
        words.append(TimedWord(text: "laga?", start: 9.42, end: 9.421125))
        let repaired = TranscriptionService.repairTimings(words, duration: 9.421125)
        let tail = repaired.suffix(15)
        #expect(tail.allSatisfy { $0.end - $0.start > 0.1 }, "tail still collapsed: \(tail.map { ($0.start, $0.end) })")
    }
}

@Suite("Squeezed timeline")
struct CompressedTimelineTests {
    private func words(_ ends: [Double]) -> [TimedWord] {
        var start = 0.0
        return ends.map { end in defer { start = end }; return TimedWord(text: "w", start: start, end: end) }
    }

    @Test("A timeline at half speed is stretched to the speech")
    func halfSpeed() {
        // The observed case: speech to 58 s, every word stamped at half its time — so
        // about 3 words a second came out as 6.
        let squeezed = words(stride(from: 0.16, through: 29.0, by: 0.16).map { $0 })
        let result = TranscriptionService.correctCompressedTimeline(squeezed, speechEnd: 58, duration: 58)
        #expect(result.scaled)
        #expect(abs((result.words.last?.end ?? 0) - 58) < 0.2)
        #expect(abs(result.words[10].start - squeezed[10].start * (58 / squeezed.last!.end)) < 0.01)
    }

    @Test("Talking for half a Reel then music is not mistaken for a squeezed timeline")
    func musicOutro() {
        // 3 words a second until 22 s of a 45 s Reel, then music: the same 2× shape,
        // but at a real speaking rate.
        let talk = words(stride(from: 0.33, through: 22.0, by: 0.33).map { $0 })
        #expect(!TranscriptionService.correctCompressedTimeline(talk, speechEnd: 45, duration: 45).scaled)
    }

    @Test("A normal timeline, or one that simply stops early, is left alone")
    func leftAlone() {
        let normal = words(stride(from: 0.5, through: 57.5, by: 0.5).map { $0 })
        #expect(!TranscriptionService.correctCompressedTimeline(normal, speechEnd: 58, duration: 58).scaled)
        // Speech genuinely ends at 20 s of a 58 s video with music after: not 2×.
        let short = words(stride(from: 0.5, through: 10, by: 0.5).map { $0 })
        #expect(!TranscriptionService.correctCompressedTimeline(short, speechEnd: 58, duration: 58).scaled)
    }
}

@Suite("Words after a pause")
struct LeadingSilenceTests {
    @Test("A word timed from the start of a pause starts where its sound does")
    func trimsPause() {
        // Speech 0–1.5 s, silence 1.5–5.5 s, speech again from 5.6 s.
        let levels = [Float](repeating: 0.3, count: 15) + [Float](repeating: 0.001, count: 41) + [Float](repeating: 0.3, count: 20)
        let words = [TimedWord(text: "uno", start: 0.1, end: 1.4),
                     TimedWord(text: "Hola,", start: 3.78, end: 6.06),
                     TimedWord(text: "amigo", start: 6.06, end: 6.6)]
        let out = TranscriptionService.trimLeadingSilence(words, levels: levels)
        #expect(abs(out[1].start - 5.6) < 0.11, "\(out[1].start)")
        #expect(out[0].start == 0.1 && out[2].start == 6.06)
    }
}
