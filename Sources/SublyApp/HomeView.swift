import SwiftUI
import UniformTypeIdentifiers
import SublyCaptions
import SublyEngine

/// Step 1: drop a video, or pick up a project. Every project is here as a picture, and
/// several can be picked to delete at once — the sidebar listed six and deleted one
/// per right-click.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirming: [ProjectDocument] = []

    private var projects: [ProjectDocument] { model.distinctRecentProjects }

    /// Captions being made, or the model for them downloading. Opening another project
    /// then would stop that work, and the new project is not saved until it finishes.
    private var isBusy: Bool { model.generation.isRunning || model.generateAfterDownload != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isBusy { RunningCard() }
                DropCard()
                if projects.isEmpty {
                    HowItWorks()
                } else {
                    header
                    grid
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, selecting ? 84 : 28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            if selecting { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PrivacyFooter() }
        .animation(Motion.standard, value: selecting)
        .navigationTitle("Subly")
        .navigationSubtitle(projects.isEmpty ? "" : "\(projects.count) project\(projects.count == 1 ? "" : "s")")
        .confirmationDialog(confirmTitle,
                            isPresented: Binding(get: { !confirming.isEmpty },
                                                 set: { if !$0 { confirming = [] } })) {
            Button(confirming.count > 1 ? "Delete \(confirming.count) Projects" : "Delete Project",
                   role: .destructive) {
                model.deleteProjects(confirming)
                selection.subtract(confirming.map(\.id))
                confirming = []
                if projects.isEmpty { endSelecting() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their captions and edits move to the Trash. Your video files stay where they are.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Your Projects").font(.title3.weight(.semibold))
            Spacer()
            if selecting {
                Button("Select All") { selection = Set(projects.map(\.id)) }
                    .keyboardShortcut("a")
            }
            Button(selecting ? "Done" : "Select") {
                selecting ? endSelecting() : (selecting = true)
            }
            .help(selecting ? "Stop selecting" : "Pick several projects to delete. ⌘-click works too.")
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 230), spacing: 18, alignment: .top)],
                  alignment: .leading, spacing: 20) {
            ForEach(projects, id: \.id) { doc in
                // A real button, so the keyboard and VoiceOver can open a project too.
                Button { tap(doc) } label: {
                    ProjectCard(doc: doc,
                                directory: model.projectsDirectory,
                                isMissing: model.missingMediaProjects.contains(doc.id),
                                selecting: selecting,
                                isSelected: selection.contains(doc.id))
                }
                .buttonStyle(.plain)
                .help(isBusy && !selecting ? "Wait for the captions being made, or cancel them above" : doc.name)
                    .contextMenu {
                        Button("Open") { open(doc) }
                            .disabled(isBusy)
                        Button("Show Video in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: doc.mediaPath)])
                        }
                        Divider()
                        let ids = selection.contains(doc.id) && selection.count > 1 ? selection : [doc.id]
                        Button(ids.count > 1 ? "Delete \(ids.count) Projects…" : "Delete…", role: .destructive) {
                            askToDelete(ids)
                        }
                    }
                    .accessibilityAddTraits(selection.contains(doc.id) ? .isSelected : [])
                    .accessibilityHint(selecting ? "Selects or deselects this project" : "Opens this project")
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(selection.isEmpty ? "Click projects to select them" : "\(selection.count) selected")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { endSelecting() }
                .keyboardShortcut(.cancelAction)
            // Keys on the buttons, which work wherever focus is: the grid itself can't
            // take keyboard focus, so Delete and Escape on it did nothing.
            Button(selection.count > 1 ? "Delete \(selection.count) Projects…" : "Delete…", role: .destructive) {
                askToDelete(selection)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selection.isEmpty)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 16)
    }

    /// A click opens; while selecting — or with ⌘ or ⇧ held, as in Finder — it picks.
    private func tap(_ doc: ProjectDocument) {
        let flags = NSEvent.modifierFlags
        if selecting || flags.contains(.command) || flags.contains(.shift) {
            selecting = true
            if selection.contains(doc.id) { selection.remove(doc.id) } else { selection.insert(doc.id) }
        } else if !isBusy {
            open(doc)
        }
    }

    private func open(_ doc: ProjectDocument) {
        model.openProject(doc)
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    private func askToDelete(_ ids: Set<UUID>) {
        confirming = projects.filter { ids.contains($0.id) }
    }

    private var confirmTitle: String {
        confirming.count == 1 ? "Delete “\(confirming[0].name)”?" : "Delete \(confirming.count) projects?"
    }

    /// "Hindi · 1:08 · Yesterday" — which video, how long, and when.
    static func detail(_ doc: ProjectDocument) -> String {
        let code = doc.sourceLanguage.split(separator: "-").first.map(String.init) ?? doc.sourceLanguage
        var parts = [CapabilityRegistry.displayName(code)]
        if let seconds = doc.spine?.duration, seconds > 0 { parts.append(Format.duration(seconds)) }
        let when = doc.modifiedAt.formatted(.relative(presentation: .named))
        parts.append(when.prefix(1).uppercased() + when.dropFirst())
        return parts.joined(separator: " · ")
    }
}

// MARK: - Work in progress

/// Shown while captions are being made, so leaving the Choose step doesn't look like
/// the work was lost — and there is a way back to it.
private struct RunningCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Making captions for “\(model.project.name)”")
                    .font(.headline)
                Text(stage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Show") { model.route = model.project.hasGeneratedCaptions ? .editor : .newProject }
            Button("Cancel", role: .cancel) {
                if let id = model.generateAfterDownload,
                   let pack = model.extendedPacks.first(where: { $0.id == id }) {
                    model.cancelPackDownload(pack)
                } else {
                    model.cancelGeneration()
                }
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        }
    }

    private var stage: String {
        if case .running(let stage, let fraction) = model.generation {
            return "\(stage) · \(Int(fraction * 100))%"
        }
        if let id = model.generateAfterDownload, let pack = model.extendedPacks.first(where: { $0.id == id }) {
            return "Downloading \(pack.displayName) first · \(Int((model.packDownloadProgress[id] ?? 0) * 100))%"
        }
        return ""
    }
}

// MARK: - First run

/// What happens after the drop, for someone who has never made a project: the empty
/// window under the drop target said nothing about what Subly does.
private struct HowItWorks: View {
    private let steps: [(icon: String, title: String, text: String)] = [
        ("film", "1. Add a video",
         "Drop it above or choose it. It stays on this Mac — nothing is uploaded."),
        ("text.bubble", "2. Choose your captions",
         "Hindi, Hinglish (Hindi in English letters) or a translation. Pick several and they share the same timing."),
        ("square.and.arrow.up", "3. Edit and share",
         "Fix a word by clicking it on the video, pick a look, then save a subtitle file or a video for Reels."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works").font(.title3.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { tiles }
                VStack(alignment: .leading, spacing: 10) { tiles }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var tiles: some View {
        ForEach(steps, id: \.title) { step in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: step.icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title).font(.headline)
                    Text(step.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(minWidth: 220, idealWidth: 320, maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Drop target

private struct DropCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.25 : 0.12))
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "film")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 72, height: 72)
            .scaleEffect(isTargeted ? 1.06 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(isTargeted ? "Drop to start" : "Drop a video to make captions")
                    .font(.title2.weight(.semibold))
                Text("MP4, MOV or an audio file. Everything happens on this Mac — nothing is uploaded.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Choose Video…") { pick() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.generation.isRunning || model.generateAfterDownload != nil)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background.secondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                              style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: isTargeted ? [] : [7, 5]))
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.generation.isRunning, let url = urls.first(where: RootView.isMedia) else { return false }
            Task { await model.importMedia(url) }
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop a video or audio file to start, or choose a file")
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.acceptedTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importMedia(url) }
        }
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    let doc: ProjectDocument
    let directory: URL
    let isMissing: Bool
    let selecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { ProjectThumbnailView(id: doc.id, directory: directory, name: doc.name) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                      lineWidth: isSelected ? 3 : 0.5)
                }
                .overlay(alignment: .topLeading) {
                    if selecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.35)))
                            .padding(8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isMissing {
                        Label("Video not found", systemImage: "film.badge.exclamationmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(7)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(HomeView.detail(doc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(.rect)
        .help(doc.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(doc.name), \(HomeView.detail(doc))\(isMissing ? ", video not found" : "")")
        .animation(Motion.selection, value: isSelected)
    }
}

/// The saved picture of a project's video, or a placeholder until there is one.
struct ProjectThumbnailView: View {
    let id: UUID
    let directory: URL
    let name: String
    @State private var image: NSImage?

    /// A steady colour per project, so placeholders can be told apart.
    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                    Color(hue: hue, saturation: 0.55, brightness: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .task(id: id) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .projectThumbnailReady)) { note in
            if (note.object as? UUID) == id { Task { await load() } }
        }
    }

    private func load() async {
        let url = ProjectThumbnail.url(for: id, in: directory)
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        image = data.flatMap(NSImage.init(data:))
    }
}

/// Where the privacy promise and the speech models live, now that there is no sidebar.
private struct PrivacyFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.laptopcomputer")
                .foregroundStyle(.secondary)
            Text("On this Mac · nothing is uploaded")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Speech Models…") { model.showModels = true }
                .help("See, download and remove speech models")
            SettingsLink {
                Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .help("Settings — appearance, default captions, storage")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
