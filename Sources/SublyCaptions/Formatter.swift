import Foundation

/// Turns per-slot text into line-broken cues that obey the caption rules.
/// Deterministic: same input always gives the same output.
public struct CaptionFormatter: Sendable {
    public let rules: CaptionRules
    public let profile: ScriptProfile

    public init(rules: CaptionRules, profile: ScriptProfile) {
        self.rules = rules; self.profile = profile
    }

    // MARK: - Line breaking

    /// Break one string into at most `maxLinesPerCue` lines honouring the word and
    /// character limits. Returns nil-free output; overflow is handled by the caller.
    public func breakIntoLines(_ text: String) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        switch profile.segmentation {
        case .wordBased:      return breakWordBased(clean)
        case .characterBased: return breakCharacterBased(clean)
        }
    }

    private func breakWordBased(_ text: String) -> [String] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var lines: [String] = []
        var current: [String] = []

        func currentWidth(_ extra: String?) -> Int {
            var parts = current
            if let extra { parts.append(extra) }
            return parts.joined(separator: " ").count
        }

        for token in tokens {
            let wouldExceedWords = current.count + 1 > rules.maxWordsPerLine
            let wouldExceedChars = currentWidth(token) > rules.maxCharsPerLine
            if !current.isEmpty && (wouldExceedWords || wouldExceedChars) {
                lines.append(current.joined(separator: " "))
                current = [token]
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { lines.append(current.joined(separator: " ")) }

        // Balance a 2-line cue so the first line isn't dramatically longer.
        if lines.count == 2 { lines = balance(lines) }
        return lines
    }

    /// For scripts without inter-word spaces, break on grapheme count.
    private func breakCharacterBased(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for ch in text {
            if current.count + 1 > profile.maxCharsPerLine, !current.isEmpty {
                lines.append(current); current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Split text into exactly `count` lines of roughly equal length, preserving all
    /// of it. Used only as an overflow fallback.
    static func pack(_ text: String, into count: Int, characterBased: Bool) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 1, !clean.isEmpty else { return [clean] }
        if characterBased {
            let chars = Array(clean)
            let per = Int(ceil(Double(chars.count) / Double(count)))
            var out: [String] = []
            var i = 0
            while i < chars.count, out.count < count {
                let j = out.count == count - 1 ? chars.count : min(i + per, chars.count)
                out.append(String(chars[i..<j]))
                i = j
            }
            return out
        }
        let tokens = clean.split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return [clean] }
        let per = Int(ceil(Double(tokens.count) / Double(count)))
        var out: [String] = []
        var i = 0
        while i < tokens.count, out.count < count {
            let j = out.count == count - 1 ? tokens.count : min(i + per, tokens.count)
            out.append(tokens[i..<j].joined(separator: " "))
            i = j
        }
        return out
    }

    /// Prefer a slightly shorter first line — standard subtitle practice.
    private func balance(_ lines: [String]) -> [String] {
        guard lines.count == 2 else { return lines }
        let all = (lines[0] + " " + lines[1])
            .split(separator: " ").map(String.init)
        guard all.count >= 2 else { return lines }
        var best = lines
        var bestScore = Int.max
        for split in 1..<all.count {
            let a = all[0..<split].joined(separator: " ")
            let b = all[split...].joined(separator: " ")
            guard all[0..<split].count <= rules.maxWordsPerLine,
                  all[split...].count <= rules.maxWordsPerLine,
                  a.count <= rules.maxCharsPerLine,
                  b.count <= rules.maxCharsPerLine else { continue }
            // Penalise imbalance, and mildly penalise a longer first line.
            let score = abs(a.count - b.count) + (a.count > b.count ? 1 : 0)
            if score < bestScore { bestScore = score; best = [a, b] }
        }
        return best
    }

    // MARK: - Slot filling

    /// How many cues this text needs in one slot, given the line budget.
    public func requiredCueCount(for text: String) -> Int {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 1 }
        let lines = breakIntoLines(clean)
        return max(1, Int(ceil(Double(lines.count) / Double(rules.maxLinesPerCue))))
    }

    /// Additionally demand a split where the text could not be read in the time
    /// available, which is how the reading-rate limit gets enforced rather than
    /// merely reported.
    public func requiredCueCount(for text: String, duration: Double) -> Int {
        let byLines = requiredCueCount(for: text)
        guard duration > 0, rules.maxReadingRate > 0 else { return byLines }
        let chars = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).count)
        let affordable = rules.maxReadingRate * duration
        guard affordable > 0 else { return byLines }
        let byRate = Int(ceil(chars / affordable))
        // Never demand a split so fine that the pieces fall under the minimum duration.
        let maxByDuration = max(1, Int(duration / max(0.01, rules.minCueDuration)))
        return min(max(byLines, byRate), maxByDuration)
    }

    /// Subdivide slots so that EVERY track fits the same cue grid.
    ///
    /// This is what makes "identical timings across tracks" true rather than
    /// aspirational: instead of each track splitting its own slots (which desynced
    /// them), the slot itself is divided once, using the largest demand across all
    /// tracks, and every track then fills the same sub-slots.
    /// `fillable[slotIndex]` caps the subdivision at what every track can fill with
    /// real text, so no track is left holding a blank cue.
    public static func unify(slots: [CueSlot], demands: [[Int: Int]],
                             words: [TimedWord],
                             minCueDuration: Double = 0,
                             fillable: [Int: Int] = [:],
                             minWordsPerPiece: Int = 1) -> [CueSlot] {
        var out: [CueSlot] = []
        let minWords = max(1, minWordsPerPiece)
        for slot in slots {
            let needed = max(1, demands.compactMap { $0[slot.index] }.max() ?? 1)
            let available = max(1, slot.wordRange.count)
            let cap = fillable[slot.index] ?? Int.max
            // Never cut a caption into pieces smaller than the minimum word count —
            // a 7-word caption split three ways used to leave a single word alone.
            let pieces = min(needed, max(1, available / minWords),
                             max(1, cap == Int.max ? cap : cap / minWords))

            if pieces <= 1 {
                var s = slot
                s.index = out.count; s.parentIndex = slot.index
                s.subIndex = 0; s.subCount = 1
                out.append(s)
                continue
            }

            // Divide at word boundaries so no text is cut mid-word, as evenly as
            // `distribute` divides the text: 7 words over 3 is 3·2·2, not 3·3·1, so
            // each piece's timing matches the words it shows.
            let base = available / pieces, remainder = available % pieces
            var ranges: [Range<Int>] = []
            var lower = slot.wordRange.lowerBound
            for k in 0..<pieces {
                let upper = min(lower + base + (k < remainder ? 1 : 0), slot.wordRange.upperBound)
                guard upper > lower else { break }
                ranges.append(lower..<upper)
                lower = upper
            }

            // Prefer real word timings, but fall back to an even division of the
            // slot when they are degenerate. Recognisers do collapse several word
            // timestamps onto one value (whisper.cpp does it at the tail of a clip),
            // and using them directly reintroduces the flashing cue that the
            // segmenter's minimum-duration pass had already fixed.
            let evenShare = slot.duration / Double(ranges.count)
            var boundaries: [(start: Double, end: Double)] = []
            for (k, range) in ranges.enumerated() {
                let isFirst = k == 0
                let isLast = k == ranges.count - 1
                boundaries.append((start: isFirst ? slot.start : words[range.lowerBound].start,
                                   end: isLast ? slot.end : words[range.upperBound - 1].end))
            }
            let degenerate = boundaries.contains { ($0.end - $0.start) < evenShare * 0.35 }
                || zip(boundaries, boundaries.dropFirst()).contains { $0.end > $1.start + 1e-9 }
            if degenerate {
                boundaries = ranges.indices.map { k in
                    (start: slot.start + evenShare * Double(k),
                     end: k == ranges.count - 1 ? slot.end : slot.start + evenShare * Double(k + 1))
                }
            }

            var created: [CueSlot] = []
            for (k, range) in ranges.enumerated() {
                created.append(CueSlot(
                    index: 0,
                    start: boundaries[k].start,
                    end: boundaries[k].end,
                    wordRange: range,
                    endsSentence: k == ranges.count - 1 ? slot.endsSentence : false,
                    parentIndex: slot.index,
                    subIndex: k,
                    subCount: 0))
            }
            for i in created.indices {
                created[i].index = out.count + i
                created[i].subCount = created.count
            }
            out.append(contentsOf: created)
        }
        // The unified grid is the FINAL grid every track shares, so the minimum
        // duration has to hold here — subdividing a slot can push a piece under it
        // even when the pre-unification grid was fine.
        return minCueDuration > 0
            ? enforceMinimum(out, minimum: minCueDuration)
            : out
    }

    /// Merge neighbours inside the same parent slot until nothing flashes. Merging is
    /// confined to siblings so cue boundaries never cross a spine slot.
    static func enforceMinimum(_ input: [CueSlot], minimum: Double) -> [CueSlot] {
        guard input.count > 1 else {
            // A single slot shorter than the minimum is the media's own fault;
            // there is nothing to merge with.
            return input
        }
        var slots = input
        var changed = true
        // Hard iteration bound. Each pass either merges (shrinking the array) or moves
        // a boundary; the bound guarantees termination even if a future edit
        // reintroduces a no-op "change".
        var guardCount = 0
        let maxPasses = max(8, input.count * 2)
        while changed, guardCount < maxPasses {
            guardCount += 1
            changed = false
            var i = 0
            while i < slots.count {
                guard slots[i].duration + 1e-9 < minimum else { i += 1; continue }

                // Prefer a sibling of the same parent.
                let mergeWithNext = i + 1 < slots.count
                    && slots[i + 1].parentIndex == slots[i].parentIndex
                let mergeWithPrevious = i > 0
                    && slots[i - 1].parentIndex == slots[i].parentIndex

                if mergeWithNext {
                    let a = slots[i], b = slots[i + 1]
                    slots.replaceSubrange(i...(i + 1), with: [CueSlot(
                        index: a.index, start: a.start, end: b.end,
                        wordRange: a.wordRange.lowerBound..<b.wordRange.upperBound,
                        endsSentence: b.endsSentence, parentIndex: a.parentIndex,
                        subIndex: a.subIndex, subCount: max(1, a.subCount - 1))])
                    changed = true
                    // Re-check the merged slot: it may still be under the minimum and
                    // have another sibling to absorb.
                    continue
                } else if mergeWithPrevious {
                    let a = slots[i - 1], b = slots[i]
                    slots.replaceSubrange((i - 1)...i, with: [CueSlot(
                        index: a.index, start: a.start, end: b.end,
                        wordRange: a.wordRange.lowerBound..<b.wordRange.upperBound,
                        endsSentence: b.endsSentence, parentIndex: a.parentIndex,
                        subIndex: a.subIndex, subCount: max(1, a.subCount - 1))])
                    changed = true
                    i = max(0, i - 1)
                    continue
                } else if i > 0,
                          abs(slots[i - 1].end - slots[i].start) < 1e-6 {
                    // No sibling: borrow from the previous slot, but ONLY when the two
                    // are contiguous. Borrowing across a silence would cut the previous
                    // caption off mid-speech and show this one before anyone speaks.
                    let spare = slots[i - 1].duration - minimum
                    if spare > 1e-9 {
                        let borrow = min(minimum - slots[i].duration, spare)
                        let previousEnd = slots[i - 1].end
                        let currentStart = slots[i].start
                        slots[i - 1].end -= borrow
                        slots[i].start -= borrow
                        // Only claim progress if the values actually moved. Below one
                        // ULP the subtraction is a no-op and `changed = true` would
                        // spin this loop forever.
                        if slots[i - 1].end != previousEnd || slots[i].start != currentStart {
                            changed = true
                        }
                    }
                }
                i += 1
            }
        }
        // Renumber and normalise sub-counts after merging.
        var perParent: [Int: Int] = [:]
        for slot in slots { perParent[slot.parentIndex, default: 0] += 1 }
        var seen: [Int: Int] = [:]
        for i in slots.indices {
            slots[i].index = i
            let parent = slots[i].parentIndex
            slots[i].subIndex = seen[parent, default: 0]
            slots[i].subCount = perParent[parent] ?? 1
            seen[parent, default: 0] += 1
        }
        return slots
    }

    /// Split one slot's text across `subCount` sub-slots by word count, so a track
    /// with more words spreads across the same grid the other tracks use.
    public func distribute(_ text: String, across subCount: Int) -> [String] {
        guard subCount > 1 else { return [text] }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Array(repeating: "", count: subCount) }

        switch profile.segmentation {
        case .wordBased:
            let tokens = clean.split(separator: " ").map(String.init)
            guard tokens.count > 1 else {
                return [clean] + Array(repeating: "", count: subCount - 1)
            }
            // Spread as evenly as possible, giving earlier groups the remainder. With
            // fewer tokens than sub-slots every group gets exactly one and the tail
            // groups are empty — which is correct: this track has nothing to say
            // there, and the shared grid must not change shape for one track.
            let base = tokens.count / subCount
            let remainder = tokens.count % subCount
            var groups: [String] = []
            var i = 0
            for g in 0..<subCount {
                let take = base + (g < remainder ? 1 : 0)
                guard take > 0 else { groups.append(""); continue }
                let j = min(i + take, tokens.count)
                groups.append(tokens[i..<j].joined(separator: " "))
                i = j
            }
            while groups.count < subCount { groups.append("") }
            return groups
        case .characterBased:
            let chars = Array(clean)
            let base = chars.count / subCount
            let remainder = chars.count % subCount
            var groups: [String] = []
            var i = 0
            for g in 0..<subCount {
                let take = base + (g < remainder ? 1 : 0)
                guard take > 0 else { groups.append(""); continue }
                let j = min(i + take, chars.count)
                groups.append(String(chars[i..<j]))
                i = j
            }
            while groups.count < subCount { groups.append("") }
            return groups
        }
    }

    /// Fill unified slots. `texts` is keyed by PARENT slot index; each parent's text
    /// is distributed across its sub-slots. Produces exactly one cue per slot, so
    /// every track has the same cue count and the same timings.
    ///
    /// **Contract:** `slots` MUST come from `unify(slots:demands:words:minCueDuration:)`,
    /// computed from the demands of *every* track that will be filled. Passing raw
    /// segmenter slots, or slots unified for a different set of tracks, silently
    /// breaks the cross-track identical-timing guarantee — the whole point of the
    /// two-phase design. `fill` never adds or removes cues, so the caller's grid is
    /// the grid every track gets.
    public func fill(slots: [CueSlot], texts: [Int: String]) -> [Cue] {
        var cues: [Cue] = []
        var distributedCache: [Int: [String]] = [:]

        for slot in slots {
            let parentText = (texts[slot.parentIndex] ?? texts[slot.index] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let piece: String
            if slot.subCount <= 1 {
                piece = parentText
            } else {
                if distributedCache[slot.parentIndex] == nil {
                    distributedCache[slot.parentIndex] =
                        distribute(parentText, across: slot.subCount)
                }
                let parts = distributedCache[slot.parentIndex] ?? []
                piece = slot.subIndex < parts.count ? parts[slot.subIndex] : ""
            }

            var lines = breakIntoLines(piece)
            // The slot is normally subdivided enough to fit. When the minimum-duration
            // rule prevented that, text is never dropped — it is packed into the
            // allowed number of lines as evenly as possible, and the validator flags
            // the over-length lines. Dumping the whole remainder into the last line
            // would produce one extreme line instead of two slightly long ones.
            if lines.count > rules.maxLinesPerCue {
                lines = Self.pack(piece, into: rules.maxLinesPerCue,
                                  characterBased: profile.segmentation == .characterBased)
            }
            cues.append(Cue(slotIndex: slot.index, start: slot.start,
                            end: slot.end, lines: lines))
        }
        return cues
    }

    // MARK: - Reflow

    /// Reapply formatting rules without changing the spoken words.
    public func reflow(_ cues: [Cue]) -> [Cue] {
        var out: [Cue] = []
        // Character-based scripts have no inter-word spaces; joining with one would
        // permanently insert whitespace into the text.
        let joiner = profile.segmentation == .characterBased ? "" : " "
        for cue in cues {
            let joined = cue.lines.joined(separator: joiner)
            guard !joined.trimmingCharacters(in: .whitespaces).isEmpty else { out.append(cue); continue }
            let lines = breakIntoLines(joined)
            if lines.count <= rules.maxLinesPerCue {
                var c = cue; c.lines = lines; out.append(c)
            } else {
                // Reflow must not invent cues, which would desync tracks. Keep the
                // words in the allowed number of lines and let the validator flag
                // the over-long line.
                var c = cue
                c.lines = Array(lines.prefix(rules.maxLinesPerCue - 1))
                    + [lines.dropFirst(rules.maxLinesPerCue - 1).joined(separator: joiner)]
                out.append(c)
            }
        }
        assert(out.count == cues.count, "reflow must preserve cue count")
        return out
    }

    // MARK: - Validation

    /// Report issues rather than silently mutating the user's text.
    public func validate(_ cues: [Cue]) -> [CueDiagnostic] {
        var out: [CueDiagnostic] = []
        for (i, cue) in cues.enumerated() {
            if cue.lines.isEmpty || cue.text.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(CueDiagnostic(cueID: cue.id, issue: .empty))
            }
            for line in cue.lines {
                if profile.segmentation == .wordBased {
                    let n = line.split(separator: " ").count
                    if n > rules.maxWordsPerLine {
                        out.append(CueDiagnostic(cueID: cue.id, issue: .overWordLimit)); break
                    }
                }
            }
            if cue.lines.contains(where: { $0.count > rules.maxCharsPerLine }) {
                out.append(CueDiagnostic(cueID: cue.id, issue: .overCharLimit))
            }
            if cue.duration + 1e-6 < rules.minCueDuration {
                out.append(CueDiagnostic(cueID: cue.id, issue: .tooShort))
            }
            if cue.duration > rules.maxCueDuration + 1e-6 {
                out.append(CueDiagnostic(cueID: cue.id, issue: .tooLong))
            }
            if cue.readingRate > rules.maxReadingRate, cue.characterCount > 0 {
                out.append(CueDiagnostic(cueID: cue.id, issue: .overReadingRate))
            }
            if i + 1 < cues.count, cue.end > cues[i + 1].start + 1e-6 {
                out.append(CueDiagnostic(cueID: cue.id, issue: .overlap))
            }
            if cue.needsReview {
                out.append(CueDiagnostic(cueID: cue.id, issue: .lowConfidence))
            }
        }
        return out
    }
}
