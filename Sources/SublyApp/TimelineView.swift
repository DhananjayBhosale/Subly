import SwiftUI
import SublyCaptions

/// One row per track with cue blocks aligned vertically — they line up because every
/// track shares the same spine.
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutMode) private var layout

    private var duration: Double { max(0.1, model.project.mediaInfo?.duration ?? 1) }
    private var tracks: [SubtitleTrack] { model.project.tracks }

    /// Horizontal magnification. 1 fits the whole clip; higher spreads it out so a cue
    /// lasting a second is wide enough to grab and retime.
    @State private var zoom: CGFloat = 1
    private static let maxZoom: CGFloat = 60

    var body: some View {
        GeometryReader { proxy in
            let paneWidth = proxy.size.width
            let width = paneWidth * zoom
            let rowHeight = rowHeight(for: proxy.size.height)

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                lanes(width: width, rowHeight: rowHeight, paneHeight: proxy.size.height)
            }
            .overlay(alignment: .topTrailing) { zoomControls }
            .onChange(of: model.timelineZoomRequest) { old, new in
                setZoom(new > old ? zoom * 1.6 : zoom / 1.6)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.secondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        // Contain, then label: labelling the container alone spread the label onto
        // every child, so each zoom button read "Caption timeline, 3 tracks".
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Caption timeline, \(tracks.count) tracks")
    }

    private func lanes(width: CGFloat, rowHeight: CGFloat, paneHeight: CGFloat) -> some View {
        VStack(spacing: 3) {
            // Where you are in time. The lanes alone gave no sense of time at all, and
            // the 57-minute project was an unreadable barcode.
            TimeRuler(duration: duration, width: width)
                .frame(width: width, height: 14)
            WaveformStrip(peaks: model.project.waveform)
                .frame(width: width, height: 22)
            ForEach(tracks) { track in
                TrackRow(track: track,
                         color: model.project.color(for: track.id),
                         duration: duration,
                         width: width,
                         height: rowHeight)
            }
        }
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .topLeading) {
            // Reads the clock directly. Passing `model.currentTime` in here made this
            // whole body — and every track canvas — rebuild 30 times a second.
            Playhead(clock: model.clock, duration: duration,
                     width: width, height: paneHeight)
        }
        .contentShape(.rect)
        .gesture(scrub(width: width))
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A cue-edge drag owns the gesture; scrubbing must not fight it.
                guard model.draggingCue == nil else { return }
                let t = Double(value.location.x / max(1, width)) * duration
                model.seek(to: min(max(0, t), duration))
            }
    }

    /// Zoom, the way an editor expects it: buttons, a keyboard pair, and pinch.
    /// At 1× a one-second cue in a 57-minute clip is a third of a pixel wide — there
    /// was no way to see it, let alone drag its edge.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { setZoom(zoom / 1.6) } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass").labelStyle(.iconOnly)
            }
                .disabled(zoom <= 1.01)
                .help("Zoom out (⌘−)")
            Text(zoom < 1.05 ? "Fit" : String(format: "%.0f×", zoom))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 26)
            Button { setZoom(zoom * 1.6) } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass").labelStyle(.iconOnly)
            }
                .disabled(zoom >= Self.maxZoom - 0.01)
                .help("Zoom in (⌘+)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .padding(6)
        .gesture(MagnifyGesture().onChanged { setZoom(zoom * (1 + ($0.magnification - 1) * 0.06)) })
    }

    private func setZoom(_ new: CGFloat) {
        withAnimation(Motion.gentle) { zoom = min(max(1, new), Self.maxZoom) }
    }

    /// Share the available height across however many tracks exist, with a floor so
    /// blocks stay clickable.
    private func rowHeight(for total: CGFloat) -> CGFloat {
        let available = total - 25 - 17 - CGFloat(max(0, tracks.count - 1)) * 3
        let perTrack = available / CGFloat(max(1, tracks.count))
        // Allow taller rows when there are few tracks, so one track does not leave
        // most of the timeline empty.
        let ceiling: CGFloat = tracks.count <= 2 ? 56 : 34
        return max(18, min(ceiling, perTrack))
    }
}

/// Time labels along the top of the timeline, spaced for the current zoom.
private struct TimeRuler: View {
    let duration: Double
    let width: CGFloat

    private var interval: Double {
        let secondsPerPoint = duration / Double(max(1, width))
        let wanted = secondsPerPoint * 80          // about one label per 80 points
        return [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600].first { $0 >= wanted } ?? 3600
    }

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            let step = interval
            var t = 0.0
            while t <= duration {
                let x = CGFloat(t / duration) * size.width
                context.fill(Path(CGRect(x: x, y: size.height - 4, width: 0.5, height: 4)),
                             with: .color(.secondary))
                let label = Text(Format.duration(t)).font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: x + 3, y: size.height / 2 - 1), anchor: .leading)
                t += step
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WaveformStrip: View {
    let peaks: [Float]

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let midY = size.height / 2
            let step = size.width / CGFloat(peaks.count)
            var path = Path()
            for (i, peak) in peaks.enumerated() {
                let x = CGFloat(i) * step
                let h = max(0.5, CGFloat(peak) * midY)
                path.move(to: CGPoint(x: x, y: midY - h))
                path.addLine(to: CGPoint(x: x, y: midY + h))
            }
            // Flat and low-chroma: no pro editor gradient-strokes its waveform, and a
             // gradient here would compete with the per-track colours above it.
            context.stroke(path, with: .color(.secondary.opacity(0.55)),
                           lineWidth: max(0.5, step * 0.8))
        }
        .padding(.horizontal, 1)
    }
}

private struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: SubtitleTrack
    let color: Color
    let duration: Double
    let width: CGFloat
    let height: CGFloat

    private var isVisible: Bool { model.project.visibleTrackIDs.contains(track.id) }

    private enum Edge { case start, end }
    @State private var dragEdge: Edge = .start
    @State private var dragOrigin: (Double, Double)?
    /// True while the drag is under way; it resets by itself when a drag is cancelled
    /// (the window loses focus mid-drag), which skips `onEnded`. Without this the app
    /// stayed "mid-drag", and later timing changes were neither indexed nor saved.
    @GestureState private var retiming = false

    var body: some View {
        // Drawn with Canvas, not one view per cue. A 57-minute project has ~1800
        // cues per track; as SwiftUI views that was thousands of nodes per track
        // rebuilt on every redraw.
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let track = self.track
            let selected = model.selectedCueSlot
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size),
                              cornerRadius: 3),
                         with: .color(.gray.opacity(0.14)))
            guard duration > 0 else { return }
            // Genuinely skip cues too narrow to see. On a 57-minute project most
            // cues are well under a pixel wide; drawing them all was wasted work.
            let minVisibleWidth: CGFloat = 0.75
            var lastDrawnX: CGFloat = -.greatestFiniteMagnitude
            for cue in track.cues {
                let x = CGFloat(cue.start / duration) * size.width
                let rawWidth = CGFloat(cue.duration / duration) * size.width
                guard x + rawWidth >= 0, x <= size.width else { continue }
                let isSelectedCue = selected == cue.slotIndex
                if rawWidth < minVisibleWidth, !isSelectedCue {
                    // Collapse a run of hairline cues into one mark per pixel.
                    if x - lastDrawnX < 1 { continue }
                }
                lastDrawnX = x
                let w = max(minVisibleWidth, rawWidth)
                let isSelected = isSelectedCue
                // A 1pt gap on each side: without it, back-to-back cues fill the
                // lane as one unbroken block and you cannot see where captions split.
                let rect = CGRect(x: x + 0.5, y: 1,
                                  width: max(1, w - 1), height: size.height - 2)
                context.fill(Path(roundedRect: rect, cornerRadius: min(4, w / 2)),
                             with: .color(isSelected ? color : color.opacity(0.7)))
                if isSelected {
                    context.stroke(Path(roundedRect: rect, cornerRadius: min(4, w / 2)),
                                   with: .color(.white.opacity(0.95)), lineWidth: 1.5)
                    // Visible grab handles: a draggable edge you cannot see is not an
                    // affordance. Only on the selected cue, so the lane stays readable.
                    if w > 10 {
                        for hx in [rect.minX + 1.5, rect.maxX - 3.5] {
                            context.fill(Path(roundedRect: CGRect(x: hx, y: rect.midY - 6,
                                                                  width: 2.5, height: 12),
                                              cornerRadius: 1.25),
                                         with: .color(Palette.onTrack))
                        }
                    }
                }
                // The words themselves on blocks wide enough to read, so you can find
                // a caption on the timeline without playing it.
                if w > 46, let line = cue.lines.first, !line.isEmpty {
                    let text = context.resolve(Text(line).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.onTrack))
                    context.draw(text, in: rect.insetBy(dx: 5, dy: max(1, (rect.height - 13) / 2)))
                }
                if cue.needsReview, w > 7 {
                    // Ringed: the caution colour is nearly the original track's amber,
                    // so a bare dot vanished on exactly the lane flagged most often.
                    let dot = Path(ellipseIn: CGRect(x: rect.maxX - 6.5, y: 2, width: 5, height: 5))
                    context.fill(dot, with: .color(Palette.caution))
                    context.stroke(dot, with: .color(.black.opacity(0.75)), lineWidth: 1)
                }
            }
        }
        .frame(height: height)
        .opacity(isVisible ? 1 : 0.4)
        .animation(Motion.gentle, value: isVisible)
        .contentShape(.rect)
        .gesture(retimeGesture)
        .onChange(of: retiming) { _, active in
            if !active, model.draggingCue != nil {
                model.finishRetime()
                dragOrigin = nil
            }
        }
        .contextMenu { CaptionContextMenu(model: model) }
        .onTapGesture { location in
            guard duration > 0, width > 0 else { return }
            let t = Double(location.x / width) * duration
            // Move the playhead to where you clicked, as every editor does. It used to
            // jump to the caption's start, so you could never click into a caption to
            // split it there.
            if let cue = track.cues.first(where: { t >= $0.start && t < $0.end }) {
                withAnimation(Motion.selection) {
                    model.selectedCueSlot = cue.slotIndex
                    model.focusedTrackID = track.id
                }
            } else {
                model.selectedCueSlot = nil
            }
            model.seek(to: t)
        }
    }

    // MARK: Retime by dragging an edge

    private static let handleSlop: CGFloat = 7

    /// Drag either edge of the selected cue to change when it appears or hides.
    ///
    /// Timing could only be changed with the inspector's steppers, 0.04s per click.
    /// Dragging is how every editor does this, and it is the reason the zoom control
    /// exists: at 1× a one-second cue is a fraction of a pixel wide.
    private var retimeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($retiming) { _, active, _ in active = true }
            .onChanged { value in
                guard duration > 0, width > 0 else { return }
                let secondsPerPoint = duration / Double(width)
                if model.draggingCue == nil {
                    // Decide what was grabbed, once, at the start.
                    guard let slot = model.selectedCueSlot,
                          let cue = track.cues.first(where: { $0.slotIndex == slot })
                    else { return }
                    let startX = CGFloat(cue.start / duration) * width
                    let endX = CGFloat(cue.end / duration) * width
                    let x = value.startLocation.x
                    if abs(x - startX) <= Self.handleSlop { dragEdge = .start }
                    else if abs(x - endX) <= Self.handleSlop { dragEdge = .end }
                    else { return }
                    model.draggingCue = slot
                    dragOrigin = (cue.start, cue.end)
                }
                guard let slot = model.draggingCue, let origin = dragOrigin else { return }
                let delta = Double(value.translation.width) * secondsPerPoint
                var start = origin.0, end = origin.1
                // Keep at least a frame of cue; the model clamps against neighbours.
                if dragEdge == .start { start = min(origin.0 + delta, origin.1 - 0.05) }
                else { end = max(origin.1 + delta, origin.0 + 0.05) }
                model.updateCueTiming(slotIndex: slot, start: max(0, start),
                                      end: min(duration, end))
            }
            .onEnded { _ in
                if model.draggingCue != nil { model.finishRetime() }
                dragOrigin = nil
            }
    }

}

private struct Playhead: View {
    let clock: PlaybackClock
    let duration: Double
    let width: CGFloat
    let height: CGFloat

    private var x: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(clock.currentTime / duration, 1)) * width
    }

    var body: some View {
        Rectangle()
            .fill(Palette.alert)
            .frame(width: 2, height: height)
            .overlay(alignment: .top) {
                Circle().fill(Palette.alert)
                    .frame(width: 9, height: 9)
                    .offset(y: -4)
            }
            .offset(x: max(0, x))
            .allowsHitTesting(false)
    }
}
