import Foundation
import AppKit
import SublyCaptions
import SublyEngine

/// Caption-level commands shared by the Captions menu, the toolbar and right-click
/// menus, so every route does exactly the same thing and undoes the same way.
extension AppModel {

    /// The caption commands act on: the selected one, else the one under the playhead.
    /// The selection wins only while the playhead is inside it. After playing on, the
    /// old selection used to stay the target, so ⌘K "split here" acted on a caption
    /// that was long gone and refused with a puzzling message.
    var targetCaptionSlot: Int? {
        let underPlayhead = project.slots.first { currentTime >= $0.start && currentTime < $0.end }?.index
        if let selectedCueSlot, project.slots.indices.contains(selectedCueSlot) {
            let s = project.slots[selectedCueSlot]
            if currentTime >= s.start && currentTime < s.end { return selectedCueSlot }
            return underPlayhead ?? selectedCueSlot
        }
        return underPlayhead
    }

    var canSplitCaption: Bool { canSplit(targetCaptionSlot) }
    var canMergeCaption: Bool { canMerge(targetCaptionSlot) }

    func canSplit(_ slot: Int?) -> Bool {
        guard let slot, project.slots.indices.contains(slot) else { return false }
        // Long enough to cut in two; where it is cut is chosen when splitting.
        let s = project.slots[slot]
        return s.end - s.start > 0.4
    }

    /// Move the start or end of the caption under the playhead to the playhead — the
    /// quickest way to make a caption appear exactly when the words begin.
    func setCaptionEdge(start: Bool) {
        guard let slot = targetCaptionSlot ?? project.slots.last(where: { $0.start <= currentTime })?.index,
              project.slots.indices.contains(slot) else { return }
        let s = project.slots[slot]
        if start { updateCueTiming(slotIndex: slot, start: currentTime, end: s.end) }
        else { updateCueTiming(slotIndex: slot, start: s.start, end: currentTime) }
        selectedCueSlot = slot
    }

    /// Show every caption a little earlier (negative) or later, to match the speech.
    /// Quick repeated nudges are one undo step.
    func shiftAllCaptions(by delta: Double) {
        guard project.hasResults else { return }
        guard !generation.isRunning else {
            infoMessage = "Wait until the captions are made, then adjust the sync."
            return
        }
        let result = CaptionEdits.shift(by: delta, words: project.spine?.words ?? [],
                                        slots: project.slots, tracks: project.tracks,
                                        mediaDuration: project.mediaInfo?.duration)
        guard result.applied != 0 else {
            infoMessage = delta < 0 ? "The captions can't start any earlier." : "The captions can't end any later."
            return
        }
        pushUndo("Shift Captions", coalescing: "sync")
        project.spine?.words = result.words
        project.slots = result.slots
        project.tracks = result.tracks
        rebuildIndex()
        scheduleAutosave()
        let ms = Int((abs(result.applied) * 1000).rounded())
        AccessibilityNotification.Announcement("Captions \(ms) milliseconds \(delta < 0 ? "earlier" : "later")").post()
    }

    /// The next caption after the playhead that has something to check, wrapping round.
    func jumpToNextIssue(in track: SubtitleTrack) {
        let flagged = Set(diagnostics(for: track).map(\.cueID))
        let cues = track.cues.filter { flagged.contains($0.id) }.sorted { $0.start < $1.start }
        guard let next = cues.first(where: { $0.start > currentTime + 0.05 }) ?? cues.first else { return }
        selectedCueSlot = next.slotIndex
        focusedTrackID = track.id
        seek(to: next.start + 0.01)
    }

    func canMerge(_ slot: Int?) -> Bool {
        guard let slot else { return false }
        return slot + 1 < project.slots.count
    }

    func selectCaption(offset: Int) {
        let count = project.slots.count
        guard count > 0 else { return }
        // Finish any caption being typed first, so its text is saved to it.
        NSApp.keyWindow?.makeFirstResponder(nil)
        let current = targetCaptionSlot ?? (offset > 0 ? -1 : count)
        let next = min(count - 1, max(0, current + offset))
        selectedCueSlot = next
        seek(to: project.slots[next].start + 0.01)
        // Say where you landed, for VoiceOver users moving with ⌘[ and ⌘].
        let text = project.tracks.first { project.visibleTrackIDs.contains($0.id) }?
            .cues.first { $0.slotIndex == next }?.text ?? ""
        AccessibilityNotification.Announcement("Caption \(next + 1) of \(count). \(text)").post()
    }

    func splitCaptionAtPlayhead(slot chosen: Int? = nil) {
        NSApp.keyWindow?.makeFirstResponder(nil)   // save a caption being typed first
        guard let slot = chosen ?? targetCaptionSlot else {
            infoMessage = "Move the playhead onto a caption to split it."
            return
        }
        // Clicking a caption puts the playhead at its very start, so Split straight
        // after said "move the playhead further inside". Off the caption's middle part,
        // split between the words nearest its middle instead.
        var time = currentTime
        if project.slots.indices.contains(slot) {
            let span = project.slots[slot]
            if time <= span.start + 0.2 || time >= span.end - 0.2 {
                time = Self.middleSplitTime(span, words: project.spine?.words ?? [])
            }
        }
        do {
            let result = try CaptionEdits.split(slot: slot, at: time, slots: project.slots,
                                                tracks: project.tracks,
                                                words: project.spine?.words ?? [])
            apply(result, label: "Split Caption", select: slot + 1, touched: [slot, slot + 1])
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    /// The start of the word nearest the caption's middle, or the middle itself.
    static func middleSplitTime(_ span: CueSlot, words: [TimedWord]) -> Double {
        let middle = (span.start + span.end) / 2
        let inside = span.wordRange.dropFirst().filter { $0 < words.count }
            .map { words[$0].start }
            .filter { $0 > span.start + 0.2 && $0 < span.end - 0.2 }
        return inside.min { abs($0 - middle) < abs($1 - middle) } ?? middle
    }

    func mergeCaptionWithNext(slot chosen: Int? = nil) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard let slot = chosen ?? targetCaptionSlot else { return }
        do {
            let result = try CaptionEdits.merge(slot: slot, slots: project.slots, tracks: project.tracks)
            apply(result, label: "Merge Captions", select: slot, touched: [slot])
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    /// Re-break only the captions an edit touched, so line breaks the user chose
    /// elsewhere are left alone.
    /// - Parameter touched: the captions the edit changed. Only these are re-broken;
    ///   it used to re-break the caption after a split and miss the first half.
    private func apply(_ result: CaptionEdits.Result, label: String, select slot: Int, touched: Set<Int>) {
        pushUndo(label)
        var tracks = result.tracks
        for t in tracks.indices where !tracks[t].isReference {
            // Keep the script subtag: "hi-Latn" is English letters, and stripping it
            // re-broke Hinglish with Hindi-script rules.
            let language = tracks[t].kind == .original ? project.sourceLanguage : tracks[t].languageTag
            let profile = ScriptProfile.forLanguage(language)
            let formatter = CaptionFormatter(rules: project.rules.adjusted(for: profile), profile: profile)
            for c in tracks[t].cues.indices where touched.contains(tracks[t].cues[c].slotIndex) {
                tracks[t].cues[c] = formatter.reflow([tracks[t].cues[c]])[0]
            }
        }
        project.slots = result.slots
        project.tracks = tracks
        selectedCueSlot = slot
        rebuildIndex()
        scheduleAutosave()
    }

    static let playbackSpeeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    // MARK: Word timing for animated captions

    /// When each word of `cue` is spoken, relative to its start, for Karaoke and
    /// Typewriter. Taken from what the recogniser heard when the caption still has
    /// those words; guessed from word lengths when it was edited; nil for a
    /// translation, whose word order does not follow the speech.
    func wordTimes(track: SubtitleTrack, cue: Cue) -> [CaptionAnimationTiming.Word]? {
        guard track.kind != .translation, !track.isReference else { return nil }
        let text = project.captionStyle.display(cue.lines.joined(separator: "\n"))
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        if let spine = project.spine, project.slots.indices.contains(cue.slotIndex) {
            let range = project.slots[cue.slotIndex].wordRange
            let heard = range.filter { $0 < spine.words.count }.map { spine.words[$0] }
            if heard.count == tokens.count, !heard.isEmpty {
                return zip(tokens, heard).map { token, word in
                    .init(text: token, start: max(0, word.start - cue.start),
                          end: max(0, min(cue.duration, word.end - cue.start)))
                }
            }
        }
        return CaptionAnimationTiming.words(in: text, start: 0, end: cue.duration)
    }

    // MARK: Video with captions

    /// The tracks shown on the preview, in its order — the starting choice for what a
    /// video export burns in. It used to fall back to every track when all were hidden,
    /// so the video disagreed with the preview.
    var tracksShownOnVideo: [SubtitleTrack] {
        project.tracks.filter { !$0.isReference && project.visibleTrackIDs.contains($0.id) }
    }

    /// Opens the export options, where the tracks to burn in are chosen.
    @MainActor func exportCaptionedVideo() {
        guard project.hasResults, videoExportTask == nil else { return }
        guard project.mediaURL != nil else {
            errorMessage = "Subly can't find this project's video. Choose it again (the banner above the video), then save the video with captions."
            return
        }
        guard project.mediaInfo?.hasVideo != false else {
            errorMessage = CaptionVideoExporter.ExportError.noVideo.localizedDescription
            return
        }
        showVideoExport = true
    }

    /// Asks where to save, then exports with the chosen tracks.
    @MainActor func chooseDestinationAndExport(trackIDs: [UUID]) {
        guard let media = project.mediaURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name) with captions.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = ExportFolder.current
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ExportFolder.current = url.deletingLastPathComponent()
        runVideoExport(media: media, trackIDs: trackIDs, to: url, reveal: true)
    }

    /// One export at a time. Each run owns a token, so a finished or cancelled run can
    /// never clear the progress of a newer one; switching projects does not stop it,
    /// because everything it needs was captured when it started.
    @MainActor func runVideoExport(media: URL, trackIDs: [UUID], to url: URL, reveal: Bool,
                                   finished: (@MainActor (Error?) -> Void)? = nil) {
        guard videoExportTask == nil else { return }
        if isPlaying { togglePlayback() }
        let style = project.captionStyle
        let tracks: [[CaptionVideoExporter.Item]] = project.tracks
            .filter { trackIDs.contains($0.id) }
            .map { track in
                track.cues.map { cue in
                    CaptionVideoExporter.Item(cue: cue, words: style.animation.isPerWord ? wordTimes(track: track, cue: cue) : nil)
                }
            }
        let token = UUID()
        videoExportToken = token
        videoExportProgress = 0
        videoExportTask = Task { @MainActor in
            defer {
                if self.videoExportToken == token { self.videoExportTask = nil; self.videoExportProgress = nil }
            }
            AccessibilityNotification.Announcement("Exporting video with captions").post()
            do {
                try await CaptionVideoExporter.export(media: media, tracks: tracks, style: style, to: url) { fraction in
                    Task { @MainActor in
                        if self.videoExportToken == token, self.videoExportTask != nil { self.videoExportProgress = fraction }
                    }
                }
                AccessibilityNotification.Announcement("Video exported").post()
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                finished?(nil)
            } catch {
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
                finished?(error)
            }
        }
    }

    /// The export stays "running" until it has actually stopped (its own cleanup clears
    /// it), so a new one cannot start while the old one is still winding down.
    func cancelVideoExport() {
        videoExportTask?.cancel()
    }

    // MARK: Caption style

    /// Undoable; quick changes (dragging a slider) are one step. Style changes could
    /// not be undone, and choosing a template wiped custom colours with no way back.
    func setCaptionStyle(_ style: CaptionStyle) {
        guard style != project.captionStyle else { return }
        pushUndo("Change Look", coalescing: "style", marksEdited: false)
        project.captionStyle = style
        scheduleAutosave()
    }

    /// Switching template keeps where the captions were placed.
    func applyTemplate(_ template: CaptionStyle.Template) {
        var style = CaptionStyle.preset(template)
        style.position = project.captionStyle.position
        setCaptionStyle(style)
    }

    /// Back to the template exactly as it ships, position included.
    func resetStyle() {
        setCaptionStyle(.preset(project.captionStyle.template))
    }

    /// The look new projects start with. A creator posting daily set it up every time.
    static var defaultCaptionStyle: CaptionStyle {
        get {
            guard let data = UserDefaults.standard.data(forKey: "defaultCaptionStyle"),
                  let style = try? JSONDecoder().decode(CaptionStyle.self, from: data) else { return .default }
            return style
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "defaultCaptionStyle") }
    }

    func useStyleForNewProjects() {
        Self.defaultCaptionStyle = project.captionStyle
        infoMessage = "New projects will start with this caption style."
    }

    /// Keyboard and VoiceOver way to place captions; dragging was the only one.
    func nudgeCaptionPosition(_ delta: Double) {
        setCaptionPosition(project.captionStyle.position + delta)
        let percent = Int((project.captionStyle.position * 100).rounded())
        AccessibilityNotification.Announcement("Captions \(percent) percent down the picture").post()
    }

    func setCaptionPosition(_ position: Double) {
        var style = project.captionStyle
        style.position = min(0.95, max(0.06, position))
        setCaptionStyle(style)
    }

    /// The track "Save SRT…" saves: the one being edited, else the first one shown on
    /// the video, else the first generated one. Picking the first track blindly saved
    /// Hindi script for someone who was working on the Hinglish track.
    var srtTrack: SubtitleTrack? {
        let generated = project.tracks.filter { !$0.isReference }
        return generated.first { $0.id == focusedTrackID }
            ?? generated.first { project.visibleTrackIDs.contains($0.id) }
            ?? generated.first
    }

    /// One Save SRT flow for the menu, toolbar and inspector.
    @MainActor func saveSRT(_ track: SubtitleTrack? = nil) {
        guard let track = track ?? srtTrack else { return }
        if let problem = QuickSRT.save(track, projectName: project.name) { errorMessage = problem }
    }

    /// Set when the spoken language was changed after the captions were made.
    var captionLanguageMismatch: (was: String, now: String)? {
        guard let made = project.spine?.sourceLanguage, project.hasResults else { return nil }
        let code = { (tag: String) in tag.split(separator: "-").first.map(String.init)?.lowercased() ?? tag }
        guard code(made) != code(project.sourceLanguage) else { return nil }
        return (CapabilityRegistry.displayName(code(made)), CapabilityRegistry.displayName(code(project.sourceLanguage)))
    }

    /// Says exactly what "Listen Again" will replace.
    var redoWarning: String {
        let names = project.tracks.filter { !$0.isReference }.map(\.displayName)
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last!
                                   : (names.first ?? "the captions")
        let edits = project.captionsEdited ? " Your corrections are replaced too." : ""
        return "This makes new captions and replaces \(list).\(edits) Undo (⌘Z) brings the current ones back."
    }
}

import SwiftUI

/// The same caption commands everywhere you right-click a caption.
struct CaptionContextMenu: View {
    let model: AppModel
    /// The caption that was right-clicked, when the click identifies one.
    var slot: Int? = nil

    private var target: Int? { slot ?? model.targetCaptionSlot }

    var body: some View {
        Button("Split Caption") { model.splitCaptionAtPlayhead(slot: target) }
            .disabled(!model.canSplit(target))
        Button("Merge with Next") { model.mergeCaptionWithNext(slot: target) }
            .disabled(!model.canMerge(target))
        Divider()
        Button("Play from Here") {
            if let slot = target, model.project.slots.indices.contains(slot) {
                model.selectedCueSlot = slot
                model.seek(to: model.project.slots[slot].start + 0.01)
                if !model.isPlaying { model.togglePlayback() }
            }
        }
        Button("Tidy Up All Lines") { model.reflow(trackID: nil) }
    }
}
