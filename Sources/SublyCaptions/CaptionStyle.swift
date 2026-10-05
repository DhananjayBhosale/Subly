import Foundation

/// How captions look on the picture: in the preview and in a video exported with the
/// captions burned in. Subtitle files (SRT, VTT) cannot carry any of this; it only
/// reaches viewers through a burned-in video, which is what Reels and Shorts need.
///
/// Sizes and positions are fractions of the video frame, not points, so the preview at
/// any window size and the exported 1080p or 4K video look the same.
public struct CaptionStyle: Codable, Sendable, Hashable {

    public enum Template: String, Codable, Sendable, CaseIterable, Identifiable {
        case clean, boldPop, karaoke, boxed, minimal, typewriter
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .clean:      return "Clean"
            case .boldPop:    return "Bold Pop"
            case .karaoke:    return "Karaoke"
            case .boxed:      return "Boxed"
            case .minimal:    return "Minimal"
            case .typewriter: return "Typewriter"
            }
        }
        /// One line on what it is for, shown under the picker.
        public var summary: String {
            switch self {
            case .clean:      return "White text on a soft dark box. Readable on anything."
            case .boldPop:    return "Big outlined capitals that pop in. Classic Reels style."
            case .karaoke:    return "Each word lights up as it is spoken."
            case .boxed:      return "Solid black box that slides up. Very high contrast."
            case .minimal:    return "Plain white with a shadow, fading in and out."
            case .typewriter: return "Words appear one by one as they are spoken."
            }
        }
    }

    public enum Font: String, Codable, Sendable, CaseIterable, Identifiable {
        case system, rounded, serif, condensed
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .system:    return "Standard"
            case .rounded:   return "Rounded"
            case .serif:     return "Serif"
            case .condensed: return "Condensed"
            }
        }
    }

    public enum Background: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, shadow, outline, box
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .none:    return "None"
            case .shadow:  return "Shadow"
            case .outline: return "Outline"
            case .box:     return "Box"
            }
        }
    }

    public enum Animation: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, fade, pop, slideUp, wordHighlight, typewriter
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .none:          return "None"
            case .fade:          return "Fade"
            case .pop:           return "Pop"
            case .slideUp:       return "Slide up"
            case .wordHighlight: return "Highlight each word"
            case .typewriter:    return "Word by word"
            }
        }
        /// True when the animation needs to know when each word is spoken.
        public var isPerWord: Bool { self == .wordHighlight || self == .typewriter }
    }

    public var template: Template
    public var font: Font
    public var bold: Bool
    /// Text height as a fraction of the frame's shorter side.
    public var size: Double
    /// `#RRGGBB` or `#RRGGBBAA`.
    public var textColor: String
    public var highlightColor: String
    public var boxColor: String
    public var background: Background
    /// Where the middle of the caption sits, from 0 (top) to 1 (bottom).
    public var position: Double
    public var uppercase: Bool
    public var animation: Animation

    public init(template: Template, font: Font, bold: Bool, size: Double, textColor: String,
                highlightColor: String, boxColor: String, background: Background,
                position: Double, uppercase: Bool, animation: Animation) {
        self.template = template; self.font = font; self.bold = bold; self.size = size
        self.textColor = textColor; self.highlightColor = highlightColor; self.boxColor = boxColor
        self.background = background; self.position = position
        self.uppercase = uppercase; self.animation = animation
    }

    public static let `default` = preset(.clean)

    private enum CodingKeys: String, CodingKey {
        case template, font, bold, size, textColor, highlightColor, boxColor, background, position, uppercase, animation
    }

    /// Each setting falls back to the Clean look on its own. A style saved by a newer
    /// Subly — a template or animation this one doesn't know — used to make the whole
    /// project unreadable, and it disappeared from the list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = CaptionStyle.preset(.clean)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        template = value(.template, base.template)
        font = value(.font, base.font)
        bold = value(.bold, base.bold)
        size = value(.size, base.size)
        textColor = value(.textColor, base.textColor)
        highlightColor = value(.highlightColor, base.highlightColor)
        boxColor = value(.boxColor, base.boxColor)
        background = value(.background, base.background)
        position = value(.position, base.position)
        uppercase = value(.uppercase, base.uppercase)
        animation = value(.animation, base.animation)
    }

    /// Where captions can sit. Reels, Shorts and TikTok cover roughly the bottom fifth
    /// with the account name, description and buttons, so templates start above it.
    public static let reelsCoveredFrom = 0.80

    /// The centre position that keeps a stack of `stackHeight` (a fraction of the
    /// frame) fully on screen. Clamping the centre alone let a tall three-track stack
    /// run off the bottom of the picture.
    public static func clampedCentre(_ position: Double, stackHeight: Double) -> Double {
        let half = min(0.45, max(0, stackHeight) / 2)
        return min(0.98 - half, max(0.02 + half, position))
    }

    public static func preset(_ template: Template) -> CaptionStyle {
        switch template {
        case .clean:
            return CaptionStyle(template: .clean, font: .system, bold: true, size: 0.045,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#00000099",
                                background: .box, position: 0.70, uppercase: false, animation: .fade)
        case .boldPop:
            return CaptionStyle(template: .boldPop, font: .condensed, bold: true, size: 0.065,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .outline, position: 0.70, uppercase: true, animation: .pop)
        case .karaoke:
            return CaptionStyle(template: .karaoke, font: .rounded, bold: true, size: 0.055,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .outline, position: 0.72, uppercase: false, animation: .wordHighlight)
        case .boxed:
            return CaptionStyle(template: .boxed, font: .system, bold: true, size: 0.048,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#000000F0",
                                background: .box, position: 0.70, uppercase: false, animation: .slideUp)
        case .minimal:
            return CaptionStyle(template: .minimal, font: .system, bold: true, size: 0.046,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#00000099",
                                background: .shadow, position: 0.72, uppercase: false, animation: .fade)
        case .typewriter:
            // Outlined, not boxed: a box is drawn at full size from the first word, so
            // early in each caption it was a big empty panel with two words in a corner.
            return CaptionStyle(template: .typewriter, font: .serif, bold: true, size: 0.05,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#000000B3",
                                background: .outline, position: 0.70, uppercase: false, animation: .typewriter)
        }
    }

    /// The caption text as it will be drawn.
    public func display(_ text: String) -> String { uppercase ? text.uppercased() : text }
}

// MARK: - Animation timing

/// Where an animated caption is at a moment. Shared by the preview and the export so
/// the two cannot disagree.
public enum CaptionAnimationTiming {
    public static let inDuration = 0.18
    public static let outDuration = 0.15

    public struct Word: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) {
            self.text = text; self.start = start; self.end = end
        }
    }

    /// When each word of a caption is spoken. Edited text no longer maps back to the
    /// recogniser's word times, so the caption's span is shared out by word length —
    /// longer words take longer to say — which tracks speech closely at caption scale.
    public static func words(in text: String, start: Double, end: Double) -> [Word] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty, end > start else { return [] }
        let weights = tokens.map { Double(max(2, $0.count)) }
        let total = weights.reduce(0, +)
        var t = start
        return zip(tokens, weights).map { token, weight in
            let span = (end - start) * weight / total
            defer { t += span }
            return Word(text: token, start: t, end: t + span)
        }
    }

    /// Opacity, scale and vertical offset (as a fraction of the text height) for an
    /// animation `elapsed` seconds into a caption lasting `duration`.
    public static func transform(_ animation: CaptionStyle.Animation, elapsed: Double,
                                 duration: Double) -> (opacity: Double, scale: Double, offset: Double) {
        let fadeIn = min(1, max(0, elapsed / inDuration))
        let fadeOut = min(1, max(0, (duration - elapsed) / outDuration))
        switch animation {
        case .none, .wordHighlight, .typewriter:
            return (1, 1, 0)
        case .fade:
            return (min(fadeIn, fadeOut), 1, 0)
        case .pop:
            // Overshoot to 1.08, then settle: reads as a pop, not a zoom.
            let p = fadeIn
            let scale = p < 0.7 ? 0.7 + (1.08 - 0.7) * (p / 0.7) : 1.08 - 0.08 * ((p - 0.7) / 0.3)
            return (min(1, p * 2), scale, 0)
        case .slideUp:
            let eased = 1 - pow(1 - fadeIn, 3)
            return (min(fadeIn * 1.5, fadeOut), 1, 0.6 * (1 - eased))
        }
    }
}
