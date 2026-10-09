import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// The natural voices' catalog and its licences.

@Suite struct NaturalVoiceCatalogTests {
    @Test func onlyVoicesThatAllowCommercialUseAreOffered() {
        let offered = NaturalVoiceCatalog.offered.map(\.id)
        #expect(!offered.contains("pocket:en:cosette"))
        #expect(!offered.contains("pocket:en:jean"))
        #expect(offered.contains("pocket:en:alba"))
        #expect(offered.contains("pocket:fr:estelle"))
        #expect(NaturalVoiceCatalog.offered.allSatisfy { $0.license != .ccByNC4 })
        #expect(NaturalVoiceCatalog.all.filter { $0.license == .ccByNC4 }.map(\.name).sorted() == ["cosette", "jean"])
        #expect(Set(NaturalVoiceCatalog.all.map(\.id)).count == NaturalVoiceCatalog.all.count)
        #expect(NaturalVoiceCatalog.voice(id: "pocket:en:cosette") == nil)
        #expect(NaturalVoiceCatalog.voice(id: "pocket:en:jean") == nil)
    }

    @Test func identifiersParseStrictly() {
        #expect(NaturalVoiceCatalog.parse("pocket:en:alba")?.pack == .english)
        #expect(NaturalVoiceCatalog.parse("pocket:fr:estelle")?.name == "estelle")
        #expect(NaturalVoiceCatalog.parse("pocket:en:peter_yearsley")?.name == "peter_yearsley")
        for bad in ["pocket:EN:alba", "pocket:de:juergen", "pocket:en:", "pocket:en:a:b", "apple:en:alba",
                    "pocket:en:al-ba", "pocket:en:Alba", "pocket::alba", "pocket", ""] {
            #expect(NaturalVoiceCatalog.parse(bad) == nil, "\(bad)")
        }
        #expect(NaturalVoiceCatalog.isNatural("pocket:anything"))
        #expect(!NaturalVoiceCatalog.isNatural("com.apple.voice.premium.en-US.Ava"))
    }

    @Test func labelsAndDescriptors() {
        let alba = NaturalVoiceCatalog.defaultVoice(for: .english)
        #expect(alba.id == "pocket:en:alba")
        #expect(alba.title == "Natural — Alba (English)")
        #expect(alba.descriptor == VoiceDescriptor(id: "pocket:en:alba", name: "Alba (Natural)", language: "en",
                                                   quality: "natural"))
        #expect(NaturalVoiceCatalog.defaultVoice(for: .french).title == "Natural — Estelle (French)")
    }

    @Test func voicesOfInstalledPacksDefaultFirst() {
        #expect(NaturalVoiceCatalog.voices(installed: []).isEmpty)
        let english = NaturalVoiceCatalog.voices(installed: [.english])
        #expect(english.first?.name == "alba")
        #expect(english.allSatisfy { $0.pack == .english })
        #expect(english.count == 19)
        #expect(Array(english.dropFirst().map(\.displayName)) == english.dropFirst().map(\.displayName).sorted())
        #expect(NaturalVoiceCatalog.voices(installed: [.french]).map(\.id) == ["pocket:fr:estelle"])
        #expect(NaturalVoiceCatalog.voices(installed: [.french, .english]).last?.id == "pocket:fr:estelle")
    }

    @Test func defaultsSwitchOnceAPackIsInstalled() {
        #expect(NaturalVoiceCatalog.defaultVoice(language: "en-US", installed: []) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: "en-GB", installed: [.english])?.id == "pocket:en:alba")
        #expect(NaturalVoiceCatalog.defaultVoice(language: "fr-CA", installed: [.english]) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: "fr-CA", installed: [.english, .french])?.id
            == "pocket:fr:estelle")
        #expect(NaturalVoiceCatalog.defaultVoice(language: "de", installed: [.english, .french]) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: nil, installed: [.english]) == nil)
    }

    @Test func queriesMatchOfferedVoicesOnly() {
        for query in ["Alba", "alba", "Alba (Natural)", "pocket:en:alba", "POCKET:EN:ALBA", "Natural — Alba (English)"] {
            #expect(NaturalVoiceCatalog.match(query)?.id == "pocket:en:alba", "\(query)")
        }
        #expect(NaturalVoiceCatalog.match("Peter Yearsley")?.id == "pocket:en:peter_yearsley")
        #expect(NaturalVoiceCatalog.match("cosette") == nil)
        #expect(NaturalVoiceCatalog.match("Ava") == nil)
        #expect(NaturalVoiceCatalog.match("  ") == nil)
    }

    @Test func packSizes() {
        #expect(NaturalVoicePack.english.downloadSize == "530 MB")
        #expect(NaturalVoicePack.french.downloadSize == "1.9 GB")
        #expect(NaturalVoicePack.forLanguage("fr-FR") == .french)
        #expect(NaturalVoicePack.forLanguage("it") == nil)
        #expect(NaturalVoicePack.english.fluidLanguage == "english")
        #expect(NaturalVoicePack.french.fluidLanguage == "french_24l")
    }
}
