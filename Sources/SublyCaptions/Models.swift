import Foundation

// MARK: - Output kinds

/// The three subtitle outputs a user may tick.
public enum OutputKind: String, Codable, Sendable, CaseIterable, Hashable {
    case translation      // → target language, English guaranteed
    case romanized        // source meaning, Latin script
    case original         // source language, source script

    public var shortLabel: String {
        switch self {
        case .translation: return "Translation"
        case .romanized:   return "In English letters"
        case .original:    return "Original transcript"
        }
    }
}

// MARK: - Timing spine

/// One recognised word with its audio time range. The atom of the timing spine.
public struct TimedWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
    public var duration: Double { max(0, end - start) }
}

/// The single alignment authority for every derived track.
///
/// Exactly one speech pass produces this. Every subtitle track is then filled into
/// the cue slots derived from it, which is what guarantees identical timings across
/// tracks and makes simultaneous display meaningful.
public struct TimingSpine: Codable, Sendable {
    public var words: [TimedWord]
    public var sourceLanguage: String      // BCP-47
    public var duration: Double
    public var engineID: String
    /// True when the recogniser already produced Roman script (some models write
    /// Hinglish straight from audio). The romanized track then needs no
    /// transliteration, and a native-script transcript is NOT available from it.
    public var isRomanizedSource: Bool
    /// Set when the recogniser seems to have missed part of the audio, so the person
    /// can be told instead of getting half-empty captions without a word of warning.
    public var warning: String?

    public init(words: [TimedWord], sourceLanguage: String, duration: Double,
                engineID: String, isRomanizedSource: Bool = false) {
        self.words = words; self.sourceLanguage = sourceLanguage
        self.duration = duration; self.engineID = engineID
        self.isRomanizedSource = isRomanizedSource
    }

    public var plainText: String {
        words.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Mean confidence across words that reported one.
    public var meanConfidence: Double? {
        let c = words.compactMap(\.confidence)
        guard !c.isEmpty else { return nil }
        return c.reduce(0, +) / Double(c.count)
    }
}

// MARK: - Cue slots

/// A time window carved from the spine. Every track fills the same slots, so cue
/// boundaries are identical across tracks by construction.
public struct CueSlot: Codable, Sendable, Hashable {
    public var index: Int
    public var start: Double
    public var end: Double
    /// Indices into `TimingSpine.words` that produced this slot.
    public var wordRange: Range<Int>
    /// True when the slot ends on sentence-final punctuation.
    public var endsSentence: Bool
    /// Index of the spine slot this was carved from. Equal to `index` unless the
    /// slot was subdivided so that a longer track could fit.
    public var parentIndex: Int
    /// Position within the parent, and how many siblings it has.
    public var subIndex: Int
    public var subCount: Int

    public init(index: Int, start: Double, end: Double, wordRange: Range<Int>,
                endsSentence: Bool, parentIndex: Int? = nil,
                subIndex: Int = 0, subCount: Int = 1) {
        self.index = index; self.start = start; self.end = end
        self.wordRange = wordRange; self.endsSentence = endsSentence
        self.parentIndex = parentIndex ?? index
        self.subIndex = subIndex; self.subCount = subCount
    }
    public var duration: Double { max(0, end - start) }
}

// MARK: - Cues and tracks

public struct Cue: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var slotIndex: Int
    public var start: Double
    public var end: Double
    public var lines: [String]
    /// Set when the engine or a validator flagged this cue for human review.
    public var needsReview: Bool
    public var reviewReason: String?

    public init(id: UUID = UUID(), slotIndex: Int, start: Double, end: Double,
                lines: [String], needsReview: Bool = false, reviewReason: String? = nil) {
        self.id = id; self.slotIndex = slotIndex; self.start = start; self.end = end
        self.lines = lines; self.needsReview = needsReview; self.reviewReason = reviewReason
    }

    private enum CodingKeys: String, CodingKey { case id, slotIndex, start, end, lines, needsReview, reviewReason }

    /// Lenient about everything but the words and their times, so a project from an
    /// older or newer Subly still opens instead of vanishing from the list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        slotIndex = try c.decode(Int.self, forKey: .slotIndex)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        lines = try c.decode([String].self, forKey: .lines)
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        reviewReason = try c.decodeIfPresent(String.self, forKey: .reviewReason)
    }

    public var duration: Double { max(0, end - start) }
    public var text: String { lines.joined(separator: "\n") }
    public var characterCount: Int { lines.reduce(0) { $0 + $1.count } }
    /// Characters per second — the reading-rate metric.
    public var readingRate: Double { duration > 0 ? Double(characterCount) / duration : .infinity }
}

public struct SubtitleTrack: Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: OutputKind
    /// BCP-47 including script subtag where it matters, e.g. `hi-Latn`.
    public var languageTag: String
    public var displayName: String
    public var cues: [Cue]
    public var engineID: String
    /// Read-only tracks (an imported reference subtitle) are excluded from export by default.
    public var isReference: Bool

    public init(id: UUID = UUID(), kind: OutputKind, languageTag: String, displayName: String,
                cues: [Cue], engineID: String, isReference: Bool = false) {
        self.id = id; self.kind = kind; self.languageTag = languageTag
        self.displayName = displayName; self.cues = cues
        self.engineID = engineID; self.isReference = isReference
    }

    /// Filename suffix for export.
    public var fileSuffix: String { languageTag }
}

// MARK: - Caption rules

public struct CaptionRules: Codable, Sendable, Hashable {
    public var maxWordsPerLine: Int
    public var maxLinesPerCue: Int
    public var maxCharsPerLine: Int
    public var maxReadingRate: Double     // chars/sec
    public var minCueDuration: Double
    public var maxCueDuration: Double
    /// A silence longer than this forces a cue boundary.
    public var pauseBoundary: Double
    public var preferSentenceBoundaries: Bool
    /// The most words one caption may hold, when the user has chosen it. Otherwise it
    /// follows the line limits.
    public var customMaxWordsPerCue: Int?
    public var maxWordsPerCue: Int { customMaxWordsPerCue ?? maxWordsPerLine * maxLinesPerCue }
    /// The fewest words a caption should hold. A caption is only left shorter when the
    /// words around it are too far away in time to join it — a lone "Thanks." after a
    /// long pause. Without this, a caption that filled up one word before the end of a
    /// sentence left that last word ("point.") on screen by itself.
    public var minWordsPerCue: Int

    public init(maxWordsPerLine: Int = 4, maxLinesPerCue: Int = 2, maxCharsPerLine: Int = 42,
                maxReadingRate: Double = 17, minCueDuration: Double = 0.75,
                maxCueDuration: Double = 4.0, pauseBoundary: Double = 0.45,
                preferSentenceBoundaries: Bool = true,
                maxWordsPerCue: Int? = nil, minWordsPerCue: Int = 3) {
        self.maxWordsPerLine = maxWordsPerLine
        self.maxLinesPerCue = maxLinesPerCue
        self.maxCharsPerLine = maxCharsPerLine
        self.maxReadingRate = maxReadingRate
        self.minCueDuration = minCueDuration
        self.maxCueDuration = maxCueDuration
        self.pauseBoundary = pauseBoundary
        self.preferSentenceBoundaries = preferSentenceBoundaries
        self.customMaxWordsPerCue = maxWordsPerCue
        self.minWordsPerCue = minWordsPerCue
    }

    /// Projects saved before the word-count settings existed still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxWordsPerLine = try c.decode(Int.self, forKey: .maxWordsPerLine)
        maxLinesPerCue = try c.decode(Int.self, forKey: .maxLinesPerCue)
        maxCharsPerLine = try c.decode(Int.self, forKey: .maxCharsPerLine)
        maxReadingRate = try c.decode(Double.self, forKey: .maxReadingRate)
        minCueDuration = try c.decode(Double.self, forKey: .minCueDuration)
        maxCueDuration = try c.decode(Double.self, forKey: .maxCueDuration)
        pauseBoundary = try c.decode(Double.self, forKey: .pauseBoundary)
        preferSentenceBoundaries = try c.decode(Bool.self, forKey: .preferSentenceBoundaries)
        customMaxWordsPerCue = try c.decodeIfPresent(Int.self, forKey: .customMaxWordsPerCue)
        minWordsPerCue = try c.decodeIfPresent(Int.self, forKey: .minWordsPerCue) ?? 3
    }

    /// Set the caption word range, keeping the line limit wide enough that the
    /// formatter does not split a caption the user asked to be longer.
    public mutating func setWordsPerCue(min lower: Int, max upper: Int) {
        let upper = Swift.max(1, upper)
        customMaxWordsPerCue = upper
        minWordsPerCue = Swift.max(1, Swift.min(lower, upper))
        let perLine = Int((Double(upper) / Double(Swift.max(1, maxLinesPerCue))).rounded(.up))
        maxWordsPerLine = Swift.max(maxWordsPerLine, perLine)
    }

    /// The default short-form preset.
    /// Vertical social video: short, fast, punchy lines burned over the picture.
    ///
    /// This used to be `CaptionRules()` — the 17 chars/sec default — which made it the
    /// *slowest* preset, slower than YouTube's 20. That is backwards for the format it
    /// is named after, and on a real Reel it marked 48 of 51 captions "too fast to
    /// read", which is noise rather than advice. Real short-form captions run around
    /// 22 chars/sec on two short lines.
    public static let shortForm = CaptionRules(maxWordsPerLine: 5, maxLinesPerCue: 2,
                                               maxCharsPerLine: 34, maxReadingRate: 22,
                                               minCueDuration: 0.7, maxCueDuration: 3.5)
    public static let youTube = CaptionRules(maxWordsPerLine: 7, maxLinesPerCue: 2, maxCharsPerLine: 42,
                                             maxReadingRate: 20, minCueDuration: 1.0, maxCueDuration: 6.0)
    public static let interview = CaptionRules(maxWordsPerLine: 6, maxLinesPerCue: 2, maxCharsPerLine: 42,
                                               maxReadingRate: 17, minCueDuration: 1.0, maxCueDuration: 7.0)
    public static let premiere = CaptionRules(maxWordsPerLine: 8, maxLinesPerCue: 2, maxCharsPerLine: 42,
                                              maxReadingRate: 20, minCueDuration: 0.83, maxCueDuration: 7.0)

    public static let presets: [(name: String, rules: CaptionRules)] = [
        ("Short-form", .shortForm), ("YouTube", .youTube),
        ("Interview", .interview), ("Premiere import", .premiere),
    ]

    /// Combine the preset's audience tolerance with the script's density.
    ///
    /// This used to assign the profile's values outright, which silently discarded the
    /// preset. "YouTube" and "Premiere import" both ask for 20 chars/sec and
    /// "Interview" for 17, but every one of them came out as whatever the script said —
    /// so the preset picker had no effect on reading rate or line length at all. On a
    /// fast vertical clip that flagged 48 of 52 captions as too fast to read, which is
    /// noise rather than information.
    ///
    /// The two settings mean different things and both matter: the profile knows that a
    /// CJK character carries far more than a Latin one, the preset knows how much the
    /// audience will tolerate. So scale the preset by the script's density relative to
    /// the Latin baseline instead of replacing it.
    public func adjusted(for profile: ScriptProfile) -> CaptionRules {
        var r = self
        let base = ScriptProfile.latin
        let rateScale = profile.maxReadingRate / base.maxReadingRate
        let charScale = Double(profile.maxCharsPerLine) / Double(base.maxCharsPerLine)
        r.maxReadingRate = (maxReadingRate * rateScale).rounded()
        // Line length is clamped to the script's ceiling as well as scaled: a preset
        // asking for long Latin lines must not produce a CJK line that cannot fit.
        let scaledChars = Int((Double(maxCharsPerLine) * charScale).rounded())
        r.maxCharsPerLine = max(8, min(scaledChars, profile.maxCharsPerLine))
        return r
    }
}

// MARK: - Validation

public enum CueIssue: String, Codable, Sendable, Hashable {
    case overWordLimit, overCharLimit, tooShort, tooLong, overReadingRate, empty, overlap, lowConfidence

    public var message: String {
        switch self {
        case .overWordLimit:   return "Line exceeds the word limit"
        case .overCharLimit:   return "Line exceeds the character limit"
        case .tooShort:        return "Cue is shorter than the minimum duration"
        case .tooLong:         return "Cue is longer than the maximum duration"
        case .overReadingRate: return "Text is too long to read in this time"
        case .empty:           return "Cue has no text"
        case .overlap:         return "Cue overlaps the next cue"
        case .lowConfidence:   return "Low recognition confidence — please review"
        }
    }
}

public struct CueDiagnostic: Sendable, Hashable, Identifiable {
    public var id: String { "\(cueID.uuidString)-\(issue.rawValue)" }
    public let cueID: UUID
    public let issue: CueIssue
    public init(cueID: UUID, issue: CueIssue) { self.cueID = cueID; self.issue = issue }
}
