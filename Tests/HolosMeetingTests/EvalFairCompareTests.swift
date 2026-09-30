import Foundation
import Testing
import HolosCore
@testable import HolosMeeting

// The normalized comparison of `voiceislocal eval compare` (docs/reference-evaluation.md, "Fair comparison"): number
// spellings, fillers, compounds, term hit rates, the echo flag, and the review page's formatting filter. Synthetic
// text only.

private func fairTimed(_ words: [String], from start: Double = 0, echo: Set<Int> = []) -> [EvalToken] {
    words.enumerated().map { index, word in
        EvalToken(text: word, start: start + Double(index), end: start + Double(index) + 0.8,
                  echo: echo.contains(index))
    }
}

private func fairUntimed(_ text: String) -> [EvalToken] { EvalText.tokens(text).map { EvalToken(text: $0) } }

private func canonical(_ text: String) -> String? {
    // Cut into words as the comparison cuts them ("30 %" is one word, as "$ 50" is).
    EvalNormalization.number(EvalText.tokens(text))?.canonical
}

// MARK: - Numbers

@Test func fairEnglishNumbersHaveOneCanonicalForm() {
    let table: [(String, String)] = [
        ("3", "3"), ("three", "3"), ("ten", "10"), ("twenty one", "21"), ("twenty-one", "21"), ("21", "21"),
        ("one hundred", "100"), ("a hundred", "100"), ("one hundred and five", "105"), ("fifteen hundred", "1500"),
        ("two thousand twenty six", "2026"), ("twenty twenty six", "2026"), ("nineteen eighty four", "1984"),
        ("twenty oh five", "2005"), ("1,000", "1000"), ("a thousand", "1000"), ("three point five", "3.5"),
        ("3.5", "3.5"), ("first", "1º"), ("1st", "1º"), ("second", "2º"), ("2nd", "2º"), ("third", "3º"),
        ("3rd", "3º"), ("twenty first", "21º"), ("21st", "21º"), ("fourth", "4º"), ("twelfth", "12º"),
        ("twentieth", "20º"), ("plus 30", "+30"), ("+30", "+30"), ("plus thirty", "+30"), ("30%", "30%"),
        ("30 %", "30%"), ("thirty percent", "30%"), ("30 percent", "30%"), ("thirty per cent", "30%"),
        ("zero", "0"), ("Three,", "3"), ("007", "7"),
    ]
    for (text, expected) in table {
        #expect(canonical(text) == expected, "\(text)")
    }
}

@Test func fairFrenchNumbersHaveOneCanonicalForm() {
    let table: [(String, String)] = [
        ("trois", "3"), ("dix", "10"), ("vingt et un", "21"), ("vingt-deux", "22"), ("soixante-dix", "70"),
        ("soixante et onze", "71"), ("soixante-dix-sept", "77"), ("quatre-vingts", "80"), ("quatre-vingt-un", "81"),
        ("quatre-vingt-dix", "90"), ("quatre-vingt-dix-neuf", "99"), ("dix-sept", "17"), ("cent", "100"),
        ("deux cents", "200"), ("cent cinq", "105"), ("mille", "1000"), ("deux mille vingt-six", "2026"),
        ("trois millions", "3000000"), ("premier", "1º"), ("première", "1º"), ("1er", "1º"), ("1re", "1º"),
        ("deuxième", "2º"), ("2e", "2º"), ("2ème", "2º"), ("cinquième", "5º"), ("neuvième", "9º"),
        ("vingt et unième", "21º"), ("trente pour cent", "30%"), ("30 pourcent", "30%"),
        ("trois virgule cinq", "3.5"), ("3,5", "3.5"), ("trois virgule vingt-cinq", "3.25"),
    ]
    for (text, expected) in table {
        #expect(canonical(text) == expected, "\(text)")
    }
}

@Test func fairWordsThatAreNoNumberStayWords() {
    for text in ["one two", "twenty thirty forty", "five five", "ten five", "hundred", "and five", "a", "plus",
                 "percent", "3:30", "-5", "$50", "1-2", "v2", "deux trois", "vingt dix", "the first one", "1.5.2",
                 "oh", "COVID-19", "30%%", "1st%"] {
        #expect(canonical(text) == nil, "\(text)")
    }
    // A decimal keeps its digits: "1.000" is not "1", and "1,5" is 1.5 while "1,500" is 1500.
    #expect(canonical("1.000") == "1.000")
    #expect(canonical("1,500") == "1500")
    #expect(canonical("1,5") == "1.5")
}

@Test func fairOnlyASpelledNumberAgainstDigitsIsTheSame() {
    // "three" and "3" are the same; "one" and "un", or "first" and "premier", are not (both spelled).
    #expect(NormalizedAlignment.align(["three"], ["3"]) == [.equal(0, 0, .number)])
    #expect(NormalizedAlignment.align(["one"], ["un"]) == [.substitute(0, 0)])
    #expect(NormalizedAlignment.align(["first"], ["premier"]) == [.substitute(0, 0)])
    #expect(NormalizedAlignment.align(["1st"], ["1er"]) == [.equal(0, 0, .number)])
    // Different numbers, and a cardinal against an ordinal, stay errors.
    #expect(NormalizedAlignment.align(["three"], ["4"]) == [.substitute(0, 0)])
    #expect(NormalizedAlignment.align(["first"], ["1"]) == [.substitute(0, 0)])
    #expect(NormalizedAlignment.align(["+30"], ["30"]) == [.substitute(0, 0)])
    #expect(NormalizedAlignment.align(["30%"], ["30"]) == [.substitute(0, 0)])
    #expect(NormalizedAlignment.align(["won"], ["1"]) == [.substitute(0, 0)])
}

// MARK: - Fillers

@Test func fairFillersAreLeftOutOnBothSides() {
    for word in ["um", "Um,", "uh", "UH.", "er", "erm", "hmm", "Hmm.", "mm", "Mmm", "ah", "ummm", "euh", "heu",
                 "Euhhh,", "bah", "hein"] {
        #expect(EvalNormalization.isFiller(word), "\(word)")
    }
    for word in ["M", "a", "I", "ben", "umbrella", "uh-huh", "oh", "ahead", "hum", "mhm", "err", "Err,"] {
        #expect(!EvalNormalization.isFiller(word), "\(word)")
    }
    let local = ["Um,", "so", "we", "uh", "ship"]
    let cloud = ["So", "we", "ship", "euh"]
    let ops = NormalizedAlignment.align(local, cloud)
    #expect(ops == [.fillerLocal(0), .equal(1, 0, .same), .equal(2, 1, .same), .fillerLocal(3),
                    .equal(4, 2, .same), .fillerCloud(3)])
    let scored = NormalizedAlignment.score(ops, a: local, b: cloud)
    #expect(scored.score.localWords == 3 && scored.score.cloudWords == 3 && scored.score.edits == 0)
    #expect(scored.counts.fillersLocal == 2 && scored.counts.fillersCloud == 1)
    // "mm" after a number is millimetres, also when the number is just before the passage.
    #expect(EvalNormalization.fillerFlags(["5", "mm", "mm"]) == [false, false, true])
    #expect(NormalizedAlignment.align(["mm"], [], before: (["5"], ["5"])) == [.localOnly(0)])
    let millimetres = WindowComparer.compare(track: "system", local: fairTimed(["cut", "5", "mm"]),
                                             cloud: fairUntimed("cut 5"), start: 0, end: 10)
    #expect(millimetres.normalized.edits == 1)
    #expect(millimetres.passages.map(\.formattingOnly) == [false])
    // A filler is never taken for the word the other side has there.
    #expect(NormalizedAlignment.align(["uh"], ["a"]) == [.cloudOnly(0), .fillerLocal(0)])
}

// MARK: - Joins and splits

@Test func fairCompoundsAndSpelledNumbersJoinAndSplit() {
    #expect(NormalizedAlignment.align(["test", "flight"], ["TestFlight"])
        == [.join(local: 0..<2, cloud: 0..<1, .compound)])
    #expect(NormalizedAlignment.align(["ChatGPT"], ["chat", "GPT"]) == [.join(local: 0..<1, cloud: 0..<2, .compound)])
    #expect(NormalizedAlignment.align(["A", "P", "I"], ["API"]) == [.join(local: 0..<3, cloud: 0..<1, .compound)])
    #expect(NormalizedAlignment.align(["V", "one,"], ["v1"]) == [.join(local: 0..<2, cloud: 0..<1, .compound)])
    #expect(NormalizedAlignment.align(["twenty", "one", "people"], ["21", "people"])
        == [.join(local: 0..<2, cloud: 0..<1, .number), .equal(2, 1, .same)])
    #expect(NormalizedAlignment.align(["plus", "30"], ["+30"]) == [.join(local: 0..<2, cloud: 0..<1, .number)])
    #expect(NormalizedAlignment.align(["one", "hundred", "and", "twenty", "five"], ["125"])
        == [.join(local: 0..<5, cloud: 0..<1, .number)])
    // Four words are not one compound, digits alone make no compound, and a real error is still one.
    #expect(NormalizedAlignment.align(["a", "b", "c", "d"], ["abcd"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["1", "5"], ["15"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["one", "two"], ["12"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["React", "Native"], ["reactative"]).contains { $0.isEdit })
    // A run of spelled numbers in a compound is one number: "V twenty one" is "V21", never "V201".
    #expect(NormalizedAlignment.align(["V", "twenty", "one"], ["V21"])
        == [.join(local: 0..<3, cloud: 0..<1, .compound)])
    #expect(NormalizedAlignment.align(["V", "twenty", "one"], ["V201"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["V", "one", "two"], ["V12"]).contains { $0.isEdit })
    // Fillers inside a joined run are left out as fillers.
    let hesitant = ["twenty", "um", "one", "test", "uh", "flight"]
    let hesitantOps = NormalizedAlignment.align(hesitant, ["21", "TestFlight"])
    #expect(hesitantOps == [.join(local: 0..<3, cloud: 0..<1, .number), .join(local: 3..<6, cloud: 1..<2, .compound)])
    let hesitantScore = NormalizedAlignment.score(hesitantOps, a: hesitant, b: ["21", "TestFlight"])
    #expect(hesitantScore.score.edits == 0 && hesitantScore.score.localWords == 4)
    #expect(hesitantScore.counts.fillersLocal == 2)
    let local = ["we", "use", "test", "flight", "and", "chat", "GPT"]
    let cloud = ["We", "use", "TestFlight", "and", "ChatGPT."]
    let scored = NormalizedAlignment.score(NormalizedAlignment.align(local, cloud), a: local, b: cloud)
    #expect(scored.score.edits == 0 && scored.counts.compounds == 2)
    #expect(scored.score.localWords == 7 && scored.score.cloudWords == 5)
}

@Test func fairJoinsNeedAWrittenCompoundAndWholeNumbers() {
    // A plain word shows no join: "now here" is not "nowhere", "check up" not "checkup".
    #expect(NormalizedAlignment.align(["now", "here"], ["nowhere"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["check", "up"], ["checkup"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["follow", "up"], ["follow-up"]) == [.join(local: 0..<2, cloud: 0..<1, .compound)])
    // Capitals alone join only letters said one by one.
    #expect(NormalizedAlignment.align(["now", "here"], ["NOWHERE"]).contains { $0.isEdit })
    // A spelled number is taken whole: "twenty one" is never 20 and 1, "quatre vingt" never 4 and 20.
    #expect(NormalizedAlignment.align(["twenty", "one"], ["20", "1"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["quatre", "vingt"], ["4", "20"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["one", "hundred", "and", "five"], ["100", "and", "5"]).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(["three", "and", "five"], ["3", "and", "5"]).allSatisfy { !$0.isEdit })
    // Too large to align again: paired in order, no matrix.
    let big = NormalizedAlignment.align(["a", "um", "b", "c"], ["a", "x"], cellLimit: 4)
    #expect(big == [.fillerLocal(1), .equal(0, 0, .same), .substitute(2, 1), .localOnly(3)])
}

@Test func fairFillersFollowTheMeetingsLanguages() {
    #expect(EvalNormalization.fillers(languages: ["en-CA"]) == EvalNormalization.englishFillers)
    #expect(EvalNormalization.fillers(languages: ["fr-CA", "en-US"]) == EvalNormalization.allFillers)
    #expect(EvalNormalization.fillers(languages: ["de-DE"]).isEmpty)
    let german = WindowComparer.compare(track: "mic", local: fairTimed(["Er", "kommt"]), cloud: fairUntimed("kommt"),
                                        start: 0, end: 5, fillers: EvalNormalization.fillers(languages: ["de-DE"]))
    #expect(german.normalized.edits == 1)
    #expect(!EvalNormalization.isFiller("euh", fillers: EvalNormalization.englishFillers))
    // A mark inside is no filler ("H&M"), nor "mm" after a spelled number.
    #expect(!EvalNormalization.isFiller("H&M"))
    #expect(EvalNormalization.fillerFlags(["five", "mm"]) == [false, false])
}

@Test func fairPassagesSplitByAFewMatchedWordsAreNormalizedTogether() {
    // The raw alignment matches the second "test" and leaves "test" and "flight"/"TestFlight" apart.
    let local = fairTimed(["we", "test", "test", "flight", "daily"])
    let result = WindowComparer.compare(track: "system", local: local, cloud: fairUntimed("we test TestFlight daily"),
                                        start: 0, end: 10)
    #expect(result.score.edits == 2)
    #expect(result.normalized.edits == 0)
    #expect(result.passages.allSatisfy { $0.formattingOnly })
    // A matched filler between the halves of a number does not split it either.
    let hesitant = WindowComparer.compare(track: "system", local: fairTimed(["twenty", "um", "one", "days"]),
                                          cloud: fairUntimed("21 um days"), start: 0, end: 10)
    #expect(hesitant.normalized.edits == 0)
    // A real error in the stretch stays on its own passage.
    let mixed = WindowComparer.compare(track: "system", local: fairTimed(["three", "cats", "and", "a", "dog"]),
                                       cloud: fairUntimed("3 cats and a frog"), start: 0, end: 10)
    #expect(mixed.passages.map(\.formattingOnly) == [true, false])
    #expect(mixed.normalized.edits == 1)
}

@Test func fairTermsAreFoundWithTheirNumbersSpelledEitherWay() {
    let terms = EvalTerms.terms(wordList: ["GPT-4"], corrections: [])
    let track = EvalTerms.Track(track: "system", words: ["we", "use", "GPT", "four"], covered: [true, true, true, false])
    #expect(EvalTerms.count(terms, tracks: [track], normalized: true).map { "\($0.hits)/\($0.cloud)" } == ["0/1"])
    #expect(EvalTerms.count(terms, tracks: [track]).isEmpty)
    // Never a prefix of a longer spelled number: "V twenty" of "V twenty one" is not "V20".
    let v20 = EvalTerms.terms(wordList: ["V20"], corrections: [])
    let longer = EvalTerms.Track(track: "system", words: ["we", "use", "V", "twenty", "one"],
                                 covered: [true, true, true, true, true])
    #expect(EvalTerms.count(v20, tracks: [longer], normalized: true).isEmpty)
}

@Test func fairAnEditMovedOntoAMatchedWordStaysForReview() {
    let result = WindowComparer.compare(track: "system", local: fairTimed(["we", "use", "TestFlight", "test", "um",
                                                                           "daily"]),
                                        cloud: fairUntimed("we use test flight daily"), start: 0, end: 10)
    #expect(result.normalized.edits == 1)
    #expect(result.passages.filter { $0.group != .caseOrPunctuation }.allSatisfy { !$0.formattingOnly })
}

@Test func fairAmbiguousNumberFormsStayDifferent() {
    #expect(canonical("0,125%") == "0.125%")
    #expect(NormalizedAlignment.align(["0,125%"], ["125%"]).contains { $0.isEdit })
    // "dix" joins only sept, huit, neuf: "dix deux" is no French number.
    #expect(canonical("dix deux") == nil)
    #expect(canonical("dix-neuf") == "19")
}

// MARK: - Window scores and passages

@Test func fairWindowScoresNormalizedAndMarksFormattingOnlyPassages() {
    let local = fairTimed(["um", "we", "have", "three", "builds", "in", "test", "flight", "and", "the", "cat"])
    let cloud = fairUntimed("We have 3 builds in TestFlight and the bat.")
    let result = WindowComparer.compare(track: "system", local: local, cloud: cloud, start: 0, end: 20)
    // Raw: "um" only local, "three"/"3", "test flight"/"TestFlight", "cat"/"bat."
    #expect(result.score.edits == 5)
    #expect(result.normalized.edits == 1)
    #expect(result.normalized.localWords == 10 && result.normalized.cloudWords == 9)
    #expect(result.normalization.fillersLocal == 1)
    #expect(result.normalization.numbers == 1 && result.normalization.compounds == 1)
    let words = result.passages.filter { $0.group != .caseOrPunctuation }
    #expect(words.map(\.local) == ["um", "three", "test flight", "cat"])
    #expect(words.map(\.formattingOnly) == [true, true, true, false])
    #expect(words.map(\.needsReview) == [false, false, false, true])
    // Per cloud word: whether the local transcript has it (raw by key; normalized).
    #expect(result.cloudMatched == [true, true, false, true, true, false, true, true, false])
    #expect(result.cloudEquivalent == [true, true, true, true, true, true, true, true, false])
}

@Test func fairEchoIsLeftOutOfTheNormalizedScoreAndTheTrackIsFlagged() {
    let local = fairTimed(["hello", "echo", "echo", "echo", "echo", "um", "team"], echo: [1, 2, 3, 4])
    let cloud = fairUntimed("hello team")
    let result = WindowComparer.compare(track: "mic", local: local, cloud: cloud, start: 0, end: 10)
    #expect(result.score.localWords == 3 && result.score.echoLocalWords == 4)
    #expect(result.normalized.echoLocalWords == 4)
    #expect(result.normalized.localWords == 2 && result.normalized.edits == 0)
    let report = CompareReport.TrackReport(track: "mic", score: result.score, groups: [:], warnings: [],
                                           normalized: result.normalized, normalization: result.normalization)
    #expect(report.mostlyEcho)
    // As many echo words as kept ones is not "mostly".
    var even = result.score
    even.echoLocalWords = even.localWords
    #expect(!CompareReport.TrackReport(track: "mic", score: even, groups: [:], warnings: []).mostlyEcho)
}

// MARK: - Terms

@Test func fairTermsCountHitsAndMissesWhereTheCloudHasThem() {
    let terms = EvalTerms.terms(wordList: ["TestFlight", "Keycloak", "Urban Sky", "Grafana"],
                                corrections: ["keycloak", "Kubernetes", "  "])
    #expect(terms.map(\.text) == ["TestFlight", "Keycloak", "Urban Sky", "Grafana", "Kubernetes"])
    #expect(terms.map(\.source) == [.wordList, .wordList, .wordList, .wordList, .correction])
    let words = ["We", "use", "Test", "Flight,", "Keycloak", "and", "Kubernetes", "at", "Urban", "Sky.", "Keycloak"]
    let covered: [Bool?] = [true, true, true, true, false, true, true, true, true, false, nil]
    let stats = EvalTerms.count(terms, tracks: [.init(track: "system", words: words, covered: covered)])
    // Keycloak: one miss, one in echo (not counted). Urban Sky: its second word missed. Grafana: never heard.
    #expect(stats.map(\.term) == ["Keycloak", "Urban Sky", "Kubernetes", "TestFlight"])
    #expect(stats.map(\.cloud) == [1, 1, 1, 1])
    #expect(stats.map(\.hits) == [0, 0, 1, 1])
    #expect(stats.map(\.misses) == [1, 1, 0, 0])
    #expect(stats[0].tracks == [.init(track: "system", cloud: 1, hits: 0)])
    // Across tracks, each track's share is kept.
    let two = EvalTerms.count(terms, tracks: [.init(track: "mic", words: ["Keycloak"], covered: [true]),
                                                .init(track: "system", words: words, covered: covered)])
    #expect(two.first { $0.term == "Keycloak" }?.tracks
        == [.init(track: "mic", cloud: 1, hits: 1), .init(track: "system", cloud: 1, hits: 0)])
    // Whole words only.
    #expect(EvalTerms.occurrences(of: "sky", in: ["skyline", "sky"]) == [1..<2])
    #expect(EvalTerms.occurrences(of: "testflight", in: ["test", "flight", "testflight"]) == [0..<2, 2..<3])
}

@Test func fairTermHitsFollowTheNormalizedComparison() {
    // The local transcript writes the term as two words: a hit under the normalized comparison, a miss raw.
    let local = fairTimed(["ship", "it", "in", "test", "flight", "with", "cube", "control"])
    let cloud = fairUntimed("Ship it in TestFlight with kubectl")
    let result = WindowComparer.compare(track: "system", local: local, cloud: cloud, start: 0, end: 20)
    let terms = EvalTerms.terms(wordList: ["TestFlight", "kubectl"], corrections: [])
    let words = cloud.map(\.text)
    let ignorable = local.map { $0.echo || EvalNormalization.isFiller($0.text) }
    let normalized = EvalTerms.count(terms, tracks: [.init(track: "system", words: words,
                                                           covered: result.cloudEquivalent,
                                                           spans: result.cloudEquivalentSpans, ignorable: ignorable)])
    let raw = EvalTerms.count(terms, tracks: [.init(track: "system", words: words, covered: result.cloudMatched,
                                                    spans: result.cloudMatchedSpans, ignorable: ignorable)])
    #expect(normalized.map { "\($0.term) \($0.hits)/\($0.cloud)" } == ["kubectl 0/1", "TestFlight 1/1"])
    #expect(raw.map { "\($0.term) \($0.hits)/\($0.cloud)" } == ["kubectl 0/1", "TestFlight 0/1"])
}

@Test func fairAPhraseIsAHitOnlyAsOneUnbrokenLocalRun() {
    let terms = EvalTerms.terms(wordList: ["machine learning"], corrections: [])
    func hits(_ localWords: [String], echo: Set<Int> = []) -> Int? {
        let local = fairTimed(localWords, echo: echo)
        let cloud = fairUntimed("we use machine learning daily")
        let result = WindowComparer.compare(track: "system", local: local, cloud: cloud, start: 0, end: 20)
        let track = EvalTerms.Track(track: "system", words: cloud.map(\.text), covered: result.cloudEquivalent,
                                    spans: result.cloudEquivalentSpans,
                                    ignorable: local.map { $0.echo || EvalNormalization.isFiller($0.text) })
        return EvalTerms.count(terms, tracks: [track]).first?.hits
    }
    #expect(hits(["we", "use", "machine", "learning", "daily"]) == 1)
    // A word between the phrase's words: both are matched, the phrase is not there.
    #expect(hits(["we", "use", "machine", "deep", "learning", "daily"]) == 0)
    // A filler between them is no break.
    #expect(hits(["we", "use", "machine", "um", "learning", "daily"]) == 1)
    #expect(hits(["we", "use", "MachineLearning", "daily"]) == 1)
    #expect(hits(["we", "use", "machinelearning", "daily"]) == 0)
}

// MARK: - Report and review page

private func fairReport(tracks: [CompareReport.TrackReport], passages: [EvalPassage],
                        terms: [TermStat] = []) -> CompareReport {
    var total = EvalScore(), normalized = EvalScore()
    for track in tracks {
        total.add(track.score)
        if let score = track.normalized { normalized.add(score) }
    }
    return CompareReport(sessionID: "SESSION", run: "gpt-transcribe-20260929T000000Z", model: "gpt-transcribe",
                         transcriptID: "T1", createdAt: Date(timeIntervalSince1970: 0), total: total, tracks: tracks,
                         passages: passages, mode: "normalized", normalizedTotal: normalized,
                         normalizationTotal: NormalizationCounts(), terms: terms, termsNotHeard: 2,
                         local: .init(source: "current", languages: ["en-CA"], vocabulary: "vocabulary.json",
                                      vocabularyCount: 3, madeAt: nil))
}

private func fairScore(local: Int, edits: Int, echo: Int = 0) -> EvalScore {
    var score = EvalScore()
    score.localWords = local; score.cloudWords = local; score.substitutions = edits; score.matches = local - edits
    score.echoLocalWords = echo
    return score
}

@Test func fairReportLeadsWithNormalizedWERAndFlagsAnEchoTrack() {
    let mic = CompareReport.TrackReport(track: "mic", score: fairScore(local: 100, edits: 50, echo: 400),
                                        groups: [:], warnings: [], normalized: fairScore(local: 95, edits: 45),
                                        normalization: NormalizationCounts())
    let system = CompareReport.TrackReport(track: "system", score: fairScore(local: 1000, edits: 220, echo: 0),
                                           groups: [:], warnings: [], normalized: fairScore(local: 980, edits: 196),
                                           normalization: NormalizationCounts())
    #expect(mic.mostlyEcho && !system.mostlyEcho)
    let passages = [
        EvalPassage(id: "system-1", track: "system", start: 1, end: 2, local: "three", cloud: "3", group: .numbers,
                    before: "", after: "", localFirst: 0, localEnd: 1, formattingOnly: true),
        EvalPassage(id: "system-2", track: "system", start: 3, end: 4, local: "cat", cloud: "bat",
                    group: .otherWords, before: "", after: "", localFirst: 2, localEnd: 3),
    ]
    let report = fairReport(tracks: [mic, system], passages: passages,
                            terms: [TermStat(term: "Keycloak", source: .wordList, cloud: 4, hits: 1,
                                             tracks: [.init(track: "system", cloud: 4, hits: 1)])])
    let markdown = EvalCompare.markdown(report)
    #expect(markdown.contains("| system | 980 | 980 | 196 | 0 | 0 | 20.0 % | 20.0 % | 22.0 % | 22.0 % |"))
    #expect(markdown.contains("mic ⚠︎ unreliable: mostly echo"))
    #expect(markdown.contains("400 local words were echo of the system track, 100 kept"))
    #expect(markdown.contains("## Terms"))
    #expect(markdown.contains("| Keycloak | word list | 4 | 1 | 3 | – | 1/4 |"))
    #expect(markdown.contains("2 more terms are not in the cloud text."))
    #expect(markdown.contains("## Other word changes (1)"))
    #expect(!markdown.contains("## Numbers"))
    #expect(markdown.contains("## Formatting only: numbers, fillers, compounds (1)"))
    let summary = EvalCompare.summaryLines(report).joined(separator: "\n")
    #expect(summary.contains("system: 980 local words, 980 cloud words; WER 20.0 % against local"))
    #expect(summary.contains("(raw WER 22.0 %, 22.0 %)"))
    #expect(summary.contains("mic is unreliable: mostly echo"))
    #expect(summary.contains("1 passages differ in words (1 more only in numbers, fillers, or compounds)"))
    #expect(summary.contains("Keycloak 3/4"))
}

@Test func fairReviewPageHidesFormattingOnlyPassagesByDefault() throws {
    let passages = [
        EvalPassage(id: "mic-1", track: "mic", start: 1, end: 2, local: "three", cloud: "3", group: .numbers,
                    before: "", after: "", localFirst: 0, localEnd: 1, formattingOnly: true),
        EvalPassage(id: "mic-2", track: "mic", start: 3, end: 4, local: "cat", cloud: "bat", group: .otherWords,
                    before: "", after: "", localFirst: 2, localEnd: 3),
        EvalPassage(id: "mic-3", track: "mic", start: 5, end: 5, local: "We", cloud: "we",
                    group: .caseOrPunctuation, before: "", after: "", localFirst: 4, localEnd: 5),
    ]
    let run = CloudRunRecord(id: "gpt-transcribe-20260929T000000Z", sessionID: "SESSION", createdAt: Date(),
                             request: CloudRequestFields(model: "gpt-transcribe"), timestampRequest: nil,
                             vocabulary: false, maxSegmentSeconds: 300, tracks: [])
    let data = EvalReviewPage.pageData(report: fairReport(tracks: [], passages: passages), run: run,
                                       sessionName: "Standup")
    #expect(data.items.map(\.id) == ["mic-1", "mic-2"])
    #expect(data.items.map(\.formatting) == [true, false])
    let html = try EvalReviewPage.html(data)
    #expect(html.contains("Show formatting-only differences"))
    #expect(html.contains("card.hidden = !!item.formatting"))
    #expect(passages.filter(\.needsReview).map(\.id) == ["mic-2"])
}

@Test func fairOldReportsStillDecode() throws {
    // A report written before the normalized comparison: no mode, no formattingOnly, schema 1.
    let old = """
        {"schemaVersion":1,"sessionID":"S","run":"r","model":"m","transcriptID":"T",
         "createdAt":"2026-09-29T00:00:00Z","total":{"localWords":1,"cloudWords":1,"matches":1,
         "caseOrPunctuationOnly":0,"substitutions":0,"localOnly":0,"cloudOnly":0},"tracks":[],
         "passages":[{"id":"mic-1","track":"mic","start":0,"end":1,"local":"a","cloud":"b","group":"other-words",
         "before":"","after":"","cloudBefore":"","cloudAfter":"","localFirst":0,"localEnd":1}]}
        """
    let report = try HolosJSON.decoder().decode(CompareReport.self, from: Data(old.utf8))
    #expect(report.passages.first?.formattingOnly == false)
    #expect(!report.isNormalized && report.isOfCurrentTranscript)
    #expect(!EvalCompare.isCurrent(report, transcriptID: "T"))
}

@Test func fairMatchedMmIsAFillerByEachSidesOwnContext() {
    // Local "5 mm" is millimetres, cloud "well mm" is a filler: the matched "mm" is a local-only word, not a match.
    let result = WindowComparer.compare(track: "system", local: fairTimed(["cut", "5", "mm", "now"]),
                                        cloud: fairUntimed("cut well mm now"), start: 0, end: 10)
    #expect(result.normalized.localOnly >= 1)
    #expect(result.normalized.edits >= 2)  // "5"/"well" and the one-sided "mm"
}

@Test func fairTermsLongerThanEightWordsAreFound() {
    let phrase = "one two three four five six seven eight nine"
    let terms = EvalTerms.terms(wordList: [phrase], corrections: [])
    let words = ["say"] + phrase.split(separator: " ").map(String.init)
    let track = EvalTerms.Track(track: "system", words: words, covered: Array(repeating: true, count: words.count))
    #expect(EvalTerms.count(terms, tracks: [track]).map { "\($0.hits)/\($0.cloud)" } == ["1/1"])
}

@Test func fairMmAfterASpelledNumberRunIsAUnit() {
    #expect(EvalNormalization.fillerFlags(["mm"], previousWords: ["one", "hundred"]) == [false])
    #expect(EvalNormalization.fillerFlags(["one", "hundred", "mm"]) == [false, false, false])
    #expect(EvalNormalization.fillerFlags(["mm"], previousWords: ["well"]) == [true])
    let unit = WindowComparer.compare(track: "system", local: fairTimed(["cut", "one", "hundred", "mm"]),
                                      cloud: fairUntimed("cut one hundred"), start: 0, end: 10)
    #expect(unit.normalized.edits == 1)
}

@Test func fairOneSidedMatchedFillerDoesNotCoverTheCloudWord() {
    // Local "well mm" (filler) against cloud "5 mm" (millimetres): the cloud's "mm" is not covered by the local one.
    let result = WindowComparer.compare(track: "system", local: fairTimed(["cut", "well", "mm", "now"]),
                                        cloud: fairUntimed("cut 5 mm now"), start: 0, end: 10)
    let mm = 2
    #expect(result.cloudEquivalent[mm] == false)
    // Every cloud word but echo is covered or not: nil is echo only.
    #expect(result.cloudEquivalent.allSatisfy { $0 != nil })
    // So a term the cloud has there is a miss, not unheard.
    let track = EvalTerms.Track(track: "system", words: ["cut", "5", "mm", "now"], covered: result.cloudEquivalent,
                                spans: result.cloudEquivalentSpans)
    let stats = EvalTerms.count(EvalTerms.terms(wordList: ["mm"], corrections: []), tracks: [track], normalized: true)
    #expect(stats.map { "\($0.hits)/\($0.cloud)" } == ["0/1"])
}

@Test func fairScaleWordsJoinTheSpelledNumberBeforeThem() {
    #expect(NormalizedAlignment.compoundForms(["V", "one", "hundred"]).contains("v100"))
    #expect(NormalizedAlignment.compoundForms(["V", "two", "thousand"]).contains("v2000"))
    // A scale word alone is not a number.
    #expect(!NormalizedAlignment.compoundForms(["V", "hundred"]).contains("v100"))
}

// MARK: - Spelled-number runs

private func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

@Test func fairSpelledNumberRunsAreMaximal() {
    let table: [(String, [Range<Int>])] = [
        ("one hundred and twenty", [0..<4]),
        ("V one hundred five", [1..<4]),
        ("twenty one", [0..<2]),
        ("twenty one twenty", [0..<3]),  // a year: 2120
        ("one two", [0..<1, 1..<2]),
        ("three and five", [0..<1, 2..<3]),
        ("one hundred and", [0..<2]),
        ("cent vingt", [0..<2]),
        ("quatre-vingt-dix-sept", [0..<1]),
        ("quatre vingt dix sept", [0..<4]),
        ("vingt et un", [0..<3]),
        ("three point five", [0..<3]),
        ("trois virgule cinq", [0..<3]),
        ("twenty first", [0..<2]),
        ("vingt et unième", [0..<3]),
        ("plus thirty percent", [0..<3]),
        ("twenty um one", [0..<3]),
        ("um twenty", [1..<2]),
        ("twenty. One", [0..<1, 1..<2]),
        ("we need a hundred", [2..<4]),
        ("a cat", []),
        ("5 mm", []),
    ]
    for (text, runs) in table {
        #expect(EvalNormalization.SpelledRuns(words(text)).runs == runs, "\(text)")
    }
}

@Test func fairASpelledNumberEqualsDigitsOnlyAsAWholeRun() {
    // (local, cloud, whether they are the same number): a prefix, a suffix, or the middle of a longer spelled number
    // is never a shorter number; the whole run is its digits.
    let table: [(String, String, Bool)] = [
        ("one hundred and twenty", "20", false), ("one hundred and twenty", "100", false),
        ("one hundred and twenty", "120", true), ("one hundred twenty five", "20", false),
        ("twenty one", "20 1", false), ("twenty one", "21", true), ("twenty one", "1", false),
        ("cent vingt", "120", true), ("cent vingt", "20", false), ("cent vingt", "100", false),
        ("quatre-vingt-dix-sept", "97", true), ("quatre vingt dix sept", "97", true),
        ("quatre vingt dix sept", "7", false), ("quatre vingt dix sept", "90", false),
        ("three point five", "3.5", true), ("three point five", "5", false), ("three point five", "3", false),
        ("trois virgule cinq", "3,5", true), ("trois virgule cinq", "5", false),
        ("twenty first", "21st", true), ("twenty first", "1st", false), ("vingt et unième", "21e", true),
        ("vingt et unième", "1er", false), ("three and five", "3 and 5", true),
        // "plus" and "percent" around a number leave its words whole.
        ("thirty percent", "30%", true), ("thirty percent", "30 percent", true), ("plus thirty", "plus 30", true),
        ("vingt pour cent", "20 pour cent", true), ("one hundred and twenty percent", "20 percent", false),
        // However many words a run takes.
        ("one thousand two hundred thirty four", "1234", true),
        ("nine hundred and ninety nine thousand nine hundred and ninety nine", "999999", true),
        ("deux mille trois cent quarante-cinq", "2345", true),
        ("one thousand two hundred thirty four", "234", false),
    ]
    for (local, cloud, same) in table {
        let ops = NormalizedAlignment.align(words(local), words(cloud))
        #expect(ops.contains { $0.isEdit } == !same, "\(local) / \(cloud)")
    }
}

@Test func fairSpelledNumbersAtAStretchsEdgeSeeTheWordsAround() {
    // "twenty" after "one hundred and" is the end of 120, not 20; "one hundred" before "five" the start of 105.
    #expect(NormalizedAlignment.align(["twenty"], ["20"], before: (words("we need one hundred and"), []))
        == [.substitute(0, 0)])
    #expect(NormalizedAlignment.align(["twenty"], ["20"], before: (words("we need"), [])) == [.equal(0, 0, .number)])
    #expect(NormalizedAlignment.align(words("one hundred"), ["100"], after: (["five"], [])).contains { $0.isEdit })
    #expect(NormalizedAlignment.align(words("V one"), ["V1"], after: (["hundred"], [])).contains { $0.isEdit })
    // In a window: the raw alignment matches "twenty", leaving "one hundred" against "100".
    let prefix = WindowComparer.compare(track: "system", local: fairTimed(words("we need one hundred twenty now")),
                                        cloud: fairUntimed("we need 100 twenty now"), start: 0, end: 10)
    #expect(prefix.normalized.edits > 0)
    #expect(prefix.normalization.numbers == 0)
    // However far the number goes on past the stretch: the runs are found over all the window's words.
    let long = WindowComparer.compare(
        track: "system", local: fairTimed(words("V nine hundred and ninety nine thousand nine hundred and ninety nine now")),
        cloud: fairUntimed("V 999 thousand nine hundred and ninety nine now"), start: 0, end: 20)
    #expect(long.normalized.edits > 0)
    #expect(long.normalization.numbers == 0)
}

@Test func fairSpelledNumberRunsHaveNoLengthLimit() {
    let english = "plus nine hundred and ninety nine billion nine hundred and ninety nine million nine hundred and "
        + "ninety nine thousand nine hundred and ninety nine percent"
    let french = "neuf cent quatre vingt dix neuf milliards neuf cent quatre vingt dix neuf millions neuf cent "
        + "quatre vingt dix neuf mille neuf cent quatre vingt dix neuf"
    #expect(EvalNormalization.SpelledRuns(words(english)).runs == [0..<25])
    #expect(EvalNormalization.SpelledRuns(words(french)).runs == [0..<27])
    #expect(NormalizedAlignment.align(words(english), ["+999999999999%"]) == [.join(local: 0..<25, cloud: 0..<1, .number)])
    #expect(NormalizedAlignment.align(words(french), ["999999999999"]) == [.join(local: 0..<27, cloud: 0..<1, .number)])
    // Number words that are no number stop a run: a count is one number per word.
    #expect(EvalNormalization.SpelledRuns(words("one two three four five six")).runs.count == 6)
}

@Test func fairTermsNeverStartOrEndInsideASpelledNumber() {
    func count(_ term: String, _ text: String) -> Int {
        let track = EvalTerms.Track(track: "system", words: words(text),
                                    covered: Array(repeating: true, count: words(text).count))
        return EvalTerms.count(EvalTerms.terms(wordList: [term], corrections: []), tracks: [track], normalized: true)
            .first?.cloud ?? 0
    }
    let table: [(String, String, Int)] = [
        ("V100", "we use V one hundred five", 0), ("V105", "we use V one hundred five", 1),
        ("V100", "we use V one hundred now", 1), ("V20", "we use V twenty one", 0),
        ("V120", "on a V cent vingt", 1), ("V20", "on a V cent vingt", 0),
        ("GPT-4", "GPT four and GPT four hundred", 1), ("V12", "V one two", 0),
        ("V999999", "V nine hundred and ninety nine thousand nine hundred and ninety nine", 1),
        ("V999", "V nine hundred and ninety nine thousand nine hundred and ninety nine", 0),
        // A term that is or holds a number is found with the number written the other way, as the alignment reads it.
        ("twenty one", "we have 21 people", 1), ("21", "we have twenty one people", 1),
        ("twenty one", "we have 20 1 people", 0), ("twenty one", "on a vingt et un", 0),
        ("twenty", "one hundred and twenty", 0), ("thirty percent", "about 30% more", 1),
        ("thirty percent", "about 30 percent more", 1), ("30%", "about thirty per cent more", 1),
        ("3.5", "version three point five", 1), ("version 2", "version two now", 1),
        ("plus thirty", "a +30 gain", 1), ("21st", "the twenty first time", 1), ("1st", "the twenty first time", 0),
    ]
    for (term, text, expected) in table {
        #expect(count(term, text) == expected, "\(term) in \(text)")
    }
    #expect(!NormalizedAlignment.compoundForms(words("V one hundred five")).contains("v100"))
    #expect(NormalizedAlignment.compoundForms(words("V one hundred five")).contains("v105"))
    #expect(!NormalizedAlignment.compoundForms(["V2", "one"]).contains("v21"))
}

@Test func fairTermsAreFoundPastEchoAndFillersBetweenTheirWords() {
    let terms = EvalTerms.terms(wordList: ["New York"], corrections: [])
    func stat(_ text: String, covered: [Bool?], skipped: [Bool] = [], normalized: Bool = false) -> String? {
        let track = EvalTerms.Track(track: "system", words: words(text), covered: covered, skipped: skipped)
        return EvalTerms.count(terms, tracks: [track], normalized: normalized).first.map { "\($0.hits)/\($0.cloud)" }
    }
    // An echo word between the term's words is left out, as echo is everywhere else.
    #expect(stat("we went New there York", covered: [true, true, true, nil, true]) == "1/1")
    #expect(stat("we went New there York", covered: [true, true, true, nil, false]) == "0/1")
    // Under the normalized comparison a filler between them is too; the raw comparison reads it as a word.
    #expect(stat("New um York", covered: [true, true, true], skipped: [false, true, false], normalized: true) == "1/1")
    #expect(stat("New um York", covered: [true, true, true]) == nil)
    // An echo word that is part of the term leaves it unheard.
    #expect(stat("New York", covered: [true, nil]) == nil)
}

@Test func fairMmFollowsTheWholeSpelledNumberBeforeIt() {
    #expect(EvalNormalization.fillerFlags(["mm"], previousWords: words("one hundred and five")) == [false])
    #expect(EvalNormalization.fillerFlags(["mm"], previousWords: words("one hundred and")) == [true])
    #expect(EvalNormalization.fillerFlags(words("twenty um mm")) == [false, true, true])
    #expect(EvalNormalization.fillerFlags(words("cent vingt mm")) == [false, false, false])
}

@Test func fairSpelledNumberTakesAllItsFillers() {
    let result = WindowComparer.compare(track: "system", local: fairTimed(["pay", "twenty", "um", "uh", "er", "one"]),
                                        cloud: fairUntimed("pay 21"), start: 0, end: 10)
    #expect(result.normalized.edits == 0)
}
