import Foundation

/// Models trained for one language (or a few), each a single GGML file that the bundled
/// whisper.cpp runs as it is. Kept apart from the six general packs so the catalogue can
/// grow without burying them.
///
/// Every entry was checked against its Hugging Face repository: exact file size and
/// SHA-256 from the repository's own metadata, licence from its model card. A model is
/// recommended over general Whisper only when `evidence` says why, with the source.
/// The research behind each choice is in docs/MODEL_RESEARCH.md.
extension ExtendedEngineManager {

    static func languagePack(id: String, name: String, languages: [String],
                             repo: String, file: String, bytes: Int64, sha256: String,
                             quant: String, dtw: String?, ramBytes: Int64, speed: Double,
                             blurb: String, detail: String, license: String,
                             evidence: String? = nil, whisperLanguage: [String: String]? = nil,
                             romanized: Bool = false, noTimestamps: Bool = false) -> ModelPack {
        var pack = ModelPack(
            id: id, displayName: name, detail: detail, filename: file,
            downloadBytes: bytes, sha256: sha256,
            url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!,
            dtwPreset: dtw, emitsRomanized: romanized, languages: languages,
            approximateRAMBytes: ramBytes, relativeSpeed: speed, specialisedFor: languages)
        pack.evidence = evidence
        pack.whisperLanguage = whisperLanguage
        pack.identity = "\(repo) · \(quant)"
        pack.blurb = blurb
        pack.license = license
        pack.localFilename = "\(id).bin"
        pack.noTimestamps = noTimestamps
        return pack
    }

    /// Best first within each language: when several are installed for one language,
    /// automatic picks the first.
    public static let languagePacks: [ModelPack] = english + chinese + cantonese + korean + european + europeanMore + southeastAsian + middleEastern + southAsian + moreLanguages

    // MARK: English

    /// OpenAI's English-only Whisper models. Its model card: the .en models "tend to
    /// perform better" on English than the multilingual model of the same size, most
    /// for base and least for medium. None is shown to beat large-v3-turbo, so none is
    /// recommended over it; they are the lighter English choices for smaller Macs.
    /// distil-large-v3.5 was considered and left out: about turbo's accuracy, 1.5x the
    /// speed, but published only at full precision (1.5 GB) and with no alignment
    /// preset, so word timings would be coarser. See docs/MODEL_RESEARCH.md.
    static let english: [ModelPack] = [
        languagePack(
            id: "whisper-medium-en-q5", name: "Whisper Medium English", languages: ["en"],
            repo: "ggerganov/whisper.cpp", file: "ggml-medium.en-q5_0.bin",
            bytes: 539_225_533, sha256: "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0",
            quant: "medium.en · q5_0", dtw: "medium.en", ramBytes: 900_000_000, speed: 3,
            blurb: "English only. A little more accurate on English than Whisper Medium.",
            detail: "OpenAI Whisper medium.en, trained on English alone.",
            license: "MIT"),
        languagePack(
            id: "whisper-small-en-q5", name: "Whisper Small English", languages: ["en"],
            repo: "ggerganov/whisper.cpp", file: "ggml-small.en-q5_1.bin",
            bytes: 190_098_681, sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
            quant: "small.en · q5_1", dtw: "small.en", ramBytes: 400_000_000, speed: 12,
            blurb: "English only. Small and quick, and better on English than Whisper Small.",
            detail: "OpenAI Whisper small.en, trained on English alone.",
            license: "MIT"),
        languagePack(
            id: "whisper-base-en-q5", name: "Whisper Base English", languages: ["en"],
            repo: "ggerganov/whisper.cpp", file: "ggml-base.en-q5_1.bin",
            bytes: 59_721_011, sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
            quant: "base.en · q5_1", dtw: "base.en", ramBytes: 200_000_000, speed: 24,
            blurb: "English only. Tiny, for a Mac very short on space. Makes more mistakes.",
            detail: "OpenAI Whisper base.en, trained on English alone.",
            license: "MIT"),
    ]

    // MARK: Chinese

    /// Mandarin. Belle (BELLE-2, Apache-2.0) is large-v3(-turbo) fine-tuned on about
    /// 10,000 hours of Mandarin, with punctuation in its labels. Breeze (MediaTek
    /// Research, Apache-2.0) is large-v2 fine-tuned for Taiwanese Mandarin and for
    /// Mandarin mixed with English, and writes Traditional characters. Both q5_0 files
    /// are quantisations of the makers' own weights, each matched byte for byte by a
    /// second, separate conversion.
    static let chinese: [ModelPack] = [
        languagePack(
            id: "belle-turbo-zh-q5", name: "Belle Mandarin", languages: ["zh"],
            repo: "uosx/Belle-whisper-large-v3-turbo-zh-ggml-quantized", file: "ggml-belle-large-v3-turbo-zh-q5_0.bin",
            bytes: 574_041_195, sha256: "bab0d61935b3f75e5435217eadfb1fceb6bcb09751b025a232e76ed33107747f",
            quant: "BELLE-2 large-v3-turbo-zh · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Mandarin, in Simplified characters with punctuation. As fast as the default model.",
            detail: "Belle-whisper-large-v3-turbo-zh: Whisper turbo fine-tuned on Mandarin by BELLE-2.",
            license: "Apache-2.0",
            evidence: "Its makers report a third to two thirds fewer character errors than Whisper large-v3-turbo on five Mandarin test sets, with punctuation added."),
        languagePack(
            id: "belle-large-zh-punct-q5", name: "Belle Mandarin Large", languages: ["zh"],
            repo: "uosx/Belle-whisper-large-v3-zh-punct-ggml", file: "ggml-belle-large-v3-zh-punct-q5_0.bin",
            bytes: 1_081_140_203, sha256: "8ff85b4faa67966c500de7b96f24e0cf1f534cb7f510c3255cf807627e854268",
            quant: "BELLE-2 large-v3-zh-punct · q5_0", dtw: "large.v3", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Mandarin, Simplified with punctuation. A little more accurate than Belle Mandarin, and much slower.",
            detail: "Belle-whisper-large-v3-zh-punct: Whisper large-v3 fine-tuned on Mandarin by BELLE-2.",
            license: "Apache-2.0"),
        languagePack(
            id: "breeze-asr-25-q5", name: "Breeze Taiwan", languages: ["zh"],
            repo: "tsuzuri-app/Breeze-ASR-25-ggml", file: "ggml-breeze-asr-25-q5_0.bin",
            bytes: 1_080_732_091, sha256: "f51573bd6ef9b1fac0bd09a1652eda58a1a638d824a08771ccdee1102fe5990a",
            quant: "MediaTek Breeze-ASR-25 · q5_0", dtw: "large.v2", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Taiwanese Mandarin in Traditional characters, and Mandarin mixed with English. Slow.",
            detail: "Breeze-ASR-25 by MediaTek Research: Whisper large-v2 fine-tuned for Taiwan and Mandarin–English mixing.",
            license: "Apache-2.0",
            evidence: "Its paper reports about half the errors of Whisper large-v3 on Mandarin mixed with English, and fewer on Taiwanese Mandarin."),
    ]

    // MARK: Cantonese

    /// Whisper small fine-tuned on Cantonese by its author, who publishes the GGML file.
    /// Writes colloquial Cantonese in Traditional characters. large-v2-era vocabularies
    /// have no Cantonese token — "-l yue" lands on <|translate|> — so it runs as "zh".
    static let cantonese: [ModelPack] = [
        languagePack(
            id: "whisper-small-cantonese-f16", name: "Whisper Cantonese", languages: ["yue"],
            repo: "alvanlii/whisper-small-cantonese", file: "ggml-model.bin",
            bytes: 487_601_967, sha256: "ab6ddf83921733fd96b0bbb4850ae57c330a1049ab35252bf36b1d339835d2bf",
            quant: "small · f16", dtw: "small", ramBytes: 800_000_000, speed: 12,
            blurb: "Cantonese, written as it is spoken, in Traditional characters with punctuation.",
            detail: "alvanlii/whisper-small-cantonese: Whisper small fine-tuned on Cantonese.",
            license: "Apache-2.0",
            evidence: "Its maker reports 7.9% character errors on Common Voice Cantonese; general Whisper large-v3 scores 12.9% on the same test in an independent benchmark.",
            whisperLanguage: ["yue": "zh"]),
    ]

    // MARK: Korean

    /// Whisper turbo fine-tuned on Korean read speech. The evidence is thin — about 16%
    /// word errors against 24%, on an unnamed test set — so it is offered, not
    /// recommended.
    static let korean: [ModelPack] = [
        languagePack(
            id: "turbo-korean-q5", name: "Whisper Korean", languages: ["ko"],
            repo: "JoaoZaokk/whisper-large-v3-turbo-korean-ggml", file: "ggml-whisper-large-v3-turbo-korean-q5_0.bin",
            bytes: 574_041_195, sha256: "fa112c2285b8b61525cf87b1693bfab5fc21ff511287e2b586974a7b58ca9d7f",
            quant: "royshilkrot large-v3-turbo-korean · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Korean. Trained on read speech, so try it on one of your own videos first.",
            detail: "whisper-large-v3-turbo-korean: Whisper turbo fine-tuned on Korean read speech.",
            license: "Apache-2.0"),
    ]

    // MARK: Europe

    /// Where a fine-tune has published evidence of beating general Whisper. For Spanish,
    /// Italian, Portuguese, Dutch, Polish and other large European languages, general
    /// Whisper already scores 2.5–5.5% WER on FLEURS and no fine-tune has broad
    /// evidence of doing better, so none is offered (docs/MODEL_RESEARCH.md).
    static let european: [ModelPack] = [
        languagePack(
            id: "kb-whisper-large-sv-q5", name: "KB-Whisper Swedish", languages: ["sv"],
            repo: "KBLab/kb-whisper-large", file: "ggml-model-q5_0.bin",
            bytes: 1_081_140_203, sha256: "6d2863812d7410322bb7d8647a5c7260761300fa946714c9ed66d22bb30bcb19",
            quant: "large-v3 · q5_0", dtw: "large.v3", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Swedish, from the National Library of Sweden. Cased and punctuated. Slow.",
            detail: "KB-Whisper Large by KBLab: Whisper large-v3 trained on 50,000 hours of Swedish.",
            license: "Apache-2.0",
            evidence: "Its makers report 5.4% word errors on FLEURS Swedish, against 7.8% for OpenAI Whisper large-v3."),
        languagePack(
            id: "nb-whisper-large-q5", name: "NB-Whisper Norwegian", languages: ["nb", "no", "nn"],
            repo: "NbAiLab/nb-whisper-large", file: "ggml-model-q5_0.bin",
            bytes: 1_081_140_203, sha256: "feb5951ae694a62cfeb81fb501f6cfa8cc50d96bcddb1e4e8215f7006bac23a2",
            quant: "large-v3 · q5_0", dtw: "large.v3", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Norwegian, from the National Library of Norway. Bokmål and Nynorsk, cased and punctuated. Slow.",
            detail: "NB-Whisper Large by the National Library of Norway: Whisper large-v3 trained on Norwegian.",
            license: "Apache-2.0",
            evidence: "Its makers' paper reports 6.6% word errors on FLEURS Bokmål, against 10.4% for OpenAI Whisper large-v3.",
            whisperLanguage: ["nb": "no"]),
        languagePack(
            id: "primeline-turbo-de-q5", name: "Whisper German", languages: ["de"],
            repo: "cstr/whisper-large-v3-turbo-german-ggml", file: "ggml-model-q5_0.bin",
            bytes: 574_041_195, sha256: "15e92e3db0993c52fffa781513eec9253475331c1be808f8fb409285c9d9d030",
            quant: "primeline large-v3-turbo-german · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "German. As fast as the default model.",
            detail: "primeline/whisper-large-v3-turbo-german: Whisper turbo fine-tuned on German.",
            license: "Apache-2.0",
            evidence: "Its makers report about a fifth fewer word errors than OpenAI Whisper large-v3 across four German test sets."),
        languagePack(
            id: "podlodka-turbo-ru-q5", name: "Whisper Russian", languages: ["ru"],
            repo: "JoaoZaokk/whisper-podlodka-turbo-ggml", file: "ggml-whisper-podlodka-turbo-q5_0.bin",
            bytes: 574_041_195, sha256: "7e58e89ea5ff49edf330649caa4d7a0895a3d3254fecd9c1cf63b27dd8fcf53d",
            quant: "bond005 whisper-podlodka-turbo · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Russian, with proper punctuation and capitals. As fast as the default model.",
            detail: "bond005/whisper-podlodka-turbo: Whisper turbo fine-tuned on Russian.",
            license: "Apache-2.0",
            evidence: "Its maker reports fewer word errors than Whisper turbo on all seven Russian test sets, e.g. 5.2% against 6.6% on Common Voice."),
        languagePack(
            id: "turbo-hr-parla-q5", name: "Whisper Croatian", languages: ["hr"],
            repo: "JoaoZaokk/whisper-large-v3-turbo-hr-parla-ggml", file: "ggml-whisper-large-v3-turbo-hr-parla-q5_0.bin",
            bytes: 574_041_195, sha256: "945a3d2fe71af09fa170b36832821b7cfec0e1b600e62aac847dba2b16f2942c",
            quant: "GoranS large-v3-turbo-hr-parla · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Croatian. As fast as the default model.",
            detail: "GoranS/whisper-large-v3-turbo-hr-parla: Whisper turbo fine-tuned on Croatian parliament speech.",
            license: "Apache-2.0",
            evidence: "Its maker reports 8.7% word errors on FLEURS Croatian against 12.7% for Whisper turbo; an independent benchmark puts turbo at 12.5%."),
        languagePack(
            id: "whisper-large-fr-q5", name: "Whisper French", languages: ["fr"],
            repo: "bofenghuang/whisper-large-v3-french", file: "ggml-model-q5_0.bin",
            bytes: 1_081_140_203, sha256: "d8da7cb6cdadfac47829abf46fe8cd36fcfef06db5601bfd8acbcd40579010a5",
            quant: "large-v3-french · q5_0", dtw: "large.v3", ramBytes: 1_900_000_000, speed: 1,
            blurb: "French, with punctuation and numbers written as digits. Slow.",
            detail: "bofenghuang/whisper-large-v3-french: Whisper large-v3 fine-tuned on French.",
            license: "MIT"),
        languagePack(
            id: "whisper-large-lv-q5", name: "Whisper Latvian", languages: ["lv"],
            repo: "AiLab-IMCS-UL/whisper-large-v3-lv-late-cv19", file: "ggml-model-q5_0.bin",
            bytes: 1_081_140_203, sha256: "cfbe8ad85fb44ee84ba577948c01c8157c41c0f53c1503184cbcf41fc169080c",
            quant: "large-v3-lv · q5_0", dtw: "large.v3", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Latvian, cased and punctuated, from the University of Latvia. Slow.",
            detail: "AiLab IMCS UL whisper-large-v3-lv: Whisper large-v3 fine-tuned on Latvian.",
            license: "Apache-2.0"),
    ]

    /// Lighter and further European choices: KBLab's and the Norwegian library's own
    /// medium and small models, Finnish and Turkish. Edda (Danish) was tested and taken
    /// out: its GGML copy repeats one word over and over, with or without -nt.
    static let europeanMore: [ModelPack] = [
        languagePack(
            id: "kb-whisper-medium-sv-q5", name: "KB-Whisper Swedish Medium", languages: ["sv"],
            repo: "KBLab/kb-whisper-medium", file: "ggml-model-q5_0.bin",
            bytes: 539_212_484, sha256: "7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0",
            quant: "medium · q5_0", dtw: "medium", ramBytes: 900_000_000, speed: 3,
            blurb: "Swedish, half the size of KB-Whisper Swedish. Its makers report 6.6% errors on FLEURS, better than OpenAI's large model.",
            detail: "KB-Whisper Medium by KBLab: Whisper medium trained on 50,000 hours of Swedish.",
            license: "Apache-2.0"),
        languagePack(
            id: "kb-whisper-small-sv-q5", name: "KB-Whisper Swedish Small", languages: ["sv"],
            repo: "KBLab/kb-whisper-small", file: "ggml-model-q5_0.bin",
            bytes: 175_209_680, sha256: "6768836a51abc902e420c613153e6d418c90ea2774e913274d02ab23170225b7",
            quant: "small · q5_0", dtw: "small", ramBytes: 400_000_000, speed: 12,
            blurb: "Swedish, small and quick. Its makers report 7.3% errors on FLEURS, still better than OpenAI's large model (7.8%).",
            detail: "KB-Whisper Small by KBLab: Whisper small trained on 50,000 hours of Swedish.",
            license: "Apache-2.0"),
        languagePack(
            id: "nb-whisper-medium-q5", name: "NB-Whisper Norwegian Medium", languages: ["nb", "no", "nn"],
            repo: "NbAiLab/nb-whisper-medium", file: "ggml-model-q5_0.bin",
            bytes: 539_212_484, sha256: "18733de634af639a43b0f8c5f5a2ea0920de4c5b32a5570ec130981581c0e5e7",
            quant: "medium · q5_0", dtw: "medium", ramBytes: 900_000_000, speed: 3,
            blurb: "Norwegian, half the size of NB-Whisper Norwegian and faster.",
            detail: "NB-Whisper Medium by the National Library of Norway.",
            license: "Apache-2.0",
            whisperLanguage: ["nb": "no"]),
        languagePack(
            id: "finnish-nlp-large-fi-q5", name: "Whisper Finnish", languages: ["fi"],
            repo: "JoaoZaokk/whisper-large-v3-finnish-ggml", file: "ggml-whisper-large-v3-finnish-q5_0.bin",
            bytes: 1_081_140_203, sha256: "7c7a5cc5064ca96dc73cfa164c9044d87ee843b8782fc69040b6330569f12b9f",
            quant: "Finnish-NLP whisper-large-finnish-v3 · q5_0", dtw: "large.v3", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Finnish, from the Finnish-NLP group. Slow.",
            detail: "Finnish-NLP whisper-large-finnish-v3: Whisper large-v3 fine-tuned on Finnish.",
            license: "Apache-2.0",
            evidence: "Its makers report fewer word errors than OpenAI Whisper large-v3 on Common Voice (8.2% against 10.8%) and FLEURS (8.2% against 9.6%)."),
        languagePack(
            id: "mozilla-turbo-fi-q5", name: "Whisper Finnish Turbo", languages: ["fi"],
            repo: "mr00mr00/whisper-large-v3-turbo-fi-ggml", file: "ggml-large-v3-turbo-fi-q5_0.bin",
            bytes: 574_041_195, sha256: "d4c6cd61446b8a8dae1106880cdca7e58d20779dc189d8dca0ffc785b2c1ada5",
            quant: "mozilla-ai whisper-large-v3-turbo-fi · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Finnish, cased and punctuated. As fast as the default model.",
            detail: "mozilla-ai whisper-large-v3-turbo-fi: Whisper turbo fine-tuned on Finnish Common Voice.",
            license: "Apache-2.0"),
        languagePack(
            id: "turkish-general-large-tr-q5", name: "Whisper Turkish", languages: ["tr"],
            repo: "JoaoZaokk/whisper-large-v3-turkish-general-ggml", file: "ggml-whisper-large-v3-turkish-general-q5_0.bin",
            bytes: 1_081_140_203, sha256: "d4c8894a0c46c0ee5ef067ae981b415c7683721c52b2bc54308895a8f7f240eb",
            quant: "TurkMedSTT whisper-large-v3-turkish-general · q5_0", dtw: "large.v3", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Turkish, everyday speech. Slow.",
            detail: "whisper-large-v3-turkish-general by TurkMedSTT: Whisper large-v3 tuned on general Turkish speech.",
            license: "Apache-2.0"),
    ]

    // MARK: Southeast Asia

    /// Thai and Vietnamese, where general Whisper is weakest of the big languages here.
    /// Typhoon Whisper (Thai) was left out: its card adds the OpenTyphoon terms on top of
    /// MIT and it was trained partly on non-commercial data. Indonesian, Malay and
    /// Tagalog fine-tunes do worse than general large-v3 on FLEURS, so none is offered.
    static let southeastAsian: [ModelPack] = [
        languagePack(
            id: "pathumma-large-th-q8", name: "Pathumma Thai", languages: ["th"],
            repo: "linkstar612/polyvox-whisper-ggml", file: "ggml-pathumma-th-large-v3-q8_0.bin",
            bytes: 1_656_538_283, sha256: "6629caba70c3c20d2a712c2b7a3163d0586d33985a32a09937367a7aad88e1c0",
            quant: "NECTEC Pathumma-whisper-th-large-v3 · q8_0", dtw: "large.v3", ramBytes: 2_400_000_000, speed: 1,
            blurb: "Thai, from Thailand's national research agency NECTEC. Slow.",
            detail: "Pathumma-whisper-th-large-v3 by NECTEC: Whisper large-v3 fine-tuned on Thai.",
            license: "Apache-2.0",
            evidence: "Its makers report fewer word errors than Whisper large-v3 on all four Thai test sets, e.g. 15.7% against 24.1% on FLEURS."),
        languagePack(
            id: "thonburian-medium-th-q5", name: "Thonburian Thai", languages: ["th"],
            repo: "suebphatt/thonburian-whisper-ggml", file: "thonburian-medium-q5_0.bin",
            bytes: 539_212_484, sha256: "25fe6beb59477b2f161371fb206e898843058f22ac13036159f83eba0a92336d",
            quant: "biodatlab Thonburian Whisper medium · q5_0", dtw: "medium", ramBytes: 900_000_000, speed: 3,
            blurb: "Thai. Lighter and faster than Pathumma Thai.",
            detail: "Thonburian Whisper medium by biodatlab (Mahidol University): Whisper medium fine-tuned on Thai.",
            license: "Apache-2.0"),
        languagePack(
            id: "phowhisper-large-vi-q8", name: "PhoWhisper Vietnamese", languages: ["vi"],
            repo: "linkstar612/polyvox-whisper-ggml", file: "ggml-phowhisper-vi-large-v2-q8_0.bin",
            bytes: 1_656_129_708, sha256: "d72b0693d332453c79af9e56a94bd4768fa2e7dc055afacc86fe002a5a9841ad",
            quant: "VinAI PhoWhisper-large · q8_0", dtw: "large.v2", ramBytes: 2_400_000_000, speed: 1,
            blurb: "Vietnamese with full diacritics, from VinAI Research. Slow.",
            detail: "PhoWhisper-large by VinAI Research: Whisper large-v2 fine-tuned on 844 hours of Vietnamese.",
            license: "BSD-3-Clause",
            evidence: "Reported 10.0% word errors on GigaSpeech 2 Vietnamese, against 17.9% for Whisper large-v3 (measured by different teams)."),
        languagePack(
            id: "phowhisper-small-vi-f16", name: "PhoWhisper Vietnamese Small", languages: ["vi"],
            repo: "dongxiat/ggml-PhoWhisper-small", file: "ggml-PhoWhisper-small.bin",
            bytes: 487_601_984, sha256: "db8de368e822fce5dcdce7c0c4c80c4b554c27655516dea5ec8c093e22f58785",
            quant: "VinAI PhoWhisper-small · f16", dtw: "small", ramBytes: 800_000_000, speed: 12,
            blurb: "Vietnamese. A third of the size of PhoWhisper Vietnamese, and less accurate.",
            detail: "PhoWhisper-small by VinAI Research: Whisper small fine-tuned on Vietnamese.",
            license: "BSD-3-Clause"),
    ]

    // MARK: Middle East

    /// Hebrew from ivrit-ai, the strongest gain found anywhere in this search. Most Indic
    /// fine-tunes (Bengali, Tamil, Telugu, Urdu) and Sunbird's African model were
    /// trained without timestamps and lose a third or more of their accuracy when
    /// whisper.cpp times them, which captions need, so none is offered until that is
    /// tested (docs/MODEL_RESEARCH.md).
    static let middleEastern: [ModelPack] = [
        languagePack(
            id: "ivrit-turbo-he-q5", name: "ivrit.ai Hebrew", languages: ["he"],
            repo: "JoaoZaokk/ivrit-whisper-large-v3-turbo-ggml", file: "ggml-ivrit-whisper-large-v3-turbo-q5_0.bin",
            bytes: 574_041_195, sha256: "6c1da92e8e41dd64b8cc402eee7eb7a433d2152567e1a4d9cf181fefcc67a572",
            quant: "ivrit-ai whisper-large-v3-turbo · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Hebrew, with punctuation, from ivrit.ai. As fast as the default model.",
            detail: "ivrit-ai whisper-large-v3-turbo: Whisper turbo trained on about 5,000 hours of Hebrew.",
            license: "Apache-2.0",
            evidence: "On ivrit.ai's public leaderboard it makes about half the word errors of standard Whisper turbo, e.g. 15.1% against 28.0% on Common Voice."),
        languagePack(
            id: "turbo-arabic-dialects-q5", name: "Whisper Arabic Dialects", languages: ["ar"],
            repo: "JoaoZaokk/whisper-large-v3-turbo-arabic-dialectal-v2-ggml", file: "ggml-whisper-large-v3-turbo-arabic-dialectal-v2-q5_0.bin",
            bytes: 574_041_195, sha256: "325b7dc691ac04174d91abbd58af74543236a146b87ea2f2f9ecfd9b260a9b6a",
            quant: "oddadmix large-v3-turbo-arabic-dialectal-v2 · q5_0", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Spoken Arabic in 13 dialects — Gulf, Egyptian, Levantine, Iraqi, Maghrebi. As fast as the default model.",
            detail: "oddadmix whisper-large-v3-turbo-arabic-dialectal-v2: Whisper turbo fine-tuned on dialectal Arabic.",
            license: "Apache-2.0"),
        languagePack(
            id: "turbo-persian-f16", name: "Whisper Persian", languages: ["fa"],
            repo: "SadeghK/whisper-large-v3-turbo", file: "ggml-large-v3-turbo-fa.bin",
            bytes: 1_624_555_275, sha256: "60cac5d4be4552ae806de48ba57c39bad4a3c732f9866a77d80e90104db3a870",
            quant: "large-v3-turbo-fa · f16", dtw: "large.v3.turbo", ramBytes: 2_200_000_000, speed: 6,
            blurb: "Persian (Farsi). As fast as the default model, but a larger download.",
            detail: "SadeghK whisper-large-v3-turbo: Whisper turbo fine-tuned on Persian, published at full precision.",
            license: "MIT"),
    ]

    // MARK: South Asia

    /// Bengali and Tamil, where general Whisper is weak (large-v3: 55% word errors on
    /// Bengali Common Voice). Both were trained with timestamps off, so they run with
    /// "-nt"; the figures below were measured inside whisper.cpp that way, by the
    /// converter. Telugu, Gujarati, Marathi and Kannada fine-tunes measured 31–51%
    /// there and Urdu showed no gain over turbo, so they are left out. Hinglish stays
    /// with Apex, which beats Oriserve's own Prime model.
    static let southAsian: [ModelPack] = [
        languagePack(
            id: "bengaliai-medium-bn-q5", name: "Whisper Bengali", languages: ["bn"],
            repo: "bhaskaro/ainotes-whisper-bengali-medium-q5_1", file: "ggml-model.bin",
            bytes: 586_617_206, sha256: "edf51fe50d4e598eaf23e2cecb43f50a50365af04f9cecfa88c0da47b873a169",
            quant: "tugstugi Bengali.AI whisper-medium · q5_1", dtw: "medium", ramBytes: 900_000_000, speed: 3,
            blurb: "Bengali, from the model that won the Bengali.AI speech contest. No punctuation.",
            detail: "tugstugi bengaliai-asr whisper-medium: Whisper medium fine-tuned on Bengali; first place in Kaggle's Bengali.AI challenge.",
            license: "Apache-2.0", noTimestamps: true),
        languagePack(
            id: "vasista22-medium-ta-q5", name: "Whisper Tamil", languages: ["ta"],
            repo: "bhaskaro/ainotes-whisper-tamil-medium-q5_1", file: "ggml-model.bin",
            bytes: 586_572_019, sha256: "786e6925448a0284f9f9cb1593645e5926893bbb2d8a614acd72ef727c1d2e09",
            quant: "vasista22 whisper-tamil-medium · q5_1", dtw: "medium", ramBytes: 900_000_000, speed: 3,
            blurb: "Tamil, from IIT Madras's speech lab.",
            detail: "vasista22 whisper-tamil-medium: Whisper medium fine-tuned on Tamil (SPRING Lab, IIT Madras).",
            license: "Apache-2.0", noTimestamps: true),
    ]

    // MARK: More languages

    /// Languages where general Whisper is weakest (large-v2 on FLEURS: Icelandic 38%,
    /// Armenian 45%, Uzbek 90% word errors). None has a same-test comparison against
    /// large-v3 or turbo, so none is recommended; each is a clear step up on what its
    /// makers measured. Georgian (no published numbers), Bulgarian (tested on its own
    /// training set) and Sunbird's African model (unknown upstream revision, gated)
    /// were left out, and the Armenian turbo was taken out after its test returned
    /// text that was not valid UTF-8 — docs/MODEL_RESEARCH.md.
    static let moreLanguages: [ModelPack] = [
        languagePack(
            id: "taltech-turbo-et-q5k", name: "TalTech Estonian", languages: ["et"],
            repo: "Aivo/whisper-large-v3-turbo-et-verbatim-2604-ggml", file: "ggml-model-q5_k.bin",
            bytes: 574_041_195, sha256: "6cc5102bf73e421ea6dc496663b1e83593164b000a51373942a0e2ca3044c855",
            quant: "TalTechNLP large-v3-turbo-et-verbatim · q5_k", dtw: "large.v3.turbo", ramBytes: 1_100_000_000, speed: 6,
            blurb: "Estonian, from Tallinn University of Technology. Writes numbers as words. As fast as the default model.",
            detail: "TalTechNLP whisper-large-v3-turbo-et-verbatim: Whisper turbo fine-tuned on Estonian, quantised by a co-author.",
            license: "MIT"),
        languagePack(
            id: "localdoc-turbo-az-f16", name: "Whisper Azerbaijani", languages: ["az"],
            repo: "mirza234/azerbaijani-whisper-turbo-ggml", file: "ggml-azerbaijani-whisper-turbo.bin",
            bytes: 1_624_555_275, sha256: "0bd8162c818aa2b558ae38e17a960b6dbfc66c005bfeae05365c450713caf568",
            quant: "LocalDoc azerbaijani-whisper-turbo · f16", dtw: "large.v3.turbo", ramBytes: 2_200_000_000, speed: 6,
            blurb: "Azerbaijani. As fast as the default model, but a larger download.",
            detail: "LocalDoc azerbaijani-whisper-turbo: Whisper turbo fine-tuned on Azerbaijani.",
            license: "Apache-2.0"),
        languagePack(
            id: "lvl-large-is-q5", name: "Whisper Icelandic", languages: ["is"],
            repo: "FredrikKarlssonSpeech/whisper-large-icelandic-62640-steps-967h-ggml", file: "ggml-model-q5_0.bin",
            bytes: 1_080_732_108, sha256: "733452d416641e1bb18320325958a10129aeec177f1885e933ffe01bb1de0d55",
            quant: "Reykjavik University LVL whisper-large-icelandic · q5_0", dtw: "large.v1", ramBytes: 1_900_000_000, speed: 1,
            blurb: "Icelandic, from Reykjavik University's Language and Voice Lab. Slow.",
            detail: "whisper-large-icelandic-62640-steps-967h by LVL: Whisper large fine-tuned on 967 hours of Icelandic.",
            license: "CC-BY-4.0"),
        languagePack(
            id: "rubaistt-medium-uz-q5", name: "rubaiSTT Uzbek", languages: ["uz"],
            repo: "azimxxm/rubaistt-v2-medium-ggml", file: "ggml-rubaistt-medium-q5_0.bin",
            bytes: 539_212_484, sha256: "3740210b611c13c5bad257d6207dbf4572b7843043191bab39ccdf47c1734e9c",
            quant: "rubaiSTT v2 medium · q5_0", dtw: "medium", ramBytes: 900_000_000, speed: 3,
            blurb: "Uzbek, in lower case.",
            detail: "rubaiSTT v2: Whisper medium fine-tuned on 475 hours of Uzbek.",
            license: "Apache-2.0", noTimestamps: true),
    ]
}
