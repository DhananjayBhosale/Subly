import Testing
import Foundation
@testable import SublyEngine
@testable import SublyCaptions

/// The engine picker's contents. The user reported Apex missing from the menu and
/// Whisper not selectable; neither could be checked automatically because the list was
/// built inline in a SwiftUI view.
@Suite("Engine options")
struct EngineOptionTests {

    private func names(_ lang: String, appleHandles: Bool = true,
                       installed: Set<String> = ["hindi2hinglish-apex-q5",
                                                 "whisper-large-v3-turbo-q5"]) -> [String] {
        EngineOption.all(languageCode: lang, appleHandles: appleHandles,
                         appleEngineName: "Dictation", installedPackIDs: installed)
            .map(\.name)
    }

    @Test("Hindi leads with Automatic, Apple and Apex, then the general models")
    func hindiOffersAll() {
        let n = names("hi")
        #expect(n.prefix(3) == ["Automatic", "Apple (built in)", "Apex"], "got \(n)")
        #expect(n.contains("Whisper"))
    }

    @Test("Apex is offered only for the languages it was tuned for")
    func apexIsHindiOnly() {
        #expect(names("hi").contains("Apex"))
        for other in ["en", "es", "ja", "ar", "ru", "ko"] {
            #expect(!names(other).contains("Apex"), "Apex wrongly offered for \(other)")
        }
    }

    @Test("Whisper is offered for every language, including ones Apple cannot do")
    func whisperIsUniversal() {
        for lang in ["hi", "en", "es", "ja", "ar", "af", "sq", "am"] {
            #expect(names(lang).contains("Whisper"), "Whisper missing for \(lang)")
        }
        // Apple absent: still offered, and Apple is not listed.
        let n = names("af", appleHandles: false)
        #expect(n.contains("Whisper"))
        #expect(!n.contains("Apple (built in)"))
    }

    @Test("Exactly one option is marked as the recommendation")
    func oneRecommendation() {
        for lang in ["hi", "en", "ja", "af"] {
            let opts = EngineOption.all(languageCode: lang, appleHandles: true,
                                        appleEngineName: "Speech",
                                        installedPackIDs: [])
            #expect(opts.filter(\.isRecommended).count == 1, "\(lang)")
        }
    }

    @Test("A model that is not downloaded is still listed, flagged for download")
    func notInstalledStillListed() {
        let opts = EngineOption.all(languageCode: "hi", appleHandles: true,
                                    appleEngineName: "Dictation", installedPackIDs: [])
        #expect(opts.map(\.name).contains("Apex"))
        #expect(opts.map(\.name).contains("Whisper"))
        let packOptions = opts.filter { $0.packID != nil }
        #expect(packOptions.count == ExtendedEngineManager.allPacks.filter { $0.serves("hi") }.count)
        #expect(packOptions.filter(\.needsDownload).count == packOptions.count)
    }

    @Test("Every option has a distinct, stable identity for the picker's tags")
    func identitiesAreDistinct() {
        // A SwiftUI Picker matches its selection by tag; duplicate or unstable tags
        // make a row impossible to select.
        let opts = EngineOption.all(languageCode: "hi", appleHandles: true,
                                    appleEngineName: "Dictation",
                                    installedPackIDs: ["whisper-large-v3-turbo-q5"])
        #expect(Set(opts.map(\.id)).count == opts.count)
        // A tag must survive the round-trip through storage, or a saved choice comes
        // back as something the menu does not contain and cannot show as selected.
        for o in opts {
            let restored = TranscriptionService.EngineChoice(storageValue: o.choice.storageValue)
            #expect(restored == o.choice, "\(o.name) did not round-trip")
        }
    }

    @Test("The real model identity is exposed for the packs")
    func modelIdentityShown() {
        let opts = EngineOption.all(languageCode: "hi", appleHandles: true,
                                    appleEngineName: "Dictation",
                                    installedPackIDs: ["hindi2hinglish-apex-q5"])
        let apex = opts.first { $0.name == "Apex" }
        let whisper = opts.first { $0.name == "Whisper" }
        #expect(apex?.modelIdentity?.contains("Hindi2Hinglish") == true)
        #expect(whisper?.modelIdentity?.contains("large-v3-turbo") == true)
    }
}

/// The model catalogue: what is offered, what is recommended, and that the recommendation
/// is never something the user cannot run.
@Suite("Model catalogue")
struct ModelCatalogueTests {

    private var all: [ExtendedEngineManager.ModelPack] { ExtendedEngineManager.allPacks }

    @Test("Every pack has a distinct id, a real URL and a checksum")
    func packsAreWellFormed() {
        #expect(Set(all.map(\.id)).count == all.count)
        for p in all {
            #expect(p.sha256.count == 64, "\(p.id) checksum looks wrong")
            #expect(p.downloadBytes > 0, "\(p.id) has no size")
            #expect(p.url.absoluteString.hasPrefix("https://"), "\(p.id) is not https")
            if let preset = p.dtwPreset { #expect(!preset.isEmpty, "\(p.id) has an empty alignment preset") }
            #expect(p.approximateRAMBytes >= p.downloadBytes,
                    "\(p.id) claims to need less memory than its own file")
        }
    }

    @Test("A specialised model is recommended only with evidence; otherwise the general one")
    func recommendations() {
        #expect(ExtendedEngineManager.recommended(for: "hi").pack.id == "hindi2hinglish-apex-q5")
        for other in ["en", "es", "ja", "ar", "ru", "af", "ta", "sv", "de", "zh"] {
            let r = ExtendedEngineManager.recommended(for: other)
            let backed = all.first { $0.specialisedFor?.contains(other) == true && $0.evidence != nil }
            #expect(r.pack.id == (backed ?? ExtendedEngineManager.generalPack).id,
                    "\(other) recommended \(r.pack.id)")
            #expect(!r.reason.isEmpty)
        }
    }

    @Test("Every language is passed to whisper.cpp under a code it knows")
    func whisperCodesAreKnown() {
        // whisper-cli refuses a code outside its table; "fil" and "jv" used to be sent.
        let known: Set<String> = ["en","zh","de","es","ru","ko","fr","ja","pt","tr","pl","ca","nl","ar",
            "sv","it","id","hi","fi","vi","he","uk","el","ms","cs","ro","da","hu","ta","no","th","ur","hr",
            "bg","lt","la","mi","ml","cy","sk","te","fa","lv","bn","sr","az","sl","kn","et","mk","br","eu",
            "is","hy","ne","mn","bs","kk","sq","sw","gl","mr","pa","si","km","sn","yo","so","af","oc","ka",
            "be","tg","sd","gu","am","yi","lo","uz","fo","ht","ps","tk","nn","mt","sa","lb","my","bo","tl",
            "mg","as","tt","haw","ln","ha","ba","jw","su","yue"]
        let general = ExtendedEngineManager.generalPack
        for code in ExtendedEngineManager.additionalLanguages {
            let sent = ExtendedEngineManager.whisperCode(for: code, pack: general)
            #expect(known.contains(sent), "\(code) is sent as \(sent)")
        }
        for pack in all where !pack.isGeneral {
            for code in pack.specialisedFor ?? [] {
                let sent = ExtendedEngineManager.whisperCode(for: code, pack: pack)
                #expect(known.contains(sent), "\(pack.id) sends \(code) as \(sent)")
            }
        }
        #expect(ExtendedEngineManager.whisperCode(for: "fil", pack: general) == "tl")
        #expect(ExtendedEngineManager.whisperCode(for: "jv", pack: general) == "jw")
        #expect(ExtendedEngineManager.whisperCode(for: "nb", pack: general) == "no")
        // Cantonese has its own token only in large-v3's vocabulary.
        #expect(ExtendedEngineManager.whisperCode(for: "yue", pack: general) == "yue")
        #expect(ExtendedEngineManager.whisperCode(for: "yue", pack: ExtendedEngineManager.largeV3Pack) == "yue")
        for small in [ExtendedEngineManager.mediumPack, ExtendedEngineManager.smallPack, ExtendedEngineManager.basePack] {
            #expect(ExtendedEngineManager.whisperCode(for: "yue", pack: small) == "zh", "\(small.id) would translate Cantonese")
        }
    }

    @Test("A model trained without timestamps still has word alignment")
    func noTimestampModelsAlignWords() {
        // With "-nt" the only word times are DTW's; without a preset there would be none.
        for p in all where p.noTimestamps {
            #expect(p.dtwPreset != nil, "\(p.id) runs with -nt and no alignment preset")
        }
    }

    @Test("From English, only the Hinglish model is suggested from another language")
    func elsewhereIsOnlyHinglish() {
        let ids = EngineOption.specialisedElsewhere(languageCode: "en").map(\.pack.id)
        #expect(ids == ["hindi2hinglish-apex-q5"], "got \(ids)")
    }

    @Test("Language packs say what they are, under which licence, and are told apart by name")
    func languagePacksAreDescribed() {
        #expect(Set(all.map(\.displayName)).count == all.count, "two packs share a name")
        // Saved under the same name, installing one would make another look installed.
        let saved = all.map { ExtendedEngineManager.shared.modelURL($0).lastPathComponent }
        #expect(Set(saved).count == all.count, "two packs would be saved as the same file")
        for p in ExtendedEngineManager.languagePacks {
            #expect(p.identity?.isEmpty == false, "\(p.id) has no identity")
            #expect(p.license?.isEmpty == false, "\(p.id) has no licence")
            #expect(p.blurb?.isEmpty == false, "\(p.id) has no description")
            #expect(p.url.host == "huggingface.co", "\(p.id) is not on Hugging Face")
            #expect(p.url.lastPathComponent == p.filename, "\(p.id) URL and filename disagree")
            #expect(p.specialisedFor?.isEmpty == false, "\(p.id) is for no language")
        }
    }

    @Test("A smaller model is always available as an alternative to the recommendation")
    func aLighterChoiceAlwaysExists() {
        // Someone short of disk or memory must have somewhere to go.
        for lang in ["hi", "en", "ja", "af"] {
            let opts = EngineOption.all(languageCode: lang, appleHandles: true,
                                        appleEngineName: "Speech", installedPackIDs: [])
            let best = ExtendedEngineManager.recommended(for: lang).pack
            let lighter = ExtendedEngineManager.allPacks.filter {
                $0.serves(lang) && $0.downloadBytes < best.downloadBytes
            }
            #expect(!lighter.isEmpty, "no lighter model offered for \(lang)")
            #expect(opts.filter { $0.isRecommended }.count == 1,
                    "\(lang) should mark exactly one recommendation")
        }
    }

    @Test("Every general model is offered for every language")
    func generalModelsAreUniversal() {
        for lang in ["hi", "en", "zh", "af", "ta"] {
            for pack in ExtendedEngineManager.allPacks where pack.isGeneral {
                #expect(pack.serves(lang), "\(pack.id) missing for \(lang)")
            }
        }
    }

    @Test("A specialised model is never offered outside its languages")
    func specialisedModelsAreRestricted() {
        for pack in ExtendedEngineManager.allPacks where !pack.isGeneral {
            let trained = pack.specialisedFor ?? []
            #expect(!trained.isEmpty, "\(pack.id) is specialised for nothing")
            for other in ["en", "es", "ja", "de"] where !trained.contains(other) {
                #expect(!pack.serves(other), "\(pack.id) wrongly offered for \(other)")
            }
        }
    }

    @Test("Alignment presets match what whisper.cpp accepts")
    func dtwPresetsAreValid() {
        // A preset the runtime does not know means no word timings at all.
        let valid: Set<String> = ["tiny", "tiny.en", "base", "base.en", "small", "small.en",
                                  "medium", "medium.en", "large.v1", "large.v2", "large.v3",
                                  "large.v3.turbo"]
        for p in all {
            if let preset = p.dtwPreset {
                #expect(valid.contains(preset), "\(p.id) has preset \(preset)")
            }
        }
        // The general packs always align words; only a model with no preset may go without.
        for p in all where p.isGeneral { #expect(p.dtwPreset != nil, "\(p.id) lost its preset") }
    }
}

@Suite("Whisper output parsing")
struct WhisperOutputParsingTests {
    @Test("Reads the detected language and its probability")
    func detectedLanguage() {
        let log = "whisper_full_with_state: auto-detected language: hi (p = 0.773177)\nother line"
        let result = ExtendedEngineManager.detectedLanguage(in: log)
        #expect(result?.code == "hi")
        #expect(abs((result?.probability ?? 0) - 0.773177) < 1e-6)
        #expect(ExtendedEngineManager.detectedLanguage(in: "no detection here") == nil)
    }

    @Test("Progress comes from the last word timestamp in a chunk")
    func progressTimestamp() {
        let chunk = "[00:00:28.100 --> 00:00:28.400]  hai\n[00:01:02.250 --> 00:01:02.900]  to"
        #expect(abs((ExtendedEngineManager.lastTimestamp(in: chunk) ?? 0) - 62.9) < 1e-9)
        #expect(ExtendedEngineManager.lastTimestamp(in: "partial line [00:00") == nil)
        #expect(ExtendedEngineManager.clock(62.9) == "1:03")
        #expect(ExtendedEngineManager.clock(3725) == "1:02:05")
    }
}

@Suite("Spelling fixer safety")
struct RefinementSafetyTests {
    @Test("An English sentence in place of a Hinglish line is rejected")
    func rejectsRewrite() {
        let original = "arre mujhe bataiye ki phone kahaan hai"
        #expect(!RefinementService.isPlausible("Hey please tell me where the phone is",
                                               original: original, requireLatinScript: true))
        #expect(!RefinementService.isPlausible("Please leave the phone here, as it is not yours",
                                               original: "phone yahin chhod do kyunki ye tumhara nahin hai",
                                               requireLatinScript: true))
    }

    @Test("Spelling and punctuation fixes are accepted")
    func acceptsFixes() {
        #expect(RefinementService.isPlausible("Arre, mujhe bataiye ki phone kahan hai?",
                                              original: "arre mujhe bataiye ki phone kahaan hai",
                                              requireLatinScript: true))
        #expect(RefinementService.isPlausible("Hain stress mein kitni bhi",
                                              original: "Hain stres men kitanee bhee",
                                              requireLatinScript: true))
    }

    @Test("A change of script is rejected in both directions")
    func rejectsScriptChange() {
        #expect(!RefinementService.isPlausible("How much stress are you in", original: "आप कितने तनाव में हैं"))
        #expect(!RefinementService.isPlausible("आप कैसे हैं", original: "aap kaise hain"))
    }
}

@Suite("Spelling polish safety")
struct PolishSafetyTests {
    @Test("A one-word line translated by the model is refused")
    func refusesShortTranslation() {
        #expect(!RefinementService.isPlausible("Yes.", original: "Desu.", requireLatinScript: true))
        #expect(RefinementService.isPlausible("hum", original: "ham", requireLatinScript: true))
    }

    @Test("A line that comes back several words short is refused, not a crash")
    func shortReplyDoesNotCrash() {
        let original = (1...21).map { "word\($0)" }.joined(separator: " ")
        let reply = (1...18).map { "word\($0)" }.joined(separator: " ")
        _ = RefinementService.keepsTheWords(reply, original: original)
    }
}
