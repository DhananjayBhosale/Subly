import SwiftUI
import SublyCaptions
import SublyEngine

/// ~64 languages need real navigation, not a long menu: search, region grouping, and
/// per-language capability badges.
struct LanguagePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showUnverified = true

    private var groups: [(CapabilityRegistry.Region, [CapabilityRegistry.LanguageCapability])] {
        model.groupedCapabilities.compactMap { region, items in
            let filtered = items.filter { cap in
                let matches = query.isEmpty
                    || cap.displayName.localizedCaseInsensitiveContains(query)
                    || cap.endonym.localizedCaseInsensitiveContains(query)
                    || cap.languageCode.localizedCaseInsensitiveContains(query)
                let tierOK = showUnverified || cap.transcriptionTier > .available
                return matches && tierOK
            }
            return filtered.isEmpty ? nil : (region, filtered)
        }
    }

    private var totalShown: Int { groups.reduce(0) { $0 + $1.1.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if totalShown == 0 {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.0) { region, items in
                        Section {
                            ForEach(items) { cap in
                                LanguageRow(cap: cap) { select(cap) }
                            }
                        } header: {
                            HStack {
                                Text(region.rawValue)
                                Spacer()
                                Text("\(items.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spoken language").font(.headline)
                    Text("The language people speak in the video. Every language listed works on this Mac; some need a one-time download first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(spacing: 10) {
                TextField("Search languages", text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Include languages we haven't checked yet", isOn: $showUnverified)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("\(totalShown) languages", systemImage: "globe")
            if let state = model.systemState {
                Label("\(state.appleLanguageCount) with no download", systemImage: "bolt.badge.checkmark")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func select(_ cap: CapabilityRegistry.LanguageCapability) {
        withAnimation(Motion.selection) {
            model.project.sourceLanguage = cap.languageTag
            model.pruneUnavailableOutputs()
        }
        dismiss()
    }
}

private struct LanguageRow: View {
    @Environment(AppModel.self) private var model
    let cap: CapabilityRegistry.LanguageCapability
    let action: () -> Void

    /// Spoken by VoiceOver: the row's visible status, which the combined label hid.
    private var statusText: String {
        switch cap.assetState {
        case .installed:   return "Ready"
        case .downloadable: return cap.engine.requiresDownload ? "Needs a model download" : "macOS downloads it once"
        case .downloading: return "Downloading"
        case .unavailable: return "Unavailable"
        }
    }

    private var isSelected: Bool {
        model.currentCapability?.languageCode == cap.languageCode
    }
    private var outputs: [OutputKind] {
        OutputKind.allCases.filter { cap.supports($0) }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cap.displayName).font(.body.weight(.medium))
                        if !cap.endonym.isEmpty, cap.endonym != cap.displayName {
                            Text(cap.endonym)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if cap.transcriptionTier == .flagship {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(Palette.info)
                                .help("Quality verified against real footage in this language.")
                        } else if cap.transcriptionTier.showsBadge {
                            Text("Not yet verified")
                                .font(.caption)
                                .foregroundStyle(Palette.caution)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(cap.engine.displayName)
                        Text("·")
                        Text(outputs.map(\.shortLabel).joined(separator: " · "))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                switch cap.assetState {
                case .installed:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.ready)
                case .downloadable:
                    if cap.engine.requiresDownload {
                        Label("Needs a model (\(ExtendedEngineManager.recommended(for: cap.languageCode).pack.formattedSize))",
                              systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("macOS downloads once", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .downloading:
                    ProgressView().controlSize(.small)
                case .unavailable:
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cap.displayName), \(cap.engine.displayName), outputs: \(outputs.map(\.shortLabel).joined(separator: ", "))")
        .accessibilityValue(statusText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
