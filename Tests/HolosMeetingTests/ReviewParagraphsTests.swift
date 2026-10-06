import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import Testing

// The review's paragraphs (docs/meeting-design.md §5.10): consecutive turns of one speaker shown as one row. Pure;
// synthetic turns. Edits on paragraphs saved and undone through ReviewSession are in ReviewSessionTests.

/// A turn of `speaker` (nil: unknown) from `start` to `end`, with one span of `words` words in segment `id`.
private func paragraphTurn(_ id: String, _ speaker: String?, _ start: Double, _ end: Double, track: String = "system",
                           words: Int = 2, uncertain: Bool = false, overlap: Bool = false) -> ProjectedTurn {
    ProjectedTurn(id: id, track: track, start: start, end: end, speakerID: speaker, clusterID: speaker,
                  spans: [WordSpan(segmentID: id, first: 0, end: words)], overlap: overlap, otherClusters: [],
                  assignmentScore: 1, timing: .measured, reassigned: false, modified: false,
                  excludedFromEnrollment: false, uncertain: uncertain || overlap || speaker == nil)
}

private func paragraphIDs(_ paragraphs: [ReviewParagraph]) -> [[String]] {
    paragraphs.map(\.turnIDs)
}

/// Words "<turn>.0" … for each turn of `paragraph`, `counts` many, one second apart from the turn's start.
private func paragraphWords(_ paragraph: ReviewParagraph, counts: [Int]) -> [[ReviewWord]] {
    zip(paragraph.turns, counts).map { turn, count in
        (0..<count).map { index in
            ReviewWord(ref: WordRef(segmentID: turn.id, word: index), text: "\(turn.id).\(index)",
                       start: turn.start + Double(index))
        }
    }
}

@Test func aSpeakerChangeEndsAParagraph() {
    let turns = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S1", 2.5, 4),
                 paragraphTurn("T3", "S2", 4.5, 6), paragraphTurn("T4", "S1", 6.5, 8)]
    #expect(paragraphIDs(ReviewParagraphs.group(turns)) == [["T1", "T2"], ["T3"], ["T4"]])
}

@Test func turnsJoinOnlyLessThanTheGapApart() {
    let gap = ReviewParagraphs.gapSeconds
    #expect(gap == 3)
    let close = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S1", 2 + gap - 0.01, 9)]
    #expect(paragraphIDs(ReviewParagraphs.group(close)) == [["T1", "T2"]])
    let apart = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S1", 2 + gap, 9)]
    #expect(paragraphIDs(ReviewParagraphs.group(apart)) == [["T1"], ["T2"]])
}

@Test func theGapIsMeasuredFromTheLatestEndOfTheParagraph() {
    // T2 lies inside T1 (an overlap on the other track): T3 is near T1's end, not T2's.
    let turns = [paragraphTurn("T1", "S1", 0, 10), paragraphTurn("T2", "S1", 1, 2, track: "mic"),
                 paragraphTurn("T3", "S1", 11, 12)]
    let paragraphs = ReviewParagraphs.group(turns)
    #expect(paragraphIDs(paragraphs) == [["T1", "T2", "T3"]])
    #expect(paragraphs[0].start == 0 && paragraphs[0].end == 12)
}

@Test func aNamedSpeakersMicrophoneAndSystemTurnsJoin() {
    let turns = [paragraphTurn("T1", "S1", 0, 2, track: "mic"), paragraphTurn("T2", "S1", 2.5, 4, track: "system")]
    #expect(paragraphIDs(ReviewParagraphs.group(turns)) == [["T1", "T2"]])
}

@Test func unknownTurnsJoinOnlyOnOneTrack() {
    let turns = [paragraphTurn("T1", nil, 0, 2, track: "mic"), paragraphTurn("T2", nil, 2.5, 4, track: "mic"),
                 paragraphTurn("T3", nil, 4.5, 6, track: "system"), paragraphTurn("T4", nil, 6.5, 8, track: "system")]
    #expect(paragraphIDs(ReviewParagraphs.group(turns)) == [["T1", "T2"], ["T3", "T4"]])
}

@Test func anUnknownMicrophoneTurnNeverJoinsANamedSystemTurn() {
    let turns = [paragraphTurn("T1", "S1", 0, 2, track: "system"), paragraphTurn("T2", nil, 2.5, 4, track: "mic"),
                 paragraphTurn("T3", "S1", 4.5, 6, track: "system")]
    #expect(paragraphIDs(ReviewParagraphs.group(turns)) == [["T1"], ["T2"], ["T3"]])
}

@Test func theSecondPartOfASplitAndABreakStartAParagraph() {
    let turns = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T1/E1", "S1", 2, 3),
                 paragraphTurn("T2", "S1", 3.5, 5), paragraphTurn("T3", "S1", 5.5, 7)]
    #expect(paragraphIDs(ReviewParagraphs.group(turns)) == [["T1"], ["T1/E1", "T2", "T3"]])
    #expect(paragraphIDs(ReviewParagraphs.group(turns, breaks: ["T3"])) == [["T1"], ["T1/E1", "T2"], ["T3"]])
}

@Test func aTurnWithoutAKnownStartIsAParagraphOfItsOwn() {
    let turns = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S1", .nan, .nan),
                 paragraphTurn("T3", "S1", 2.5, 4)]
    #expect(paragraphIDs(ReviewParagraphs.group(turns)) == [["T1"], ["T2"], ["T3"]])
}

@Test func aParagraphWarnsWhenAnyOfItsTurnsIsUncertain() {
    let plain = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S1", 2.5, 4)])
    #expect(!plain[0].uncertain && !plain[0].overlap)
    let unsure = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 2),
                                         paragraphTurn("T2", "S1", 2.5, 4, uncertain: true)])
    #expect(unsure[0].uncertain && !unsure[0].overlap)
    let overlapped = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 2, overlap: true),
                                             paragraphTurn("T2", "S1", 2.5, 4)])
    #expect(overlapped[0].uncertain && overlapped[0].overlap)
}

@Test func aParagraphListsItsTurnsWordsInOrder() {
    let paragraph = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 2, words: 3),
                                            paragraphTurn("T2", "S1", 2.5, 4, words: 2)])[0]
    #expect(paragraph.id == "T1")
    #expect(paragraph.spans == [WordSpan(segmentID: "T1", first: 0, end: 3), WordSpan(segmentID: "T2", first: 0, end: 2)])
    #expect(paragraph.contains(turnID: "T2") && !paragraph.contains(turnID: "T3"))
}

// MARK: - Split Turn on a paragraph

@Test func splittingInsideATurnSplitsThatTurn() throws {
    let paragraph = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 3), paragraphTurn("T2", "S1", 3.5, 6)])[0]
    let words = paragraphWords(paragraph, counts: [3, 3])
    // Word 4 of the paragraph is T2's second word.
    #expect(ReviewParagraphs.split(paragraph, words: words, at: 4)
        == .splitTurn(turnID: "T2", at: WordRef(segmentID: "T2", word: 1)))
    #expect(ReviewParagraphs.split(paragraph, words: words, at: 1)
        == .splitTurn(turnID: "T1", at: WordRef(segmentID: "T1", word: 1)))
}

@Test func splittingWhereATurnStartsOnlyBreaksTheParagraph() {
    let paragraph = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 3), paragraphTurn("T2", "S1", 3.5, 6)])[0]
    let words = paragraphWords(paragraph, counts: [3, 3])
    #expect(ReviewParagraphs.split(paragraph, words: words, at: 3) == .breakBefore(turnID: "T2"))
}

@Test func splittingAtTheFirstWordOrPastTheEndDoesNothing() {
    let paragraph = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 3), paragraphTurn("T2", "S1", 3.5, 6)])[0]
    let words = paragraphWords(paragraph, counts: [3, 3])
    #expect(ReviewParagraphs.split(paragraph, words: words, at: 0) == nil)
    #expect(ReviewParagraphs.split(paragraph, words: words, at: 6) == nil)
    // A first turn without words: the paragraph's first word is T2's.
    let empty = paragraphWords(paragraph, counts: [0, 3])
    #expect(ReviewParagraphs.split(paragraph, words: empty, at: 0) == nil)
    #expect(ReviewParagraphs.split(paragraph, words: empty, at: 1)
        == .splitTurn(turnID: "T2", at: WordRef(segmentID: "T2", word: 1)))
}

// MARK: - Playback

@Test func theWordPlayingCountsTheEarlierTurnsWords() {
    let paragraph = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 3), paragraphTurn("T2", "S1", 4, 7)])[0]
    let starts = [[0.0, 1, 2], [4.0, 5, 6]]
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T1", at: 1.5, starts: starts) == 1)
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T2", at: 5.2, starts: starts) == 4)
    // T2 playing before its first word: the word before it stays tinted.
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T2", at: 3.9, starts: starts) == 2)
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T1", at: -1, starts: starts) == nil)
}

@Test func aPauseInsideAParagraphKeepsItPlaying() {
    let paragraphs = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 3), paragraphTurn("T2", "S1", 4, 7),
                                             paragraphTurn("T3", "S2", 12, 14)])
    #expect(ReviewParagraphs.index(at: 3.5, in: paragraphs) == 0)
    #expect(ReviewParagraphs.index(at: 9, in: paragraphs) == nil)
    #expect(ReviewParagraphs.index(at: 13, in: paragraphs) == 1)
    // No turn is spoken at 3.5: the last word of the turn before the pause.
    let starts = [[0.0, 1, 2], [4.0, 5, 6]]
    #expect(ReviewParagraphs.playingWord(in: paragraphs[0], turnID: nil, at: 3.5, starts: starts) == 2)
}

@Test func overlappingTurnsOfAParagraphTintTheWordOfTheTurnSpoken() {
    // T2 (microphone) starts inside T1 (system audio): text order is T1's words, then T2's.
    let paragraph = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 6, track: "system"),
                                            paragraphTurn("T2", "S1", 2, 4, track: "mic")])[0]
    let starts = [[0.0, 2, 4], [2.0, 3]]
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T1", at: 4.5, starts: starts) == 2)
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T2", at: 3.5, starts: starts) == 4)
}

@Test func aPauseAfterAnOverlapKeepsTheWordOfTheTurnThatFinishedLast() {
    // T2 (microphone) lies inside T1; T3 follows after a pause. In that pause the last word spoken is T1's, not the
    // last word of T2, which started later but ended long before.
    let paragraph = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 10, track: "system"),
                                            paragraphTurn("T2", "S1", 1, 2, track: "mic"),
                                            paragraphTurn("T3", "S1", 11, 12, track: "system")])[0]
    #expect(paragraph.turnIDs == ["T1", "T2", "T3"])
    let starts = [[0.0, 5, 9], [1.0], [11.0]]
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T1", at: 9.5, starts: starts) == 2)
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: nil, at: 10.5, starts: starts) == 2)
    #expect(ReviewParagraphs.playingWord(in: paragraph, turnID: "T3", at: 11.5, starts: starts) == 4)
}
