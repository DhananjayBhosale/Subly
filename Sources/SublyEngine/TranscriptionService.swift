import Foundation
import Speech
import AVFoundation
import CoreMedia
import SublyCaptions

/// Produces the timing spine. Exactly one pass per generation. PRD ASR-01, ASR-04.
public actor TranscriptionService {

    public enum TranscriptionError: LocalizedError {
        case unsupportedLanguage(String)
        case assetInstallFailed(String, underlying: String)
        case noSpeechFound
        case engineNotInstalled(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let l):
                return "Subly can't listen to \(l) on this Mac yet. Pick another language, or add it in System Settings › General › Language & Region."
            case .assetInstallFailed(let l, let u):
                return "macOS couldn't download the \(l) speech model. \(u)"
            case .noSpeechFound:
                return "Subly couldn't hear any speech in this file. If it has music or silence only, there is nothing to caption."
            case .engineNotInstalled(let name):
                return "\(name) is not installed yet."
            }
        }
    }

    public struct Progress: Sendable {
        public var stage: String
        public var fraction: Double
    }

    /// Set when installing a language forced another out of the reservation pool, so
    /// the UI can say so rather than leaving it unexplained.
    public private(set) var lastEvictedLocale: String?

    public init() {}

    public func poolState() async -> LocaleReservations.PoolState {
        await LocaleReservations.shared.state()
    }

    // MARK: - Locale routing

    /// `supportedLocale(equivalentTo:)` does loose language matching and will return a
    /// locale whose asset does not exist — asking SpeechTranscriber for `hi-IN` yields
    /// `hi-IN` and then fails to install. Membership in `supportedLocales` is the only
    /// trustworthy signal, so routing is done by hand.
    public static func pick(_ supported: [Locale], _ want: Locale) -> Locale? {
        let wantFull = want.identifier(.bcp47).lowercased()
        if let exact = supported.first(where: { $0.identifier(.bcp47).lowercased() == wantFull }) {
            return exact
        }
        guard let wantLang = want.language.languageCode?.identifier.lowercased() else { return nil }
        let sameLang = supported.filter {
            $0.language.languageCode?.identifier.lowercased() == wantLang
        }
        guard !sameLang.isEmpty else { return nil }

        // 1. The region the caller asked for.
        if let region = want.region?.identifier.lowercased(),
           let match = sameLang.first(where: { $0.region?.identifier.lowercased() == region }) {
            return match
        }
        // 2. The region this Mac is actually set to.
        if let userRegion = Locale.current.region?.identifier.lowercased(),
           let match = sameLang.first(where: { $0.region?.identifier.lowercased() == userRegion }) {
            return match
        }
        // 3. The conventional default for the language, so English does not land on
        //    en-ZA purely because of enumeration order.
        let conventional = ["en": "us", "es": "es", "pt": "br", "zh": "cn",
                            "fr": "fr", "de": "de", "it": "it", "ar": "sa", "nl": "nl"]
        if let pref = conventional[wantLang],
           let match = sameLang.first(where: { $0.region?.identifier.lowercased() == pref }) {
            return match
        }
        // 4. Deterministic fallback so repeated runs pick the same locale.
        return sameLang.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }.first
    }

    public struct Route: Sendable {
        public var engine: CapabilityRegistry.Engine
        public var locale: Locale
        public var engineID: String
    }

    // MARK: - Which engine to use

    /// Which engine should transcribe a language.
    ///
    /// This replaced a single boolean ("prefer the extended engine, yes/no"). The
    /// boolean could not express the choice that actually matters: for Hindi there are
    /// *three* usable engines — Apple's, the Hinglish-specialised Apex model, and
    /// general Whisper — and the boolean silently let `pack(for:)` decide between the
    /// last two, so the user could not pick Whisper at all.
    public enum EngineChoice: Hashable, Sendable {
        /// Apple where it covers the language, otherwise the best installed pack.
        case automatic
        case apple
        case pack(String)

        public var isPack: Bool { if case .pack = self { return true } else { return false } }

        public var storageValue: String {
            switch self {
            case .automatic: return "automatic"
            case .apple:     return "apple"
            case .pack(let id): return "pack:" + id
            }
        }

        public init(storageValue: String) {
            if storageValue == "apple" { self = .apple }
            else if storageValue.hasPrefix("pack:") {
                self = .pack(String(storageValue.dropFirst(5)))
            } else { self = .automatic }
        }
    }

    static let engineChoiceKey = "SublyEngineChoiceByLanguage"
    /// Superseded by `engineChoiceKey`; still read once so an existing preference is
    /// not silently dropped when the app updates.
    public static let preferExtendedEngineKey = "SublyPreferExtendedEngine"

    private static func languageCode(_ language: String) -> String {
        language.split(separator: "-").first.map(String.init)?.lowercased() ?? language
    }

    public static func engineChoice(for language: String) -> EngineChoice {
        let code = languageCode(language)
        if let map = UserDefaults.standard.dictionary(forKey: engineChoiceKey) as? [String: String],
           let raw = map[code] {
            return EngineChoice(storageValue: raw)
        }
        // Migrate the old boolean: "prefer extended" meant the language's default pack.
        let legacy = UserDefaults.standard.stringArray(forKey: preferExtendedEngineKey) ?? []
        if legacy.contains(code), let pack = ExtendedEngineManager.shared.pack(for: code) {
            return .pack(pack.id)
        }
        return .automatic
    }

    public static func setEngineChoice(_ choice: EngineChoice, for language: String) {
        let code = languageCode(language)
        var map = (UserDefaults.standard.dictionary(forKey: engineChoiceKey) as? [String: String]) ?? [:]
        map[code] = choice.storageValue
        UserDefaults.standard.set(map, forKey: engineChoiceKey)
    }

    public func route(for language: String) async -> Route? {
        let want = Locale(identifier: language)
        let code = Self.languageCode(language)
        let choice = Self.engineChoice(for: language)

        // An explicit pack choice wins, but only if that pack is actually on disk.
        if case .pack(let id) = choice,
           let pack = ExtendedEngineManager.allPacks.first(where: { $0.id == id }),
           ExtendedEngineManager.shared.isInstalled(pack) {
            return Route(engine: .extendedEngine, locale: want,
                         engineID: "Subly · \(pack.displayName) model")
        }
        let stSupported = await SpeechTranscriber.supportedLocales
        if let loc = Self.pick(stSupported, want) {
            return Route(engine: .speechTranscriber, locale: loc,
                         engineID: "Apple Speech · \(loc.identifier(.bcp47))")
        }
        let dtSupported = await DictationTranscriber.supportedLocales
        if let loc = Self.pick(dtSupported, want) {
            return Route(engine: .dictationTranscriber, locale: loc,
                         engineID: "Apple Dictation · \(loc.identifier(.bcp47))")
        }
        if ExtendedEngineManager.additionalLanguages.contains(code) {
            let pack = ExtendedEngineManager.resolvePack(for: language)
            return Route(engine: .extendedEngine, locale: want,
                         engineID: "Subly · \(pack?.displayName ?? ExtendedEngineManager.generalPack.displayName) model")
        }
        return nil
    }

    // MARK: - Asset installation

    public func assetStatus(for language: String) async -> CapabilityRegistry.AssetState {
        guard let route = await route(for: language) else { return .unavailable }
        guard let module = makeModule(route) else { return .unavailable }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:   return .installed
        case .downloading: return .downloading
        case .supported:   return .downloadable
        case .unsupported: return .unavailable
        @unknown default:  return .unavailable
        }
    }

    /// Download the macOS speech asset for a language.
    ///
    /// NOTE: this is currently invoked from `transcribe`, i.e. by pressing Generate,
    /// with no separate confirmation dialog. PRD ASR-08 asks for an explicit
    /// confirmation step; the UI shows the size and a "Get it now" affordance
    /// beforehand, but does not gate Generate. Tracked as a known gap.
    public func installAssets(for language: String,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let route = await route(for: language), let module = makeModule(route) else {
            throw TranscriptionError.unsupportedLanguage(language)
        }
        // Reserve before installing. Without this, the fifth language succeeds and
        // the sixth fails with "Too many allocated locales".
        var evicted: String?
        do {
            evicted = try await LocaleReservations.shared.ensureReserved(route.locale)
        } catch {
            throw TranscriptionError.assetInstallFailed(
                CapabilityRegistry.displayName(language), underlying: error.localizedDescription)
        }
        lastEvictedLocale = evicted

        let status = await AssetInventory.status(forModules: [module])
        guard status != .installed else { return }
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                return
            }
            let observation = request.progress.observe(\.fractionCompleted) { p, _ in
                progress?(p.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            progress?(1.0)
        } catch {
            throw TranscriptionError.assetInstallFailed(
                CapabilityRegistry.displayName(language), underlying: error.localizedDescription)
        }
    }

    private func makeModule(_ route: Route) -> (any SpeechModule)? {
        switch route.engine {
        case .speechTranscriber:
            // The stock preset carries .audioTimeRange but NOT
            // .transcriptionConfidence, which left every confidence nil and made
            // low-confidence review flagging (ASR-10) dead code.
            let preset = SpeechTranscriber.Preset.timeIndexedTranscriptionWithAlternatives
            return SpeechTranscriber(
                locale: route.locale,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions,
                attributeOptions: preset.attributeOptions.union([.audioTimeRange,
                                                                 .transcriptionConfidence]))
        case .dictationTranscriber:
            // .shortForm is a short-phrase hint and roughly halves throughput on
            // arbitrary-length media while returning one result at EOF. The
            // long-dictation preset streams results and is what media needs.
            let preset = DictationTranscriber.Preset.timeIndexedLongDictation
            return DictationTranscriber(
                locale: route.locale,
                contentHints: preset.contentHints,
                transcriptionOptions: preset.transcriptionOptions.union([.punctuation]),
                reportingOptions: preset.reportingOptions,
                attributeOptions: preset.attributeOptions.union([.audioTimeRange,
                                                                 .transcriptionConfidence]))
        case .extendedEngine:
            return nil
        }
    }

    // MARK: - Transcription

    /// Names, brands and uncommon words, tidied for a recogniser: trimmed, one line
    /// each, blanks and repeats (ignoring case) dropped, first mention kept in order.
    static func vocabularyTerms(_ vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        return vocabulary.compactMap { raw in
            let term = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    /// - Parameter vocabulary: names, brands and uncommon words likely to be said, so
    ///   the recogniser spells them the way the person expects. Empty means no hint.
    public func transcribe(audioURL: URL,
                           language: String,
                           vocabulary: [String] = [],
                           progress: (@Sendable (Progress) -> Void)? = nil) async throws -> TimingSpine {
        guard let route = await route(for: language) else {
            throw TranscriptionError.unsupportedLanguage(CapabilityRegistry.displayName(language))
        }
        if route.engine == .extendedEngine {
            guard ExtendedEngineManager.shared.isInstalled else {
                throw TranscriptionError.engineNotInstalled("the extra-language model")
            }
            let outcome = try await ExtendedEngineManager.shared.transcribe(
                audioURL: audioURL, language: language, vocabulary: vocabulary, progress: progress)
            return outcome.spine
        }

        progress?(Progress(stage: "Preparing the \(CapabilityRegistry.displayName(language)) model", fraction: 0.02))
        try await installAssets(for: language) { f in
            progress?(Progress(stage: "Downloading language model", fraction: 0.02 + f * 0.25))
        }

        guard let module = makeModule(route) else {
            throw TranscriptionError.unsupportedLanguage(language)
        }

        progress?(Progress(stage: "Listening to the audio", fraction: 0.3))

        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate

        // Collect results concurrently with analysis; the analyzer finishes at EOF.
        // Report how far through the audio recognition has got, so the bar moves
        // during the longest step instead of sitting on "Listening" until it ends.
        let name = CapabilityRegistry.displayName(language)
        let report: @Sendable (CMTimeRange) -> Void = { range in
            guard duration > 0 else { return }
            let heard = min(duration, range.end.seconds.isFinite ? range.end.seconds : 0)
            progress?(Progress(stage: "Listening (\(name)) — \(ExtendedEngineManager.clock(heard)) of \(ExtendedEngineManager.clock(duration))",
                               fraction: 0.3 + 0.25 * heard / duration))
        }
        let collector = Task { () -> [TimedWord] in
            var words: [TimedWord] = []
            if let st = module as? SpeechTranscriber {
                for try await result in st.results {
                    words.append(contentsOf: Self.words(from: result.text, fallback: result.range))
                    report(result.range)
                }
            } else if let dt = module as? DictationTranscriber {
                for try await result in dt.results {
                    words.append(contentsOf: Self.words(from: result.text, fallback: result.range))
                    report(result.range)
                }
            }
            return words
        }

        // Give the recogniser audio in the format it asks for. Handing it audio it did
        // not ask for is the likeliest cause of a timeline that came back at exactly
        // half speed (Hindi dictation ended every caption by 0:29 of a 0:58 video).
        var analysed = file
        var convertedURL: URL?
        defer { if let convertedURL { try? FileManager.default.removeItem(at: convertedURL) } }
        if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module],
                                                                    considering: file.processingFormat),
           best.sampleRate != file.processingFormat.sampleRate
            || best.channelCount != file.processingFormat.channelCount
            || best.commonFormat != file.processingFormat.commonFormat {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("subly-speech-\(UUID().uuidString).caf")
            if let converted = try? Self.convert(file, to: best, at: url) {
                analysed = converted
                convertedURL = url
            }
        }

        // The vocabulary goes in as contextual strings, Apple's way of biasing
        // recognition towards expected words. Handed over at creation: this
        // initialiser starts analysing at once, so a context set afterwards could miss
        // the opening words. SpeechTranscriber accepts them but made no visible
        // difference on the clips it was tried with; whisper's prompt is what fixes
        // brand names today.
        let context = AnalysisContext()
        let terms = Self.vocabularyTerms(vocabulary)
        if !terms.isEmpty { context.contextualStrings[.general] = terms }

        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(inputAudioFile: analysed,
                                                modules: [module],
                                                analysisContext: context,
                                                finishAfterFile: true)
        } catch {
            // Without this the collector sits forever on a results stream that will
            // never finish, holding the engine open.
            collector.cancel()
            throw error
        }
        // Cancel reaches the recogniser. Waiting on the collector, a separate task,
        // let a cancelled run carry on to the end of the file and then start a
        // translation that ended someone else's.
        var words: [TimedWord]
        do {
            words = try await withTaskCancellationHandler {
                try await collector.value
            } onCancel: {
                collector.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }
        try Task.checkCancellation()

        progress?(Progress(stage: "Building the timing spine", fraction: 0.55))

        // Before the length cap in the repair: capped first, a word heard at 5–5.5 s but
        // timed from 0 became 0–2.5 s, all of it before the speech.
        if let (levels, _) = Self.loudness(audioURL) {
            words = Self.trimLeadingSilence(words, levels: levels)
        }
        words = Self.repairTimings(words, duration: duration)
        guard !words.isEmpty else { throw TranscriptionError.noSpeechFound }

        // A squeezed timeline is repaired; a short one is reported.
        let speechEnd = Self.lastSpeechTime(audioURL) ?? duration
        // Not for languages without spaces: their tokens are characters, six a second
        // is normal, and correct Japanese timings followed by music were doubled.
        let wordBased = ScriptProfile.forLanguage(language).segmentation != .characterBased
        let corrected = wordBased
            ? Self.correctCompressedTimeline(words, speechEnd: speechEnd, duration: duration)
            : (words: words, scaled: false)
        words = corrected.words
        var warning: String?
        if let last = words.last?.end, speechEnd > 8, last < 0.7 * speechEnd {
            warning = "Subly only heard speech up to \(ExtendedEngineManager.clock(last)) of \(ExtendedEngineManager.clock(speechEnd)). The rest of the video may have no captions — try Whisper under Speech model, then Listen Again."
        }

        var spine = TimingSpine(words: words,
                           sourceLanguage: route.locale.identifier(.bcp47),
                           duration: duration,
                           engineID: route.engineID)
        spine.warning = warning
        return spine
    }

    // MARK: - Timeline sanity

    /// Undo a timeline the recogniser squeezed. Observed with Apple's Hindi dictation:
    /// every word at exactly half its real time, so captions ran at double speed and
    /// stopped half-way through the video while the person kept talking. When the words
    /// end around half-way but the sound clearly continues, and the gap matches a
    /// whole-timeline scale (1.6–2.4×), stretch the words to fit the speech.
    public static func correctCompressedTimeline(_ words: [TimedWord], speechEnd: Double,
                                                 duration: Double) -> (words: [TimedWord], scaled: Bool) {
        guard let last = words.last?.end, last > 1, speechEnd > 0 else { return (words, false) }
        let ratio = speechEnd / last
        guard ratio >= 1.6, ratio <= 2.4, last < 0.65 * speechEnd else { return (words, false) }
        // And only when the words come impossibly fast. A Reel that stops talking half-way
        // and ends on music has the same shape, and its correct captions were stretched to
        // twice their real time. Squeezed speech runs at 5+ words a second; real speech,
        // even fast Hinglish, at about 2.5–4.
        let wordsPerSecond = Double(words.count) / last
        guard wordsPerSecond >= 5.0 else { return (words, false) }
        let scaled = words.map { w -> TimedWord in
            var w = w
            w.start = min(duration, w.start * ratio)
            w.end = min(duration, w.end * ratio)
            return w
        }
        return (scaled, true)
    }

    /// Loudness (RMS) of each 100 ms of a float audio file, and its length.
    static func loudness(_ url: URL) -> (levels: [Float], seconds: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * 0.1))
        else { return nil }
        let rate = file.processingFormat.sampleRate
        var levels: [Float] = []
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
                  let data = buffer.floatChannelData?[0] else { break }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            levels.append((sum / Float(buffer.frameLength)).squareRoot())
        }
        return (levels, Double(file.length) / rate)
    }

    /// When the last real sound in the file is, from 100 ms loudness. Nil if unreadable.
    static func lastSpeechTime(_ url: URL) -> Double? {
        guard let (levels, seconds) = loudness(url), let peak = levels.max(), peak > 0 else { return nil }
        // "Sound" is anything above a tenth of the loudest moment; room noise is far below.
        guard let lastLoud = levels.lastIndex(where: { $0 > peak * 0.1 }) else { return nil }
        return min(seconds, Double(lastLoud + 1) * 0.1)
    }

    /// Apple's recogniser starts the first word after a pause when the pause starts,
    /// not when the speaking does: a Spanish "Hola" said at 5.6 s was timed from 3.8 s,
    /// so its caption showed almost two seconds early. A long word is started where
    /// its sound begins.
    static func trimLeadingSilence(_ words: [TimedWord], levels: [Float], window: Double = 0.1) -> [TimedWord] {
        guard let peak = levels.max(), peak > 0 else { return words }
        let loud = peak * 0.1
        var out = words
        for i in out.indices where out[i].end - out[i].start > 0.5 {
            var k = max(0, Int(out[i].start / window))
            while k < levels.count, Double(k) * window < out[i].end - 0.15, levels[k] < loud { k += 1 }
            let speechStart = Double(k) * window
            if speechStart - out[i].start > 0.25 {
                out[i].start = min(out[i].end - 0.1, speechStart)
            }
        }
        return out
    }

    /// Convert an audio file to `format` for the recogniser.
    static func convert(_ file: AVAudioFile, to format: AVAudioFormat, at url: URL) throws -> AVAudioFile {
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw TranscriptionError.unsupportedLanguage("audio format")
        }
        let out = try AVAudioFile(forWriting: url, settings: format.settings,
                                  commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let inCapacity: AVAudioFrameCount = 16_384
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(Double(inCapacity) * format.sampleRate
                                                                             / file.processingFormat.sampleRate) + 1024)
        else { throw TranscriptionError.unsupportedLanguage("audio format") }
        file.framePosition = 0
        var finished = false
        while !finished {
            var error: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                do {
                    try file.read(into: input)
                } catch {
                    outStatus.pointee = .endOfStream; return nil
                }
                if input.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if output.frameLength > 0 { try out.write(from: output) }
            finished = status == .endOfStream || status == .error
        }
        return try AVAudioFile(forReading: url)
    }

    // MARK: - Attributed string harvesting

    /// Each attributed run carries `audioTimeRange` and `transcriptionConfidence` when
    /// a time-indexed preset is used.
    static func words(from attributed: AttributedString, fallback: CMTimeRange) -> [TimedWord] {
        var out: [TimedWord] = []
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let confidence = run.transcriptionConfidence.map { Double($0) }

            let start = (run.audioTimeRange?.start.isNumeric == true)
                ? run.audioTimeRange!.start.seconds : -1
            let end = (run.audioTimeRange?.end.isNumeric == true)
                ? run.audioTimeRange!.end.seconds : -1

            // Punctuation attaches to the word before it. On real footage the
            // recogniser emits standalone punctuation runs with long time ranges,
            // which produced cues containing nothing but a comma — held on screen
            // for up to 14 seconds.
            let isPunctuationOnly = trimmed.allSatisfy { !$0.isLetter && !$0.isNumber }
            if isPunctuationOnly {
                // Attach to the word before it, or drop it. `words(from:)` is called
                // once per recogniser result, so a result that *opens* with
                // punctuation has nothing to attach to — that is how cues containing
                // nothing but `,,,,,,` were reaching the screen.
                if !out.isEmpty {
                    out[out.count - 1].text += trimmed
                    if end >= 0 { out[out.count - 1].end = max(out[out.count - 1].end, end) }
                }
                continue
            }
            out.append(TimedWord(text: trimmed, start: start, end: end, confidence: confidence))
        }
        return out
    }

    /// No single spoken word lasts this long. A longer reported range is a recogniser
    /// artefact — usually an isolated token during silence or music — and using it
    /// verbatim leaves a caption on screen for many seconds.
    public static let maxPlausibleWordDuration: Double = 2.5

    /// Fill any gaps left by runs that carried no time range, and guarantee a
    /// monotonically increasing, non-overlapping sequence.
    public static func repairTimings(_ input: [TimedWord], duration: Double) -> [TimedWord] {
        guard !input.isEmpty else { return [] }

        // Spine-level sweep: fold any punctuation-only token into the previous word,
        // or discard it. Results are harvested independently, so one can still open
        // with punctuation even after the per-result pass.
        var words: [TimedWord] = []
        words.reserveCapacity(input.count)
        for word in input {
            let isPunctuationOnly = !word.text.isEmpty
                && word.text.allSatisfy { !$0.isLetter && !$0.isNumber }
            if isPunctuationOnly {
                if !words.isEmpty {
                    words[words.count - 1].text += word.text
                    if word.end >= 0 {
                        words[words.count - 1].end = max(words[words.count - 1].end, word.end)
                    }
                }
                continue
            }
            words.append(word)
        }
        guard !words.isEmpty else { return [] }

        // Interpolate untimed runs between their nearest timed neighbours.
        var i = 0
        while i < words.count {
            guard words[i].start < 0 else { i += 1; continue }
            let prevEnd = (i > 0) ? words[i - 1].end : 0
            var j = i
            while j < words.count, words[j].start < 0 { j += 1 }
            let nextStart = (j < words.count) ? words[j].start : max(prevEnd, duration)
            let span = max(0.0001, nextStart - prevEnd)
            let n = j - i
            for k in 0..<n {
                words[i + k].start = prevEnd + span * Double(k) / Double(n)
                words[i + k].end   = prevEnd + span * Double(k + 1) / Double(n)
            }
            i = j
        }

        // Some engines collapse trailing tokens onto one timestamp (whisper.cpp does
        // this at the tail of a clip). Spread any run of identical timings across the
        // gap to the next distinct timestamp so the cues do not flash.
        var i2 = 0
        while i2 < words.count {
            var j = i2 + 1
            while j < words.count,
                  abs(words[j].start - words[i2].start) < 1e-6,
                  abs(words[j].end - words[i2].end) < 1e-6 { j += 1 }
            let runLength = j - i2
            if runLength > 1 {
                let spanStart = words[i2].start
                let spanEnd = (j < words.count)
                    ? max(spanStart, words[j].start)
                    : max(words[i2].end, min(duration, spanStart + Double(runLength) * 0.3))
                let step = (spanEnd - spanStart) / Double(runLength)
                if step > 0 {
                    for k in 0..<runLength {
                        words[i2 + k].start = spanStart + step * Double(k)
                        words[i2 + k].end = spanStart + step * Double(k + 1)
                    }
                }
            }
            i2 = j
        }

        // Clamp implausible word durations before they become cue durations.
        for i in words.indices where words[i].end - words[i].start > maxPlausibleWordDuration {
            // Keep the start (that is when speech began) and trim the tail.
            words[i].end = words[i].start + maxPlausibleWordDuration
        }

        // Enforce monotonic, non-negative, non-overlapping timings.
        for i in words.indices {
            if words[i].end < words[i].start { words[i].end = words[i].start }
            if i > 0, words[i].start < words[i - 1].end {
                words[i].start = words[i - 1].end
                if words[i].end < words[i].start { words[i].end = words[i].start }
            }
            words[i].start = max(0, min(words[i].start, duration))
            words[i].end = max(words[i].start, min(words[i].end, duration))
        }
        return spreadCollapsedEnding(words, duration: duration)
    }

    /// whisper.cpp often stamps the last words of a clip at, or past, the end of the
    /// audio; after clamping they all sit at one instant with no time of their own. A
    /// real clip put its last 14 words into one 0.7-second caption this way. Spread
    /// them, and as many words before them as needed, back over the closing seconds at
    /// a speaking pace.
    static func spreadCollapsedEnding(_ input: [TimedWord], duration: Double) -> [TimedWord] {
        var words = input
        var tail = words.count
        // "No time of their own" means under 20 ms, not exactly zero: the last word of
        // a real clip ended 1 ms later (at the true end of the audio), and the exact
        // test then skipped the whole collapsed run.
        while tail > 0, words[tail - 1].end - words[tail - 1].start < 0.02 { tail -= 1 }
        guard words.count - tail >= 3 else { return words }

        let pace = 0.3
        let end = min(duration, max(words[words.count - 1].end, words[tail].start))
        var p = tail
        // Borrow time from at most as many words as collapsed. Unbounded, fast speech
        // (Hinglish runs about 0.25 s a word, under the 0.3 s pace) walked back to the
        // first word and spread every word of a 68-second clip evenly across it.
        let earliest = max(0, tail - (words.count - tail))
        while p > earliest, end - words[p - 1].start < Double(words.count - p + 1) * pace { p -= 1 }
        let windowStart = end - Double(words.count - p) * pace
        let start = max(0, windowStart, p > 0 ? words[p - 1].end : 0)
        let share = (end - start) / Double(words.count - p)
        guard share > 0 else { return words }
        for k in 0..<(words.count - p) {
            words[p + k].start = start + share * Double(k)
            words[p + k].end = start + share * Double(k + 1)
        }
        return words
    }
}
