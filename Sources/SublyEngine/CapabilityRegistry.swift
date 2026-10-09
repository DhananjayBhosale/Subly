import Foundation
import Speech
import Translation
import FoundationModels
import SublyCaptions

/// Which engine can produce which output, for which language, on THIS Mac.
///
/// Everything the UI says about a language comes from here, built from runtime queries
/// only — never from a hardcoded list or an OS-version guess.
public actor CapabilityRegistry {

    // MARK: - Types

    public enum Engine: String, Sendable, Codable, Hashable {
        case speechTranscriber      // 30 locales, richer options
        case dictationTranscriber   // 54 locales, includes Hindi
        case extendedEngine         // optional download, everything else

        public var displayName: String {
            switch self {
            case .speechTranscriber:    return "Apple (built in)"
            case .dictationTranscriber: return "Apple (built in)"
            case .extendedEngine:       return "Downloaded model"
            }
        }
        public var requiresDownload: Bool { self == .extendedEngine }
        public var isApple: Bool { self != .extendedEngine }
    }

    /// Quality tiers.
    public enum Tier: Int, Sendable, Codable, Comparable, Hashable {
        case unsupported = 0, available = 1, verified = 2, flagship = 3
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .flagship, .verified: return ""
            case .available:           return "Quality not verified"
            case .unsupported:         return "Not supported"
            }
        }
        public var showsBadge: Bool { self == .available }
    }

    public enum AssetState: String, Sendable, Codable, Hashable {
        case installed, downloadable, downloading, unavailable
    }

    public struct LanguageCapability: Sendable, Codable, Hashable, Identifiable {
        public var id: String { languageTag }
        public var languageTag: String          // BCP-47, e.g. "hi-IN"
        public var languageCode: String         // e.g. "hi"
        public var displayName: String
        public var endonym: String
        public var region: Region
        public var engine: Engine
        public var effectiveLocale: String      // locale actually passed to the engine
        public var transcriptionTier: Tier
        public var assetState: AssetState
        /// Translation targets verified available from this language.
        public var translationTargets: [String]
        /// Targets whose assets are not provisioned for this app yet. Offered, but
        /// the UI says a one-time macOS download is needed.
        public var translationNeedsDownload: [String]
        public var translationTier: Tier
        public var romanizationTier: Tier
        public var scriptCode: String
        public var isRightToLeft: Bool

        public func supports(_ kind: OutputKind) -> Bool {
            switch kind {
            case .original:    return transcriptionTier > .unsupported
            case .translation:
                // A language "translated" into itself is not a translation. Targets
                // already exclude the source, so an empty list means no real target.
                return translationTier > .unsupported && !translationTargets.isEmpty
            case .romanized:   return romanizationTier > .unsupported
            }
        }

        /// Whether this specific target is a usable translation destination.
        public func canTranslate(to target: String) -> Bool {
            let t = target.split(separator: "-").first.map(String.init)?.lowercased() ?? target
            return t != languageCode && translationTargets.contains { $0.hasPrefix(t) }
        }
        public func tier(for kind: OutputKind) -> Tier {
            switch kind {
            case .original:    return transcriptionTier
            case .translation: return translationTier
            case .romanized:   return romanizationTier
            }
        }
    }

    public enum Region: String, Sendable, Codable, CaseIterable, Hashable {
        case southAsia = "South Asia"
        case eastAsia = "East & Southeast Asia"
        case europe = "Europe"
        case middleEastAfrica = "Middle East & Africa"
        case americas = "Americas"
        case other = "Other"
    }

    /// Whole-system readiness, for the status line and the unavailable-reason copy.
    public struct SystemState: Sendable {
        public var foundationModelAvailable: Bool
        public var foundationModelReason: String?
        public var speechTranscriberAvailable: Bool
        public var appleLanguageCount: Int
        public var extendedEngineInstalled: Bool
    }

    // MARK: - Stored

    private var cache: [LanguageCapability]?
    private var systemStateCache: SystemState?

    public init() {}

    // MARK: - Flagship / tier policy

    /// Launch-blocking languages, reviewed to the correction-time threshold.
    static let flagshipCodes: Set<String> = ["en", "hi"]
    /// Reviewed by a native speaker for transcription and translation.
    static let verifiedCodes: Set<String> = [
        "en", "hi", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "yue", "ru", "ar", "nl",
    ]

    /// Targets worth probing. English first — it is the guaranteed target.
    static let translationTargets = ["en", "es", "fr", "de", "it", "pt", "ja", "ko",
                                      "zh-Hans", "hi", "ar", "ru", "nl", "pl", "tr",
                                      "vi", "th", "id", "uk"]

    /// A language only reaches Flagship or Verified on the engine it was reviewed on.
    /// Running the flagship language on a different engine must not inherit the badge.
    static func transcriptionTier(for code: String, engine: Engine) -> Tier {
        switch engine {
        case .speechTranscriber:
            if flagshipCodes.contains(code) { return .flagship }
            if verifiedCodes.contains(code) { return .verified }
            return .available
        case .dictationTranscriber:
            // Reviewed for Hindi specifically; everything else is unverified here.
            if code == "hi" { return .flagship }
            return .available
        case .extendedEngine:
            return .available
        }
    }

    // MARK: - System state

    public func systemState() async -> SystemState {
        if let c = systemStateCache { return c }
        let model = SystemLanguageModel.default
        var reason: String?
        if case .unavailable(let r) = model.availability {
            switch r {
            case .deviceNotEligible:
                reason = "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                reason = "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
            case .modelNotReady:
                reason = "macOS is still downloading the Apple Intelligence model. Try again shortly."
            @unknown default:
                reason = "Apple Intelligence is unavailable on this Mac."
            }
        }
        let caps = await capabilities()
        let state = SystemState(
            foundationModelAvailable: model.isAvailable,
            foundationModelReason: reason,
            speechTranscriberAvailable: SpeechTranscriber.isAvailable,
            appleLanguageCount: Set(caps.filter { $0.engine.isApple }.map(\.languageCode)).count,
            extendedEngineInstalled: ExtendedEngineManager.shared.isInstalled
        )
        systemStateCache = state
        return state
    }

    public func invalidate() { cache = nil; systemStateCache = nil }

    // MARK: - Capability build

    public func capabilities() async -> [LanguageCapability] {
        if let c = cache { return c }

        let stLocales = await SpeechTranscriber.supportedLocales
        let stInstalled = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47).lowercased() })
        let dtLocales = await DictationTranscriber.supportedLocales
        let dtInstalled = Set(await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47).lowercased() })


        // One capability per distinct language, preferring SpeechTranscriber where it
        // covers the language. Region selection goes through the SAME routing helper
        // the transcriber uses, so the picker cannot advertise `en-ZA` while the
        // engine would actually run `en-US`.
        var byLanguage: [String: (engine: Engine, locale: Locale, installed: Bool)] = [:]

        func choose(_ code: String, from locales: [Locale], installedSet: Set<String>,
                    engine: Engine) {
            let candidates = locales.filter {
                $0.language.languageCode?.identifier.lowercased() == code
            }
            guard !candidates.isEmpty else { return }
            // Prefer an already-installed region; otherwise use the routing helper's
            // preference order (asked-for → this Mac's region → conventional default).
            let installedCandidates = candidates.filter {
                installedSet.contains($0.identifier(.bcp47).lowercased())
            }
            let pool = installedCandidates.isEmpty ? candidates : installedCandidates
            guard let chosen = TranscriptionService.pick(pool, Locale(identifier: code))
                ?? pool.first else { return }
            byLanguage[code] = (engine, chosen,
                                installedSet.contains(chosen.identifier(.bcp47).lowercased()))
        }

        let dtCodes = Set(dtLocales.compactMap { $0.language.languageCode?.identifier.lowercased() })
        let stCodes = Set(stLocales.compactMap { $0.language.languageCode?.identifier.lowercased() })
        for code in dtCodes {
            choose(code, from: dtLocales, installedSet: dtInstalled, engine: .dictationTranscriber)
        }
        for code in stCodes {
            choose(code, from: stLocales, installedSet: stInstalled, engine: .speechTranscriber)
        }

        // Translation availability is ~1250 separate framework round-trips (68 languages
        // x 19 candidate targets). Run them concurrently: measured 1.40s -> ~0.2s, and
        // this probe is what gates the first usable screen.
        let translation = await withTaskGroup(
            of: (String, [String], [String]).self,
            returning: [String: (targets: [String], needsDownload: [String])].self
        ) { group in
            for code in byLanguage.keys {
                group.addTask {
                    let availability = LanguageAvailability()
                    let src = Locale.Language(identifier: code)
                    var targets: [String] = []
                    var needsDownload: [String] = []
                    for candidate in Self.translationTargets where candidate != code {
                        switch await availability.status(
                            from: src, to: Locale.Language(identifier: candidate)) {
                        case .installed:
                            targets.append(candidate)
                        case .supported:
                            targets.append(candidate)
                            needsDownload.append(candidate)
                        default:
                            break
                        }
                    }
                    return (code, targets, needsDownload)
                }
            }
            var map: [String: (targets: [String], needsDownload: [String])] = [:]
            for await (code, targets, needsDownload) in group {
                map[code] = (targets, needsDownload)
            }
            return map
        }

        var out: [LanguageCapability] = []

        for (code, entry) in byLanguage {
            let profile = ScriptProfile.forLanguage(code)
            let tier = Self.transcriptionTier(for: code, engine: entry.engine)

            // Translation: verify the actual pair on this Mac.
            // `.installed` means ready now; `.supported` means macOS has the pair but
            // has not provisioned it for this app yet — offerable, with a one-time
            // download the first time it runs. Only `.unsupported` is withheld.
            let targets = translation[code]?.targets ?? []
            let needsDownload = translation[code]?.needsDownload ?? []
            let translationTier: Tier = targets.isEmpty
                ? .unsupported
                : (Self.verifiedCodes.contains(code) ? .verified : .available)

            // Romanization: only for non-Latin scripts that clear the gate.
            var romanTier = Tier.unsupported
            if profile.romanizable {
                if code == "hi" { romanTier = .flagship }
                else if Romanizer.isReviewed(code) { romanTier = .verified }
                else if Romanizer.isUnreliable(code) { romanTier = .available }
                else { romanTier = .available }
            }

            out.append(LanguageCapability(
                languageTag: entry.locale.identifier(.bcp47),
                languageCode: code,
                displayName: Self.displayName(code),
                endonym: Self.endonym(code),
                region: Self.region(for: code),
                engine: entry.engine,
                effectiveLocale: entry.locale.identifier(.bcp47),
                transcriptionTier: tier,
                assetState: entry.installed ? .installed : .downloadable,
                translationTargets: targets,
                translationNeedsDownload: needsDownload,
                translationTier: translationTier,
                romanizationTier: romanTier,
                scriptCode: profile.scriptCode,
                isRightToLeft: profile.isRightToLeft
            ))
        }

        // Languages the Apple stack cannot do at all, offered via the optional engine.
        let appleCodes = Set(out.map(\.languageCode))
        // Translation still goes through Apple's Translation, which knows few of these
        // (not Marathi, Bengali, Tamil, Telugu, Persian, Swahili, Urdu or Gujarati), so
        // ask it. Offering "English translation" for all of them failed after a whole
        // transcription.
        let extra = ExtendedEngineManager.additionalLanguages.subtracting(appleCodes)
        let translatable: [String: (targets: [String], needsDownload: [String])] = await withTaskGroup(
            of: (String, [String], [String]).self) { group in
            for code in extra {
                group.addTask {
                    let availability = LanguageAvailability()
                    switch await availability.status(from: Locale.Language(identifier: code),
                                                     to: Locale.Language(identifier: "en")) {
                    case .installed: return (code, ["en"], [])
                    case .supported: return (code, ["en"], ["en"])
                    default:         return (code, [], [])
                    }
                }
            }
            var map: [String: (targets: [String], needsDownload: [String])] = [:]
            for await (code, targets, needsDownload) in group { map[code] = (targets, needsDownload) }
            return map
        }
        for code in ExtendedEngineManager.additionalLanguages where !appleCodes.contains(code) {
            let profile = ScriptProfile.forLanguage(code)
            out.append(LanguageCapability(
                languageTag: code,
                languageCode: code,
                displayName: Self.displayName(code),
                endonym: Self.endonym(code),
                region: Self.region(for: code),
                engine: .extendedEngine,
                effectiveLocale: code,
                transcriptionTier: .available,
                // Check the pack that would actually serve THIS language. Installing
                // only the Hindi pack must not mark Tamil "Ready".
                // Any general model will do, or one made for this language.
                assetState: ExtendedEngineManager.allPacks.contains {
                    $0.serves(code) && ExtendedEngineManager.shared.isInstalled($0)
                } ? .installed : .downloadable,
                translationTargets: translatable[code]?.targets ?? [],
                translationNeedsDownload: translatable[code]?.needsDownload ?? [],
                translationTier: (translatable[code]?.targets.isEmpty ?? true) ? .unsupported : .available,
                romanizationTier: profile.romanizable ? .available : .unsupported,
                scriptCode: profile.scriptCode,
                isRightToLeft: profile.isRightToLeft
            ))
        }

        out.sort { a, b in
            if a.transcriptionTier != b.transcriptionTier { return a.transcriptionTier > b.transcriptionTier }
            return a.displayName < b.displayName
        }
        cache = out
        return out
    }

    public func capability(forLanguage code: String) async -> LanguageCapability? {
        let all = await capabilities()
        let want = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code
        return all.first { $0.languageCode == want }
    }

    public func grouped() async -> [(Region, [LanguageCapability])] {
        let all = await capabilities()
        return Region.allCases.compactMap { region in
            let items = all.filter { $0.region == region }
            return items.isEmpty ? nil : (region, items)
        }
    }

    // MARK: - Naming

    public static func displayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }
    public static func endonym(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized ?? ""
    }
    public static func region(for code: String) -> Region {
        switch code {
        case "hi","bn","ur","pa","mr","gu","ta","te","kn","ml","ne","si","as","or","sd","bho","kok":
            return .southAsia
        case "zh","yue","wuu","ja","ko","vi","th","id","ms","fil","tl","my","km","lo","jv","su":
            return .eastAsia
        case "en","es","pt","fr","de","it","nl","ru","uk","pl","cs","sk","ro","hu","bg","sr",
             "hr","el","sv","nb","no","da","fi","ca","lt","lv","et","sl","is","ga","mt","sq","mk","be":
            return .europe
        case "ar","he","fa","tr","sw","am","ha","yo","af","ig","zu","xh","so","ti","ps","ku","az","hy","ka":
            return .middleEastAfrica
        default: return .other
        }
    }
}
