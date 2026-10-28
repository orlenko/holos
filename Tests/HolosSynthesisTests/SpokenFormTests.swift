import Testing
@testable import HolosSynthesis

// SpokenForm's own rules (the normalizer's stage is FluidAudio's, exercised in the tool).

@Suite struct SpokenFormTests {
    private func english(_ text: String) -> String { SpokenForm.text(text, language: "en", normalizer: nil) }

    @Test func pathsAndWebAddressesAreSaidByName() {
        #expect(english("See flight-tools/notes/BENCH_RESULTS_2026-10-25.txt §9.")
            == "See BENCH RESULTS 2026-10-25 section 9.")
        #expect(english("copy at ~/code/tools/intake/Falcon.zip, then") == "copy at Falcon, then")
        #expect(english("the docs at docs.example.com/guide/payload-*.") == "the docs at docs.example.com.")
        #expect(english("Open https://example.com/a/b?c=1 now") == "Open example.com now")
        // One slash is no path: two words, or a fraction left for the normalizer.
        #expect(english("dev/ops and A/B, falcon/next-flight, 1/2") == "dev slash ops and A slash B, falcon slash next-flight, 1/2")
    }

    @Test func unitsRangesAndPortsAreSpelled() {
        #expect(english("A 24.5 MP camera at 0.5–6 Mbit/s and 30 fps.")
            == "A 24.5 megapixel camera at 0.5 to 6 megabits per second and 30 frames per second.")
        #expect(english("The ring is 220 GB, 5 ms apart.") == "The ring is 220 gigabytes, 5 milliseconds apart.")
        #expect(english("API on :8090; localhost:8080 too") == "API on port 8090; localhost port 8080 too")
        // A unit needs a number before it; a time keeps its colon.
        #expect(english("MP for the area, at 3:30") == "MP for the area, at 3:30")
    }

    @Test func versionsArrowsAndSymbols() {
        #expect(english("Version 1.2.3 and v2.0.1, not 27.10.2026.")
            == "Version 1 point 2 point 3 and 2 point 0 point 1, not 27.10.2026.")
        #expect(english("SEARCH → SLEW → LOCK ⇄ COAST") == "SEARCH then SLEW then LOCK to and from COAST")
        #expect(english("S3 → pipeline ← cloud") == "S3 to pipeline from cloud")
        #expect(english("about ~30, ±2, #4, R&D, 1920×1080") == "about about 30, plus or minus 2, number 4, R and D, 1920 by 1080")
        #expect(english("H.265 1080p, TL;DR, e.g. this, i.e. that, devs. vs. ops, 24/7")
            == "H two sixty-five ten eighty p, T L D R, for example this, that is that, devs. versus ops, twenty-four seven")
    }

    @Test func frenchHasItsOwnWordsAndOtherLanguagesAreLeft() {
        #expect(SpokenForm.text("De 25–45 Mbit/s, 2 Go → disque.", language: "fr-CA", normalizer: nil)
            == "De 25 à 45 mégabits par seconde, 2 gigaoctets à disque.")
        #expect(SpokenForm.text("Von 25–45 Mbit/s", language: "de", normalizer: nil) == "Von 25–45 Mbit/s")
    }

    @Test func theNormalizerRunsAfterTheRules() {
        struct Upper: SpokenFormNormalizer {
            func normalize(_ text: String, language: String) -> String { text.uppercased() }
        }
        #expect(SpokenForm.text("at 30 fps", language: "en", normalizer: Upper()) == "AT 30 FRAMES PER SECOND")
    }
}
