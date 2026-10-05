import SwiftUI
import SublyCaptions

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`; anything unreadable falls back to white.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let value = UInt64(s, radix: 16) ?? 0xFFFFFF
        let hasAlpha = s.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// `#RRGGBBAA`, for storing a colour chosen in a ColorPicker.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func c(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", c(ns.redComponent), c(ns.greenComponent),
                      c(ns.blueComponent), c(ns.alphaComponent))
    }
}

extension CaptionStyle {
    func font(size: CGFloat) -> SwiftUI.Font {
        let weight: SwiftUI.Font.Weight = bold ? (font == .condensed ? .black : .bold) : .medium
        switch font {
        case .system:    return .system(size: size, weight: weight)
        case .rounded:   return .system(size: size, weight: weight, design: .rounded)
        case .serif:     return .system(size: size, weight: weight, design: .serif)
        case .condensed: return .system(size: size, weight: weight).width(.condensed)
        }
    }
}

/// A caption drawn in a style, at a moment in its life. The preview draws this every
/// frame; the burned-in export uses the same `CaptionAnimationTiming`, so what you see
/// here is what the exported video shows.
struct StyledCaption: View {
    let text: String
    let style: CaptionStyle
    let fontSize: CGFloat
    /// Seconds since the caption appeared, and how long it lasts.
    let elapsed: Double
    let duration: Double
    /// When each word is spoken, relative to the caption's start. Nil draws the caption
    /// whole, with no per-word effect — used for a translation, whose words do not
    /// line up with the speech, so lighting them up one by one would be wrong.
    var words: [CaptionAnimationTiming.Word]? = nil
    /// False when the export applies the entrance itself; drawing it here too baked a
    /// half-faded copy into the picture of short captions.
    var applyTransform = true

    private var shown: String { style.display(text) }

    /// Condensed, extra-heavy type suits English letters but squeezes Devanagari and
    /// other scripts until the letters collide, so those get the standard width.
    private var effectiveStyle: CaptionStyle {
        guard style.font == .condensed,
              text.unicodeScalars.contains(where: { !$0.isASCII && CharacterSet.letters.contains($0) })
        else { return style }
        var s = style
        s.font = .system
        return s
    }

    var body: some View {
        let t = applyTransform
            ? CaptionAnimationTiming.transform(style.animation, elapsed: elapsed, duration: duration)
            : (opacity: 1, scale: 1, offset: 0)
        decorated
            .scaleEffect(t.scale)
            .offset(y: t.offset * fontSize)
            .opacity(t.opacity)
    }

    @ViewBuilder
    private var decorated: some View {
        switch style.background {
        case .none:
            styledText(uniform: nil)
        case .shadow:
            styledText(uniform: nil)
                .shadow(color: .black.opacity(0.9), radius: fontSize * 0.08, y: fontSize * 0.04)
        case .outline:
            // SwiftUI has no text stroke. Eight offset copies in black behind the text
            // give a clean outline at caption sizes, and cost nothing noticeable.
            let w = max(1, fontSize * 0.06)
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let angle = Double(i) * .pi / 4
                    styledText(uniform: .black)
                        .offset(x: cos(angle) * w, y: sin(angle) * w)
                }
                styledText(uniform: nil)
            }
        case .box:
            styledText(uniform: nil)
                .padding(.horizontal, fontSize * 0.4)
                .padding(.vertical, fontSize * 0.18)
                .background(Color(hex: style.boxColor),
                            in: RoundedRectangle(cornerRadius: fontSize * 0.25, style: .continuous))
        }
    }

    /// The text, one colour per word when the animation needs it. `uniform` paints every
    /// word one colour (the outline copies) while keeping the identical layout.
    private func styledText(uniform: Color?) -> some View {
        coloured(uniform: uniform)
            .font(effectiveStyle.font(size: fontSize))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func coloured(uniform: Color?) -> Text {
        let base = Color(hex: style.textColor)
        guard style.animation.isPerWord, let words else {
            return Text(shown).foregroundStyle(uniform ?? base)
        }
        var index = 0
        var result = Text("")
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false)
        for (l, line) in lines.enumerated() {
            if l > 0 { result = result + Text("\n") }
            let tokens = line.split(separator: " ")
            for (k, token) in tokens.enumerated() {
                if k > 0 { result = result + Text(" ") }
                let word = index < words.count ? words[index] : nil
                index += 1
                let spoken = (word?.start ?? 0) <= elapsed
                let current = word.map { elapsed >= $0.start && elapsed < $0.end } ?? false
                var colour = uniform ?? base
                switch style.animation {
                case .wordHighlight where uniform == nil && current:
                    colour = Color(hex: style.highlightColor)
                case .typewriter where !spoken:
                    colour = .clear      // keeps the layout still while words appear
                default:
                    break
                }
                result = result + Text(String(token)).foregroundStyle(colour)
            }
        }
        return result
    }
}
