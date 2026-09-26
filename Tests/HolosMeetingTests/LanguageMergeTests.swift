import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// `LanguageMerge` (docs/meeting-design.md §4.14): the per-window language choice, smoothing, and the segments it
// keeps, on synthetic transcriptions. A word's spelling says which language it reads as ("fr-3@en" is a French word
// the English model heard), and `languageMergeScorer` reads it that way, as NLLanguageRecognizer reads real text.

// MARK: - Helpers

private let french = "fr-CA"
private let english = "en-CA"
private let spanish = "es-ES"

/// The probability of each candidate language: the share of the text's tokens spelled with its language code; the
/// same for every candidate when no token has one.
private func languageMergeScorer(_ text: String, _ languages: [String]) -> [String: Double] {
    let tokens = text.split(separator: " ")
    var counts: [String: Double] = [:]
    for language in languages {
        let code = String(language.prefix(2))
        counts[language] = Double(tokens.filter { $0.hasPrefix(code) }.count)
    }
    let total = counts.values.reduce(0, +)
    guard total > 0 else {
        return Dictionary(uniqueKeysWithValues: languages.map { ($0, 1 / Double(languages.count)) })
    }
    return counts.mapValues { $0 / total }
}

/// A segment of `words` on `track`, one every `wordSeconds` from `start`, each lasting 80 % of that, all with
/// `confidence`.
private func languageMergeSegment(_ words: [String], start: Double, wordSeconds: Double = 0.5,
                                  confidence: Double?, track: String? = "mic",
                                  id: String = UUID().uuidString) -> TranscriptSegment {
    var segment = SessionFixtures.segment(words, track: track, start: start, wordSeconds: wordSeconds, id: id)
    segment.words = segment.words.map { word in
        var scored = word
        scored.confidence = confidence
        return scored
    }
    return segment
}

/// What `model` (a language code) hears over [start, start + seconds) of speech in `spoken`: a word every 0.5 s
/// spelled in the spoken language, confident when the model is the spoken language's, less so otherwise (the French
/// model stays fairly confident on English speech, the English one does not on French, as measured).
private func languageMergePassage(_ spoken: String, heardBy model: String, from start: Double, seconds: Double,
                                  track: String? = "mic", id: String = UUID().uuidString) -> TranscriptSegment {
    let count = Int((seconds / 0.5).rounded())
    let words = (0..<count).map { "\(spoken)-\(Int(start * 2) + $0)@\(model)" }
    let confidence = model == spoken ? 0.9 : (model == "fr" ? 0.6 : 0.2)
    return languageMergeSegment(words, start: start, confidence: confidence, track: track, id: id)
}

private func languageMergeRun(_ candidates: [LanguageMerge.Candidate]) -> LanguageMerge.Result {
    LanguageMerge.merge(candidates, scorer: languageMergeScorer)
}

// MARK: - Choosing the language

@Test func pureFrenchKeepsEveryFrenchSegmentWhole() {
    let french1 = languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 30, id: "F1")
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [french1]),
        LanguageMerge.Candidate(language: english,
                                segments: [languageMergePassage("fr", heardBy: "en", from: 0, seconds: 30, id: "E1")]),
    ])
    var expected = french1
    expected.language = french
    #expect(result.segments == [expected])
    #expect(result.summary == LanguageMerge.Summary(windows: 10, windowsByLanguage: [french: 10], switches: 0,
                                                    wordsByLanguage: [french: 60]))
}

@Test func englishControlNeverSwitchesToFrench() {
    // An English meeting. The French model also hears it, fairly confidently, and makes up a word at the very start
    // and one in a pause, where the English model heard nothing: one window each, never two in a row.
    let french1 = languageMergeSegment(["fr-a@fr"], start: 0.5, confidence: 0.9, id: "F0")
    let french2 = languageMergePassage("en", heardBy: "fr", from: 3, seconds: 9, id: "F1")
    let french3 = languageMergeSegment(["fr-b@fr"], start: 13, confidence: 0.9, id: "F2")
    let french4 = languageMergePassage("en", heardBy: "fr", from: 15, seconds: 15, id: "F3")
    let english1 = languageMergePassage("en", heardBy: "en", from: 3, seconds: 9, id: "E1")
    let english2 = languageMergePassage("en", heardBy: "en", from: 15, seconds: 15, id: "E2")
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [french1, french2, french3, french4]),
        LanguageMerge.Candidate(language: english, segments: [english1, english2]),
    ])
    #expect(result.segments.map(\.id) == ["E1", "E2"])
    #expect(result.segments.allSatisfy { $0.language == english })
    #expect(result.summary.windowsByLanguage[french] == nil, "No window is kept in French.")
    #expect(result.summary.windows == 10)
    #expect(result.summary.switches == 0)
}

@Test func alternatingPassagesSwitchLanguage() {
    // French, English, French, 12 s each (4 windows): each model hears all of it.
    let spoken = [("fr", 0.0), ("en", 12.0), ("fr", 24.0)]
    let frenchModel = spoken.enumerated().map { index, part in
        languageMergePassage(part.0, heardBy: "fr", from: part.1, seconds: 12, id: "F\(index + 1)")
    }
    let englishModel = spoken.enumerated().map { index, part in
        languageMergePassage(part.0, heardBy: "en", from: part.1, seconds: 12, id: "E\(index + 1)")
    }
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: frenchModel),
        LanguageMerge.Candidate(language: english, segments: englishModel),
    ])
    #expect(result.segments.map(\.id) == ["F1", "E2", "F3"])
    #expect(result.segments.map(\.language) == [french, english, french])
    #expect(result.segments[1].text == englishModel[1].text, "Whole segments keep their text.")
    #expect(result.summary.switches == 2)
    #expect(result.summary.windowsByLanguage == [french: 8, english: 4])
}

@Test func switchNeedsTwoAgreeingWindowsAndHappensAtTheFirst() {
    // French with 6 s of English (two windows) in the middle of one long French-model segment.
    let frenchModel = [
        languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 12, id: "F1"),
        languageMergePassage("en", heardBy: "fr", from: 12, seconds: 6, id: "F2"),
        languageMergePassage("fr", heardBy: "fr", from: 18, seconds: 12, id: "F3"),
    ]
    let englishModel = [
        languageMergePassage("fr", heardBy: "en", from: 0, seconds: 12, id: "E1"),
        languageMergePassage("en", heardBy: "en", from: 12, seconds: 6, id: "E2"),
        languageMergePassage("fr", heardBy: "en", from: 18, seconds: 12, id: "E3"),
    ]
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: frenchModel),
        LanguageMerge.Candidate(language: english, segments: englishModel),
    ])
    #expect(result.segments.map(\.id) == ["F1", "E2", "F3"])
    #expect(result.summary.switches == 2)
}

@Test func loneWindowIsSmoothedAway() {
    // One window (3 s) of English inside French, and one at the very end: neither has a second window to agree.
    let frenchModel = [
        languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 12, id: "F1"),
        languageMergePassage("en", heardBy: "fr", from: 12, seconds: 3, id: "F2"),
        languageMergePassage("fr", heardBy: "fr", from: 15, seconds: 12, id: "F3"),
        languageMergePassage("en", heardBy: "fr", from: 27, seconds: 3, id: "F4"),
    ]
    let englishModel = [
        languageMergePassage("fr", heardBy: "en", from: 0, seconds: 12, id: "E1"),
        languageMergePassage("en", heardBy: "en", from: 12, seconds: 3, id: "E2"),
        languageMergePassage("fr", heardBy: "en", from: 15, seconds: 12, id: "E3"),
        languageMergePassage("en", heardBy: "en", from: 27, seconds: 3, id: "E4"),
    ]
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: frenchModel),
        LanguageMerge.Candidate(language: english, segments: englishModel),
    ])
    #expect(result.segments.map(\.id) == ["F1", "F2", "F3", "F4"])
    #expect(result.summary.switches == 0)
    #expect(result.summary.windowsByLanguage == [french: 10])
}

@Test func emptyWindowsCarryThePreviousChoiceAndDoNotBreakARun() {
    // French for 6 s, silence, then two lone windows of English separated by silence: they still agree.
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [
            languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 6, id: "F1"),
            languageMergePassage("en", heardBy: "fr", from: 15, seconds: 3, id: "F2"),
            languageMergePassage("en", heardBy: "fr", from: 21, seconds: 3, id: "F3"),
        ]),
        LanguageMerge.Candidate(language: english, segments: [
            languageMergePassage("fr", heardBy: "en", from: 0, seconds: 6, id: "E1"),
            languageMergePassage("en", heardBy: "en", from: 15, seconds: 3, id: "E2"),
            languageMergePassage("en", heardBy: "en", from: 21, seconds: 3, id: "E3"),
        ]),
    ])
    #expect(result.segments.map(\.id) == ["F1", "E2", "E3"])
    #expect(result.summary.windows == 4, "Only windows with words count.")
    #expect(result.summary.switches == 1)
}

@Test func windowsWhereOnlyOneLanguageHasWordsTakeIt() {
    // Both models hear 0–6 s (French wins), only the English one hears 6–12 s, both hear 12–18 s again.
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [
            languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 6, id: "F1"),
            languageMergePassage("fr", heardBy: "fr", from: 12, seconds: 6, id: "F3"),
        ]),
        LanguageMerge.Candidate(language: english, segments: [
            languageMergePassage("fr", heardBy: "en", from: 0, seconds: 6, id: "E1"),
            languageMergePassage("en", heardBy: "en", from: 6, seconds: 6, id: "E2"),
            languageMergePassage("fr", heardBy: "en", from: 12, seconds: 6, id: "E3"),
        ]),
    ])
    #expect(result.segments.map(\.id) == ["F1", "E2", "F3"])
}

@Test func aLoneWindowHeardOnlyInTheOtherLanguageKeepsNothing() {
    // Smoothing keeps French over one window that only the English model heard, and French has no words there.
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [
            languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 9, id: "F1"),
            languageMergePassage("fr", heardBy: "fr", from: 12, seconds: 9, id: "F3"),
        ]),
        LanguageMerge.Candidate(language: english, segments: [
            languageMergePassage("fr", heardBy: "en", from: 0, seconds: 9, id: "E1"),
            languageMergePassage("en", heardBy: "en", from: 9, seconds: 3, id: "E2"),
            languageMergePassage("fr", heardBy: "en", from: 12, seconds: 9, id: "E3"),
        ]),
    ])
    #expect(result.segments.map(\.id) == ["F1", "F3"])
    #expect(result.summary.windowsByLanguage == [french: 7])
}

@Test func aTieGoesToTheLanguageListedFirst() {
    // Same confidence, and text that reads as neither language.
    let first = languageMergeSegment(["xx", "yy", "zz"], start: 0, confidence: 0.5, id: "A")
    let second = languageMergeSegment(["qq", "ww", "vv"], start: 0, confidence: 0.5, id: "B")
    let frenchFirst = languageMergeRun([LanguageMerge.Candidate(language: french, segments: [first]),
                                        LanguageMerge.Candidate(language: english, segments: [second])])
    #expect(frenchFirst.segments.map(\.id) == ["A"])
    let englishFirst = languageMergeRun([LanguageMerge.Candidate(language: english, segments: [second]),
                                         LanguageMerge.Candidate(language: french, segments: [first])])
    #expect(englishFirst.segments.map(\.id) == ["B"])
}

@Test func tracksAreMergedSeparately() {
    // At the same time, the microphone speaks French and the call English.
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [
            languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 12, track: "mic", id: "FM"),
            languageMergePassage("en", heardBy: "fr", from: 0, seconds: 12, track: "system", id: "FS"),
        ]),
        LanguageMerge.Candidate(language: english, segments: [
            languageMergePassage("fr", heardBy: "en", from: 0, seconds: 12, track: "mic", id: "EM"),
            languageMergePassage("en", heardBy: "en", from: 0, seconds: 12, track: "system", id: "ES"),
        ]),
    ])
    #expect(result.segments.map(\.id) == ["FM", "ES"])
    #expect(result.segments.map(\.track) == ["mic", "system"])
    #expect(result.summary.windows == 8)
    #expect(result.summary.switches == 0)
}

@Test func threeLanguagesAreToldApart() {
    let spoken = [("fr", 0.0), ("en", 6.0), ("es", 12.0)]
    func model(_ code: String, prefix: String) -> [TranscriptSegment] {
        spoken.enumerated().map { index, part in
            var segment = languageMergePassage(part.0, heardBy: code, from: part.1, seconds: 6,
                                               id: "\(prefix)\(index + 1)")
            // Every model is sure only of its own language here.
            segment.words = segment.words.map { word in
                var scored = word
                scored.confidence = part.0 == code ? 0.9 : 0.3
                return scored
            }
            return segment
        }
    }
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: model("fr", prefix: "F")),
        LanguageMerge.Candidate(language: english, segments: model("en", prefix: "E")),
        LanguageMerge.Candidate(language: spanish, segments: model("es", prefix: "S")),
    ])
    #expect(result.segments.map(\.id) == ["F1", "E2", "S3"])
    #expect(result.segments.map(\.language) == [french, english, spanish])
    #expect(result.summary.switches == 2)
}

@Test func oneCandidateKeepsEverySegment() {
    let segments = [languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 6, id: "F1"),
                    languageMergePassage("en", heardBy: "fr", from: 10, seconds: 2, id: "F2")]
    let result = languageMergeRun([LanguageMerge.Candidate(language: french, segments: segments)])
    #expect(result.segments.map(\.id) == ["F1", "F2"])
    #expect(result.segments.allSatisfy { $0.language == french })
}

@Test func noWordsGiveNoSegments() {
    let result = languageMergeRun([LanguageMerge.Candidate(language: french, segments: []),
                                   LanguageMerge.Candidate(language: english, segments: [])])
    #expect(result.segments.isEmpty)
    #expect(result.summary == LanguageMerge.Summary())
}

// MARK: - Words and segments

@Test func wordsAreAssignedToWindowsByTheirMiddle() {
    // Windows 0 and 1 are French (only the French model heard them); windows 2 and 3 are English. The third French
    // word ends at 6.0 s (middle 5.9 s, window 1); the fourth starts before 6 s but its middle is 6.1 s (window 2).
    let words = [
        TimedWord(text: "fr-0", start: 1.0, end: 1.4, utf16Offset: 0, utf16Length: 4, confidence: 0.9),
        TimedWord(text: "fr-1", start: 4.0, end: 4.4, utf16Offset: 5, utf16Length: 4, confidence: 0.9),
        TimedWord(text: "fr-2", start: 5.8, end: 6.0, utf16Offset: 10, utf16Length: 4, confidence: 0.9),
        TimedWord(text: "fr-3", start: 5.9, end: 6.3, utf16Offset: 15, utf16Length: 4, confidence: 0.5),
        TimedWord(text: "fr-4", start: 10.0, end: 10.4, utf16Offset: 20, utf16Length: 4, confidence: 0.5),
    ]
    let frenchSegment = TranscriptSegment(id: "F", start: 1.0, end: 10.4, text: "fr-0 fr-1 fr-2 fr-3 fr-4",
                                          words: words, track: "mic")
    let englishSegment = TranscriptSegment(id: "E", start: 7.0, end: 10.9, text: "en-a en-b", words: [
        TimedWord(text: "en-a", start: 7.0, end: 7.4, utf16Offset: 0, utf16Length: 4, confidence: 0.9),
        TimedWord(text: "en-b", start: 10.5, end: 10.9, utf16Offset: 5, utf16Length: 4, confidence: 0.9),
    ], track: "mic")
    let result = languageMergeRun([LanguageMerge.Candidate(language: french, segments: [frenchSegment]),
                                   LanguageMerge.Candidate(language: english, segments: [englishSegment])])
    #expect(result.segments.map(\.id) == ["F/0", "E"])
    let piece = result.segments[0]
    #expect(piece.words.map(\.text) == ["fr-0", "fr-1", "fr-2"])
    #expect(piece.text == "fr-0 fr-1 fr-2 ", "A cut that starts the segment runs to the next word's offset.")
    #expect(piece.start == 1.0 && piece.end == 6.0)
    #expect(piece.language == french)
    #expect(result.summary.switches == 1)
}

@Test func cutSegmentsFollowTheRecognizerOffsets() {
    // Recognizer text: leading spaces in the words, punctuation between them.
    let text = " Bonjour, tout le monde. Hello there."
    let spelled = [" Bonjour", " tout", " le", " monde", " Hello", " there"]
    var words: [TimedWord] = []
    var searchFrom = text.startIndex
    for (index, word) in spelled.enumerated() {
        let range = text.range(of: word, range: searchFrom..<text.endIndex)!
        let offset = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
        words.append(TimedWord(text: word, start: Double(index), end: Double(index) + 0.5, utf16Offset: offset,
                               utf16Length: word.utf16.count, confidence: 0.8))
        searchFrom = range.upperBound
    }
    let segment = TranscriptSegment(id: "S", start: 0, end: 6, text: text, words: words, track: "mic")

    let head = LanguageMerge.piece(of: segment, first: 0, end: 4, language: french)
    #expect(head.id == "S/0")
    #expect(head.text == " Bonjour, tout le monde.")
    #expect(head.words.map(\.utf16Offset) == [0, 9, 14, 17])
    #expect(head.start == 0 && head.end == 3.5)
    let tail = LanguageMerge.piece(of: segment, first: 4, end: 6, language: english)
    #expect(tail.id == "S/4")
    #expect(tail.text == " Hello there.")
    #expect(tail.words.map(\.utf16Offset) == [0, 6])
    #expect(tail.start == 4 && tail.end == 6, "A cut that ends the segment keeps its end.")
    #expect(LanguageMerge.piece(of: segment, first: 0, end: 6, language: french).id == "S",
            "All the words: the segment itself.")

    // Offsets that do not fit the text: the words' own texts, joined with spaces.
    var broken = segment
    broken.words[2].utf16Offset = 3
    let fallback = LanguageMerge.piece(of: broken, first: 1, end: 3, language: french)
    #expect(fallback.text == "tout le")
    #expect(fallback.words.map(\.utf16Offset) == [0, 5])
    #expect(fallback.words.map(\.utf16Length) == [4, 2])
}

@Test func untimedSegmentsMoveWhole() {
    let untimed = TranscriptSegment(id: "U", start: 0, end: 2.9, text: "fr-a fr-b fr-c", track: "mic")
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [untimed]),
        LanguageMerge.Candidate(language: english,
                                segments: [languageMergePassage("fr", heardBy: "en", from: 0, seconds: 3, id: "E")]),
    ])
    var expected = untimed
    expected.language = french
    #expect(result.segments == [expected])
    #expect(result.summary.wordsByLanguage == [french: 3])
}

@Test func segmentIDsStayUnique() {
    // Two transcriptions that happen to use the same segment ID, both kept.
    let result = languageMergeRun([
        LanguageMerge.Candidate(language: french, segments: [
            languageMergePassage("fr", heardBy: "fr", from: 0, seconds: 6, id: "S"),
        ]),
        LanguageMerge.Candidate(language: english, segments: [
            languageMergePassage("en", heardBy: "en", from: 6, seconds: 6, id: "S"),
        ]),
    ])
    #expect(result.segments.map(\.id) == ["S", "S/en-CA"])
}

@Test func mergeIsDeterministic() {
    let frenchModel = (0..<6).map { index in
        languageMergePassage(index.isMultiple(of: 2) ? "fr" : "en", heardBy: "fr", from: Double(index) * 7,
                             seconds: 7, id: "F\(index)")
    }
    let englishModel = (0..<6).map { index in
        languageMergePassage(index.isMultiple(of: 2) ? "fr" : "en", heardBy: "en", from: Double(index) * 7,
                             seconds: 7, id: "E\(index)")
    }
    let candidates = [LanguageMerge.Candidate(language: french, segments: frenchModel),
                      LanguageMerge.Candidate(language: english, segments: englishModel)]
    #expect(languageMergeRun(candidates) == languageMergeRun(candidates))
}

// MARK: - Smoothing

@Test func smoothingSwitchesOnlyAfterAgreeingWindows() {
    #expect(LanguageMerge.smooth([], switchWindows: 2) == [])
    #expect(LanguageMerge.smooth([1], switchWindows: 2) == [1])
    #expect(LanguageMerge.smooth([0, 0, 1, 0, 0], switchWindows: 2) == [0, 0, 0, 0, 0])
    #expect(LanguageMerge.smooth([0, 0, 1, 1, 0, 0], switchWindows: 2) == [0, 0, 1, 1, 0, 0])
    // A lone last window has nothing to agree with.
    #expect(LanguageMerge.smooth([0, 0, 1, 1, 0], switchWindows: 2) == [0, 0, 1, 1, 1])
    // A lone first window does not set the language: the first agreeing run does.
    #expect(LanguageMerge.smooth([1, 0, 0, 0], switchWindows: 2) == [0, 0, 0, 0])
    #expect(LanguageMerge.smooth([0, 1, 0, 1], switchWindows: 2) == [0, 0, 0, 0])
    #expect(LanguageMerge.smooth([0, 1, 0, 1], switchWindows: 1) == [0, 1, 0, 1])
    #expect(LanguageMerge.smooth([0, 1, 1, 1, 2, 2], switchWindows: 3) == [1, 1, 1, 1, 1, 1])
}

// MARK: - Echo in calls (rule 5)

/// A call: the user speaks French on the microphone (0–6 s and 9–18 s); the far end says one English phrase on the
/// system track (6–9 s), which the laptop speakers play back into the microphone 0.1 s later.
private func languageMergeEchoCall(echo: Bool) -> [LanguageMerge.Candidate] {
    func heard(by model: String, prefix: String) -> [TranscriptSegment] {
        [languageMergePassage("fr", heardBy: model, from: 0, seconds: 6, track: "mic", id: "\(prefix)1"),
         languageMergePassage("en", heardBy: model, from: 6.1, seconds: 3, track: "mic", id: "\(prefix)E"),
         languageMergePassage("fr", heardBy: model, from: 9, seconds: 9, track: "mic", id: "\(prefix)3"),
         languageMergePassage("en", heardBy: model, from: 6, seconds: 3, track: "system", id: "\(prefix)S")]
    }
    return [
        LanguageMerge.Candidate(language: french, segments: heard(by: "fr", prefix: "F"),
                                echo: echo ? [WordSpan(segmentID: "FE", first: 0, end: 6)] : []),
        LanguageMerge.Candidate(language: english, segments: heard(by: "en", prefix: "E"),
                                echo: echo ? [WordSpan(segmentID: "EE", first: 0, end: 6)] : []),
    ]
}

@Test func echoWindowFollowsTheSystemTracksLanguage() {
    // Without echo, the lone English window on the microphone is smoothed to French: the microphone keeps the
    // French model's words for the phrase while the system track keeps the English model's, which no longer match.
    let smoothed = languageMergeRun(languageMergeEchoCall(echo: false))
    #expect(smoothed.segments.filter { $0.track == "mic" }.map(\.id) == ["F1", "FE", "F3"])
    #expect(smoothed.segments.filter { $0.track == "system" }.map(\.id) == ["ES"])

    // With the echo each transcription found, that window takes the system track's language, so both tracks keep
    // the same model's words and the speaker stages' echo filter can drop the microphone copy.
    let result = languageMergeRun(languageMergeEchoCall(echo: true))
    let mic = result.segments.filter { $0.track == "mic" }
    #expect(mic.map(\.id) == ["F1", "EE", "F3"])
    #expect(mic.map(\.language) == [french, english, french])
    #expect(result.segments.filter { $0.track == "system" }.map(\.id) == ["ES"])
    #expect(mic[1].text == result.segments.first { $0.track == "system" }?.text)
}

@Test func echoNeedsHalfOfTheWindowsWordsAndSystemChoiceBreaksTies() {
    // Echo on only 2 of the window's 6 words does not pin it.
    var candidates = languageMergeEchoCall(echo: true)
    candidates[0].echo = [WordSpan(segmentID: "FE", first: 0, end: 2)]
    candidates[1].echo = [WordSpan(segmentID: "EE", first: 0, end: 2)]
    #expect(languageMergeRun(candidates).segments.filter { $0.track == "mic" }.map(\.id) == ["F1", "FE", "F3"])

    // Echo heard only in French is followed even though the system track chose English.
    candidates = languageMergeEchoCall(echo: true)
    candidates[1].echo = []
    #expect(languageMergeRun(candidates).segments.filter { $0.track == "mic" }.map(\.id) == ["F1", "FE", "F3"])
}

@Test func echoInAnUntimedSegmentIsMeasuredInWords() {
    // The English transcription heard the echoed phrase as one untimed (legacy) segment of 12 words, which moves as
    // one unit; echo is still counted by its words, not by that one unit.
    func candidates(echoedWords: Int) -> [LanguageMerge.Candidate] {
        var calls = languageMergeEchoCall(echo: false)
        let words = (0..<12).map { "en-\(12 + $0)@en" }.joined(separator: " ")
        calls[1].segments = calls[1].segments.map { segment in
            segment.id == "EE" ? TranscriptSegment(id: "EE", start: 6.1, end: 9.1, text: words, track: "mic") : segment
        }
        calls[1].echo = [WordSpan(segmentID: "EE", first: 0, end: echoedWords)]
        return calls
    }
    func mic(_ result: LanguageMerge.Result) -> [String] {
        result.segments.filter { $0.track == "mic" }.map(\.id)
    }
    // 3 echoed words of 12 are not half of the window's words: the window is smoothed to French as without echo.
    #expect(mic(languageMergeRun(candidates(echoedWords: 3))) == ["F1", "FE", "F3"])
    #expect(mic(languageMergeRun(candidates(echoedWords: 5))) == ["F1", "FE", "F3"])
    // Half of them, or all, pin it to the system track's language.
    #expect(mic(languageMergeRun(candidates(echoedWords: 6))) == ["F1", "EE", "F3"])
    #expect(mic(languageMergeRun(candidates(echoedWords: 12))) == ["F1", "EE", "F3"])
}

@Test func pinnedWindowsTakeNoPartInSmoothing() {
    #expect(LanguageMerge.smooth([0, 0, 1, 0, 0], switchWindows: 2, pinned: [nil, nil, 1, nil, nil])
        == [0, 0, 1, 0, 0])
    // A pinned window between two windows that agree does not break their run.
    #expect(LanguageMerge.smooth([0, 0, 1, 0, 1, 0], switchWindows: 2, pinned: [nil, nil, nil, 0, nil, nil])
        == [0, 0, 1, 0, 1, 1])
    #expect(LanguageMerge.smooth([0, 1], switchWindows: 2, pinned: []) == LanguageMerge.smooth([0, 1], switchWindows: 2))
}

// MARK: - Language identification

@Test func naturalLanguageScorerTellsFrenchFromEnglish() {
    let scorer = NaturalLanguageScorer()
    let frenchText = scorer.probabilities(of: "nous allons voter la proposition du conseil la semaine prochaine",
                                          among: [french, english])
    #expect((frenchText[french] ?? 0) > 0.8)
    #expect(abs((frenchText[french] ?? 0) + (frenchText[english] ?? 0) - 1) < 1e-9)
    let englishText = scorer.probabilities(of: "we should move the vote to next week because the report is ready",
                                           among: [french, english])
    #expect((englishText[english] ?? 0) > 0.8)
    // Two regions of one language share its probability.
    let shared = scorer.probabilities(of: "the report is ready", among: ["en-CA", "en-US"])
    #expect(abs((shared["en-CA"] ?? 0) - 0.5) < 1e-9 && abs((shared["en-US"] ?? 0) - 0.5) < 1e-9)
    #expect(NaturalLanguageScorer.naturalLanguage("zh-TW") == .traditionalChinese)
    #expect(NaturalLanguageScorer.naturalLanguage("zh-CN") == .simplifiedChinese)
    #expect(NaturalLanguageScorer.naturalLanguage("fr-CA") == .french)
}
