import SwiftUI
import AVKit
import AVFoundation
import SublyCaptions

/// AVPlayerLayer hosted directly, so the original file plays with VideoToolbox
/// hardware decode — ProRes, HEVC 10-bit, HDR — with no transcode.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}

// MARK: - Preview with simultaneous overlay

struct VideoPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutMode) private var layout

    /// Width ÷ height of the picture, or nil when there is nothing to size to.
    private var aspect: CGFloat? {
        guard let size = model.project.mediaInfo?.videoSize,
              size.width > 0, size.height > 0 else { return nil }
        return CGFloat(size.width / size.height)
    }

    /// The black box hugs the picture instead of filling the pane. A phone-shot
    /// vertical clip used to sit as a narrow strip inside a wide black rectangle, with
    /// most of the preview area wasted.
    ///
    /// Only the **width** is set here. Two earlier attempts set width and height from a
    /// computed box, or used `.aspectRatio(_:contentMode:)` against a flexible parent —
    /// both let the view grow taller than the pane it lives in and draw over the
    /// transport bar and the timeline. Height still comes from the parent, so vertical
    /// overflow is impossible by construction; the width is additionally clamped to the
    /// space offered, so an over-reported height cannot widen it either.
    var body: some View {
        GeometryReader { proxy in
            let width = aspect.map { min(proxy.size.width, proxy.size.height * $0) }
                ?? proxy.size.width
            picture
                .frame(width: max(1, width))
                .frame(maxWidth: .infinity)
        }
    }

    private var picture: some View {
        ZStack {
            Rectangle().fill(.black)
            if let player = model.player, model.project.mediaInfo?.hasVideo == true {
                PlayerLayerView(player: player)
            } else if model.project.mediaInfo?.hasVideo == false {
                // Audio-only source: show the waveform as the canvas.
                AudioOnlyBackdrop()
            }
            SubtitleOverlay()
        }
        .clipShape(RoundedRectangle(cornerRadius: layout == .compact ? 8 : 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: layout == .compact ? 8 : 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        // Deliberately static. Reading the clock here rebuilt this body — and the
        // player layer and overlay inside it — 30 times a second.
        .accessibilityLabel("Video preview. Subtitle tracks are shown over the picture.")
    }
}

private struct AudioOnlyBackdrop: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("Audio only")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Every enabled track renders at the same moment, stacked in the lower third, each
/// labelled and independently toggleable. This is the core of MULTI-03.
struct SubtitleOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutMode) private var layout
    /// The caption (cue ID) being edited directly on the picture. Keyed by cue, not
    /// track: keyed by track, moving to the next caption kept the open field and its
    /// draft, and saving then wrote that draft over the next caption.
    @State private var editing: UUID?
    /// Live vertical drag, as a fraction of the picture height.
    @State private var dragDelta: Double = 0
    @State private var dragging = false
    /// Height of the caption stack, to keep all of it on screen.
    @State private var stackHeight: CGFloat = 0
    /// Track labels show on hover only: drawn all the time they made the preview stack
    /// taller than the exported video, and sat over the footage.
    @State private var hovering = false
    /// A first-run hint: editing and placing captions on the video had no visible cue.
    @AppStorage("tip.overlayEditing.dismissed") private var tipDismissed = false

    private var active: [(track: SubtitleTrack, cue: Cue)] {
        model.activeCues(at: model.clock.currentTime)
    }

    private var allTracksHidden: Bool {
        let generated = model.project.tracks.filter { !$0.isReference }
        return !generated.isEmpty && generated.allSatisfy { !model.project.visibleTrackIDs.contains($0.id) }
    }

    /// The picture inside this view. A wide video in a tall pane is letterboxed, and
    /// caption size and position are fractions of the picture, not of the pane.
    private func videoRect(in size: CGSize) -> CGRect {
        guard let video = model.project.mediaInfo?.videoSize, video.width > 0, video.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let aspect = video.width / video.height
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = videoRect(in: geo.size)
            let style = model.project.captionStyle
            let fontSize = max(9, min(rect.width, rect.height) * style.size)
            let position = style.position + dragDelta
            let centre = CaptionStyle.clampedCentre(position, stackHeight: rect.height > 0 ? Double(stackHeight / rect.height) : 0)
            let now = model.clock.currentTime
            // Reduce Motion: no popping or sliding in the preview. (The exported video
            // keeps the chosen animation; it must not depend on this Mac's settings.)
            let previewStyle: CaptionStyle = {
                var s = style
                // Paused, a caption is shown whole. Drawn at the moment it was stopped, the
                // first frame of a fade or the start of word-by-word looked like no caption
                // at all — which is where the editor lands after making captions.
                if !model.clock.isPlaying, [.fade, .pop, .slideUp, .typewriter].contains(style.animation) {
                    s.animation = .none
                } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                          style.animation == .pop || style.animation == .slideUp {
                    s.animation = .fade
                }
                return s
            }()
            ZStack {
                if editing != nil {
                    // A click anywhere else on the picture closes the open caption; the
                    // caption saves what was typed as it closes.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { editing = nil }
                }
                if dragging {
                    // Where Reels, Shorts and TikTok put their own buttons and text.
                    let top = rect.minY + CaptionStyle.reelsCoveredFrom * rect.height
                    Rectangle()
                        .fill(.black.opacity(0.35))
                        .overlay(alignment: .top) {
                            Text("Covered by Reels and Shorts buttons")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.top, 6)
                        }
                        .frame(width: rect.width, height: rect.maxY - top)
                        .position(x: rect.midX, y: (top + rect.maxY) / 2)
                        .allowsHitTesting(false)
                }
                // Not on a picture too narrow for it: squeezed, it wrapped to four lines
                // and its first line was cut off.
                if !tipDismissed, !active.isEmpty, !model.clock.isPlaying, editing == nil, rect.width >= 300,
                   model.spellingNote == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left")
                        Text("Click a caption to fix a word. Drag it to move all captions.")
                        Button { tipDismissed = true } label: {
                            Label("Dismiss tip", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
                    .frame(maxWidth: rect.width - 24)
                    // Away from the captions: at the top it sat on captions placed there.
                    .position(x: rect.midX, y: centre < 0.45 ? rect.maxY - 28 : rect.minY + 24)
                }
                if allTracksHidden {
                    // With every track hidden the picture shows no text at all, and the
                    // editor looked empty. Say so, with the way back.
                    Button {
                        model.project.visibleTrackIDs.formUnion(model.project.tracks.filter { !$0.isReference }.map(\.id))
                    } label: {
                        Label("Captions are hidden — Show", systemImage: "eye.slash")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show every track on the video")
                    .position(x: rect.midX, y: rect.minY + 0.85 * rect.height)
                }
                VStack(spacing: fontSize * 0.3) {
                    ForEach(active, id: \.cue.id) { item in
                        OverlayLine(track: item.track, cue: item.cue,
                                    color: model.project.videoColor(for: item.track.id),
                                    style: previewStyle, fontSize: fontSize,
                                    elapsed: now - item.cue.start, duration: item.cue.duration,
                                    words: style.animation.isPerWord ? model.wordTimes(track: item.track, cue: item.cue) : nil,
                                    showLabel: hovering && model.project.visibleTrackIDs.count > 1,
                                    isEditing: editing == item.cue.id,
                                    begin: {
                                        // Pause first: with the clock running the active cue
                                        // changes underneath and the field would vanish
                                        // mid-sentence. (Setting isPlaying only changed the
                                        // button; the player kept going.)
                                        if model.isPlaying { model.togglePlayback() }
                                        editing = item.cue.id
                                    },
                                    commit: { lines in
                                        model.updateCueText(trackID: item.track.id,
                                                            cueID: item.cue.id, lines: lines)
                                        // Only this caption: a click on another caption may
                                        // already have opened that one.
                                        if editing == item.cue.id { editing = nil }
                                    },
                                    move: { dy in
                                        guard rect.height > 0 else { return }
                                        dragging = true
                                        dragDelta = dy / rect.height
                                    },
                                    moveEnded: { dy in
                                        dragging = false
                                        guard rect.height > 0 else { dragDelta = 0; return }
                                        let stack = Double(stackHeight / rect.height)
                                        model.setCaptionPosition(CaptionStyle.clampedCentre(
                                            style.position + dy / rect.height, stackHeight: stack))
                                        dragDelta = 0
                                    })
                    }
                }
                .frame(maxWidth: rect.width * 0.92)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
                .onHover { hovering = $0 }
                .position(x: rect.midX, y: rect.minY + centre * rect.height)
                .animation(Motion.gentle, value: active.map(\.cue.id))
            }
        }
        .onChange(of: active.map(\.cue.id)) { _, ids in
            // The cue moved on: stop editing rather than write into the wrong one.
            if let editing, !ids.contains(editing) { self.editing = nil }
        }
        .onChange(of: model.clock.isPlaying) { _, playing in
            // Pressing play commits what you typed instead of discarding it.
            if playing { editing = nil }
        }
    }
}

/// One track's caption, drawn over the picture in the project's caption style and
/// editable where it sits.
///
/// Fixing a mis-heard word while watching it is the single most common thing anyone
/// does in a caption editor, so a click here opens the words for editing.
private struct OverlayLine: View {
    let track: SubtitleTrack
    let cue: Cue
    let color: Color
    let style: CaptionStyle
    let fontSize: CGFloat
    let elapsed: Double
    let duration: Double
    let words: [CaptionAnimationTiming.Word]?
    let showLabel: Bool
    let isEditing: Bool
    let begin: () -> Void
    /// Saves the words and closes the field.
    let commit: ([String]) -> Void
    /// Vertical drag distance in points, live and at the end.
    let move: (CGFloat) -> Void
    let moveEnded: (CGFloat) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool
    /// The press has moved far enough to be a drag rather than a click.
    @State private var moving = false
    /// The pointer is over the open caption, so a click there keeps it open.
    @State private var overField = false
    /// The grip sits outside the field, so a press on it must not close the field.
    @State private var overGrip = false
    @State private var clickMonitor: Any?

    private var isRTL: Bool {
        ScriptProfile.forLanguage(track.languageTag).isRightToLeft
    }

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            if isEditing {
                TextField("\(track.displayName) caption", text: $draft, axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(style.font(size: fontSize))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                    .focused($focused)
                    .onSubmit { commit(lines(from: draft)) }
                    // Escape closes the caption too, keeping what was typed (⌘Z undoes).
                    .onExitCommand { commit(lines(from: draft)) }
                    .onAppear {
                        draft = cue.lines.joined(separator: "\n")
                        focused = true
                    }
                    .onChange(of: focused) { _, has in
                        // Clicking away commits, which is what people expect of a field
                        // they opened by clicking.
                        if !has { commit(lines(from: draft)) }
                    }
                    .padding(.leading, 38)
                    .padding(.trailing, 14)
                    .padding(.vertical, 8)
                    // The margin around the open field still drags the captions; the
                    // field itself keeps its clicks for placing the cursor.
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black.opacity(0.75))
                            .gesture(press)
                            .pointerStyle(moving ? .grabActive : .grabIdle)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                    // A dragging inside the open text selects words, as in any field, and
                    // the margin alone was a 10-point target. A visible grip moves it.
                    .overlay(alignment: .leading) {
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor, in: Circle())
                            .contentShape(Circle())
                            // Inside the box: the picture clips anything past its edge.
                            .padding(.leading, 7)
                            .gesture(press)
                            .pointerStyle(moving ? .grabActive : .grabIdle)
                            .help("Drag to move the captions up or down.")
                            .onHover { overGrip = $0 }
                            .accessibilityHidden(true)
                    }
                    .onHover { overField = $0 }
            } else {
                StyledCaption(text: cue.lines.joined(separator: "\n"), style: style,
                              fontSize: fontSize, elapsed: elapsed, duration: duration, words: words)
                    .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                    .layoutPriority(1)
                    .overlay(alignment: .leading) {
                        if cue.needsReview {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.caution)
                                .frame(width: 3)
                                .offset(x: -8)
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if showLabel {
                // White on a dark tag with the track's colour as a dot: coloured text
                // straight on the footage measured under 2:1 on bright frames.
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(shortLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: Capsule())
                .offset(y: -14)
                .allowsHitTesting(false)
            }
        }
        // Only the caption is hittable, so clicks anywhere else still reach the video.
        .contentShape(.rect)
        // One gesture for both click and drag. A tap gesture here with a drag on the
        // stack above never moved anything: the tap on the caption outranked the drag,
        // so a press on a caption could only ever become a click.
        .gesture(press, including: isEditing ? .subviews : .all)
        .pointerStyle(isEditing ? nil : (moving ? .grabActive : .grabIdle))
        .help((track.isReference ? "Imported tracks are read-only. "
               : (cue.needsReview ? "The orange bar means Subly is unsure about this caption — worth checking. " : "")
                 + "Click to edit this caption; Return, Escape or a click elsewhere saves it. ")
              + "Drag to move all captions up or down.")
        .onChange(of: isEditing) { _, editing in
            if editing {
                watchClicksOutside()
            } else {
                stopWatchingClicks()
                // Closed from outside — a click on the picture, or Play. Keep the words.
                commit(lines(from: draft))
            }
        }
        .onDisappear {
            stopWatchingClicks()
            // The caption left the screen while open (a seek): save into its own cue.
            if isEditing { commit(lines(from: draft)) }
        }
        // Editable without a mouse: the tap was the only way in.
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel("\(shortLabel.capitalized) caption")
        .accessibilityValue(cue.text + (cue.needsReview ? ", needs checking" : ""))
        .accessibilityAddTraits(track.isReference ? [] : .isButton)
        .accessibilityAction(named: "Edit caption") { if !track.isReference { begin() } }
        .transition(.opacity)
    }

    /// A press that moves a few points drags every caption up or down, as in CapCut;
    /// one that does not is a click, which opens the words for editing.
    private var press: some Gesture {
        // Global space: the caption moves with the drag, so its own space would shift.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !moving, hypot(value.translation.width, value.translation.height) < 4 { return }
                moving = true
                move(value.translation.height)
            }
            .onEnded { value in
                if moving {
                    moving = false
                    moveEnded(value.translation.height)
                } else if !isEditing && !track.isReference {
                    begin()
                }
            }
    }

    /// A click outside the open caption — on the picture, the timeline, a button that
    /// takes no focus — closes it. Clicks that move focus already did; the rest left
    /// the field open with no way out but Return.
    private func watchClicksOutside() {
        stopWatchingClicks()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            // Escape in a multi-line field means "complete the word", so the field's
            // exit command never ran and Escape did nothing. Close it here, unless an
            // input method (Hindi, Marathi) is using Escape to drop half-typed text.
            if event.type == .keyDown {
                guard event.keyCode == 53, let window = event.window,
                      let editor = window.firstResponder as? NSTextView,
                      !editor.hasMarkedText() else { return event }
                window.makeFirstResponder(nil)
                return nil
            }
            guard !overField, !overGrip, let window = event.window,
                  let editor = window.firstResponder as? NSTextView else { return event }
            let point = editor.convert(event.locationInWindow, from: nil)
            if !editor.visibleRect.contains(point) {
                // Losing focus saves through the field's own focus handler.
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Blank lines are dropped: in a subtitle file one would end the caption early.
    private func lines(from text: String) -> [String] {
        let lines = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.isEmpty ? [""] : lines
    }

    private var shortLabel: String { OutputLabels.badge(for: track) }
}

// MARK: - Transport

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutMode) private var layout

    private var duration: Double { model.project.mediaInfo?.duration ?? 1 }

    var body: some View {
        HStack(spacing: layout == .compact ? 8 : 12) {
            // Frame stepping and speed stay in the Playback menu on a narrow window,
            // where they squeezed the scrubber down to a dot.
            if layout > .compact {
            Button { model.step(frames: -1) } label: {
                Label("Step Back One Frame", systemImage: "backward.frame.fill").labelStyle(.iconOnly)
            }
            .help("Step back one frame (←)")
            }

            // No Space shortcut here: the Playback menu owns Space, and gives it back to
            // a caption being typed. A second shortcut on this button took it regardless.
            Button { model.togglePlayback() } label: {
                Label(model.clock.isPlaying ? "Pause" : "Play",
                      systemImage: model.clock.isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
            }
            .help(model.clock.isPlaying ? "Pause (Space)" : "Play (Space)")

            if layout > .compact {
            Button { model.step(frames: 1) } label: {
                Label("Step Forward One Frame", systemImage: "forward.frame.fill").labelStyle(.iconOnly)
            }
            .help("Step forward one frame (→)")
            }

            Button { model.showFrameTimecode.toggle() } label: {
                TransportTimecode(clock: model.clock, showFrames: model.showFrameTimecode,
                                  fps: Double(model.project.mediaInfo?.nominalFrameRate ?? 30))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: layout == .compact ? 72 : 88, alignment: .leading)
            }
            .help("Click to switch between milliseconds and frames")
            .accessibilityHint("Switches between milliseconds and frames")

            TransportScrubber(clock: model.clock, duration: duration) { model.seek(to: $0) }
                .frame(minWidth: 60)

            // Same style as the current time, so the two read as a pair.
            Text(Format.timecode(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                // One line always: squeezed, it wrapped into a column of single digits.
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Total length \(Format.duration(duration))")

            if layout > .compact {
            Picker("Playback speed", selection: Binding(
                get: { model.playbackRate },
                set: { model.playbackRate = $0 })) {
                ForEach(AppModel.playbackSpeeds, id: \.self) { speed in
                    Text(String(format: "%g×", speed)).tag(speed)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 72)
            .help("Playback speed")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Isolated so the 30 Hz clock does not invalidate the rest of the transport bar.
private struct TransportScrubber: View {
    let clock: PlaybackClock
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        Slider(value: Binding(get: { min(clock.currentTime, duration) },
                              set: { onSeek($0) }),
               in: 0...max(0.1, duration)) { Text("Playback position") }
        .labelsHidden()
        .controlSize(.small)
        .tint(.accentColor)
        .accessibilityValue(Format.timecode(clock.currentTime))
    }
}

private struct TransportTimecode: View {
    let clock: PlaybackClock
    let showFrames: Bool
    let fps: Double

    var body: some View {
        Text(Format.timecode(clock.currentTime, frames: showFrames, fps: fps))
            // Label and value here, where the clock is read: a label on the button
            // outside replaced the time, so VoiceOver heard "Current time" and nothing else.
            .accessibilityLabel("Current time")
            .accessibilityValue(Format.timecode(clock.currentTime, frames: showFrames, fps: fps))
            .accessibilityAddTraits(.updatesFrequently)
    }
}
