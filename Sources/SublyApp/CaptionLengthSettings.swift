import AppKit
import SwiftUI
import SublyCaptions

/// How many words a caption holds. In the editor a change re-cuts the captions
/// straight away from the existing transcript; before generating it just sets the rule.
struct WordsPerCaptionRows: View {
    @Environment(AppModel.self) private var model
    var appliesNow: Bool
    /// A change waiting for confirmation, because applying it would replace edits.
    @State private var pending: (min: Int, max: Int)?

    /// The numbers just chosen, while the re-cut that applies them is still running.
    private var rules: CaptionRules { model.pendingRules ?? model.project.rules }

    var body: some View {
        // Number beside its stepper on the right, as System Settings lays it out.
        LabeledContent("Fewest words") {
            HStack(spacing: 6) {
                Text("\(rules.minWordsPerCue)").monospacedDigit()
                Stepper("Fewest words", value: Binding(
                    get: { rules.minWordsPerCue },
                    set: { request(min: $0, max: Swift.max($0, rules.maxWordsPerCue)) }),
                        in: 1...6)
                    .labelsHidden()
            }
        }
        .help("No caption is cut shorter than this, unless a pause in the speech leaves a word on its own.")
        .disabled(appliesNow && model.generation.isRunning)
        LabeledContent("Most words") {
            HStack(spacing: 6) {
                Text("\(rules.maxWordsPerCue)").monospacedDigit()
                Stepper("Most words", value: Binding(
                    get: { rules.maxWordsPerCue },
                    set: { request(min: Swift.min(rules.minWordsPerCue, $0), max: $0) }),
                        in: 2...20)
                    .labelsHidden()
            }
        }
        .help("A caption starts a new one once it holds this many words.")
        .disabled(appliesNow && model.generation.isRunning)
        .confirmationDialog("Re-cut every caption?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Re-cut Captions", role: .destructive) {
                if let p = pending { model.setWordsPerCaption(min: p.min, max: p.max) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Captions are rebuilt from what was heard, so the words you corrected and any captions you split or merged go back to how they were. You can undo this with ⌘Z.")
        }
    }

    /// Re-cutting rebuilds captions from the transcript. It used to do that silently on
    /// every click, wiping corrections; now it asks first when there is anything to lose.
    private func request(min lower: Int, max upper: Int) {
        guard appliesNow else {
            model.project.rules.setWordsPerCue(min: lower, max: upper)
            return
        }
        if model.project.captionsEdited { pending = (lower, upper) }
        else { model.setWordsPerCaption(min: lower, max: upper) }
    }
}

/// The folder subtitles were last saved to. Every save started in Downloads, so saving
/// to the Desktop meant navigating there every single time.
enum ExportFolder {
    static var current: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "exportFolder"),
               FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { UserDefaults.standard.set(newValue.path(percentEncoded: false), forKey: "exportFolder") }
    }
}

/// Save one track as an `.srt` file, without going through the full export sheet.
@MainActor
enum QuickSRT {
    static func save(_ track: SubtitleTrack, projectName: String) -> String? {
        let writer = SubtitleWriter()
        do { try writer.validate(track) } catch { return error.localizedDescription }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = writer.filename(base: projectName, track: track, format: .srt)
        // No allowed type: ".srt" has no system type on most Macs, so the panel took the
        // language tag for the extension and saved "clip.hi-Latn.srt.srt".
        panel.directoryURL = ExportFolder.current
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != "srt" { url.appendPathExtension("srt") }
        ExportFolder.current = url.deletingLastPathComponent()
        do {
            try Data(writer.srt(track).utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
