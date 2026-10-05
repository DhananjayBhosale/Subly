import SwiftUI
import SublyCaptions
import SublyEngine

/// The one place to see and manage speech models. It answers, without hovering:
/// what is on this Mac, what can be downloaded, what each is for, what it costs, and
/// which one to pick. Settings and the inspector link here instead of keeping copies.
struct EnginesView: View {
    @Environment(AppModel.self) private var model

    private var installed: [ExtendedEngineManager.ModelPack] {
        model.extendedPacks.filter { model.installedPackIDs.contains($0.id) }
    }
    private var available: [ExtendedEngineManager.ModelPack] {
        model.extendedPacks.filter { !model.installedPackIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            appleSection
            installedSection
            availableSection
            languagesSection
        }
        .formStyle(.grouped)
        .navigationTitle("Speech Models")
        .navigationSubtitle(installed.isEmpty ? "No models downloaded"
                            : "\(installed.count) model\(installed.count == 1 ? "" : "s") on this Mac")
    }

    private var appleSection: some View {
        Section {
            let ready = model.capabilities.filter { $0.engine.isApple && $0.assetState == .installed }.count
            let onDemand = model.capabilities.filter { $0.engine.isApple && $0.assetState != .installed }.count
            LabeledContent {
                Label("Always available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.ready)
            } label: {
                Text("Apple (built in)")
                Text("\(ready + onDemand) languages, nothing to download from Subly. \(ready) ready now; macOS fetches the others the first time you use them.")
            }
        } header: {
            Text("Built into your Mac")
        } footer: {
            Text("Works for most languages. Download a model below for Hinglish (Hindi in English letters), for a language macOS can't transcribe, or for better accuracy.")
        }
    }

    private var installedSection: some View {
        Section {
            if installed.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            } else {
                ForEach(installed, id: \.id) { PackRow(pack: $0) }
            }
        } header: {
            Text("Downloaded models")
        } footer: {
            if !installed.isEmpty {
                let used = installed.reduce(Int64(0)) { $0 + model.modelBytes($1) }
                Text("Using \(AppModel.formatBytes(used)) of disk. Removing a model never touches your captions.")
            }
        }
    }

    private var availableSection: some View {
        Section {
            ForEach(available, id: \.id) { PackRow(pack: $0) }
        } header: {
            Text("Available to download")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let free = Self.freeDiskBytes {
                    Text("Free on this Mac: \(AppModel.formatBytes(free)).")
                }
                Text("Low on space, or an older Mac: \(ExtendedEngineManager.smallPack.displayName) (\(ExtendedEngineManager.smallPack.formattedSize)) is the smallest we suggest. Subly never downloads anything on its own.")
            }
        }
    }

    private var languagesSection: some View {
        let ready = model.capabilities.filter { $0.assetState == .installed }
        return Section {
            if ready.isEmpty {
                Text("None yet. A language becomes ready the first time you make captions in it.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ready) { cap in
                    LabeledContent(cap.displayName, value: cap.engine.displayName)
                }
            }
        } header: {
            Text("Languages ready to use offline")
        }
    }

    static var freeDiskBytes: Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// One model, with everything needed to decide on it visible: what it is for, the
/// download size and memory, whether it is recommended for the current language, and
/// the one action that applies.
private struct PackRow: View {
    @Environment(AppModel.self) private var model
    let pack: ExtendedEngineManager.ModelPack
    @State private var confirmRemove = false

    private var installed: Bool { model.installedPackIDs.contains(pack.id) }
    private var downloading: Double? { model.packDownloadProgress[pack.id] }

    /// Recommended for the language of the open project, when there is one.
    private var recommendedFor: String? {
        guard let cap = model.currentCapability,
              ExtendedEngineManager.recommended(for: cap.languageCode).pack.id == pack.id,
              pack.serves(cap.languageCode) else { return nil }
        // Apple already covers most languages; only call a general model "recommended"
        // where it is actually needed.
        guard !pack.isGeneral || cap.engine.requiresDownload else { return nil }
        return cap.displayName
    }

    var body: some View {
        LabeledContent {
            if let fraction = downloading {
                HStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 100)
                    Button("Cancel") { model.cancelPackDownload(pack) }
                }
            } else if installed {
                Button("Remove…") { confirmRemove = true }
            } else {
                Button("Download") { model.installPack(pack) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(pack.displayName)
                if let language = recommendedFor {
                    Text("Recommended for \(language)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.info)
                }
            }
            Text(pack.bestFor)
            Text(installed ? "On this Mac · \(pack.formattedSize)" : pack.costLine)
        }
        .confirmationDialog("Remove \(pack.displayName)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.deletePack(pack) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(pack.formattedSize). Your captions are untouched and you can download it again at any time.")
        }
    }
}
