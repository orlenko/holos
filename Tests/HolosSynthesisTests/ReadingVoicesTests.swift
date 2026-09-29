import Foundation
import Testing
@testable import HolosSynthesis

@Suite struct ReadingVoicesTests {
    private let voices = [
        VoiceDescriptor(id: "en.samantha", name: "Samantha", language: "en-US", quality: "default"),
        VoiceDescriptor(id: "fr.thomas", name: "Thomas", language: "fr-FR", quality: "default"),
        VoiceDescriptor(id: "en.ava.premium", name: "Ava (Premium)", language: "en-US", quality: "premium"),
        VoiceDescriptor(id: "de.anna.premium", name: "Anna (Premium)", language: "de-DE", quality: "premium"),
        VoiceDescriptor(id: "en.zoe.enhanced", name: "Zoe", language: "en-US", quality: "enhanced"),
        VoiceDescriptor(id: "fr.amelie.premium", name: "Amélie", language: "fr-CA", quality: "premium"),
        VoiceDescriptor(id: "novelty.bubbles", name: "Bubbles", language: "en-US", quality: "default", novelty: true),
        VoiceDescriptor(id: "en.eddy.gb", name: "Eddy", language: "en-GB", quality: "default"),
        VoiceDescriptor(id: "fr.eddy", name: "Eddy", language: "fr-FR", quality: "default"),
    ]

    @Test func theUsersLanguagesComeFirstBestFirst() {
        let items = ReadingVoiceMenu.items(voices, preferredLanguages: ["en-CA", "fr-CA"])
        #expect(items.map(\.id) == [
            // English and French: Premium (English before French, as the user lists them), Enhanced, default.
            "en.ava.premium", "fr.amelie.premium", "en.zoe.enhanced", "en.eddy.gb", "en.samantha", "fr.eddy",
            "fr.thomas",
            // The rest.
            "de.anna.premium",
        ])
        #expect(items.map(\.preferred) == [true, true, true, true, true, true, true, false])
        #expect(!items.contains { $0.id == "novelty.bubbles" })
    }

    @Test func premiumAndEnhancedVoicesAreMarked() {
        let byID = Dictionary(uniqueKeysWithValues: ReadingVoiceMenu.items(voices, preferredLanguages: ["en"])
            .map { ($0.id, $0) })
        #expect(byID["en.ava.premium"]?.title == "Ava (Premium) — English (United States)")
        #expect(byID["en.ava.premium"]?.name == "Ava (Premium)")
        #expect(byID["fr.amelie.premium"]?.name == "Amélie (Premium)")
        #expect(byID["en.zoe.enhanced"]?.name == "Zoe (Enhanced)")
        #expect(byID["en.samantha"]?.name == "Samantha")
        // A name shared across languages already says its language, which is not repeated.
        #expect(byID["en.eddy.gb"]?.title == "Eddy (English (United Kingdom))")
    }

    @Test func speedMapsOntoTheRateAndBack() {
        #expect(ReadingSpeed.rate(for: 1) == nil)
        func near(_ rate: Float?, _ expected: Float) -> Bool { rate.map { abs($0 - expected) < 0.0001 } ?? false }
        #expect(near(ReadingSpeed.rate(for: 0.8), 0.42))
        #expect(near(ReadingSpeed.rate(for: 1.4), 0.6))
        #expect(near(ReadingSpeed.rate(for: 1.2), 0.55))
        // Out of range and odd values land on the slider's stops.
        #expect(near(ReadingSpeed.rate(for: 3), 0.6))
        #expect(near(ReadingSpeed.rate(for: 0.1), 0.42))
        #expect(ReadingSpeed.rate(for: .nan) == nil)
        var previous: Float = 0
        for step in 0...6 {
            let speed = 0.8 + Double(step) * 0.1
            let rate = ReadingSpeed.rate(for: speed) ?? 0.5
            #expect(rate > previous)
            #expect(SpeechRate.range.contains(rate))
            #expect(abs(ReadingSpeed.speed(for: ReadingSpeed.rate(for: speed)) - speed) < 0.001)
            previous = rate
        }
        #expect(ReadingSpeed.speed(for: nil) == 1)
        #expect(ReadingSpeed.label(1.2) == "1.2×")
        #expect(ReadingSpeed.label(1) == "1.0×")
        #expect(abs(ReadingSpeed.clamped(1.26) - 1.3) < 0.001)
    }
}
