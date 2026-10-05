import Foundation

/// Carves the timing spine into cue slots. Runs ONCE per generation; every selected
/// output track then fills these same slots, which is what makes cue timings identical
/// across tracks. PRD MULTI-02, CAP-03, CAP-08.
public struct Segmenter: Sendable {
    public let rules: CaptionRules
    public let profile: ScriptProfile

    public init(rules: CaptionRules, profile: ScriptProfile) {
        self.rules = rules; self.profile = profile
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？", "।", "؟", "۔"]
    private static let clauseEnders: Set<Character>  = [",", ";", ":", "،", "؛", "、", "，"]

    private func endsSentence(_ w: String) -> Bool {
        guard let last = w.trimmingCharacters(in: .whitespaces).last else { return false }
        return Self.sentenceEnders.contains(last)
    }
    private func endsClause(_ w: String) -> Bool {
        guard let last = w.trimmingCharacters(in: .whitespaces).last else { return false }
        return Self.clauseEnders.contains(last)
    }

    /// Unit count used for the "is this slot full" test.
    private func units(_ words: ArraySlice<TimedWord>) -> Int {
        switch profile.segmentation {
        case .wordBased:      return words.count
        case .characterBased: return words.reduce(0) { $0 + $1.text.count }
        }
    }
    private var maxUnitsPerCue: Int {
        switch profile.segmentation {
        case .wordBased:      return rules.maxWordsPerCue
        case .characterBased: return profile.maxCharsPerLine * rules.maxLinesPerCue
        }
    }

    public func segment(_ spine: TimingSpine) -> [CueSlot] {
        let words = spine.words
        guard !words.isEmpty else { return [] }

        var slots: [CueSlot] = []
        var startIdx = 0

        for i in words.indices {
            let sliceCount = units(words[startIdx...i])
            let spanDuration = words[i].end - words[startIdx].start
            let gapAhead: Double = (i + 1 < words.count) ? words[i + 1].start - words[i].end : .infinity

            let isLast = (i == words.count - 1)
            let sentenceBreak = rules.preferSentenceBoundaries && endsSentence(words[i].text)
            let pauseBreak = gapAhead >= rules.pauseBoundary
            let full = sliceCount >= maxUnitsPerCue
            let tooLong = spanDuration >= rules.maxCueDuration

            // A clause break only counts once the slot is at least half full, so we
            // don't emit a two-word cue every time there's a comma.
            let clauseBreak = endsClause(words[i].text) && sliceCount >= max(2, maxUnitsPerCue / 2)

            if isLast || sentenceBreak || pauseBreak || full || tooLong || clauseBreak {
                slots.append(CueSlot(index: slots.count,
                                     start: words[startIdx].start,
                                     end: words[i].end,
                                     wordRange: startIdx..<(i + 1),
                                     endsSentence: sentenceBreak || isLast))
                startIdx = i + 1
            }
        }

        slots = splitOverlongSlots(slots, words: words)
        slots = enforceMinimumDuration(slots, words: words, totalDuration: spine.duration)
        slots = removeOverlaps(slots)
        slots = trimTrailingSilence(slots, words: words)
        // Final guard: the cap is an invariant, so anything still over it is split
        // or clamped here rather than reaching the writer.
        slots = enforceMaximum(slots, words: words)
        slots = absorbShortSlots(slots, words: words)
        return slots.enumerated().map { idx, s in
            var s = s; s.index = idx; return s
        }
    }

    /// Give every caption at least `minWordsPerCue` words where the speech allows it.
    ///
    /// A caption that filled up one word before the end of a sentence used to leave
    /// that word ("point.") on screen by itself. A short caption first tries to join a
    /// neighbour outright; if that would run past the duration cap, it takes words from
    /// the neighbour instead, so both keep the minimum. Captions separated by a real
    /// silence are left alone: gluing a lone "Thanks." onto speech from two seconds
    /// earlier would show it before it is said.
    private func absorbShortSlots(_ input: [CueSlot], words: [TimedWord]) -> [CueSlot] {
        let minWords = rules.minWordsPerCue
        guard profile.segmentation == .wordBased, minWords > 1, input.count > 1 else { return input }
        let maxGap = max(1.0, rules.pauseBoundary * 2)
        var slots = input
        var i = 0
        var steps = 0
        while i < slots.count, steps < input.count * 4 {
            steps += 1
            // A whole short sentence ("Hello there.") reads fine on its own; only a
            // fragment of one, or a single word, is joined.
            let wholeSentence = slots[i].endsSentence && (i == 0 || slots[i - 1].endsSentence)
            let needed = wholeSentence ? 2 : minWords
            guard slots[i].wordRange.count < needed else { i += 1; continue }

            let prevGap = i > 0 ? slots[i].start - slots[i - 1].end : .infinity
            let nextGap = i + 1 < slots.count ? slots[i + 1].start - slots[i].end : .infinity
            // Keep sentences together: an orphaned sentence ending goes back to its
            // sentence, an orphaned sentence start goes forward to its own.
            var order: [Int]
            if slots[i].endsSentence { order = [i - 1, i + 1] }
            else if i > 0, slots[i - 1].endsSentence { order = [i + 1, i - 1] }
            else { order = prevGap <= nextGap ? [i - 1, i + 1] : [i + 1, i - 1] }
            order = order.filter { j in
                j >= 0 && j < slots.count && (j < i ? prevGap : nextGap) <= maxGap
            }

            // In order of preference: join within the word limit; take words from a
            // neighbour so both meet the minimum; and only then join past the limit,
            // because one caption a little long reads better than a word on its own.
            var fixed = false
            attempts: for attempt in 0..<3 {
                for j in order {
                    let a = min(i, j), b = max(i, j)
                    let range = slots[a].wordRange.lowerBound..<slots[b].wordRange.upperBound
                    let joinedDuration = slots[b].end - slots[a].start
                    let limit = attempt == 0 ? rules.maxWordsPerCue : rules.maxWordsPerCue + minWords - 1
                    if attempt != 1 {
                        guard range.count <= limit,
                              joinedDuration <= rules.maxCueDuration + 1e-6 else { continue }
                        slots.replaceSubrange(a...b, with: [CueSlot(
                            index: slots[a].index, start: slots[a].start, end: slots[b].end,
                            wordRange: range, endsSentence: slots[b].endsSentence)])
                        i = a
                        fixed = true
                        break attempts
                    }
                    guard range.count >= minWords * 2 else { continue }
                    let split = j < i ? range.upperBound - minWords : range.lowerBound + minWords
                    let first = CueSlot(index: slots[a].index, start: slots[a].start,
                                        end: words[split - 1].end,
                                        wordRange: range.lowerBound..<split, endsSentence: false)
                    let second = CueSlot(index: slots[b].index, start: words[split].start,
                                         end: slots[b].end,
                                         wordRange: split..<range.upperBound,
                                         endsSentence: slots[b].endsSentence)
                    let fits = [first, second].allSatisfy {
                        $0.duration > 0 && $0.duration <= rules.maxCueDuration + 1e-6
                    }
                    if fits, first.end <= second.start + 1e-9 {
                        slots.replaceSubrange(a...b, with: [first, second])
                        i = a + 1
                        fixed = true
                        break attempts
                    }
                }
            }
            if !fixed { i += 1 }
        }
        return slots
    }

    /// Split or clamp anything still over the cap after merging and trimming.
    /// `splitOverlongSlots` runs before the merge passes, so a merge can reintroduce
    /// an over-cap slot that nothing else would catch.
    private func enforceMaximum(_ input: [CueSlot], words: [TimedWord]) -> [CueSlot] {
        var out: [CueSlot] = []
        for slot in input {
            guard slot.duration > rules.maxCueDuration + 1e-6 else { out.append(slot); continue }

            // Prefer splitting at a word boundary.
            if slot.wordRange.count > 1 {
                let pieces = max(2, Int((slot.duration / rules.maxCueDuration).rounded(.up)))
                let per = max(1, Int((Double(slot.wordRange.count) / Double(pieces)).rounded(.up)))
                var lower = slot.wordRange.lowerBound
                var created: [CueSlot] = []
                while lower < slot.wordRange.upperBound {
                    let upper = min(lower + per, slot.wordRange.upperBound)
                    let isFirst = created.isEmpty
                    let isLast = upper == slot.wordRange.upperBound
                    created.append(CueSlot(
                        index: 0,
                        start: isFirst ? slot.start : words[lower].start,
                        end: isLast ? slot.end : words[upper - 1].end,
                        wordRange: lower..<upper,
                        endsSentence: isLast ? slot.endsSentence : false))
                    lower = upper
                }
                // Only accept the split if it actually resolved the breach.
                if created.allSatisfy({ $0.duration <= rules.maxCueDuration + 1e-6 }),
                   created.allSatisfy({ $0.duration > 0 }) {
                    out.append(contentsOf: created)
                    continue
                }
            }

            // Cannot split: clamp. Trailing time past the cap is not readable anyway.
            var clamped = slot
            clamped.end = slot.start + rules.maxCueDuration
            out.append(clamped)
        }
        return out
    }

    /// A slot that could not be split any further still must not linger. Real footage
    /// produces these constantly: sparse speech leaves a slot whose last word ends
    /// early but whose span runs on through silence, so the caption sat on screen for
    /// up to 14 seconds on a 57-minute test file.
    ///
    /// Trailing time not covered by the slot's own words is silence, so trimming it
    /// removes no speech.
    private func trimTrailingSilence(_ input: [CueSlot], words: [TimedWord]) -> [CueSlot] {
        var slots = input
        for i in slots.indices {
            guard slots[i].duration > rules.maxCueDuration + 1e-6 else { continue }
            let upper = min(words.count, slots[i].wordRange.upperBound)
            guard upper > slots[i].wordRange.lowerBound else { continue }
            let lastWordEnd = words[upper - 1].end

            let ceiling = slots[i].start + rules.maxCueDuration
            // Normally never cut before the last word ends. But a slot that cannot be
            // split — a single word, or one whose own reported range exceeds the cap —
            // has to be clamped anyway: no caption should sit on screen for 14
            // seconds because the recogniser attributed a long span to one token.
            let canSplitFurther = slots[i].wordRange.count > 1
            let floor = canSplitFurther
                ? max(lastWordEnd, slots[i].start + rules.minCueDuration)
                : slots[i].start + rules.minCueDuration
            let trimmed = max(floor, min(slots[i].end, ceiling))
            if trimmed < slots[i].end { slots[i].end = trimmed }
        }
        return slots
    }

    /// Break any slot that runs past the duration cap into equal word groups, at word
    /// boundaries so no text moves. A single long word can push a slot over the cap
    /// during the main pass, so this is a separate corrective step. PRD CAP-06.
    private func splitOverlongSlots(_ input: [CueSlot], words: [TimedWord]) -> [CueSlot] {
        var out: [CueSlot] = []
        for slot in input {
            guard slot.duration > rules.maxCueDuration + 1e-6,
                  slot.wordRange.count > 1 else { out.append(slot); continue }

            let pieces = max(2, Int((slot.duration / rules.maxCueDuration).rounded(.up)))
            let total = slot.wordRange.count
            let per = max(1, Int((Double(total) / Double(pieces)).rounded(.up)))

            // Build the ranges first, then derive times. Word timings can be
            // collapsed (recognisers do this), which would yield zero-duration
            // pieces, so fall back to an even division of the slot in that case.
            var ranges: [Range<Int>] = []
            var lower = slot.wordRange.lowerBound
            while lower < slot.wordRange.upperBound {
                let upper = min(lower + per, slot.wordRange.upperBound)
                ranges.append(lower..<upper)
                lower = upper
            }
            let evenShare = slot.duration / Double(ranges.count)
            var bounds: [(Double, Double)] = ranges.enumerated().map { k, range in
                (k == 0 ? slot.start : words[range.lowerBound].start,
                 k == ranges.count - 1 ? slot.end : words[range.upperBound - 1].end)
            }
            if bounds.contains(where: { $1 - $0 < evenShare * 0.2 })
                || zip(bounds, bounds.dropFirst()).contains(where: { $0.1 > $1.0 + 1e-9 }) {
                bounds = ranges.indices.map { k in
                    (slot.start + evenShare * Double(k),
                     k == ranges.count - 1 ? slot.end : slot.start + evenShare * Double(k + 1))
                }
            }
            for (k, range) in ranges.enumerated() {
                out.append(CueSlot(index: out.count,
                                   start: bounds[k].0,
                                   end: bounds[k].1,
                                   wordRange: range,
                                   endsSentence: k == ranges.count - 1 ? slot.endsSentence : false))
            }
        }
        return out
    }

    /// Merge or extend slots that flash too briefly. PRD CAP-05.
    private func enforceMinimumDuration(_ input: [CueSlot], words: [TimedWord],
                                        totalDuration: Double) -> [CueSlot] {
        guard !input.isEmpty else { return input }
        var slots = input
        var i = 0
        while i < slots.count {
            guard slots[i].duration < rules.minCueDuration else { i += 1; continue }

            // Prefer extending into following silence — it changes no text.
            let nextStart = (i + 1 < slots.count) ? slots[i + 1].start : totalDuration
            let room = nextStart - slots[i].end
            let needed = rules.minCueDuration - slots[i].duration
            if room >= needed {
                slots[i].end += needed
                i += 1
                continue
            }

            // Borrow from the previous slot if it can spare the time. This is the
            // common tail case: an engine collapses its last few word timestamps, so
            // the final cue is a few milliseconds long while its neighbour is long.
            // Only borrow from a CONTIGUOUS neighbour. Reaching back across silence
            // would truncate the previous caption mid-speech and show this one early.
            if i > 0, abs(slots[i - 1].end - slots[i].start) < 1e-6 {
                let previous = slots[i - 1]
                let spare = previous.duration - rules.minCueDuration
                if spare > 1e-9 {
                    let borrow = min(needed, spare)
                    slots[i - 1].end -= borrow
                    slots[i].start -= borrow
                    if slots[i].duration >= rules.minCueDuration - 1e-9 { i += 1; continue }
                }
            }

            // Otherwise merge with the neighbour that keeps us inside the duration cap.
            let mergeNext = (i + 1 < slots.count) &&
                (slots[i + 1].end - slots[i].start) <= rules.maxCueDuration
            if mergeNext {
                let merged = CueSlot(index: slots[i].index, start: slots[i].start, end: slots[i + 1].end,
                                     wordRange: slots[i].wordRange.lowerBound..<slots[i + 1].wordRange.upperBound,
                                     endsSentence: slots[i + 1].endsSentence)
                slots.replaceSubrange(i...(i + 1), with: [merged])
                continue
            }
            // Must not breach the maximum: an over-long caption sits on screen
            // visibly, while a slot that stays short is merely flagged. Earlier this
            // allowed 1.6x the cap and nothing re-split the result, which is how a
            // real 57-minute file produced a 4.12 s cue under a 4.0 s cap.
            if i > 0, (slots[i].end - slots[i - 1].start) <= rules.maxCueDuration {
                let merged = CueSlot(index: slots[i - 1].index, start: slots[i - 1].start, end: slots[i].end,
                                     wordRange: slots[i - 1].wordRange.lowerBound..<slots[i].wordRange.upperBound,
                                     endsSentence: slots[i].endsSentence)
                slots.replaceSubrange((i - 1)...i, with: [merged])
                i = max(0, i - 1)
                continue
            }
            // Cannot fix without breaking a harder rule: leave it, the validator will flag it.
            i += 1
        }
        return slots
    }

    /// Guarantee chronological, non-overlapping slots. PRD CAP-04.
    private func removeOverlaps(_ input: [CueSlot]) -> [CueSlot] {
        guard input.count > 1 else { return input }
        var slots = input.sorted { $0.start < $1.start }
        // Repeat until stable: nudging slot i+1 forward can create a fresh overlap
        // with i+2, which a single forward pass would never look at.
        var passes = 0
        let maxPasses = max(4, slots.count + 2)
        var dirty = true
        while dirty, passes < maxPasses {
            dirty = false
            passes += 1
        for i in 0..<(slots.count - 1) {
            guard slots[i].end > slots[i + 1].start else { continue }
            dirty = true
            // Clamp to the next start, but if that would collapse this slot to zero
            // duration (two slots reported the same start time, which recognisers do),
            // push the NEXT slot later instead of annihilating this one.
            let clamped = max(slots[i].start, min(slots[i + 1].start, slots[i].end))
            if clamped > slots[i].start {
                slots[i].end = clamped
            } else {
                let nudged = max(slots[i].end, slots[i].start)
                slots[i].end = nudged
                slots[i + 1].start = max(slots[i + 1].start, nudged)
                slots[i + 1].end = max(slots[i + 1].end, slots[i + 1].start)
            }
        }
        }
        return slots
    }
}
