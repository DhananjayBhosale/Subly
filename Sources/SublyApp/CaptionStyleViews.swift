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

/// Fonts shipped inside Subly.app, in Contents/Resources/Fonts. They are registered
/// for this process only, the first time a caption asks for one.
enum CaptionFonts {
    static let instrumentSerifRegular = "InstrumentSerif-Regular"
    static let instrumentSerifItalic = "InstrumentSerif-Italic"

    /// False when the fonts are not in the bundle (a `swift run` build); captions then
    /// use the system serif instead.
    static let hasInstrumentSerif: Bool = {
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
           let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
        return NSFont(name: instrumentSerifItalic, size: 12) != nil
            && NSFont(name: instrumentSerifRegular, size: 12) != nil
    }()
}

extension CaptionStyle {
    func font(size: CGFloat) -> SwiftUI.Font {
        let weight: SwiftUI.Font.Weight = bold ? (font == .condensed ? .black : .bold) : .medium
        let result: SwiftUI.Font
        switch font {
        case .system:    result = .system(size: size, weight: weight)
        case .rounded:   result = .system(size: size, weight: weight, design: .rounded)
        case .serif:     result = .system(size: size, weight: weight, design: .serif)
        case .condensed: result = .system(size: size, weight: weight).width(.condensed)
        case .instrumentSerif:
            // One weight only, so Bold is ignored. Fixed size: the export draws at an
            // exact pixel size.
            if CaptionFonts.hasInstrumentSerif {
                return .custom(italic ? CaptionFonts.instrumentSerifItalic : CaptionFonts.instrumentSerifRegular,
                               fixedSize: size)
            }
            result = .system(size: size, weight: .regular, design: .serif)
        }
        return italic ? result.italic() : result
    }

    /// The text's paint: the gradient's colours, or the one text colour.
    var textFill: [Color] { (textGradient ?? [textColor]).map(Color.init(hex:)) }

    /// The box's paint, solid or a gradient left to right.
    var boxFill: AnyShapeStyle {
        guard let boxGradient else { return AnyShapeStyle(Color(hex: boxColor)) }
        return AnyShapeStyle(LinearGradient(colors: boxGradient.map(Color.init(hex:)),
                                            startPoint: .leading, endPoint: .trailing))
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
    /// Export only: draw nothing but this word's fill, without box, outline or shadow,
    /// in the same layout. The export lays these over a picture of the faded caption
    /// and reveals each one as its word is said.
    var onlyWord: Int? = nil
    /// Export only: told where each word was drawn.
    var probe: CaptionRunProbe? = nil

    private var shown: String { style.display(text) }

    /// Gradient text and "Fill each word" are painted by `CaptionTextRenderer`. Every
    /// other look keeps plain coloured text.
    private var usesRenderer: Bool { style.textGradient != nil || style.animation == .wordFill }

    /// Where the text starts inside the caption, from its top left.
    static func textInset(_ style: CaptionStyle, fontSize: CGFloat) -> CGSize {
        style.background == .box ? CGSize(width: fontSize * 0.4, height: fontSize * 0.18) : .zero
    }

    /// How far the drawing reaches past the caption's frame: the outline and shadow, or
    /// the wide soft shade of a word-fill caption.
    static func reach(_ style: CaptionStyle, fontSize: CGFloat) -> CGFloat {
        fontSize * (style.background == .shadow && style.animation == .wordFill ? 0.6 : 0.15)
    }

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
        let edge = Color(hex: style.edgeColor)
        // The export's word-fill pictures hold only the fill, in the same layout.
        let bare = onlyWord != nil
        switch style.background {
        case .none:
            styledText(uniform: nil)
        case .shadow where style.animation == .wordFill:
            // A wide soft shade behind the words and a close shadow under each letter,
            // both from solid copies: a faded word is as readable as a filled one, even
            // on a bright wall. They are also the part of the picture that does not
            // change, which lets the export reveal the fill on its own.
            ZStack {
                if !bare {
                    // Thin serif strokes blur to almost nothing, so the shade is made
                    // from the letters thickened first, the way the outline is drawn.
                    ZStack {
                        ForEach(0..<8, id: \.self) { i in
                            let angle = Double(i) * .pi / 4
                            styledText(uniform: edge)
                                .offset(x: cos(angle) * fontSize * 0.07, y: sin(angle) * fontSize * 0.07)
                        }
                    }
                    .blur(radius: fontSize * 0.16)
                    .opacity(0.6)
                    styledText(uniform: edge.opacity(0.9))
                        .blur(radius: fontSize * 0.04)
                        .offset(y: fontSize * 0.03)
                }
                styledText(uniform: nil)
            }
        case .shadow:
            styledText(uniform: nil)
                .shadow(color: edge.opacity(0.9), radius: fontSize * 0.08, y: fontSize * 0.04)
        case .outline:
            // SwiftUI has no text stroke. Eight offset copies behind the text give a
            // clean outline at caption sizes, and cost nothing noticeable.
            let w = max(1, fontSize * 0.06)
            ZStack {
                if !bare {
                    ForEach(0..<8, id: \.self) { i in
                        let angle = Double(i) * .pi / 4
                        styledText(uniform: edge)
                            .offset(x: cos(angle) * w, y: sin(angle) * w)
                    }
                }
                styledText(uniform: nil)
            }
        case .box:
            let inset = Self.textInset(style, fontSize: fontSize)
            styledText(uniform: nil)
                .padding(.horizontal, inset.width)
                .padding(.vertical, inset.height)
                .background(bare ? AnyShapeStyle(Color.clear) : style.boxFill,
                            in: RoundedRectangle(cornerRadius: fontSize * 0.25, style: .continuous))
        }
    }

    /// The text, one colour per word when the animation needs it. `uniform` paints every
    /// word one colour (the outline copies) while keeping the identical layout.
    @ViewBuilder
    private func styledText(uniform: Color?) -> some View {
        let text = coloured(uniform: uniform)
            .font(effectiveStyle.font(size: fontSize))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if uniform == nil, usesRenderer {
            text.textRenderer(CaptionTextRenderer(fill: style.textFill, onlyWord: onlyWord, probe: probe,
                                                  reach: fontSize * 0.5))
        } else {
            text
        }
    }

    private func coloured(uniform: Color?) -> Text {
        let base = Color(hex: style.textColor)
        // Painted by the renderer: the gradient, and each word's fill.
        let painted = uniform == nil && usesRenderer
        guard style.needsWordTimes, let words else {
            let whole = Text(shown).foregroundStyle(uniform ?? base)
            return painted ? whole.customAttribute(CaptionWordRun(index: 0, fill: 1, baseOpacity: 1)) : whole
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
                let i = index
                index += 1
                let spoken = (word?.start ?? 0) <= elapsed
                let current = word.map { elapsed >= $0.start && elapsed < $0.end } ?? false
                var colour = uniform ?? base
                var run: CaptionWordRun? = painted ? CaptionWordRun(index: i, fill: 1, baseOpacity: 1) : nil
                if style.animation == .typewriter, !spoken {
                    colour = .clear      // keeps the layout still while words appear
                    run = nil
                } else if style.animation == .wordFill, painted {
                    // Faded until said, then filled left to right while it is said.
                    let fill = word.map { CaptionAnimationTiming.fillProgress($0, elapsed: elapsed) } ?? 1
                    run = CaptionWordRun(index: i, fill: fill, baseOpacity: CaptionAnimationTiming.unspokenOpacity)
                } else if uniform == nil, current, style.highlightsCurrentWord {
                    colour = Color(hex: style.highlightColor)
                    run = nil
                }
                var piece = Text(String(token)).foregroundStyle(colour)
                if let run { piece = piece.customAttribute(run) }
                result = result + piece
            }
        }
        return result
    }
}

// MARK: - Gradient text and word fill

/// Marks a word for `CaptionTextRenderer`: how much of it is filled (0–1) and how
/// strongly the rest of it shows.
struct CaptionWordRun: TextAttribute {
    var index: Int
    var fill: Double
    var baseOpacity: Double
}

/// Where each word's glyphs were drawn, in the text's own coordinates. The export
/// uses it to reveal each word's fill at the moment the preview fills it.
final class CaptionRunProbe: @unchecked Sendable {
    struct Run {
        var word: Int
        var rect: CGRect
        var rightToLeft: Bool
    }
    var runs: [Run] = []
}

/// Paints marked words with the caption's fill, solid or a gradient across the whole
/// caption, and fills each word from where reading starts as it is said. Unmarked text
/// (spaces, a highlighted word) is drawn as it is.
struct CaptionTextRenderer: TextRenderer {
    var fill: [Color]
    var onlyWord: Int?
    var probe: CaptionRunProbe?
    /// How far glyphs may reach outside their line, for italic tails. Not given to
    /// SwiftUI as `displayPadding`: ImageRenderer shifts the whole drawing right by it,
    /// which pushed the export's captions off centre and cut their last letter.
    var reach: CGFloat

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let bounds = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        guard !bounds.isNull else { return }
        let shading: GraphicsContext.Shading = fill.count > 1
            ? .linearGradient(Gradient(colors: fill), startPoint: CGPoint(x: bounds.minX, y: bounds.midY),
                              endPoint: CGPoint(x: bounds.maxX, y: bounds.midY))
            : .color(fill.first ?? .white)
        let everywhere = Path(bounds.insetBy(dx: -reach * 2, dy: -reach * 2))
        probe?.runs.removeAll()
        for line in layout {
            for run in line {
                guard let word = run[CaptionWordRun.self] else {
                    if onlyWord == nil { ctx.draw(run) }
                    continue
                }
                let rect = run.typographicBounds.rect
                let rightToLeft = run.layoutDirection == .rightToLeft
                probe?.runs.append(.init(word: word.index, rect: rect, rightToLeft: rightToLeft))
                if let onlyWord, onlyWord != word.index { continue }
                if onlyWord == nil, word.fill < 1, word.baseOpacity > 0 {
                    var faded = ctx
                    faded.opacity = word.baseOpacity
                    faded.draw(run)
                }
                guard word.fill > 0 else { continue }
                var paint = ctx
                if word.fill < 1 {
                    // Everything up to the fill's edge, and nothing past it.
                    let done = rect.width * word.fill
                    paint.clip(to: Path(CGRect(x: rightToLeft ? rect.maxX - done : rect.minX - reach * 2,
                                               y: rect.minY - reach * 2,
                                               width: done + reach * 2, height: rect.height + reach * 4)))
                }
                paint.clipToLayer { $0.draw(run) }
                paint.fill(everywhere, with: shading)
            }
        }
    }
}
