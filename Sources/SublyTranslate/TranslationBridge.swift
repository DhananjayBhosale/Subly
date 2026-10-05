import SwiftUI
import Translation

/// Apple only lets a SwiftUI-attached `TranslationSession` download language assets.
/// A detached actor can translate pairs already provisioned for this app, but the
/// first use of a pair needs a session created by `.translationTask`.
///
/// This bridges the two: the generation pipeline hands a job here, a hidden host view
/// runs it on a real session, and the result goes back to the pipeline.
///
/// Deliberately lock-guarded rather than actor- or MainActor-isolated: `TranslationSession`
/// is not `Sendable`, so the task body must not hop isolation while holding one.
public final class TranslationBridge: @unchecked Sendable {

    public init() {}


    public struct Job: Sendable {
        public let texts: [Int: String]
        public let source: String
        public let target: String
        /// Which request this is. Preparation, completion and timeouts all name it, so
        /// an older session finishing late can only ever complete its own request —
        /// it used to resume whichever request was current.
        public let token: Int
    }

    /// How long a *prepared* session may sit silent before it is failed. Nothing in
    /// the Translation framework guarantees a reply, so this is the only bound there is.
    static let timeoutSeconds: Double = 45

    /// How long to allow for `prepareTranslation()`, which can be showing Apple's
    /// language-download sheet and waiting on the user to accept and download.
    ///
    /// `SUBLY_PREPARE_TIMEOUT` shortens it for the headless harnesses, where no one is
    /// there to accept the sheet and waiting the full ten minutes would be pointless.
    static let prepareTimeoutSeconds: Double = {
        if let raw = ProcessInfo.processInfo.environment["SUBLY_PREPARE_TIMEOUT"],
           let value = Double(raw), value > 0 { return value }
        return 600
    }()

    public enum BridgeError: LocalizedError {
        case unavailable(String, String)
        case timedOut(String, String)
        case superseded

        public var errorDescription: String? {
            switch self {
            case .unavailable(let s, let t):
                return "macOS couldn't set up \(s) → \(t) translation. Open System Settings › General › Language & Region, add the language, then try again."
            case .timedOut(let s, let t):
                return "\(s) → \(t) translation didn't respond, so Subly stopped waiting. Your other tracks are ready. Open System Settings › General › Language & Region, add the language, then try the translation again."
            case .superseded:
                return "Translation was replaced by a newer request."
            }
        }
    }

    private let lock = NSLock()
    private var pending: Job?
    private var continuation: CheckedContinuation<[Int: String], Error>?
    /// The request the waiting continuation belongs to. A request cancelled between
    /// taking its turn and installing its continuation must not end the caller still
    /// waiting from before.
    private var continuationToken: Int?
    /// The outstanding request's number.
    private var jobToken = 0
    /// When preparation finished for the outstanding request. Before that, macOS may be
    /// showing its language-download sheet, which can legitimately take minutes; the
    /// short reply timeout is measured from here, not from the start — counting the
    /// download time against it failed a session the moment it became ready.
    private var preparedAt: (token: Int, date: Date)?

    /// Called by the session runner once preparation succeeds for `token`.
    public func notePrepared(token: Int) {
        lock.lock(); defer { lock.unlock() }
        if token == jobToken { preparedAt = (token, Date()) }
    }

    /// Drives the host view's `translationTask`. Read on the main actor by SwiftUI.
    private var _configuration: TranslationSession.Configuration?
    /// Which request the published configuration was made for. A session started for
    /// an older configuration could otherwise claim a newer request and translate it
    /// with the wrong language pair.
    private var _configurationToken: Int?
    private var pendingConfiguration: (token: Int, configuration: TranslationSession.Configuration)?
    /// The configuration SwiftUI last saw, to make the next one differ from it.
    private var lastPublished: TranslationSession.Configuration?
    private let configurationChanged = ObservableTrigger()

    public var configuration: TranslationSession.Configuration? {
        lock.lock(); defer { lock.unlock() }
        return _configuration
    }

    public var configurationToken: Int? {
        lock.lock(); defer { lock.unlock() }
        return _configurationToken
    }

    /// Observable stand-in so SwiftUI re-evaluates when the configuration changes.
    @Observable public final class ObservableTrigger { public var generation = 0; public init() {} }
    public var trigger: ObservableTrigger { configurationChanged }

    public func translate(_ texts: [Int: String], from source: String,
                   to target: String) async throws -> [Int: String] {
        guard !texts.isEmpty else { return [:] }
        // Before taking a turn: a cancelled caller that still took one superseded the
        // translation running for someone else, and its cancel then ended that one.
        try Task.checkCancellation()
        lock.lock()
        jobToken += 1
        let token = jobToken
        lock.unlock()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { newContinuation in
                lock.lock()
                guard token == jobToken, !Task.isCancelled else {
                    lock.unlock()
                    newContinuation.resume(throwing: Task.isCancelled ? CancellationError() : BridgeError.superseded)
                    return
                }
                let previous = continuation
                continuation = newContinuation
                continuationToken = token
                preparedAt = nil
                pending = Job(texts: texts, source: source, target: target, token: token)
                // `Configuration` is Equatable and SwiftUI diffs it, so reusing an equal
                // value would NOT restart the task — the second translation of the same
                // pair would hang forever. Invalidating the old one forces a fresh
                // session, and clearing to nil first guarantees a change is observed.
                _configuration?.invalidate()
                _configuration = nil
                _configurationToken = nil
                // The same language pair again (Listen Again on a project with a
                // translation): a fresh Configuration equals the one SwiftUI last saw —
                // both version 0 — and the nil published in between can be coalesced
                // away, so the task never restarted and the redo waited out the timeout.
                // A new version of the last one always differs.
                var next = TranslationSession.Configuration(
                    source: Locale.Language(identifier: source),
                    target: Locale.Language(identifier: target))
                if var last = lastPublished, last.source == next.source, last.target == next.target {
                    last.invalidate()
                    next = last
                }
                pendingConfiguration = (token, next)
                lock.unlock()

                previous?.resume(throwing: BridgeError.superseded)
                // Two-step so SwiftUI definitely sees a change: publish nil, then the new
                // configuration on the next runloop turn — unless a newer request has
                // replaced this one in between.
                Task { @MainActor in
                    self.configurationChanged.generation += 1
                    await Task.yield()
                    self.lock.lock()
                    if let next = self.pendingConfiguration, next.token == token, self.jobToken == token {
                        self._configuration = next.configuration
                        self.lastPublished = next.configuration
                        self._configurationToken = token
                        self.pendingConfiguration = nil
                    }
                    self.lock.unlock()
                    self.configurationChanged.generation += 1
                }
                // A translation that never comes back must not hang the whole job.
                // Armed on this request's token, claimed or not (an earlier version
                // waited only while the job was unclaimed, so a started session that
                // never replied hung forever).
                Task { [weak self] in
                    let started = Date()
                    while true {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self else { return }
                        self.lock.lock()
                        let outstanding = self.continuation != nil && self.jobToken == token
                        let prepared = self.preparedAt.flatMap { $0.token == token ? $0.date : nil }
                        self.lock.unlock()
                        guard outstanding else { return }
                        let expired = prepared.map { Date().timeIntervalSince($0) > Self.timeoutSeconds }
                            ?? (Date().timeIntervalSince(started) > Self.prepareTimeoutSeconds)
                        if expired {
                            self.finish(token: token, .failure(BridgeError.timedOut(source, target)))
                            return
                        }
                    }
                }
            }
        } onCancel: {
            // The caller gave up: end this request now rather than leave it waiting
            // up to the preparation timeout.
            finish(token: token, .failure(CancellationError()))
        }
    }

    /// Claim the pending job made for `token`. Synchronous, so the caller never hops
    /// isolation.
    public func takePendingJob(token: Int?) -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard let job = pending, job.token == token else { return nil }
        pending = nil
        return job
    }

    /// Complete request `token`, if it is still the outstanding one.
    public func finish(token: Int, _ result: Result<[Int: String], Error>) {
        lock.lock()
        guard token == jobToken, token == continuationToken, let waiting = continuation else { lock.unlock(); return }
        continuation = nil
        continuationToken = nil
        pending = nil
        var withdraw = false
        if case .failure = result {
            // Withdraw the session too. Left in place, Apple's "Download Languages to
            // Translate" sheet stayed on screen after Subly had given up waiting, and
            // the app could not quit while it was up.
            _configuration = nil
            _configurationToken = nil
            withdraw = true
        }
        lock.unlock()
        waiting.resume(with: result)
        if withdraw {
            Task { @MainActor in self.configurationChanged.generation += 1 }
        }
    }
}

/// Invisible, but must stay in the view tree: `translationTask` only runs on a view
/// that is actually installed.
public struct TranslationHost: View {
    private let bridge: TranslationBridge

    public init(bridge: TranslationBridge) { self.bridge = bridge }

    public var body: some View {
        // Reading `generation` is what re-evaluates this view when a new job arrives.
        let _ = bridge.trigger.generation
        let token = bridge.configurationToken
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(bridge.configuration) { [bridge] session in
                await runTranslation(session: session, bridge: bridge, token: token)
            }
    }
}

/// Runs the session work outside any actor. `TranslationSession` is not `Sendable`,
/// so this must not be MainActor-isolated — otherwise the compiler rejects passing
/// the session in from the framework's own task.
func runTranslation(session: TranslationSession,
                                bridge: TranslationBridge, token: Int?) async {
    guard !Task.isCancelled, let job = bridge.takePendingJob(token: token) else { return }
    do {
        // The call that may present Apple's language-download UI. Tell the bridge when
        // it returns so the watchdog can switch from the generous "waiting for macOS
        // and the user" bound to the short "session should reply promptly" one.
        try await session.prepareTranslation()
        bridge.notePrepared(token: job.token)

        let requests = job.texts.keys.sorted()
            .compactMap { key -> TranslationSession.Request? in
                guard let text = job.texts[key],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return TranslationSession.Request(sourceText: text,
                                                  clientIdentifier: String(key))
            }
        guard !requests.isEmpty else { bridge.finish(token: job.token, .success([:])); return }

        var out: [Int: String] = [:]
        for try await response in session.translate(batch: requests) {
            if let id = response.clientIdentifier, let slot = Int(id) {
                out[slot] = response.targetText
            }
        }
        bridge.finish(token: job.token, .success(out))
    } catch {
        bridge.finish(token: job.token, .failure(error))
    }
}
