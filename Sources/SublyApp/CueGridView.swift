import SwiftUI
import SublyCaptions

/// The caption table — the surface a user spends hours in.
///
/// A real `Table`, not a hand-rolled `HStack` grid. That buys column resizing,
/// sorting, multi-select, type-select, keyboard navigation and the correct
/// accessibility role, none of which the previous stack of `HStack`s had.
///
/// Tracks share one cue grid, so every row exists in every track. A track column
/// shows its own text and nothing else; colour appears only as a thin leading rule
/// identifying which track a column belongs to.
struct CueGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutMode) private var layout
    @State private var searchText = ""
    @State private var replaceText = ""
    @State private var showReplace = false
    @AppStorage("replaceWholeWords") private var wholeWords = true
    @FocusState private var searchFocused: Bool
    @State private var selection = Set<Int>()
    /// Caption text size in the grid. `.controlSize(.small)` sized the text for
    /// controls, not for reading, and subtitles are the thing you stare at here.
    @AppStorage("gridTextSize") private var textSize: Double = 15
    @AppStorage("gridShowsEndTime") private var showEndTime = false

    /// One row per shared cue slot.
    struct Row: Identifiable, Hashable {
        let id: Int
        let number: Int
        let start: Double
        let end: Double
        let needsReview: Bool
    }

    private var visibleTracks: [SubtitleTrack] {
        let all = model.project.tracks
        let limit = layout.maxVisibleTrackColumns
        guard all.count > limit else { return all }
        if let focused = model.focusedTrackID,
           let f = all.first(where: { $0.id == focused }) {
            return [f] + all.filter { $0.id != focused }.prefix(limit - 1)
        }
        return Array(all.prefix(limit))
    }

    private var rows: [Row] {
        let slots = model.index.slots(matching: searchText)
        var out: [Row] = []
        out.reserveCapacity(slots.count)
        for (i, slot) in slots.enumerated() {
            var start = 0.0, end = 0.0, review = false
            for track in model.project.tracks {
                if let cue = model.cue(in: track, slot: slot) {
                    start = cue.start; end = cue.end
                    if cue.needsReview { review = true }
                    break
                }
            }
            out.append(Row(id: slot, number: i + 1, start: start, end: end, needsReview: review))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
        }
        .background(.background)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { row in
                // Status lives in its own narrow column, so a flagged row does not
                // grow taller than an unflagged one.
                if row.needsReview {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.caution)
                        .help("Subly is unsure about this one — worth checking")
                        .accessibilityLabel("Needs checking")
                } else {
                    Color.clear
                }
            }
            .width(16)

            TableColumn("#") { row in
                Text("\(row.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(34)

            // One compact "Time" column by default. Two full timecodes at
            // `00:00.000` each took roughly a third of the pane and pushed the caption
            // text — the thing being read — into an ellipsis. The end time is available
            // in the inspector and on hover, and can be turned back on here.
            if layout.cueGridShowsTimecodeColumn {
                TableColumn("Time") { row in
                    Text(Format.shortTimecode(row.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(Format.timecode(row.start)) to \(Format.timecode(row.end))")
                }
                .width(min: 46, ideal: 52, max: 64)

                if showEndTime {
                    TableColumn("Hides") { row in
                        Text(Format.shortTimecode(row.end))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 46, ideal: 52, max: 64)
                }
            }

            TableColumnForEach(visibleTracks) { track in
                TableColumn(track.displayName) { row in
                    CueCell(model: model, track: track, slot: row.id, textSize: textSize)
                }
                .width(min: 160, ideal: 260)
            }
        }
        .contextMenu(forSelectionType: Int.self) { slots in
            if let slot = slots.first { CaptionContextMenu(model: model, slot: slot) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .controlSize(.small)
        .environment(\.defaultMinListRowHeight, textSize + 13)
        .onChange(of: selection) { _, new in
            guard let slot = new.first else { return }
            model.selectedCueSlot = slot
            if let track = model.project.tracks.first,
               let cue = model.cue(in: track, slot: slot) {
                model.seek(to: cue.start + 0.01)
            }
        }
        .onChange(of: model.findRequest) { _, _ in searchFocused = true }
        // ⌘F with the list hidden shows it; this list then appears after the request
        // was made, so pick the request up on arrival.
        .onAppear {
            if model.findPending { model.findPending = false; searchFocused = true }
        }
        .onChange(of: model.selectedCueSlot) { _, slot in
            if let slot, !selection.contains(slot) { selection = [slot] }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("Find in captions", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, maxWidth: 200)
                .focused($searchFocused)

            if showReplace {
                // Counted once per update; it walks every caption.
                let matches = replaceCount
                TextField("Replace with", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Toggle("Whole words", isOn: $wholeWords)
                    .toggleStyle(.checkbox)
                    .help("Only match complete words, so “ho” does not change “hota”")
                Button("Replace All") { replaceAll() }
                    .disabled(searchText.isEmpty || matches == 0)
                // Say how much will change before it changes. "Replace All" touched
                // every track, including ones not on screen, with no way to know how
                // many words it would rewrite.
                if !searchText.isEmpty {
                    Text(matches == 0
                         ? "No matches"
                         : "\(matches) match\(matches == 1 ? "" : "es") in \(editableTrackCount) track\(editableTrackCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(matches == 0 ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(Palette.caution))
                        .help("Replace All changes every track you can edit, not just the one showing.")
                }
            }

            Button {
                withAnimation(Motion.snappy) { showReplace.toggle() }
            } label: {
                Label("Find & Replace", systemImage: "text.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .help("Find and replace a word everywhere — useful for fixing a name")

            Spacer(minLength: 4)

            if model.project.tracks.count > layout.maxVisibleTrackColumns {
                Picker("Track to show", selection: Binding(
                    get: { model.focusedTrackID ?? model.project.tracks.first?.id },
                    set: { model.focusedTrackID = $0 })) {
                    ForEach(model.project.tracks) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .help("Choose which track to show")
            }

            Menu {
                Picker("Caption text size", selection: $textSize) {
                    Text("Small").tag(13.0)
                    Text("Medium").tag(15.0)
                    Text("Large").tag(18.0)
                    Text("Extra Large").tag(22.0)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Show end times", isOn: $showEndTime)
            } label: {
                Label("View", systemImage: "textformat.size").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How big the caption text is in this list")

            Text("\(rows.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .help("\(rows.count) caption\(rows.count == 1 ? "" : "s")")
                .accessibilityLabel("\(rows.count) captions")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Tracks that `replaceAll()` would actually touch.
    private var editableTracks: [SubtitleTrack] {
        model.project.tracks.filter { !$0.isReference }
    }
    private var editableTrackCount: Int { editableTracks.count }

    /// How many occurrences `replaceAll()` would rewrite, counted the same way it
    /// rewrites them so the number cannot disagree with the action.
    private var replaceCount: Int {
        guard let regex = TextReplace.pattern(for: searchText, wholeWords: wholeWords) else { return 0 }
        var total = 0
        for track in editableTracks {
            for cue in track.cues {
                for line in cue.lines { total += TextReplace.count(in: line, regex) }
            }
        }
        return total
    }

    private func replaceAll() {
        guard let regex = TextReplace.pattern(for: searchText, wholeWords: wholeWords) else { return }
        model.pushUndo("Replace All")
        for t in model.project.tracks.indices where !model.project.tracks[t].isReference {
            for c in model.project.tracks[t].cues.indices {
                model.project.tracks[t].cues[c].lines = model.project.tracks[t].cues[c].lines.map {
                    TextReplace.replace(in: $0, regex, with: replaceText)
                }
            }
        }
        model.rebuildIndex()
        model.scheduleAutosave()
    }
}

/// One track's text for one row. Colour appears as a thin leading rule and nowhere
/// else — the cell background stays neutral so the text keeps full contrast.
private struct CueCell: View {
    /// Passed in, not read from the environment. `Table` is `NSTableView`-backed and
    /// AppKit hosts each cell in its own `NSHostingView`; when `TableColumnForEach`
    /// changes the column set at a layout breakpoint those cells are torn down and
    /// rebuilt, and a rebuilt cell could be evaluated before the environment was
    /// re-propagated — trapping on a missing `AppModel`.
    let model: AppModel
    let track: SubtitleTrack
    let slot: Int
    let textSize: Double
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var cue: Cue? { model.cue(in: track, slot: slot) }

    private var profile: ScriptProfile {
        ScriptProfile.forLanguage(track.kind == .original && !track.isReference
                                  ? model.project.sourceLanguage : track.languageTag)
    }

    var body: some View {
        guard let cue else { return AnyView(Color.clear) }
        return AnyView(
            HStack(spacing: 6) {
                Rectangle()
                    .fill(model.project.color(for: track.id))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)

                if track.isReference {
                    Text(cue.lines.joined(separator: " "))
                        .font(.system(size: textSize))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                } else {
                    TextField("\(track.displayName) caption", text: Binding(
                        get: { focused ? draft : shown(cue) },
                        set: { draft = $0 }))
                    .font(.system(size: textSize))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .lineLimit(1)
                    .environment(\.layoutDirection,
                                 profile.isRightToLeft ? .rightToLeft : .leftToRight)
                    .onChange(of: focused) { _, isFocused in
                        if isFocused { draft = shown(cue) }
                        else { commit(cue) }
                    }
                    .onSubmit { commit(cue) }
                }

                if overLimit(cue) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.caution)
                        .help(limitHelp(cue))
                }
            }
        )
    }

    private func overLimit(_ cue: Cue) -> Bool {
        let rules = model.project.rules.adjusted(for: profile)
        for line in cue.lines {
            if profile.segmentation == .wordBased,
               line.split(separator: " ").count > rules.maxWordsPerLine { return true }
            if line.count > rules.maxCharsPerLine { return true }
        }
        return false
    }

    private func limitHelp(_ cue: Cue) -> String {
        let rules = model.project.rules.adjusted(for: profile)
        return "This is longer than your caption style allows (\(rules.maxWordsPerLine) words a line). Use “Tidy lines”, or shorten it."
    }

    /// The caption on one line, joined the way its script is written: Japanese and
    /// Chinese have no spaces, and joining with one put a space into the caption.
    private func shown(_ cue: Cue) -> String {
        cue.lines.joined(separator: profile.segmentation == .characterBased ? "" : " ")
    }

    private func commit(_ cue: Cue) {
        // Unchanged text is left exactly as it was: clicking in and out of a caption
        // used to re-break it, mark it edited and add an undo step.
        guard draft != shown(cue) else { return }
        // The table shows one line per cell; re-break within the line limit, keeping
        // the number of lines a caption may have.
        let rules = model.project.rules.adjusted(for: profile)
        let formatter = CaptionFormatter(rules: rules, profile: profile)
        let text = profile.segmentation == .characterBased
            ? draft : draft.split(separator: " ").joined(separator: " ")
        var edited = cue
        edited.lines = [text]
        let lines = formatter.reflow([edited]).first?.lines ?? [text]
        guard lines != cue.lines else { return }
        model.updateCueText(trackID: track.id, cueID: cue.id, lines: lines)
    }
}
