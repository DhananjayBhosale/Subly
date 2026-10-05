import Foundation

/// Splitting and merging captions. Every generated track shares one cue grid, so an
/// edit to the grid has to be applied to every track at once or their timings drift
/// apart — which is the one thing this app promises never happens.
public enum CaptionEdits {

    public enum EditError: LocalizedError, Equatable {
        case noNextCaption
        case tooCloseToEdge
        case tooShortToSplit(trackName: String)

        public var errorDescription: String? {
            switch self {
            case .noNextCaption:
                return "This is the last caption, so there is nothing to merge it with."
            case .tooCloseToEdge:
                return "Move the playhead further inside the caption to split it."
            case .tooShortToSplit(let name):
                return "The \(name) caption here is a single word, so it can't be split."
            }
        }
    }

    public struct Result: Sendable {
        public var slots: [CueSlot]
        public var tracks: [SubtitleTrack]
    }

    /// Join caption `slot` with the one after it, in every generated track.
    public static func merge(slot index: Int, slots: [CueSlot],
                             tracks: [SubtitleTrack]) throws -> Result {
        guard slots.indices.contains(index), slots.indices.contains(index + 1) else {
            throw EditError.noNextCaption
        }
        let a = slots[index], b = slots[index + 1]
        var newSlots = slots
        newSlots.replaceSubrange(index...(index + 1), with: [CueSlot(
            index: index, start: a.start, end: b.end,
            wordRange: a.wordRange.lowerBound..<max(a.wordRange.upperBound, b.wordRange.upperBound),
            endsSentence: b.endsSentence)])

        let newTracks = tracks.map { track -> SubtitleTrack in
            guard !track.isReference else { return track }
            var track = track
            let joiner = Self.joiner(for: track)
            let first = track.cues.firstIndex { $0.slotIndex == index }
            let second = track.cues.firstIndex { $0.slotIndex == index + 1 }
            switch (first, second) {
            case let (f?, s?):
                var merged = track.cues[f]
                let text = [track.cues[f].lines.joined(separator: joiner),
                            track.cues[s].lines.joined(separator: joiner)]
                    .filter { !$0.isEmpty }.joined(separator: joiner)
                merged.lines = [text]
                merged.end = b.end
                merged.needsReview = track.cues[f].needsReview || track.cues[s].needsReview
                track.cues[f] = merged
                track.cues.remove(at: s)
            case let (f?, nil):
                track.cues[f].end = b.end
            case let (nil, s?):
                track.cues[s].start = a.start
                track.cues[s].slotIndex = index
            default:
                break
            }
            for k in track.cues.indices where track.cues[k].slotIndex > index + 1 {
                track.cues[k].slotIndex -= 1
            }
            return track
        }
        return Result(slots: renumber(newSlots), tracks: newTracks)
    }

    /// Cut caption `slot` in two at `time`, in every generated track. Each track's text
    /// is divided in proportion to where the cut falls; the spine words follow the
    /// audio, so a later re-cut still knows which words belong where.
    public static func split(slot index: Int, at time: Double, slots: [CueSlot],
                             tracks: [SubtitleTrack], words: [TimedWord]) throws -> Result {
        guard slots.indices.contains(index) else { throw EditError.tooCloseToEdge }
        let slot = slots[index]
        let margin = 0.2
        guard time > slot.start + margin, time < slot.end - margin else {
            throw EditError.tooCloseToEdge
        }
        let fraction = (time - slot.start) / slot.duration

        let range = slot.wordRange
        // One timed word can't be shared between two captions: splitting 東京 left the
        // first half with no time of its own.
        guard range.count >= 2 else {
            throw EditError.tooShortToSplit(trackName: tracks.first { !$0.isReference }?.displayName ?? "This")
        }
        var cutWord = range.lowerBound
        if range.count >= 2 {
            let firstAfter = range.first { $0 < words.count && words[$0].start >= time } ?? range.upperBound
            cutWord = min(range.upperBound - 1, max(range.lowerBound + 1, firstAfter))
        }
        let spoken = range.allSatisfy { $0 < words.count } ? range.map { words[$0].text } : []

        // Divide every track's text first, so a refusal leaves nothing half-done.
        var pieces: [UUID: (String, String)] = [:]
        for track in tracks where !track.isReference {
            guard let cue = track.cues.first(where: { $0.slotIndex == index }) else { continue }
            let joiner = Self.joiner(for: track)
            let text = cue.lines.joined(separator: joiner)
            let units: [String] = joiner.isEmpty ? text.map(String.init)
                                                 : text.split(separator: " ").map(String.init)
            guard units.count >= 2 else {
                if units.isEmpty { pieces[track.id] = ("", ""); continue }
                throw EditError.tooShortToSplit(trackName: track.displayName)
            }
            // Text still exactly as heard is cut at the same word as the timing, so no
            // word lands in the half where it isn't spoken. Edited text and
            // translations are divided in proportion to where the cut falls.
            var cut = min(units.count - 1, max(1, Int((Double(units.count) * fraction).rounded())))
            // A word respelled one for one ("yah" → "ye") still lines up with what was
            // heard, so it is cut at the timing word too; reworded text and
            // translations are not.
            let sameWords = spoken.joined(separator: joiner) == text
                || (!joiner.isEmpty && track.kind == .romanized && spoken.count == units.count)
            if !spoken.isEmpty, sameWords, range.count >= 2 {
                let before = spoken[..<(cutWord - range.lowerBound)]
                let atUnit = joiner.isEmpty ? before.reduce(0) { $0 + $1.count } : before.count
                cut = min(units.count - 1, max(1, atUnit))
            }
            pieces[track.id] = (units[..<cut].joined(separator: joiner),
                                units[cut...].joined(separator: joiner))
        }
        var newSlots = slots
        newSlots.replaceSubrange(index...index, with: [
            CueSlot(index: index, start: slot.start, end: time,
                    wordRange: range.lowerBound..<cutWord, endsSentence: false),
            CueSlot(index: index + 1, start: time, end: slot.end,
                    wordRange: cutWord..<range.upperBound, endsSentence: slot.endsSentence),
        ])

        let newTracks = tracks.map { track -> SubtitleTrack in
            guard !track.isReference else { return track }
            var track = track
            for k in track.cues.indices where track.cues[k].slotIndex > index {
                track.cues[k].slotIndex += 1
            }
            if let at = track.cues.firstIndex(where: { $0.slotIndex == index }),
               let (left, right) = pieces[track.id] {
                var first = track.cues[at]
                first.end = time
                first.lines = [left]
                var second = track.cues[at]
                second.id = UUID()
                second.slotIndex = index + 1
                second.start = time
                second.lines = [right]
                track.cues.replaceSubrange(at...at, with: [first, second])
            }
            return track
        }
        return Result(slots: renumber(newSlots), tracks: newTracks)
    }

    public struct ShiftResult: Sendable {
        public var words: [TimedWord]
        public var slots: [CueSlot]
        public var tracks: [SubtitleTrack]
        /// The shift actually made, after keeping every caption on screen.
        public var applied: Double
    }

    /// Move every caption earlier (negative `delta`) or later, in seconds: the spoken
    /// words, the cue grid and every generated track together, so they stay in step
    /// and a later re-cut still fits. Times stop at 0 and at `mediaDuration`; the
    /// shift is limited so no caption is squeezed to under 0.1 s at either end.
    /// Imported reference tracks keep their own timing.
    public static func shift(by delta: Double, words: [TimedWord], slots: [CueSlot],
                             tracks: [SubtitleTrack], mediaDuration: Double? = nil) -> ShiftResult {
        let minLength = 0.1
        let limit = (mediaDuration ?? 0) > 0 ? mediaDuration! : Double.infinity
        let cues = tracks.filter { !$0.isReference }.flatMap(\.cues)
        let ends = slots.map(\.end) + cues.map(\.end)
        let starts = slots.map(\.start) + cues.map(\.start)
        let lower = min(0, minLength - (ends.min() ?? 0))
        let upper = max(0, limit - (starts.max() ?? 0) - minLength)
        let applied = min(max(delta, lower), upper)
        guard applied != 0 else {
            return ShiftResult(words: words, slots: slots, tracks: tracks, applied: 0)
        }
        func move(_ start: Double, _ end: Double) -> (Double, Double) {
            let s = min(limit, max(0, start + applied))
            return (s, max(s, min(limit, max(0, end + applied))))
        }
        let newWords = words.map { w -> TimedWord in
            var w = w
            (w.start, w.end) = move(w.start, w.end)
            return w
        }
        let newSlots = slots.map { s -> CueSlot in
            var s = s
            (s.start, s.end) = move(s.start, s.end)
            return s
        }
        let newTracks = tracks.map { track -> SubtitleTrack in
            guard !track.isReference else { return track }
            var track = track
            for c in track.cues.indices {
                (track.cues[c].start, track.cues[c].end) = move(track.cues[c].start, track.cues[c].end)
            }
            return track
        }
        return ShiftResult(words: newWords, slots: newSlots, tracks: newTracks, applied: applied)
    }

    /// After a manual edit every slot stands alone: its own parent, no siblings. The
    /// parent bookkeeping exists for the generator's subdivision step, and stale
    /// values would make a track added later group text under the wrong caption.
    static func renumber(_ slots: [CueSlot]) -> [CueSlot] {
        slots.enumerated().map { i, s in
            var s = s
            s.index = i; s.parentIndex = i; s.subIndex = 0; s.subCount = 1
            return s
        }
    }

    /// The full tag, script subtag included: "ja-Latn" is spaced words, not Japanese.
    static func joiner(for track: SubtitleTrack) -> String {
        ScriptProfile.forLanguage(track.languageTag).segmentation == .characterBased ? "" : " "
    }
}
