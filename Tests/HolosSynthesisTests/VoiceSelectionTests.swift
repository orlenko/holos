import Foundation
import Testing
@testable import HolosSynthesis

@Suite struct VoiceSelectionTests {
    private func voice(_ id: String, _ name: String, _ language: String, _ quality: String = "default",
                       novelty: Bool = false) -> VoiceDescriptor {
        VoiceDescriptor(id: id, name: name, language: language, quality: quality, novelty: novelty)
    }

    private var installed: [VoiceDescriptor] {
        [
            voice("compact.en-US.Ava", "Ava", "en-US"),
            voice("enhanced.en-US.Ava", "Ava (Enhanced)", "en-US", "enhanced"),
            voice("premium.en-US.Ava", "Ava (Premium)", "en-US", "premium"),
            voice("premium.en-US.Zoe", "Zoe (Premium)", "en-US", "premium"),
            voice("premium.en-GB.Serena", "Serena (Premium)", "en-GB", "premium"),
            voice("enhanced.en-US.Evan", "Evan (Enhanced)", "en-US", "enhanced"),
            voice("compact.en-GB.Daniel", "Daniel", "en-GB"),
            voice("super-compact.en-GB.Daniel", "Daniel", "en-GB"),
            voice("eloquence.en-US.Eddy", "Eddy", "en-US"),
            voice("eloquence.fr-CA.Eddy", "Eddy", "fr-CA"),
            voice("super-compact.fr-CA.Amelie", "Amélie", "fr-CA"),
            voice("super-compact.fr-FR.Thomas", "Thomas", "fr-FR"),
            voice("synthesis.Bubbles", "Bubbles", "de-DE", novelty: true),
            voice("compact.de-DE.Anna", "Anna", "de-DE"),
        ]
    }

    @Test func namesMatchTheWaySayPrintsThem() {
        let voices = installed
        func id(_ query: String, language: String? = nil) -> String? {
            VoiceSelection.match(query, in: voices, language: language)?.id
        }
        #expect(id("premium.en-US.Ava") == "premium.en-US.Ava")
        #expect(id("Ava (Premium)") == "premium.en-US.Ava")
        #expect(id("  ava (premium) ") == "premium.en-US.Ava")
        #expect(id("Ava") == "compact.en-US.Ava")                 // exact name first, as in say
        #expect(id("Zoe") == "premium.en-US.Zoe")                 // no plain Zoe: the named voice
        #expect(id("Evan (Premium)") == nil)
        #expect(id("Evan (Enhanced)") == "enhanced.en-US.Evan")
        #expect(id("Eddy (English (US))") == "eloquence.en-US.Eddy")
        #expect(id("Eddy (English (United States))") == "eloquence.en-US.Eddy")
        #expect(id("Eddy (French (Canada))") == "eloquence.fr-CA.Eddy")
        #expect(id("Eddy", language: "fr") == "eloquence.fr-CA.Eddy")
        #expect(id("Daniel (English (UK))") == "compact.en-GB.Daniel")
        #expect(id("Daniel") == "compact.en-GB.Daniel")          // compact over super-compact
        #expect(id("amelie") == "super-compact.fr-CA.Amelie")
        #expect(id("Nobody") == nil)
        #expect(id("") == nil)
    }

    @Test func displayNamesAddTheLanguageOnlyWhenNamesRepeat() {
        let names = VoiceSelection.displayNames(installed)
        #expect(names["premium.en-US.Ava"] == "Ava (Premium)")
        #expect(names["compact.en-GB.Daniel"] == "Daniel")
        #expect(names["eloquence.en-US.Eddy"] == "Eddy (English (United States))")
        #expect(names["eloquence.fr-CA.Eddy"] == "Eddy (French (Canada))")
        // Every display name finds its own voice again.
        for voice in installed where voice.id != "super-compact.en-GB.Daniel" {
            #expect(VoiceSelection.match(names[voice.id]!, in: installed)?.id == voice.id)
        }
    }

    @Test func bestVoicePrefersQualityThenRegionThenSystemVoice() {
        let voices = installed
        func best(_ language: String, preferred: [String] = [], region: String? = nil,
                  system: String? = nil) -> String? {
            VoiceSelection.best(language: language, in: voices, preferredLanguages: preferred,
                                currentRegion: region, systemDefault: system)?.id
        }
        #expect(best("en", preferred: ["en-CA", "en-US"], system: "premium.en-US.Ava") == "premium.en-US.Ava")
        #expect(best("en", preferred: ["en-US"], system: "premium.en-US.Zoe") == "premium.en-US.Zoe")
        #expect(best("en", preferred: ["en-GB"]) == "premium.en-GB.Serena")
        #expect(best("en-GB", preferred: ["en-US"]) == "premium.en-GB.Serena")
        // Quality comes before region: a premium US voice beats a compact British one.
        let noBritishPremium = voices.filter { $0.id != "premium.en-GB.Serena" }
        #expect(VoiceSelection.best(language: "en", in: noBritishPremium, preferredLanguages: ["en-GB"])?.language == "en-US")
        #expect(VoiceSelection.best(language: "en", in: noBritishPremium, preferredLanguages: ["en-GB"])?.quality == "premium")
        // French: all default quality; the user's region, then the system's voice for it.
        #expect(best("fr", region: "CA", system: "super-compact.fr-CA.Amelie") == "super-compact.fr-CA.Amelie")
        #expect(best("fr", region: "FR") == "super-compact.fr-FR.Thomas")
        // Novelty voices are never a default.
        #expect(best("de") == "compact.de-DE.Anna")
        #expect(best("ja") == nil)
    }
}
