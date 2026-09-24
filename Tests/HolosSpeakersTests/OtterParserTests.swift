import Foundation
import Testing
@testable import HolosSpeakers

// Synthetic samples in Otter's plain-text layout; no private reference text.

@Test func otterParserIgnoresFooterAndCountsWords() {
    let sample = """
        Alex Morgan  0:03
        Good morning, everyone. Let's start.

        Sam  1:02:07
        Thanks — the report is ready.


        Transcribed by https://otter.ai

        """
    let turns = OtterTranscriptParser.parse(sample)
    #expect(turns == [
        // "Let's" is two words, as the evaluator counts them.
        ReferenceTurn(speaker: "Alex Morgan", start: 3, end: 3727, wordCount: 6),
        ReferenceTurn(speaker: "Sam", start: 3727, end: nil, wordCount: 5),
    ])
    // Counts only: a turn holds no text.
    #expect(Mirror(reflecting: turns[0]).children.compactMap(\.label) == ["start", "end", "wordCount"])
}

@Test func otterWordCountMatchesTheEvaluator() throws {
    // scripts/evaluate-references.swift: runs of [\p{L}\p{N}] after NFKC and lowercasing.
    let words = try NSRegularExpression(pattern: OtterTranscriptParser.wordPattern)
    #expect(OtterTranscriptParser.wordCount("don't 12:30 e-mail U.S.", words: words) == 8)
    #expect(OtterTranscriptParser.wordCount("— … ,", words: words) == 0)
    // Ligatures and full-width digits count as one word each.
    #expect(OtterTranscriptParser.wordCount("ﬁne ２０２６", words: words) == 2)
}

@Test func referenceTurnPrintsNoSpeakerName() {
    let turn = ReferenceTurn(speaker: "Private Name", start: 3, end: 9, wordCount: 4)
    var dumped = ""
    dump(turn, to: &dumped)
    for text in [String(describing: turn), String(reflecting: turn), "\(turn)", dumped] {
        #expect(!text.contains("Private"))
        #expect(text.contains("wordCount"))
    }
}

@Test func otterParserReadsBothTimeLayouts() {
    let sample = "Speaker 1  00:05\none\n\nSpeaker 2  12:34\ntwo\n\nSpeaker 1  1:00:00\nthree\n\nSpeaker 2  10:00:01\nfour\n"
    #expect(OtterTranscriptParser.parse(sample).map(\.start) == [5, 754, 3600, 36_001])
}

@Test func otterParserSkipsPreambleAndKeepsOrder() {
    let sample = "Council meeting notes\nexported today\n\nChair  0:10\nWelcome back.\r\n\r\nClerk   0:05  \nRoll call.\n"
    let turns = OtterTranscriptParser.parse(sample)
    #expect(turns.map(\.speaker) == ["Chair", "Clerk"])
    // File order and times as written, even when a later header has an earlier time.
    #expect(turns.map(\.start) == [10, 5])
    #expect(turns.map(\.end) == [5, nil])
    #expect(turns.map(\.wordCount) == [2, 2])
}

@Test func otterParserNameMayContainSpacesAndTimes() {
    let sample = "Room  12:30 group  00:07\nhello\n\n  Jim   Smith  0:09 \nhi\n"
    let turns = OtterTranscriptParser.parse(sample)
    #expect(turns.map(\.speaker) == ["Room  12:30 group", "Jim   Smith"])
    #expect(turns.map(\.start) == [7, 9])
}

@Test func otterParserRejectsLinesTheEvaluatorRejects() {
    // One space before the time, three-digit minutes, text after the time, or no name.
    let sample = "Alex 0:03\nBea  100:03\nCal  0:03 later\n  0:03\nDee  0:04\nseven words are counted in this turn\n"
    let turns = OtterTranscriptParser.parse(sample)
    #expect(turns == [ReferenceTurn(speaker: "Dee", start: 4, end: nil, wordCount: 7)])
}

@Test func otterFooterMatchesCaseAndSchemeVariants() {
    let sample = "Alex  0:00\nhello\nTRANSCRIBED BY http://otter.ai/\n  transcribed by https://otter.ai  \n"
    #expect(OtterTranscriptParser.parse(sample) == [ReferenceTurn(speaker: "Alex", start: 0, wordCount: 1)])
}

@Test func otterParserDropsByteOrderMark() {
    let turns = OtterTranscriptParser.parse("\u{FEFF}Alex  0:00\nhello\n\nBea  0:04\nhi\n\nAlex  0:09\nbye\n")
    #expect(turns.map(\.speaker) == ["Alex", "Bea", "Alex"])
}

@Test func otterParserOfEmptyTextIsEmpty() {
    #expect(OtterTranscriptParser.parse("").isEmpty)
    #expect(OtterTranscriptParser.parse("Transcribed by https://otter.ai").isEmpty)
}
