import SwiftUI
import SublyCaptions
import SublyEngine

/// The language and engine controls, shared by New Project and the caption editor.
///
/// These used to exist only before generating. If you picked the wrong language — or
/// the app guessed it — the editor gave you no way to see what had been used, let alone
/// change it. A Hindi clip captioned with an English recogniser produced unusable text
/// and the only escape was to start a new project.
struct TranscriptionSettings: View {
    @Environment(AppModel.self) private var model
    enum Part { case language, names, model, translation }
    /// Which rows to show. The Choose step puts each in its own section.
    var parts: Set<Part> = [.language, .names, .model, .translation]
    /// Editor mode adds re-run affordances and warns that they replace existing tracks.
    var showsRedo: Bool = false
    @State private var targets: [String] = ["en"]
    @State private var confirmRedo = false
    /// Typed text, kept as typed: parsing it on every keystroke ate the comma and
    /// space before the next name could be entered.
    @State private var namesText = ""

    private var cap: CapabilityRegistry.LanguageCapability? { model.currentCapability }

    var body: some View {
        if parts.contains(.language) { languageRow }
        if parts.contains(.names) { namesRow }
        if parts.contains(.model), let cap {
            engineRows(cap)
            // Apple's speech files matter only when Apple's engine will do the work.
            if !model.engineChoice(for: cap.languageTag).isPack { speechAssetRows(cap) }
        }
        if parts.contains(.translation) { translationRow }
        if showsRedo { redoRow }
    }

    // MARK: Language

    @ViewBuilder
    private var languageRow: some View {
        LabeledContent("Spoken language") {
            HStack(spacing: 6) {
                if let cap {
                    Text(cap.displayName)
                    if cap.transcriptionTier.showsBadge {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Palette.caution)
                            .help("Subly hasn't checked the quality of this language yet")
                    }
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
                Button("Change…") { model.showLanguagePicker = true }
                Button {
                    Task { await model.autoDetectLanguage() }
                } label: {
                    if model.isDetectingLanguage {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Detect")
                    }
                }
                .disabled(model.isDetectingLanguage)
                .help("Listen to the start of the video and pick the language")
            }
        }
        if let note = model.detectionNote, note.projectID == model.project.id,
           note.language == model.project.sourceLanguage {
            Label(note.text, systemImage: note.unsure ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.callout)
                .foregroundStyle(note.unsure ? AnyShapeStyle(Palette.caution) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Names

    /// Brands and people the recogniser can't know. Apex wrote "Amaz Fit Terex" and
    /// "chess trap" until it was told "Amazfit T-Rex Ultra 2, chest strap".
    private var namesRow: some View {
        LabeledContent {
            TextField("Names and brands", text: $namesText, prompt: Text("Fitbit Air, Whoop"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: 220)
                .onAppear { namesText = model.project.vocabulary.joined(separator: ", ") }
                .onChange(of: model.project.id) { namesText = model.project.vocabulary.joined(separator: ", ") }
                .onChange(of: namesText) {
                    let names = namesText.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard names != model.project.vocabulary else { return }
                    model.project.vocabulary = names
                    if model.project.hasResults { model.scheduleAutosave() }
                }
        } label: {
            Text("Names and brands")
            Text("Optional. Separate with commas.")
        }
    }

    // MARK: Apple speech assets

    @ViewBuilder
    private func speechAssetRows(_ cap: CapabilityRegistry.LanguageCapability) -> some View {
        if cap.engine.requiresDownload {
            // The model rows above already say what is needed and offer the download.
            EmptyView()
        } else if cap.assetState == .downloadable {
            if model.assetInstallLanguage == cap.languageTag {
                LabeledContent("Downloading") {
                    ProgressView(value: model.assetInstallProgress).frame(maxWidth: 140)
                }
            } else {
                LabeledContent {
                    Button("Get It Now") { model.installAssets(for: cap.languageTag) }
                } label: {
                    Text("Apple's \(cap.displayName) speech files")
                    Text("One-time download.")
                }
            }
        }
    }

    // MARK: Engine

    private func engineOptions(_ cap: CapabilityRegistry.LanguageCapability) -> [EngineOption] {
        EngineOption.all(languageCode: cap.languageCode,
                         appleHandles: !cap.engine.requiresDownload,
                         appleEngineName: cap.engine.displayName,
                         installedPackIDs: model.installedPackIDs)
    }

    /// One picker plus one visible line about the chosen model. What a model is for,
    /// what it costs and whether it is here used to live in tooltips, which a Mac user
    /// never sees unless they hover — so nobody could tell which model to pick.
    @ViewBuilder
    private func engineRows(_ cap: CapabilityRegistry.LanguageCapability) -> some View {
        let opts = engineOptions(cap)
        let current = model.engineChoice(for: cap.languageTag)
        let selected = opts.first { $0.choice == current }
        let pack = selected?.packID.flatMap { id in ExtendedEngineManager.allPacks.first { $0.id == id } }

        recommendedRow(cap, opts: opts, current: current)

        let picker = Picker("Model", selection: Binding(
            get: { current },
            set: { model.setEngineChoice($0, for: cap.languageTag) })) {
            ForEach(opts) { o in
                Text(label(for: o)).tag(o.choice)
            }
        }
        if showsRedo {
            // Stacked in the editor: in its narrow inspector a labelled picker truncated
            // the model name to "Apex — Reco…" and squeezed the description into a
            // column one word wide.
            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.body)
                picker
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(summary(selected, pack: pack, cap: cap))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // New Project has room: a normal labelled row, aligned with the others.
            LabeledContent {
                picker.labelsHidden().fixedSize()
            } label: {
                Text("Model")
                Text(summary(selected, pack: pack, cap: cap))
            }
        }

        if let pack {
            if let fraction = model.packDownloadProgress[pack.id] {
                LabeledContent("Downloading \(pack.displayName)") {
                    HStack(spacing: 6) {
                        ProgressView(value: fraction).frame(width: 90)
                        Button("Cancel") { model.cancelPackDownload(pack) }
                    }
                }
            } else if model.installedPackIDs.contains(pack.id) {
                LabeledContent {
                    Button("Manage Models…") { model.showModels = true }
                } label: {
                    Label("On this Mac", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.ready)
                }
            } else {
                LabeledContent {
                    Button("Download Now") { model.installPack(pack) }
                } label: {
                    Text("Not downloaded yet")
                    Text("\(pack.formattedSize), downloaded once.")
                }
            }
        }

        // A model made for another language: say what it does, and how to get to it.
        // Only for languages written in English letters anyway — the usual case is a
        // Hindi video left on English. Offering "Switch to Hindi" on a Marathi project
        // would point a Marathi speaker at the wrong language.
        // New Project only: in the editor of an English project it was just an advert
        // for another language's model.
        let latinScript = !ScriptProfile.forLanguage(cap.languageCode).romanizable && !showsRedo
        ForEach(latinScript ? EngineOption.specialisedElsewhere(languageCode: cap.languageCode) : [],
                id: \.pack.id) { item in
            let langs = item.languageCodes.map { CapabilityRegistry.displayName($0) }
                .joined(separator: " or ")
            LabeledContent {
                if let target = firstUsable(item.languageCodes) {
                    Button("Switch to \(langs)") { model.switchSpokenLanguage(to: target.languageTag) }
                }
            } label: {
                Text("\(item.pack.displayName) is for \(langs) only")
            }
        }

    }

    /// The best model for the spoken language, one click away, above the full list:
    /// "How accurate?" asked people to judge something they had no way to know.
    @ViewBuilder
    private func recommendedRow(_ cap: CapabilityRegistry.LanguageCapability,
                                opts: [EngineOption],
                                current: TranscriptionService.EngineChoice) -> some View {
        if let best = opts.first(where: \.isRecommended),
           let pack = best.packID.flatMap({ id in ExtendedEngineManager.allPacks.first { $0.id == id } }) {
            let name = pack.emitsRomanized ? "\(pack.displayName) (Hinglish)" : pack.displayName
            LabeledContent {
                if current == best.choice {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.ready)
                } else {
                    Button(best.needsDownload ? "Use It (\(pack.formattedSize))" : "Use It") {
                        model.setEngineChoice(best.choice, for: cap.languageTag)
                        if pack.emitsRomanized { model.project.selectedOutputs.insert(.romanized) }
                    }
                }
            } label: {
                Text("Best for \(cap.displayName): \(name)")
            }
        }
    }

    // MARK: Translation

    /// Shown whenever a translation exists **or** is selected, so the editor can answer
    /// "what did it translate into?" — which it previously could not.
    @ViewBuilder
    private var translationRow: some View {
        let hasTrack = model.project.tracks.contains { $0.kind == .translation && !$0.isReference }
        if hasTrack || model.project.selectedOutputs.contains(.translation) {
            Picker("Translate into", selection: Binding(
                get: { model.project.translationTarget },
                set: { new in
                    guard new != model.project.translationTarget else { return }
                    if hasTrack { model.retranslate(to: new) }
                    else { model.project.translationTarget = new }
                })) {
                ForEach(targets, id: \.self) {
                    Text(CapabilityRegistry.displayName($0)).tag($0)
                }
            }
            .task(id: model.project.sourceLanguage) { await refreshTargets() }
            .disabled(hasTrack && model.generation.isRunning)
        }
    }

    /// One line per menu item — a native menu cannot show two. Name, then the facts
    /// that decide the choice: recommended, size, and whether it still needs a download.
    /// "Recommended" used to vanish until the model was downloaded, which is exactly
    /// when someone needs to see it.
    private func label(for o: EngineOption) -> String {
        guard let id = o.packID, let pack = ExtendedEngineManager.allPacks.first(where: { $0.id == id }) else {
            return o.name
        }
        var parts: [String] = []
        if o.isRecommended { parts.append("Recommended") }
        // "Downloaded" is said by the row below; in the menu it only cost width.
        if o.needsDownload { parts.append("\(pack.formattedSize) download") }
        let name = pack.emitsRomanized ? "\(o.name) (Hinglish)" : o.name
        return parts.isEmpty ? name : "\(name) — " + parts.joined(separator: ", ")
    }

    /// The visible line under the picker.
    private func summary(_ o: EngineOption?, pack: ExtendedEngineManager.ModelPack?,
                         cap: CapabilityRegistry.LanguageCapability) -> String {
        guard let o else { return "" }
        if let pack {
            return pack.bestFor
        }
        switch o.choice {
        case .apple: return "Built into macOS."
        case .automatic:
            if cap.engine.isApple { return "Uses Apple (built in)." }
            if let installed = ExtendedEngineManager.allPacks.first(where: {
                model.installedPackIDs.contains($0.id) && $0.serves(cap.languageCode) }) {
                return "Uses \(installed.displayName)."
            }
            let best = ExtendedEngineManager.recommended(for: cap.languageCode).pack
            return "Needs \(best.displayName) (\(best.formattedSize))."
        case .pack: return ""
        }
    }

    /// The first of `codes` this Mac can actually transcribe.
    private func firstUsable(_ codes: [String]) -> CapabilityRegistry.LanguageCapability? {
        for code in codes {
            if let cap = model.capabilities.first(where: {
                $0.languageCode == code && $0.assetState == .installed
            }) { return cap }
        }
        return model.capabilities.first { codes.contains($0.languageCode) }
    }

    private func refreshTargets() async {
        guard let cap else { return }
        let list = cap.translationTargets.filter { $0 != cap.languageCode }
        targets = list.isEmpty ? [model.project.translationTarget] : list
        if !targets.contains(model.project.translationTarget), let first = targets.first {
            model.project.translationTarget = first
        }
    }

    // MARK: Redo

    /// "Redo" shared its name with Edit › Redo, and changing the language did nothing
    /// visible until it was pressed — the captions stayed in the old language with no
    /// hint why. Now the row says when they no longer match and what pressing it does.
    @ViewBuilder
    private var redoRow: some View {
        if let stale = model.captionLanguageMismatch {
            Label("These captions are still in \(stale.was). Listen again to make them in \(stale.now).",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(Palette.caution)
        }
        LabeledContent {
            Button(model.missingModel.map { "Download \($0.displayName) and Listen Again…" } ?? "Listen Again…") {
                confirmRedo = true
            }
            .disabled(model.generation.isRunning || model.generateAfterDownload != nil)
        } label: {
            Text("Make captions again")
            Text("Listens to the whole video again, from the start, with the settings above.")
        }
        .confirmationDialog("Listen to the video again?", isPresented: $confirmRedo) {
            Button("Replace Captions", role: .destructive) { model.redoTranscription() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.redoWarning)
        }
    }
}
