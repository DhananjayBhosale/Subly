import SublyCaptions
import SublyEngine

/// What each kind of subtitle is called, in one place.
///
/// The "English letters" output was named differently on each screen ("Hinglish",
/// "Marathi in English letters", "ROMAN", "romanized"), and only Hindi had an example,
/// so a Marathi speaker had no way to tell it was the option they wanted.
enum OutputLabels {
    /// A short sentence in each language, so every option can show what it produces.
    private static let samples: [String: (native: String, latin: String)] = [
        "hi": ("\u{0906}\u{092A} \u{0915}\u{0948}\u{0938}\u{0947} \u{0939}\u{0948}\u{0902}", "aap kaise hain"),
        "mr": ("\u{0924}\u{0941}\u{092E}\u{094D}\u{0939}\u{0940} \u{0915}\u{0938}\u{0947} \u{0906}\u{0939}\u{093E}\u{0924}", "tumhi kase aahat"),
    ]

    static func title(_ kind: OutputKind, languageCode code: String, target: String) -> String {
        let name = CapabilityRegistry.displayName(code)
        switch kind {
        case .romanized:
            return code == "hi" ? "Hinglish (Hindi in English letters)" : "\(name) in English letters"
        case .original:
            // Named as the track will be named in the editor, with the script spelled out.
            return ScriptProfile.forLanguage(code).romanizable ? "\(name) transcript (\(name) script)" : "\(name) transcript"
        case .translation:
            return "\(CapabilityRegistry.displayName(target)) translation"
        }
    }

    /// - Parameter keepsEnglishSpelling: true when the chosen speech recognition writes
    ///   English letters straight from the audio (Apex). Otherwise the text is written
    ///   in the language's own script first and spelled out afterwards, which turns an
    ///   English word like "crease" into "kreejee" — so it must not be promised.
    static func example(_ kind: OutputKind, languageCode code: String, target: String,
                        keepsEnglishSpelling: Bool = false) -> String {
        let name = CapabilityRegistry.displayName(code)
        let sample = samples[code]
        switch kind {
        case .romanized:
            let shown = sample.map { "\u{201C}\($0.latin)\u{201D}. " } ?? ""
            let english = keepsEnglishSpelling
                ? " English words stay spelled as English."
                : code == "hi" ? " For English words spelled correctly, use Apex." : ""
            return "\(shown)\(name) words spelled in English letters. Not translated.\(english)"
        case .original:
            if let sample { return "\u{201C}\(sample.native)\u{201D}. The words as spoken, in \(name) script." }
            return "The words as spoken, written in \(name)."
        case .translation:
            let targetName = CapabilityRegistry.displayName(target)
            if sample != nil, target == "en" { return "\u{201C}how are you\u{201D}. The meaning, rewritten in English." }
            return "The meaning, rewritten in \(targetName)."
        }
    }

    /// The short name on a choice card: "Hinglish", "Hindi", "English translation".
    static func cardTitle(_ kind: OutputKind, languageCode code: String, target: String) -> String {
        let name = CapabilityRegistry.displayName(code)
        switch kind {
        case .romanized:   return code == "hi" ? "Hinglish" : "\(name) in English letters"
        case .original:    return name
        case .translation: return "\(CapabilityRegistry.displayName(target)) translation"
        }
    }

    /// A few words under the title, only where the card has no sample line to show.
    /// The translation card has its language menu there instead.
    static func cardSubtitle(_ kind: OutputKind, languageCode code: String) -> String? {
        switch kind {
        case .romanized:   return "Not translated"
        case .original:    return "As spoken"
        case .translation: return nil
        }
    }

    /// A sample line in the card, when there is one for the language.
    static func cardSample(_ kind: OutputKind, languageCode code: String, target: String) -> String? {
        guard let sample = samples[code] else { return nil }
        switch kind {
        case .romanized:   return sample.latin
        case .original:    return sample.native
        case .translation: return target == "en" ? "how are you" : nil
        }
    }

    /// The badge on the video preview.
    static func badge(for track: SubtitleTrack) -> String {
        // Words, not codes: "HI" and "EN" next to "HINGLISH" mixed two systems.
        let code = track.languageTag.split(separator: "-").first.map(String.init) ?? track.languageTag
        let name = CapabilityRegistry.displayName(code).uppercased()
        switch track.kind {
        case .translation: return name
        case .romanized:   return code == "hi" ? "HINGLISH" : "\(name) · ENGLISH LETTERS"
        case .original:    return track.isReference ? "IMPORTED" : name
        }
    }
}
