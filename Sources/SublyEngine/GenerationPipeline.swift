import Foundation
import SublyCaptions

/// Orchestrates a generation run: media → audio → ONE speech pass → spine → slots →
/// every selected track. PRD ASR-04, MULTI-02, MULTI-09.
public actor GenerationPipeline {

    /// A track's text before the cue grid is decided.
    struct Resolved {
        var kind: OutputKind
        var languageTag: String
        var displayName: String
        var texts: [Int: String]
        var flagged: Set<Int>
        var note: String?
        var formatter: CaptionFormatter
    }


    public struct Request: Sendable {
        public var mediaURL: URL
        public var workingDirectory: URL
        public var sourceLanguage: String
        public var outputs: Set<OutputKind>
        public var translationTarget: String
        public var rules: CaptionRules
        public var protectedTerms: [String]
        /// Names, brands and uncommon words likely to be said ("Fitbit Air", "Amazfit").
        /// Passed to the recogniser as a spelling hint; empty means none.
        public var vocabulary: [String]
        public var useRefinement: Bool
        /// Supplied by the app: a translator backed by a SwiftUI `translationTask`
        /// session. Apple only lets a view-attached session download language assets,
        /// so a detached actor can translate only already-provisioned pairs.
        public var translator: (@Sendable ([Int: String], String, String) async throws -> [Int: String])?
        /// A transcript from an earlier run. When set, the audio is not read or listened
        /// to again; only the captions are re-cut, so changing how many words a caption
        /// holds takes a moment instead of a full transcription.
        public var reuse: Reuse?

        public struct Reuse: Sendable {
            public var spine: TimingSpine
            public var audioURL: URL
            public var waveform: [Float]
            public init(spine: TimingSpine, audioURL: URL, waveform: [Float]) {
                self.spine = spine; self.audioURL = audioURL; self.waveform = waveform
            }
        }

        public init(mediaURL: URL, workingDirectory: URL, sourceLanguage: String,
                    outputs: Set<OutputKind>, translationTarget: String = "en",
                    rules: CaptionRules = .shortForm, protectedTerms: [String] = [],
                    vocabulary: [String] = [],
                    useRefinement: Bool = true,
                    translator: (@Sendable ([Int: String], String, String) async throws -> [Int: String])? = nil) {
            self.mediaURL = mediaURL; self.workingDirectory = workingDirectory
            self.sourceLanguage = sourceLanguage; self.outputs = outputs
            self.translationTarget = translationTarget; self.rules = rules
            self.protectedTerms = protectedTerms; self.vocabulary = vocabulary
            self.useRefinement = useRefinement
            self.translator = translator
        }
    }

    public struct Update: Sendable {
        public var stage: String
        public var fraction: Double
        public var detail: String?
        public init(stage: String, fraction: Double, detail: String? = nil) {
            self.stage = stage; self.fraction = fraction; self.detail = detail
        }
    }

    /// One failed track never discards the successful ones. PRD MULTI-09.
    public struct Output: Sendable {
        public var spine: TimingSpine
        public var slots: [CueSlot]
        public var tracks: [SubtitleTrack]
        public var failures: [(kind: OutputKind, message: String)]
        public var audioURL: URL
        public var waveform: [Float]
    }

    private let media = MediaService()
    private let transcription = TranscriptionService()
    private let translation = TranslationService()
    private let refinement = RefinementService()
    private let romanizer = Romanizer()

    public init() {}

    public func generate(_ request: Request,
                         progress: (@Sendable (Update) -> Void)? = nil) async throws -> Output {
        let profile = ScriptProfile.forLanguage(request.sourceLanguage)
        let rules = request.rules.adjusted(for: profile)

        let audioURL: URL
        var spine: TimingSpine
        if let reuse = request.reuse {
            audioURL = reuse.audioURL
            spine = reuse.spine
        } else {
            // 1. Audio
            progress?(Update(stage: "Reading the audio", fraction: 0.02))
            try FileManager.default.createDirectory(at: request.workingDirectory,
                                                    withIntermediateDirectories: true)
            audioURL = request.workingDirectory.appendingPathComponent("audio.caf")
            _ = try await media.extractAudio(from: request.mediaURL, to: audioURL) { f in
                progress?(Update(stage: "Reading the audio", fraction: 0.02 + f * 0.08))
            }

            // 2. One speech pass — the timing spine.
            spine = try await transcription.transcribe(audioURL: audioURL,
                                                        language: request.sourceLanguage,
                                                        vocabulary: request.vocabulary) { p in
                progress?(Update(stage: p.stage, fraction: 0.10 + p.fraction * 0.45))
            }
            // Words, not characters, for languages written without spaces.
            if profile.segmentation == .characterBased {
                let code = request.sourceLanguage.split(separator: "-").first.map(String.init) ?? request.sourceLanguage
                spine.words = WordGrouping.group(spine.words, languageCode: code)
            }
        }

        // 3. Slots, carved once and shared by every track.
        progress?(Update(stage: "Laying out caption cues", fraction: 0.58))
        let segmenter = Segmenter(rules: rules, profile: profile)
        let slots = segmenter.segment(spine)
        let sourceTexts = Self.slotTexts(spine: spine, slots: slots)

        // 4. Resolve every selected output's TEXT first, then unify the cue grid to
        // the largest demand, then fill all tracks against that single grid. This is
        // what makes identical cross-track timings true instead of aspirational.
        var failures: [(kind: OutputKind, message: String)] = []
        let lowConfidenceSlots = Self.lowConfidenceSlots(spine: spine, slots: slots)

        // Translation LAST. It is the only output that depends on a framework which
        // can stall, and resolving it first meant a stalled translation starved the
        // transcript and romanized tracks that were already ready in about two seconds.
        // With it last, a translation failure costs the user the translation and
        // nothing else.
        let ordered: [OutputKind] = [.original, .romanized, .translation]
        var wanted = request.outputs
        // A model like Apex hears Hindi and writes it in English letters, so there is
        // no native-script transcript to give. Asking for "the transcript" with it
        // selected used to fail the whole run; what the user gets instead is the
        // Hinglish track, which is the reason they picked that model.
        if spine.isRomanizedSource, wanted.remove(.original) != nil {
            wanted.insert(.romanized)
        }
        let selected = ordered.filter { wanted.contains($0) }
        let perTrack = 0.34 / Double(max(1, selected.count))

        var resolved: [Resolved] = []
        for (trackIndex, kind) in selected.enumerated() {
            let base = 0.60 + perTrack * Double(trackIndex)
            do {
                let r = try await resolveText(kind: kind, request: request, spine: spine,
                                              slots: slots, sourceTexts: sourceTexts,
                                              baseRules: request.rules) { f, label in
                    progress?(Update(stage: label, fraction: base + f * perTrack))
                }
                resolved.append(r)
            } catch {
                failures.append((kind, error.localizedDescription))
            }
        }

        guard !resolved.isEmpty else {
            throw failures.first.map { NSError(domain: "Subly", code: 1, userInfo: [
                NSLocalizedDescriptionKey: $0.message]) }
                ?? NSError(domain: "Subly", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No subtitle tracks could be produced."])
        }

        progress?(Update(stage: "Aligning the tracks", fraction: 0.95))

        // How many cues does each track need per slot? Take the maximum.
        let demands: [[Int: Int]] = resolved.map { r in
            var demand: [Int: Int] = [:]
            for slot in slots {
                let text = r.texts[slot.index] ?? ""
                demand[slot.index] = r.formatter.requiredCueCount(for: text,
                                                                  duration: slot.duration)
            }
            return demand
        }
        // How many pieces can the THINNEST track fill without leaving a cue empty?
        // Subdividing beyond that would give some track a blank cue, the writers skip
        // blank cues, and the exported files would then disagree on cue count — which
        // is exactly the guarantee this design exists to keep.
        var fillable: [Int: Int] = [:]
        for slot in slots {
            let counts = resolved.map { r -> Int in
                let text = (r.texts[slot.index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return 1 }
                switch r.formatter.profile.segmentation {
                case .wordBased:      return max(1, text.split(separator: " ").count)
                case .characterBased: return max(1, text.count)
                }
            }
            fillable[slot.index] = max(1, counts.min() ?? 1)
        }
        let unified = CaptionFormatter.unify(slots: slots, demands: demands,
                                              words: spine.words,
                                              minCueDuration: rules.minCueDuration,
                                              fillable: fillable,
                                              minWordsPerPiece: profile.segmentation == .wordBased
                                                  ? rules.minWordsPerCue : 1)

        var tracks: [SubtitleTrack] = []
        for r in resolved {
            var cues = r.formatter.fill(slots: unified, texts: r.texts)
            let flagged = r.flagged.union(lowConfidenceSlots)
            cues = Self.flagReview(cues, slots: flagged, parents: unified,
                                   reason: r.note ?? "Low recognition confidence")
            tracks.append(SubtitleTrack(kind: r.kind, languageTag: r.languageTag,
                                        displayName: r.displayName, cues: cues,
                                        engineID: spine.engineID))
        }

        progress?(Update(stage: "Drawing the waveform", fraction: 0.98))
        let waveform: [Float]
        if let reuse = request.reuse { waveform = reuse.waveform }
        else { waveform = (try? await media.waveform(for: audioURL,
                                                       buckets: MediaService.waveformBuckets(for: spine.duration))) ?? [] }

        progress?(Update(stage: "Done", fraction: 1.0))
        return Output(spine: spine, slots: unified, tracks: tracks,
                      failures: failures, audioURL: audioURL, waveform: waveform)
    }

    // MARK: - Text resolution

    private func resolveText(kind: OutputKind,
                             request: Request,
                             spine: TimingSpine,
                             slots: [CueSlot],
                             sourceTexts: [Int: String],
                             baseRules: CaptionRules,
                             progress: @escaping @Sendable (Double, String) -> Void) async throws -> Resolved {
        let sourceCode = request.sourceLanguage.split(separator: "-").first.map(String.init)
            ?? request.sourceLanguage

        // The script the OUTPUT is written in, not the source script. Formatting an
        // English translation with Japanese rules sliced words mid-token.
        let outputLanguage: String
        switch kind {
        case .original:    outputLanguage = spine.isRomanizedSource ? "\(sourceCode)-Latn" : sourceCode
        case .translation: outputLanguage = request.translationTarget
        case .romanized:   outputLanguage = "\(sourceCode)-Latn"
        }
        let outputProfile = ScriptProfile.forLanguage(outputLanguage)
        let formatter = CaptionFormatter(rules: baseRules.adjusted(for: outputProfile),
                                          profile: outputProfile)

        switch kind {
        case .original:
            if spine.isRomanizedSource {
                throw NSError(domain: "Subly", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "The \(CapabilityRegistry.displayName(sourceCode)) engine writes in the Roman alphabet, so it can't produce a native-script transcript. Switch to Apple's engine for that."])
            }
            progress(1.0, "Writing the original transcript")
            return Resolved(kind: .original, languageTag: sourceCode,
                            displayName: "\(CapabilityRegistry.displayName(sourceCode)) transcript",
                            texts: sourceTexts, flagged: [], note: nil, formatter: formatter)

        case .translation:
            progress(0.1, "Translating")
            var texts: [Int: String]
            if let translator = request.translator {
                texts = try await translator(sourceTexts, sourceCode, request.translationTarget)
            } else {
                texts = try await translation.translate(slotTexts: sourceTexts,
                                                         from: sourceCode,
                                                         to: request.translationTarget) { f in
                    progress(0.1 + f * 0.7, "Translating")
                }
            }
            if request.useRefinement, await refinement.isAvailable {
                progress(0.85, "Polishing the translation")
                texts = await refinement.refine(
                    slotTexts: texts,
                    language: request.translationTarget,
                    instruction: "Fix punctuation and capitalisation in these subtitle lines. Keep the wording natural for on-screen captions.")
            }
            progress(1.0, "Translating")
            let target = request.translationTarget
            return Resolved(kind: .translation, languageTag: target,
                            displayName: "\(CapabilityRegistry.displayName(target)) translation",
                            texts: texts, flagged: [], note: nil, formatter: formatter)

        case .romanized:
            let label = sourceCode == "hi" ? "Hinglish"
                : "\(CapabilityRegistry.displayName(sourceCode)) in English letters"

            // Already Roman from the recogniser: use it as-is. Transliterating again
            // would corrupt it.
            if spine.isRomanizedSource {
                progress(1.0, "Writing it in English letters")
                return Resolved(kind: .romanized, languageTag: "\(sourceCode)-Latn",
                                displayName: label, texts: sourceTexts,
                                flagged: [], note: nil, formatter: formatter)
            }

            progress(0.2, "Writing it in English letters")
            var texts: [Int: String] = [:]
            var flagged = Set<Int>()
            var note: String?
            for (slot, text) in sourceTexts {
                let r = romanizer.romanize(text, language: sourceCode,
                                           protectedTerms: request.protectedTerms)
                texts[slot] = r.text
                if r.lowConfidence { flagged.insert(slot) }
                if note == nil { note = r.note }
            }
            if request.useRefinement, await refinement.isAvailable {
                progress(0.7, "Polishing the spelling")
                texts = await refinement.rerankRomanization(
                    slotTexts: texts, language: sourceCode,
                    protectedTerms: request.protectedTerms)
            }
            progress(1.0, "Writing it in English letters")
            return Resolved(kind: .romanized, languageTag: "\(sourceCode)-Latn",
                            displayName: label, texts: texts,
                            flagged: flagged, note: note, formatter: formatter)
        }
    }

    // MARK: - Helpers

    /// Join words, keeping punctuation tight to the preceding word.
    ///
    /// This replaced a regular expression that ran once per slot. Compiling and
    /// applying it 850 times cost 1.65 ms where a single pass costs 0.22 ms.
    static func join(_ words: ArraySlice<TimedWord>, joiner: String) -> String {
        var text = ""
        text.reserveCapacity(words.count * 8)
        var first = true
        for word in words {
            let piece = word.text
            guard !piece.isEmpty else { continue }
            if !first, !joiner.isEmpty {
                // No space before punctuation.
                let leads = piece.first!
                if !",.!?;:)]}\u{2019}".contains(leads) { text += joiner }
            }
            text += piece
            first = false
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Join the spine words for each slot, keyed by PARENT slot index.
    ///
    /// Use this with an already-unified grid. `CaptionFormatter.fill` looks text up by
    /// `parentIndex`, so keying by the unified sub-slot index silently loses every
    /// word outside the first sub-slot of each parent.
    public static func parentSlotTexts(spine: TimingSpine, slots: [CueSlot]) -> [Int: String] {
        let profile = ScriptProfile.forLanguage(spine.sourceLanguage)
        let joiner = profile.segmentation == .characterBased ? "" : " "
        var ranges: [Int: (lower: Int, upper: Int)] = [:]
        for slot in slots {
            let lower = max(0, slot.wordRange.lowerBound)
            let upper = min(spine.words.count, slot.wordRange.upperBound)
            guard lower < upper else { continue }
            if let existing = ranges[slot.parentIndex] {
                ranges[slot.parentIndex] = (min(existing.lower, lower), max(existing.upper, upper))
            } else {
                ranges[slot.parentIndex] = (lower, upper)
            }
        }
        var out: [Int: String] = [:]
        for (parent, range) in ranges {
            out[parent] = Self.join(spine.words[range.lower..<range.upper], joiner: joiner)
        }
        return out
    }

    /// Join the spine words belonging to each slot, with script-appropriate spacing.
    public static func slotTexts(spine: TimingSpine, slots: [CueSlot]) -> [Int: String] {
        let profile = ScriptProfile.forLanguage(spine.sourceLanguage)
        let joiner = profile.segmentation == .characterBased ? "" : " "
        var out: [Int: String] = [:]
        for slot in slots {
            let lower = max(0, slot.wordRange.lowerBound)
            let upper = min(spine.words.count, slot.wordRange.upperBound)
            guard lower < upper else { out[slot.index] = ""; continue }
            out[slot.index] = Self.join(spine.words[lower..<upper], joiner: joiner)
        }
        return out
    }

    /// Slots whose words came back with weak confidence get marked for review rather
    /// than presented as certain. PRD ASR-10.
    static func lowConfidenceSlots(spine: TimingSpine, slots: [CueSlot],
                                   threshold: Double = 0.4) -> Set<Int> {
        var out = Set<Int>()
        for slot in slots {
            let lower = max(0, slot.wordRange.lowerBound)
            let upper = min(spine.words.count, slot.wordRange.upperBound)
            guard lower < upper else { continue }
            let confidences = spine.words[lower..<upper].compactMap(\.confidence)
            guard !confidences.isEmpty else { continue }
            let mean = confidences.reduce(0, +) / Double(confidences.count)
            if mean < threshold { out.insert(slot.index) }
        }
        return out
    }

    /// Flags are computed against spine slots; cues live on unified sub-slots, so
    /// map through `parentIndex`.
    static func flagReview(_ cues: [Cue], slots: Set<Int>,
                           parents: [CueSlot], reason: String) -> [Cue] {
        guard !slots.isEmpty else { return cues }
        var parentOf: [Int: Int] = [:]
        for slot in parents { parentOf[slot.index] = slot.parentIndex }
        return cues.map { cue in
            let parent = parentOf[cue.slotIndex] ?? cue.slotIndex
            guard slots.contains(parent) else { return cue }
            var c = cue; c.needsReview = true; c.reviewReason = reason; return c
        }
    }
}
