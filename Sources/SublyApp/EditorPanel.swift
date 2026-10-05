import SwiftUI
import SublyCaptions
import SublyEngine

/// The editor's one panel, in three tabs: which captions show and how they are cut,
/// how they look on the video, and how to share them. It replaces an inspector of six
/// stacked sections, where "how it looks" was off-screen below the speech settings.
struct EditorPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: Binding(get: { model.panelTab }, set: { model.panelTab = $0 })) {
                ForEach(AppModel.PanelTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            Group {
                switch model.panelTab {
                case .captions: CaptionsPane()
                case .look:     LookPane()
                case .share:    SharePane()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(.background)
    }
}

// MARK: - Captions

private struct CaptionsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            tracksSection
            if let slot = model.selectedCueSlot,
               let cue = model.project.tracks.lazy.compactMap({ model.cue(in: $0, slot: slot) }).first {
                timingSection(slot: slot, cue: cue)
            }
            Section {
                SyncRow()
            }
            Section("Words per caption") {
                WordsPerCaptionRows(appliesNow: true)
            }
            issuesSection
            // Kept for choosing the speech model, folded away until wanted.
            FoldingSection(speechTitle, key: "speech", expandedByDefault: false) {
                TranscriptionSettings(parts: [.language, .names, .model], showsRedo: true)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    /// "Speech model · Apex": which model made these captions, without a footer.
    private var speechTitle: String {
        guard let engine = model.project.spine?.engineID else { return "Speech model" }
        return "Speech model · \(Self.friendlyEngine(engine))"
    }

    /// Which captions show on the video, each with its own switch.
    private var tracksSection: some View {
        Section {
            ForEach(model.project.tracks) { track in
                TrackRow(track: track)
            }
            AddOutputMenu(model: model)
            // Change what a translation is in without leaving the editor.
            TranscriptionSettings(parts: [.translation])
        } header: {
            Text("Captions on the video")
        }
    }

    private func timingSection(slot: Int, cue: Cue) -> some View {
        Section {
            TimeStepper(label: "Appears", value: cue.start) { new in
                model.updateCueTiming(slotIndex: slot, start: new, end: cue.end)
            }
            TimeStepper(label: "Hides", value: cue.end) { new in
                model.updateCueTiming(slotIndex: slot, start: cue.start, end: new)
            }
            let tooFast = cue.readingRate > model.project.rules.maxReadingRate
            LabeledContent("Easy to read?") {
                Text(tooFast ? "A bit fast" : "Comfortable")
                    .foregroundStyle(tooFast ? Palette.caution : Palette.ready)
            }
            .help(tooFast ? "There is more text here than most people can read in \(String(format: "%.1f", cue.duration)) seconds. Give it more time, or shorten it."
                          : "This caption is on screen long enough to read comfortably.")
        } header: {
            Text("Caption \(slot + 1)")
        }
    }

    private var issuesSection: some View {
        Section("Things to check") {
            ForEach(model.project.tracks.filter { !$0.isReference }) { track in
                let count = model.diagnostics(for: track).count
                Button {
                    model.jumpToNextIssue(in: track)
                } label: {
                    LabeledContent {
                        Text(count == 0 ? "None" : "\(count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Label {
                            Text(track.displayName).lineLimit(1)
                        } icon: {
                            Image(systemName: count == 0 ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.caution))
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .help(count == 0 ? "Nothing to check in \(track.displayName)" : "Go to the next caption to check in \(track.displayName)")
            }
        }
    }

    /// "Subly · Apex model" → "Apex"; "Apple Speech · hi-IN" → "Apple (built in)".
    static func friendlyEngine(_ id: String) -> String {
        if id.hasPrefix("Apple") { return "Apple (built in)" }
        if let name = ExtendedEngineManager.allPacks.first(where: { id.contains("· \($0.displayName) model") })?.displayName {
            return name
        }
        return id
    }
}

/// One caption track: its colour, name, a switch for showing it on the video, and a
/// menu for the rest.
private struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: SubtitleTrack

    private var isShown: Bool { model.project.visibleTrackIDs.contains(track.id) }

    private func setShown(_ on: Bool) {
        withAnimation(Motion.selection) {
            if on { model.project.visibleTrackIDs.insert(track.id) }
            else { model.project.visibleTrackIDs.remove(track.id) }
        }
        model.scheduleAutosave()
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !track.isReference {
                    Menu {
                        Button("Save as SRT…") { model.saveSRT(track) }
                        Button("Tidy Up the Lines") { model.reflow(trackID: track.id) }
                        Divider()
                        Button("Remove", role: .destructive) { model.deleteTrack(track.id) }
                    } label: {
                        Label("\(track.displayName) options", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Toggle("Show \(track.displayName) on video", isOn: Binding(get: { isShown }, set: setShown))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // The switch style ignores the accessibility press that VoiceOver and
                    // Voice Control send; say what pressing it does.
                    .accessibilityAction(.default) { setShown(!isShown) }
                    .help(isShown ? "Hide from the video" : "Show on the video")
            }
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(model.project.color(for: track.id))
                    .frame(width: 4, height: 15)
                Text(track.displayName).lineLimit(1)
            }
            if track.isReference { Text("Read-only") }
        }
    }
}

/// Every caption a little earlier or later, to land on the spoken word.
private struct SyncRow: View {
    @Environment(AppModel.self) private var model
    private let step = 0.05

    var body: some View {
        LabeledContent("Sync") {
            HStack(spacing: 6) {
                Button("Earlier") { model.shiftAllCaptions(by: -step) }
                    .help("Show every caption 0.05 s earlier")
                Button("Later") { model.shiftAllCaptions(by: step) }
                    .help("Show every caption 0.05 s later")
                Text("0.05 s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .fixedSize()
        }
        .disabled(model.generation.isRunning || model.project.slots.isEmpty)
    }
}

private struct TimeStepper: View {
    let label: String
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(Format.timecode(value)).monospacedDigit()
                Stepper(label) { onChange(value + 0.04) } onDecrement: { onChange(max(0, value - 0.04)) }
                    .labelsHidden()
                    .accessibilityValue(Format.timecode(value))
            }
        }
    }
}

// MARK: - Look

/// Pick a look, place it, then adjust it. Every change shows on the video at once.
private struct LookPane: View {
    @Environment(AppModel.self) private var model

    private var style: CaptionStyle { model.project.captionStyle }

    private func binding<T>(_ keyPath: WritableKeyPath<CaptionStyle, T>) -> Binding<T> {
        Binding(get: { model.project.captionStyle[keyPath: keyPath] },
                set: { value in
                    var s = model.project.captionStyle
                    s[keyPath: keyPath] = value
                    model.setCaptionStyle(s)
                })
    }

    private func colour(_ keyPath: WritableKeyPath<CaptionStyle, String>) -> Binding<Color> {
        Binding(get: { Color(hex: model.project.captionStyle[keyPath: keyPath]) },
                set: { value in
                    var s = model.project.captionStyle
                    s[keyPath: keyPath] = value.hexString
                    model.setCaptionStyle(s)
                })
    }

    var body: some View {
        Form {
            Section {
                TemplateGrid(current: style.template) { model.applyTemplate($0) }
            } header: {
                Text("Look")
            }

            Section {
                PositionButtons(position: style.position) { model.setCaptionPosition($0) }
                Slider(value: binding(\.position), in: 0.06...0.95, step: 0.01) { Text("Position") }
                    .labelsHidden()
                    .accessibilityValue("\(Int((style.position * 100).rounded())) percent down the picture")
            } header: {
                Text("Where captions sit")
            }

            Section("Text") {
                LabeledContent("Size") {
                    Slider(value: binding(\.size), in: 0.03...0.09, step: 0.005) { Text("Size") }
                        .labelsHidden()
                        .accessibilityValue("\(Int((style.size / 0.045 * 100).rounded())) percent of standard size")
                }
                Picker("Font", selection: binding(\.font)) {
                    ForEach(CaptionStyle.Font.allCases) { Text($0.displayName).tag($0) }
                }
                HStack(spacing: 16) {
                    Toggle("Bold", isOn: binding(\.bold))
                    Toggle("All capitals", isOn: binding(\.uppercase))
                }
                .toggleStyle(.checkbox)
                ColourRow(title: "Colour", selection: colour(\.textColor))
                if style.animation == .wordHighlight {
                    ColourRow(title: "Highlight", selection: colour(\.highlightColor))
                }
            }

            Section("Background and motion") {
                Picker("Background", selection: binding(\.background)) {
                    ForEach(CaptionStyle.Background.allCases) { Text($0.displayName).tag($0) }
                }
                if style.background == .box {
                    ColorPicker("Box colour", selection: colour(\.boxColor), supportsOpacity: true)
                }
                Picker("Animation", selection: binding(\.animation)) {
                    ForEach(CaptionStyle.Animation.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                Button("Reset to \(style.template.displayName)") { model.resetStyle() }
                    .disabled(style == .preset(style.template))
                Button("Use This Look for New Projects") { model.useStyleForNewProjects() }
                    .disabled(style == AppModel.defaultCaptionStyle)
                    .help("Start every new project with this look")
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}

/// Every template as a small picture of itself, so choosing is looking, not reading.
private struct TemplateGrid: View {
    let current: CaptionStyle.Template
    let pick: (CaptionStyle.Template) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
            ForEach(CaptionStyle.Template.allCases) { template in
                Button { pick(template) } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.17, green: 0.27, blue: 0.34),
                                                    Color(red: 0.05, green: 0.09, blue: 0.11)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            StyledCaption(text: "Your caption", style: sample(template), fontSize: 12,
                                          elapsed: 0.8, duration: 3,
                                          words: CaptionAnimationTiming.words(in: "Your caption", start: 0.3, end: 1.6),
                                          applyTransform: false)
                                .padding(.horizontal, 4)
                        }
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(template == current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                              lineWidth: template == current ? 2.5 : 0.5)
                        }
                        Text(template.displayName)
                            .font(.caption)
                            .foregroundStyle(template == current ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(template.displayName)
                .accessibilityHint(template.summary)
                .accessibilityAddTraits(template == current ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }

    /// Typewriter shows its first words only at this moment, which is the point.
    private func sample(_ template: CaptionStyle.Template) -> CaptionStyle {
        CaptionStyle.preset(template)
    }
}

/// Three common places, one click each.
private struct PositionButtons: View {
    let position: Double
    let set: (Double) -> Void

    private let places: [(String, String, Double)] = [
        ("Top", "rectangle.tophalf.inset.filled", 0.14),
        ("Middle", "rectangle.center.inset.filled", 0.5),
        ("Bottom", "rectangle.bottomhalf.inset.filled", 0.72),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(places, id: \.0) { name, icon, value in
                let isNear = abs(position - value) < 0.06
                Button { set(value) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon).font(.title3)
                        Text(name).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isNear ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.fill.quaternary),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isNear ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), lineWidth: 1.5)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(name == "Bottom" ? "Low, but above where Reels and Shorts put their buttons" : "Put captions at the \(name.lowercased())")
                .accessibilityAddTraits(isNear ? .isSelected : [])
            }
        }
    }
}

/// A few caption colours one click away, and the full picker for anything else.
private struct ColourRow: View {
    let title: String
    @Binding var selection: Color

    private let swatches = ["#FFFFFF", "#FFD60A", "#30D158", "#FF375F", "#64D2FF"]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                ForEach(swatches, id: \.self) { hex in
                    let isOn = selection.hexString.prefix(7) == hex
                    Button { selection = Color(hex: hex) } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 16, height: 16)
                            .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                            .padding(2)
                            .overlay { Circle().strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(hex)")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                ColorPicker(title, selection: $selection, supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }
}

// MARK: - Share

private struct SharePane: View {
    @Environment(AppModel.self) private var model

    private var shown: [SubtitleTrack] { model.tracksShownOnVideo }

    var body: some View {
        Form {
            Section {
                Button {
                    model.exportCaptionedVideo()
                } label: {
                    Label("Save Video with Captions…", systemImage: "film")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.videoExportProgress != nil || shown.isEmpty)
                .help(shown.isEmpty ? "Turn on a caption track in Captions first"
                                    : "Saves the video as the preview shows it")
                if shown.isEmpty {
                    Text("Turn on a caption track first.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Video with captions")
            }

            Section {
                ForEach(model.project.tracks.filter { !$0.isReference }) { track in
                    LabeledContent(track.displayName) {
                        Button("Save SRT…") { model.saveSRT(track) }
                    }
                }
                Button("More Formats…") { model.showExport = true }
                    .help("VTT, plain text, or several files at once")
            } header: {
                Text("Subtitle files")
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}
