import Foundation

/// Per-script caption behaviour. Word limits are meaningless for languages written
/// without spaces, and scripts differ sharply in how much text fits a line. PRD CAP-10.
public struct ScriptProfile: Sendable, Hashable {
    public enum Segmentation: String, Sendable, Hashable {
        /// Space-delimited: count words.
        case wordBased
        /// No inter-word spaces (CJK, Thai): count grapheme clusters.
        case characterBased
    }

    public let scriptCode: String          // ISO 15924, e.g. "Latn", "Deva", "Jpan"
    public let segmentation: Segmentation
    public let maxCharsPerLine: Int
    public let maxReadingRate: Double
    public let isRightToLeft: Bool
    /// True when Romanization is a meaningful output for this script.
    public let romanizable: Bool

    public init(scriptCode: String, segmentation: Segmentation, maxCharsPerLine: Int,
                maxReadingRate: Double, isRightToLeft: Bool, romanizable: Bool) {
        self.scriptCode = scriptCode; self.segmentation = segmentation
        self.maxCharsPerLine = maxCharsPerLine; self.maxReadingRate = maxReadingRate
        self.isRightToLeft = isRightToLeft; self.romanizable = romanizable
    }

    // Latin baseline follows common broadcast practice: 42 chars/line, 17 chars/sec.
    public static let latin  = ScriptProfile(scriptCode: "Latn", segmentation: .wordBased,
                                             maxCharsPerLine: 42, maxReadingRate: 17,
                                             isRightToLeft: false, romanizable: false)
    // Indic scripts render wider per character and combine marks; allow fewer chars.
    public static let devanagari = ScriptProfile(scriptCode: "Deva", segmentation: .wordBased,
                                                 maxCharsPerLine: 38, maxReadingRate: 15,
                                                 isRightToLeft: false, romanizable: true)
    // CJK carries far more meaning per glyph: fewer characters, slower rate.
    public static let cjk    = ScriptProfile(scriptCode: "Hani", segmentation: .characterBased,
                                             maxCharsPerLine: 16, maxReadingRate: 9,
                                             isRightToLeft: false, romanizable: true)
    public static let japanese = ScriptProfile(scriptCode: "Jpan", segmentation: .characterBased,
                                               maxCharsPerLine: 16, maxReadingRate: 9,
                                               isRightToLeft: false, romanizable: true)
    public static let korean = ScriptProfile(scriptCode: "Kore", segmentation: .wordBased,
                                             maxCharsPerLine: 20, maxReadingRate: 12,
                                             isRightToLeft: false, romanizable: true)
    public static let thai   = ScriptProfile(scriptCode: "Thai", segmentation: .characterBased,
                                             maxCharsPerLine: 30, maxReadingRate: 14,
                                             isRightToLeft: false, romanizable: true)
    public static let arabic = ScriptProfile(scriptCode: "Arab", segmentation: .wordBased,
                                             maxCharsPerLine: 40, maxReadingRate: 16,
                                             isRightToLeft: true, romanizable: true)
    public static let hebrew = ScriptProfile(scriptCode: "Hebr", segmentation: .wordBased,
                                             maxCharsPerLine: 40, maxReadingRate: 16,
                                             isRightToLeft: true, romanizable: true)
    public static let cyrillic = ScriptProfile(scriptCode: "Cyrl", segmentation: .wordBased,
                                               maxCharsPerLine: 40, maxReadingRate: 16,
                                               isRightToLeft: false, romanizable: true)
    public static let greek  = ScriptProfile(scriptCode: "Grek", segmentation: .wordBased,
                                             maxCharsPerLine: 40, maxReadingRate: 16,
                                             isRightToLeft: false, romanizable: true)

    /// Resolve a profile from a BCP-47 language tag.
    public static func forLanguage(_ tag: String) -> ScriptProfile {
        let lang = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        // Explicit script subtag wins.
        if tag.lowercased().contains("-latn") { return .latin }
        switch lang {
        case "hi", "mr", "ne", "sa", "kok", "bho": return .devanagari
        case "bn", "as":       return ScriptProfile(scriptCode: "Beng", segmentation: .wordBased, maxCharsPerLine: 38, maxReadingRate: 15, isRightToLeft: false, romanizable: true)
        case "gu":             return ScriptProfile(scriptCode: "Gujr", segmentation: .wordBased, maxCharsPerLine: 38, maxReadingRate: 15, isRightToLeft: false, romanizable: true)
        case "pa":             return ScriptProfile(scriptCode: "Guru", segmentation: .wordBased, maxCharsPerLine: 38, maxReadingRate: 15, isRightToLeft: false, romanizable: true)
        case "ta":             return ScriptProfile(scriptCode: "Taml", segmentation: .wordBased, maxCharsPerLine: 36, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        case "te":             return ScriptProfile(scriptCode: "Telu", segmentation: .wordBased, maxCharsPerLine: 36, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        case "kn":             return ScriptProfile(scriptCode: "Knda", segmentation: .wordBased, maxCharsPerLine: 36, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        case "ml":             return ScriptProfile(scriptCode: "Mlym", segmentation: .wordBased, maxCharsPerLine: 36, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        case "si":             return ScriptProfile(scriptCode: "Sinh", segmentation: .wordBased, maxCharsPerLine: 36, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        case "ur", "fa", "ps", "sd": return .arabic
        case "ar":             return .arabic
        case "he", "yi":       return .hebrew
        case "ja":             return .japanese
        case "zh", "yue", "wuu": return .cjk
        case "ko":             return .korean
        case "th", "lo":       return .thai
        case "my":             return ScriptProfile(scriptCode: "Mymr", segmentation: .characterBased, maxCharsPerLine: 30, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        case "km":             return ScriptProfile(scriptCode: "Khmr", segmentation: .characterBased, maxCharsPerLine: 30, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        case "ru", "uk", "bg", "sr", "mk", "be", "kk", "ky", "mn": return .cyrillic
        case "el":             return .greek
        case "am", "ti":       return ScriptProfile(scriptCode: "Ethi", segmentation: .wordBased, maxCharsPerLine: 36, maxReadingRate: 14, isRightToLeft: false, romanizable: true)
        default:               return .latin
        }
    }
}
