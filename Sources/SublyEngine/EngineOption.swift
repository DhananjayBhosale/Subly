import Foundation

/// The engines a user can pick from for one language, built once so the UI and the
/// tests agree on the list. It lived inside the SwiftUI view, where nothing could
/// check it — and the app has no test target, so "is Apex actually in the menu?" had
/// no answer short of looking.
public struct EngineOption: Identifiable, Sendable, Equatable {
    public var choice: TranscriptionService.EngineChoice
    public var name: String
    public var detail: String
    /// The model's real identity, e.g. `ggerganov/whisper.cpp · large-v3-turbo · q5_0`.
    public var modelIdentity: String?
    public var packID: String?
    public var needsDownload: Bool
    /// The model this app suggests for the language. Shown, never forced — someone
    /// short of disk or memory may reasonably take a smaller one.
    public var isRecommended: Bool = false

    public var id: String { choice.storageValue }

    /// Every engine that can transcribe `languageCode`, in preference order.
    ///
    /// - Parameter appleHandles: false when Apple has no engine for this language, in
    ///   which case Apple is not offered at all.
    public static func all(languageCode: String,
                           appleHandles: Bool,
                           appleEngineName: String,
                           installedPackIDs: Set<String>) -> [EngineOption] {
        var out: [EngineOption] = [
            EngineOption(choice: .automatic, name: "Automatic",
                         detail: "Picks for you: Apple where it handles the language, otherwise a model you have downloaded.",
                         modelIdentity: nil, packID: nil, needsDownload: false)
        ]
        if appleHandles {
            out.append(EngineOption(
                choice: .apple, name: "Apple (built in)",
                detail: "Built into macOS. Fastest, nothing to download, and the only option that writes the language in its own script.",
                modelIdentity: nil, packID: nil, needsDownload: false))
        }
        let best = ExtendedEngineManager.recommended(for: languageCode).pack
        for pack in ExtendedEngineManager.allPacks where pack.serves(languageCode) {
            out.append(EngineOption(
                choice: .pack(pack.id),
                name: pack.displayName,
                detail: pack.bestFor,
                modelIdentity: pack.modelIdentity, packID: pack.id,
                needsDownload: !installedPackIDs.contains(pack.id),
                isRecommended: pack.id == best.id))
        }
        return out
    }

    /// Specialised models that do NOT serve `languageCode`, with the language each one
    /// needs. Offered so a user who wants Apex can get to it in one step.
    ///
    /// Filtering them out silently was wrong: with the spoken language left on English,
    /// Apex vanished from the menu entirely and there was nothing to indicate it
    /// existed, let alone what to change.
    public static func specialisedElsewhere(languageCode: String)
        -> [(pack: ExtendedEngineManager.ModelPack, languageCodes: [String])] {
        ExtendedEngineManager.allPacks.compactMap { pack in
            guard pack.id != ExtendedEngineManager.generalPack.id,
                  !pack.serves(languageCode) else { return nil }
            return (pack, pack.languages)
        }
    }
}

public extension ExtendedEngineManager.ModelPack {
    /// Whether this model can transcribe a language at all.
    ///
    /// Whisper is general-purpose, so it serves everything; Apex is fine-tuned for the
    /// languages it lists and would produce nonsense elsewhere.
    func serves(_ languageCode: String) -> Bool {
        // Every general Whisper model is multilingual, so all of them serve every
        // language. Only a specialised model is restricted — and it is restricted to
        // what it was actually trained on.
        if isGeneral { return true }
        return specialisedFor?.contains(languageCode) ?? languages.contains(languageCode)
    }
}
