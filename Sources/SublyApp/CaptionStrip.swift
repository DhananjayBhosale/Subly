import SwiftUI
import SublyCaptions

/// The captions as a row of cards under the video, to read ahead and jump with a
/// click. It follows playback, so the caption being spoken stays in view.
struct CaptionStrip: View {
    @Environment(AppModel.self) private var model
    @State private var activeSlot: Int?

    /// The first track shown on the video, else the first track.
    private var track: SubtitleTrack? {
        let generated = model.project.tracks.filter { !$0.isReference }
        return generated.first { model.project.visibleTrackIDs.contains($0.id) } ?? generated.first
    }

    var body: some View {
        if let track {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(track.cues) { cue in
                            Button {
                                model.selectedCueSlot = cue.slotIndex
                                model.seek(to: cue.start + 0.01)
                            } label: {
                                StripCard(cue: cue,
                                          isActive: cue.slotIndex == activeSlot,
                                          isSelected: cue.slotIndex == model.selectedCueSlot)
                            }
                            .buttonStyle(.plain)
                            .id(cue.slotIndex)
                            .contextMenu { CaptionContextMenu(model: model, slot: cue.slotIndex) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .onChange(of: activeSlot) { _, slot in
                    guard let slot else { return }
                    withAnimation(Motion.gentle) { proxy.scrollTo(slot, anchor: .center) }
                }
            }
            // Only this tiny view reads the clock, so the strip itself redraws when the
            // spoken caption changes, not 30 times a second.
            .background(ActiveCueObserver(clock: model.clock, slot: { time in
                guard let position = model.index.index(for: track.id)?.cuePosition(at: time),
                      position < track.cues.count else { return nil }
                return track.cues[position].slotIndex
            }) { activeSlot = $0 })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Captions, \(track.displayName)")
        }
    }
}

private struct ActiveCueObserver: View {
    let clock: PlaybackClock
    let slot: (Double) -> Int?
    let onChange: (Int?) -> Void

    var body: some View {
        let current = slot(clock.currentTime)
        Color.clear.onChange(of: current, initial: true) { _, new in onChange(new) }
    }
}

private struct StripCard: View {
    let cue: Cue
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(Format.shortTimecode(cue.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if cue.needsReview {
                    Circle().fill(Palette.caution).frame(width: 6, height: 6)
                        .help("Subly is unsure about this caption — worth checking")
                }
            }
            Text(cue.text)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(width: 170, height: 50, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.background.secondary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor)
                              : isActive ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(.separator),
                              lineWidth: isSelected ? 2 : (isActive ? 1 : 0.5))
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Caption at \(Format.shortTimecode(cue.start)): \(cue.text)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
