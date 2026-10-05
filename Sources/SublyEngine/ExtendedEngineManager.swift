import Foundation
import CryptoKit
import AVFoundation
import SublyCaptions

/// The optional downloadable engine for languages Apple's frameworks do not cover,
/// and for Hindi/Hinglish where a specialised model beats the generic path.
///
/// Never bundled, never auto-downloaded, and never required for an Apple-covered
/// language.5 (EXT-01…EXT-09).
public final class ExtendedEngineManager: @unchecked Sendable {

    public static let shared = ExtendedEngineManager()

    // MARK: - Model packs

    public struct ModelPack: Sendable, Codable, Hashable, Identifiable {
        public var id: String
        public var displayName: String
        /// The model's real identity, shown under the picker. Users comparing engines
        /// need to know exactly which weights are running.
        public var modelIdentity: String {
            switch id {
            case "whisper-large-v3-turbo-q5":  return "ggerganov/whisper.cpp · large-v3-turbo · q5_0"
            case "whisper-large-v3-q5":        return "ggerganov/whisper.cpp · large-v3 · q5_0"
            case "whisper-medium-q5":          return "ggerganov/whisper.cpp · medium · q5_0"
            case "whisper-small-q5":           return "ggerganov/whisper.cpp · small · q5_1"
            case "whisper-base-q5":            return "ggerganov/whisper.cpp · base · q5_1"
            case "hindi2hinglish-apex-q5":     return "Marquestra/Whisper-Hindi2Hinglish-Apex · q5_0"
            default:                            return id
            }
        }
        public var detail: String
        public var filename: String
        public var downloadBytes: Int64
        public var sha256: String
        public var url: URL
        /// whisper.cpp alignment-head preset for word-level timestamps.
        public var dtwPreset: String
        /// True when the model emits Roman script directly from audio, so its output
        /// IS the romanized track and there is no native-script transcript from it.
        public var emitsRomanized: Bool
        public var languages: [String]

        /// Roughly what this needs free while running, over and above the file itself.
        /// Whisper holds the weights plus activations, so plan for about 1.6x the
        /// download for the larger models.
        public var approximateRAMBytes: Int64
        /// Relative transcription speed, 1 being the slowest shipped model. Used to
        /// tell someone what they are trading away, not as a benchmark.
        public var relativeSpeed: Double
        /// Nil for a general model. Set when the model is trained for specific
        /// languages and should be recommended for them.
        public var specialisedFor: [String]?

        public var isGeneral: Bool { specialisedFor == nil }

        /// What the model is for, in words a non-technical person can act on. Shown on
        /// screen, not in a tooltip: the names alone ("Whisper Medium") say nothing
        /// about which one to pick.
        public var bestFor: String {
            switch id {
            case "hindi2hinglish-apex-q5":    return "Hindi only. Writes Hindi in English letters (Hinglish)."
            case "whisper-large-v3-turbo-q5": return "Any language. The best balance of speed and accuracy."
            case "whisper-large-v3-q5":       return "Any language. The most accurate, and much slower."
            case "whisper-medium-q5":         return "Any language. Smaller, for older Macs."
            case "whisper-small-q5":          return "Any language. For Macs short on space. Less accurate."
            case "whisper-base-q5":           return "Any language. Tiny, but makes frequent mistakes."
            default:                          return detail
            }
        }

        /// "574 MB download · uses about 1.1 GB of memory"
        public var costLine: String {
            let memory = ByteCountFormatter.string(fromByteCount: approximateRAMBytes, countStyle: .file)
            return "\(formattedSize) download · uses about \(memory) of memory"
        }

        public var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
        }
    }

    private static func hfURL(_ file: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + file)!
    }

    /// General multilingual pack and the recommended default. Covers ~99 languages.
    public static let generalPack = ModelPack(
        id: "whisper-large-v3-turbo-q5",
        displayName: "Whisper",
        detail: "OpenAI Whisper large-v3-turbo. Handles about 99 languages, including the ones Apple's engines don't cover.",
        filename: "ggml-large-v3-turbo-q5_0.bin",
        downloadBytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        url: hfURL("ggml-large-v3-turbo-q5_0.bin"),
        dtwPreset: "large.v3.turbo",
        emitsRomanized: false,
        languages: Array(additionalLanguages).sorted(),
        approximateRAMBytes: 1_100_000_000,
        relativeSpeed: 6)

    /// Most accurate general model. 32 decoder layers against turbo's 4, so it is
    /// markedly slower — worth it only when accuracy matters more than waiting.
    public static let largeV3Pack = ModelPack(
        id: "whisper-large-v3-q5",
        displayName: "Whisper Large",
        detail: "Whisper large-v3, the full model. The most accurate option and the slowest by a wide margin.",
        filename: "ggml-large-v3-q5_0.bin",
        downloadBytes: 1_081_140_203,
        sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
        url: hfURL("ggml-large-v3-q5_0.bin"),
        dtwPreset: "large.v3",
        emitsRomanized: false,
        languages: Array(additionalLanguages).sorted(),
        approximateRAMBytes: 1_900_000_000,
        relativeSpeed: 1)

    /// Middle of the road: noticeably better than Small, a little smaller than turbo.
    public static let mediumPack = ModelPack(
        id: "whisper-medium-q5",
        displayName: "Whisper Medium",
        detail: "Good accuracy with a little less disk and memory than the default. A sensible choice on an older Mac.",
        filename: "ggml-medium-q5_0.bin",
        downloadBytes: 539_212_467,
        sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
        url: hfURL("ggml-medium-q5_0.bin"),
        dtwPreset: "medium",
        emitsRomanized: false,
        languages: Array(additionalLanguages).sorted(),
        approximateRAMBytes: 900_000_000,
        relativeSpeed: 3)

    /// For a Mac short of disk or memory. Accuracy drops, most visibly on accented
    /// speech and code-switching, which is exactly where this app is often used.
    public static let smallPack = ModelPack(
        id: "whisper-small-q5",
        displayName: "Whisper Small",
        detail: "A third of the size of the default. Faster and lighter, and noticeably less accurate on accented or mixed-language speech.",
        filename: "ggml-small-q5_1.bin",
        downloadBytes: 190_085_487,
        sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
        url: hfURL("ggml-small-q5_1.bin"),
        dtwPreset: "small",
        emitsRomanized: false,
        languages: Array(additionalLanguages).sorted(),
        approximateRAMBytes: 400_000_000,
        relativeSpeed: 12)

    /// The smallest usable option. Offered for machines that cannot host anything
    /// bigger; it is not recommended for real caption work.
    public static let basePack = ModelPack(
        id: "whisper-base-q5",
        displayName: "Whisper Base",
        detail: "Tiny and quick. Use it only if disk or memory is genuinely tight — it makes frequent mistakes on real-world audio.",
        filename: "ggml-base-q5_1.bin",
        downloadBytes: 59_707_625,
        sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
        url: hfURL("ggml-base-q5_1.bin"),
        dtwPreset: "base",
        emitsRomanized: false,
        languages: Array(additionalLanguages).sorted(),
        approximateRAMBytes: 200_000_000,
        relativeSpeed: 24)

    /// Hindi/Hinglish pack. Writes Hinglish straight from audio, which is materially
    /// better than transcribing to Devanagari and transliterating afterwards.
    public static let hinglishPack = ModelPack(
        id: "hindi2hinglish-apex-q5",
        displayName: "Apex",
        detail: "Whisper-Hindi2Hinglish-Apex, fine-tuned for Hindi. Writes Hinglish straight from speech, keeping English words in English.",
        filename: "ggml-apex-hinglish-q5_0.bin",
        downloadBytes: 574_041_195,
        sha256: "9d877151b15cec1feb9110cfbc0a3162cf377bcc0ab1935174226f461cf60f13",
        url: URL(string: "https://huggingface.co/Marquestra/Whisper-Hindi2Hinglish-Apex-GGML/resolve/main/ggml-apex-hinglish-q5_0.bin")!,
        dtwPreset: "large.v3.turbo",
        emitsRomanized: true,
        languages: ["hi"],
        approximateRAMBytes: 1_100_000_000,
        relativeSpeed: 6,
        specialisedFor: ["hi"])

    /// Everything on offer, best first. Order is the order the picker shows.
    public static let allPacks: [ModelPack] = [
        hinglishPack, generalPack, largeV3Pack, mediumPack, smallPack, basePack
    ]

    /// The model to suggest for a language, and why.
    ///
    /// Deliberately short. A specialised model is only recommended where there is
    /// measured evidence it beats the general one — today that is Hindi and Apex.
    /// Inventing a per-language favourite without having tested it would be worse
    /// than saying nothing.
    public static func recommended(for languageCode: String)
        -> (pack: ModelPack, reason: String) {
        if let special = allPacks.first(where: { $0.specialisedFor?.contains(languageCode) == true }) {
            return (special, "Trained for this language and measurably better than the general model.")
        }
        return (generalPack, "Handles about 99 languages and is the best general choice.")
    }

    /// Languages the Apple stack cannot transcribe on any Mac.
    public static let additionalLanguages: Set<String> = [
        "mr", "as",                                                       // South Asia
        "bn", "gu", "pa", "ta", "te", "kn", "ml", "ur", "ne", "si",
        "fil", "my", "km", "jv", "su",                                    // Southeast Asia
        "fa", "sw", "am", "ha", "yo", "af", "az", "hy", "ka", "uz",       // ME / Africa / C. Asia
        "sq", "is", "mt", "cy", "gl", "eu", "lt", "lv", "et", "sl",       // Europe long tail
    ]

    // MARK: - State

    public enum InstallState: Equatable, Sendable {
        case notInstalled
        case downloading(fraction: Double)
        case verifying
        case installed(bytes: Int64)
        case failed(String)
    }

    public enum EngineError: LocalizedError {
        case notInstalled(String)
        case checksumMismatch(String)
        case insufficientSpace(needed: Int64, available: Int64)
        case downloadFailed(String)
        case runtimeMissing
        case transcriptionFailed(String)
        case noSpeechFound

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let pack):
                return "The “\(pack)” model isn't installed yet."
            case .checksumMismatch(let pack):
                return "The “\(pack)” download failed its integrity check and was discarded."
            case .insufficientSpace(let needed, let available):
                let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let a = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "Not enough disk space. \(n) is needed and \(a) is free."
            case .downloadFailed(let m):
                return "The download stopped before it finished. Check your internet connection and try again. (\(m))"
            case .runtimeMissing:
                return "The extra-language engine is missing from the app bundle. Reinstall Subly."
            case .transcriptionFailed(let m):
                return "The speech model couldn't process this audio. Try again, or choose Apple (built in) under Speech recognition. (\(m))"
            case .noSpeechFound:
                return "No speech was found. Check that the video has someone talking and the sound is not muted."
            }
        }
    }

    // MARK: - Paths

    public var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Subly/Engines", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    /// The bundled whisper.cpp runtime. Ships inside the app — no Homebrew, no Python,
    /// nothing for the user to install (EXT-05). Falls back to a development checkout
    /// so the CLI harness works before the bundle is assembled.
    public var runtimeURL: URL? {
        // Contents/Helpers, where signed helper tools belong; Resources/engine for a
        // bundle assembled by an older script.
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-cli")
        if FileManager.default.isExecutableFile(atPath: helpers.path) { return helpers }
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil,
                                          subdirectory: "engine"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        #if DEBUG
        // Development fallback: the statically linked build in the source tree, so the
        // CLI harness works before the .app is assembled. Deliberately NOT a Homebrew
        // path — depending on the user's Homebrew would break EXT-05's promise that
        // the engine needs nothing installed. Debug only, so release builds don't
        // carry the developer's folder names.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SublyEngine
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Resources/engine/whisper-cli")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
        #else
        return nil
        #endif
    }

    public func modelURL(_ pack: ModelPack) -> URL {
        supportDirectory.appendingPathComponent(pack.filename)
    }

    // MARK: - Install state

    public func isInstalled(_ pack: ModelPack) -> Bool {
        let url = modelURL(pack)
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 else { return false }
        // Guard against a truncated download being treated as installed.
        return size == pack.downloadBytes
    }

    public var isInstalled: Bool { Self.allPacks.contains { isInstalled($0) } }

    public func state(_ pack: ModelPack) -> InstallState {
        isInstalled(pack) ? .installed(bytes: pack.downloadBytes) : .notInstalled
    }

    public var installedPacks: [ModelPack] { Self.allPacks.filter { isInstalled($0) } }

    public var installedBytes: Int64 { installedPacks.reduce(0) { $0 + $1.downloadBytes } }

    /// Best pack for a language. The Hinglish pack wins for Hindi.
    /// The pack that should actually run: the user's choice when they made one and it
    /// is installed, otherwise the best available for the language.
    static func resolvePack(for language: String) -> ModelPack? {
        if case .pack(let id) = TranscriptionService.engineChoice(for: language),
           let chosen = allPacks.first(where: { $0.id == id }),
           shared.isInstalled(chosen) {
            return chosen
        }
        return shared.pack(for: language)
    }

    public func pack(for language: String) -> ModelPack? {
        let code = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language
        // A model trained for this language wins if it is here.
        if let special = Self.allPacks.first(where: {
            $0.specialisedFor?.contains(code) == true && isInstalled($0)
        }) { return special }
        // Otherwise the best installed general model, in catalogue order.
        if let best = Self.allPacks.first(where: { $0.isGeneral && isInstalled($0) }) {
            return best
        }
        if code == "hi" { return Self.hinglishPack }
        return Self.generalPack
    }

    /// Delete a pack. Existing tracks stay readable and editable; only regeneration
    /// needs a reinstall.
    public func delete(_ pack: ModelPack) throws {
        let url = modelURL(pack)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // A half-finished download goes too; it is hundreds of megabytes nobody can see.
        try? FileManager.default.removeItem(at: url.appendingPathExtension("part"))
    }

    // MARK: - Disk space

    public func availableSpace() -> Int64 {
        let values = try? supportDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: - Download

    /// Resumable, checksum-verified, cancellable.
    public func install(_ pack: ModelPack,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if isInstalled(pack) { return }

        let destination = modelURL(pack)
        let partial = destination.appendingPathExtension("part")
        let partialSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0

        // Room for what is still to come, not the whole model: a finished download
        // needs only a rename, and was refused with 250 MB free.
        let available = availableSpace()
        let remaining = max(0, pack.downloadBytes - partialSize)
        guard partialSize >= pack.downloadBytes || available > remaining + 200_000_000 else {
            throw EngineError.insufficientSpace(needed: remaining, available: available)
        }
        // A partial file that is already whole — the app quit while checking it, or a
        // cancel landed after the last byte — only needs checking. Asking the server
        // for the bytes after its end got a 416, every time, and the model could never
        // be downloaded again.
        if partialSize >= pack.downloadBytes {
            try await verifyAndInstall(partial, as: destination, pack: pack, progress: progress)
            return
        }

        var request = URLRequest(url: pack.url)
        var existing: Int64 = 0
        if partialSize > 0 {
            existing = partialSize
            request.setValue("bytes=\(partialSize)-", forHTTPHeaderField: "Range")
        }

        var (stream, response) = try await URLSession.shared.bytes(for: request)
        if existing > 0, (response as? HTTPURLResponse)?.statusCode == 416 {
            // The server says the range is no good: start again from nothing.
            try? FileManager.default.removeItem(at: partial)
            existing = 0
            (stream, response) = try await URLSession.shared.bytes(for: URLRequest(url: pack.url))
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EngineError.downloadFailed("Server returned status \(code).")
        }
        // A 200 to a ranged request means the server ignored it; start over.
        if existing > 0, http.statusCode == 200 {
            try? FileManager.default.removeItem(at: partial)
            existing = 0
        }

        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        defer { try? handle.close() }

        var written = existing
        var buffer = Data(capacity: 1 << 20)
        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(min(1, Double(written) / Double(pack.downloadBytes)))
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()

        try await verifyAndInstall(partial, as: destination, pack: pack, progress: progress)
    }

    /// Check a downloaded file and move it into place. A mismatch deletes it, so the
    /// next try starts clean.
    private func verifyAndInstall(_ partial: URL, as destination: URL, pack: ModelPack,
                                  progress: (@Sendable (Double) -> Void)?) async throws {
        progress?(1.0)
        // Verify before promoting the file into place. Checked for cancellation first:
        // a cancelled download used to be verified and installed anyway.
        try Task.checkCancellation()
        let digest = try Self.sha256(of: partial)
        try Task.checkCancellation()
        guard digest == pack.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw EngineError.checksumMismatch(pack.displayName)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Transcription

    public struct Outcome: Sendable {
        public var spine: TimingSpine
        /// True when the text is already Roman script, so the romanized track needs
        /// no transliteration and a native-script transcript is NOT available.
        public var isRomanized: Bool
    }

    public func transcribe(audioURL: URL,
                           language: String,
                           vocabulary: [String] = [],
                           progress: (@Sendable (TranscriptionService.Progress) -> Void)? = nil
    ) async throws -> Outcome {
        // Honour the user's explicit engine choice. `pack(for:)` picks the *best* pack
        // for a language, which for Hindi is always the Hinglish one — so choosing
        // Whisper in the picker routed correctly but then transcribed with Apex anyway,
        // and failed with Apex's "can't write native script" message.
        guard let pack = Self.resolvePack(for: language) else {
            throw EngineError.notInstalled("the extra-language model")
        }
        guard isInstalled(pack) else { throw EngineError.notInstalled(pack.displayName) }
        guard let runtime = runtimeURL else { throw EngineError.runtimeMissing }

        let code = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language

        // Every temporary file of this run — the converted audio, its pieces and
        // whisper's transcripts — lives in one folder, removed on success, failure and
        // cancel alike. A failed or killed run used to leave its files behind.
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("subly-ext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        // whisper.cpp reads 16-bit PCM WAV only. The pipeline extracts Float32 CAF
        // for the Apple recognisers, so convert here rather than degrade that path.
        let wavURL = workDirectory.appendingPathComponent("audio.wav")
        let audioSeconds: Double
        let pieces: [AudioPiece]
        let inputs: [URL]
        let levels: [Float]
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try Self.writeWAV16(from: audioURL, to: wavURL)
            audioSeconds = Self.wavDuration(wavURL)
            // Long audio goes to whisper in pieces of at most 28 seconds, cut where it
            // is quiet. whisper decodes in 30-second windows, and where one window
            // hands over to the next on long audio it loses or invents text: a
            // 68-second Hinglish review lost its last 8 seconds and got a made-up
            // repeat instead, and a five-minute test file lost one word in seven.
            // Short audio is one piece, exactly as before.
            levels = (try? Self.levels(ofWAV: wavURL, window: Self.levelWindow)) ?? []
            let cuts = audioSeconds > Self.maxPieceSeconds
                ? Self.cutTimes(levels: levels, window: Self.levelWindow, duration: audioSeconds)
                : []
            var cutPieces = Self.pieces(cuts: cuts, duration: audioSeconds)
            // whisper drops the opening words of audio that starts right on speech:
            // "Mahanga Whoop" at 0.0 s came back as nothing. A moment of silence in
            // front brings them back; every later piece already starts in a pause.
            cutPieces[0].leadIn = Self.leadInSeconds
            pieces = cutPieces
            inputs = pieces.indices.map { workDirectory.appendingPathComponent("piece-\($0).wav") }
            try Self.writePieces(of: wavURL, pieces: pieces, to: inputs)
            // The pieces hold every sample; an hour of audio is 115 MB not to keep twice.
            try? FileManager.default.removeItem(at: wavURL)
        } catch {
            throw EngineError.transcriptionFailed("Could not prepare the audio. \(error.localizedDescription)")
        }
        try Task.checkCancellation()

        progress?(TranscriptionService.Progress(
            stage: "Running \(pack.displayName) on this Mac", fraction: 0.1))

        // One process for every piece, not one per piece: whisper writes a transcript
        // per input file, and loading the model once saves a third to half a second
        // a piece — about a minute on an hour of audio.
        let stems = inputs.map { $0.deletingPathExtension() }
        var arguments = ["-m", modelURL(pack).path]
        for (input, stem) in zip(inputs, stems) {
            arguments += ["-f", input.path, "-of", stem.path]
        }
        arguments += [
            "-l", code,
            "-dtw", pack.dtwPreset,
            "-ml", "1",              // one unit per segment, merged into words below
            // Split on WORD, not on token. `-ml 1` alone cuts at token boundaries,
            // which for Devanagari (and any multi-byte script) slices a UTF-8
            // character in half: whisper then wrote invalid UTF-8 into its JSON and
            // decoding failed with "Unreadable engine output", so the Multilingual
            // model could not transcribe any non-Latin language at all. The Hinglish
            // model was unaffected only because it emits Latin text.
            "-sow",
            // Word times from DTW alignment, read from the full JSON. whisper's segment
            // times put the last words of every piece on one instant — 15 words of a
            // Hinglish review all at 20.64 s — while DTW had each one where it was
            // said. Flash attention silently turns DTW off, so it is disabled: about a
            // fifth slower, for captions that land on the words.
            "-nfa",
            "-ojf",
            "--no-prints",
        ]
        // Given to every piece: each one is decoded on its own, with nothing of the
        // pieces before it to go on.
        if let prompt = Self.whisperPrompt(for: vocabulary) {
            arguments += ["--prompt", prompt]
        }
        let process = Process()
        process.executableURL = runtime
        process.arguments = arguments

        // stdout carries one line per word as it is recognised ("[00:00:29.120 -->
        // 00:00:29.480]  word"). It used to go to /dev/null, so the progress bar sat
        // on one step for the whole run — 17 s on a one-minute clip, many minutes on
        // a long one. Reading the latest timestamp gives real progress. stderr shares
        // the pipe so that whisper's "reading audio data from '…'" line arrives in
        // order with the words: each piece's timestamps start again from zero, and
        // that line says which piece they belong to. Reading also keeps the pipe
        // drained, which an unread Pipe needs to avoid stalling the child once the OS
        // buffer fills. The transcript itself still comes from the JSON files.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let name = pack.displayName
        let paths = inputs.map(\.path)

        try process.run()
        // One cancellation scope around reading AND waiting, so Cancel stops whisper
        // whichever piece it is on.
        let lastMessage: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var reader = ProgressReader(pieces: pieces, paths: paths)
                    var pending = Data()
                    let handle = pipe.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        pending.append(chunk)
                        // Whole lines only: a chunk can end half-way through one.
                        guard let newline = pending.lastIndex(of: 0x0A) else { continue }
                        let lines = String(decoding: pending[..<newline], as: UTF8.self)
                        pending = Data(pending[pending.index(after: newline)...])
                        for line in lines.split(separator: "\n") {
                            guard let heard = reader.read(line: String(line)),
                                  let progress, audioSeconds > 0 else { continue }
                            progress(TranscriptionService.Progress(
                                stage: "Listening with \(name) — \(Self.clock(heard)) of \(Self.clock(audioSeconds))",
                                fraction: 0.1 + 0.4 * min(1, heard / audioSeconds)))
                        }
                    }
                    if !pending.isEmpty { _ = reader.read(line: String(decoding: pending, as: UTF8.self)) }
                    process.waitUntilExit()
                    continuation.resume(returning: reader.lastMessage)
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()

        progress?(TranscriptionService.Progress(stage: "Building the timing spine", fraction: 0.5))

        guard process.terminationStatus == 0 else {
            throw EngineError.transcriptionFailed(lastMessage ?? "exit \(process.terminationStatus)")
        }

        // whisper skips an input it cannot read and carries on, so a missing transcript
        // for any piece is the failure signal, not the exit status.
        var results: [(piece: AudioPiece, words: [TimedWord])] = []
        for (piece, stem) in zip(pieces, stems) {
            guard let data = try? Data(contentsOf: stem.appendingPathExtension("json")) else {
                throw EngineError.transcriptionFailed("The engine produced no output.")
            }
            results.append((piece, try Self.words(fromWhisperJSON: data,
                                                   spaced: ScriptProfile.forLanguage(code).segmentation != .characterBased)))
        }

        let words = Self.dropInventedWords(Self.stitch(results), levels: levels, window: Self.levelWindow)
        guard !words.isEmpty else { throw EngineError.noSpeechFound }

        let duration = Self.audioDuration(audioURL) ?? (words.last?.end ?? 0)
        let repaired = TranscriptionService.repairTimings(words, duration: duration)

        let spine = TimingSpine(words: repaired,
                                sourceLanguage: code,
                                duration: duration,
                                engineID: "Subly · \(pack.displayName) model",
                                isRomanizedSource: pack.emitsRomanized)
        return Outcome(spine: spine, isRomanized: pack.emitsRomanized)
    }

    /// whisper.cpp with `-ml 1` emits sub-word tokens. A token that begins with a
    /// space starts a new word, which is how the word sequence is reconstructed.
    /// - Parameter spaced: false for languages written without spaces (Japanese,
    ///   Chinese, Thai). There no segment starts with a space, and joining on spaces
    ///   made a whole sentence one "word" timed from its first piece; each piece stays
    ///   its own token, and `WordGrouping` makes words from them later.
    static func words(fromWhisperJSON data: Data, spaced: Bool = true) throws -> [TimedWord] {
        struct Offsets: Decodable { let from: Int; let to: Int }
        struct Token: Decodable {
            let text: String
            /// DTW-aligned time in centiseconds; -1 when alignment did not run.
            let t_dtw: Int?
        }
        struct Segment: Decodable { let text: String; let offsets: Offsets; let tokens: [Token]? }
        struct Root: Decodable { let transcription: [Segment] }

        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) }
        catch {
            let valid = String(data: data, encoding: .utf8) != nil
            throw EngineError.transcriptionFailed(
                valid ? "The engine's output was not in the expected format."
                      : "The engine returned text Subly could not read. This usually means a word was cut in the middle of a character.")
        }

        var words: [TimedWord] = []
        // DTW times of each word's first and last token, kept beside `words`.
        var aligned: [(first: Double, last: Double)?] = []
        for segment in root.transcription {
            let raw = segment.text
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let start = Double(segment.offsets.from) / 1000.0
            let end = Double(segment.offsets.to) / 1000.0
            // Special tokens ("[_BEG_]", "[_TT_150]") carry no word.
            let times = (segment.tokens ?? [])
                .filter { !$0.text.hasPrefix("[_") }
                .compactMap { $0.t_dtw }.filter { $0 >= 0 }
                .map { Double($0) / 100.0 }

            // Punctuation attaches to the preceding word rather than standing alone.
            let isPunctuationOnly = trimmed.allSatisfy { !$0.isLetter && !$0.isNumber }
            let startsNewWord = raw.hasPrefix(" ") || raw.hasPrefix("\n")

            if words.isEmpty || ((startsNewWord || !spaced) && !isPunctuationOnly) {
                words.append(TimedWord(text: trimmed, start: start, end: end))
                aligned.append(times.first.map { (first: $0, last: times.last ?? $0) })
            } else {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = max(words[words.count - 1].end, end)
                if let last = times.last, let previous = aligned[aligned.count - 1] {
                    aligned[aligned.count - 1] = (previous.first, max(previous.last, last))
                }
            }
        }
        return Self.applyAlignment(aligned, to: words)
    }

    /// Use DTW times when every word has one. A DTW time marks when a token is heard,
    /// so a word starts at its first token and lasts until the next word starts —
    /// though not past its own segment end, so a caption does not hang on through a
    /// pause, and never shorter than its last token.
    static func applyAlignment(_ aligned: [(first: Double, last: Double)?],
                               to words: [TimedWord]) -> [TimedWord] {
        let starts = aligned.compactMap { $0 }
        guard starts.count == words.count, !words.isEmpty else { return words }
        var out = words
        for i in out.indices {
            let start = starts[i].first
            let next = i + 1 < starts.count ? starts[i + 1].first : nil
            let segmentEnd = words[i].end > words[i].start ? words[i].end : start + 0.4
            var end = max(starts[i].last + 0.12, min(segmentEnd, start + 1.2))
            if let next { end = min(end, next) }
            out[i].start = start
            out[i].end = max(start + 0.05, end)
            if let next { out[i].end = min(out[i].end, max(start, next)) }
        }
        return out
    }

    // MARK: - Long audio

    /// The longest piece whisper is given. Its window is 30 seconds; staying under it
    /// with room to spare means a piece is always decoded in one window.
    static let maxPieceSeconds = 28.0
    /// How far into a piece a cut may go. Not before 16 s, so pieces stay long enough
    /// to give the model some context; not after 27 s, so they stay under the limit.
    static let cutSearchRange = 16.0...27.0
    /// Loudness is measured over 100 ms: long enough to span the gap between two
    /// words, short enough to find it.
    static let levelWindow = 0.1

    /// A stretch of the audio, in seconds on the whole file's clock.
    struct AudioPiece: Equatable, Sendable {
        var start: Double
        var end: Double
        /// Seconds of silence written in front of the piece's audio.
        var leadIn: Double = 0
        var length: Double { end - start }
    }

    static let leadInSeconds = 0.3

    /// Where to cut audio so whisper never has to cross from one 30-second window to
    /// the next.
    ///
    /// Each cut goes in the quietest window between 16 and 27 seconds after the start
    /// of the piece, which is almost always a pause between words, so a word is rarely
    /// sliced in half. Audio with no quiet moment at all is still cut inside that
    /// range, so no piece is ever longer than 28 seconds.
    ///
    /// - Parameters:
    ///   - levels: loudness of consecutive `window`-second slices of the audio.
    ///   - duration: length of the whole audio, in seconds.
    /// - Returns: cut times in seconds, ascending. Empty for audio of 28 s or less.
    static func cutTimes(levels: [Float], window: Double, duration: Double,
                         maxPiece: Double = maxPieceSeconds,
                         searchRange: ClosedRange<Double> = cutSearchRange) -> [Double] {
        var cuts: [Double] = []
        var start = 0.0
        while duration - start > maxPiece {
            var cut = start + searchRange.upperBound
            if window > 0 {
                // Only windows lying wholly inside the search range. The tolerance keeps
                // 16.0 / 0.1 = 160.00000000000003 from skipping the first one.
                let first = Int(((start + searchRange.lowerBound) / window - 1e-9).rounded(.up))
                let last = min(levels.count,
                               Int(((start + searchRange.upperBound) / window + 1e-9).rounded(.down))) - 1
                if first <= last {
                    var quietest = first
                    for i in first...last where levels[i] < levels[quietest] { quietest = i }
                    // Equally quiet windows in a row (digital silence) are cut in the
                    // middle. whisper drops the opening words of a file that starts
                    // right on speech, so a piece should not begin just before it.
                    var runEnd = quietest
                    while runEnd < last, levels[runEnd + 1] == levels[quietest] { runEnd += 1 }
                    cut = (Double(quietest + runEnd) / 2 + 0.5) * window
                }
            }
            cuts.append(cut)
            start = cut
        }
        return cuts
    }

    static func pieces(cuts: [Double], duration: Double) -> [AudioPiece] {
        let bounds = [0] + cuts + [duration]
        return zip(bounds, bounds.dropFirst()).map { AudioPiece(start: $0, end: $1) }
    }

    /// Join each piece's words into one transcript on the whole file's clock.
    ///
    /// whisper treats the end of every piece as the end of a file: it piles the last
    /// words onto the final instant, or stamps them past it (one piece of a real clip
    /// ended with five words at one instant and one running 7 s beyond the audio). The
    /// spine repair handles that at the real end of the audio, but knows nothing about
    /// the cuts, and the next piece's words were then pushed later and later to stay in
    /// order. So every piece but the last is repaired against its own length first.
    /// The last piece ends where the audio does and is left to the spine repair, which
    /// also keeps audio short enough to be one piece exactly as it was.
    static func stitch(_ results: [(piece: AudioPiece, words: [TimedWord])]) -> [TimedWord] {
        var out: [TimedWord] = []
        for (index, result) in results.enumerated() {
            let isLast = index == results.count - 1
            let piece = result.piece
            let local = isLast ? result.words
                : TranscriptionService.repairTimings(result.words, duration: piece.length + piece.leadIn)
            // Back onto the whole file's clock, less the silence written in front.
            let shift = piece.start - piece.leadIn
            for (k, var word) in local.enumerated() {
                word.start = max(piece.start, word.start + shift)
                word.end = max(word.start, word.end + shift)
                // Each piece is heard with no memory of the one before, so a new
                // sentence at its start often came back lower-case ("…too. use
                // filtered water"). Capitalise after a full stop.
                if k == 0, let previous = out.last?.text.last, ".!?".contains(previous),
                   let first = word.text.first, first.isLowercase {
                    word.text = first.uppercased() + word.text.dropFirst()
                }
                out.append(word)
            }
        }
        return out
    }

    /// whisper writes something for every stretch of audio, speech or not: "Thank
    /// you." over silence and room tone, "*music*" over a chord, even after the
    /// speaker has stopped. Words over near-silence and sound descriptions in
    /// brackets or asterisks are dropped, so a silent file reports "no speech" and a
    /// silent ending stays empty.
    static func dropInventedWords(_ words: [TimedWord], levels: [Float], window: Double) -> [TimedWord] {
        let peak = levels.max() ?? 0
        // Below about -40 dBFS, or a twentieth of the loudest moment, is not speech.
        let quiet = max(Float(300), peak * 0.05)
        let closers: [Character: Character] = ["[": "]", "(": ")", "*": "*"]
        var out: [TimedWord] = []
        var openSpan: Character?     // inside "[background … music]", across words
        var spanLength = 0
        for word in words {
            let raw = word.text.trimmingCharacters(in: .whitespaces)
            if let closer = openSpan {
                spanLength += 1
                if raw.last == closer || raw.contains(closer) || spanLength > 8 { openSpan = nil }
                continue
            }
            if raw.contains("♪") { continue }
            if let first = raw.first, let closer = closers[first] {
                if raw.count > 1, raw.last == closer { continue }          // "[Music]", "*music*"
                if !raw.dropFirst().contains(closer) { openSpan = closer; spanLength = 0; continue }
            }
            let core = raw.trimmingCharacters(in: .punctuationCharacters)
            if core.isEmpty || levels.isEmpty || window <= 0 { out.append(word); continue }
            // A little either side: word times can sit just off the sound.
            let from = max(0, Int(((word.start - 0.2) / window).rounded(.down)))
            let to = min(levels.count - 1, Int(((word.end + 0.2) / window).rounded(.up)))
            if from > to || levels[from...to].contains(where: { $0 >= quiet }) { out.append(word) }
        }
        return out
    }

    /// Loudness (RMS) of every `window`-second slice of a 16-bit WAV.
    static func levels(ofWAV url: URL, window: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(max(1, (file.processingFormat.sampleRate * window).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw EngineError.transcriptionFailed("Could not read the audio.")
        }
        var levels: [Float] = []
        levels.reserveCapacity(Int(file.length / AVAudioFramePosition(frames)) + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { break }
            var sum = 0.0
            for i in 0..<Int(buffer.frameLength) {
                let s = Double(samples[i])
                sum += s * s
            }
            levels.append(Float((sum / Double(buffer.frameLength)).squareRoot()))
        }
        return levels
    }

    /// Copy each piece of a 16-bit WAV into a file of its own. whisper-cli cannot be
    /// limited to part of a file: with `-ot` and `-d` its first 30-second window still
    /// decodes past the requested end, so the pieces must really be separate files.
    static func writePieces(of source: URL, pieces: [AudioPiece], to destinations: [URL]) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
        let rate = input.processingFormat.sampleRate
        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
            throw EngineError.transcriptionFailed("Could not read the audio.")
        }
        for (piece, destination) in zip(pieces, destinations) {
            let output = try AVAudioFile(forWriting: destination, settings: input.fileFormat.settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true)
            let silence = AVAudioFrameCount((piece.leadIn * rate).rounded())
            if silence > 0, let quiet = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: silence) {
                quiet.frameLength = silence
                quiet.int16ChannelData?[0].update(
                    repeating: 0, count: Int(silence) * Int(input.processingFormat.channelCount))
                try output.write(from: quiet)
            }
            let end = min(input.length, AVAudioFramePosition((piece.end * rate).rounded()))
            input.framePosition = AVAudioFramePosition((piece.start * rate).rounded())
            while input.framePosition < end {
                let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), end - input.framePosition))
                try input.read(into: buffer, frameCount: want)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            // Finish the header now: whisper opens the file before this one goes away.
            output.close()
        }
    }

    /// Turns whisper-cli's console output into how far through the WHOLE file it has
    /// got. Each piece's timestamps start again from zero; whisper names every input as
    /// it opens it ("read_audio_data: reading audio data from '…'"), so the piece being
    /// heard is known exactly and its start is added back.
    struct ProgressReader {
        let pieces: [AudioPiece]
        let paths: [String]
        private var current = 0
        private var heard = 0.0
        /// The last line that was not a word, which is where whisper puts its errors.
        private(set) var lastMessage: String?

        init(pieces: [AudioPiece], paths: [String]) {
            self.pieces = pieces; self.paths = paths
        }

        /// Seconds of the whole file heard so far, when this line moved it forward.
        mutating func read(line: String) -> Double? {
            guard let stamp = ExtendedEngineManager.lastTimestamp(in: line),
                  pieces.indices.contains(current) else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lastMessage = trimmed }
                if let open = line.range(of: "reading audio data from '") {
                    let path = String(line[open.upperBound...].prefix { $0 != "'" })
                    if let index = paths.firstIndex(of: path) { current = index }
                }
                return nil
            }
            // whisper stamps its last words past the end of the audio; never show
            // "1:30 of 1:08", and never move the bar backwards.
            let piece = pieces[current]
            let now = piece.start + min(max(0, stamp - piece.leadIn), piece.length)
            guard now > heard else { return nil }
            heard = now
            return now
        }
    }

    /// whisper's `--prompt`, built from names and uncommon words the person expects to
    /// hear. whisper reads a prompt as text spoken just before the audio, so a brand
    /// spelled there tends to be spelled that way in the transcript — on a Hinglish
    /// review it turned "Terex ultra 2" into "T-Rex Ultra 2" and "Fitbit air" into
    /// "Fitbit Air". Kept short: whisper reads at most 224 tokens of prompt, and a long
    /// one starts to steer the words, not just their spelling.
    ///
    /// - Returns: nil when there is nothing to say, so no prompt is passed at all.
    static func whisperPrompt(for vocabulary: [String], maxCharacters: Int = 200) -> String? {
        var terms: [String] = []
        var length = 1                                     // the closing full stop
        for term in TranscriptionService.vocabularyTerms(vocabulary) {
            let added = (terms.isEmpty ? 0 : 2) + term.count  // ", " between terms
            guard length + added <= maxCharacters else { break }
            terms.append(term)
            length += added
        }
        return terms.isEmpty ? nil : terms.joined(separator: ", ") + "."
    }

    // MARK: - Language identification

    /// Identify the spoken language with Whisper's own language detector, which scores
    /// about 99 languages from one pass over the first 30 seconds.
    ///
    /// The app used to guess by transcribing the clip with each Apple language already
    /// on the Mac and keeping the most confident result. Hindi was usually not among
    /// them, so a Hinglish video came back as Spanish.
    ///
    /// - Returns: nil when no general Whisper model is downloaded.
    public func detectLanguage(audioURL: URL) async throws -> (code: String, probability: Double)? {
        guard let pack = Self.allPacks.first(where: { $0.isGeneral && isInstalled($0) }),
              let runtime = runtimeURL else { return nil }
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("subly-detect-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try Self.writeWAV16(from: audioURL, to: wavURL)

        let process = Process()
        process.executableURL = runtime
        // No --no-prints: that also silences the "auto-detected language" line.
        process.arguments = ["-m", modelURL(pack).path, "-f", wavURL.path, "-l", "auto", "-dl"]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? errPipe.fileHandleForReading.readToEnd()
                process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
        return data.flatMap { Self.detectedLanguage(in: String(decoding: $0, as: UTF8.self)) }
    }

    /// Parses "auto-detected language: hi (p = 0.773177)".
    static func detectedLanguage(in log: String) -> (code: String, probability: Double)? {
        guard let marker = log.range(of: "auto-detected language: ") else { return nil }
        let rest = log[marker.upperBound...]
        let code = rest.prefix { $0.isLetter }
        guard !code.isEmpty, let p = rest.range(of: "p = ") else { return nil }
        let number = rest[p.upperBound...].prefix { $0.isNumber || $0 == "." }
        return (String(code), Double(number) ?? 0)
    }

    /// The end time of the last "[from --> to]" line in a chunk of whisper output.
    static func lastTimestamp(in text: String) -> Double? {
        guard let arrow = text.range(of: "--> ", options: .backwards) else { return nil }
        let rest = text[arrow.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { return nil }
        let parts = rest[..<close].split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Length of an audio file in seconds. Read from the file, not guessed from its
    /// size: AVAudioFile writes WAV headers larger than the classic 44 bytes.
    static func wavDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Convert any readable audio to 16 kHz mono signed-16 WAV.
    static func writeWAV16(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let targetRate: Double = 16_000

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: targetRate,
                                            channels: 1, interleaved: true) else {
            throw EngineError.transcriptionFailed("Unsupported audio format.")
        }
        var settings = outFormat.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false

        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)

        guard let converter = AVAudioConverter(from: input.processingFormat, to: outFormat) else {
            throw EngineError.transcriptionFailed("Could not convert the audio.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let chunk: AVAudioFrameCount = 16_384
        var finished = false
        while !finished {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                                    frameCapacity: chunk) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { need, outStatus in
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                      frameCapacity: need) else {
                    outStatus.pointee = .endOfStream; return nil
                }
                do { try input.read(into: inBuffer, frameCount: need) }
                catch { outStatus.pointee = .endOfStream; return nil }
                if inBuffer.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError { throw conversionError }
            if outBuffer.frameLength > 0 { try output.write(from: outBuffer) }
            if status == .endOfStream || status == .error { finished = true }
        }
    }

    static func audioDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }
}
