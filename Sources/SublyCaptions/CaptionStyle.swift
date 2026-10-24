import Foundation

/// How captions look on the picture: in the preview and in a video exported with the
/// captions burned in. Subtitle files (SRT, VTT) cannot carry any of this; it only
/// reaches viewers through a burned-in video, which is what Reels and Shorts need.
///
/// Sizes and positions are fractions of the video frame, not points, so the preview at
/// any window size and the exported 1080p or 4K video look the same.
public struct CaptionStyle: Codable, Sendable, Hashable {

    public enum Template: String, Codable, Sendable, CaseIterable, Identifiable {
        case clean, boldPop, karaoke, boxed, minimal, typewriter, gradientPop
        case punch, oneWord, neon, highlighter, wordBox, retro, drop, cinematic
        case handwritten, comic, terminal, headline, glitch, candy, rainbow
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .clean:      return "Clean"
            case .boldPop:    return "Bold Pop"
            case .karaoke:    return "Karaoke"
            case .boxed:      return "Boxed"
            case .minimal:    return "Minimal"
            case .typewriter: return "Typewriter"
            case .gradientPop: return "Gradient Pop"
            case .punch:       return "Punch"
            case .oneWord:     return "One Word"
            case .neon:        return "Neon"
            case .highlighter: return "Highlighter"
            case .wordBox:     return "Word Box"
            case .retro:       return "Retro"
            case .drop:        return "Drop"
            case .cinematic:   return "Cinematic"
            case .handwritten: return "Handwritten"
            case .comic:       return "Comic"
            case .terminal:    return "Terminal"
            case .headline:    return "Headline"
            case .glitch:      return "Glitch"
            case .candy:       return "Candy"
            case .rainbow:     return "Rainbow"
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
            case .gradientPop: return "Serif italic words fill with colour as they are spoken."
            case .punch:       return "Heavy capitals that zoom in fast, the spoken word in yellow."
            case .oneWord:     return "One huge word at a time, in step with the speech."
            case .neon:        return "A glowing pink sign that flickers on."
            case .highlighter: return "Dark text on a yellow marker stripe that slides in."
            case .wordBox:     return "A purple box jumps from word to word as each is spoken."
            case .retro:       return "Warm capitals with a hard orange shadow that pop in."
            case .drop:        return "Yellow outlined text that drops in and bounces."
            case .cinematic:   return "Wide-spaced small capitals that fade in slowly, like film titles."
            case .handwritten: return "Marker lettering that tilts into place."
            case .comic:       return "Black lettering on a white speech box that pops up."
            case .terminal:    return "Green computer text typed word by word on a dark screen."
            case .headline:    return "Capitals on a red news banner that slides in from the side."
            case .glitch:      return "Capitals with a cyan and pink split that shake in."
            case .candy:       return "White text on a pink and purple box that pops in fast."
            case .rainbow:     return "Rainbow-coloured text that bounces in."
            }
        }
    }

    public enum Font: String, Codable, Sendable, CaseIterable, Identifiable {
        case system, rounded, serif, condensed, instrumentSerif
        case monospaced, avenirNext, futura, impact, markerFelt, chalkboard
        case americanTypewriter, didot, georgia, rockwell, copperplate
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .system:          return "Standard"
            case .rounded:         return "Rounded"
            case .serif:           return "Serif"
            case .condensed:       return "Condensed"
            case .instrumentSerif: return "Instrument Serif"
            case .monospaced:      return "Monospaced"
            case .avenirNext:      return "Avenir Next"
            case .futura:          return "Futura"
            case .impact:          return "Impact"
            case .markerFelt:      return "Marker Felt"
            case .chalkboard:      return "Chalkboard"
            case .americanTypewriter: return "American Typewriter"
            case .didot:           return "Didot"
            case .georgia:         return "Georgia"
            case .rockwell:        return "Rockwell"
            case .copperplate:     return "Copperplate"
            }
        }
        /// Instrument Serif and Impact come in one weight, so Bold does nothing for them.
        public var hasBold: Bool { self != .instrumentSerif && self != .impact }
    }

    public enum Background: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, shadow, outline, box, glow, offsetShadow, highlighter, splitColour
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .none:    return "None"
            case .shadow:  return "Shadow"
            case .outline: return "Outline"
            case .box:     return "Box"
            case .glow:    return "Glow"
            case .offsetShadow: return "Offset shadow"
            case .highlighter:  return "Marker"
            case .splitColour:  return "Split colour"
            }
        }
    }

    public enum Animation: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, fade, pop, slideUp, wordHighlight, typewriter, wordFill
        case slideIn, zoomIn, bounce, drop, tilt, flicker, shake, wordBox, oneWord
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .none:          return "None"
            case .fade:          return "Fade"
            case .pop:           return "Pop"
            case .slideUp:       return "Slide up"
            case .wordHighlight: return "Highlight each word"
            case .typewriter:    return "Word by word"
            case .wordFill:      return "Fill each word"
            case .slideIn:       return "Slide in"
            case .zoomIn:        return "Zoom in"
            case .bounce:        return "Bounce"
            case .drop:          return "Drop"
            case .tilt:          return "Tilt in"
            case .flicker:       return "Flicker"
            case .shake:         return "Shake"
            case .wordBox:       return "Box each word"
            case .oneWord:       return "One word at a time"
            }
        }
        /// True when the animation needs to know when each word is spoken.
        public var isPerWord: Bool {
            self == .wordHighlight || self == .typewriter || self == .wordFill || self == .wordBox || self == .oneWord
        }
        /// The whole caption comes in as one: these have an entrance, and Speed sets how
        /// long it takes.
        public var isEntrance: Bool {
            switch self {
            case .fade, .pop, .slideUp, .slideIn, .zoomIn, .bounce, .drop, .tilt, .flicker, .shake: return true
            case .none, .wordHighlight, .typewriter, .wordFill, .wordBox, .oneWord: return false
            }
        }
        /// True when the caption moves or changes size, which Reduce Motion replaces
        /// with a fade.
        public var moves: Bool {
            switch self {
            case .pop, .slideUp, .slideIn, .zoomIn, .bounce, .drop, .tilt, .shake, .flicker: return true
            case .none, .fade, .wordHighlight, .typewriter, .wordFill, .wordBox, .oneWord: return false
            }
        }
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
    public var italic: Bool
    /// Two or more `#RRGGBB(AA)` colours painted left to right across the caption,
    /// in place of `textColor`. Nil is one solid colour. With "Fill each word",
    /// `textColor` is still the colour of the words not yet spoken.
    public var textGradient: [String]?
    /// The same for the box behind the text, in place of `boxColor`.
    public var boxGradient: [String]?
    /// The word being spoken is drawn in `highlightColor`, whatever the animation.
    /// Karaoke ("Highlight each word") always does this.
    public var highlightsSpokenWord: Bool
    /// The colour of the outline, shadow, glow and offset shadow.
    public var edgeColor: String
    /// How fast whole-caption entrances play: 0.5 is Slow, 1 Normal, 1.8 Fast. It
    /// divides the entrance and exit times.
    public var animationSpeed: Double
    /// Space between letters, as a fraction of the text size.
    public var tracking: Double
    /// How thick the outline, shadow, glow, offset shadow and split colour are, as a
    /// multiple of their usual thickness.
    public var edgeWidth: Double

    public static let trackingRange = -0.05...0.3
    public static let edgeWidthRange = 0.5...2.5

    public init(template: Template, font: Font, bold: Bool, size: Double, textColor: String,
                highlightColor: String, boxColor: String, background: Background,
                position: Double, uppercase: Bool, animation: Animation,
                italic: Bool = false, textGradient: [String]? = nil, boxGradient: [String]? = nil,
                highlightsSpokenWord: Bool = false, edgeColor: String = "#000000",
                animationSpeed: Double = 1, tracking: Double = 0, edgeWidth: Double = 1) {
        self.template = template; self.font = font; self.bold = bold; self.size = size
        self.textColor = textColor; self.highlightColor = highlightColor; self.boxColor = boxColor
        self.background = background; self.position = position
        self.uppercase = uppercase; self.animation = animation
        self.italic = italic; self.textGradient = textGradient; self.boxGradient = boxGradient
        self.highlightsSpokenWord = highlightsSpokenWord; self.edgeColor = edgeColor
        self.animationSpeed = animationSpeed; self.tracking = tracking; self.edgeWidth = edgeWidth
    }

    public static let `default` = preset(.clean)

    private enum CodingKeys: String, CodingKey {
        case template, font, bold, size, textColor, highlightColor, boxColor, background, position, uppercase, animation
        case italic, textGradient, boxGradient, highlightsSpokenWord, edgeColor
        case animationSpeed, tracking, edgeWidth
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
        // Newer settings. Older projects have none of these and keep looking as they did.
        italic = value(.italic, base.italic)
        textGradient = Self.validGradient(value(.textGradient, base.textGradient))
        boxGradient = Self.validGradient(value(.boxGradient, base.boxGradient))
        highlightsSpokenWord = value(.highlightsSpokenWord, base.highlightsSpokenWord)
        edgeColor = value(.edgeColor, base.edgeColor)
        let speed = value(.animationSpeed, base.animationSpeed)
        animationSpeed = speed > 0 && speed.isFinite ? speed : base.animationSpeed
        tracking = min(Self.trackingRange.upperBound, max(Self.trackingRange.lowerBound, value(.tracking, base.tracking)))
        edgeWidth = min(Self.edgeWidthRange.upperBound, max(Self.edgeWidthRange.lowerBound, value(.edgeWidth, base.edgeWidth)))
    }

    /// A gradient needs at least two colours; anything less is drawn solid.
    private static func validGradient(_ colours: [String]?) -> [String]? {
        guard let colours, colours.count >= 2 else { return nil }
        return colours
    }

    /// True when the preview and the export need to know when each word is spoken.
    public var needsWordTimes: Bool { animation.isPerWord || highlightsSpokenWord }

    /// True when the spoken word is drawn in the highlight colour. "Fill each word"
    /// already marks the spoken word by filling it, so it is never highlighted too.
    /// "Box each word" draws its box in the highlight colour, so recolouring the word
    /// the same colour would hide it; "One word at a time" shows only the spoken word.
    public var highlightsCurrentWord: Bool {
        animation == .wordHighlight
            || (highlightsSpokenWord && animation != .wordFill && animation != .wordBox && animation != .oneWord)
    }

    /// Ready-made gradients, a click each. Text gradients are bright so they read on
    /// footage; box gradients are deep so white text reads on them.
    public struct GradientPreset: Sendable, Hashable, Identifiable {
        public let name: String
        public let colours: [String]
        public var id: String { name }
        public init(name: String, colours: [String]) { self.name = name; self.colours = colours }
    }

    /// The first is Subly's own: the colours of the website's headline in dark mode.
    public static let textGradients: [GradientPreset] = [
        GradientPreset(name: "Subly", colours: ["#AE92FF", "#FF70C9", "#FFAD62"]),
        GradientPreset(name: "Sunset", colours: ["#FFD166", "#FF5E62"]),
        GradientPreset(name: "Ocean", colours: ["#6EE7F9", "#8B8CFF"]),
        GradientPreset(name: "Lime", colours: ["#EEFF6A", "#3DDC97"]),
        GradientPreset(name: "Gold", colours: ["#FFF3B0", "#FFB627"]),
        GradientPreset(name: "Rainbow", colours: ["#FF5E5E", "#FFB443", "#FFF05A", "#4BE37C", "#4FC3FF", "#B07CFF"]),
        GradientPreset(name: "Candy", colours: ["#FF9AD5", "#9AD0FF"]),
        GradientPreset(name: "Neon", colours: ["#00F5FF", "#FF00E5"]),
    ]

    /// The first is Subly's website headline in light mode, nearly opaque.
    public static let boxGradients: [GradientPreset] = [
        GradientPreset(name: "Subly", colours: ["#5828DCE6", "#C42A85E6", "#C75A12E6"]),
        GradientPreset(name: "Night", colours: ["#0B1023E6", "#3A1C71E6"]),
        GradientPreset(name: "Ember", colours: ["#7A1F1FE6", "#C2410CE6"]),
        GradientPreset(name: "Forest", colours: ["#063B2EE6", "#0F766EE6"]),
        GradientPreset(name: "Royal", colours: ["#1E3A8AE6", "#7C3AEDE6"]),
        GradientPreset(name: "Breaking", colours: ["#DC2626F0", "#7F1D1DF0"]),
        GradientPreset(name: "Candy", colours: ["#EC4899E6", "#8B5CF6E6"]),
    ]

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
        case .gradientPop:
            // The website's headline on the video: Instrument Serif italic, each word
            // filling with Subly's gradient as it is said. A soft shadow under every
            // word, faded or filled, keeps it readable on bright footage.
            return CaptionStyle(template: .gradientPop, font: .instrumentSerif, bold: false, size: 0.07,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#00000099",
                                background: .shadow, position: 0.70, uppercase: false, animation: .wordFill,
                                italic: true, textGradient: textGradients[0].colours)
        case .punch:
            return CaptionStyle(template: .punch, font: .impact, bold: false, size: 0.07,
                                textColor: "#FFFFFF", highlightColor: "#FFE600", boxColor: "#000000CC",
                                background: .outline, position: 0.70, uppercase: true, animation: .zoomIn,
                                highlightsSpokenWord: true, animationSpeed: 1.8, edgeWidth: 1.4)
        case .oneWord:
            return CaptionStyle(template: .oneWord, font: .futura, bold: true, size: 0.09,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .outline, position: 0.70, uppercase: true, animation: .oneWord,
                                edgeWidth: 1.6)
        case .neon:
            return CaptionStyle(template: .neon, font: .avenirNext, bold: true, size: 0.06,
                                textColor: "#FFE3F6", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .glow, position: 0.70, uppercase: false, animation: .flicker,
                                edgeColor: "#FF2BD6")
        case .highlighter:
            return CaptionStyle(template: .highlighter, font: .avenirNext, bold: true, size: 0.05,
                                textColor: "#111111", highlightColor: "#FFD60A", boxColor: "#FFE45C",
                                background: .highlighter, position: 0.70, uppercase: false, animation: .slideIn)
        case .wordBox:
            return CaptionStyle(template: .wordBox, font: .rounded, bold: true, size: 0.055,
                                textColor: "#FFFFFF", highlightColor: "#8B5CF6", boxColor: "#000000CC",
                                background: .outline, position: 0.70, uppercase: true, animation: .wordBox)
        case .retro:
            return CaptionStyle(template: .retro, font: .rockwell, bold: true, size: 0.06,
                                textColor: "#FFF4D6", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .offsetShadow, position: 0.70, uppercase: true, animation: .pop,
                                edgeColor: "#E4572E")
        case .drop:
            return CaptionStyle(template: .drop, font: .rounded, bold: true, size: 0.06,
                                textColor: "#FFE600", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .outline, position: 0.70, uppercase: false, animation: .drop)
        case .cinematic:
            // Small and wide, low in the frame, fading in slowly like a film title.
            return CaptionStyle(template: .cinematic, font: .futura, bold: false, size: 0.036,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#00000099",
                                background: .shadow, position: 0.78, uppercase: true, animation: .fade,
                                animationSpeed: 0.5, tracking: 0.25)
        case .handwritten:
            return CaptionStyle(template: .handwritten, font: .markerFelt, bold: true, size: 0.062,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#00000099",
                                background: .shadow, position: 0.70, uppercase: false, animation: .tilt)
        case .comic:
            return CaptionStyle(template: .comic, font: .chalkboard, bold: true, size: 0.05,
                                textColor: "#111111", highlightColor: "#FFD60A", boxColor: "#FFFFFFF2",
                                background: .box, position: 0.70, uppercase: true, animation: .pop)
        case .terminal:
            return CaptionStyle(template: .terminal, font: .monospaced, bold: true, size: 0.042,
                                textColor: "#39FF88", highlightColor: "#FFD60A", boxColor: "#0A0F0AE6",
                                background: .box, position: 0.70, uppercase: false, animation: .typewriter)
        case .headline:
            return CaptionStyle(template: .headline, font: .futura, bold: true, size: 0.045,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#DC2626F0",
                                background: .box, position: 0.74, uppercase: true, animation: .slideIn,
                                boxGradient: colours(boxGradients, "Breaking"))
        case .glitch:
            return CaptionStyle(template: .glitch, font: .condensed, bold: true, size: 0.062,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .splitColour, position: 0.70, uppercase: true, animation: .shake)
        case .candy:
            return CaptionStyle(template: .candy, font: .rounded, bold: true, size: 0.052,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#EC4899E6",
                                background: .box, position: 0.70, uppercase: false, animation: .pop,
                                boxGradient: colours(boxGradients, "Candy"), animationSpeed: 1.8)
        case .rainbow:
            return CaptionStyle(template: .rainbow, font: .rounded, bold: true, size: 0.06,
                                textColor: "#FFFFFF", highlightColor: "#FFD60A", boxColor: "#000000CC",
                                background: .outline, position: 0.70, uppercase: false, animation: .bounce,
                                textGradient: colours(textGradients, "Rainbow"))
        }
    }

    private static func colours(_ presets: [GradientPreset], _ name: String) -> [String] {
        (presets.first { $0.name == name } ?? presets[0]).colours
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

    /// How strongly a word not yet spoken shows with "Fill each word".
    public static let unspokenOpacity = 0.5

    /// How much of a word is filled with "Fill each word", from 0 to 1, `elapsed`
    /// seconds into the caption: empty until it is said, filling evenly left to right
    /// while it is said, full after.
    public static func fillProgress(_ word: Word, elapsed: Double) -> Double {
        guard word.end > word.start else { return elapsed >= word.start ? 1 : 0 }
        return min(1, max(0, (elapsed - word.start) / (word.end - word.start)))
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

    /// Where a whole-caption animation has put the caption: how visible, how big, how far
    /// it is shifted (in text heights, as SwiftUI counts: right and down are positive)
    /// and how far it is turned (degrees, clockwise).
    public struct Pose: Sendable, Equatable {
        public var opacity: Double
        public var scale: Double
        public var offsetX: Double
        public var offsetY: Double
        public var rotation: Double

        public init(opacity: Double = 1, scale: Double = 1, offsetX: Double = 0,
                    offsetY: Double = 0, rotation: Double = 0) {
            self.opacity = opacity; self.scale = scale
            self.offsetX = offsetX; self.offsetY = offsetY; self.rotation = rotation
        }

        public static let identity = Pose()
    }

    /// Seconds an animation takes to come in at normal speed.
    public static func entranceDuration(_ animation: CaptionStyle.Animation) -> Double {
        switch animation {
        case .slideIn: return 0.28
        case .zoomIn:  return 0.22
        case .bounce:  return 0.5
        case .drop:    return 0.45
        case .tilt:    return 0.3
        case .flicker: return 0.35
        case .shake:   return 0.3
        default:       return inDuration
        }
    }

    /// The pose for an animation `elapsed` seconds into a caption lasting `duration`.
    /// `speed` divides the entrance and exit times: 0.5 is twice as slow, 1.8 nearly twice
    /// as fast. Per-word animations (and none) leave the caption as it is.
    public static func transform(_ animation: CaptionStyle.Animation, elapsed: Double,
                                 duration: Double, speed: Double = 1) -> Pose {
        let speed = max(0.05, speed)
        let inD = entranceDuration(animation) / speed
        let outD = outDuration / speed
        let fadeIn = min(1, max(0, elapsed / inD))
        let fadeOut = min(1, max(0, (duration - elapsed) / outD))
        let p = fadeIn
        let eased = 1 - pow(1 - p, 3)
        switch animation {
        case .none, .wordHighlight, .typewriter, .wordFill, .wordBox, .oneWord:
            return .identity
        case .fade:
            return Pose(opacity: min(fadeIn, fadeOut))
        case .pop:
            // Overshoot to 1.08, then settle: reads as a pop, not a zoom.
            let scale = p < 0.7 ? 0.7 + (1.08 - 0.7) * (p / 0.7) : 1.08 - 0.08 * ((p - 0.7) / 0.3)
            return Pose(opacity: min(1, p * 2), scale: scale)
        case .slideUp:
            return Pose(opacity: min(fadeIn * 1.5, fadeOut), offsetY: 0.6 * (1 - eased))
        case .slideIn:
            return Pose(opacity: min(fadeIn * 1.5, fadeOut), offsetX: -1.2 * (1 - eased))
        case .zoomIn:
            return Pose(opacity: min(fadeIn * 2, fadeOut), scale: 1.35 - 0.35 * eased)
        case .bounce:
            return Pose(opacity: min(1, p * 3, fadeOut), offsetY: 0.8 * (1 - p) * cos(3 * .pi * p))
        case .drop:
            return Pose(opacity: min(1, p * 3, fadeOut), offsetY: -1.2 * (1 - easeOutBounce(p)))
        case .tilt:
            return Pose(opacity: min(fadeIn * 1.5, fadeOut), scale: 0.9 + 0.1 * eased, rotation: -12 * (1 - eased))
        case .flicker:
            // Sputters on in six jumps; a smooth fade would not look like a bad tube.
            let steps = [0, 0.9, 0.2, 1, 0.5, 1]
            return Pose(opacity: p < 1 ? steps[min(5, Int(p * 6))] : fadeOut)
        case .shake:
            return Pose(opacity: min(1, p * 2, fadeOut), offsetX: 0.12 * (1 - p) * sin(12 * .pi * p))
        }
    }

    /// 0 to 1, landing on 1 after a few bounces.
    private static func easeOutBounce(_ x: Double) -> Double {
        let n = 7.5625, d = 2.75
        if x < 1 / d { return n * x * x }
        if x < 2 / d { let t = x - 1.5 / d; return n * t * t + 0.75 }
        if x < 2.5 / d { let t = x - 2.25 / d; return n * t * t + 0.9375 }
        let t = x - 2.625 / d
        return n * t * t + 0.984375
    }

    /// The word being said `elapsed` seconds into a caption, as an index: the last word
    /// that has started, or the first before any has, so "one word at a time" never
    /// shows an empty caption. Nil when there are no words.
    public static func shownWord(_ words: [Word], elapsed: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        return words.lastIndex(where: { $0.start <= elapsed }) ?? 0
    }
}
