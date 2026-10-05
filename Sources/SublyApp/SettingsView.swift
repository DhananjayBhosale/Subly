import SwiftUI
import SublyCaptions
import SublyEngine

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LanguageSettings()
                .tabItem { Label("Languages", systemImage: "globe") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(18)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.appearance }, set: { model.appearance = $0 })) {
                    Text("Match System").tag(AppModel.Appearance.system)
                    Text("Light").tag(AppModel.Appearance.light)
                    Text("Dark").tag(AppModel.Appearance.dark)
                }
                .pickerStyle(.segmented)
            }

            Section("Defaults for new projects") {
                Picker("Caption length", selection: Binding(
                    get: { model.defaultPreset },
                    set: {
                        model.defaultPreset = $0
                        // A deliberate default replaces the remembered caption length.
                        UserDefaults.standard.removeObject(forKey: "lastRules")
                        UserDefaults.standard.removeObject(forKey: "lastPreset")
                    })) {
                    ForEach(CaptionRules.presets, id: \.name) { Text($0.name).tag($0.name) }
                }
                Picker("Subtitles to make", selection: Binding(
                    get: { model.defaultOutputsRaw },
                    set: {
                        model.defaultOutputsRaw = $0
                        // A deliberate default replaces what was used last time.
                        UserDefaults.standard.removeObject(forKey: "lastOutputs")
                    })) {
                    Text("Transcript").tag("original")
                    Text("In English letters (e.g. Hinglish)").tag("romanized")
                    Text("English letters + Translation").tag("romanized,translation")
                    Text("Translation").tag("translation")
                    Text("Transcript + Translation").tag("original,translation")
                    Text("All three").tag("original,translation,romanized")
                }
                Toggle("Fix spelling and punctuation with Apple Intelligence", isOn: Binding(
                    get: { model.useRefinementDefault }, set: { model.useRefinementDefault = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct LanguageSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ManageModelsSection()
            Section("Words to keep in English") {
                Text("Names and product words you want kept in English. Used when writing your language in English letters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Comma separated", text: Binding(
                    get: { model.protectedTermsRaw }, set: { model.protectedTermsRaw = $0 }),
                          axis: .vertical)
                .lineLimit(3...6)
            }
            LearnedSpellingsSection()
        }
        .formStyle(.grouped)
    }
}

/// The words Subly has learned to spell this person's way, from their corrections.
private struct LearnedSpellingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("Learn from my corrections", isOn: Binding(
                get: { model.learnsSpellings }, set: { model.learnsSpellings = $0 }))
            let rules = model.spellingPreferences.rules
            if rules.isEmpty {
                Text("When you change a word in a caption, for example “yah” to “ye”, Subly uses your spelling in new captions too.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rules.keys.sorted(), id: \.self) { tag in
                    ForEach(rules[tag, default: [:]].sorted(by: { $0.key < $1.key }), id: \.key) { heard, preferred in
                        HStack {
                            Text("\(heard) → \(preferred)")
                            Spacer()
                            Text(Self.languageName(tag)).font(.caption).foregroundStyle(.secondary)
                            Button {
                                model.spellingPreferences.forget(heard: heard, languageTag: tag)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Forget this spelling")
                            .accessibilityLabel("Forget \(heard) to \(preferred)")
                        }
                    }
                }
                Button("Forget All", role: .destructive) { model.spellingPreferences.forgetAll() }
            }
        } header: {
            Text("Your spellings")
        }
    }

    private static func languageName(_ tag: String) -> String {
        if tag.hasSuffix("-Latn"), let base = tag.split(separator: "-").first {
            let name = Locale.current.localizedString(forLanguageCode: String(base)) ?? String(base)
            return base == "hi" ? "Hinglish" : "\(name) in English letters"
        }
        return Locale.current.localizedString(forIdentifier: tag) ?? tag
    }
}

/// Models are managed in exactly one place, the Speech Models sheet in the main window.
/// Settings used to keep its own copy of the list, which removed a model without the
/// confirmation the main screen asks for and showed less about each one.
private struct ManageModelsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                Button("Manage Models…") { Self.open(model) }
            } label: {
                let count = model.installedPackIDs.count
                Text("Speech models")
                Text(count == 0 ? "Apple's built-in recognition only. Optional models add Hinglish and more languages."
                                : "\(count) downloaded. See what each is for, download more, or remove one.")
            }
        }
    }

    @MainActor
    static func open(_ model: AppModel) {
        model.showModels = true
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
    }
}

/// Project storage and temporary-file control.
/// What Subly is using on disk, itemised. Project storage and downloaded models were
/// reported in different places with different units, so the same 574 MB model also
/// appeared as 549 MB and nothing added up.
private struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var projects: Int64 = 0
    @State private var working: Int64 = 0
    @State private var backups: Int64 = 0
    @State private var settings: Int64 = 0
    @State private var models: [(name: String, bytes: Int64)] = []

    private var total: Int64 {
        projects + working + backups + settings + models.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        Form {
            Section("Disk space") {
                row("Video projects", projects)
                ForEach(models, id: \.name) { m in
                    row("\(m.name) model", m.bytes)
                }
                if !models.isEmpty {
                    Button("Remove Models…") { ManageModelsSection.open(model) }
                }
                row("Working files", working)
                if backups > 0 { row("Project backups", backups) }
                row("Settings", settings)
                Divider()
                LabeledContent("Total") {
                    Text(AppModel.formatBytes(total))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
            }

            Section("Video projects") {
                LabeledContent("Saved in") {
                    Text(model.projectsDirectory.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.projectsDirectory])
                }
            }

            Section {
                HStack {
                    Button("Reveal") { model.revealWorkingFiles() }
                    Button("Clear Now") { model.clearWorkingFiles(); refresh() }
                        .disabled(working == 0 || model.workInProgress != nil)
                }
            } header: {
                Text("Working files")
            } footer: {
                Text("Audio Subly extracts while generating captions. Safe to clear when Subly isn't making captions — it is rebuilt when needed.")
            }

            if backups > 0 {
                Section {
                    Button("Delete Backups", role: .destructive) {
                        model.deleteBackups(); refresh()
                    }
                } header: {
                    Text("Project backups")
                } footer: {
                    Text("Copies of your projects folder made before a bulk change.")
                }
            }

            Section {
                Button("Open Language & Region…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text("Apple language models")
            } footer: {
                Text("macOS downloads speech and translation models for its own frameworks and stores them outside Subly, so their size is not counted above and Subly cannot remove them. Manage them in System Settings.")
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .onChange(of: model.installedPackIDs) { _, _ in refresh() }
    }

    private func row(_ label: String, _ bytes: Int64) -> some View {
        LabeledContent(label) {
            Text(AppModel.formatBytes(bytes))
                .monospacedDigit()
                .foregroundStyle(bytes == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        }
    }

    private func refresh() {
        projects = model.projectsBytes()
        working = model.workingFilesBytes()
        backups = model.backupsBytes()
        settings = model.settingsBytes()
        models = model.extendedPacks
            .filter { model.installedPackIDs.contains($0.id) }
            .map { (name: $0.displayName, bytes: model.modelBytes($0)) }
    }
}


private struct AboutSettings: View {
    @Environment(AppModel.self) private var model

    /// "Version 1.0 (202610041623)", for bug reports.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subly").font(.title2.weight(.semibold))
                    Text("Local subtitles for creators")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(Self.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Divider()
            if let state = model.systemState {
                LabeledContent("Apple Intelligence",
                               value: state.foundationModelAvailable ? "Available" : "Unavailable")
                LabeledContent("Speech recognition",
                               value: state.speechTranscriberAvailable ? "Available" : "Unavailable")
                LabeledContent("Languages", value: "\(model.capabilities.count)")
                LabeledContent("No download needed", value: "\(state.appleLanguageCount)")
            }
            Divider()
            Text("Your video and audio never leave this Mac. The only network use is downloading models: macOS fetches a language's speech model the first time you caption in it, and the extra-language downloads happen only when you ask for them. Once a model is on your Mac, captioning makes no network request at all.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Acknowledgements…") {
                    if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") == nil)
                .help("Licences for whisper.cpp and the speech models")
                Button("Subly on GitHub") { NSWorkspace.shared.open(AppModel.helpURL) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
