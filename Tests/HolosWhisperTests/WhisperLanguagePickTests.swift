import Foundation
import Testing
@testable import HolosWhisper

/// Choosing each passage's language among a meeting's languages (docs/meeting-design.md §4.16): pure, no model.
@Suite struct WhisperLanguagePickTests {
    /// 1,600 samples per 100 ms frame, as the transcriber cuts them.
    private let frame = 1_600

    /// Voice activity from a pattern: "#" speech, "." pause, one character per frame.
    private func activity(_ pattern: String) -> [Bool] { pattern.map { $0 == "#" } }

    @Test func speechFramesAreJudgedAgainstTheStretchsOwnLevel() {
        // Speech at about -26 dBFS, room noise at about -56 dBFS, a pause of digital silence.
        let speech = (0..<frame).map { index in Float(index.isMultiple(of: 2) ? 0.05 : -0.05) }
        let noise = (0..<frame).map { index in Float(index.isMultiple(of: 2) ? 0.0016 : -0.0016) }
        let quiet = [Float](repeating: 0, count: frame)
        let samples = speech + speech + noise + quiet + speech + Array(speech.prefix(800))
        #expect(WhisperLanguagePick.activity(samples, frameSamples: frame) == [true, true, false, false, true, true])
        // The same speech much quieter (a call at a low level) is still speech against its own noise.
        let soft = samples.map { $0 * 0.1 }
        #expect(WhisperLanguagePick.activity(soft, frameSamples: frame) == [true, true, false, false, true, true])
        #expect(WhisperLanguagePick.activity([], frameSamples: frame).isEmpty)
        #expect(WhisperLanguagePick.activity(quiet, frameSamples: frame) == [false], "Silence is never speech.")
    }

    @Test func passagesAreCutAtTheMiddleOfLongPauses() {
        // 3 s of speech, a 1 s pause, 2.5 s of speech, a 0.3 s pause (bridged), 2 s of speech.
        let pattern = String(repeating: "#", count: 30) + String(repeating: ".", count: 10)
            + String(repeating: "#", count: 25) + "..." + String(repeating: "#", count: 20)
        let total = pattern.count * frame
        let passages = WhisperLanguagePick.passages(activity: activity(pattern), frameSamples: frame, total: total)
        #expect(passages.map(\.range) == [0..<(35 * frame), (35 * frame)..<total])
        #expect(passages.map(\.speech) == [0..<(30 * frame), (40 * frame)..<(88 * frame)])
    }

    @Test func joinedShortPassagesCountTheirSpeechNotTheirPauses() {
        // "Oui." (0.5 s), a 1.5 s pause, "Merci." (0.5 s), a 0.6 s pause, 4 s: joined, the two short ones span 2.5 s
        // but hold 1 s of speech, so they join the long one too; counted by their span they would stay apart.
        let pattern = String(repeating: "#", count: 5) + String(repeating: ".", count: 15)
            + String(repeating: "#", count: 5) + String(repeating: ".", count: 6) + String(repeating: "#", count: 40)
        let passages = WhisperLanguagePick.passages(activity: activity(pattern), frameSamples: frame,
                                                    total: pattern.count * frame)
        #expect(passages.count == 1)
        // A passage with 1 s of speech each side of a 3 s pause has 2 s of speech: too little to halve.
        let sparse = String(repeating: "#", count: 10) + String(repeating: ".", count: 30)
            + String(repeating: "#", count: 10)
        let levels = sparse.map { $0 == "#" ? -20.0 : -60.0 }
        let passage = WhisperLanguagePick.Passage(range: 0..<(sparse.count * frame), speech: 0..<(sparse.count * frame))
        #expect(WhisperLanguagePick.halves(passage, activity: activity(sparse), levels: levels,
                                           frameSamples: frame) == nil)
        #expect(WhisperLanguagePick.activeSamples(in: 0..<(sparse.count * frame), activity: activity(sparse),
                                                  frameSamples: frame) == 20 * frame)
    }

    @Test func aShortPassageJoinsItsCloserNeighbour() {
        // 4 s, a 1.5 s pause, "Okay." (0.6 s), a 0.6 s pause, 4 s: the short one joins the one after it.
        let pattern = String(repeating: "#", count: 40) + String(repeating: ".", count: 15)
            + String(repeating: "#", count: 6) + String(repeating: ".", count: 6) + String(repeating: "#", count: 40)
        let total = pattern.count * frame
        let passages = WhisperLanguagePick.passages(activity: activity(pattern), frameSamples: frame, total: total)
        #expect(passages.count == 2)
        #expect(passages.last?.speech == (55 * frame)..<(107 * frame))
        #expect(passages.first?.range.upperBound == (40 * frame + 55 * frame) / 2)
        #expect(passages.last?.range.upperBound == total, "The passages cover the stretch.")
        // Alone, a short stretch is one passage.
        #expect(WhisperLanguagePick.passages(activity: activity("..###.."), frameSamples: frame, total: 7 * frame)
            .map(\.range) == [0..<(7 * frame)])
    }

    @Test func aStretchWithoutSpeechIsOnePassage() {
        let passages = WhisperLanguagePick.passages(activity: activity("......"), frameSamples: frame,
                                                    total: 6 * frame)
        #expect(passages == [WhisperLanguagePick.Passage(range: 0..<(6 * frame), speech: 0..<(6 * frame))])
        #expect(WhisperLanguagePick.passages(activity: [], frameSamples: frame, total: 0).isEmpty)
    }

    @Test func anUnsurePassageIsHalvedAtItsLongestPause() {
        // 3 s of speech, a 0.2 s pause, 2.5 s, a 0.4 s pause, 3 s: two voices with no clear pause between them.
        let pattern = String(repeating: "#", count: 30) + ".." + String(repeating: "#", count: 25) + "...."
            + String(repeating: "#", count: 30)
        let flags = activity(pattern)
        let levels = flags.map { $0 ? -20.0 : -60.0 }
        let total = pattern.count * frame
        let whole = WhisperLanguagePick.Passage(range: 0..<total, speech: 0..<total)
        let halves = WhisperLanguagePick.halves(whole, activity: flags, levels: levels, frameSamples: frame)
        // The 0.4 s pause (frames 57..<61) leaves at least 2 s of speech on each side: cut at its middle.
        #expect(halves?.0 == WhisperLanguagePick.Passage(range: 0..<(59 * frame), speech: 0..<(57 * frame)))
        #expect(halves?.1 == WhisperLanguagePick.Passage(range: (59 * frame)..<total, speech: (61 * frame)..<total))
        // Too little speech to leave 2 s on each side: kept whole.
        let short = WhisperLanguagePick.Passage(range: 0..<(35 * frame), speech: 0..<(35 * frame))
        #expect(WhisperLanguagePick.halves(short, activity: Array(flags.prefix(35)), levels: Array(levels.prefix(35)),
                                           frameSamples: frame) == nil)
    }

    @Test func anUnsurePassageWithoutAPauseIsHalvedAtItsQuietestFrame() {
        // 6 s of speech with no pause; the quietest frame is at 2.5 s, the next quietest at 1 s (too near the start).
        var levels = [Double](repeating: -20, count: 60)
        levels[10] = -40
        levels[25] = -30
        let flags = [Bool](repeating: true, count: 60)
        let passage = WhisperLanguagePick.Passage(range: 0..<(60 * frame), speech: 0..<(60 * frame))
        let halves = WhisperLanguagePick.halves(passage, activity: flags, levels: levels, frameSamples: frame)
        let cut = 25 * frame + frame / 2
        #expect(halves?.0 == WhisperLanguagePick.Passage(range: 0..<cut, speech: 0..<cut))
        #expect(halves?.1 == WhisperLanguagePick.Passage(range: cut..<(60 * frame), speech: cut..<(60 * frame)))
        // Level ties go to the frame nearer the middle (the earlier of two as near).
        let flat = WhisperLanguagePick.halves(passage, activity: flags, levels: [Double](repeating: -20, count: 60),
                                              frameSamples: frame)
        #expect(flat?.0.range.upperBound == 29 * frame + frame / 2)
    }

    @Test func detectionIsLimitedToTheMeetingsLanguages() {
        // Whisper's own detection would say German; among French and English, French wins.
        let probabilities = WhisperLanguagePick.probabilities(logits: ["fr": 2.0, "en": 0.0])
        #expect(abs((probabilities["fr"] ?? 0) - 1 / (1 + exp(-2.0))) < 1e-9)
        #expect(abs(probabilities.values.reduce(0, +) - 1) < 1e-9)
        #expect(WhisperLanguagePick.choice(probabilities, languages: ["en", "fr"]) == "fr")
        // A tie goes to the language listed first; one without a logit scores 0.
        #expect(WhisperLanguagePick.choice(["fr": 0.5, "en": 0.5], languages: ["en", "fr"]) == "en")
        let missing = WhisperLanguagePick.probabilities(logits: ["fr": 1, "en": -.infinity])
        #expect(missing == ["fr": 1, "en": 0])
        #expect(WhisperLanguagePick.probabilities(logits: ["fr": .nan, "en": .nan]) == ["fr": 0.5, "en": 0.5])
        #expect(WhisperLanguagePick.choice([:], languages: ["fr", "en"]) == "fr")
        #expect(WhisperLanguagePick.choice([:], languages: []) == nil)
    }

    @Test func adjacentPassagesInOneLanguageAreDecodedTogether() {
        let runs = WhisperLanguagePick.runs([
            (0..<100, "fr"), (100..<180, "fr"), (180..<260, "en"), (260..<300, "fr"), (300..<300, "en"),
            (400..<450, "fr"),
        ])
        #expect(runs.map(\.range) == [0..<180, 180..<260, 260..<300, 400..<450])
        #expect(runs.map(\.language) == ["fr", "en", "fr", "fr"], "Separate stretches stay apart.")
    }

    @Test func passagesAreNeverJoinedAcrossThePlannedStretches() {
        // Three touching 20 s stretches of one long French turn: three runs, none longer than its stretch (the
        // decoder's window and prompt budget rely on that bound).
        let stretch = 20 * 16_000
        let runs = WhisperLanguagePick.runs(byStretch: [
            [(0..<(stretch / 2), "fr"), ((stretch / 2)..<stretch, "fr")],
            [(stretch..<(2 * stretch), "fr")],
            [((2 * stretch)..<(3 * stretch), "fr")],
        ])
        #expect(runs.map(\.range) == [0..<stretch, stretch..<(2 * stretch), (2 * stretch)..<(3 * stretch)])
        #expect(runs.allSatisfy { $0.range.count <= stretch })
        // Within a stretch, a change of language still cuts it.
        let mixed = WhisperLanguagePick.runs(byStretch: [[(0..<100, "fr"), (100..<200, "en"), (200..<300, "en")]])
        #expect(mixed.map(\.range) == [0..<100, 100..<300])
    }
}
