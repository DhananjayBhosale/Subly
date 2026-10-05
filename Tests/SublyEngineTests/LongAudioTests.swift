import Testing
import Foundation
import AVFoundation
@testable import SublyEngine
@testable import SublyCaptions

/// Long audio goes to whisper.cpp in pieces of at most 28 seconds. Run whole, a
/// 68-second Hinglish review lost its last 8 seconds where whisper's 30-second windows
/// hand over, and got a made-up repeat in their place.
@Suite("Long audio in pieces")
struct LongAudioTests {

    typealias Engine = ExtendedEngineManager

    // MARK: - Where to cut

    @Test("Audio of 28 seconds or less is never cut")
    func shortAudioStaysWhole() {
        for duration in [0.0, 5, 27.9, 28] {
            let levels = [Float](repeating: 100, count: Int(duration * 10))
            #expect(Engine.cutTimes(levels: levels, window: 0.1, duration: duration).isEmpty,
                    "\(duration) s was cut")
        }
    }

    @Test("Each cut lands on the quietest window between 16 and 27 seconds into the piece")
    func cutsAtQuietestWindowInRange() {
        var levels = [Float](repeating: 1000, count: 600)       // 60 s of speech
        levels[100] = 0     // silent, but only 10 s in: too early for a cut
        levels[280] = 0     // silent, but 28 s in: too late
        levels[205] = 10    // 20.5–20.6 s, the quietest allowed moment of the first piece
        levels[412] = 5     // 41.2–41.3 s, the quietest of the second
        let cuts = Engine.cutTimes(levels: levels, window: 0.1, duration: 60)
        #expect(cuts.count == 2, "got \(cuts)")
        #expect(abs(cuts[0] - 20.55) < 1e-9, "got \(cuts)")
        #expect(abs(cuts[1] - 41.25) < 1e-9, "got \(cuts)")
    }

    @Test("A quiet window right at either end of the range still counts")
    func rangeEndsAreInclusive() {
        var early = [Float](repeating: 1000, count: 400)
        early[160] = 1      // 16.0–16.1 s
        #expect(Engine.cutTimes(levels: early, window: 0.1, duration: 40).first.map { abs($0 - 16.05) < 1e-9 } == true)
        var late = [Float](repeating: 1000, count: 400)
        late[269] = 1       // 26.9–27.0 s
        #expect(Engine.cutTimes(levels: late, window: 0.1, duration: 40).first.map { abs($0 - 26.95) < 1e-9 } == true)
    }

    @Test("Audio with no quiet moment, or unreadable levels, is still cut into pieces of 28 s or less")
    func noQuietPointStillCut() {
        for levels in [[Float](repeating: 500, count: 6000), []] {
            let duration = 600.0
            let cuts = Engine.cutTimes(levels: levels, window: 0.1, duration: duration)
            let pieces = Engine.pieces(cuts: cuts, duration: duration)
            #expect(!cuts.isEmpty)
            for piece in pieces {
                #expect(piece.length <= 28 + 1e-9, "a \(piece.length) s piece")
                #expect(piece.length > 0)
            }
            // Every piece but the last starts at least 16 s before the next cut.
            for piece in pieces.dropLast() { #expect(piece.length >= 16 - 1e-9) }
        }
    }

    @Test("Pieces are back to back and cover the whole file")
    func piecesCoverTheFile() {
        let pieces = Engine.pieces(cuts: [20.55, 41.25], duration: 60)
        #expect(pieces == [.init(start: 0, end: 20.55), .init(start: 20.55, end: 41.25),
                           .init(start: 41.25, end: 60)])
        #expect(Engine.pieces(cuts: [], duration: 12) == [.init(start: 0, end: 12)])
    }

    // MARK: - Joining the pieces

    @Test("Each piece's words move onto the whole file's clock")
    func stitchOffsetsWords() {
        let first = Engine.AudioPiece(start: 0, end: 20)
        let second = Engine.AudioPiece(start: 20, end: 45)
        let words = Engine.stitch([
            (first, [TimedWord(text: "a", start: 1, end: 1.4), TimedWord(text: "b", start: 2, end: 2.5)]),
            (second, [TimedWord(text: "c", start: 0.5, end: 0.9), TimedWord(text: "d", start: 24, end: 24.6)]),
        ])
        #expect(words.map(\.text) == ["a", "b", "c", "d"])
        for (got, want) in zip(words.map(\.start), [1, 2, 20.5, 44]) { #expect(abs(got - want) < 1e-9) }
        for (got, want) in zip(words.map(\.end), [1.4, 2.5, 20.9, 44.6]) { #expect(abs(got - want) < 1e-9) }
    }

    @Test("A stretch of digital silence is cut in its middle, away from the speech around it")
    func silentStretchCutInMiddle() {
        var levels = [Float](repeating: 1000, count: 400)
        for i in 180..<220 { levels[i] = 0 }                   // silence from 18.0 to 22.0 s
        let cuts = Engine.cutTimes(levels: levels, window: 0.1, duration: 40)
        #expect(cuts.count == 1)
        #expect(abs(cuts[0] - 20.0) < 1e-9, "got \(cuts)")
    }

    @Test("Words whisper piles onto the end of a piece are kept inside it, in order")
    func stitchRepairsCollapsedPieceEnd() {
        // Real output for the middle piece of a clip: the last words all at the cut,
        // and the very last stamped 7 s beyond the audio. Unrepaired, the next piece
        // would be pushed later and later to stay after it.
        var tail = (0..<20).map { TimedWord(text: "w\($0)", start: 2 + Double($0) * 0.5,
                                            end: 2.4 + Double($0) * 0.5) }
        tail += (0..<5).map { _ in TimedWord(text: "t", start: 22.89, end: 22.89) }
        tail.append(TimedWord(text: "hai.", start: 22.89, end: 30))
        let first = Engine.AudioPiece(start: 0, end: 22.9)
        let second = Engine.AudioPiece(start: 22.9, end: 50)
        let next = [TimedWord(text: "But", start: 0.3, end: 0.6), TimedWord(text: "manual", start: 0.6, end: 1.0)]
        let words = Engine.stitch([(first, tail), (second, next)])

        #expect(words.count == tail.count + next.count)
        for word in words.prefix(tail.count) {
            #expect(word.end <= 22.9 + 1e-9, "\(word.text) runs past the cut to \(word.end)")
        }
        // The collapsed words got time of their own instead of one shared instant.
        for word in words.prefix(tail.count).suffix(6) {
            #expect(word.end - word.start > 0.1, "\(word.text) still has no time of its own")
        }
        // The next piece is where it was said, not shoved along.
        #expect(abs(words[tail.count].start - 23.2) < 1e-9)
        for (a, b) in zip(words, words.dropFirst()) {
            #expect(b.start >= a.end - 1e-9, "\(a.text) → \(b.text) out of order")
        }
    }

    @Test("Silence written in front of a piece is taken back off its word times")
    func leadInIsRemoved() {
        var piece = Engine.AudioPiece(start: 0, end: 10)
        piece.leadIn = 0.3
        let words = [TimedWord(text: "a", start: 0.1, end: 0.25), TimedWord(text: "b", start: 0.35, end: 0.8)]
        let out = Engine.stitch([(piece, words)])
        #expect(out.map(\.start) == [0, 0.35 - 0.3])
        #expect(abs(out[1].end - 0.5) < 1e-9)
    }

    @Test("A single piece is passed through untouched, as before")
    func singlePieceIsUnchanged() {
        let words = [TimedWord(text: "x", start: 3, end: 30), TimedWord(text: "y", start: 30, end: 30)]
        #expect(Engine.stitch([(Engine.AudioPiece(start: 0, end: 25), words)]) == words)
    }

    // MARK: - Progress

    @Test("Progress is measured on the whole file, piece after piece")
    func progressIsAbsolute() {
        let pieces = [Engine.AudioPiece(start: 0, end: 17.75), Engine.AudioPiece(start: 17.75, end: 40.65)]
        var reader = Engine.ProgressReader(pieces: pieces, paths: ["/t/piece-0.wav", "/t/piece-1.wav"])
        #expect(reader.read(line: "read_audio_data: reading audio data from '/t/piece-0.wav' ...") == nil)
        #expect(reader.read(line: "[00:00:01.000 --> 00:00:02.500]   lene") == 2.5)
        // Stamped past the end of its piece: held at the piece's end.
        #expect(reader.read(line: "[00:00:17.000 --> 00:00:30.000]   hai.") == 17.75)
        _ = reader.read(line: "output_json: saving output to '/t/piece-0.json'")
        _ = reader.read(line: "read_audio_data: reading audio data from '/t/piece-1.wav' ...")
        // Before any word of the new piece, nothing moves backwards.
        #expect(reader.read(line: "[00:00:00.000 --> 00:00:00.000]  ") == nil)
        let heard = reader.read(line: "[00:00:03.000 --> 00:00:04.000]   cricket")
        #expect(heard.map { abs($0 - 21.75) < 1e-9 } == true, "got \(String(describing: heard))")
        _ = reader.read(line: "error: failed to read audio file '/t/piece-2.wav'")
        #expect(reader.lastMessage == "error: failed to read audio file '/t/piece-2.wav'")
    }

    // MARK: - Vocabulary

    @Test("The vocabulary becomes one short whisper prompt")
    func promptFromVocabulary() {
        #expect(Engine.whisperPrompt(for: []) == nil)
        #expect(Engine.whisperPrompt(for: ["  ", "\n"]) == nil)
        #expect(Engine.whisperPrompt(for: ["Whoop", " Fitbit Air ", "whoop", "", "Amazfit\nT-Rex Ultra 2"])
                == "Whoop, Fitbit Air, Amazfit T-Rex Ultra 2.")
        let many = (0..<100).map { "Brand\($0)" }
        let prompt = Engine.whisperPrompt(for: many) ?? ""
        #expect(prompt.count <= 200)
        #expect(prompt.hasPrefix("Brand0, Brand1, "))
        #expect(prompt.hasSuffix("."))
        #expect(!prompt.contains(", ."))
    }

    // MARK: - Real audio files

    @Test("A long WAV is measured, cut where it is quiet, and copied into exact pieces")
    func splitsARealWAV() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("subly-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 40 s of loud noise with 300 ms of silence at 21.0 s.
        let source = folder.appendingPathComponent("audio.wav")
        let rate = 16_000.0
        let total = AVAudioFrameCount(40 * rate)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
            buffer.frameLength = total
            let samples = buffer.int16ChannelData![0]
            var seed: UInt32 = 1
            for i in 0..<Int(total) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let quiet = i >= Int(21.0 * rate) && i < Int(21.3 * rate)
                samples[i] = quiet ? 0 : Int16(truncatingIfNeeded: Int(seed >> 20) - 2048) * 4
            }
            try file.write(from: buffer)
        }

        let levels = try Engine.levels(ofWAV: source, window: 0.1)
        #expect(levels.count == 400)
        let cuts = Engine.cutTimes(levels: levels, window: 0.1, duration: 40)
        #expect(cuts.count == 1)
        #expect((21.0...21.3).contains(cuts[0]), "cut at \(cuts)")

        let pieces = Engine.pieces(cuts: cuts, duration: 40)
        let urls = [folder.appendingPathComponent("piece-0.wav"), folder.appendingPathComponent("piece-1.wav")]
        try Engine.writePieces(of: source, pieces: pieces, to: urls)
        let lengths = try urls.map { try AVAudioFile(forReading: $0).length }
        #expect(lengths[0] == AVAudioFramePosition((cuts[0] * rate).rounded()))
        #expect(lengths.reduce(0, +) == AVAudioFramePosition(total))
    }

    /// Runs the real engine. Opt in with SUBLY_LIVE_ENGINE=1; it needs a general
    /// Whisper model downloaded and the whisper-cli runtime in Resources/engine.
    @Test("Cancel stops whisper part-way through a long file and leaves nothing behind",
          .enabled(if: ProcessInfo.processInfo.environment["SUBLY_LIVE_ENGINE"] != nil))
    func cancelStopsTheEngine() async throws {
        let audio = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/en_long.wav")
        let temp = FileManager.default.temporaryDirectory
        func leftovers() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
                .filter { $0.hasPrefix("subly-ext-") })
        }
        func whisperRunning() -> Bool {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", "whisper-cli.*subly-ext-"]
            pgrep.standardOutput = FileHandle.nullDevice
            try? pgrep.run()
            pgrep.waitUntilExit()
            return pgrep.terminationStatus == 0
        }
        let before = leftovers()

        let run = Task { try await Engine.shared.transcribe(audioURL: audio, language: "en") }
        // Wait until whisper is actually working on the pieces.
        var waited = 0
        while !whisperRunning(), waited < 200 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
        #expect(whisperRunning(), "whisper never started")
        try await Task.sleep(for: .seconds(2))

        let cancelled = Date()
        run.cancel()
        let result = await run.result
        #expect(Date().timeIntervalSince(cancelled) < 3, "Cancel took too long")
        if case .success = result { Issue.record("a cancelled run finished anyway") }
        #expect(!whisperRunning(), "whisper still running after Cancel")
        #expect(leftovers().subtracting(before).isEmpty, "temporary files left behind")
    }
}

@Suite("whisper word times")
struct WhisperAlignmentTests {
    private func json(_ segments: [(String, Int, Int, [(String, Int)])]) -> Data {
        let items = segments.map { text, from, to, tokens in
            let toks = tokens.map { #"{"text":"\#($0.0)","t_dtw":\#($0.1)}"# }.joined(separator: ",")
            return #"{"text":"\#(text)","offsets":{"from":\#(from),"to":\#(to)},"tokens":[\#(toks)]}"#
        }.joined(separator: ",")
        return Data(#"{"transcription":[\#(items)]}"#.utf8)
    }

    @Test("DTW times replace segment times that piled up at the end of a piece")
    func usesDTW() throws {
        // Real shape: whisper put the last words of a piece all at 20.64 s; DTW had
        // them at 16.40, 16.52 and 16.88 s.
        let data = json([
            (" count", 20640, 20640, [("[_BEG_]", -1), (" count", 1640)]),
            (" kie,", 20640, 20640, [(" k", 1652), ("ie", 1660), (",", 1674)]),
            (" Fitbit", 20640, 20640, [(" Fit", 1690), ("bit", 1702)]),
        ])
        let words = try ExtendedEngineManager.words(fromWhisperJSON: data)
        #expect(words.map(\.text) == ["count", "kie,", "Fitbit"])
        #expect(words.map(\.start) == [16.40, 16.52, 16.90])
        #expect(words[0].end <= words[1].start && words[1].end <= words[2].start)
        #expect(words.allSatisfy { $0.end > $0.start })
    }

    @Test("Without DTW times the segment times are used as before")
    func fallsBackToSegments() throws {
        let data = Data(#"{"transcription":[{"text":" hello","offsets":{"from":100,"to":400}},{"text":" there","offsets":{"from":400,"to":900}}]}"#.utf8)
        let words = try ExtendedEngineManager.words(fromWhisperJSON: data)
        #expect(words.map(\.start) == [0.1, 0.4])
        #expect(words.map(\.end) == [0.4, 0.9])
    }
}

@Suite("Words for languages without spaces")
struct WordGroupingTests {
    @Test("Japanese characters are joined into words, keeping their times")
    func japanese() {
        let chars = Array("このiPhoneのディスプレイはとてもきれいです。").map(String.init)
        // "iPhone" arrives as one token, as the recogniser gives it.
        var tokens: [String] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "i" { tokens.append("iPhone"); i += 6 } else { tokens.append(chars[i]); i += 1 }
        }
        let words = tokens.enumerated().map { k, t in TimedWord(text: t, start: Double(k) * 0.1, end: Double(k) * 0.1 + 0.1) }
        let grouped = WordGrouping.group(words, languageCode: "ja")
        let texts = grouped.map(\.text)
        #expect(texts.joined() == tokens.joined(), "text changed: \(texts)")
        #expect(texts.contains("ディスプレイ"), "katakana word split: \(texts)")
        #expect(grouped.count < words.count)
        #expect(grouped.first?.start == 0)
        #expect(abs((grouped.last?.end ?? 0) - Double(words.count) * 0.1) < 1e-9)
        for (a, b) in zip(grouped, grouped.dropFirst()) { #expect(a.end <= b.start + 1e-9) }
    }

    @Test("Words already whole are left as they are")
    func alreadyWords() {
        let words = ["今日", "は", "晴れ"].enumerated().map { k, t in TimedWord(text: t, start: Double(k), end: Double(k) + 1) }
        #expect(WordGrouping.group(words, languageCode: "ja").map(\.text).joined() == "今日は晴れ")
    }
}

@Suite("Words whisper makes up")
struct InventedWordTests {
    typealias Engine = ExtendedEngineManager

    @Test("Words over silence and sound descriptions are dropped; speech stays")
    func dropsSilenceAndTags() {
        // 0–2 s speech, 2–6 s silence.
        let levels = [Float](repeating: 4000, count: 20) + [Float](repeating: 40, count: 40)
        let words = [
            TimedWord(text: "Hello", start: 0.2, end: 0.6),
            TimedWord(text: "there.", start: 0.7, end: 1.2),
            TimedWord(text: "Thank", start: 4.0, end: 4.3),
            TimedWord(text: "you.", start: 4.3, end: 4.6),
            TimedWord(text: "*music*", start: 1.0, end: 1.5),
        ]
        let kept = Engine.dropInventedWords(words, levels: levels, window: 0.1).map(\.text)
        #expect(kept == ["Hello", "there."])
    }

    @Test("A sound description over several words is dropped, even over loud music")
    func multiWordTag() {
        let levels = [Float](repeating: 6000, count: 50)
        let words = ["[background", "music]", "Hello", "(upbeat", "music", "playing)", "there"].enumerated().map { k, t in
            TimedWord(text: t, start: Double(k) * 0.5, end: Double(k) * 0.5 + 0.4)
        }
        #expect(Engine.dropInventedWords(words, levels: levels, window: 0.1).map(\.text) == ["Hello", "there"])
    }

    @Test("A silent file keeps nothing")
    func silentFile() {
        let levels = [Float](repeating: 20, count: 300)
        let words = [TimedWord(text: "Thank", start: 0.1, end: 0.5), TimedWord(text: "you.", start: 0.5, end: 1.1)]
        #expect(Engine.dropInventedWords(words, levels: levels, window: 0.1).isEmpty)
    }
}

@Suite("whisper output for languages without spaces")
struct UnspacedWhisperTests {
    @Test("Chinese pieces keep their own times instead of joining into one word")
    func chinese() throws {
        let data = Data(#"{"transcription":[{"text":"你好","offsets":{"from":0,"to":1000}},{"text":"世界","offsets":{"from":2000,"to":3000}}]}"#.utf8)
        let words = try ExtendedEngineManager.words(fromWhisperJSON: data, spaced: false)
        #expect(words.map(\.text) == ["你好", "世界"])
        #expect(words.map(\.start) == [0, 2])
    }
}
