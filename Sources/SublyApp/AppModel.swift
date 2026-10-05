import SwiftUI
import Observation
import AVFoundation
import UniformTypeIdentifiers
import SublyCaptions
import SublyEngine
import SublyTranslate

// MARK: - Project

@Observable
final class Project: Identifiable {
    /// Restored when a saved project is opened. It was a fresh UUID every time, so
    /// each editing session saved a new copy beside the old one; the sidebar hid the
    /// duplicates but they piled up on disk.
    var id = UUID()
    var name: String
    var mediaURL: URL?
    /// The video's saved location and fingerprint, kept even while the file is missing
    /// so captions edited in the meantime can still be saved. With the video moved,
    /// every save used to be skipped and those edits were lost.
    var storedMediaPath: String?
    var storedFingerprint: String?
    var mediaInfo: MediaService.MediaInfo?
    var sourceLanguage: String = "en-US"
    var selectedOutputs: Set<OutputKind> = [.original]
    var translationTarget: String = "en"
    var rules: CaptionRules = .shortForm
    var presetName: String = "Short-form"
    var useRefinement = true

    var spine: TimingSpine?
    var slots: [CueSlot] = []
    var tracks: [SubtitleTrack] = []
    var waveform: [Float] = []
    var audioURL: URL?
    var generationFailures: [(kind: OutputKind, message: String)] = []

    /// Per-track overlay visibility. Every generated track is visible by default —
    /// simultaneous display is the point. PRD MULTI-03.
    var visibleTrackIDs: Set<UUID> = []
    /// Edited since the captions were last generated or re-cut; re-cutting would lose it.
    var captionsEdited = false
    var captionStyle: CaptionStyle = .default
    /// Names and brand words said in the video ("Fitbit Air, Whoop"), passed to the
    /// recogniser. Without them Apex wrote "Amaz Fit Terex" and "chess trap".
    var vocabulary: [String] = []
    var createdAt = Date()
    var lastExportPaths: [String] = []

    init(name: String = "Untitled") { self.name = name }

    var hasResults: Bool { !tracks.isEmpty }
    /// Captions this app made, not counting a subtitle file found beside the video.
    var hasGeneratedCaptions: Bool { tracks.contains { !$0.isReference } }
    var exportableTracks: [SubtitleTrack] { tracks.filter { !$0.isReference } }

    func trackIndex(_ id: UUID) -> Int { tracks.firstIndex { $0.id == id } ?? 0 }

    /// Stable per-track colour.
    ///
    /// Keyed to what the track IS, not where it sits in the array. Using the array
    /// position meant deleting one track silently recoloured the others.
    func colorSlot(for id: UUID) -> Int {
        guard let track = tracks.first(where: { $0.id == id }) else { return 0 }
        return TrackPalette.slot(kind: track.kind, languageTag: track.languageTag,
                                 isReference: track.isReference)
    }

    func color(for id: UUID) -> Color { TrackPalette.color(colorSlot(for: id)) }
    func videoColor(for id: UUID) -> Color { TrackPalette.onVideo(colorSlot(for: id)) }
}

// MARK: - Playback clock

/// Playback position lives in its own observable so that a 30 Hz tick invalidates
/// only the views that actually show time — the playhead, the transport and the
/// caption overlay. When this was a property on `AppModel`, the timeline's body read
/// it for the playhead offset, which rebuilt every track's canvas 30 times a second.
@Observable
@MainActor
final class PlaybackClock {
    var currentTime: Double = 0
    var isPlaying = false
}

// MARK: - Undo

/// Everything an edit can change, so undo puts all of it back. It held only tracks and
/// slots: undoing a re-cut restored the corrected captions but left the new word rules
/// and an "unedited" flag, so the next re-cut wiped the corrections without warning;
/// undoing a track deletion brought the track back hidden.
struct EditSnapshot {
    let projectID: UUID
    let tracks: [SubtitleTrack]
    /// Snapshotted alongside tracks: `updateCueTiming` mutates both, so restoring
    /// only tracks would leave the slot grid disagreeing with the cues.
    let slots: [CueSlot]
    let rules: CaptionRules
    let captionsEdited: Bool
    let visibleTrackIDs: Set<UUID>
    let selectedOutputs: Set<OutputKind>
    let translationTarget: String
    let captionStyle: CaptionStyle
    /// The transcript and its language, so Listen Again can be undone: the old
    /// captions only fit the transcript they were cut from.
    let spine: TimingSpine?
    let sourceLanguage: String
    let label: String

    @MainActor init(_ project: Project, label: String) {
        projectID = project.id
        spine = project.spine; sourceLanguage = project.sourceLanguage
        tracks = project.tracks; slots = project.slots; rules = project.rules
        captionsEdited = project.captionsEdited; visibleTrackIDs = project.visibleTrackIDs
        selectedOutputs = project.selectedOutputs; translationTarget = project.translationTarget
        captionStyle = project.captionStyle
        self.label = label
    }

    @MainActor func restore(into project: Project) {
        project.spine = spine; project.sourceLanguage = sourceLanguage
        project.tracks = tracks; project.slots = slots; project.rules = rules
        project.captionsEdited = captionsEdited; project.visibleTrackIDs = visibleTrackIDs
        project.selectedOutputs = selectedOutputs; project.translationTarget = translationTarget
        project.captionStyle = captionStyle
    }
}

// MARK: - App model

@Observable
@MainActor
final class AppModel {

    // Navigation
    /// The three steps of the window: add a video, choose what to make, then edit and
    /// share. Speech models open as a sheet over whichever step you are on.
    enum Route: Hashable { case home, newProject, editor }
    var route: Route = .home {
        // The projects step has no playback controls, so sound playing on from the
        // editor could only be stopped with a key nobody would guess.
        didSet { if route == .home, isPlaying { togglePlayback() } }
    }
    var showModels = false
    /// Which tab of the editor's side panel is showing.
    enum PanelTab: String, CaseIterable, Identifiable {
        case captions, look, share
        var id: String { rawValue }
        var title: String {
            switch self {
            case .captions: return "Captions"
            case .look:     return "Look"
            case .share:    return "Share"
            }
        }
    }
    var panelTab: PanelTab = .captions
    var project = Project()
    var recentProjects: [Project] = []

    // Capability
    var capabilities: [CapabilityRegistry.LanguageCapability] = []
    var groupedCapabilities: [(CapabilityRegistry.Region, [CapabilityRegistry.LanguageCapability])] = []
    var systemState: CapabilityRegistry.SystemState?
    var isLoadingCapabilities = true

    // Generation
    enum GenerationState: Equatable {
        case idle
        case running(stage: String, fraction: Double)
        case done
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
    }
    var generation: GenerationState = .idle
    var generationTask: Task<Void, Never>?

    // Asset install
    var assetInstallLanguage: String?
    var assetInstallProgress: Double = 0

    // Extended engine packs
    var installedPackIDs: Set<String> = []
    var packDownloadProgress: [String: Double] = [:]
    @ObservationIgnored private var packTasks: [String: Task<Void, Never>] = [:]
    var extendedPacks: [ExtendedEngineManager.ModelPack] { ExtendedEngineManager.allPacks }

    /// Observable mirror of the per-language engine choice.
    ///
    /// The picker used to read `TranscriptionService.engineChoice` straight from
    /// `UserDefaults` inside its `Binding`. Writing the new value persisted it, but
    /// nothing observable changed, so SwiftUI never re-rendered — the menu snapped back
    /// to the old engine and it looked as though the app refused the selection.
    /// `UserDefaults` stays the source of truth; this exists so the view updates.
    private(set) var engineChoiceRevision = 0

    func engineChoice(for language: String) -> TranscriptionService.EngineChoice {
        _ = engineChoiceRevision      // establishes the observation dependency
        return TranscriptionService.engineChoice(for: language)
    }

    func setEngineChoice(_ choice: TranscriptionService.EngineChoice, for language: String) {
        TranscriptionService.setEngineChoice(choice, for: language)
        engineChoiceRevision += 1
        // A model like Apex writes in English letters only: what it makes is the
        // Hinglish track, so ask for that rather than a transcript it cannot produce.
        // Only for the open project's own language: a download finishing for another
        // language used to change this project's outputs.
        let code = { (t: String) in t.split(separator: "-").first.map(String.init)?.lowercased() ?? t }
        if case .pack(let id) = choice, code(language) == code(project.sourceLanguage),
           extendedPacks.first(where: { $0.id == id })?.emitsRomanized == true,
           project.selectedOutputs.remove(.original) != nil {
            project.selectedOutputs.insert(.romanized)
        }
    }

    /// What Generate will actually make. With a model that writes English letters only,
    /// a ticked transcript becomes the Hinglish track — so show it that way.
    var effectiveOutputs: Set<OutputKind> {
        var outputs = project.selectedOutputs
        if chosenModelWritesEnglishLettersOnly, outputs.remove(.original) != nil {
            outputs.insert(.romanized)
        }
        return outputs
    }

    /// True when the chosen model cannot write the language in its own script.
    var chosenModelWritesEnglishLettersOnly: Bool {
        guard let cap = currentCapability,
              case .pack(let id) = engineChoice(for: cap.languageTag) else { return false }
        return extendedPacks.first { $0.id == id }?.emitsRomanized == true
    }

    func refreshPacks() {
        installedPackIDs = Set(ExtendedEngineManager.shared.installedPacks.map(\.id))
    }

    func installPack(_ pack: ExtendedEngineManager.ModelPack) {
        guard packTasks[pack.id] == nil else { return }
        // The language it was downloaded for. Using whichever project was open when it
        // finished changed another language's engine.
        let languageAtStart = project.sourceLanguage
        packDownloadProgress[pack.id] = 0
        packTasks[pack.id] = Task {
            do {
                try await ExtendedEngineManager.shared.install(pack) { f in
                    Task { @MainActor in self.packDownloadProgress[pack.id] = f }
                }
                await MainActor.run {
                    self.packDownloadProgress.removeValue(forKey: pack.id)
                    self.packTasks.removeValue(forKey: pack.id)
                    self.refreshPacks()
                    // Downloading a model for this language means wanting to use it.
                    // It used to sit unused until the user found the picker again, and
                    // "Automatic" kept choosing Apple's engine.
                    let language = languageAtStart
                    let code = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language
                    // A model made for this language, or one downloaded to caption it now.
                    // Any general Whisper "serves" every language, and downloading one
                    // switched English away from Apple's engine without asking.
                    if pack.serves(code), !pack.isGeneral || self.generateAfterDownload == pack.id
                        || self.engineChoice(for: language) == .pack(pack.id) {
                        self.setEngineChoice(.pack(pack.id), for: language)
                    }
                    if self.generateAfterDownload == pack.id {
                        self.generateAfterDownload = nil
                        if self.generateAfterDownloadProject == self.project.id { self.generate() }
                    } else {
                        self.infoMessage = "\(pack.displayName) is downloaded and selected."
                    }
                }
                await registry.invalidate()
                await loadCapabilities()
            } catch is CancellationError {
                await MainActor.run {
                    self.packDownloadProgress.removeValue(forKey: pack.id)
                    self.packTasks.removeValue(forKey: pack.id)
                    if self.generateAfterDownload == pack.id { self.generateAfterDownload = nil }
                }
            } catch {
                await MainActor.run {
                    self.packDownloadProgress.removeValue(forKey: pack.id)
                    self.packTasks.removeValue(forKey: pack.id)
                    if self.generateAfterDownload == pack.id { self.generateAfterDownload = nil }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelPackDownload(_ pack: ExtendedEngineManager.ModelPack) {
        packTasks[pack.id]?.cancel()
        // The task entry stays until the cancelled download has actually stopped (its
        // own cleanup removes it). Removing it here let Download start a second copy
        // writing the same partial file while the first was still running.
        packDownloadProgress.removeValue(forKey: pack.id)
        if generateAfterDownload == pack.id { generateAfterDownload = nil }
    }

    /// The model Generate would need but is not on this Mac, if any.
    ///
    /// Choosing a model that was not downloaded used to make Generate quietly run
    /// Apple's engine instead — a Hindi speaker who picked Apex got Devanagari spelled
    /// out ("kreejee" for "crease"), the very result Apex exists to avoid.
    var missingModel: ExtendedEngineManager.ModelPack? {
        guard let cap = currentCapability else { return nil }
        switch engineChoice(for: cap.languageTag) {
        case .pack(let id):
            guard let pack = extendedPacks.first(where: { $0.id == id }),
                  !installedPackIDs.contains(id) else { return nil }
            return pack
        case .automatic where cap.engine.requiresDownload:
            let usable = extendedPacks.contains { installedPackIDs.contains($0.id) && $0.serves(cap.languageCode) }
            return usable ? nil : ExtendedEngineManager.recommended(for: cap.languageCode).pack
        default:
            return nil
        }
    }

    /// Set while a model downloads on the way to generating, so Generate continues by
    /// itself once the download finishes.
    var generateAfterDownload: String?
    /// The project that download was for. Finishing the download used to regenerate
    /// whichever project happened to be open by then, replacing its captions.
    @ObservationIgnored var generateAfterDownloadProject: UUID?
    @ObservationIgnored var generationToken = UUID()

    /// What the Generate and Redo buttons do: download the chosen model first if it is
    /// missing, then transcribe.
    func generateOrDownload() {
        if let pack = missingModel {
            generateAfterDownload = pack.id
            generateAfterDownloadProject = project.id
            installPack(pack)
        } else {
            generate()
        }
    }

    func deletePack(_ pack: ExtendedEngineManager.ModelPack) {
        do {
            try ExtendedEngineManager.shared.delete(pack)
            refreshPacks()
        } catch { errorMessage = error.localizedDescription }
    }

    // Playback
    var player: AVPlayer?
    let clock = PlaybackClock()
    /// Forwarded for call sites that do not care about the isolation.
    var currentTime: Double {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }
    var isPlaying: Bool {
        get { clock.isPlaying }
        set { clock.isPlaying = newValue }
    }
    var playbackRate: Float = 1.0 {
        didSet { if isPlaying { player?.rate = playbackRate } }
    }
    var showFrameTimecode = false

    // MARK: Layout the user can rearrange, remembered between launches.
    //
    // Stored here rather than as view state so the View menu, the toolbar and the
    // editor all read and change the same value. The inspector's visibility used to be
    // view state, so it reopened every time and no menu command could reach it.

    var showInspector: Bool = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    var showCaptionList: Bool = UserDefaults.standard.bool(forKey: "showCueGrid") {
        didSet { UserDefaults.standard.set(showCaptionList, forKey: "showCueGrid") }
    }
    /// Bumped by Captions › Find…; the caption list focuses its search field.
    var findRequest = 0
    @ObservationIgnored var findPending = false
    /// Progress of a burned-in video export, 0…1, while one runs.
    var videoExportProgress: Double?
    @ObservationIgnored var videoExportTask: Task<Void, Never>?
    @ObservationIgnored var videoExportToken = UUID()
    /// Shows the "Export Video with Captions" options.
    var showVideoExport = false

    /// Precomputed lookups (cue-by-slot, binary-searchable times, cached diagnostics,
    /// lowercased search text). Rebuilt when tracks change — NOT on every redraw.
    /// Before this, validating every track cost 8.7 ms per body evaluation and a
    /// search keystroke cost 74 ms on a 57-minute project.
    private(set) var index = ProjectIndex()

    private func formatter(for track: SubtitleTrack) -> CaptionFormatter {
        let language = track.kind == .original ? project.sourceLanguage : track.languageTag
        let profile = ScriptProfile.forLanguage(language)
        return CaptionFormatter(rules: project.rules.adjusted(for: profile), profile: profile)
    }

    /// Reindex a single track. A caption edit touches one track, so rebuilding all of
    /// them was mostly wasted work.
    func rebuildIndex(trackID: UUID) {
        guard let track = project.tracks.first(where: { $0.id == trackID }) else {
            rebuildIndex(); return
        }
        index = index.replacing(track: track, formatter: formatter(for: track),
                                allTracks: project.tracks)
    }

    func rebuildIndex() {
        let sourceLanguage = project.sourceLanguage
        let rules = project.rules
        index = ProjectIndex(tracks: project.tracks) { track in
            let language = track.kind == .original ? sourceLanguage : track.languageTag
            let profile = ScriptProfile.forLanguage(language)
            return CaptionFormatter(rules: rules.adjusted(for: profile), profile: profile)
        }
    }

    // Editing
    var selectedCueSlot: Int?
    var focusedTrackID: UUID?
    var undoStack: [EditSnapshot] = []
    var redoStack: [EditSnapshot] = []

    // Sheets
    var showExport = false
    var showLanguagePicker = false
    var errorMessage: String?
    var infoMessage: String?

    // Settings (persisted)
    @ObservationIgnored @AppStorage("defaultPreset") var defaultPreset = "Short-form"
    @ObservationIgnored @AppStorage("defaultOutputs") var defaultOutputsRaw = "original"
    @ObservationIgnored @AppStorage("protectedTerms") var protectedTermsRaw = "iPhone, Android, display, camera, battery, brightness"
    @ObservationIgnored @AppStorage("useRefinement") var useRefinementDefault = true

    var protectedTerms: [String] {
        protectedTermsRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Owns the SwiftUI-attached translation session. See TranslationBridge.
    let translationBridge = TranslationBridge()

    private var store: ProjectStore { ProjectStore(directory: projectsDirectory) }
    private let registry = CapabilityRegistry()
    private let pipeline = GenerationPipeline()
    private let mediaService = MediaService()
    private let transcription = TranscriptionService()

    init() {}

    // MARK: - Capability loading

    func loadCapabilities() async {
        // Recents come from a small JSON file on disk. They used to load *after* the
        // capability probe below, which asks Speech and Translation about 68 locales
        // and takes seconds — so a returning user stared at an empty window the whole
        // time. Read them first; nothing here depends on the probe.
        loadRecentProjects()
        isLoadingCapabilities = true
        let caps = await registry.capabilities()
        let grouped = await registry.grouped()
        let state = await registry.systemState()
        capabilities = caps
        groupedCapabilities = grouped
        systemState = state
        refreshPacks()
        isLoadingCapabilities = false

        // Defaults are for a blank project only. This runs seconds after launch and
        // again after every speech-model download, and it used to reset whatever was
        // open: a Hindi project flipped back to English (so Apex disappeared from the
        // engine menu) and its caption settings reverted to the defaults.
        guard project.mediaURL == nil, project.spine == nil else { return }
        // Default to a flagship language that is already installed where possible.
        if let installed = caps.first(where: { $0.assetState == .installed && $0.transcriptionTier == .flagship }) {
            project.sourceLanguage = installed.languageTag
        }
        applyDefaults()
    }

    func applyDefaults() {
        if let preset = CaptionRules.presets.first(where: { $0.name == defaultPreset }) {
            project.rules = preset.rules
            project.presetName = preset.name
        }
        // Start from what was used last time: a Hindi creator re-chose Hindi and
        // Hinglish for every single video.
        // Only while "Remember these choices" is on: unticking it used to stop saving
        // but kept starting new videos with the old remembered choices.
        let remembered = rememberChoices
        if remembered, let last = UserDefaults.standard.string(forKey: "lastSourceLanguage"),
           capabilities.contains(where: { $0.languageTag == last }) {
            project.sourceLanguage = last
        }
        let raw = (remembered ? UserDefaults.standard.string(forKey: "lastOutputs") : nil) ?? defaultOutputsRaw
        let kinds = raw.split(separator: ",").compactMap { OutputKind(rawValue: String($0)) }
        if !kinds.isEmpty { project.selectedOutputs = Set(kinds) }
        if remembered, let target = UserDefaults.standard.string(forKey: "lastTranslationTarget") {
            project.translationTarget = target
        }
        if remembered, let data = UserDefaults.standard.data(forKey: "lastRules"),
           let rules = try? JSONDecoder().decode(CaptionRules.self, from: data) {
            project.rules = rules
            project.presetName = UserDefaults.standard.string(forKey: "lastPreset") ?? project.presetName
        }
        project.useRefinement = useRefinementDefault
        pruneUnavailableOutputs()
        // Never leave nothing ticked (e.g. "Hinglish only" carried to an English video).
        if project.selectedOutputs.isEmpty { project.selectedOutputs = [.original] }
    }

    /// What actually produced the tracks, for the privacy badge and the header.
    /// Falls back to the selected language only when nothing has been generated.
    var activeEngineDescription: String? {
        project.spine?.engineID
    }

    var activeEngineIsApple: Bool? {
        if let id = project.spine?.engineID {
            return id.hasPrefix("Apple")
        }
        // Nothing generated yet — say what WOULD run, or nothing if unknown.
        guard let cap = currentCapability else { return nil }
        return cap.engine.isApple
    }

    var currentCapability: CapabilityRegistry.LanguageCapability? {
        let code = project.sourceLanguage.split(separator: "-").first.map(String.init)?.lowercased()
            ?? project.sourceLanguage
        return capabilities.first { $0.languageCode == code }
    }

    /// Never leave an impossible output ticked. The UI disables it with a reason, and
    /// this keeps state honest if the language changes underneath. PRD MULTI-01.
    func pruneUnavailableOutputs() {
        guard let cap = currentCapability else { return }
        let translationPointedAtSource = project.translationTarget.split(separator: "-").first.map(String.init)?.lowercased()
            == cap.languageCode.lowercased()
        // Keep the translation target valid for the chosen source, so we never offer
        // English → English.
        if !cap.translationTargets.isEmpty,
           !cap.canTranslate(to: project.translationTarget) {
            project.translationTarget = cap.translationTargets.first { $0 != cap.languageCode }
                ?? cap.translationTargets[0]
        }
        var outputs = project.selectedOutputs
        // "In English letters" for a language already written in them is just its
        // transcript: a Hindi creator's remembered Hinglish became, on an English video,
        // nothing at all but a translation.
        if outputs.contains(.romanized), !cap.supports(.romanized),
           !ScriptProfile.forLanguage(cap.languageCode).romanizable, cap.supports(.original) {
            outputs.remove(.romanized)
            outputs.insert(.original)
        }
        // A translation into the language being spoken is dropped, not quietly sent to
        // whichever language sorts first (an English video got only a Spanish track).
        if translationPointedAtSource { outputs.remove(.translation) }
        project.selectedOutputs = outputs.filter {
            $0 == .translation ? cap.canTranslate(to: project.translationTarget) : cap.supports($0)
        }
        if project.selectedOutputs.isEmpty {
            if cap.supports(.original) { project.selectedOutputs = [.original] }
            else if let first = OutputKind.allCases.first(where: { cap.supports($0) }) {
                project.selectedOutputs = [first]
            }
        }
    }

    func availableOutputs(for cap: CapabilityRegistry.LanguageCapability?) -> [OutputKind] {
        guard let cap else { return [.original] }
        return OutputKind.allCases.filter { cap.supports($0) }
    }

    /// Plain-language reason an output is unavailable, shown inline before Generate.
    func unavailableReason(_ kind: OutputKind, cap: CapabilityRegistry.LanguageCapability?) -> String? {
        guard let cap else { return "Choose a source language first." }
        if cap.supports(kind) { return nil }
        let name = cap.displayName
        switch kind {
        case .original:
            return "Subly can't listen to \(name) on this Mac yet."
        case .translation:
            if cap.translationTargets.isEmpty {
                return "Translation from \(name) isn't available on this Mac."
            }
            return "Translating \(name) into \(CapabilityRegistry.displayName(project.translationTarget)) isn't available on this Mac."
        case .romanized:
            return ScriptProfile.forLanguage(cap.languageCode).romanizable
                ? "Romanization hasn't been enabled for \(name) yet."
                : "\(name) already uses the Latin alphabet, so there's nothing to romanize."
        }
    }

    // MARK: - Persistence

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastUndoKey: String?
    /// Bumped by every edit, undo and redo — a re-cut applies only if it is unchanged.
    /// (The undo stack's size can't serve: it stops growing at its 80-step cap.)
    @ObservationIgnored private(set) var editRevision = 0
    @ObservationIgnored private var lastUndoTime = Date.distantPast

    /// Debounced autosave. PRD PROJ-01.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.autosaveTask = nil
                self?.saveProject()
            }
        }
    }

    /// Called on quit. Autosave waits 1.5 s after the last change, so an edit made just
    /// before quitting used to be lost. Save it now and wait for the write. Returns the
    /// error if the latest save failed (a full disk), so quitting can stop.
    @discardableResult
    func flushPendingSave() -> String? {
        if autosaveTask != nil {
            autosaveTask?.cancel()
            autosaveTask = nil
            saveProject()
        }
        return Self.saveQueue.sync { Self.saveStatus.failure }
    }

    func saveProject() {
        let media = project.mediaURL
        guard let path = media?.path(percentEncoded: false) ?? project.storedMediaPath else { return }
        let bookmark = try? media?.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
        var document = ProjectDocument(
            id: project.id, name: project.name,
            createdAt: project.createdAt, modifiedAt: Date(),
            mediaPath: path,
            mediaFingerprint: media != nil ? ProjectStore.fingerprint(path: path)
                                           : (project.storedFingerprint ?? ""),
            mediaBookmark: bookmark,
            sourceLanguage: project.sourceLanguage,
            translationTarget: project.translationTarget,
            selectedOutputs: project.selectedOutputs.map(\.rawValue),
            rules: project.rules, presetName: project.presetName,
            useRefinement: project.useRefinement,
            spine: project.spine, slots: project.slots, tracks: project.tracks,
            visibleTrackIDs: Array(project.visibleTrackIDs),
            lastExportPaths: project.lastExportPaths)
        document.captionsEdited = project.captionsEdited
        document.waveform = project.waveform.isEmpty ? nil : project.waveform
        document.captionStyle = project.captionStyle
        document.vocabulary = project.vocabulary.isEmpty ? nil : project.vocabulary
        lastProjectID = document.id.uuidString
        // Encode and write off the main thread: on a long project that is ~10 ms,
        // which landed as a hitch while typing every time autosave fired. Writes go
        // through one serial queue so an older save can never land after a newer one.
        let store = self.store
        let snapshot = document
        Self.saveQueue.async {
            do {
                try store.save(snapshot)
                Self.saveStatus.failure = nil
            } catch {
                let message = error.localizedDescription
                Self.saveStatus.failure = message
                Task { @MainActor in self.errorMessage = message }
            }
        }
    }
    private static let saveQueue = DispatchQueue(label: "Subly.save", qos: .utility)
    /// Whether the newest save failed. Read and written only on `saveQueue`.
    private final class SaveStatus: @unchecked Sendable { var failure: String? }
    private static let saveStatus = SaveStatus()

    func loadRecentProjects() {
        // Let any save still being written finish first, so a project saved a moment
        // ago is in the list. Saves are a few milliseconds; this is rare.
        Self.saveQueue.sync {}
        savedProjects = store.loadAll()
        refreshMissingMedia()
    }

    /// Recent projects whose video can't be found, for the sidebar's icon.
    ///
    /// Worked out in the background. The sidebar used to check each video's file while
    /// drawing, on the main thread, so a slow disk, an iCloud file still downloading
    /// or a pending macOS permission prompt for Downloads froze the whole app — it
    /// stopped responding even to Quit.
    var missingMediaProjects: Set<UUID> = []

    private func refreshMissingMedia() {
        let docs = savedProjects.map { (id: $0.id, path: $0.mediaPath, fingerprint: $0.mediaFingerprint) }
        Task.detached(priority: .utility) {
            let missing = Set(docs.filter {
                ProjectStore.mediaState(path: $0.path, expecting: $0.fingerprint) == .missing
            }.map(\.id))
            await MainActor.run { self.missingMediaProjects = missing }
        }
    }

    var savedProjects: [ProjectDocument] = []

    /// Newest project per source file. Repeated runs on the same clip used to fill
    /// the sidebar with identical rows.
    var distinctRecentProjects: [ProjectDocument] {
        var seen = Set<String>()
        return savedProjects.filter { seen.insert($0.mediaPath).inserted }
    }

    func openProject(_ listed: ProjectDocument) {
        // A video still being read for an import must not replace this project.
        importToken = UUID()
        // Same rule as opening a video: switching would stop the captions being made.
        if generation.isRunning || generateAfterDownload != nil {
            infoMessage = "Captions are still being made for “\(project.name)”. Wait for them to finish, or press Cancel, then open the other project."
            return
        }
        // Save the project being left first: an edit made in the last 1.5 s used to be
        // dropped, because autosave then saved whichever project was open by then.
        flushPendingSave()
        cancelGeneration()
        resetEditingState()
        // Read it fresh from disk. The sidebar's copy can be older than what was saved
        // since, and reopening from it threw away saved edits.
        let document = (try? store.load(id: listed.id)) ?? listed
        mediaMissingPath = nil
        // A failure message belongs to the project it happened in.
        if case .failed = generation { generation = .idle }
        let state = ProjectStore.mediaState(path: document.mediaPath,
                                             expecting: document.mediaFingerprint)
        let p = Project(name: document.name)
        p.sourceLanguage = document.sourceLanguage
        p.translationTarget = document.translationTarget
        p.selectedOutputs = Set(document.selectedOutputs.compactMap { OutputKind(rawValue: $0) })
        p.rules = document.rules
        p.presetName = document.presetName
        p.useRefinement = document.useRefinement
        p.spine = document.spine
        p.slots = document.slots
        p.tracks = document.tracks
        p.visibleTrackIDs = Set(document.visibleTrackIDs)
        p.captionsEdited = document.captionsEdited ?? false
        p.waveform = document.waveform ?? []
        p.captionStyle = document.captionStyle ?? .default
        p.vocabulary = document.vocabulary ?? []
        p.lastExportPaths = document.lastExportPaths
        p.id = document.id
        p.storedMediaPath = document.mediaPath
        p.storedFingerprint = document.mediaFingerprint
        lastProjectID = document.id.uuidString
        p.createdAt = document.createdAt

        switch state {
        case .present, .changed:
            let url = URL(fileURLWithPath: document.mediaPath)
            p.mediaURL = url
            project = p
            preparePlayer(url)
            if state == .changed {
                infoMessage = "This video file has changed since the project was saved, so captions may be out of sync. Play it through to check, or use Listen Again to make them again."
            }
            // Only into the project it was read for: opening another one meanwhile
            // used to give that one this video's size and length.
            let opened = p
            Task {
                if let info = try? await MediaService().probe(url) {
                    await MainActor.run { if self.project === opened { opened.mediaInfo = info } }
                }
            }
        case .missing:
            // Stop the previous video: its sound and clock kept running under these
            // captions when the new project had no video to replace it.
            player?.pause()
            isPlaying = false
            detachTimeObserver()
            player = nil
            clock.currentTime = 0
            project = p
            mediaMissingPath = document.mediaPath
            infoMessage = "“\((document.mediaPath as NSString).lastPathComponent)” has moved or been deleted. Your captions are intact — relink the file to play it again."
        }
        rebuildIndex()
        route = project.hasResults ? .editor : .newProject
        if mediaMissingPath == nil, project.hasResults, let media = project.mediaURL {
            ProjectThumbnail.makeIfMissing(media: media, id: project.id, directory: projectsDirectory,
                                           duration: project.spine?.duration ?? project.mediaInfo?.duration ?? 0)
        }
        if project.waveform.isEmpty, project.hasResults, let media = project.mediaURL {
            rebuildWaveform(from: media, projectID: project.id)
        }
    }

    /// For projects saved before the waveform was kept: extract the audio again in the
    /// background and draw it, then save so it is there next time.
    private func rebuildWaveform(from media: URL, projectID: UUID) {
        Task.detached(priority: .utility) {
            // Its own file: sharing generation's audio.caf let the two write the same
            // file at once if Listen Again started while this ran.
            let audio = FileManager.default.temporaryDirectory
                .appendingPathComponent("subly-waveform-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: audio) }
            let service = MediaService()
            guard (try? await service.extractAudio(from: media, to: audio)) != nil else { return }
            let duration = (try? await service.probe(media))?.duration ?? 0
            guard let peaks = try? await service.waveform(for: audio,
                                                          buckets: MediaService.waveformBuckets(for: duration)),
                  !peaks.isEmpty else { return }
            await MainActor.run {
                guard self.project.id == projectID, self.project.waveform.isEmpty else { return }
                self.project.waveform = peaks
                self.saveProject()
            }
        }
    }

    /// Set when a reopened project's media is gone, so the UI can offer a relink.
    var mediaMissingPath: String?

    func relinkMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Choose the file this project was made from."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.mediaURL = url
        mediaMissingPath = nil
        preparePlayer(url)
        let relinked = project
        Task {
            if let info = try? await MediaService().probe(url) {
                await MainActor.run {
                    guard self.project === relinked else { return }
                    relinked.mediaInfo = info
                    self.saveProject()
                }
            }
        }
    }

    /// Deletes every saved copy for the same video. The sidebar shows one row per
    /// video, so deleting that row has to remove what it stands for; otherwise an
    /// older copy took its place and "Delete" looked as if it did nothing.
    func deleteProject(_ document: ProjectDocument) { deleteProjects([document]) }

    /// Each listed project goes with every older run on the same video, since the
    /// lists show one row per video. A project without a video path is matched by id
    /// alone: matching on an empty path would have taken every other such project.
    func deleteProjects(_ documents: [ProjectDocument]) {
        let paths = Set(documents.map(\.mediaPath).filter { !$0.isEmpty })
        let deleted = Set(documents.map(\.id))
            .union(savedProjects.filter { paths.contains($0.mediaPath) }.map(\.id))
        // Through the save queue, after any queued save: a save landing after the
        // delete recreated the folder and the project came back.
        // Saved first: if the Trash refuses, the project stays — with its latest edits.
        if deleted.contains(project.id) { flushPendingSave() }
        let store = self.store
        var failed: [UUID] = []
        Self.saveQueue.sync {
            for id in deleted where (try? store.delete(id: id, toTrash: true)) == nil { failed.append(id) }
        }
        if !failed.isEmpty {
            let names = savedProjects.filter { failed.contains($0.id) }.map { "“\($0.name)”" }
            errorMessage = "Couldn't move \(names.isEmpty ? "\(failed.count) project(s)" : names.joined(separator: ", ")) to the Trash, so they were kept. The disk they're on may have no Trash."
        }
        // Deleting the project that is open left it open, and the next edit's autosave
        // wrote it straight back.
        let removed = deleted.subtracting(failed)
        if removed.contains(project.id) {
            cancelGeneration()
            resetEditingState()
            project = Project(name: "")
            index = ProjectIndex()
            selectedCueSlot = nil
            mediaMissingPath = nil
            undoStack.removeAll(); redoStack.removeAll()
            player?.pause(); isPlaying = false
            detachTimeObserver()
            player = nil
            route = .home
            applyDefaults()
        }
        if let last = lastProjectID, removed.contains(where: { $0.uuidString == last }) { lastProjectID = nil }
        loadRecentProjects()
    }

    /// The project to reopen at launch, as Mac apps restore where you left off.
    /// Test and review runs (any SUBLY_ hook) neither read nor change it, so they
    /// cannot alter what the person's own launch reopens.
    var lastProjectID: String? {
        get { UserDefaults.standard.string(forKey: "lastProjectID") }
        set {
            guard !Self.isHookRun else { return }
            UserDefaults.standard.set(newValue, forKey: "lastProjectID")
        }
    }

    static let isHookRun = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("SUBLY_") }

    /// The guide: how to make captions, what each model is for, and where files go.
    static let helpURL = URL(string: "https://github.com/DhananjayBhosale/Subly#readme")!

    /// Reopen the last project, unless something else (a file opened from Finder, a
    /// test hook) already chose what to show.
    func restoreLastProject() {
        guard project.mediaURL == nil, !Self.isHookRun, importsInFlight == 0,
              let id = lastProjectID,
              let doc = savedProjects.first(where: { $0.id.uuidString == id }) else { return }
        openProject(doc)
        if project.hasResults { route = .editor }
    }

    // MARK: - Storage

    var projectsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        // Test hook: a scratch folder, so checks that delete never reach real projects.
        let dir = ProcessInfo.processInfo.environment["SUBLY_PROJECTS_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("Subly/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var workingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Subly", isDirectory: true)
    }

    /// Bytes on disk under `url`, counting what the filesystem actually allocated.
    nonisolated static func bytesOnDisk(at url: URL) -> Int64 {
        let fm = FileManager.default
        // A single file, not a directory: `enumerator(at:)` returns nil for one, which
        // reported every downloaded model as "Zero KB".
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                      .fileAllocatedSizeKey])
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey,
                                                                          .fileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in e {
            let v = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                       .fileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// One formatter everywhere, so the same bytes never appear as two different
    /// numbers. A model reported 574 MB in one place and 549 MB in another purely
    /// because one used decimal units and the other binary.
    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func workingFilesBytes() -> Int64 { Self.bytesOnDisk(at: workingDirectory) }
    func projectsBytes() -> Int64 { Self.bytesOnDisk(at: projectsDirectory) }
    func modelBytes(_ pack: ExtendedEngineManager.ModelPack) -> Int64 {
        installedPackIDs.contains(pack.id)
            ? Self.bytesOnDisk(at: ExtendedEngineManager.shared.modelURL(pack)) : 0
    }

    func workingFilesSize() -> String { Self.formatBytes(workingFilesBytes()) }

    /// Backup copies of the projects folder, if any exist beside it.
    var backupDirectories: [URL] {
        let base = projectsDirectory.deletingLastPathComponent()
        let all = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("Projects-backup") }
    }
    func backupsBytes() -> Int64 {
        backupDirectories.reduce(0) { $0 + Self.bytesOnDisk(at: $1) }
    }
    func deleteBackups() {
        for url in backupDirectories { try? FileManager.default.removeItem(at: url) }
    }

    /// Where Subly's own preferences live. Tiny, but it is one of the places the app
    /// writes, so the accounting should not pretend it does not exist.
    func settingsBytes() -> Int64 {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.subly.local.plist")
        let size = (try? plist.resourceValues(forKeys: [.fileAllocatedSizeKey]))?.fileAllocatedSize
        return Int64(size ?? 0)
    }

    func revealWorkingFiles() {
        try? FileManager.default.createDirectory(at: workingDirectory,
                                                  withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([workingDirectory])
    }

    func clearWorkingFiles() {
        // The audio being transcribed lives here; clearing it mid-run failed the run.
        if let work = workInProgress {
            infoMessage = "Working files are in use while \(work). Clear them when that's done."
            return
        }
        try? FileManager.default.removeItem(at: workingDirectory)
        try? FileManager.default.createDirectory(at: workingDirectory,
                                                  withIntermediateDirectories: true)
    }

    // MARK: - Language detection

    /// ASR-02 auto-detect. Runs the installed locales over a short head of the audio
    /// and keeps whichever returns the most confident text. Honest about its limits:
    /// it only considers languages this Mac can already transcribe without a download.
    var isDetectingLanguage = false
    /// What Detect found, shown under the language for the project and language it
    /// was about. It was an alert to dismiss even when the answer was certain.
    struct DetectionNote: Equatable { var projectID: UUID; var language: String; var text: String; var unsure: Bool }
    var detectionNote: DetectionNote?

    private func noteDetection(_ text: String, unsure: Bool) {
        detectionNote = DetectionNote(projectID: project.id, language: project.sourceLanguage, text: text, unsure: unsure)
    }

    func autoDetectLanguage() async {
        guard let media = project.mediaURL else { return }
        isDetectingLanguage = true
        defer { isDetectingLanguage = false }
        // The answer is about this video. Opening another project, or choosing a
        // language by hand, while it listened used to have the old answer applied there.
        let projectID = project.id, startLanguage = project.sourceLanguage
        func stillWanted() -> Bool {
            project.id == projectID && project.sourceLanguage == startLanguage
                && !generation.isRunning && generateAfterDownload == nil
        }

        // Whisper's detector when a general model is on this Mac: it knows ~99
        // languages, Hindi and Marathi included, and needs one pass instead of one
        // transcription per installed language.
        if let detected = await detectWithWhisper(media) {
            guard stillWanted() else { return }
            let matches = capabilities.filter { $0.languageCode == detected.code }
            // Keep the regional variant already chosen, else one that's ready, else the
            // one for this Mac's region — not whichever sorts first (English came back
            // as English (India)).
            let region = Locale.current.region?.identifier
            if let cap = matches.first(where: { $0.languageTag == project.sourceLanguage })
                ?? matches.first(where: { $0.assetState == .installed })
                ?? matches.first(where: { region != nil && $0.languageTag.hasSuffix("-\(region!)") })
                ?? matches.first {
                project.sourceLanguage = cap.languageTag
                pruneUnavailableOutputs()
                let sure = Int((detected.probability * 100).rounded())
                var message = detected.probability >= 0.5
                    ? "Detected \(cap.displayName) (\(sure)% sure)."
                    : "Probably \(cap.displayName), but only \(sure)% sure. Please check it before making subtitles."
                // Whisper's detector often confuses these two.
                if detected.code == "hi" { message += " If it's Marathi, choose Marathi instead." }
                if detected.code == "mr" { message += " If it's Hindi, choose Hindi instead." }
                noteDetection(message, unsure: detected.probability < 0.5)
            } else {
                noteDetection("This sounds like \(CapabilityRegistry.displayName(detected.code)), which Subly can't caption yet. Please choose a language.", unsure: true)
            }
            return
        }

        let installed = capabilities.filter { $0.assetState == .installed && $0.engine.isApple }
        // Without Whisper, detection can only compare languages already on this Mac,
        // and it used to switch to the only one installed — telling a Hindi speaker
        // their video was English. Leave the choice alone and say how to detect properly.
        let needsWhisper = "To detect any language, including Hindi and Marathi, download Whisper in Speech Models. Or click Change… to choose the language yourself."
        guard installed.count > 1 else {
            noteDetection("Subly can't detect the language yet. " + needsWhisper, unsure: true)
            return
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("subly-detect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let clip = work.appendingPathComponent("head.caf")
            // Only the opening matters here. Detection runs one transcription per
            // installed language, so using the whole file would mean N full passes.
            _ = try await MediaService().extractAudio(from: media, to: clip,
                                                      maxSeconds: 20)

            var scores: [(tag: String, score: Double)] = []
            for cap in installed {
                guard let spine = try? await TranscriptionService()
                    .transcribe(audioURL: clip, language: cap.languageTag) else { continue }
                let confidence = spine.meanConfidence ?? 0
                let words = Double(spine.words.count)
                // Weight confidence by how much it actually recognised.
                scores.append((cap.languageTag, confidence * min(1, words / 8)))
            }
            guard stillWanted() else { return }
            scores.sort { $0.score > $1.score }
            // Only trust a clear winner. A Hinglish clip scored 0.3 as Spanish because
            // Hindi was not among the candidates; a weak, close result means "none of these".
            let margin = scores.count > 1 ? scores[0].score - scores[1].score : 1
            let best = scores.first.flatMap { $0.score >= 0.5 && margin >= 0.15 ? $0 : nil }
            // This can only pick among the languages whose Apple speech files are
            // already downloaded, so say which ones it compared.
            let compared = installed.map { CapabilityRegistry.displayName($0.languageCode) }
                .joined(separator: ", ")
            if let best {
                project.sourceLanguage = best.tag
                pruneUnavailableOutputs()
                noteDetection("Detected \(CapabilityRegistry.displayName(best.tag.split(separator: "-").first.map(String.init) ?? best.tag)), comparing only the languages ready on this Mac (\(compared)). For any language, including Hindi, download Whisper in Speech Models.", unsure: false)
            } else {
                noteDetection("Subly couldn't tell which language this is from the ones ready on this Mac (\(compared)). " + needsWhisper, unsure: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func detectWithWhisper(_ media: URL) async -> (code: String, probability: Double)? {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("subly-detect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let clip = work.appendingPathComponent("head.caf")
            _ = try await MediaService().extractAudio(from: media, to: clip, maxSeconds: 30)
            return try await ExtendedEngineManager.shared.detectLanguage(audioURL: clip)
        } catch {
            return nil
        }
    }

    // MARK: - Import

    static let acceptedTypes: [UTType] = [
        .movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio,
    ]

    /// What would be lost by quitting or switching now, in words, or nil.
    var workInProgress: String? {
        if generation.isRunning { return "captions are being made" }
        if generateAfterDownload != nil || !packDownloadProgress.isEmpty { return "a model is downloading" }
        if videoExportProgress != nil { return "a video is being saved" }
        // Pending rules are cleared on every way a re-cut ends, unlike its task handle.
        if pendingRules != nil { return "captions are being re-cut" }
        return nil
    }

    @ObservationIgnored private var importToken = UUID()
    @ObservationIgnored private var importsInFlight = 0

    func importMedia(_ url: URL) async {
        // Opening another video stops the captions being made for this one, and that
        // project isn't saved until they're done. ⌘O and Finder did it silently.
        if generation.isRunning || generateAfterDownload != nil {
            infoMessage = "Captions are still being made for “\(project.name)”. Wait for them to finish, or press Cancel, then open the new video."
            return
        }
        // A picture or a document said "may be damaged or use an unsupported codec",
        // which sent people looking for a codec.
        if let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic,
           !type.conforms(to: .audiovisualContent) {
            errorMessage = "“\(url.lastPathComponent)” isn't a video or audio file. Choose a video (MP4, MOV) or an audio file."
            return
        }
        // A video opened from Finder while Subly started used to be cancelled by
        // reopening the last project, which ran while this waited for the languages.
        importsInFlight += 1
        defer { importsInFlight -= 1 }
        // Only the newest request lands. A slow file opened first used to finish
        // reading after a newer one had started making captions, and cancel them.
        let token = UUID()
        importToken = token
        // The remembered language can only be applied once the languages are known.
        for _ in 0..<40 where isLoadingCapabilities { try? await Task.sleep(for: .milliseconds(250)) }
        do {
            let info = try await mediaService.probe(url)
            guard importToken == token, !generation.isRunning, generateAfterDownload == nil else { return }
            guard info.hasAudio else {
                errorMessage = MediaService.MediaError.noAudioTrack.localizedDescription  // token checked above
                return
            }
            // Dropping in a video that already has captions opens them, instead of
            // starting a second project and leaving the first one hidden behind it.
            if let existing = savedProjects.first(where: {
                $0.mediaPath == url.path(percentEncoded: false) && !$0.tracks.isEmpty
            }), ProjectStore.mediaState(path: existing.mediaPath, expecting: existing.mediaFingerprint) == .present {
                openProject(existing)
                infoMessage = "You already have captions for this video, so Subly opened them. To make new ones, use Make Captions Again on the Choose step."
                return
            }
            flushPendingSave()
            cancelGeneration()
            resetEditingState()
            mediaMissingPath = nil
            project = Project(name: url.deletingPathExtension().lastPathComponent)
            project.captionStyle = Self.defaultCaptionStyle
            project.mediaURL = url
            project.mediaInfo = info
            // Drop the previous project's index, or the grid renders phantom rows.
            index = ProjectIndex()
            applyDefaults()
            preparePlayer(url)
            route = .newProject
            // Listen for the language straight away. Only the remembered language was
            // applied, so an English video opened after a Hindi one was set to Hindi.
            // Whisper's detector needs one short pass; without it, keep the choice.
            if ExtendedEngineManager.shared.installedPacks.contains(where: \.isGeneral), !Self.isHookRun {
                Task { await autoDetectLanguage() }
            }
            await loadReferenceTrackIfPresent(for: url)
        } catch {
            // Only for the import still wanted.
            guard importToken == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Offer an existing sidecar subtitle as a read-only reference track. PRD MED-06.
    func loadReferenceTrackIfPresent(for url: URL) async {
        let base = url.deletingPathExtension()
        for ext in ["srt", "vtt"] {
            let candidate = base.appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let cues = SubtitleImporter().parse(text)
            guard !cues.isEmpty else { continue }
            let track = SubtitleTrack(kind: .original, languageTag: "und",
                                      displayName: "\(candidate.lastPathComponent) (reference)",
                                      cues: cues, engineID: "Imported", isReference: true)
            // Only into the project the video belongs to.
            guard project.mediaURL == url else { return }
            project.tracks.append(track)
            project.visibleTrackIDs.insert(track.id)
            rebuildIndex()
            infoMessage = "Found \(candidate.lastPathComponent) next to the video and added it for comparison. It can't be edited and isn't included when you export."
            return
        }
    }

    func preparePlayer(_ url: URL) {
        // Tear the old observer down against the player that issued it. Removing a
        // token from a different AVPlayer is an error, and leaving it attached keeps
        // the old player alive and stops currentTime updating.
        detachTimeObserver()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p
        currentTime = 0
        isPlaying = false
        // Observed from the start: the Choose step plays the video too, and without
        // the observer the clock never moved and the end of the video was never seen,
        // so it could not be played again.
        attachTimeObserver()
    }

    // MARK: - Time observation

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private weak var observedPlayer: AVPlayer?

    /// Idempotent, and re-binds when the player is replaced.
    func attachTimeObserver() {
        guard let player else { return }
        if observedPlayer === player, timeObserver != nil { return }
        detachTimeObserver()
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        observedPlayer = player
        let clock = self.clock
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard time.isNumeric else { return }
            MainActor.assumeIsolated {     // delivered on .main, as requested above
                // Write straight to the clock: only time-showing views invalidate.
                clock.currentTime = time.seconds
                if let duration = self?.project.mediaInfo?.duration,
                   duration > 0, time.seconds >= duration - 0.05 {
                    clock.isPlaying = false
                }
            }
        }
    }

    func detachTimeObserver() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
    }

    // MARK: - Generation

    /// "Remember these choices for next time", on the Choose step. On by default:
    /// a Hindi creator re-chose Hindi and Hinglish for every single video.
    var rememberChoices: Bool = UserDefaults.standard.object(forKey: "rememberChoices") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rememberChoices, forKey: "rememberChoices") }
    }

    /// Store this project's choices as the starting point for the next new project.
    func rememberCurrentChoices() {
        // Test and review runs never change what the person's own next project starts with.
        guard !Self.isHookRun else { return }
        let defaults = UserDefaults.standard
        defaults.set(project.sourceLanguage, forKey: "lastSourceLanguage")
        defaults.set(project.selectedOutputs.map(\.rawValue).sorted().joined(separator: ","),
                     forKey: "lastOutputs")
        // Only a language someone chose: a target the app fell back to (English
        // speech can't be translated into English) came back on the next video.
        if project.selectedOutputs.contains(.translation) {
            defaults.set(project.translationTarget, forKey: "lastTranslationTarget")
        }
        defaults.set(project.presetName, forKey: "lastPreset")
        if let data = try? JSONEncoder().encode(project.rules) { defaults.set(data, forKey: "lastRules") }
    }

    func generate() {
        guard let media = project.mediaURL else { return }
        if rememberChoices { rememberCurrentChoices() }
        guard !project.selectedOutputs.isEmpty else {
            errorMessage = "Tick at least one subtitle output."
            return
        }
        generationTask?.cancel()
        // Work begun on the old captions can't be allowed to land on the new ones: a
        // re-cut finishing after Listen Again saved tracks cut from the old transcript.
        abandonPendingRecut()
        cancelOutputWork()
        generation = .running(stage: "Starting", fraction: 0)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Subly/\(project.id.uuidString)", isDirectory: true)
        let request = GenerationPipeline.Request(
            mediaURL: media,
            workingDirectory: work,
            sourceLanguage: project.sourceLanguage,
            outputs: project.selectedOutputs,
            translationTarget: project.translationTarget,
            rules: project.rules,
            protectedTerms: protectedTerms,
            vocabulary: project.vocabulary,
            useRefinement: project.useRefinement,
            translator: { [bridge = translationBridge] texts, source, target in
                try await bridge.translate(texts, from: source, to: target)
            })

        // Every update and the result belong to this run, in this project. A run that
        // finished after another project was opened used to put its captions there.
        let token = UUID()
        generationToken = token
        let projectID = project.id
        generationTask = Task { [pipeline] in
            do {
                let output = try await pipeline.generate(request) { update in
                    Task { @MainActor in
                        guard self.generationToken == token else { return }
                        self.generation = .running(stage: update.stage, fraction: update.fraction)
                    }
                }
                if Task.isCancelled {
                    await MainActor.run {
                        if self.generationToken == token { self.generation = .idle; self.generationTask = nil }
                    }
                    return
                }
                await MainActor.run {
                    // Guard again on the main actor: the user may have cancelled while
                    // the final hop was in flight, and clobbering their state then
                    // would yank them into the editor unasked.
                    guard self.generationToken == token, self.project.id == projectID,
                          case .running = self.generation else { return }
                    let references = self.project.tracks.filter(\.isReference)
                    // Listening again replaces captions someone may have just corrected,
                    // even while it ran: keep them one ⌘Z away instead of losing them.
                    let before = self.project.hasGeneratedCaptions ? EditSnapshot(self.project, label: "Listen Again") : nil
                    self.project.spine = output.spine
                    self.project.slots = output.slots
                    self.project.tracks = output.tracks + references
                    self.project.waveform = output.waveform
                    self.project.audioURL = output.audioURL
                    self.project.generationFailures = output.failures
                    self.project.captionsEdited = false
                    self.editRevision += 1
                    // One track on the picture to start with — English letters if made,
                    // else the transcript. Three stacked tracks covered about 40% of a
                    // vertical frame; the others are listed and one click away.
                    let primary = [OutputKind.romanized, .original, .translation].lazy
                        .compactMap { kind in output.tracks.first { $0.kind == kind } }.first
                    self.project.visibleTrackIDs = Set([primary?.id].compactMap { $0 })
                        .union(self.project.tracks.filter(\.isReference).map(\.id))
                    self.focusedTrackID = output.tracks.first?.id
                    self.selectedCueSlot = output.tracks.first?.cues.first?.slotIndex
                    // Land on the first caption so there is text on screen straight away.
                    if let first = output.tracks.first?.cues.first { self.seek(to: first.start + 0.01) }
                    if let before { self.commitUndo(before) }
                    else { self.undoStack.removeAll(); self.redoStack.removeAll() }
                    self.rebuildIndex()
                    // New captions open on the Captions tab, not wherever the last
                    // project's panel was left.
                    self.panelTab = .captions
                    self.generation = .done
                    // Finished: Undo during a later Add Captions decides whether a run is
                    // still going by this, and a stale handle left its banner stuck.
                    self.generationTask = nil
                    // Into the editor from the Choose step; someone who went back to
                    // their projects meanwhile is not pulled away from them.
                    if self.route != .home { self.route = .editor }
                    self.saveProject()
                    self.loadRecentProjects()
                    ProjectThumbnail.makeIfMissing(media: media, id: self.project.id,
                                                   directory: self.projectsDirectory,
                                                   duration: self.project.mediaInfo?.duration ?? 0)
                    if !self.recentProjects.contains(where: { $0.id == self.project.id }) {
                        self.recentProjects.insert(self.project, at: 0)
                    }
                    let notes = (output.spine.warning.map { [$0] } ?? [])
                        + output.failures.map { self.explain($0.kind, $0.message) }
                    if !notes.isEmpty { self.infoMessage = notes.joined(separator: "\n\n") }
                }
            } catch {
                await MainActor.run {
                    guard self.generationToken == token else { return }
                    self.generation = Task.isCancelled ? .idle : .failed(error.localizedDescription)
                    self.generationTask = nil
                }
            }
        }
    }

    /// One output that could not be made, said so a person can fix it. A missing
    /// translation language came through as Apple's bare "Unable to Translate".
    func explain(_ kind: OutputKind, _ message: String, target: String? = nil) -> String {
        guard kind == .translation, let cap = currentCapability else { return "\(kind.shortLabel): \(message)" }
        let from = cap.displayName, to = CapabilityRegistry.displayName(target ?? project.translationTarget)
        return "The \(to) translation wasn't made. macOS needs its \(from) and \(to) translation languages: "
            + "choose Download when it offers them, or add them in System Settings › General › Language & Region › Translation Languages. "
            + "Then use Add Captions in the Captions tab to make the translation."
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        addOutputTask?.cancel(); addOutputTask = nil
        addOutputToken = UUID()
        generationToken = UUID()     // late updates from the cancelled run are ignored
        if case .running = generation { generation = .idle }
    }

    // MARK: - Asset install

    func installAssets(for language: String) {
        assetInstallLanguage = language
        assetInstallProgress = 0
        Task { [transcription] in
            do {
                try await transcription.installAssets(for: language) { f in
                    Task { @MainActor in self.assetInstallProgress = f }
                }
                await MainActor.run {
                    self.assetInstallLanguage = nil
                    self.infoMessage = "\(CapabilityRegistry.displayName(language)) is ready to use offline."
                }
                await registry.invalidate()
                await loadCapabilities()
            } catch {
                await MainActor.run {
                    self.assetInstallLanguage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Editing

    /// - Parameter coalescing: edits with the same key less than a second apart are one
    ///   undo step. Dragging a caption edge used to push an entry on every mouse move,
    ///   so one drag could fill the 80-step history and push out earlier text edits.
    /// - Parameter marksEdited: false for changes that leave the words alone (the
    ///   look), so re-cutting or listening again doesn't warn about losing corrections.
    ///   It used to compare the label, and renaming a label broke it.
    func pushUndo(_ label: String, coalescing key: String? = nil, marksEdited: Bool = true) {
        let now = Date()
        if let key, key == lastUndoKey, now.timeIntervalSince(lastUndoTime) < 1, !undoStack.isEmpty {
            lastUndoTime = now
            redoStack.removeAll()
            // Still an edit: a re-cut started since the first nudge must not land on it.
            editRevision += 1
            abandonPendingRecut()
            return
        }
        lastUndoKey = key
        lastUndoTime = now
        editRevision += 1
        // Any edit supersedes a re-cut still in progress; its result would otherwise
        // land on top of this edit.
        abandonPendingRecut()
        undoStack.append(EditSnapshot(project, label: label))
        if marksEdited { project.captionsEdited = true }
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let snapshot = undoStack.popLast(), snapshot.projectID == project.id else { return }
        abandonPendingRecut()      // a pending re-cut must not undo the undo
        cancelOutputWork()
        editRevision += 1
        redoStack.append(EditSnapshot(project, label: snapshot.label))
        snapshot.restore(into: project)
        lastUndoKey = nil        // the next drag is a new step, not part of the undone one
        rebuildIndex()
        scheduleAutosave()
    }

    func redo() {
        guard let snapshot = redoStack.popLast(), snapshot.projectID == project.id else { return }
        abandonPendingRecut()
        cancelOutputWork()
        editRevision += 1
        undoStack.append(EditSnapshot(project, label: snapshot.label))
        snapshot.restore(into: project)
        lastUndoKey = nil
        rebuildIndex()
        scheduleAutosave()
    }

    /// Called whenever a different project becomes current. History, selection and
    /// in-progress gestures belong to the project they happened in: undo used to write
    /// the previous project's captions into the one just opened.
    func resetEditingState() {
        // A pending "download, then generate" belonged to the project being left.
        generateAfterDownload = nil
        generateAfterDownloadProject = nil
        undoStack.removeAll(); redoStack.removeAll()
        lastUndoKey = nil
        selectedCueSlot = nil
        draggingCue = nil
        abandonPendingRecut()
    }

    /// Record a snapshot taken earlier as the latest undo step.
    private func commitUndo(_ snapshot: EditSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastUndoKey = nil
        editRevision += 1
    }

    /// Stop an Add Track or translation change in progress. Undo restores tracks the
    /// running work did not expect, so its result would no longer fit.
    func cancelOutputWork() {
        guard addOutputTask != nil else { return }
        addOutputTask?.cancel(); addOutputTask = nil
        addOutputToken = UUID()
        if case .running = generation, generationTask == nil { generation = .done }
    }

    /// Editing one track never touches another track's text. PRD MULTI-05.
    func updateCueText(trackID: UUID, cueID: UUID, lines: [String]) {
        guard let t = project.tracks.firstIndex(where: { $0.id == trackID }),
              let c = project.tracks[t].cues.firstIndex(where: { $0.id == cueID }) else { return }
        guard project.tracks[t].cues[c].lines != lines else { return }
        pushUndo("Edit Caption")
        project.tracks[t].cues[c].lines = lines
        rebuildIndex(trackID: trackID)
        scheduleAutosave()
    }

    /// Timing is shared, so a timing change applies across every track. PRD MULTI-06.
    ///
    /// The requested times are clamped to the neighbouring cues. Without this the
    /// editor could push one cue past the next, which produces an overlap that
    /// `SubtitleWriter.validate` rejects — the user would silently end up with a
    /// project that cannot be exported.
    func updateCueTiming(slotIndex: Int, start: Double, end: Double) {
        guard let bounds = CueTiming.clamp(slotIndex: slotIndex,
                                           requestedStart: start, requestedEnd: end,
                                           slots: project.slots,
                                           mediaDuration: project.mediaInfo?.duration)
        else { return }
        let newStart = bounds.start, newEnd = bounds.end, clamped = bounds.wasClamped
        pushUndo("Change Timing", coalescing: "timing-\(slotIndex)")
        for t in project.tracks.indices where !project.tracks[t].isReference {
            for c in project.tracks[t].cues.indices
            where project.tracks[t].cues[c].slotIndex == slotIndex {
                project.tracks[t].cues[c].start = newStart
                project.tracks[t].cues[c].end = newEnd
            }
        }
        if let i = project.slots.firstIndex(where: { $0.index == slotIndex }) {
            project.slots[i].start = newStart
            project.slots[i].end = newEnd
        }
        // Mid-drag, skip the full re-index (milliseconds on a long project, at mouse
        // rate) and the alert (it popped up while the mouse was still down).
        guard draggingCue == nil else { return }
        rebuildIndex()
        if clamped {
            infoMessage = "Adjusted so it doesn't overlap the caption before or after it."
        }
        scheduleAutosave()
    }

    /// End of a timeline drag: do the work skipped while it was in progress.
    func finishRetime() {
        draggingCue = nil
        rebuildIndex()
        scheduleAutosave()
    }

    func reflow(trackID: UUID?) {
        pushUndo("Tidy Lines")
        for t in project.tracks.indices where !project.tracks[t].isReference {
            if let trackID, project.tracks[t].id != trackID { continue }
            // Each track reflows with ITS OWN script profile. Using the source
            // profile for every track re-broke an English translation of Japanese
            // speech with CJK rules, cutting words mid-token.
            let track = project.tracks[t]
            let language = track.kind == .original ? project.sourceLanguage : track.languageTag
            let profile = ScriptProfile.forLanguage(language)
            let formatter = CaptionFormatter(rules: project.rules.adjusted(for: profile),
                                              profile: profile)
            project.tracks[t].cues = formatter.reflow(track.cues)
        }
        rebuildIndex()
        scheduleAutosave()
    }

    func deleteTrack(_ id: UUID) {
        pushUndo("Remove Captions")
        project.tracks.removeAll { $0.id == id }
        project.visibleTrackIDs.remove(id)
        if focusedTrackID == id { focusedTrackID = project.tracks.first?.id }
        rebuildIndex()
        scheduleAutosave()
    }

    /// Swap the translation to a different language, reusing the existing spine so
    /// speech recognition does not run again. Previously the target could only be
    /// chosen before generating, and afterwards there was no way to tell what it had
    /// translated into, let alone change it.
    func retranslate(to target: String) {
        guard project.spine != nil else { return }
        let existing = project.tracks.first(where: { $0.kind == .translation && !$0.isReference })
        project.selectedOutputs.insert(.translation)
        addOutput(.translation, replacing: existing?.id, target: target)
    }

    /// Light or dark, independent of the system. Requested because the app followed
    /// the system with no way to override it.
    enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    var appearance: Appearance {
        get { Appearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }
    @ObservationIgnored @AppStorage("appearance") private var appearanceRaw = "system"

    /// Bumped by the View menu's zoom commands; the timeline watches it so ⌘+ and ⌘−
    /// work from the keyboard as well as the on-screen buttons.
    var timelineZoomRequest = 0

    /// The cue edge currently being dragged in the timeline, so the scrub gesture can
    /// stand aside while a retime is in progress.
    var draggingCue: Int?

    /// Change the spoken language without re-transcribing, so the engine picker and the
    /// available outputs update and the user can decide what to do next.
    func switchSpokenLanguage(to languageTag: String) {
        project.sourceLanguage = languageTag
        pruneUnavailableOutputs()
    }

    /// Switch the spoken language and immediately re-transcribe, requesting `want` as
    /// well as whatever is already selected.
    ///
    /// Exists because the useful outputs depend on the spoken language, and getting
    /// from "wrong language" to "the track I wanted" took four separate steps in three
    /// different places: notice the language is wrong, change it, redo the
    /// transcription, then add the track. A user asked how to get Hinglish three times
    /// before this existed.
    func switchLanguage(to languageTag: String, wanting want: OutputKind?) {
        project.sourceLanguage = languageTag
        if let want { project.selectedOutputs.insert(want) }
        pruneUnavailableOutputs()
        redoTranscription()
    }

    /// Re-run speech recognition on the same file with the current language and engine.
    /// Replaces every generated track, so the caller must warn first.
    /// The current captions stay until the new ones are ready. They used to be cleared
    /// first, so a failed redo left an empty editor.
    func redoTranscription() {
        guard project.mediaURL != nil else { return }
        // The whole file is always listened to again. Stopping and going back to the
        // start shows that: a redo begun mid-video kept playing from there, under the
        // old captions, and looked like it only redid the rest.
        if isPlaying { togglePlayback() }
        seek(to: 0)
        selectedCueSlot = nil
        generateOrDownload()
    }

    /// Change how many words a caption holds and re-cut every track from the existing
    /// transcript. Nothing is listened to again, so it takes a moment; ⌘Z restores the
    /// previous captions, including any edits made to them.
    /// The rules waiting for a re-cut to finish. Rules and captions are committed
    /// together, only on success: changing the rules first left new rules with old
    /// captions whenever the re-cut was undone, cancelled or failed.
    var pendingRules: CaptionRules?
    /// The state before the first change of this burst, recorded as one undo step when
    /// the re-cut lands.
    @ObservationIgnored private var pendingRecutSnapshot: EditSnapshot?

    func setWordsPerCaption(min lower: Int, max upper: Int) {
        var rules = pendingRules ?? project.rules
        rules.setWordsPerCue(min: lower, max: upper)
        if pendingRules == nil { pendingRecutSnapshot = EditSnapshot(project, label: "Change Words per Caption") }
        pendingRules = rules
        recutCaptions(rules: rules)
    }

    /// Stop a re-cut that has not landed, leaving everything as it was.
    func abandonPendingRecut() {
        recutTask?.cancel(); recutTask = nil
        pendingRules = nil
        pendingRecutSnapshot = nil
    }

    func recutCaptions(rules newRules: CaptionRules? = nil) {
        guard let spine = project.spine else { return }
        guard let media = project.mediaURL else {
            // The stepper showed the new number and nothing happened.
            abandonPendingRecut()
            infoMessage = "Subly can't find this project's video, so the captions can't be re-cut. Choose the video again first."
            return
        }
        let rules = newRules ?? project.rules
        let kinds = Set(project.tracks.filter { !$0.isReference }.map(\.kind))
        guard !kinds.isEmpty else { return }
        recutTask?.cancel()

        var request = GenerationPipeline.Request(
            mediaURL: media,
            workingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("Subly/\(project.id.uuidString)", isDirectory: true),
            sourceLanguage: project.sourceLanguage,
            outputs: kinds,
            translationTarget: project.translationTarget,
            rules: rules,
            protectedTerms: protectedTerms,
            useRefinement: project.useRefinement,
            translator: { [bridge = translationBridge] texts, source, target in
                try await bridge.translate(texts, from: source, to: target)
            })
        request.reuse = .init(spine: spine, audioURL: project.audioURL ?? media,
                              waveform: project.waveform)

        let projectID = project.id
        let revision = editRevision
        recutTask = Task { [pipeline] in
            // Clicking the stepper three times used to run three full re-cuts, each
            // re-translating when a translation track exists. Wait for the clicks to
            // settle; a newer click cancels this one.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let output: GenerationPipeline.Output
            do { output = try await pipeline.generate(request) }
            catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        guard self.project.id == projectID else { return }
                        self.abandonPendingRecut()      // nothing changed, rules included
                        self.errorMessage = "Couldn't re-cut the captions, so nothing was changed. \(error.localizedDescription)"
                    }
                }
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only into the project it was started for, and only if nothing was
                // edited or undone meanwhile.
                guard self.project.id == projectID, self.editRevision == revision, !Task.isCancelled else { return }
                // All or nothing: a translation that failed used to vanish silently,
                // replaced by just the tracks that succeeded.
                guard output.failures.isEmpty else {
                    self.abandonPendingRecut()
                    self.errorMessage = "Couldn't re-cut the captions, so nothing was changed. "
                        + output.failures.map { "\($0.kind.shortLabel): \($0.message)" }.joined(separator: " ")
                    return
                }
                let references = self.project.tracks.filter(\.isReference)
                // Same track, new cues: keep each track's identity so what is shown,
                // what is focused, and undo all carry on as before.
                var tracks = output.tracks
                for k in tracks.indices {
                    if let old = self.project.tracks.first(where: { !$0.isReference && $0.kind == tracks[k].kind }) {
                        tracks[k].id = old.id
                        tracks[k].displayName = old.displayName
                    }
                }
                // One undo step for the whole burst, with the state from before it.
                if let before = self.pendingRecutSnapshot { self.commitUndo(before) }
                self.project.rules = rules
                self.project.slots = output.slots
                self.project.tracks = tracks + references
                self.project.captionsEdited = false
                self.pendingRules = nil
                self.pendingRecutSnapshot = nil
                self.recutTask = nil
                self.selectedCueSlot = nil
                self.rebuildIndex()
                self.scheduleAutosave()
            }
        }
    }
    @ObservationIgnored private var recutTask: Task<Void, Never>?

    /// Add an output to an existing project WITHOUT re-running speech recognition.
    /// PRD MULTI-07.
    ///
    /// - Parameter replacing: a track this one replaces (a translation into another
    ///   language). The old track stays until the new one is ready: removing it first
    ///   meant a failed translation left no translation at all.
    func addOutput(_ requested: OutputKind, replacing oldID: UUID? = nil, target requestedTarget: String? = nil) {
        guard let spine = project.spine, !project.slots.isEmpty else { return }
        // Apex-style models write Hindi in English letters, so "the transcript" from
        // them IS the Hinglish track.
        let kind: OutputKind = requested == .original && spine.isRomanizedSource ? .romanized : requested
        guard oldID != nil || !project.tracks.contains(where: { $0.kind == kind && !$0.isReference }) else { return }
        generation = .running(stage: "Adding \(kind.shortLabel.lowercased())", fraction: 0.2)

        let sourceCode = project.sourceLanguage.split(separator: "-").first.map(String.init)
            ?? project.sourceLanguage
        let target = requestedTarget ?? project.translationTarget
        // Format each output in ITS OWN script: an English translation of Japanese was
        // broken up by characters because every new track used the source's rules.
        let outputLanguage: String
        switch kind {
        case .original:    outputLanguage = spine.isRomanizedSource ? "\(sourceCode)-Latn" : sourceCode
        case .translation: outputLanguage = target
        case .romanized:   outputLanguage = "\(sourceCode)-Latn"
        }
        let profile = ScriptProfile.forLanguage(outputLanguage)
        let rules = project.rules.adjusted(for: profile)
        let slots = project.slots
        let terms = protectedTerms
        let refine = project.useRefinement
        let projectID = project.id
        let bridge = translationBridge
        let token = UUID()
        addOutputToken = token
        addOutputTask?.cancel()

        // Off the main actor: building a long project's text froze editing and playback.
        // Kept as a task so Cancel reaches it.
        addOutputTask = Task.detached(priority: .userInitiated) {
            let formatter = CaptionFormatter(rules: rules, profile: profile)
            // `project.slots` is the UNIFIED grid, so text must be keyed by parent
            // slot — keying by sub-slot index dropped every word after the first
            // sub-slot of each parent.
            let sourceTexts = GenerationPipeline.parentSlotTexts(spine: spine, slots: slots)
            let romanizer = Romanizer()
            let refinementService = RefinementService()
            do {
                var track: SubtitleTrack
                switch kind {
                case .original:
                    track = SubtitleTrack(kind: .original, languageTag: sourceCode,
                                          displayName: "\(CapabilityRegistry.displayName(sourceCode)) transcript",
                                          cues: formatter.fill(slots: slots, texts: sourceTexts),
                                          engineID: spine.engineID)
                case .translation:
                    // Through the window's translation session, which can download a
                    // missing language pair; the plain service only refused.
                    var texts = try await bridge.translate(sourceTexts, from: sourceCode, to: target)
                    if refine, await refinementService.isAvailable {
                        texts = await refinementService.refine(
                            slotTexts: texts, language: target,
                            instruction: "Fix punctuation and capitalisation in these subtitle lines.")
                    }
                    track = SubtitleTrack(kind: .translation, languageTag: target,
                                          displayName: "\(CapabilityRegistry.displayName(target)) translation",
                                          cues: formatter.fill(slots: slots, texts: texts),
                                          engineID: spine.engineID)
                case .romanized:
                    var texts: [Int: String] = [:]
                    if spine.isRomanizedSource {
                        // Already in English letters; transliterating again corrupts it.
                        texts = sourceTexts
                    } else {
                        for (slot, text) in sourceTexts {
                            texts[slot] = romanizer.romanize(text, language: sourceCode,
                                                              protectedTerms: terms).text
                        }
                    }
                    if !spine.isRomanizedSource, refine, await refinementService.isAvailable {
                        texts = await refinementService.rerankRomanization(
                            slotTexts: texts, language: sourceCode, protectedTerms: terms)
                    }
                    let label = sourceCode == "hi" ? "Hinglish"
                        : "\(CapabilityRegistry.displayName(sourceCode)) in English letters"
                    track = SubtitleTrack(kind: .romanized, languageTag: "\(sourceCode)-Latn",
                                          displayName: label,
                                          cues: formatter.fill(slots: slots, texts: texts),
                                          engineID: spine.engineID)
                }
                let finished = track
                await MainActor.run {
                    // Same project, same caption grid, or the result no longer fits:
                    // a split made meanwhile would have mixed two grids.
                    guard self.project.id == projectID, self.addOutputToken == token, !Task.isCancelled else { return }
                    guard self.project.slots == slots else {
                        self.generation = .done
                        self.errorMessage = "The captions changed while the new track was being made, so it wasn't added. Please try again."
                        return
                    }
                    // The track being replaced must still be there; otherwise an undo
                    // changed things meanwhile and this result would add a duplicate.
                    if let oldID, !self.project.tracks.contains(where: { $0.id == oldID }) {
                        self.generation = .done
                        return
                    }
                    // Started twice? Only one track of a kind.
                    if oldID == nil, self.project.tracks.contains(where: { $0.kind == kind && !$0.isReference }) {
                        self.generation = .done
                        return
                    }
                    self.pushUndo(oldID == nil ? "Add Captions" : "Change Translation Language")
                    // The new language is set with the track, after the undo snapshot, so
                    // undo brings back the old language and track together.
                    if kind == .translation { self.project.translationTarget = target }
                    let references = self.project.tracks.filter(\.isReference)
                    var generated = self.project.tracks.filter { !$0.isReference && $0.id != oldID }
                    generated.append(finished)
                    let order: [OutputKind] = [.translation, .romanized, .original]
                    generated.sort {
                        (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9)
                    }
                    self.project.tracks = generated + references
                    if let oldID { self.project.visibleTrackIDs.remove(oldID) }
                    self.project.visibleTrackIDs.insert(finished.id)
                    self.project.selectedOutputs.insert(kind)
                    self.rebuildIndex()
                    self.generation = .done
                    self.saveProject()
                }
            } catch {
                await MainActor.run {
                    guard self.project.id == projectID, self.addOutputToken == token else { return }
                    self.generation = .done
                    if !(error is CancellationError) { self.errorMessage = self.explain(kind, error.localizedDescription, target: target) }
                }
            }
        }
    }
    @ObservationIgnored private var addOutputTask: Task<Void, Never>?
    @ObservationIgnored private var addOutputToken = UUID()

    // MARK: - Diagnostics

    /// Cached. Recomputing this per view body cost 8.7 ms across three tracks on a
    /// long project, on a main thread that redraws 30 times a second.
    func diagnostics(for track: SubtitleTrack) -> [CueDiagnostic] {
        index.index(for: track.id)?.diagnostics ?? []
    }

    func issueCount(for track: SubtitleTrack) -> Int {
        index.index(for: track.id)?.issueCount ?? 0
    }

    /// O(1) cue lookup for a grid cell.
    func cue(in track: SubtitleTrack, slot: Int) -> Cue? {
        guard let position = index.index(for: track.id)?.position(forSlot: slot),
              position < track.cues.count else { return nil }
        return track.cues[position]
    }

    // MARK: - Playback

    func seek(to seconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play(); player.rate = playbackRate }
        isPlaying.toggle()
    }

    /// Real frame stepping via the player item, which lands on actual frame
    /// boundaries — including on variable-frame-rate phone footage, where dividing
    /// by a nominal rate does not.
    func step(frames: Int) {
        guard let player, let item = player.currentItem else { return }
        if isPlaying { player.pause(); isPlaying = false }
        if item.canStepBackward || item.canStepForward {
            item.step(byCount: frames)
            currentTime = player.currentTime().seconds
            return
        }
        // Fallback for audio-only media, where there are no frames to step.
        let fps = Double(project.mediaInfo?.nominalFrameRate ?? 30)
        seek(to: currentTime + Double(frames) / (fps > 0 ? fps : 30))
    }

    /// Cues active at a given time, for the simultaneous overlay.
    ///
    /// Tracks share one cue grid, so a track with less text can legitimately have a
    /// blank cell in some slot. Blank cells are skipped here so the overlay never
    /// flashes an empty caption box, and the writers skip them on export too.
    func activeCues(at time: Double) -> [(track: SubtitleTrack, cue: Cue)] {
        project.tracks.compactMap { track in
            guard project.visibleTrackIDs.contains(track.id) else { return nil }
            // Binary search via the index. This runs 30 times a second during
            // playback, so the linear scan it replaces was 375x more expensive.
            guard let position = index.index(for: track.id)?.cuePosition(at: time),
                  position < track.cues.count else { return nil }
            let cue = track.cues[position]
            guard !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (track, cue)
        }
    }
}
