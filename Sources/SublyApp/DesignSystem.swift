import SwiftUI
import SublyCaptions

// MARK: - Layout adaptivity

/// Drives every responsive decision in the app from one place, so resizing the window
/// reflows the whole interface consistently instead of each view guessing.
public enum LayoutMode: Int, Comparable, Sendable {
    case compact   // narrow window — the editor's panel lies over the video
    case regular   // standard laptop width
    case wide      // large display — everything visible at once

    public static func < (a: LayoutMode, b: LayoutMode) -> Bool { a.rawValue < b.rawValue }

    static func mode(for width: CGFloat) -> LayoutMode {
        if width < 920 { return .compact }
        if width < 1340 { return .regular }
        return .wide
    }

    var cueGridShowsTimecodeColumn: Bool { self > .compact }
    var maxVisibleTrackColumns: Int { self == .compact ? 1 : (self == .regular ? 2 : 4) }
}

private struct LayoutModeKey: EnvironmentKey {
    static let defaultValue: LayoutMode = .regular
}

extension EnvironmentValues {
    var layoutMode: LayoutMode {
        get { self[LayoutModeKey.self] } set { self[LayoutModeKey.self] = newValue }
    }
}

/// Measures its container and publishes the layout mode downward.
///
/// Animated, so dragging the window reflows smoothly instead of snapping.
///
/// Crossing a breakpoint changes the grid's column set, and `Table` cells are hosted
/// by AppKit in their own hosting views. A cell reading `@Environment(AppModel.self)`
/// could be rebuilt before that environment was re-propagated, which trapped with
/// "No Observable object of type AppModel found" — dragging past 920pt with a project
/// open crashed the app every time. The fix is in `CueCell`, which now takes the model
/// explicitly; this animation was verified safe afterwards, twice, through all ten
/// widths with a real project loaded.
struct LayoutReader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let mode = LayoutMode.mode(for: proxy.size.width)
            content
                .environment(\.layoutMode, mode)
                .animation(Motion.layout, value: mode)
        }
    }
}

// MARK: - Metrics

enum Metrics {
    static let controlRadius: CGFloat = 8
    /// One width everywhere. It used to float between 280 and 400 depending on the
    /// project, so the same controls fitted on one video and were cut off on the next.
    static let inspectorWidth: CGFloat = 320
    static let timelineHeight: CGFloat = 132
    static let timelineCompactHeight: CGFloat = 96
}

// MARK: - Motion

/// One motion vocabulary. Interruptible springs everywhere, so a gesture or a resize
/// can redirect an in-flight animation instead of fighting it.
/// Every animation in the app goes through here, so Reduce Motion is honoured in one
/// place: with it on, changes happen instantly. It used to be respected only on the
/// drop target.
enum Motion {
    private static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var layout: Animation? { reduce ? nil : .smooth(duration: 0.34, extraBounce: 0.02) }
    static var standard: Animation? { reduce ? nil : .smooth(duration: 0.26) }
    static var snappy: Animation? { reduce ? nil : .snappy(duration: 0.2) }
    static var gentle: Animation? { reduce ? nil : .easeInOut(duration: 0.18) }
    static var selection: Animation? { reduce ? nil : .snappy(duration: 0.15) }
}

// MARK: - Palette

/// Every colour in the app is appearance-aware. `Color(red:green:blue:)` bakes one
/// fixed value, which then either fails contrast in Dark Mode or glares in Light —
/// so each hue is declared as a light/dark pair and resolved by AppKit at draw time.
/// That also means Increased Contrast and inactive windows repaint correctly for free.
private func adaptive(_ name: String,
                      light: (Double, Double, Double),
                      dark: (Double, Double, Double)) -> Color {
    Color(nsColor: NSColor(name: name) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let c = isDark ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}

/// Status colours only. Chrome is neutral; colour is spent on meaning, never on
/// branding.
///
/// Every pair clears 4.5:1 against the *window* background of its own appearance —
/// `#ECECEC` in Light, `#1E1E1E` in Dark — not merely against white. That distinction
/// matters: an earlier pass targeted white and five of the eight then failed on the
/// grey window background they are actually drawn on, by as much as 3.83:1. These are
/// safe for caption-sized text, not just for filled shapes.
enum Palette {
    static let ready   = adaptive("sublyReady",   light: (0.048, 0.477, 0.286), dark: (0.35, 0.85, 0.55))
    static let caution = adaptive("sublyCaution", light: (0.595, 0.365, 0.000), dark: (1.00, 0.72, 0.30))
    static let alert   = adaptive("sublyAlert",   light: (0.75, 0.10, 0.10), dark: (1.00, 0.45, 0.42))
    static let info    = adaptive("sublyInfo",    light: (0.05, 0.40, 0.85), dark: (0.45, 0.70, 1.00))
    /// Marks drawn ON a track-coloured shape (timeline grab handles). White vanished
    /// on the bright dark-mode track colours (1.7:1); near-black reads at 7.5:1 or more.
    static let onTrack = adaptive("sublyOnTrack", light: (1, 1, 1), dark: (0.10, 0.10, 0.10))
}

/// One flat hue per track, reused verbatim wherever that track appears — the cue
/// grid's leading rule, the timeline lane, the caption overlay. This is Final Cut's
/// role-colour model: a small saturated mark identifies the lane, and nothing else
/// in the window is tinted. Never a gradient, never a full-row wash.
enum TrackPalette {
    static let colors: [Color] = [
        adaptive("sublyTrack0", light: (0.045, 0.407, 0.815), dark: (0.40, 0.68, 1.00)),  // blue     — translation
        adaptive("sublyTrack1", light: (0.027, 0.477, 0.329), dark: (0.30, 0.85, 0.60)),  // green    — romanized
        adaptive("sublyTrack2", light: (0.621, 0.351, 0.000), dark: (1.00, 0.70, 0.28)),  // amber    — original
        adaptive("sublyTrack3", light: (0.48, 0.25, 0.80), dark: (0.78, 0.58, 1.00)),  // violet   — reference
    ]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }

    /// The same hues for text drawn on the video's black caption pill, which is dark in
    /// both appearances. The adaptive colours above switch to their deep light-mode
    /// variants in Light Mode and dropped to about 2:1 on the pill.
    static let onVideoColors: [Color] = [
        Color(red: 0.40, green: 0.68, blue: 1.00), Color(red: 0.30, green: 0.85, blue: 0.60),
        Color(red: 1.00, green: 0.70, blue: 0.28), Color(red: 0.78, green: 0.58, blue: 1.00),
    ]
    static func onVideo(_ index: Int) -> Color { onVideoColors[index % onVideoColors.count] }

    /// A track's colour slot, derived from the track's identity rather than its
    /// position in an array. Reordering or deleting a track must not recolour the rest.
    static func slot(kind: OutputKind, languageTag: String, isReference: Bool) -> Int {
        if isReference { return 3 }
        switch kind {
        case .translation: return 0
        case .romanized:   return 1
        case .original:    return 2
        }
    }
}

// MARK: - Section heading

/// A plain heading. Hierarchy comes from type weight and spacing, which is what the
/// system's own apps do — not from a gradient-filled icon tile.
struct SectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Formatting

enum Format {
    /// `1:04.320` — compact but precise enough to trust for caption work.
    static func timecode(_ seconds: Double, frames: Bool = false, fps: Double = 30) -> String {
        let t = max(0, seconds)
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if frames {
            let f = Int(((t - Double(Int(t))) * fps).rounded(.down))
            return h > 0 ? String(format: "%d:%02d:%02d:%02d", h, m, s, f)
                         : String(format: "%02d:%02d:%02d", m, s, f)
        }
        let ms = Int(((t - Double(Int(t))) * 1000).rounded())
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
                     : String(format: "%02d:%02d.%03d", m, s, ms)
    }

    /// `1:04.3` — enough to find a cue, a third the width of a full timecode.
    static func shortTimecode(_ seconds: Double) -> String {
        let t = max(0, seconds)
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        let tenths = Int((t - Double(Int(t))) * 10)
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
                     : String(format: "%d:%02d.%d", m, s, tenths)
    }

    static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}
