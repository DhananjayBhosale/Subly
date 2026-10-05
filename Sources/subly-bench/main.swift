import Foundation
import SublyCaptions

// Benchmarks the operations the editor performs on every redraw / playback tick.
// Sizes match a 57-minute video: ~1800 cues per track, 3 tracks.

func makeTrack(_ n: Int, kind: OutputKind, tag: String) -> SubtitleTrack {
    let cues = (0..<n).map { i in
        Cue(slotIndex: i, start: Double(i) * 2.0, end: Double(i) * 2.0 + 1.8,
            lines: ["Line one here", "line two here"])
    }
    return SubtitleTrack(kind: kind, languageTag: tag, displayName: tag, cues: cues, engineID: "bench")
}

func time(_ label: String, iterations: Int = 1, _ body: () -> Void) {
    setvbuf(stdout, nil, _IONBF, 0)
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { body() }
    let ns = DispatchTime.now().uptimeNanoseconds - start
    let perOp = Double(ns) / Double(iterations) / 1_000_000
    let flag = perOp > 16.6 ? "<-- DROPS FRAMES AT 60fps" : (perOp > 4 ? "<-- heavy" : "")
    let padded = label.padding(toLength: 52, withPad: " ", startingAt: 0)
    print(padded + String(format: " %8.3f ms/op   ", perOp) + flag)
}

let cueCount = 1800
let tracks = [makeTrack(cueCount, kind: .translation, tag: "en"),
              makeTrack(cueCount, kind: .romanized, tag: "hi-Latn"),
              makeTrack(cueCount, kind: .original, tag: "hi")]
print("=== \(tracks.count) tracks x \(cueCount) cues (≈57-minute video) ===\n")

// 1. What activeCues(at:) does on every playback tick (30/sec).
time("activeCues: linear scan of every track", iterations: 30) {
    let t = 3000.0
    var found: [Cue] = []
    for track in tracks {
        if let cue = track.cues.first(where: { t >= $0.start && t < $0.end }) { found.append(cue) }
    }
    _ = found
}

// 2. What diagnostics(for:) does on every view body evaluation.
let formatter = CaptionFormatter(rules: .shortForm, profile: .latin)
time("diagnostics: validate() over one track") {
    _ = formatter.validate(tracks[0].cues)
}
time("diagnostics: validate() over all tracks (inspector body)") {
    for track in tracks { _ = formatter.validate(track.cues) }
}

// 3. What CueGridView.slots does on every body evaluation.
time("cue grid: build sorted unique slot list") {
    let all = tracks.flatMap { $0.cues.map(\.slotIndex) }
    _ = Array(Set(all)).sorted()
}

// 4. What filteredSlots does when the search box has text.
let slots = Array(0..<cueCount)
time("cue grid: search filter (slots x tracks x cues)") {
    _ = slots.filter { slot in
        tracks.contains { track in
            track.cues.contains { $0.slotIndex == slot && $0.text.localizedCaseInsensitiveContains("here") }
        }
    }
}

// 5. Per-cell cue lookup, as the grid does for every visible row.
time("cue grid: per-cell linear lookup x 40 visible rows", iterations: 1) {
    for row in 0..<40 {
        for track in tracks { _ = track.cues.first { $0.slotIndex == row } }
    }
}

// 6. trackIndex, called per row and per cell.
time("trackIndex linear scan x 120 calls") {
    for _ in 0..<120 { _ = tracks.firstIndex { $0.id == tracks[2].id } }
}

print("\n--- with the obvious fixes ---\n")

// Indexed lookups.
var bySlot: [[Int: Cue]] = tracks.map { track in
    Dictionary(track.cues.map { ($0.slotIndex, $0) }, uniquingKeysWith: { a, _ in a })
}
time("activeCues: binary search on sorted cues", iterations: 30) {
    let t = 3000.0
    var found: [Cue] = []
    for track in tracks {
        var lo = 0, hi = track.cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cue = track.cues[mid]
            if t < cue.start { hi = mid - 1 }
            else if t >= cue.end { lo = mid + 1 }
            else { found.append(cue); break }
        }
    }
    _ = found
}
time("cue grid: per-cell dictionary lookup x 40 rows") {
    for row in 0..<40 { for d in bySlot { _ = d[row] } }
}
time("diagnostics: cached (dictionary hit)") {
    _ = bySlot[0].count
}

print("\n--- ProjectIndex (shipped implementation) ---\n")
let projectIndex = ProjectIndex(tracks: tracks, formatterFor: { _ in formatter })
time("ProjectIndex: build once per edit") {
    _ = ProjectIndex(tracks: tracks, formatterFor: { _ in formatter })
}
time("search filter via index", iterations: 10) {
    _ = projectIndex.slots(matching: "here")
}
time("activeCues via index", iterations: 30) {
    var found = 0
    for track in tracks {
        if projectIndex.index(for: track.id)?.cuePosition(at: 3000.0) != nil { found += 1 }
    }
    _ = found
}
time("diagnostics via index (all tracks)") {
    var n = 0
    for track in tracks { n += projectIndex.index(for: track.id)?.issueCount ?? 0 }
    _ = n
}
time("grid cell lookup x 40 rows via index") {
    for row in 0..<40 {
        for track in tracks { _ = projectIndex.index(for: track.id)?.position(forSlot: row) }
    }
}

print("\n=== generation-side hot paths (57-minute project) ===\n")

// A spine matching the real 57-minute file: ~2650 words, 850 slots.
var benchWords: [TimedWord] = []
var bt = 0.0
for i in 0..<2650 {
    let dur = 0.18 + Double(i % 5) * 0.06
    benchWords.append(TimedWord(text: i % 9 == 0 ? "word\(i)," : "word\(i)",
                                start: bt, end: bt + dur, confidence: 0.7))
    bt += dur + (i % 17 == 0 ? 2.2 : 0.05)
}
let bigSpine = TimingSpine(words: benchWords, sourceLanguage: "hi-IN",
                           duration: bt + 1, engineID: "bench")
let seg = Segmenter(rules: .shortForm, profile: .devanagari)

time("segment 2650 words") { _ = seg.segment(bigSpine) }
let bigSlots = seg.segment(bigSpine)
print("   -> \(bigSlots.count) slots")

// The per-slot text join, which uses a regex.
time("slot text join (regex per slot)") {
    let profile = ScriptProfile.forLanguage(bigSpine.sourceLanguage)
    let joiner = profile.segmentation == .characterBased ? "" : " "
    var out: [Int: String] = [:]
    for slot in bigSlots {
        let lower = max(0, slot.wordRange.lowerBound)
        let upper = min(bigSpine.words.count, slot.wordRange.upperBound)
        guard lower < upper else { continue }
        out[slot.index] = bigSpine.words[lower..<upper].map(\.text).joined(separator: joiner)
            .replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    _ = out
}

// The same join without a regex.
time("slot text join (no regex)") {
    var out: [Int: String] = [:]
    for slot in bigSlots {
        let lower = max(0, slot.wordRange.lowerBound)
        let upper = min(bigSpine.words.count, slot.wordRange.upperBound)
        guard lower < upper else { continue }
        var text = ""
        text.reserveCapacity((upper - lower) * 8)
        for (n, w) in bigSpine.words[lower..<upper].enumerated() {
            if n > 0, let f = w.text.first, !",.!?;:".contains(f) { text += " " }
            text += w.text
        }
        out[slot.index] = text
    }
    _ = out
}

var devaSlotTexts: [Int: String] = [:]
for slot in bigSlots {
    let lower = max(0, slot.wordRange.lowerBound)
    let upper = min(bigSpine.words.count, slot.wordRange.upperBound)
    if lower < upper {
        devaSlotTexts[slot.index] = bigSpine.words[lower..<upper].map(\.text).joined(separator: " ")
    }
}

let romanizer = Romanizer()
time("romanize every slot (Latin input, no-op path)") {
    for (_, t) in devaSlotTexts { _ = romanizer.romanize(t, language: "hi") }
}

let devaTexts = devaSlotTexts.mapValues { _ in "यहाँ पर बहुत कम रिफ्लेक्शन्स हैं" }
time("romanize every slot (real Devanagari)") {
    for (_, t) in devaTexts { _ = romanizer.romanize(t, language: "hi") }
}

let bigFormatter = CaptionFormatter(rules: .shortForm, profile: .devanagari)
time("requiredCueCount for every slot") {
    for slot in bigSlots { _ = bigFormatter.requiredCueCount(for: devaSlotTexts[slot.index] ?? "", duration: slot.duration) }
}
var bigDemand: [Int: Int] = [:]
for slot in bigSlots { bigDemand[slot.index] = bigFormatter.requiredCueCount(for: devaSlotTexts[slot.index] ?? "", duration: slot.duration) }
time("unify") { _ = CaptionFormatter.unify(slots: bigSlots, demands: [bigDemand], words: benchWords, minCueDuration: 0.75) }
let bigUnified = CaptionFormatter.unify(slots: bigSlots, demands: [bigDemand], words: benchWords, minCueDuration: 0.75)
time("fill") { _ = bigFormatter.fill(slots: bigUnified, texts: devaSlotTexts) }
let bigCues = bigFormatter.fill(slots: bigUnified, texts: devaSlotTexts)
let bigTrack = SubtitleTrack(kind: .original, languageTag: "hi", displayName: "T",
                             cues: bigCues, engineID: "bench")
let writer = SubtitleWriter()
time("write SRT (\(bigCues.count) cues)") { _ = writer.srt(bigTrack) }
time("validate") { _ = bigFormatter.validate(bigCues) }

print("\n=== after the second performance pass ===\n")
time("slot text join (shipped, no regex)") {
    _ = GenerationPipelineJoinProbe.join(bigSpine, slots: bigSlots)
}
time("romanize every slot, Devanagari (cache warm)") {
    for (_, t) in devaTexts { _ = romanizer.romanize(t, language: "hi") }
}
var varied = devaTexts
for (k, _) in varied { varied[k] = "यहाँ पर बहुत कम रिफ्लेक्शन्स हैं \(k)" }
time("romanize every slot, varied text (cache partly cold)") {
    for (_, t) in varied { _ = romanizer.romanize(t, language: "hi") }
}
let idx = ProjectIndex(tracks: tracks, formatterFor: { _ in formatter })
time("reindex ONE track (incremental)") {
    _ = idx.replacing(track: tracks[0], formatter: formatter, allTracks: tracks)
}
time("reindex ALL tracks (full)") {
    _ = ProjectIndex(tracks: tracks, formatterFor: { _ in formatter })
}

print("\n=== project save/load (largest real project, if present) ===\n")
if let path = ProcessInfo.processInfo.environment["SUBLY_BENCH_PROJECT"],
   let data = FileManager.default.contents(atPath: path) {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    if let doc = try? decoder.decode(ProjectDocument.self, from: data) {
        print("project: \(data.count / 1024) KB, \(doc.tracks.reduce(0) { $0 + $1.cues.count }) cues, \(doc.spine?.words.count ?? 0) words")
        time("decode project", iterations: 10) { _ = try? decoder.decode(ProjectDocument.self, from: data) }
        let pretty = JSONEncoder(); pretty.outputFormatting = [.prettyPrinted, .sortedKeys]; pretty.dateEncodingStrategy = .iso8601
        let compact = JSONEncoder(); compact.dateEncodingStrategy = .iso8601
        time("encode project (pretty, sorted)", iterations: 10) { _ = try? pretty.encode(doc) }
        time("encode project (compact)", iterations: 10) { _ = try? compact.encode(doc) }
        print("   sizes: pretty \((try? pretty.encode(doc).count ?? 0) ?? 0) B, compact \((try? compact.encode(doc).count ?? 0) ?? 0) B")
    }
}
