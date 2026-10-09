import Foundation
import HolosCore

/// The licence of a natural voice's prompt recording (the audio Kyutai encoded into the voice), as Kyutai's
/// tts-voices repository states it (https://huggingface.co/kyutai/tts-voices, read 2026-10-08).
public enum NaturalVoiceLicense: String, Sendable, Equatable, Codable {
    case cc0 = "CC0"
    case ccBy4 = "CC BY 4.0"
    case ccByNC4 = "CC BY-NC 4.0"

    /// Whether a commercial product may ship the voice: CC0 and CC BY yes (CC BY with credit), CC BY-NC no.
    public var allowsCommercialUse: Bool { self != .ccByNC4 }
}

/// A language pack of Kyutai Pocket TTS, as FluidAudio downloads it: the Core ML models and constants for one
/// language. The voices of a pack speak its language.
public enum NaturalVoicePack: String, Sendable, Equatable, CaseIterable, Codable {
    case english
    case french

    /// FluidAudio's `PocketTtsLanguage` raw value: English is the 6-layer pack, French only exists as 24 layers.
    public var fluidLanguage: String {
        switch self {
        case .english: "english"
        case .french: "french_24l"
        }
    }

    /// The language code the pack's voices speak ("en", "fr").
    public var languageCode: String {
        switch self {
        case .english: "en"
        case .french: "fr"
        }
    }

    public var languageName: String {
        switch self {
        case .english: "English"
        case .french: "French"
        }
    }

    /// Bytes downloaded for the pack (FluidInference/pocket-tts-coreml `v2.1/<lang>/`, the fp16 GPU models and
    /// `constants_bin/`, as FluidAudio 0.17.1 filters them; the repository's listing on 2026-10-08).
    public var downloadBytes: Int64 {
        switch self {
        case .english: 529_600_000
        case .french: 1_935_500_000
        }
    }

    /// "530 MB", "1.9 GB".
    public var downloadSize: String {
        let bytes = Double(downloadBytes)
        return bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : String(format: "%.0f MB", bytes / 1e6)
    }

    /// The pack for a language tag ("en-GB" → English); nil for a language no pack speaks.
    public static func forLanguage(_ tag: String?) -> NaturalVoicePack? {
        guard let tag, let code = VoiceSelection.languageCode(tag) else { return nil }
        return allCases.first { $0.languageCode == code }
    }
}

/// One Pocket TTS voice: a recording Kyutai encoded into a voice prompt, in one language pack.
public struct NaturalVoice: Sendable, Equatable {
    public static let engine = "pocket"

    public let pack: NaturalVoicePack
    /// The prompt's name in the pack ("alba"): `constants_bin/<name>.safetensors`.
    public let name: String
    /// "Alba".
    public let displayName: String
    /// The recording the prompt was made from, as Kyutai's model card names it.
    public let source: String
    public let license: NaturalVoiceLicense

    public init(pack: NaturalVoicePack, name: String, displayName: String, source: String,
                license: NaturalVoiceLicense) {
        self.pack = pack
        self.name = name
        self.displayName = displayName
        self.source = source
        self.license = license
    }

    /// "pocket:en:alba".
    public var id: String { "\(Self.engine):\(pack.languageCode):\(name)" }

    /// "Natural — Alba (English)".
    public var title: String { "Natural — \(displayName) (\(pack.languageName))" }

    /// The voice as the voice lists describe voices: quality "natural", language the pack's code.
    public var descriptor: VoiceDescriptor {
        VoiceDescriptor(id: id, name: "\(displayName) (Natural)", language: pack.languageCode, quality: "natural")
    }
}

/// The natural voices Voice is Local knows, and which of them it offers (Sources/HolosSynthesis/README.md).
///
/// Each voice's licence is the licence of the recording its prompt was made from (Kyutai's model card maps voices to
/// recordings; the tts-voices repository gives each recording's licence). The weights themselves are CC BY 4.0
/// (Kyutai), credited in the About panel and THIRD_PARTY_NOTICES.md. Voices whose recording is non-commercial are
/// listed here, so the filter is explicit and tested, but never offered.
public enum NaturalVoiceCatalog {
    private static func english(_ name: String, _ display: String, _ source: String,
                                _ license: NaturalVoiceLicense) -> NaturalVoice {
        NaturalVoice(pack: .english, name: name, displayName: display, source: source, license: license)
    }

    public static let all: [NaturalVoice] = [
        english("alba", "Alba", "alba-mackenna/casual.wav", .ccBy4),
        english("anna", "Anna", "vctk/p228_023_enhanced.wav", .ccBy4),
        english("azelma", "Azelma", "vctk/p303_023_enhanced.wav", .ccBy4),
        english("bill_boerst", "Bill Boerst", "voice-zero/bill_boerst.wav", .cc0),
        english("caro_davy", "Caro Davy", "voice-zero/caro_davy.wav", .cc0),
        english("charles", "Charles", "vctk/p254_023_enhanced.wav", .ccBy4),
        english("cosette", "Cosette", "expresso/ex04-ex02_confused_001_channel1_499s.wav", .ccByNC4),
        english("eponine", "Eponine", "vctk/p262_023_enhanced.wav", .ccBy4),
        english("eve", "Eve", "vctk/p361_023_enhanced.wav", .ccBy4),
        english("fantine", "Fantine", "vctk/p244_023_enhanced.wav", .ccBy4),
        english("george", "George", "vctk/p315_023_enhanced.wav", .ccBy4),
        english("jane", "Jane", "vctk/p339_023_enhanced.wav", .ccBy4),
        english("javert", "Javert", "voice-donations/Butter.wav", .cc0),
        english("jean", "Jean", "ears/p010/freeform_speech_01_enhanced.wav", .ccByNC4),
        english("marius", "Marius", "voice-donations/Selfie.wav", .cc0),
        english("mary", "Mary", "vctk/p333_023_enhanced.wav", .ccBy4),
        english("michael", "Michael", "vctk/p360_023_enhanced.wav", .ccBy4),
        english("paul", "Paul", "vctk/p259_023_enhanced.wav", .ccBy4),
        english("peter_yearsley", "Peter Yearsley", "voice-zero/peter_yearsley.wav", .cc0),
        english("stuart_bell", "Stuart Bell", "voice-zero/stuart_bell.wav", .cc0),
        english("vera", "Vera", "vctk/p229_023_enhanced.wav", .ccBy4),
        NaturalVoice(pack: .french, name: "estelle", displayName: "Estelle",
                     source: "unmute-prod-website/developpeuse-3.wav", license: .cc0),
    ]

    /// The voices offered: those whose recording allows commercial use.
    public static var offered: [NaturalVoice] { all.filter(\.license.allowsCommercialUse) }

    /// The voice each pack reads with unless the user picks another: Alba in English, Estelle in French.
    public static func defaultVoice(for pack: NaturalVoicePack) -> NaturalVoice {
        switch pack {
        case .english: voice(id: "pocket:en:alba")!
        case .french: voice(id: "pocket:fr:estelle")!
        }
    }

    /// Whether `id` names a natural voice ("pocket:…"), offered or not, well formed or not.
    public static func isNatural(_ id: String) -> Bool { id.hasPrefix(NaturalVoice.engine + ":") }

    /// The parts of "pocket:<language>:<name>": a known language code and a name of lowercase letters, digits, and
    /// underscores. Nil for anything else.
    public static func parse(_ id: String) -> (pack: NaturalVoicePack, name: String)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == NaturalVoice.engine,
              let pack = NaturalVoicePack.allCases.first(where: { $0.languageCode == parts[1] }),
              !parts[2].isEmpty,
              parts[2].allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" }) else {
            return nil
        }
        return (pack, String(parts[2]))
    }

    /// The offered voice `id` names; nil for a voice that is not offered (a non-commercial one) or unknown.
    public static func voice(id: String) -> NaturalVoice? {
        guard let parsed = parse(id) else { return nil }
        return offered.first { $0.pack == parsed.pack && $0.name == parsed.name }
    }

    /// The offered voices of the installed packs, by pack (English first), the pack's default first, then by name.
    public static func voices(installed: Set<NaturalVoicePack>) -> [NaturalVoice] {
        NaturalVoicePack.allCases.filter(installed.contains).flatMap { pack -> [NaturalVoice] in
            let preferred = defaultVoice(for: pack)
            return offered.filter { $0.pack == pack }.sorted { lhs, rhs in
                if (lhs == preferred) != (rhs == preferred) { return lhs == preferred }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    /// The natural voice a reading in `language` gets by default: its pack's default voice once that pack is
    /// installed; nil otherwise (the best Apple voice reads it).
    public static func defaultVoice(language: String?, installed: Set<NaturalVoicePack>) -> NaturalVoice? {
        guard let pack = NaturalVoicePack.forLanguage(language), installed.contains(pack) else { return nil }
        return defaultVoice(for: pack)
    }

    /// A natural voice by `voiceislocal` query: its identifier ("pocket:en:alba"), its title, or its name with or
    /// without "(Natural)" ("Alba", "alba"). Only offered voices match.
    public static func match(_ query: String) -> NaturalVoice? {
        let wanted = VoiceSelection.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !wanted.isEmpty else { return nil }
        if let exact = voice(id: query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return exact }
        return offered.first { voice in
            [voice.title, voice.displayName, voice.descriptor.name, voice.name]
                .contains { VoiceSelection.normalized($0) == wanted }
        }
    }
}
