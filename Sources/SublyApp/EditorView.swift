import SwiftUI
import AVFoundation
import SublyCaptions
import SublyEngine

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutMode) private var layout
    @State private var confirmRedo = false
    /// The caption list joins the window a moment after the editor appears. Present
    /// from the first frame, its table left the window's toolbar blank — no steps,
    /// no buttons — until the next relaunch.
    @State private var listReady = false
    private var showPanel: Bool { model.showInspector }

    var body: some View {
        Group {
            if model.project.hasResults {
                studio
            } else {
                ContentUnavailableView {
                    Label("No Captions Yet", systemImage: "text.word.spacing")
                } description: {
                    Text("Choose what to make, then press Make Captions.")
                } actions: {
                    Button(model.project.mediaURL != nil ? "Choose Captions" : "Add a Video") {
                        model.route = model.project.mediaURL != nil ? .newProject : .home
                    }
                }
            }
        }
        .overlay(alignment: .top) { generationBanner }
        .navigationTitle(model.project.name)
        .navigationSubtitle(subtitleLine)
        // Customizable, as Mac toolbars are expected to be: right-click it (or View ›
        // Customize Toolbar…) to add, remove and rearrange buttons. A new id, so the
        // new default set shows instead of an arrangement saved for the old editor.
        .toolbar(id: "studio") { toolbarContent }
        .toolbarRole(.editor)
        .confirmationDialog("Listen to the video again?", isPresented: $confirmRedo) {
            Button("Replace Captions", role: .destructive) { model.redoTranscription() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.redoWarning)
        }
        .onAppear { model.attachTimeObserver() }
        .task { await Task.yield(); listReady = true }
        .onChange(of: model.player) { _, _ in model.attachTimeObserver() }
    }

    // MARK: - Layout

    /// The video, big, with the caption on it to click and drag; playback, a strip of
    /// captions and the timeline under it; and one panel beside it for the captions,
    /// their look and sharing.
    private var studio: some View {
        // Beside the video at every width. Laid over it on narrow windows, the panel
        // hid half of the picture it was styling.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                stage
                Divider()
                bottomArea
            }
            .frame(minWidth: 340, maxWidth: .infinity)
            if showPanel {
                Divider()
                EditorPanel()
                    .frame(width: Metrics.inspectorWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(Motion.standard, value: showPanel)
        .background(.background)
    }

    private var stage: some View {
        VideoPreview()
            .padding(.horizontal, layout == .compact ? 12 : 24)
            .padding(.vertical, layout == .compact ? 10 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var bottomArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TransportBar()
                Picker("Show", selection: Binding(get: { model.showCaptionList },
                                                  set: { new in withAnimation(Motion.standard) { model.showCaptionList = new } })) {
                    Label("Timeline", systemImage: "timeline.selection").tag(false)
                    Label("List", systemImage: "list.bullet").tag(true)
                }
                // Icons alone on a narrow window, where the words pushed the playback
                // controls into each other.
                .labelStyle(layout == .compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleOnly))
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.trailing, 12)
                .help("Show the timeline, or every caption as an editable list (⌥⌘L)")
            }
            if model.showCaptionList {
                Group {
                    if listReady { CueGridView() } else { Color.clear }
                }
                .frame(height: layout == .compact ? 220 : 290)
            } else {
                CaptionStrip()
                    .frame(height: 64)
                TimelineView()
                    .frame(height: layout == .compact ? Metrics.timelineCompactHeight : 118)
                    .padding(.horizontal, layout == .compact ? 10 : 14)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .background(.background)
    }

    /// Shown while a re-transcription runs. Redo gave no feedback at all, so the app
    /// looked frozen for the half-minute it takes — the work was happening, nothing
    /// said so.
    @ViewBuilder
    private var generationBanner: some View {
        if let missing = model.mediaMissingPath {
            // The relink button lived on the New Project screen, which a project with
            // captions never shows, so a moved video could not be found again.
            banner {
                HStack(spacing: 10) {
                    Image(systemName: "film.badge.exclamationmark").foregroundStyle(Palette.caution)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Can't find “\((missing as NSString).lastPathComponent)”").font(.callout.weight(.semibold))
                        Text("Your captions are safe and still saved. Choose the video to play it again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Choose Video…") { model.relinkMedia() }.controlSize(.small)
                }
            }
        } else if let fraction = model.videoExportProgress {
            banner {
                HStack(spacing: 10) {
                    Text("Saving the video with captions").font(.callout)
                    Spacer(minLength: 8)
                    Text("\(Int(fraction * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Button("Cancel") { model.cancelVideoExport() }
                        .controlSize(.small)
                        .keyboardShortcut(".", modifiers: .command)
                }
                ProgressView(value: fraction) { Text("Saving the video with captions") }
                    .labelsHidden()
            }
        } else if let id = model.generateAfterDownload,
           let pack = model.extendedPacks.first(where: { $0.id == id }) {
            banner {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(pack.displayName) (\(pack.formattedSize))").font(.callout)
                    Spacer(minLength: 8)
                    Button("Cancel") { model.cancelPackDownload(pack) }.controlSize(.small)
                }
                ProgressView(value: model.packDownloadProgress[id] ?? 0)
                Text("Your captions are redone as soon as it finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if case .failed(let message) = model.generation {
            banner {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.caution)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't redo the captions").font(.callout.weight(.semibold))
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Your existing captions are unchanged.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("OK") { model.generation = .idle }.controlSize(.small)
                }
            }
        } else if case .running(let stage, let fraction) = model.generation {
            banner {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.callout)
                    Spacer(minLength: 8)
                    Text("\(Int(fraction * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelGeneration() }
                        .controlSize(.small)
                }
                ProgressView(value: fraction)
                Text("Listening to the whole video again, from the start. Your current captions stay until the new ones are ready.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(Motion.standard, value: fraction)
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 6, content: content)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Plain language only. The engine id and the locale tag are implementation detail.
    private var subtitleLine: String {
        let tracks = model.project.tracks.filter { !$0.isReference }.count
        let count = "\(tracks) caption track\(tracks == 1 ? "" : "s")"
        guard let language = model.currentCapability?.displayName else { return count }
        return "\(language) · \(count)"
    }

    // MARK: - Toolbar

    /// Default set first, then extras people can drag in from Customize Toolbar….
    /// Views here get the model passed in: toolbar items are hosted outside the window's
    /// environment, and reading it from there crashed the app before.
    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        ToolbarItem(id: "steps", placement: .principal) { StepBar(model: model) }
            .customizationBehavior(.disabled)
        editingItems
        ToolbarSpacer(.fixed, placement: .primaryAction)
        windowItems
    }

    @ToolbarContentBuilder
    private var editingItems: some CustomizableToolbarContent {
        ToolbarItem(id: "undo", placement: .primaryAction) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(model.undoStack.isEmpty)
                .help(model.undoStack.last.map { "Undo \($0.label) (⌘Z)" } ?? "Undo (⌘Z)")
        }
        ToolbarItem(id: "redoEdit", placement: .primaryAction) {
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(model.redoStack.isEmpty)
                .help("Redo (⇧⌘Z)")
        }
        ToolbarItem(id: "split", placement: .primaryAction) {
            Button { model.splitCaptionAtPlayhead() } label: {
                Label("Split Caption", systemImage: "scissors")
            }
            .help("Split the caption at the playhead, or between its middle words when the playhead is at its start (⌘K)")
        }
        ToolbarItem(id: "merge", placement: .primaryAction) {
            Button { model.mergeCaptionWithNext() } label: {
                Label("Merge Captions", systemImage: "arrow.triangle.merge")
            }
            .help("Merge this caption with the next one (⌘J)")
        }
        ToolbarItem(id: "addTrack", placement: .primaryAction) {
            AddOutputMenu(model: model)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "playPause", placement: .primaryAction) {
            Button { model.togglePlayback() } label: {
                Label(model.isPlaying ? "Pause" : "Play",
                      systemImage: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Play or pause (Space)")
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "tidy", placement: .primaryAction) {
            Button { model.reflow(trackID: nil) } label: {
                Label("Tidy Lines", systemImage: "text.alignleft")
            }
            .help("Re-fit the lines to your caption style. Your words are not changed.")
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "redo", placement: .primaryAction) {
            Button { confirmRedo = true } label: {
                Label("Listen Again", systemImage: "arrow.clockwise")
            }
            .help("Make the captions again with the current language and speech model")
            .disabled(model.generation.isRunning)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "zoomOut", placement: .primaryAction) {
            Button { model.timelineZoomRequest -= 1 } label: {
                Label("Zoom Out Timeline", systemImage: "minus.magnifyingglass")
            }
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "zoomIn", placement: .primaryAction) {
            Button { model.timelineZoomRequest += 1 } label: {
                Label("Zoom In Timeline", systemImage: "plus.magnifyingglass")
            }
        }
        .defaultCustomization(.hidden)
    }

    @ToolbarContentBuilder
    private var windowItems: some CustomizableToolbarContent {
        ToolbarItem(id: "share", placement: .primaryAction) {
            // Both kinds of export behind one button, video first: it is what Reels and
            // Shorts need.
            Menu {
                Button("Video with Captions…") { model.exportCaptionedVideo() }
                    .disabled(model.videoExportProgress != nil)
                Button("Subtitle File (SRT)…") { model.saveSRT() }
                Button("More Formats…") { model.showExport = true }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Save a video with the captions drawn in, or a subtitle file such as SRT")
        }
        ToolbarItem(id: "panel", placement: .primaryAction) {
            Button { model.showInspector.toggle() } label: {
                Label("Side Panel", systemImage: "sidebar.trailing")
            }
            .help(model.showInspector ? "Hide the Captions, Look and Share panel (⌥⌘I)"
                                      : "Show the Captions, Look and Share panel (⌥⌘I)")
        }
    }
}

// MARK: - Add output

struct AddOutputMenu: View {
    /// Passed in, not read from the environment: this appears in the toolbar, whose
    /// hosting view does not reliably inherit it.
    let model: AppModel

    /// Captions made with a model that writes English letters only (Apex) have no
    /// native-script transcript to add: offering it added nothing and said nothing.
    private var writesLettersOnly: Bool { model.project.spine?.isRomanizedSource == true }

    private var missing: [OutputKind] {
        guard let cap = model.currentCapability else { return [] }
        let present = Set(model.project.tracks.filter { !$0.isReference }.map(\.kind))
        return OutputKind.allCases.filter {
            cap.supports($0) && !present.contains($0) && !($0 == .original && writesLettersOnly)
        }
    }

    /// Outputs this Mac cannot produce right now, with the reason.
    private var blocked: [(kind: OutputKind, reason: String)] {
        let present = Set(model.project.tracks.filter { !$0.isReference }.map(\.kind))
        return OutputKind.allCases.compactMap { kind in
            guard !present.contains(kind) else { return nil }
            guard let reason = model.unavailableReason(kind, cap: model.currentCapability)
            else { return nil }
            return (kind, reason)
        }
    }

    /// Unavailable outputs are listed and explained rather than silently dropped.
    ///
    /// They used to just vanish, and the menu said "All available outputs are already
    /// here" — which reads as "there is nothing else to get". On a Hindi clip left on
    /// English by mistake, Hinglish is unsupported (English is already Latin script),
    /// so the one thing the user wanted was invisible and the menu implied it did not
    /// exist. Now it says what to change.
    var body: some View {
        Menu {
            ForEach(missing, id: \.self) { kind in
                Button {
                    model.addOutput(kind)
                } label: {
                    Label(label(kind), systemImage: icon(kind))
                }
            }
            if writesLettersOnly, let cap = model.currentCapability,
               !model.project.tracks.contains(where: { $0.kind == .original && !$0.isReference }) {
                if !missing.isEmpty { Divider() }
                Text("\(cap.displayName) script: these captions were made with a model that writes English letters only. Choose Apple (built in) under Speech and model, then Listen Again.")
            }
            let blocked = blocked
            if !blocked.isEmpty {
                if !missing.isEmpty { Divider() }
                Section("Needs a different spoken language") {
                    ForEach(blocked, id: \.kind) { item in
                        // Offer the fix, not just the diagnosis. A blocked output used
                        // to be a disabled row with the reason in a tooltip, which told
                        // the user what was wrong but left them to work out the four
                        // steps that put it right.
                        ForEach(fixes(for: item.kind)) { fix in
                            Button {
                                model.switchLanguage(to: fix.languageTag, wanting: item.kind)
                            } label: {
                                Label(fix.title, systemImage: icon(item.kind))
                            }
                            .help(item.reason)
                        }
                    }
                }
            }
            if missing.isEmpty && blocked.isEmpty {
                Text("All available outputs are already here")
            }
        } label: {
            Label("Add Captions", systemImage: "text.badge.plus")
        }
        .disabled(model.generation.isRunning)
        .help("Add captions in another form or language, without listening again")
    }

    /// Languages that would unlock `kind`, offered as a single action each.
    ///
    /// Only languages already installed, so the fix is one click and not a download,
    /// and capped so this stays a fix rather than becoming a second language picker.
    private func fixes(for kind: OutputKind) -> [EngineFix] {
        // Ready means Apple's files are here or a downloaded model serves it: Hindi with
        // Apex installed was left out, and the fix offered for Hinglish was Chinese.
        let candidates = model.capabilities.filter { cap in
            cap.supports(kind) && (cap.assetState == .installed
                || model.extendedPacks.contains { model.installedPackIDs.contains($0.id) && $0.serves(cap.languageCode) && !$0.isGeneral })
        }
        // A specialised model's own languages first — those are the ones someone asking
        // for Hinglish actually means.
        let specialised = Set(ExtendedEngineManager.allPacks
            .filter { $0.id != ExtendedEngineManager.generalPack.id }
            .flatMap(\.languages))
        let ordered = candidates.sorted { a, b in
            let sa = specialised.contains(a.languageCode), sb = specialised.contains(b.languageCode)
            if sa != sb { return sa }
            return a.displayName < b.displayName
        }
        return ordered.prefix(4).map { cap in
            let what = OutputLabels.title(kind, languageCode: cap.languageCode,
                                          target: model.project.translationTarget)
            return EngineFix(id: cap.languageTag,
                             title: "\(what) — switch to \(cap.displayName) and redo",
                             languageTag: cap.languageTag)
        }
    }

    private func label(_ kind: OutputKind) -> String {
        guard let cap = model.currentCapability else { return kind.shortLabel }
        return OutputLabels.title(kind, languageCode: cap.languageCode, target: model.project.translationTarget)
    }
    private func icon(_ kind: OutputKind) -> String {
        switch kind {
        case .translation: return "character.book.closed"
        case .romanized:   return "textformat.abc"
        case .original:    return "text.quote"
        }
    }
}

/// One offered remedy for an output the current spoken language cannot produce.
struct EngineFix: Identifiable {
    let id: String
    let title: String
    let languageTag: String
}

/// An inspector section you can fold away by clicking its heading, remembered between
/// launches. The inspector shows everything at once otherwise, and most people use two
/// or three of its sections.
struct FoldingSection<Content: View, Footer: View>: View {
    let title: String
    @AppStorage private var expanded: Bool
    let content: Content
    let footer: Footer

    init(_ title: String, key: String, expandedByDefault: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self._expanded = AppStorage(wrappedValue: expandedByDefault, "inspector.section.\(key)")
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        Section {
            if expanded { content }
        } header: {
            Button {
                withAnimation(Motion.standard) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    // Leading disclosure triangle, as in Finder and DisclosureGroup; a
                    // trailing ">" read as System Settings navigation.
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    // Styled explicitly: after a collapsed (empty) section, the grouped
                    // form otherwise renders the next heading as small grey footer text.
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                }
                .padding(.top, expanded ? 0 : 4)
                .padding(.bottom, expanded ? 0 : 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides this section")
            .accessibilityAddTraits(.isHeader)
        } footer: {
            if expanded { footer }
        }
    }
}

extension FoldingSection where Footer == EmptyView {
    init(_ title: String, key: String, expandedByDefault: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title, key: key, expandedByDefault: expandedByDefault,
                  content: content, footer: { EmptyView() })
    }
}

/// A label style chosen at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
