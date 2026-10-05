import Testing
import Foundation
@testable import SublyCaptions

/// `TrackIndex`/`ProjectIndex` are what made the editor usable — search dropped from
/// ~70 ms to 0.65 ms per redraw, active-cue lookup from a linear scan to a binary
/// search. None of it had a single test, so a regression in the app's headline
/// performance fix would have passed `swift test` silently.
@Suite("Track and project index")
struct IndexTests {

    private func formatter() -> CaptionFormatter {
        CaptionFormatter(rules: CaptionRules(), profile: .latin)
    }

    private func track(_ name: String, _ texts: [(Int, Double, Double, String)],
                       kind: OutputKind = .original) -> SubtitleTrack {
        SubtitleTrack(
            kind: kind, languageTag: "en", displayName: name,
            cues: texts.map { Cue(slotIndex: $0.0, start: $0.1, end: $0.2, lines: [$0.3]) },
            engineID: "test")
    }

    // MARK: Binary search

    @Test("Cue position is found for any time inside a cue")
    func positionInsideEachCue() {
        let t = track("A", [(0, 0, 1, "one"), (1, 1, 2, "two"), (2, 2, 3, "three")])
        let index = TrackIndex(track: t, formatter: formatter())
        #expect(index.cuePosition(at: 0.0) == 0)
        #expect(index.cuePosition(at: 0.99) == 0)
        #expect(index.cuePosition(at: 1.0) == 1)
        #expect(index.cuePosition(at: 2.5) == 2)
    }

    @Test("Time outside every cue returns no position")
    func positionOutsideCues() {
        let t = track("A", [(0, 1, 2, "only")])
        let index = TrackIndex(track: t, formatter: formatter())
        #expect(index.cuePosition(at: 0.5) == nil)
        #expect(index.cuePosition(at: 2.5) == nil)
    }

    @Test("Binary search agrees with a linear scan at every sampled time")
    func agreesWithLinearScan() {
        // The optimisation is only safe if it is indistinguishable from the obvious
        // implementation it replaced.
        var cues: [(Int, Double, Double, String)] = []
        for i in 0..<400 {
            let start = Double(i) * 2.0
            cues.append((i, start, start + 1.5, "line \(i)"))
        }
        let t = track("A", cues)
        let index = TrackIndex(track: t, formatter: formatter())
        for step in 0..<1600 {
            let time = Double(step) * 0.5
            let linear = t.cues.firstIndex { time >= $0.start && time < $0.end }
            #expect(index.cuePosition(at: time) == linear, "mismatch at t=\(time)")
        }
    }

    // MARK: Slot lookup

    @Test("Every slot maps back to its cue position")
    func slotPositions() {
        let t = track("A", [(0, 0, 1, "a"), (5, 1, 2, "b"), (9, 2, 3, "c")])
        let index = TrackIndex(track: t, formatter: formatter())
        #expect(index.position(forSlot: 0) == 0)
        #expect(index.position(forSlot: 5) == 1)
        #expect(index.position(forSlot: 9) == 2)
        #expect(index.position(forSlot: 3) == nil)
    }

    // MARK: Search

    @Test("Search is case-insensitive and matches substrings")
    func searchCaseInsensitive() {
        let t = track("A", [(0, 0, 1, "Hello World"), (1, 1, 2, "goodbye")])
        let index = TrackIndex(track: t, formatter: formatter())
        #expect(index.matches(slot: 0, lowercasedNeedle: "hello"))
        #expect(index.matches(slot: 0, lowercasedNeedle: "o wor"))
        #expect(!index.matches(slot: 0, lowercasedNeedle: "goodbye"))
        #expect(index.matches(slot: 1, lowercasedNeedle: "goodbye"))
    }

    @Test("A slot holding several cues matches text in any of them")
    func searchAcrossMultipleCuesInOneSlot() {
        // A long caption is split into several cues that share one slot. Searching
        // only the slot's first cue silently missed the rest.
        let t = track("A", [(0, 0, 1, "first part"), (0, 1, 2, "second part")])
        let index = TrackIndex(track: t, formatter: formatter())
        #expect(index.matches(slot: 0, lowercasedNeedle: "first"))
        #expect(index.matches(slot: 0, lowercasedNeedle: "second"))
    }

    @Test("Project search returns slots matching in any track")
    func projectSearchSpansTracks() {
        let a = track("English", [(0, 0, 1, "the cat"), (1, 1, 2, "the dog")])
        let b = track("Hinglish", [(0, 0, 1, "billi"), (1, 1, 2, "kutta")],
                      kind: .romanized)
        let project = ProjectIndex(tracks: [a, b]) { _ in self.formatter() }
        #expect(project.slots(matching: "cat") == [0])
        #expect(project.slots(matching: "kutta") == [1])
        #expect(project.slots(matching: "the") == [0, 1])
        #expect(project.slots(matching: "nothing here").isEmpty)
    }

    @Test("An empty or whitespace query returns every slot, not none")
    func emptyQueryReturnsAllSlots() {
        let a = track("A", [(0, 0, 1, "x"), (1, 1, 2, "y")])
        let project = ProjectIndex(tracks: [a]) { _ in self.formatter() }
        #expect(project.slots(matching: "") == [0, 1])
        #expect(project.slots(matching: "   ") == [0, 1])
    }

    // MARK: Incremental reindex

    @Test("Replacing one track leaves the others' indexes intact")
    func replacingOneTrack() {
        // Editing a caption reindexes one track, not all of them. The untouched
        // tracks must still answer correctly afterwards.
        let a = track("A", [(0, 0, 1, "alpha"), (1, 1, 2, "beta")])
        let b = track("B", [(0, 0, 1, "gamma"), (1, 1, 2, "delta")], kind: .romanized)
        var project = ProjectIndex(tracks: [a, b]) { _ in self.formatter() }

        var editedA = a
        editedA.cues[0].lines = ["omega"]
        project = project.replacing(track: editedA, formatter: formatter(),
                                    allTracks: [editedA, b])

        #expect(project.slots(matching: "omega") == [0])
        #expect(project.slots(matching: "alpha").isEmpty)
        #expect(project.slots(matching: "gamma") == [0], "untouched track lost its index")
        #expect(project.slots(matching: "delta") == [1], "untouched track lost its index")
    }

    @Test("An empty index answers safely instead of trapping")
    func emptyIndex() {
        let project = ProjectIndex()
        #expect(project.slots.isEmpty)
        #expect(project.slots(matching: "anything").isEmpty)
        #expect(project.index(for: UUID()) == nil)
    }
}

/// `adjusted(for:)` used to overwrite the preset's reading rate and line length with the
/// script profile's, so every preset behaved identically. These pin the combined
/// behaviour so that regression cannot come back quietly.
@Suite("Preset and script combine")
struct PresetScriptTests {

    @Test("A preset's reading rate survives on Latin script")
    func latinKeepsPreset() {
        let youTube = CaptionRules.youTube.adjusted(for: .latin)
        #expect(youTube.maxReadingRate == 20)
        #expect(youTube.maxCharsPerLine == 42)
        let interview = CaptionRules.interview.adjusted(for: .latin)
        #expect(interview.maxReadingRate == 17)
    }

    @Test("Presets stay distinguishable from each other on every script")
    func presetsRemainDistinct() {
        for profile in [ScriptProfile.latin, .devanagari, .cjk, .arabic, .cyrillic] {
            let fast = CaptionRules.youTube.adjusted(for: profile)       // asks for 20
            let slow = CaptionRules.interview.adjusted(for: profile)     // asks for 17
            #expect(fast.maxReadingRate > slow.maxReadingRate,
                    "preset collapsed on \(profile.scriptCode)")
        }
    }

    @Test("A denser script still reads slower than Latin for the same preset")
    func scriptDensityStillApplies() {
        let latin = CaptionRules.youTube.adjusted(for: .latin)
        let cjk = CaptionRules.youTube.adjusted(for: .cjk)
        let deva = CaptionRules.youTube.adjusted(for: .devanagari)
        #expect(cjk.maxReadingRate < latin.maxReadingRate)
        #expect(cjk.maxCharsPerLine < latin.maxCharsPerLine)
        #expect(deva.maxReadingRate < latin.maxReadingRate)
    }

    @Test("Line length never collapses to something unusable")
    func lineLengthFloor() {
        for profile in [ScriptProfile.latin, .devanagari, .cjk, .japanese, .korean, .arabic] {
            for preset in CaptionRules.presets {
                let r = preset.rules.adjusted(for: profile)
                #expect(r.maxCharsPerLine >= 8, "\(preset.name)/\(profile.scriptCode)")
                #expect(r.maxReadingRate > 0)
            }
        }
    }
}

/// Cue timing bounds. Dragging a cue edge in the timeline calls this on every mouse
/// move, and before the logic was lifted out of `AppModel` nothing could test it —
/// no test target reaches the app module.
@Suite("Cue timing bounds")
struct CueTimingTests {

    private func slots(_ spans: [(Double, Double)]) -> [CueSlot] {
        spans.enumerated().map { i, s in
            CueSlot(index: i, start: s.0, end: s.1, wordRange: 0..<1,
                    endsSentence: false, parentIndex: i, subIndex: 0, subCount: 1)
        }
    }

    @Test("A move that fits is left exactly alone")
    func unclampedPassesThrough() {
        let s = slots([(0, 1), (2, 3), (4, 5)])
        let b = CueTiming.clamp(slotIndex: 1, requestedStart: 2.2, requestedEnd: 2.8,
                                slots: s, mediaDuration: 10)
        #expect(b?.start == 2.2)
        #expect(b?.end == 2.8)
        #expect(b?.wasClamped == false)
    }

    @Test("Dragging the start back stops at the previous cue")
    func clampedByPreviousCue() {
        let s = slots([(0, 1), (2, 3), (4, 5)])
        let b = CueTiming.clamp(slotIndex: 1, requestedStart: 0.5, requestedEnd: 3,
                                slots: s, mediaDuration: 10)
        #expect(b?.start == 1, "must not overlap the cue ending at 1")
        #expect(b?.wasClamped == true)
    }

    @Test("Dragging the end forward stops at the next cue")
    func clampedByNextCue() {
        let s = slots([(0, 1), (2, 3), (4, 5)])
        let b = CueTiming.clamp(slotIndex: 1, requestedStart: 2, requestedEnd: 4.9,
                                slots: s, mediaDuration: 10)
        #expect(b?.end == 4, "must not overlap the cue starting at 4")
        #expect(b?.wasClamped == true)
    }

    @Test("The last cue is bounded by the media, not by infinity")
    func lastCueBoundedByMedia() {
        let s = slots([(0, 1), (2, 3)])
        let b = CueTiming.clamp(slotIndex: 1, requestedStart: 2, requestedEnd: 99,
                                slots: s, mediaDuration: 5)
        #expect(b?.end == 5)
        #expect(b?.wasClamped == true)
    }

    @Test("The first cue cannot be dragged before zero")
    func firstCueCannotGoNegative() {
        let s = slots([(1, 2), (3, 4)])
        let b = CueTiming.clamp(slotIndex: 0, requestedStart: -5, requestedEnd: 2,
                                slots: s, mediaDuration: 10)
        #expect(b?.start == 0)
    }

    @Test("A cue never collapses to nothing")
    func neverZeroLength() {
        let s = slots([(0, 1), (2, 3), (4, 5)])
        for (from, to) in [(2.5, 2.5), (2.5, 2.4), (2.0, 2.0)] {
            let b = CueTiming.clamp(slotIndex: 1, requestedStart: from, requestedEnd: to,
                                    slots: s, mediaDuration: 10)
            #expect(b != nil, "collapsed request produced nothing")
            if let b {
                #expect(b.end - b.start >= CueTiming.minimumDuration - 1e-9,
                        "\(from)->\(to) gave \(b.end - b.start)")
                #expect(b.start >= 1 && b.end <= 4, "escaped its neighbours")
            }
        }
    }

    @Test("Back-to-back neighbours still leave a usable cue")
    func tightNeighbours() {
        // Adjacent cues with no gap: the middle slot has exactly its own span to live
        // in, and a drag must not push it outside that.
        let s = slots([(0, 2), (2, 2.5), (2.5, 4)])
        let b = CueTiming.clamp(slotIndex: 1, requestedStart: 1.0, requestedEnd: 3.5,
                                slots: s, mediaDuration: 10)
        #expect(b?.start == 2)
        #expect(b?.end == 2.5)
        #expect(b?.wasClamped == true)
    }

    @Test("An unknown slot is refused rather than guessed at")
    func unknownSlot() {
        #expect(CueTiming.clamp(slotIndex: 99, requestedStart: 0, requestedEnd: 1,
                                slots: slots([(0, 1)]), mediaDuration: 10) == nil)
    }

    @Test("Order of the slot array does not matter")
    func unsortedInput() {
        let s = slots([(0, 1), (2, 3), (4, 5)]).reversed()
        let b = CueTiming.clamp(slotIndex: 1, requestedStart: 0.5, requestedEnd: 9,
                                slots: Array(s), mediaDuration: 10)
        #expect(b?.start == 1)
        #expect(b?.end == 4)
    }
}
