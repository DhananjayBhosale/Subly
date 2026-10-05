import Testing
import Foundation
@testable import SublyCaptions

// MARK: - Helpers

private func spine(_ words: [(String, Double, Double)],
                   language: String = "en-US",
                   confidence: Double? = nil) -> TimingSpine {
    TimingSpine(words: words.map { TimedWord(text: $0.0, start: $0.1, end: $0.2, confidence: confidence) },
                sourceLanguage: language,
                duration: words.last?.2 ?? 0,
                engineID: "test")
}

/// Evenly spaced words, `step` seconds each.
private func evenSpine(_ texts: [String], step: Double = 0.3,
                       language: String = "en-US") -> TimingSpine {
    var words: [TimedWord] = []
    for (i, t) in texts.enumerated() {
        words.append(TimedWord(text: t, start: Double(i) * step, end: Double(i + 1) * step))
    }
    return TimingSpine(words: words, sourceLanguage: language,
                       duration: Double(texts.count) * step, engineID: "test")
}

// MARK: - Segmenter invariants

@Suite("Segmenter invariants")
struct SegmenterTests {

    @Test("Cues are chronological and never overlap")
    func chronologicalNonOverlapping() {
        let rules = CaptionRules.shortForm
        let seg = Segmenter(rules: rules, profile: .latin)
        let s = evenSpine((1...40).map { "word\($0)" })
        let slots = seg.segment(s)

        #expect(!slots.isEmpty)
        for i in slots.indices {
            #expect(slots[i].end >= slots[i].start, "slot \(i) has negative duration")
            if i + 1 < slots.count {
                #expect(slots[i].end <= slots[i + 1].start + 1e-9,
                        "slot \(i) end \(slots[i].end) overlaps slot \(i+1) start \(slots[i + 1].start)")
                #expect(slots[i].start < slots[i + 1].start, "slots not strictly increasing at \(i)")
            }
        }
    }

    @Test("Every word lands in exactly one slot, none dropped or duplicated")
    func wordCoverageIsExact() {
        let seg = Segmenter(rules: .shortForm, profile: .latin)
        let s = evenSpine((1...37).map { "w\($0)" })
        let slots = seg.segment(s)
        var covered: [Int] = []
        for slot in slots { covered.append(contentsOf: Array(slot.wordRange)) }
        #expect(covered.sorted() == Array(0..<s.words.count),
                "expected full coverage 0..<\(s.words.count), got \(covered.sorted())")
    }

    @Test("Empty spine yields no slots")
    func emptySpine() {
        let seg = Segmenter(rules: .shortForm, profile: .latin)
        #expect(seg.segment(spine([])).isEmpty)
    }

    @Test("Single word produces one slot meeting the minimum duration")
    func singleWord() {
        let rules = CaptionRules.shortForm
        let seg = Segmenter(rules: rules, profile: .latin)
        let s = TimingSpine(words: [TimedWord(text: "Hello", start: 0, end: 0.1)],
                            sourceLanguage: "en-US", duration: 5, engineID: "test")
        let slots = seg.segment(s)
        #expect(slots.count == 1)
        #expect(slots[0].duration >= rules.minCueDuration - 1e-9,
                "expected >= \(rules.minCueDuration), got \(slots[0].duration)")
    }

    @Test("Sentence boundaries are preferred as cue breaks")
    func sentenceBoundary() {
        let seg = Segmenter(rules: .shortForm, profile: .latin)
        let s = spine([("Hello", 0, 0.4), ("there.", 0.4, 1.2),
                       ("Next", 1.3, 1.7), ("sentence.", 1.7, 2.6)])
        let slots = seg.segment(s)
        #expect(slots.count == 2, "expected a break after the full stop, got \(slots.count) slots")
        #expect(slots[0].endsSentence)
    }

    @Test("A long pause forces a cue break")
    func pauseBoundary() {
        let seg = Segmenter(rules: .shortForm, profile: .latin)
        let s = spine([("one", 0, 0.4), ("two", 0.4, 0.8),
                       ("three", 3.0, 3.4), ("four", 3.4, 3.8)])
        let slots = seg.segment(s)
        #expect(slots.count >= 2, "a 2.2s gap must break the cue")
    }

    @Test("No slot exceeds the maximum cue duration where avoidable")
    func maxDurationRespected() {
        let rules = CaptionRules.shortForm
        let seg = Segmenter(rules: rules, profile: .latin)
        let s = evenSpine((1...60).map { "w\($0)" }, step: 0.5)
        let slots = seg.segment(s)
        // Allow the merge path to exceed slightly, but nothing wild.
        for slot in slots {
            #expect(slot.duration <= rules.maxCueDuration * 2,
                    "slot \(slot.index) duration \(slot.duration) far exceeds cap")
        }
    }

    @Test("Character-based scripts segment on character count, not word count")
    func characterBasedSegmentation() {
        let seg = Segmenter(rules: .shortForm, profile: .cjk)
        // 40 single-glyph "words" — word-based rules would give ~5 cues of 8.
        let s = evenSpine((1...40).map { _ in "字" }, step: 0.2, language: "zh-CN")
        let slots = seg.segment(s)
        #expect(!slots.isEmpty)
        for slot in slots {
            let chars = s.words[slot.wordRange].reduce(0) { $0 + $1.text.count }
            #expect(chars <= ScriptProfile.cjk.maxCharsPerLine * 2 + 2,
                    "CJK slot has \(chars) chars, over the 2-line budget")
        }
    }

    @Test("Pathological input does not hang or crash", .timeLimit(.minutes(1)))
    func pathologicalInput() {
        let seg = Segmenter(rules: .shortForm, profile: .latin)
        // All words at identical timestamps — a real possibility when an engine
        // reports no usable timing.
        let words = (0..<200).map { _ in TimedWord(text: "x", start: 1.0, end: 1.0) }
        let s = TimingSpine(words: words, sourceLanguage: "en-US", duration: 1.0, engineID: "t")
        let slots = seg.segment(s)
        #expect(!slots.isEmpty)
        for i in slots.indices where i + 1 < slots.count {
            #expect(slots[i].end <= slots[i + 1].start + 1e-9)
        }
    }
}

// MARK: - Formatter

@Suite("Caption formatter")
struct FormatterTests {

    @Test("Word limit is enforced on every line")
    func wordLimit() {
        for limit in 1...8 {
            var rules = CaptionRules.shortForm
            rules.maxWordsPerLine = limit
            rules.maxCharsPerLine = 500          // isolate the word rule
            let f = CaptionFormatter(rules: rules, profile: .latin)
            let lines = f.breakIntoLines("one two three four five six seven eight nine ten")
            for line in lines {
                #expect(line.split(separator: " ").count <= limit,
                        "limit \(limit): line '\(line)' has \(line.split(separator: " ").count) words")
            }
        }
    }

    @Test("Character limit is enforced")
    func charLimit() {
        var rules = CaptionRules.shortForm
        rules.maxCharsPerLine = 20
        rules.maxWordsPerLine = 99
        let f = CaptionFormatter(rules: rules, profile: .latin)
        let lines = f.breakIntoLines("alpha bravo charlie delta echo foxtrot golf")
        for line in lines {
            #expect(line.count <= 20, "line '\(line)' is \(line.count) chars")
        }
    }

    @Test("A single word longer than the character limit is never dropped")
    func overlongWordPreserved() {
        var rules = CaptionRules.shortForm
        rules.maxCharsPerLine = 5
        let f = CaptionFormatter(rules: rules, profile: .latin)
        let lines = f.breakIntoLines("Kraftfahrzeughaftpflichtversicherung")
        #expect(lines.joined().contains("Kraftfahrzeug"),
                "an over-long word must survive, got \(lines)")
    }

    @Test("Text is never silently lost when breaking into lines")
    func noTextLoss() {
        let inputs = [
            "one two three four five six seven eight",
            "Hello, world. This is a test of the caption system!",
            "आप कैसे हो यह बहुत अच्छा है",
            "a",
            "word1 word2",
        ]
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        for input in inputs {
            let lines = f.breakIntoLines(input)
            let rejoined = lines.joined(separator: " ")
            let normalise = { (s: String) in
                s.split(separator: " ").joined(separator: " ")
            }
            #expect(normalise(rejoined) == normalise(input),
                    "text changed:\n  in:  \(input)\n  out: \(rejoined)")
        }
    }

    @Test("Unifying subdivides a slot inside its own time range, never beyond it")
    func splitStaysInsideSlot() {
        var rules = CaptionRules.shortForm
        rules.maxWordsPerLine = 2
        rules.maxLinesPerCue = 1
        let f = CaptionFormatter(rules: rules, profile: .latin)
        let words = (0..<8).map {
            TimedWord(text: "w\($0)", start: 10.0 + Double($0) * 0.5,
                      end: 10.5 + Double($0) * 0.5)
        }
        let slot = CueSlot(index: 0, start: 10.0, end: 14.0, wordRange: 0..<8, endsSentence: true)
        let text = "one two three four five six seven eight"
        let demand = f.requiredCueCount(for: text, duration: slot.duration)
        #expect(demand > 1, "eight words at two per line needs more than one cue")

        let unified = CaptionFormatter.unify(slots: [slot], demands: [[0: demand]], words: words)
        #expect(unified.count > 1, "slot should have been subdivided")
        #expect(unified.first!.start >= slot.start - 1e-9)
        #expect(unified.last!.end <= slot.end + 1e-9)
        for i in unified.indices where i + 1 < unified.count {
            #expect(unified[i].end <= unified[i + 1].start + 1e-9, "sub-slots overlap")
        }
        let cues = f.fill(slots: unified, texts: [0: text])
        #expect(cues.count == unified.count, "one cue per slot")
    }

    @Test("Every track gets the same cue grid even when one needs far more room")
    func unifiedGridIsShared() {
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        let words = (0..<6).map {
            TimedWord(text: "w\($0)", start: Double($0) * 0.5, end: 0.5 + Double($0) * 0.5)
        }
        let slot = CueSlot(index: 0, start: 0, end: 3, wordRange: 0..<6, endsSentence: true)
        let shortText = "hi"
        let longText = String(repeating: "word ", count: 30)
        let demands = [[0: f.requiredCueCount(for: shortText, duration: 3)],
                       [0: f.requiredCueCount(for: longText, duration: 3)]]
        let unified = CaptionFormatter.unify(slots: [slot], demands: demands, words: words)

        let a = f.fill(slots: unified, texts: [0: shortText])
        let b = f.fill(slots: unified, texts: [0: longText])
        #expect(a.count == b.count, "cue counts must match: \(a.count) vs \(b.count)")
        for (x, y) in zip(a, b) {
            #expect(abs(x.start - y.start) < 1e-9)
            #expect(abs(x.end - y.end) < 1e-9)
        }
    }

    @Test("Empty slot text produces an empty cue, not a crash")
    func emptySlotText() {
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        let slot = CueSlot(index: 0, start: 0, end: 1, wordRange: 0..<0, endsSentence: false)
        let cues = f.fill(slots: [slot], texts: [:])
        #expect(cues.count == 1)
        #expect(cues[0].lines.isEmpty)
    }

    @Test("Reflow preserves the spoken words exactly")
    func reflowPreservesWords() {
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        let original = [Cue(slotIndex: 0, start: 0, end: 3,
                            lines: ["one two three four five", "six seven"])]
        let reflowed = f.reflow(original)
        let before = original.flatMap { $0.lines.joined(separator: " ").split(separator: " ") }
        let after = reflowed.flatMap { $0.lines.joined(separator: " ").split(separator: " ") }
        #expect(before == after, "reflow changed words: \(before) → \(after)")
    }

    @Test("Validator reports over-limit edits instead of truncating")
    func validatorFlagsOverLimit() {
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        let cue = Cue(slotIndex: 0, start: 0, end: 2,
                      lines: ["one two three four five six seven eight nine"])
        let issues = f.validate([cue]).map(\.issue)
        #expect(issues.contains(.overWordLimit))
        // The text itself must be untouched.
        #expect(cue.lines[0].split(separator: " ").count == 9)
    }

    @Test("Validator catches overlap, short, long and empty cues")
    func validatorCoverage() {
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        let overlapping = [Cue(slotIndex: 0, start: 0, end: 2, lines: ["a b"]),
                           Cue(slotIndex: 1, start: 1, end: 3, lines: ["c d"])]
        #expect(f.validate(overlapping).map(\.issue).contains(.overlap))

        let tooShort = [Cue(slotIndex: 0, start: 0, end: 0.2, lines: ["hi"])]
        #expect(f.validate(tooShort).map(\.issue).contains(.tooShort))

        let tooLong = [Cue(slotIndex: 0, start: 0, end: 30, lines: ["hi"])]
        #expect(f.validate(tooLong).map(\.issue).contains(.tooLong))

        let empty = [Cue(slotIndex: 0, start: 0, end: 2, lines: [])]
        #expect(f.validate(empty).map(\.issue).contains(.empty))
    }
}

// MARK: - Cross-track invariant

@Suite("Cross-track alignment")
struct CrossTrackTests {

    @Test("Different text in the same slots yields identical timings")
    func identicalTimings() {
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        let seg = Segmenter(rules: .shortForm, profile: .latin)
        let s = evenSpine(["Here", "there", "are", "far", "fewer", "reflections.",
                           "At", "high", "brightness", "it", "feels", "smooth."])
        let slots = seg.segment(s)

        var english: [Int: String] = [:]
        var roman: [Int: String] = [:]
        for slot in slots {
            english[slot.index] = "english text here"
            roman[slot.index] = "roman text"
        }
        let a = f.fill(slots: slots, texts: english)
        let b = f.fill(slots: slots, texts: roman)

        #expect(a.count == b.count, "cue counts differ: \(a.count) vs \(b.count)")
        for (x, y) in zip(a, b) {
            #expect(abs(x.start - y.start) < 1e-9, "start differs at slot \(x.slotIndex)")
            #expect(abs(x.end - y.end) < 1e-9, "end differs at slot \(x.slotIndex)")
        }
    }

    @Test("Very long translated text still shares the slot's outer bounds")
    func overflowKeepsOuterBounds() {
        let f = CaptionFormatter(rules: .shortForm, profile: .latin)
        let slot = CueSlot(index: 0, start: 5, end: 8, wordRange: 0..<4, endsSentence: true)
        let short = f.fill(slots: [slot], texts: [0: "short"])
        let long = f.fill(slots: [slot], texts: [0: String(repeating: "word ", count: 40)])
        #expect(short.first!.start == long.first!.start)
        #expect(short.last!.end == long.last!.end)
    }
}

// MARK: - Romanizer

@Suite("Romanizer")
struct RomanizerTests {
    let r = Romanizer()

    @Test("Hindi flagship phrase reaches the conventional spelling")
    func hindiFlagship() {
        let out = r.romanize("आप कैसे हो", language: "hi")
        #expect(out.text.lowercased().hasPrefix("aap"),
                "expected schwa-deleted 'aap', got '\(out.text)'")
        #expect(!out.text.contains("ā"), "diacritics must be gone: \(out.text)")
        #expect(out.lowConfidence == false, "Hindi is a reviewed language")
    }

    @Test("Final schwa deletion")
    func schwaDeletion() {
        #expect(r.deleteFinalSchwa("aapa") == "aap")
        #expect(r.deleteFinalSchwa("bahuta") == "bahut")
        #expect(r.deleteFinalSchwa("aapa kaise ho") == "aap kaise ho")
        // Trailing punctuation must be preserved.
        #expect(r.deleteFinalSchwa("bahuta.") == "bahut.")
        #expect(r.deleteFinalSchwa("hai, bahuta!") == "hai, bahut!")
    }

    @Test("Schwa deletion never mangles short or vowel-final words")
    func schwaDeletionSafety() {
        // Too short to touch.
        #expect(r.deleteFinalSchwa("ka") == "ka")
        #expect(r.deleteFinalSchwa("a") == "a")
        // Preceding vowel: deleting would break the syllable.
        #expect(r.deleteFinalSchwa("kya") == "kya")
        #expect(r.deleteFinalSchwa("aa") == "aa")
        // Long `a` arrives doubled from the orthography pass and must survive;
        // collapseFinalLongA then renders it `accha`.
        #expect(r.deleteFinalSchwa("acchaa") == "acchaa")
        #expect(Romanizer.collapseFinalLongA("acchaa") == "accha")
        // Latin words must pass through untouched.
        for word in ["camera", "data", "media", "extra", "alpha"] {
            #expect(r.deleteFinalSchwa(word) == word, "mangled '\(word)'")
        }
    }

    @Test("Protected English terms survive romanization")
    func protectedTerms() {
        let out = r.romanize("यह आईफ़ोन डिस्प्ले बहुत अच्छा है", language: "hi",
                             protectedTerms: ["iPhone", "display"])
        #expect(out.text.contains("iPhone"), "iPhone not restored: \(out.text)")
        #expect(out.text.contains("display"), "display not restored: \(out.text)")
    }

    @Test("User-supplied protected terms are honoured")
    func customProtectedTerms() {
        let out = r.romanize("कैमरा", language: "hi", protectedTerms: ["Camera"])
        #expect(out.text.contains("Camera") || out.text.contains("camera"),
                "custom term ignored: \(out.text)")
    }

    @Test("Latin-script input is a no-op, not an error")
    func latinIsNoOp() {
        let out = r.romanize("Hello world", language: "es")
        #expect(out.text == "Hello world")
        #expect(out.lowConfidence == false)
        #expect(out.note != nil, "should explain that it is already Latin")
    }

    @Test("Japanese does not get Chinese pinyin applied to kanji")
    func japaneseNotPinyin() {
        // Generic Any-Latin renders 元気 as "yuán qì". The Japanese chain must not.
        let out = r.romanize("こんにちは", language: "ja")
        #expect(out.text.lowercased().contains("konnichi")
                || out.text.lowercased().contains("kon'nichi"),
                "unexpected Japanese romanization: \(out.text)")
    }

    @Test("Korean and Chinese produce expected romanizations")
    func otherScripts() {
        #expect(r.romanize("안녕하세요", language: "ko").text.lowercased().contains("annyeong"))
        let zh = r.romanize("你好", language: "zh").text.lowercased()
        #expect(zh.contains("ni") && zh.contains("hao"), "pinyin expected, got \(zh)")
    }

    @Test("Unvocalised scripts are flagged low confidence")
    func unreliableFlagged() {
        for lang in ["ar", "he", "fa"] {
            let out = r.romanize("שלום", language: lang)
            #expect(out.lowConfidence, "\(lang) must be flagged low confidence")
            #expect(out.note != nil)
        }
    }

    @Test("Empty and whitespace input is handled")
    func emptyInput() {
        #expect(r.romanize("", language: "hi").text.isEmpty)
        #expect(r.romanize("   ", language: "hi").text.isEmpty)
    }

    @Test("Digraph substitutions are applied before single characters")
    func substitutionOrder() {
        // ṭh must become "th", not "t"+"h" from a wrong-order pass producing "tha".
        let out = r.applyOrthography("ṭhīka", language: "hi")
        #expect(out.contains("th"), "retroflex aspirate lost: \(out)")
        #expect(!out.contains("ṭ"), "raw retroflex remains: \(out)")
    }
}

// MARK: - Writers

@Suite("Subtitle writers")
struct WriterTests {
    let w = SubtitleWriter()

    private func track(_ cues: [Cue], tag: String = "en") -> SubtitleTrack {
        SubtitleTrack(kind: .original, languageTag: tag, displayName: "Test",
                      cues: cues, engineID: "test")
    }

    @Test("SRT timecode format uses a comma separator")
    func srtTimecode() {
        #expect(SubtitleWriter.srtTime(0) == "00:00:00,000")
        #expect(SubtitleWriter.srtTime(39.18) == "00:00:39,180")
        #expect(SubtitleWriter.srtTime(3661.5) == "01:01:01,500")
        #expect(SubtitleWriter.srtTime(-5) == "00:00:00,000")
    }

    @Test("VTT timecode format uses a period separator")
    func vttTimecode() {
        #expect(SubtitleWriter.vttTime(39.18) == "00:00:39.180")
    }

    @Test("SRT output is well formed and sequentially numbered")
    func srtStructure() {
        let t = track([Cue(slotIndex: 0, start: 0, end: 2, lines: ["Line one", "Line two"]),
                       Cue(slotIndex: 1, start: 2, end: 4, lines: ["Second"])])
        let srt = w.srt(t)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nLine one\nLine two\n\n"))
        #expect(srt.contains("2\n00:00:02,000 --> 00:00:04,000\nSecond"))
    }

    @Test("Blank cues are skipped and numbering stays contiguous")
    func blankCuesSkipped() {
        let t = track([Cue(slotIndex: 0, start: 0, end: 1, lines: ["A"]),
                       Cue(slotIndex: 1, start: 1, end: 2, lines: []),
                       Cue(slotIndex: 2, start: 2, end: 3, lines: ["B"])])
        let srt = w.srt(t)
        #expect(srt.contains("1\n") && srt.contains("2\n"))
        #expect(!srt.contains("3\n"), "numbering must not skip: \n\(srt)")
    }

    @Test("VTT carries the required header")
    func vttHeader() {
        let vtt = w.vtt(track([Cue(slotIndex: 0, start: 0, end: 1, lines: ["Hi"])]))
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(vtt.contains("Language: en"))
    }

    @Test("Validation rejects overlap, negative duration and empty tracks")
    func validation() {
        #expect(throws: (any Error).self) { try w.validate(track([])) }
        #expect(throws: (any Error).self) {
            try w.validate(track([Cue(slotIndex: 0, start: 5, end: 2, lines: ["x"])]))
        }
        #expect(throws: (any Error).self) {
            try w.validate(track([Cue(slotIndex: 0, start: 0, end: 3, lines: ["a"]),
                                  Cue(slotIndex: 1, start: 1, end: 4, lines: ["b"])]))
        }
        // Valid track must not throw.
        try! w.validate(track([Cue(slotIndex: 0, start: 0, end: 2, lines: ["a"]),
                               Cue(slotIndex: 1, start: 2, end: 4, lines: ["b"])]))
    }

    @Test("Filenames carry BCP-47 tags including the script subtag")
    func filenames() {
        let en = track([], tag: "en")
        let hiLatn = SubtitleTrack(kind: .romanized, languageTag: "hi-Latn",
                                   displayName: "Hinglish", cues: [], engineID: "t")
        #expect(w.filename(base: "clip", track: en, format: .srt) == "clip.en.srt")
        #expect(w.filename(base: "clip", track: hiLatn, format: .srt) == "clip.hi-Latn.srt")
        #expect(w.filename(base: "clip", track: en, format: .vtt) == "clip.en.vtt")
    }

    @Test("Non-Latin scripts survive a write/read round trip")
    func unicodeRoundTrip() throws {
        let samples = ["आप कैसे हो", "こんにちは", "안녕하세요", "مرحبا", "Здравствуйте", "你好"]
        for (i, text) in samples.enumerated() {
            let t = track([Cue(slotIndex: 0, start: Double(i), end: Double(i) + 1, lines: [text])])
            let srt = w.srt(t)
            #expect(srt.contains(text), "lost '\(text)'")
            let data = srt.data(using: .utf8)
            #expect(data != nil, "'\(text)' is not UTF-8 encodable")
            #expect(String(data: data!, encoding: .utf8)!.contains(text))
        }
    }

    @Test("JSON export is valid JSON")
    func jsonValid() throws {
        let t = track([Cue(slotIndex: 0, start: 0, end: 2, lines: ["Hello"])])
        let json = try w.json(t, spine: evenSpine(["Hello"]))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        #expect(parsed is [String: Any])
    }
}

// MARK: - Importer

@Suite("Subtitle importer")
struct ImporterTests {
    let importer = SubtitleImporter()

    @Test("Parses SRT")
    func parseSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        First line
        Second line

        2
        00:00:04,000 --> 00:00:06,000
        Another cue
        """
        let cues = importer.parse(srt)
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0)
        #expect(abs(cues[0].end - 3.5) < 1e-9)
        #expect(cues[0].lines == ["First line", "Second line"])
    }

    @Test("Parses VTT including cue settings after the timestamp")
    func parseVTT() {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:03.000 line:90%
        Hello
        """
        let cues = importer.parse(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].start == 1.0)
        #expect(cues[0].end == 3.0)
    }

    @Test("Malformed input yields no cues rather than crashing")
    func malformed() {
        #expect(importer.parse("").isEmpty)
        #expect(importer.parse("not a subtitle file at all").isEmpty)
        #expect(importer.parse("1\ngarbage timing\ntext").isEmpty)
    }

    @Test("Time parser handles both separators and missing hours")
    func timeParsing() {
        #expect(SubtitleImporter.parseTime("00:00:01,500") == 1.5)
        #expect(SubtitleImporter.parseTime("00:00:01.500") == 1.5)
        #expect(SubtitleImporter.parseTime("01:02:03,004") == 3723.004)
        #expect(SubtitleImporter.parseTime("02:03.5") == 123.5)
        #expect(SubtitleImporter.parseTime("garbage") == nil)
    }
}

// MARK: - Script profiles

@Suite("Script profiles")
struct ScriptProfileTests {

    @Test("Languages map to the right script and direction")
    func mapping() {
        #expect(ScriptProfile.forLanguage("hi").scriptCode == "Deva")
        #expect(ScriptProfile.forLanguage("hi-IN").scriptCode == "Deva")
        #expect(ScriptProfile.forLanguage("ja").segmentation == .characterBased)
        #expect(ScriptProfile.forLanguage("zh-CN").segmentation == .characterBased)
        #expect(ScriptProfile.forLanguage("ar").isRightToLeft)
        #expect(ScriptProfile.forLanguage("he").isRightToLeft)
        #expect(ScriptProfile.forLanguage("ur").isRightToLeft)
        #expect(!ScriptProfile.forLanguage("en").isRightToLeft)
    }

    @Test("A Latin script subtag overrides the base language")
    func latnOverride() {
        // hi-Latn is romanized Hindi: Latin rules, and not romanizable again.
        #expect(ScriptProfile.forLanguage("hi-Latn").scriptCode == "Latn")
        #expect(ScriptProfile.forLanguage("hi-Latn").romanizable == false)
    }

    @Test("Latin-script languages are not offered romanization")
    func latinNotRomanizable() {
        for lang in ["en", "es", "fr", "de", "it", "pt", "nl", "id", "vi"] {
            #expect(ScriptProfile.forLanguage(lang).romanizable == false,
                    "\(lang) should not be romanizable")
        }
    }

    @Test("Non-Latin scripts are romanizable")
    func nonLatinRomanizable() {
        for lang in ["hi", "ja", "ko", "zh", "ru", "el", "th", "ta", "ar", "he"] {
            #expect(ScriptProfile.forLanguage(lang).romanizable,
                    "\(lang) should be romanizable")
        }
    }

    @Test("Rules adopt script-appropriate limits")
    func rulesAdjust() {
        // The script scales the preset rather than replacing it. Replacing it meant
        // every preset behaved the same, which made the preset picker a no-op for
        // reading rate and line length.
        let cjk = CaptionRules.shortForm.adjusted(for: .cjk)
        let latin = CaptionRules.shortForm.adjusted(for: .latin)
        // Never longer than the script can physically hold.
        #expect(cjk.maxCharsPerLine <= ScriptProfile.cjk.maxCharsPerLine)
        // Denser script, stricter limits than the same preset on Latin.
        #expect(cjk.maxCharsPerLine < latin.maxCharsPerLine)
        #expect(cjk.maxReadingRate < latin.maxReadingRate)
        // The user's explicit word choice is preserved.
        #expect(cjk.maxWordsPerLine == CaptionRules.shortForm.maxWordsPerLine)
    }
}

// MARK: - Reading rate

@Suite("Cue metrics")
struct CueMetricTests {

    @Test("Reading rate is characters per second")
    func readingRate() {
        let cue = Cue(slotIndex: 0, start: 0, end: 2, lines: ["12345", "12345"])
        #expect(cue.characterCount == 10)
        #expect(abs(cue.readingRate - 5.0) < 1e-9)
    }

    @Test("Zero-duration cue reports infinite rate rather than dividing by zero")
    func zeroDuration() {
        let cue = Cue(slotIndex: 0, start: 1, end: 1, lines: ["text"])
        #expect(cue.readingRate == .infinity)
    }
}

// MARK: - Engine timing artefacts

@Suite("Engine timing artefacts")
struct TimingArtefactTests {

    /// whisper.cpp collapses the last few word timestamps onto one value. The
    /// segmenter must still produce a readable final cue.
    @Test("A collapsed tail does not leave a flashing final cue")
    func collapsedTail() {
        let words: [TimedWord] = [
            .init(text: "Aap", start: 0.0, end: 0.28), .init(text: "kaise", start: 0.28, end: 0.51),
            .init(text: "ho?", start: 0.51, end: 1.02), .init(text: "Yah", start: 1.02, end: 1.04),
            .init(text: "iPhone", start: 1.04, end: 1.49), .init(text: "ka", start: 1.49, end: 1.54),
            .init(text: "display", start: 1.54, end: 2.00), .init(text: "bahut", start: 2.00, end: 2.32),
            .init(text: "achchha", start: 2.32, end: 2.77), .init(text: "hai.", start: 2.77, end: 3.31),
            .init(text: "Camera", start: 3.31, end: 4.34), .init(text: "ki", start: 4.34, end: 4.70),
            .init(text: "quality", start: 4.70, end: 5.29), .init(text: "bhi", start: 5.29, end: 5.29),
            .init(text: "shaandaar", start: 5.29, end: 5.29), .init(text: "hai.", start: 5.29, end: 5.297),
        ]
        let spine = TimingSpine(words: words, sourceLanguage: "hi-Latn",
                                duration: 5.297, engineID: "test")
        let rules = CaptionRules.shortForm
        let slots = Segmenter(rules: rules, profile: .latin).segment(spine)

        #expect(!slots.isEmpty)
        let tooShort = slots.filter { $0.duration + 1e-6 < rules.minCueDuration }
        let detail = tooShort.map {
            String(format: "#%d %.3f-%.3f (%.3fs)", $0.index, $0.start, $0.end, $0.duration)
        }.joined(separator: ", ")
        #expect(tooShort.isEmpty, "slots under the minimum: \(detail)")
        for i in slots.indices where i + 1 < slots.count {
            #expect(slots[i].end <= slots[i + 1].start + 1e-9)
        }
    }
}

// MARK: - Caption rule presets

@Suite("Caption presets")
struct PresetTests {

    @Test("Every shipped preset is internally consistent")
    func presetsConsistent() {
        for (name, rules) in CaptionRules.presets {
            #expect(rules.maxWordsPerLine >= 1, "\(name): word limit too low")
            #expect(rules.maxLinesPerCue >= 1 && rules.maxLinesPerCue <= 2, "\(name): line count")
            #expect(rules.minCueDuration > 0, "\(name): min duration")
            #expect(rules.maxCueDuration > rules.minCueDuration, "\(name): duration range inverted")
            #expect(rules.maxCharsPerLine > 0, "\(name): char limit")
            #expect(rules.maxReadingRate > 0, "\(name): reading rate")
            #expect(rules.maxWordsPerCue == rules.maxWordsPerLine * rules.maxLinesPerCue)
        }
    }

    @Test("Script adjustment never loosens the user's word limit")
    func adjustmentKeepsWordLimit() {
        var rules = CaptionRules.shortForm
        rules.maxWordsPerLine = 3
        for profile in [ScriptProfile.latin, .devanagari, .cjk, .arabic, .thai, .korean] {
            let adjusted = rules.adjusted(for: profile)
            #expect(adjusted.maxWordsPerLine == 3,
                    "\(profile.scriptCode) changed the word limit")
            // Never looser than the script's ceiling; a preset may be stricter.
            #expect(adjusted.maxCharsPerLine <= profile.maxCharsPerLine,
                    "\(profile.scriptCode) exceeded the script's line length")
        }
    }
}

// MARK: - Regressions found in review

@Suite("Review regressions")
struct ReviewRegressionTests {
    let r = Romanizer()

    @Test("enforceMinimum terminates on sub-ULP borrows", .timeLimit(.minutes(1)))
    func noInfiniteBorrowLoop() {
        // At large timestamps the spare time is below one ULP, so subtracting it is a
        // no-op. Reporting that as progress used to spin the loop forever.
        let a = CueSlot(index: 0, start: 2047.0, end: 2048.0000000000005,
                        wordRange: 0..<2, endsSentence: false, parentIndex: 0)
        let b = CueSlot(index: 1, start: 2048.0000000000005, end: 2048.5,
                        wordRange: 2..<3, endsSentence: true, parentIndex: 1)
        let out = CaptionFormatter.enforceMinimum([a, b], minimum: 1.0)
        #expect(out.count >= 1)
    }

    @Test("Minimum duration never borrows across silence")
    func noBorrowAcrossSilence() {
        // Slot 0 is speech ending at 3.0; slot 1 is speech starting at 5.0 after two
        // seconds of silence. Borrowing would cut slot 0 off mid-word and show slot 1
        // before anyone speaks.
        let words = [TimedWord(text: "one", start: 0, end: 1.0),
                     TimedWord(text: "two", start: 1.0, end: 3.0),
                     TimedWord(text: "three", start: 5.0, end: 5.2)]
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: 5.2, engineID: "test")
        let slots = Segmenter(rules: .shortForm, profile: .latin).segment(spine)
        for slot in slots {
            #expect(slot.start >= -1e-9)
            // Nothing may start before the word it covers.
            let firstWord = words[slot.wordRange.lowerBound]
            #expect(slot.start <= firstWord.start + 1e-6,
                    "slot \(slot.index) starts at \(slot.start), after its first word \(firstWord.start)")
            #expect(slot.start >= firstWord.start - 2.0,
                    "slot \(slot.index) was dragged \(firstWord.start - slot.start)s into silence")
        }
    }

    @Test("Identical word start times never yield a zero-duration slot")
    func noZeroDurationFromIdenticalStarts() {
        let words = [TimedWord(text: "a.", start: 1.0, end: 1.0),
                     TimedWord(text: "b.", start: 1.0, end: 2.5),
                     TimedWord(text: "c.", start: 2.5, end: 3.5)]
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: 3.5, engineID: "test")
        let slots = Segmenter(rules: .shortForm, profile: .latin).segment(spine)
        for slot in slots {
            #expect(slot.end > slot.start - 1e-9, "slot \(slot.index) has negative duration")
            #expect(slot.duration > 0, "slot \(slot.index) has zero duration")
        }
    }

    @Test("Typographic punctuation counts as Latin, not a foreign script")
    func typographicPunctuationIsLatin() {
        // `don’t` with a curly apostrophe used to fall through to Devanagari rules,
        // which stripped the apostrophe and then deleted the final vowel.
        for token in ["don’t", "“camera”", "display—", "Apple…", "it’s", "—dash"] {
            #expect(Romanizer.isAlreadyLatin(token), "'\(token)' should be treated as Latin")
        }
        #expect(!Romanizer.isAlreadyLatin("आप"))
        #expect(!Romanizer.isAlreadyLatin("こんにちは"))
    }

    @Test("A quoted or bracketed protected term is still restored")
    func protectedTermWithSurroundingPunctuation() {
        let lexicon = Romanizer.lexicon(adding: ["iPhone"])
        for token in ["aaeefona", "“aaeefona”", "(aaeefona)", "aaeefona,", "—aaeefona"] {
            let restored = Romanizer.restore(token, lexicon: lexicon)
            #expect(restored?.contains("iPhone") == true,
                    "'\(token)' -> \(restored ?? "nil")")
        }
    }

    @Test("Reflow does not inject spaces into scripts that have none")
    func reflowKeepsCJKUnspaced() {
        let formatter = CaptionFormatter(rules: .shortForm, profile: .cjk)
        let cue = Cue(slotIndex: 0, start: 0, end: 3,
                      lines: ["これは日本語", "のテストです"])
        let out = formatter.reflow([cue])
        let joined = out.flatMap(\.lines).joined()
        #expect(!joined.contains(" "), "reflow inserted a space: '\(joined)'")
        #expect(joined == "これは日本語のテストです", "text changed: '\(joined)'")
    }

    @Test("Stressed Cyrillic u stays a u")
    func stressedCyrillicU() {
        // ICU emits `ú` for a stressed `у`; mapping it to "y" produced `ryka`.
        let out = r.applyOrthography("rúka", language: "ru")
        #expect(out.lowercased().contains("ruka"), "got '\(out)'")
        #expect(!out.lowercased().contains("ryka"))
    }

    @Test("A blank cell in the shared grid is never exported")
    func blankCellsNotExported() {
        // Tracks share one grid, so a track with less text can have a blank cell.
        // It must keep its slot (the invariant) but never reach the file.
        let track = SubtitleTrack(kind: .translation, languageTag: "en",
                                  displayName: "T", cues: [
            Cue(slotIndex: 0, start: 0, end: 1, lines: ["Hello"]),
            Cue(slotIndex: 1, start: 1, end: 2, lines: []),
            Cue(slotIndex: 2, start: 2, end: 3, lines: ["world"]),
        ], engineID: "test")
        let srt = SubtitleWriter().srt(track)
        #expect(srt.contains("Hello") && srt.contains("world"))
        // Two cues written, numbered contiguously.
        #expect(srt.contains("1\n") && srt.contains("2\n") && !srt.contains("3\n"))
    }

    @Test("Distribute never loses text and fills as evenly as it can")
    func distributeIsLossless() {
        let formatter = CaptionFormatter(rules: .shortForm, profile: .latin)
        for subCount in 1...5 {
            for wordCount in 1...12 {
                let words = (1...wordCount).map { "w\($0)" }
                let text = words.joined(separator: " ")
                let parts = formatter.distribute(text, across: subCount)
                #expect(parts.count == subCount,
                        "subCount \(subCount), words \(wordCount): got \(parts.count) parts")
                let rejoined = parts.filter { !$0.isEmpty }.joined(separator: " ")
                #expect(rejoined == text,
                        "lost text at subCount \(subCount), words \(wordCount): '\(rejoined)'")
            }
        }
    }
}

// MARK: - Second review round regressions

@Suite("Review round 2 regressions")
struct ReviewRound2Tests {

    @Test("Three words on one timestamp never leak a zero-duration slot")
    func cascadingOverlapsResolved() {
        // A single forward pass fixed slot 0 against slot 1 but never re-checked the
        // overlap its own nudge created between slot 1 and slot 2.
        let words = [TimedWord(text: "a.", start: 1.0, end: 1.0),
                     TimedWord(text: "b.", start: 1.0, end: 1.0),
                     TimedWord(text: "c.", start: 1.0, end: 1.0),
                     TimedWord(text: "d.", start: 1.0, end: 2.0)]
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: 2.0, engineID: "test")
        let slots = Segmenter(rules: .shortForm, profile: .latin).segment(spine)
        for slot in slots {
            #expect(slot.duration > 0,
                    "slot \(slot.index) is \(slot.start)-\(slot.end)")
        }
        for i in slots.indices where i + 1 < slots.count {
            #expect(slots[i].end <= slots[i + 1].start + 1e-9,
                    "slot \(i) still overlaps slot \(i + 1)")
        }
    }

    @Test("Export validation rejects a zero-duration cue")
    func zeroDurationRejected() {
        let writer = SubtitleWriter()
        let track = SubtitleTrack(kind: .original, languageTag: "en", displayName: "T",
                                  cues: [Cue(slotIndex: 0, start: 5, end: 5, lines: ["hi"])],
                                  engineID: "test")
        // 00:00:05,000 --> 00:00:05,000 is ill-formed and rejected by real players.
        #expect(throws: (any Error).self) { try writer.validate(track) }
    }

    @Test("Reflow overflow does not inject spaces into CJK")
    func reflowOverflowKeepsCJKUnspaced() {
        var rules = CaptionRules.shortForm
        rules.maxLinesPerCue = 1          // force the overflow branch
        let formatter = CaptionFormatter(rules: rules, profile: .cjk)
        let text = String(repeating: "日", count: 40)
        let out = formatter.reflow([Cue(slotIndex: 0, start: 0, end: 3, lines: [text])])
        let joined = out.flatMap(\.lines).joined()
        #expect(!joined.contains(" "), "overflow reflow inserted a space")
        #expect(joined == text, "text changed length \(joined.count) vs \(text.count)")
    }
}

// MARK: - Unified-grid text keying

@Suite("Unified grid text keying")
struct UnifiedGridKeyingTests {

    /// `fill` looks text up by `parentIndex`. Keying by the unified sub-slot index
    /// instead silently dropped every word after the first sub-slot of each parent —
    /// which is exactly how re-adding an output lost half the transcript.
    @Test("Parent-keyed text covers every word; sub-slot-keyed text does not")
    func parentKeyingIsRequired() {
        let words = (0..<8).map {
            TimedWord(text: "W\($0)", start: Double($0) * 0.5, end: 0.5 + Double($0) * 0.5)
        }
        let slot = CueSlot(index: 0, start: 0, end: 4, wordRange: 0..<8, endsSentence: true)
        var rules = CaptionRules.shortForm
        rules.maxWordsPerLine = 2
        rules.maxLinesPerCue = 1
        let formatter = CaptionFormatter(rules: rules, profile: .latin)

        let demand = formatter.requiredCueCount(for: words.map(\.text).joined(separator: " "),
                                                duration: slot.duration)
        let unified = CaptionFormatter.unify(slots: [slot], demands: [[0: demand]], words: words)
        #expect(unified.count > 1, "slot should subdivide")
        #expect(unified.allSatisfy { $0.parentIndex == 0 })

        // Correct: key by parent.
        let full = words.map(\.text).joined(separator: " ")
        let correct = formatter.fill(slots: unified, texts: [0: full])
        let covered = correct.flatMap { $0.lines.joined(separator: " ").split(separator: " ") }
            .map(String.init)
        #expect(covered == words.map(\.text), "parent-keyed fill lost words: \(covered)")

        // Wrong: key by unified sub-slot index. Only the parent-0 slot resolves.
        var bySubSlot: [Int: String] = [:]
        for s in unified { bySubSlot[s.index] = words[s.wordRange].map(\.text).joined(separator: " ") }
        let broken = formatter.fill(slots: unified, texts: bySubSlot)
        let brokenWords = broken.flatMap { $0.lines.joined(separator: " ").split(separator: " ") }
        #expect(brokenWords.count < words.count,
                "sub-slot keying should under-cover, proving the contract matters")
    }

    @Test("Capping subdivision to the thinnest track prevents blank cues")
    func fillableCapAvoidsBlanks() {
        let words = (0..<6).map {
            TimedWord(text: "w\($0)", start: Double($0) * 0.5, end: 0.5 + Double($0) * 0.5)
        }
        let slot = CueSlot(index: 0, start: 0, end: 3, wordRange: 0..<6, endsSentence: true)
        let formatter = CaptionFormatter(rules: .shortForm, profile: .latin)

        let dense = String(repeating: "word ", count: 30)
        let thin = "hi"                         // one token — can fill only one cue
        let demands = [[0: formatter.requiredCueCount(for: dense, duration: 3)],
                       [0: formatter.requiredCueCount(for: thin, duration: 3)]]

        let unified = CaptionFormatter.unify(slots: [slot], demands: demands, words: words,
                                             minCueDuration: 0, fillable: [0: 1])
        #expect(unified.count == 1, "cap should hold the grid at one cue")

        let a = formatter.fill(slots: unified, texts: [0: dense])
        let b = formatter.fill(slots: unified, texts: [0: thin])
        #expect(a.count == b.count)
        // Neither track may end up with an empty cue, because the writers drop those
        // and the exported files would then disagree on cue count.
        #expect(a.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(b.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}

// MARK: - Real-footage regressions

@Suite("Real footage regressions")
struct RealFootageTests {

    /// A 57-minute real video produced 69 cues over the 4-second cap, the worst
    /// lasting 14.34 s, because the recogniser attributed a long span to a single
    /// isolated token.
    @Test("A single word with an implausible span cannot hold a cue past the cap")
    func singleLongWordIsClamped() {
        let rules = CaptionRules.shortForm
        let words = [TimedWord(text: "Come", start: 49.1, end: 59.0)]   // 9.9 s, as observed
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: 3434, engineID: "test")
        let slots = Segmenter(rules: rules, profile: .latin).segment(spine)
        #expect(!slots.isEmpty)
        for slot in slots {
            #expect(slot.duration <= rules.maxCueDuration + 1e-6,
                    "slot \(slot.index) lasts \(slot.duration)s, cap is \(rules.maxCueDuration)s")
            #expect(slot.duration >= rules.minCueDuration - 1e-6)
        }
    }

    @Test("Sparse speech never leaves a caption lingering through silence")
    func noLingeringThroughSilence() {
        let rules = CaptionRules.shortForm
        // Two words, then a long silence before the next.
        let words = [TimedWord(text: "Hello", start: 0, end: 0.4),
                     TimedWord(text: "there.", start: 0.4, end: 0.9),
                     TimedWord(text: "Later", start: 30.0, end: 30.4)]
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: 40, engineID: "test")
        let slots = Segmenter(rules: rules, profile: .latin).segment(spine)
        for slot in slots {
            #expect(slot.duration <= rules.maxCueDuration + 1e-6,
                    "slot \(slot.index) spans \(slot.duration)s of mostly silence")
        }
    }

    @Test("Long-form input keeps every invariant", .timeLimit(.minutes(1)))
    func longFormInvariants() {
        // ~2600 words over 57 minutes, matching the real test file's density.
        var words: [TimedWord] = []
        var t = 0.0
        for i in 0..<2600 {
            let dur = 0.18 + Double(i % 5) * 0.06
            words.append(TimedWord(text: "w\(i)", start: t, end: t + dur, confidence: 0.6))
            // Periodic silence, as real speech has.
            t += dur + (i % 17 == 0 ? 2.4 : 0.06)
        }
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: t + 1, engineID: "test")
        let rules = CaptionRules.shortForm
        let slots = Segmenter(rules: rules, profile: .latin).segment(spine)

        #expect(!slots.isEmpty)
        var covered: [Int] = []
        for slot in slots {
            covered.append(contentsOf: Array(slot.wordRange))
            #expect(slot.duration > 0, "slot \(slot.index) has no duration")
            #expect(slot.duration <= rules.maxCueDuration + 1e-6,
                    "slot \(slot.index) lasts \(slot.duration)s")
        }
        #expect(covered.sorted() == Array(0..<words.count), "words lost or duplicated")
        for i in slots.indices where i + 1 < slots.count {
            #expect(slots[i].end <= slots[i + 1].start + 1e-9, "overlap at \(i)")
        }
    }
}

// MARK: - Maximum duration is an invariant

@Suite("Cue duration cap")
struct DurationCapTests {

    /// Exact input from an independent review: eight words, a short isolated word,
    /// then eight more. The last-resort merge used to allow 1.6x the cap, producing a
    /// 4.4 s slot under a 4.0 s cap with nothing left to re-split it.
    @Test("The merge pass cannot breach the cap")
    func mergeCannotBreachCap() {
        var words: [TimedWord] = []
        var t = 0.0
        for i in 0..<8 { words.append(TimedWord(text: "p\(i)", start: t, end: t + 0.40)); t += 0.45 }
        words.append(TimedWord(text: "Oh.", start: 4.10, end: 4.40))
        t = 4.45
        for i in 0..<8 { words.append(TimedWord(text: "q\(i)", start: t, end: t + 0.44)); t += 0.49 }

        let rules = CaptionRules.shortForm
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: t + 0.5, engineID: "test")
        let slots = Segmenter(rules: rules, profile: .latin).segment(spine)

        for slot in slots {
            #expect(slot.duration <= rules.maxCueDuration + 1e-6,
                    "slot \(slot.index) is \(String(format: "%.3f", slot.duration))s, cap is \(rules.maxCueDuration)s")
            #expect(slot.duration > 0)
        }
        // And nothing was lost while enforcing it.
        var covered: [Int] = []
        for slot in slots { covered.append(contentsOf: Array(slot.wordRange)) }
        #expect(covered.sorted() == Array(0..<words.count))
    }

    @Test("The cap holds across every shipped preset")
    func capHoldsForAllPresets() {
        var words: [TimedWord] = []
        var t = 0.0
        for i in 0..<40 {
            let d = 0.3 + Double(i % 7) * 0.25
            words.append(TimedWord(text: "w\(i)", start: t, end: t + d))
            t += d + (i % 6 == 0 ? 1.9 : 0.04)
        }
        let spine = TimingSpine(words: words, sourceLanguage: "en-US",
                                duration: t + 1, engineID: "test")
        for (name, rules) in CaptionRules.presets {
            let slots = Segmenter(rules: rules, profile: .latin).segment(spine)
            for slot in slots {
                #expect(slot.duration <= rules.maxCueDuration + 1e-6,
                        "\(name): slot \(slot.index) is \(String(format: "%.2f", slot.duration))s")
            }
        }
    }
}

@Suite("Words per caption")
struct WordsPerCaptionTests {
    /// The real case: a caption filled up at "on" and "point." was shown alone.
    @Test("A sentence ending is not left on screen by itself")
    func noOrphanedSentenceEnd() {
        let text = "the heart rate measurement was on point and the sleep data was point."
            .split(separator: " ").map(String.init)
        // 13 words, evenly 0.25 s apart, no pauses.
        let words = text.enumerated().map { (i, w) in (w, Double(i) * 0.25, Double(i) * 0.25 + 0.24) }
        var rules = CaptionRules.shortForm
        rules.setWordsPerCue(min: 3, max: 6)
        let slots = Segmenter(rules: rules, profile: .latin).segment(spine(words))
        for slot in slots {
            #expect(slot.wordRange.count >= 3, "slot \(slot.index) has \(slot.wordRange.count) word(s)")
        }
        #expect(slots.map(\.wordRange.count).reduce(0, +) == text.count)
    }

    @Test("A word isolated by a long pause is left alone rather than shown early")
    func isolatedWordStays() {
        let s = spine([("We", 0, 0.3), ("are", 0.3, 0.6), ("done", 0.6, 1.0), ("here.", 1.0, 1.4),
                       ("Thanks.", 5.0, 5.5)])
        let slots = Segmenter(rules: .shortForm, profile: .latin).segment(s)
        #expect(slots.last?.wordRange.count == 1)
        #expect((slots.last?.start ?? 0) >= 4.9)
    }

    @Test("Subdividing never splits off a single word")
    func unifyRespectsMinimum() {
        let words = (0..<7).map { TimedWord(text: "w\($0)", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.45) }
        let slot = CueSlot(index: 0, start: 0, end: 3.45, wordRange: 0..<7, endsSentence: true)
        let unified = CaptionFormatter.unify(slots: [slot], demands: [[0: 3]], words: words,
                                             minWordsPerPiece: 3)
        #expect(unified.count == 2)
        #expect(unified.allSatisfy { $0.wordRange.count >= 3 })
    }

    @Test("Projects saved before the setting existed still open, with the default")
    func decodesOldRules() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CaptionRules.shortForm)) as! [String: Any]
        json.removeValue(forKey: "minWordsPerCue")
        json.removeValue(forKey: "customMaxWordsPerCue")
        let rules = try JSONDecoder().decode(CaptionRules.self,
                                             from: JSONSerialization.data(withJSONObject: json))
        #expect(rules.minWordsPerCue == 3)
        #expect(rules.maxWordsPerCue == rules.maxWordsPerLine * rules.maxLinesPerCue)
    }
}

@Suite("Split and merge captions")
struct CaptionEditTests {
    private func fixture() -> (slots: [CueSlot], tracks: [SubtitleTrack], words: [TimedWord]) {
        let words = ["one", "two", "three", "four", "five", "six"].enumerated().map {
            TimedWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.9)
        }
        let slots = [CueSlot(index: 0, start: 0, end: 2.9, wordRange: 0..<3, endsSentence: false),
                     CueSlot(index: 1, start: 3, end: 5.9, wordRange: 3..<6, endsSentence: true)]
        let original = SubtitleTrack(kind: .original, languageTag: "en", displayName: "English", cues: [
            Cue(slotIndex: 0, start: 0, end: 2.9, lines: ["one two three"]),
            Cue(slotIndex: 1, start: 3, end: 5.9, lines: ["four five six"])], engineID: "t")
        let translation = SubtitleTrack(kind: .translation, languageTag: "es", displayName: "Spanish", cues: [
            Cue(slotIndex: 0, start: 0, end: 2.9, lines: ["uno dos tres"]),
            Cue(slotIndex: 1, start: 3, end: 5.9, lines: ["cuatro cinco seis"])], engineID: "t")
        return (slots, [original, translation], words)
    }

    @Test("Merging joins the text and timing in every track")
    func merge() throws {
        let f = fixture()
        let r = try CaptionEdits.merge(slot: 0, slots: f.slots, tracks: f.tracks)
        #expect(r.slots.count == 1)
        #expect(r.slots[0].start == 0 && r.slots[0].end == 5.9 && r.slots[0].wordRange == 0..<6)
        for track in r.tracks {
            #expect(track.cues.count == 1)
            #expect(track.cues[0].end == 5.9)
        }
        #expect(r.tracks[0].cues[0].lines.joined(separator: " ") == "one two three four five six")
        #expect(throws: CaptionEdits.EditError.noNextCaption) {
            try CaptionEdits.merge(slot: 0, slots: r.slots, tracks: r.tracks)
        }
    }

    @Test("Splitting cuts every track at the same moment")
    func split() throws {
        let f = fixture()
        let r = try CaptionEdits.split(slot: 0, at: 2.0, slots: f.slots, tracks: f.tracks, words: f.words)
        #expect(r.slots.count == 3)
        #expect(r.slots.map(\.index) == [0, 1, 2])
        #expect(r.slots[0].end == 2.0 && r.slots[1].start == 2.0)
        #expect(r.slots[0].wordRange == 0..<2 && r.slots[1].wordRange == 2..<3)
        for track in r.tracks {
            #expect(track.cues.map(\.slotIndex) == [0, 1, 2])
            #expect(track.cues[0].end == 2.0 && track.cues[1].start == 2.0)
            #expect(track.cues.allSatisfy { !$0.text.isEmpty })
        }
        #expect(r.tracks[0].cues[0].text == "one two")
        #expect(r.tracks[0].cues[1].text == "three")
        // Cue identities stay unique.
        #expect(Set(r.tracks[0].cues.map(\.id)).count == 3)
    }

    @Test("Splitting refuses a cut at the very edge or through a single word")
    func splitRefusals() {
        let f = fixture()
        #expect(throws: CaptionEdits.EditError.tooCloseToEdge) {
            try CaptionEdits.split(slot: 0, at: 0.05, slots: f.slots, tracks: f.tracks, words: f.words)
        }
        var tracks = f.tracks
        tracks[1].cues[0].lines = ["uno"]
        #expect(throws: CaptionEdits.EditError.tooShortToSplit(trackName: "Spanish")) {
            try CaptionEdits.split(slot: 0, at: 1.5, slots: f.slots, tracks: tracks, words: f.words)
        }
    }

    @Test("Sync moves the words, the cue grid and every track together")
    func shiftKeepsTracksInStep() {
        let f = fixture()
        let r = CaptionEdits.shift(by: 0.25, words: f.words, slots: f.slots, tracks: f.tracks,
                                   mediaDuration: 10)
        #expect(r.applied == 0.25)
        #expect(r.words.map(\.start) == f.words.map { $0.start + 0.25 })
        #expect(r.slots.map(\.start) == [0.25, 3.25])
        #expect(r.slots.map(\.end) == f.slots.map { $0.end + 0.25 })
        for track in r.tracks {
            #expect(track.cues.map(\.start) == r.slots.map(\.start))
            #expect(track.cues.map(\.end) == r.slots.map(\.end))
        }
        // Undoing by the opposite shift lands back where it started.
        let back = CaptionEdits.shift(by: -0.25, words: r.words, slots: r.slots, tracks: r.tracks)
        #expect(back.slots.map(\.start) == f.slots.map(\.start))
    }

    @Test("Sync stops at zero and at the end of the media, and keeps every caption visible")
    func shiftClamps() {
        let f = fixture()
        let earlier = CaptionEdits.shift(by: -1, words: f.words, slots: f.slots, tracks: f.tracks)
        #expect(earlier.applied == -1)
        #expect(earlier.slots[0].start == 0 && earlier.words[0].start == 0)
        #expect(earlier.slots[0].end > earlier.slots[0].start)
        for track in earlier.tracks {
            #expect(track.cues.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        }
        // The first caption ends at 2.9 s; it can't be pushed off the start entirely.
        let tooFar = CaptionEdits.shift(by: -5, words: f.words, slots: f.slots, tracks: f.tracks)
        #expect(abs(tooFar.applied - -2.8) < 1e-9)
        #expect(tooFar.slots.allSatisfy { $0.end - $0.start >= 0.1 - 1e-9 })
        // The last caption starts at 3 s in a 6 s video.
        let later = CaptionEdits.shift(by: 5, words: f.words, slots: f.slots, tracks: f.tracks,
                                       mediaDuration: 6)
        #expect(abs(later.applied - 2.9) < 1e-9)
        #expect(later.tracks.allSatisfy { $0.cues.allSatisfy { $0.end <= 6 && $0.end > $0.start } })
    }
}

@Suite("Find and replace")
struct TextReplaceTests {
    @Test("Whole-word replace leaves longer words alone")
    func wholeWords() {
        #expect(TextReplace.replace(in: "main ho, wo hota hai", find: "ho", with: "hoon", wholeWords: true)
                == "main hoon, wo hota hai")
        #expect(TextReplace.count(in: "ho hota Ho", find: "ho", wholeWords: true) == 2)
        #expect(TextReplace.replace(in: "hota", find: "ho", with: "X", wholeWords: false) == "Xta")
    }

    @Test("Devanagari vowel signs count as part of a word")
    func devanagari() {
        // "है" must not match inside "हैं".
        #expect(TextReplace.count(in: "वह है, वे हैं", find: "है", wholeWords: true) == 1)
    }

    @Test("Special characters are matched literally")
    func literal() {
        #expect(TextReplace.replace(in: "cost $5 (approx)", find: "$5 (approx)", with: "five", wholeWords: false)
                == "cost five")
        #expect(TextReplace.replace(in: "a.b", find: ".", with: "$1", wholeWords: false) == "a$1b")
    }
}

@Suite("Caption styles and animation timing")
struct CaptionStyleTests {
    @Test("Word timings cover the caption exactly, longer words taking longer")
    func wordTimes() {
        let words = CaptionAnimationTiming.words(in: "hi wonderful world", start: 10, end: 13)
        #expect(words.count == 3)
        #expect(abs(words.first!.start - 10) < 1e-9)
        #expect(abs(words.last!.end - 13) < 1e-9)
        for (a, b) in zip(words, words.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
        #expect(words[1].end - words[1].start > words[0].end - words[0].start)
        #expect(CaptionAnimationTiming.words(in: "", start: 0, end: 1).isEmpty)
    }

    @Test("Animations start hidden or small and settle fully visible")
    func transforms() {
        for animation in [CaptionStyle.Animation.fade, .pop, .slideUp] {
            let start = CaptionAnimationTiming.transform(animation, elapsed: 0, duration: 2)
            let middle = CaptionAnimationTiming.transform(animation, elapsed: 1, duration: 2)
            #expect(start.opacity < 0.01 || start.scale < 0.9 || start.offset > 0.1, "\(animation) does not animate in")
            #expect(abs(middle.opacity - 1) < 1e-9 && abs(middle.scale - 1) < 1e-9 && abs(middle.offset) < 1e-9,
                    "\(animation) not settled mid-caption")
        }
        let end = CaptionAnimationTiming.transform(.fade, elapsed: 2, duration: 2)
        #expect(end.opacity < 0.01)
    }

    @Test("Every template is a complete, sensible style")
    func templates() {
        for template in CaptionStyle.Template.allCases {
            let style = CaptionStyle.preset(template)
            #expect(style.template == template)
            #expect(style.size > 0.02 && style.size < 0.1)
            #expect(style.position > 0.1 && style.position < 0.95)
        }
        #expect(CaptionStyle.preset(.karaoke).animation == .wordHighlight)
        #expect(CaptionStyle.preset(.boldPop).display("hello") == "HELLO")
    }
}

@Suite("Hinglish spelling")
struct HinglishSpellingTests {
    let r = Romanizer()
    private func hi(_ s: String) -> String { r.romanize(s, language: "hi").text }

    @Test("च is ch, and छ is chh") func ch() {
        #expect(hi("चलो").lowercased() == "chalo")
        #expect(hi("चाहिए").lowercased().hasPrefix("chaah") || hi("चाहिए").lowercased().hasPrefix("chah"))
        #expect(hi("चेक").lowercased() == "check")
    }
    @Test("और is aur") func aur() { #expect(hi("और देखो").lowercased() == "aur dekho") }
    @Test("The nasal mark is n") func nasal() {
        #expect(hi("हूँ").lowercased() == "hoon")
        #expect(hi("यहाँ").lowercased().hasSuffix("an"))
    }
    @Test("Silent middle vowels are dropped") func medial() {
        #expect(hi("करता").lowercased() == "karta")
        #expect(hi("आपको").lowercased() == "aapko")
        #expect(hi("देखते").lowercased() == "dekhte")
        #expect(hi("करना").lowercased() == "karna")
        #expect(hi("सरकार").lowercased() == "sarkaar")
        // …but not where the vowel is heard.
        #expect(hi("कमल").lowercased() == "kamal")
        #expect(hi("समझ").lowercased() == "samajh")
    }
    @Test("Final long vowels as people type them") func finals() {
        #expect(hi("कितनी भी").lowercased() == "kitni bhi")
        #expect(hi("नहीं").lowercased() == "nahin")
        #expect(hi("में").lowercased() == "mein")
    }
    @Test("A brand at the start keeps its own capitals") func brandCase() {
        #expect(hi("आईफ़ोन अच्छा है").hasPrefix("iPhone"))
    }
}

@Suite("Subtitle files with blank lines")
struct BlankLineWriterTests {
    @Test("A blank line inside a caption is left out of SRT and VTT")
    func blankLinesDropped() {
        let cue = Cue(slotIndex: 0, start: 0, end: 2, lines: ["Hello", "", "world"])
        let track = SubtitleTrack(kind: .original, languageTag: "en", displayName: "English", cues: [cue], engineID: "test")
        let srt = SubtitleWriter().srt(track)
        #expect(srt.contains("Hello\nworld\n\n"))
        #expect(!srt.contains("Hello\n\nworld"))
        let back = SubtitleImporter().parse(srt)
        #expect(back.first?.lines == ["Hello", "world"])
        #expect(SubtitleWriter().vtt(track).contains("Hello\nworld\n\n"))
    }
}

@Suite("Reading projects from other versions")
struct LenientDecodingTests {
    @Test("A caption style with a look this version doesn't know still opens")
    func unknownTemplate() throws {
        let json = ##"{"template":"neon","font":"system","bold":true,"size":0.05,"textColor":"#FFFFFF","highlightColor":"#FFD60A","boxColor":"#000000","background":"glow","position":0.3,"uppercase":false,"animation":"bounce"}"##
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(json.utf8))
        #expect(style.template == .clean)
        #expect(style.background == CaptionStyle.preset(.clean).background)
        #expect(style.position == 0.3)
        #expect(style.size == 0.05)
    }

    @Test("A caption without the review fields still opens")
    func cueWithoutReview() throws {
        let json = #"{"id":"6B9F6A8E-7C5E-4C34-9E7A-8E0C3A8D2F11","slotIndex":2,"start":1.5,"end":3,"lines":["hi"]}"#
        let cue = try JSONDecoder().decode(Cue.self, from: Data(json.utf8))
        #expect(cue.lines == ["hi"] && cue.needsReview == false && cue.slotIndex == 2)
    }
}

@Suite("Japanese in English letters")
struct JapaneseRomajiTests {
    @Test("Kanji get readings, words get spaces, particles are spelled as said")
    func romaji() {
        let out = Romanizer().romanize("このiPhoneのディスプレイはとてもきれいです。カメラの画質も素晴らしい。", language: "ja").text
        #expect(!out.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }, "\(out)")
        #expect(out.contains(" "), "\(out)")
        #expect(out.lowercased().contains("iphone"), "\(out)")
        #expect(out.contains(" wa "), "\(out)")
        #expect(!out.contains("~"), "\(out)")
    }
}

@Suite("Splitting at a word")
struct SplitAtWordTests {
    @Test("Unedited text is split at the same word as the timing")
    func splitFollowsWords() throws {
        let texts = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
        // Seven quick words, then a pause, then the eighth at 1.3 s… and the caption runs to 2.6 s.
        var words = texts.prefix(7).enumerated().map { k, t in TimedWord(text: t, start: Double(k) * 0.15, end: Double(k) * 0.15 + 0.14) }
        words.append(TimedWord(text: "eight", start: 1.3, end: 2.6))
        let slot = CueSlot(index: 0, start: 0, end: 2.6, wordRange: 0..<8, endsSentence: true)
        let cue = Cue(slotIndex: 0, start: 0, end: 2.6, lines: [texts.joined(separator: " ")])
        let track = SubtitleTrack(kind: .original, languageTag: "en", displayName: "English", cues: [cue], engineID: "t")
        let result = try CaptionEdits.split(slot: 0, at: 1.3, slots: [slot], tracks: [track], words: words)
        let lines = result.tracks[0].cues.map { $0.lines.joined(separator: " ") }
        #expect(lines == ["one two three four five six seven", "eight"])
    }

    @Test("English letters with a respelled word are still split at the timing word")
    func splitFollowsRespelledWords() throws {
        let texts = ["yah", "phone", "bahut", "achchha", "hai", "aur", "camera", "bhi"]
        var words = texts.prefix(7).enumerated().map { k, t in TimedWord(text: t, start: Double(k) * 0.15, end: Double(k) * 0.15 + 0.14) }
        words.append(TimedWord(text: "bhi", start: 1.3, end: 2.6))
        let slot = CueSlot(index: 0, start: 0, end: 2.6, wordRange: 0..<8, endsSentence: true)
        let cue = Cue(slotIndex: 0, start: 0, end: 2.6, lines: ["ye phone bahut achha hai aur camera bhi"])
        let track = SubtitleTrack(kind: .romanized, languageTag: "hi-Latn", displayName: "Hinglish", cues: [cue], engineID: "t")
        let result = try CaptionEdits.split(slot: 0, at: 1.3, slots: [slot], tracks: [track], words: words)
        #expect(result.tracks[0].cues.map { $0.lines.joined(separator: " ") }
                == ["ye phone bahut achha hai aur camera", "bhi"])
    }
}

@Suite("Learning how someone spells")
struct SpellingPreferencesTests {
    private func pairs(_ old: String, _ new: String) -> [String] {
        SpellingPreferences.corrections(from: old, to: new).map { "\($0.heard)→\($0.preferred)" }
    }

    @Test("A one-word change is a spelling; rewording and case-only edits are not")
    func findsSwaps() {
        #expect(pairs("Yah iPhone ka display", "Ye iPhone ka display") == ["Yah→ye"])
        #expect(pairs("yah bahut achchha hai,", "yeh bahut acha hai,") == ["yah→yeh", "achchha→acha"])
        #expect(pairs("kaise ho", "kaise ho aap") == [])            // an added word
        #expect(pairs("main ghar ja raha", "hum office ja raha") == [])  // a rewording
        #expect(pairs("Yah achchha hai", "Ye achha hai") == ["Yah→ye", "achchha→achha"])
        // A different word is an edit, not a spelling.
        #expect(pairs("It is good", "It was good") == [])
        #expect(pairs("good food", "great flavor") == [])
        #expect(pairs("yah ka phone", "yah ki phone") == [])          // grammar, two letters
        #expect(pairs("can't stop", "can’t stop") == [])             // punctuation inside
        // A capital the sentence gave the word is not kept.
        #expect(pairs("teh book", "The book") == ["teh→the"])
        #expect(pairs("iphone ka camera", "iPhone ka camera") == ["iphone→iPhone"])
        #expect(pairs("delhi mein", "Delhi mein") == [])             // case only
        #expect(pairs("hai.", "hai!") == [])                         // punctuation only
        #expect(pairs("ek do teen", "ek 2 teen") == [])              // a number is not a spelling
    }

    @Test("Learned words are used on new captions, keeping punctuation and sentence capitals")
    func appliesWithCase() {
        var prefs = SpellingPreferences()
        prefs.learn(SpellingPreferences.corrections(from: "Yah achchha hai", to: "Ye achha hai"),
                    languageTag: "hi-Latn")
        #expect(prefs.apply(to: "yah display achchha hai, yah camera bhi.", languageTag: "hi-Latn")
                == "ye display achha hai, ye camera bhi.")
        #expect(prefs.apply(to: "Yah achchha.", languageTag: "hi-Latn") == "Ye achha.")
        #expect(prefs.apply(to: "YAH", languageTag: "hi-Latn") == "YE")
        // Another caption language is untouched, and so is a word that only contains it.
        #expect(prefs.apply(to: "yah", languageTag: "hi") == "yah")
        #expect(prefs.apply(to: "yahan", languageTag: "hi-Latn") == "yahan")
    }

    @Test("A spelling with its own capitals is kept as typed")
    func keepsBrandCapitals() {
        var prefs = SpellingPreferences()
        prefs.learn([.init(heard: "iphone", preferred: "iPhone")], languageTag: "hi-Latn")
        #expect(prefs.apply(to: "Iphone ka camera", languageTag: "hi-Latn") == "iPhone ka camera")
    }

    @Test("Only a word's own capitals are learned in a transcript or translation")
    func capitalsOnlyOutsideEnglishLetters() {
        #expect(SpellingPreferences.corrections(from: "yah phone", to: "ye phone", respellings: false).isEmpty)
        #expect(SpellingPreferences.corrections(from: "naya iphone", to: "naya iPhone", respellings: false)
                .map(\.preferred) == ["iPhone"])
        // Japanese has no spaces: a changed sentence is one "word" and must not be learned.
        #expect(SpellingPreferences.corrections(from: "明日は学校へ行く", to: "明日は会社へ行く").isEmpty)
    }

    @Test("A later spelling wins for every word that led to the old one")
    func revisesChain() {
        var prefs = SpellingPreferences()
        prefs.learn([.init(heard: "yah", preferred: "ye")], languageTag: "hi-Latn")
        prefs.learn([.init(heard: "ye", preferred: "yeh")], languageTag: "hi-Latn")
        #expect(prefs.apply(to: "yah ye", languageTag: "hi-Latn") == "yeh yeh")
        // Rules can be put back exactly, as Don't Learn and Undo do.
        let before = prefs.rules(for: "hi-Latn")
        prefs.learn([.init(heard: "yah", preferred: "ya")], languageTag: "hi-Latn")
        prefs.setRules(before, for: "hi-Latn")
        #expect(prefs.apply(to: "yah", languageTag: "hi-Latn") == "yeh")
    }

    @Test("Changing a word back forgets the earlier preference")
    func undoesLoop() {
        var prefs = SpellingPreferences()
        prefs.learn([.init(heard: "yah", preferred: "ye")], languageTag: "hi-Latn")
        prefs.learn([.init(heard: "ye", preferred: "yah")], languageTag: "hi-Latn")
        #expect(prefs.apply(to: "yah ye", languageTag: "hi-Latn") == "yah yah")
        #expect(prefs.rules["hi-Latn"]?["yah"] == nil)
    }

    @Test("Applies to a whole track and counts what it would change")
    func trackLevel() {
        var prefs = SpellingPreferences()
        prefs.learn([.init(heard: "yah", preferred: "ye")], languageTag: "hi-Latn")
        let track = SubtitleTrack(kind: .romanized, languageTag: "hi-Latn", displayName: "Hinglish",
                                  cues: [Cue(slotIndex: 0, start: 0, end: 1, lines: ["yah achha", "hai"]),
                                         Cue(slotIndex: 1, start: 1, end: 2, lines: ["Yah bhi"])],
                                  engineID: "test")
        #expect(prefs.changes(in: track) == 2)
        let fixed = prefs.apply(to: track)
        #expect(fixed.cues.map(\.lines) == [["ye achha", "hai"], ["Ye bhi"]])
        #expect(prefs.changes(in: fixed) == 0)
    }
}
