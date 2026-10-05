import Foundation
import FoundationModels
import SublyCaptions

/// On-device text refinement via the Apple Foundation Model.
///
/// Two hard rules: it edits TEXT ONLY and can never touch a timestamp, and it may
/// only improve output the deterministic pipeline already produced — never
/// originate it. A rejected suggestion falls
/// back to the deterministic text.
public actor RefinementService {

    /// Structured output keeps the model inside a known shape instead of free prose.
    @Generable
    struct RefinedLine {
        @Guide(description: "The corrected subtitle text. Keep the same meaning and the same language. Never add commentary.")
        var text: String
    }

    @Generable
    struct RefinedBatch {
        @Guide(description: "Corrected subtitle lines, in the same order and the same count as the input.")
        var lines: [String]
    }

    public enum RefinementError: LocalizedError {
        case unavailable(String)
        public var errorDescription: String? {
            switch self { case .unavailable(let r): return r }
        }
    }

    public init() {}

    public var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// The on-device model has a finite context window, so transcripts are chunked and
    /// merged only when the result validates.
    private static let linesPerChunk = 12

    /// Improve punctuation and obvious spelling in already-generated caption text.
    /// Returns the input unchanged for any chunk the model declines or mangles.
    public func refine(slotTexts: [Int: String],
                       language: String,
                       instruction: String,
                       requireLatinScript: Bool = false,
                       progress: (@Sendable (Double) -> Void)? = nil) async -> [Int: String] {
        guard SystemLanguageModel.default.isAvailable else { return slotTexts }

        let ordered = slotTexts.keys.sorted()
        var result = slotTexts
        let chunks = stride(from: 0, to: ordered.count, by: Self.linesPerChunk).map {
            Array(ordered[$0..<min($0 + Self.linesPerChunk, ordered.count)])
        }

        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { break }
            let inputs = chunk.compactMap { slotTexts[$0] }
            guard !inputs.isEmpty else { continue }

            let prompt = """
            \(instruction)

            Language: \(CapabilityRegistry.displayName(language)).
            Correct each numbered subtitle line. Return exactly \(inputs.count) lines in the same order.
            Do not translate. Do not merge or split lines. Do not add or remove information.

            \(inputs.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            """

            do {
                // Bounded: the on-device model service can stall for many minutes, and
                // "Polishing the spelling" then never finished. A chunk that takes too
                // long ends the polish; the captions keep their unpolished text.
                guard let lines = try await Self.respond(to: prompt, within: Self.chunkTimeout) else { break }
                // Only accept a chunk that came back with the exact expected shape.
                if lines.count == inputs.count {
                    for (k, slot) in chunk.enumerated() {
                        let candidate = lines[k].trimmingCharacters(in: .whitespacesAndNewlines)
                        if Self.isPlausible(candidate, original: inputs[k],
                                            requireLatinScript: requireLatinScript) {
                            result[slot] = candidate
                        }
                    }
                }
            } catch {
                // Refinement is optional polish; a failure must never fail the job.
            }
            progress?(Double(i + 1) / Double(max(1, chunks.count)))
        }
        return result
    }

    static let chunkTimeout: Duration = .seconds(25)

    /// The model's lines for `prompt`, or nil if it hasn't answered in time.
    static func respond(to prompt: String, within limit: Duration) async throws -> [String]? {
        let once = ResumeOnce<[String]?>()
        let work = WorkBox()
        // Cancel ends the wait at once and stops the model's task, as a timeout does.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                work.task = Task {
                    do {
                        let response = try await LanguageModelSession().respond(to: prompt, generating: RefinedBatch.self)
                        once.resume(.success(response.content.lines))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(for: limit)
                    if once.resume(.success(nil)) { work.cancel() }
                }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
            work.cancel()
        }
    }

    /// Guard against the model rewriting, translating, or padding a line. A refusal to
    /// accept simply keeps the deterministic text.
    static func isPlausible(_ candidate: String, original: String,
                            requireLatinScript: Bool = false) -> Bool {
        guard !candidate.isEmpty else { return false }
        let a = Double(candidate.count), b = Double(max(1, original.count))
        guard a / b > 0.5, a / b < 1.8 else { return false }

        // A romanized line must stay romanized. Without this the model happily
        // "corrects" Latin text back into the source script, silently undoing the
        // transliteration — observed with Russian, where it returned Cyrillic.
        if requireLatinScript, !Self.isLatinScript(candidate) { return false }

        // More generally, never let the model switch scripts on us — in either
        // direction: a Devanagari line coming back in English is a translation.
        if Self.isLatinScript(original) != Self.isLatinScript(candidate) { return false }

        // Same words, lightly corrected. A length check alone let the model replace a
        // Hinglish line with an English sentence nobody said ("Please leave the phone
        // here, as it is not yours") — burned into an exported video.
        guard Self.keepsTheWords(candidate, original: original) else { return false }
        // Reject obvious meta-commentary.
        let lowered = candidate.lowercased()
        for marker in ["here is", "here's the", "corrected:", "sure,", "i have", "as an ai"] {
            if lowered.hasPrefix(marker) { return false }
        }
        return true
    }

    /// True when the candidate is the original with spelling or punctuation fixed: about
    /// the same number of words, and most words still recognisably themselves, in order.
    static func keepsTheWords(_ candidate: String, original: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { $0.isWhitespace }).map {
                String($0.unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters).contains($0) })
            }.filter { !$0.isEmpty }
        }
        let a = words(candidate), b = words(original)
        guard !b.isEmpty else { return !a.isEmpty }
        guard abs(a.count - b.count) <= max(1, b.count / 7) else { return false }
        var matched = 0
        for (i, word) in b.enumerated() {
            // Bounded on both sides: with the model's line three words shorter, the
            // window near the end was 19..<18, which crashed the app.
            let lower = min(max(0, i - 1), a.count)
            let nearby = a[lower..<max(lower, min(a.count, i + 2))]
            let allowed = max(2, word.count / 3)
            // A short word changed by two letters must still start the same way:
            // "bhee" → "bhi" is a spelling fix, "desu" → "yes" is a translation.
            if nearby.contains(where: { candidate in
                let d = editDistance(candidate, word)
                return d <= allowed && (d <= 1 || word.count > 4 || candidate.first == word.first)
            }) { matched += 1 }
        }
        return Double(matched) / Double(b.count) >= 0.7
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }

    /// True when every letter is Latin (or ASCII punctuation / digits).
    static func isLatinScript(_ s: String) -> Bool {
        for scalar in s.unicodeScalars where scalar.value > 0x02FF {
            // Allow combining diacritics and general punctuation; reject real scripts.
            if scalar.value >= 0x0370 { return false }
        }
        return true
    }

    /// Romanization rerank: the deterministic result is the baseline and the model may
    /// only adjust spelling.
    public func rerankRomanization(slotTexts: [Int: String],
                                   language: String,
                                   protectedTerms: [String]) async -> [Int: String] {
        let terms = protectedTerms.isEmpty ? "" :
            "\nAlways keep these spelled exactly as given: \(protectedTerms.joined(separator: ", "))."
        let instruction = """
        These lines are \(CapabilityRegistry.displayName(language)) speech written in the Roman alphabet, \
        the way a native speaker would type it casually in a chat message. \
        Fix only awkward or unnatural spelling. Keep every word and its meaning. \
        Keep English loanwords spelled in English.\(terms)
        """
        return await refine(slotTexts: slotTexts, language: language,
                            instruction: instruction, requireLatinScript: true)
    }

    public func unavailableReason() -> String? {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady:
                return "macOS is still preparing the Apple Intelligence model."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        }
        return nil
    }
}

/// The model's task, reachable from the cancellation handler. Remembers a cancel
/// that came before the task existed, and cancels the task as soon as it is set.
final class WorkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Never>?
    private var cancelled = false
    var task: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return _task }
        set {
            lock.lock(); _task = newValue; let stop = cancelled; lock.unlock()
            if stop { newValue?.cancel() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let t = _task; lock.unlock()
        t?.cancel()
    }
}

/// Resumes a continuation exactly once, whichever of a result and a timeout comes first.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var done = false
    /// A result that arrived before the continuation did (a cancel at the very start).
    private var early: Result<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early { self.early = nil; lock.unlock(); c.resume(with: early); return }
        continuation = c
        lock.unlock()
    }

    /// True if this call decided the result.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        guard let c = continuation else { early = result; lock.unlock(); return true }
        continuation = nil
        lock.unlock()
        c.resume(with: result)
        return true
    }
}
