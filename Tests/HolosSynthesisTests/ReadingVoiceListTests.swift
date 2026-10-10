import Foundation
import Testing
@testable import HolosSynthesis

@Suite struct ReadingVoiceListTests {
    private let voices = [
        VoiceDescriptor(id: "zoe", name: "Zoe", language: "en-US", quality: "premium"),
        VoiceDescriptor(id: "amelie", name: "Amélie", language: "fr-CA", quality: "enhanced"),
        VoiceDescriptor(id: "ava.standard", name: "Ava", language: "en_US", quality: "default"),
        VoiceDescriptor(id: "ava.gb", name: "Ava", language: "en-GB", quality: "premium"),
        VoiceDescriptor(id: "ava.premium", name: "Ava (Premium)", language: "en-US", quality: "premium"),
        VoiceDescriptor(id: "ava.enhanced", name: "Ava (Enhanced)", language: "en-US", quality: "enhanced"),
        VoiceDescriptor(id: "bubbles", name: "Bubbles", language: "en-US", quality: "default", novelty: true),
    ]

    @Test func browsingIsAlphabeticalAcrossQualitiesAndRegions() {
        let list = ReadingVoiceList(voices: voices, installed: [])
        #expect(list.items.map(\.id) == ["amelie", "ava.gb", "ava.premium", "ava.enhanced", "ava.standard", "zoe"])
        #expect(list.languages.map(\.name) == ["English", "French"])
        #expect(ReadingVoiceList(voices: voices.reversed(), installed: []).items == list.items)
    }

    @Test func searchCombinesNameRegionLanguageAndQualityIgnoringCaseAndAccents() {
        let list = ReadingVoiceList(voices: voices, installed: [])
        #expect(list.matching(query: "  AMELIE  enhanced ", language: nil).map(\.id) == ["amelie"])
        #expect(list.matching(query: "united states premium", language: "en").map(\.id) == ["ava.premium", "zoe"])
        #expect(list.matching(query: "ava", language: "fr").isEmpty)
        #expect(list.matching(query: "", language: "en").count == 5)
        #expect(list.matching(query: "fr-ca", language: nil).map(\.id) == ["amelie"])
    }

    @Test func naturalVoicesShareTheAlphabeticalListAndLanguageFilter() {
        let list = ReadingVoiceList(voices: voices, installed: [.english, .french])
        #expect(list.items.first?.id == "pocket:en:alba")
        #expect(list.matching(query: "natural", language: "fr").map(\.id) == ["pocket:fr:estelle"])
        #expect(list.matching(query: "alba", language: "en").first?.detail == "English · Natural")
        #expect(!list.items.contains { $0.id == "pocket:en:cosette" || $0.id == "pocket:en:jean" })
        #expect(ReadingVoiceList(voices: [], installed: []).languages.isEmpty)
    }
}
