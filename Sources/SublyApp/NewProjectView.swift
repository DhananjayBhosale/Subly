import SwiftUI
import UniformTypeIdentifiers
import SublyCaptions
import SublyEngine

/// Step 2: what to make from this video. The video sits on the left so you can play it
/// and hear the language; the choices are a `Form` on the right, one question per
/// section, in the order you decide them.
struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutMode) private var layout

    private var hasMedia: Bool { model.project.mediaURL != nil || model.mediaMissingPath != nil }

    var body: some View {
        Group {
            if hasMedia {
                configuration
            } else {
                ContentUnavailableView {
                    Label("No Video Yet", systemImage: "film")
                } description: {
                    Text("Add a video first, then choose the captions to make.")
                } actions: {
                    Button("Add a Video") { model.route = .home }
                }
            }
        }
        .navigationTitle(hasMedia ? model.project.name : "Choose")
        .navigationSubtitle(hasMedia ? "Choose what to make" : "")
    }

    private var configuration: some View {
        HStack(alignment: .top, spacing: 4) {
            if layout > .compact {
                VideoColumn()
                    .frame(width: 270)
                    .padding(.leading, 24)
                    .padding(.top, 20)
            }
            Form {
                if layout == .compact { Section { VideoSummaryRow() } }
                if model.mediaMissingPath != nil { Section { RelinkRow() } }
                Section("What language is spoken?") {
                    TranscriptionSettings(parts: [.language])
                }
                CaptionsSection()
                Section("Speech model") {
                    TranscriptionSettings(parts: [.model])
                }
                Section {
                    TranscriptionSettings(parts: [.names])
                } header: {
                    Text("Names in this video")
                }
                MoreOptionsSection()
            }
            .formStyle(.grouped)
            .frame(maxWidth: 860)
        }
        // Video and choices stay together in the middle of a wide window, instead of
        // the video pinned left and the form floating far to the right.
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { GenerateBar() }
    }
}

// MARK: - Video

/// The video being captioned, playable, so you can hear what language it is in.
private struct VideoColumn: View {
    @Environment(AppModel.self) private var model

    /// Tall enough for a phone video, short enough that a wide one isn't letterboxed.
    private var previewHeight: CGFloat {
        guard let size = model.project.mediaInfo?.videoSize, size.width > 0, size.height > 0 else { return 200 }
        return min(420, 270 * CGFloat(size.height / size.width))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.project.mediaInfo?.hasVideo == true {
                VideoPreview().frame(height: previewHeight)
            }
            HStack(spacing: 8) {
                Button { model.togglePlayback() } label: {
                    Label(model.isPlaying ? "Pause" : "Play",
                          systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(model.player == nil)
                .help("Play the video to check what language it is in")
                Spacer()
            }
            VideoSummaryRow()
        }
    }
}

private struct VideoSummaryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.project.name)
                .font(.headline)
                .lineLimit(2)
            if let info = model.project.mediaInfo {
                Text([info.formattedDuration,
                      info.videoSize.flatMap { $0.width > 0 ? "\(Int($0.width)) × \(Int($0.height))" : nil },
                      info.formattedFileSize].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if info.isVariableFrameRate {
                    Text("Variable frame rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Use a Different Video…") { pick() }
                .buttonStyle(.link)
                .padding(.top, 2)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.acceptedTypes
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importMedia(url) }
        }
    }
}

private struct RelinkRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent {
            Button("Choose Video…") { model.relinkMedia() }
        } label: {
            Text("The video is missing")
            Text("Your captions are safe.")
        }
    }
}

// MARK: - Captions to make

private struct CaptionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            CaptionCards()
            Toggle("Remember these choices for next time",
                   isOn: Binding(get: { model.rememberChoices }, set: { model.rememberChoices = $0 }))
                .toggleStyle(.checkbox)
        } header: {
            Text("Which captions do you want?")
        } footer: {
            Text("Pick one or more.")
        }
    }
}

private struct CaptionCards: View {
    @Environment(AppModel.self) private var model

    /// "In English letters" first where the language has its own script: for Hindi and
    /// Marathi creators it is the one most often wanted.
    /// A language already written in English letters has no "in English letters"
    /// card: it could only ever be a disabled card explaining why.
    private var order: [OutputKind] {
        guard let cap = model.currentCapability,
              ScriptProfile.forLanguage(cap.languageCode).romanizable else {
            return [.original, .translation]
        }
        return [.romanized, .original, .translation]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(order, id: \.self) { CaptionCard(kind: $0).frame(minWidth: 150, idealWidth: 190, maxWidth: .infinity) }
            }
            VStack(spacing: 8) {
                ForEach(order, id: \.self) { CaptionCard(kind: $0) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One kind of caption, with an example of what it makes, picked by clicking it.
/// The translation card carries its own language menu.
private struct CaptionCard: View {
    @Environment(AppModel.self) private var model
    let kind: OutputKind

    private var cap: CapabilityRegistry.LanguageCapability? { model.currentCapability }
    private var code: String { cap?.languageCode ?? "en" }
    private var target: String { model.project.translationTarget }

    private var available: Bool {
        guard let cap else { return false }
        if kind == .original, model.chosenModelWritesEnglishLettersOnly { return false }
        return kind == .translation ? cap.canTranslate(to: target) : cap.supports(kind)
    }

    private var isOn: Bool { available && model.effectiveOutputs.contains(kind) }

    /// A speech model that writes the language in its own script, for when the chosen
    /// one (Apex) writes English letters only. Clicking the card switches to it, so the
    /// card is never a dead end.
    private var scriptModel: (choice: TranscriptionService.EngineChoice, name: String)? {
        guard kind == .original, model.chosenModelWritesEnglishLettersOnly,
              let cap, cap.supports(.original) else { return nil }
        if !cap.engine.requiresDownload { return (.apple, "Apple (built in)") }
        let packs = ExtendedEngineManager.allPacks.filter { $0.serves(cap.languageCode) && !$0.emitsRomanized }
        guard let pack = packs.first(where: { model.installedPackIDs.contains($0.id) }) ?? packs.first else { return nil }
        return (.pack(pack.id), pack.displayName)
    }

    private var clickable: Bool { available || scriptModel != nil }

    /// A few words on why a card can't be picked.
    private var reason: String? {
        guard let cap else { return "Pick a language first" }
        switch kind {
        case .original:    return "Not supported yet"
        case .romanized:   return "Not available yet"
        case .translation: return cap.translationTargets.isEmpty ? "Can't translate on this Mac" : "Pick another language"
        }
    }

    /// Hinglish is what most Hindi Reels use.
    private var tag: String? {
        kind == .romanized && code == "hi" ? "Best for Reels" : nil
    }

    private var sample: String? { OutputLabels.cardSample(kind, languageCode: code, target: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: tap) {
                content
                    .padding([.horizontal, .top], 12)
                    .padding(.bottom, showsLanguageMenu ? 6 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!clickable)
            .opacity(clickable ? 1 : 0.6)
            .accessibilityLabel(OutputLabels.title(kind, languageCode: code, target: target))
            .accessibilityValue(isOn ? "Selected" : "Not selected")
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(isOn ? .isSelected : [])

            if showsLanguageMenu, let cap {
                TranslationLanguageMenu(cap: cap)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.background))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                              lineWidth: isOn ? 2 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if let tag, available {
                Text(tag)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: -30, y: -8)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.selection, value: isOn)
    }

    private var showsLanguageMenu: Bool {
        kind == .translation && !(cap?.translationTargets.isEmpty ?? true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(TrackPalette.color(TrackPalette.slot(kind: kind, languageTag: "", isReference: false)))
                    .frame(width: 3, height: 13)
                Text(OutputLabels.cardTitle(kind, languageCode: code, target: target))
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            if clickable, let sample {
                Text("\u{201C}\(sample)\u{201D}")
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if clickable, let line = OutputLabels.cardSubtitle(kind, languageCode: code) {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let scriptModel {
                Text("Switches to \(scriptModel.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !available, let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityHint: String {
        if let scriptModel { return "Switches the speech model to \(scriptModel.name)" }
        if !available { return reason ?? "" }
        return sample.map { "For example: \($0)" } ?? ""
    }

    private func tap() {
        if let scriptModel, let cap {
            model.setEngineChoice(scriptModel.choice, for: cap.languageTag)
            model.project.selectedOutputs.insert(.original)
            return
        }
        if isOn {
            // Never leave nothing picked: the last card stays on.
            guard model.effectiveOutputs.count > 1 else { return }
            model.project.selectedOutputs.remove(kind)
            if kind == .romanized, model.chosenModelWritesEnglishLettersOnly {
                model.project.selectedOutputs.remove(.original)
            }
        } else {
            model.project.selectedOutputs.insert(kind)
        }
    }
}

/// The language the translation card makes, inside the card. Picking one also ticks
/// the card; a translation already made is redone in the new language.
private struct TranslationLanguageMenu: View {
    @Environment(AppModel.self) private var model
    let cap: CapabilityRegistry.LanguageCapability

    private var targets: [String] {
        let list = cap.translationTargets.filter { $0 != cap.languageCode }
        return list.isEmpty ? [model.project.translationTarget] : list
    }

    var body: some View {
        Picker("Translate into", selection: Binding(
            get: { model.project.translationTarget },
            set: { new in
                guard new != model.project.translationTarget else { return }
                // As in the editor; changing only the setting left the old one in place.
                if model.project.tracks.contains(where: { $0.kind == .translation && !$0.isReference }) {
                    model.retranslate(to: new)
                } else {
                    model.project.translationTarget = new
                    model.project.selectedOutputs.insert(.translation)
                }
            })) {
            ForEach(targets, id: \.self) { Text(CapabilityRegistry.displayName($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(model.generation.isRunning)
        .accessibilityLabel("Translate into")
        .task(id: model.project.sourceLanguage) {
            if !targets.contains(model.project.translationTarget), let first = targets.first {
                model.project.translationTarget = first
            }
        }
    }
}

// MARK: - More options

private struct MoreOptionsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("choose.moreOptions.expanded") private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                let made = model.project.hasGeneratedCaptions
                Picker("Caption length", selection: Binding(
                    get: { model.project.presetName },
                    set: { name in
                        model.project.presetName = name
                        if let p = CaptionRules.presets.first(where: { $0.name == name }) {
                            model.project.rules = p.rules
                        }
                    })) {
                    ForEach(CaptionRules.presets, id: \.name) { Text($0.name).tag($0.name) }
                }
                // With captions already made, the words control re-cuts them at once, as in
                // the editor; the preset and lines only apply to the next Make Captions.
                .disabled(made)
                WordsPerCaptionRows(appliesNow: made)
                Stepper(value: Binding(get: { model.project.rules.maxLinesPerCue },
                                       set: { model.project.rules.maxLinesPerCue = $0 }),
                        in: 1...2) {
                    LabeledContent("Lines per caption", value: "\(model.project.rules.maxLinesPerCue)")
                }
                .disabled(made)
                Toggle("Fix spelling and punctuation with Apple Intelligence",
                       isOn: Binding(get: { model.project.useRefinement },
                                     set: { model.project.useRefinement = $0 }))
                .disabled(!(model.systemState?.foundationModelAvailable ?? false))
                if let reason = model.systemState?.foundationModelReason {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
            } label: {
                Text("More options")
                    .font(.headline)
            }
        }
    }
}

// MARK: - Make captions

private struct GenerateBar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReplace = false

    private var isRunning: Bool { model.generation.isRunning }

    var body: some View {
        HStack(spacing: 10) {
            if let id = model.generateAfterDownload,
               let pack = model.extendedPacks.first(where: { $0.id == id }) {
                ProgressView(value: model.packDownloadProgress[id] ?? 0) {
                    Text("Downloading \(pack.displayName) (\(pack.formattedSize)) — captions start right after")
                        .font(.caption)
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
                Button("Cancel") { model.cancelPackDownload(pack) }
            } else if case .running(let stage, let fraction) = model.generation {
                ProgressView(value: fraction) { Text(stage).font(.caption) }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                Button("Cancel") { model.cancelGeneration() }
            } else if case .failed(let message) = model.generation {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.caution)
                    .lineLimit(2)
                    .help(message)
            } else {
                Text(willMake)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(buttonTitle) {
                // A project that already has captions: making them again replaces them,
                // so ask, as Listen Again does.
                if model.project.hasGeneratedCaptions { confirmReplace = true } else { model.generateOrDownload() }
            }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isRunning || model.generateAfterDownload != nil || model.isDetectingLanguage
                          || model.project.selectedOutputs.isEmpty || model.project.mediaURL == nil)
        }
        .confirmationDialog("Make the captions again?", isPresented: $confirmReplace) {
            Button("Replace Captions", role: .destructive) { model.redoTranscription() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.redoWarning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Says what will be made and with which model.
    private var willMake: String {
        guard let cap = model.currentCapability else { return "Choose the spoken language first" }
        let names = [OutputKind.romanized, .original, .translation]
            .filter { model.effectiveOutputs.contains($0) }
            .map { OutputLabels.cardTitle($0, languageCode: cap.languageCode, target: model.project.translationTarget) }
        guard !names.isEmpty else { return "Pick at least one kind of caption" }
        return "Will make: " + names.joined(separator: ", ") + " · " + engineName(cap)
    }

    private func engineName(_ cap: CapabilityRegistry.LanguageCapability) -> String {
        switch model.engineChoice(for: cap.languageTag) {
        case .pack(let id): return model.extendedPacks.first { $0.id == id }?.displayName ?? "Downloaded model"
        case .apple:        return "Apple (built in)"
        case .automatic:    return cap.engine.isApple ? "Apple (built in)" : "Automatic"
        }
    }

    private var buttonTitle: String {
        if let pack = model.missingModel {
            return "Download \(pack.displayName) (\(pack.formattedSize)) and Make Captions"
        }
        if case .failed = model.generation { return "Try Again" }
        return model.project.hasGeneratedCaptions ? "Make Captions Again…" : "Make Captions"
    }
}
