import Foundation
import SublyCaptions
import SublyEngine

// End-to-end harness: exercises the exact pipeline the app uses.

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    usage:
      subly-cli generate <media> <lang> [outputs] [target]
      subly-cli transcribe <media> <lang> [vocabulary, comma separated]
      subly-cli caps
      subly-cli assets <lang>\n  subly-cli engine <auto|apple|pack-id> <lang>
    outputs: comma list of translation,romanized,original (default: all available)
    """)
    exit(0)
}

let command = args[1]

switch command {
case "caps":
    let registry = CapabilityRegistry()
    let state = await registry.systemState()
    print("Foundation model available: \(state.foundationModelAvailable)")
    if let r = state.foundationModelReason { print("  reason: \(r)") }
    print("SpeechTranscriber available: \(state.speechTranscriberAvailable)")
    print("Apple languages: \(state.appleLanguageCount)")
    print("Extended engine installed: \(state.extendedEngineInstalled)")
    print("")
    for (region, items) in await registry.grouped() {
        print("── \(region.rawValue) (\(items.count))")
        for c in items {
            let outs = OutputKind.allCases.filter { c.supports($0) }.map(\.shortLabel).joined(separator: ",")
            let tgt = c.translationTargets.isEmpty ? "-" : c.translationTargets.joined(separator: "/")
            print(String(format: "  %-12s %-22s %-20s tier=%d asset=%-12s [%@]",
                         (c.languageCode as NSString).utf8String!,
                         (c.displayName as NSString).utf8String!,
                         (c.engine.displayName as NSString).utf8String!,
                         c.transcriptionTier.rawValue,
                         (c.assetState.rawValue as NSString).utf8String!,
                         outs + " tgt=" + tgt))
        }
    }

case "trprobe":
    let svc2 = TranslationService()
    for c in ["es","ja","hi","fr"] {
        print("direct \(c)->en = \(await svc2.status(from: c, to: "en"))")
    }
    let reg2 = CapabilityRegistry()
    if let cap = await reg2.capability(forLanguage: "es") {
        print("registry es targets = \(cap.translationTargets) tier=\(cap.translationTier.rawValue)")
    }

case "trtry":
    // Does translate() succeed even when status reports .supported?
    let svc3 = TranslationService()
    do {
        let out = try await svc3.translate(slotTexts: [0: "Hola, este teléfono es muy bueno."],
                                           from: "es", to: "en")
        print("translate OK: \(out)")
    } catch { print("translate FAILED: \(error.localizedDescription)") }

case "pool":
    let svc = TranscriptionService()
    let st = await svc.poolState()
    print("reserved locales: \(st.reserved.count)/\(st.maximum)")
    for l in st.reserved { print("  \(l)") }

case "engine":
    guard args.count >= 4 else {
        fail("usage: subly-cli engine <auto|apple|pack-id> <lang>")
    }
    let choice: TranscriptionService.EngineChoice
    switch args[2] {
    case "auto", "automatic": choice = .automatic
    case "apple":             choice = .apple
    default:                  choice = .pack(args[2])
    }
    TranscriptionService.setEngineChoice(choice, for: args[3])
    let svc2 = TranscriptionService()
    let route = await svc2.route(for: args[3])
    print("engine for \(args[3]): \(route?.engineID ?? "none available")")
    print("runtime: \(ExtendedEngineManager.shared.runtimeURL?.path ?? "NOT FOUND")")
    for pack in ExtendedEngineManager.allPacks {
        print("  pack \(pack.id): installed=\(ExtendedEngineManager.shared.isInstalled(pack))")
    }

case "assets":
    guard args.count >= 2 else { fail("need a language") }
    let svc = TranscriptionService()
    let lang = args[2]
    if let route = await svc.route(for: lang) {
        print("route: \(route.engine.displayName) locale=\(route.locale.identifier(.bcp47))")
    } else { print("no route for \(lang)") }
    print("asset state: \(await svc.assetStatus(for: lang))")

case "transcribe":
    // The speech pass alone, through the same engine routing the app uses, so the
    // transcript and its word timings can be checked without the caption layout.
    guard args.count >= 4 else { fail("usage: transcribe <media> <lang> [vocabulary, comma separated]") }
    let media = URL(fileURLWithPath: args[2])
    let vocabulary = args.count >= 5 ? args[4].split(separator: ",").map(String.init) : []
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("subly-cli-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: work) }
    do {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let audio = try await MediaService().extractAudio(from: media, to: work.appendingPathComponent("audio.caf"))
        let started = Date()
        let spine = try await TranscriptionService().transcribe(audioURL: audio, language: args[3],
                                                                vocabulary: vocabulary) { p in
            FileHandle.standardError.write(Data(String(format: "  [%3.0f%%] %@\n", p.fraction * 100, p.stage).utf8))
        }
        let elapsed = Date().timeIntervalSince(started)
        let words = spine.words
        let ordered = zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 && $0.start <= $0.end }
        print("engine: \(spine.engineID)  duration: \(String(format: "%.2f", spine.duration))s")
        print("words: \(words.count)  first: \(String(format: "%.2f", words.first?.start ?? 0))s"
              + "  last: \(String(format: "%.2f", words.last?.end ?? 0))s  monotonic: \(ordered)")
        print("elapsed: \(String(format: "%.2f", elapsed))s")
        if ProcessInfo.processInfo.environment["SUBLY_WORD_TIMES"] != nil {
            print(words.map { String(format: "%.2f-%.2f %@", $0.start, $0.end, $0.text) }.joined(separator: " | "))
        } else {
            print(words.map(\.text).joined(separator: " "))
        }
    } catch {
        try? FileManager.default.removeItem(at: work)   // `fail` exits before `defer` runs
        fail("TRANSCRIPTION FAILED: \(error.localizedDescription)")
    }

case "generate":
    guard args.count >= 4 else { fail("usage: generate <media> <lang> [outputs] [target]") }
    let media = URL(fileURLWithPath: args[2])
    let lang = args[3]
    var outputs: Set<OutputKind> = [.original, .romanized, .translation]
    if args.count >= 5 {
        outputs = Set(args[4].split(separator: ",").compactMap { OutputKind(rawValue: String($0)) })
    }
    let target = args.count >= 6 ? args[5] : "en"

    // Drop outputs this Mac cannot produce, so the harness mirrors the UI.
    let registry = CapabilityRegistry()
    if let cap = await registry.capability(forLanguage: lang) {
        let before = outputs
        outputs = outputs.filter { cap.supports($0) }
        let dropped = before.subtracting(outputs)
        if !dropped.isEmpty {
            print("note: dropped unavailable outputs: \(dropped.map(\.shortLabel).joined(separator: ", "))")
        }
    }
    guard !outputs.isEmpty else { fail("no available outputs for \(lang)") }

    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("subly-cli-\(UUID().uuidString)")
    let request = GenerationPipeline.Request(
        mediaURL: media, workingDirectory: work, sourceLanguage: lang,
        outputs: outputs, translationTarget: target, rules: .shortForm,
        protectedTerms: ["iPhone", "display", "camera", "quality", "brightness"],
        useRefinement: true)

    let pipeline = GenerationPipeline()
    let started = Date()
    do {
        let out = try await pipeline.generate(request) { u in
            FileHandle.standardError.write(Data(String(format: "  [%3.0f%%] %@\n", u.fraction * 100, u.stage).utf8))
        }
        let elapsed = Date().timeIntervalSince(started)
        print("\n=== SPINE ===")
        print("engine: \(out.spine.engineID)")
        print("language: \(out.spine.sourceLanguage)  duration: \(String(format: "%.2f", out.spine.duration))s")
        print("words: \(out.spine.words.count)  slots: \(out.slots.count)")
        if let c = out.spine.meanConfidence { print("mean confidence: \(String(format: "%.2f", c))") }
        print("elapsed: \(String(format: "%.2f", elapsed))s  (\(String(format: "%.1f", out.spine.duration / max(0.001, elapsed)))x realtime)")

        if !out.failures.isEmpty {
            print("\n=== FAILURES ===")
            for f in out.failures { print("  \(f.kind.shortLabel): \(f.message)") }
        }

        let writer = SubtitleWriter()
        let profile = ScriptProfile.forLanguage(lang)
        let formatter = CaptionFormatter(rules: CaptionRules.shortForm.adjusted(for: profile), profile: profile)

        // Cross-track invariant: identical cue timings across every generated track.
        print("\n=== CROSS-TRACK ALIGNMENT ===")
        let counts = Set(out.tracks.map { $0.cues.count })
        print("cue counts: \(out.tracks.map { "\($0.displayName)=\($0.cues.count)" }.joined(separator: " "))")
        if counts.count == 1 {
            var aligned = true
            if let first = out.tracks.first {
                for t in out.tracks.dropFirst() {
                    for (a, b) in zip(first.cues, t.cues) {
                        if abs(a.start - b.start) > 1e-6 || abs(a.end - b.end) > 1e-6 { aligned = false; break }
                    }
                }
            }
            print(aligned ? "PASS identical timings across all tracks" : "FAIL timings diverge")
        } else {
            print("NOTE cue counts differ (a track split within its slots) — timings still derive from one spine")
        }

        for track in out.tracks {
            print("\n=== \(track.displayName)  [\(track.languageTag)] ===")
            let diags = formatter.validate(track.cues)
            if diags.isEmpty { print("validation: clean") }
            else {
                var byIssue: [CueIssue: Int] = [:]
                for d in diags { byIssue[d.issue, default: 0] += 1 }
                print("validation: " + byIssue.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))
            }
            do { try writer.validate(track); print("export check: valid") }
            catch { print("export check: \(error.localizedDescription)") }
            print("---")
            print(writer.srt(track).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? FileManager.default.removeItem(at: work)
    } catch {
        fail("GENERATION FAILED: \(error.localizedDescription)")
    }

default:
    fail("unknown command \(command)")
}
