import Foundation
import Translation
import SublyCaptions

/// On-device translation. English is the guaranteed target; other pairs appear only
/// where this Mac reports them available. PRD §6.3.
public actor TranslationService {

    public enum TranslationServiceError: LocalizedError {
        case pairUnavailable(from: String, to: String)
        case assetsNotInstalled(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .pairUnavailable(let f, let t):
                return "Translation from \(CapabilityRegistry.displayName(f)) to \(CapabilityRegistry.displayName(t)) isn't available on this Mac."
            case .assetsNotInstalled(let l):
                return "macOS hasn't downloaded the \(l) translation model yet. Open System Settings › General › Language & Region and add \(l), then try again."
            case .failed(let m):
                return "Translation failed. \(m)"
            }
        }
    }

    public init() {}

    public func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        return await availability.status(from: Locale.Language(identifier: source),
                                         to: Locale.Language(identifier: target))
    }

    /// Translate one string per cue slot, preserving the slot → text mapping via
    /// `clientIdentifier`, so translated text lands back in the correct time window
    /// and the spine is never re-timed. PRD CAP-08.
    public func translate(slotTexts: [Int: String],
                          from source: String,
                          to target: String,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Int: String] {
        guard !slotTexts.isEmpty else { return [:] }

        let sourceLang = Locale.Language(identifier: source)
        let targetLang = Locale.Language(identifier: target)

        let availability = LanguageAvailability()
        let state = await availability.status(from: sourceLang, to: targetLang)
        switch state {
        case .installed:
            break
        case .supported:
            // Verified by experiment: a detached session genuinely fails here with
            // "Unable to Translate". The pair exists on this Mac but is not
            // provisioned for this app, and only a SwiftUI-attached session may
            // request that. The app routes through TranslationBridge; this path is
            // reached only by the CLI harness.
            throw TranslationServiceError.assetsNotInstalled(CapabilityRegistry.displayName(source))
        default:
            throw TranslationServiceError.pairUnavailable(from: source, to: target)
        }

        let session = TranslationSession(installedSource: sourceLang, target: targetLang)
        do { try await session.prepareTranslation() }
        catch {
            // Report what actually failed instead of assuming it was the download.
            throw TranslationServiceError.failed(error.localizedDescription)
        }

        let ordered = slotTexts.keys.sorted()
        let requests = ordered.compactMap { key -> TranslationSession.Request? in
            guard let text = slotTexts[key],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranslationSession.Request(sourceText: text, clientIdentifier: String(key))
        }
        guard !requests.isEmpty else { return [:] }

        var out: [Int: String] = [:]
        var done = 0
        do {
            for try await response in session.translate(batch: requests) {
                if let id = response.clientIdentifier, let slot = Int(id) {
                    out[slot] = response.targetText
                }
                done += 1
                progress?(Double(done) / Double(requests.count))
            }
        } catch {
            throw TranslationServiceError.failed(error.localizedDescription)
        }
        return out
    }

    /// Available targets from a source language, verified on this Mac.
    public func availableTargets(from source: String) async -> [String] {
        let candidates = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh-Hans",
                          "hi", "ar", "ru", "nl", "pl", "tr", "vi", "th", "id", "uk"]
        let availability = LanguageAvailability()
        let src = Locale.Language(identifier: source)
        var out: [String] = []
        for target in candidates {
            guard target != source else { continue }
            let status = await availability.status(from: src, to: Locale.Language(identifier: target))
            if status == .installed { out.append(target) }
        }
        return out
    }
}
