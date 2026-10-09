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

// MARK: - Window-only breaks

@Test func aBreakBelongsToItsRunAndGoesWithItsTurn() {
    let t1 = paragraphTurn("T1", "S1", 0, 2), t2 = paragraphTurn("T2", "S1", 2.5, 4)
    var breaks = ReviewParagraphBreaks()
    breaks.insert(before: t2, runID: "R1")
    #expect(paragraphIDs(ReviewParagraphs.group([t1, t2], breaks: breaks.active(in: [t1, t2], runID: "R1")))
        == [["T1"], ["T2"]])
    // Within the run, it goes with its turn (here: T2 merged away), and does not come back.
    #expect(breaks.active(in: [t1], runID: "R1").isEmpty)
    #expect(breaks.active(in: [t1, t2], runID: "R1").isEmpty && breaks.isEmpty)
    // A relabel: a new run whose "T2" has the same track and start is still another turn. The break goes.
    breaks.insert(before: t2, runID: "R1")
    #expect(breaks.active(in: [t1, t2], runID: "R2").isEmpty)
    #expect(breaks.active(in: [t1, t2], runID: "R2").isEmpty)
}

@Test func aBreakStaysOnARunThatKeptItsTurns() {
    let turns = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S1", 2.5, 4)]
    var breaks = ReviewParagraphBreaks()
    breaks.insert(before: turns[1], runID: "R1")
    // A word edit published R2 from R1, and its undo R3 from R2, with no carry-over bracket around either.
    let lineage = ["R2": "R1", "R3": "R2"]
    func keeps(_ runID: String) -> (String) -> Bool {
        { old in
            var id = runID
            while let previous = lineage[id] {
                if previous == old { return true }
                id = previous
            }
            return false
        }
    }
    #expect(breaks.active(in: turns, runID: "R3", keepsTurnsOf: keeps("R3")) == ["T2"])
    // A run that did not keep them (a relabel) still drops it.
    #expect(breaks.active(in: turns, runID: "R4", keepsTurnsOf: keeps("R4")).isEmpty)
}

@Test func aBreakIsCarriedOverByTurnWhileWordFixesAreReverted() {
    var breaks = ReviewParagraphBreaks()
    breaks.insert(before: paragraphTurn("T2", "S1", 2.4, 6), runID: "R1")
    // Two reverts in flight; each republishes the same turns (T2's estimated start moves from 2.4 s to 3 s).
    breaks.beginCarryOver()
    breaks.beginCarryOver()
    let first = [paragraphTurn("T1", "S1", 0, 2.9), paragraphTurn("T2", "S1", 3, 6)]
    #expect(breaks.active(in: first, runID: "R2") == ["T2"])
    // The first revert ends; the second still runs and publishes another run with the same turns.
    breaks.endCarryOver(turns: first, runID: "R2")
    let second = [paragraphTurn("T1", "S1", 0, 2.8), paragraphTurn("T2", "S1", 2.9, 6)]
    #expect(breaks.active(in: second, runID: "R3") == ["T2"])
    breaks.endCarryOver(turns: second, runID: "R3")
    // No revert in flight: a further run (a relabel) drops it.
    #expect(breaks.active(in: second, runID: "R3") == ["T2"])
    #expect(breaks.active(in: second, runID: "R4").isEmpty)
    // Carried over, a break keeps only a turn on the same track.
    breaks.insert(before: paragraphTurn("T2", "S1", 3, 6), runID: "R4")
    breaks.beginCarryOver()
    #expect(breaks.active(in: [paragraphTurn("T2", "S1", 3, 6, track: "mic")], runID: "R5").isEmpty)
}

@Test func aJoinIsNeverCarriedOverByARevertInFlightAlone() {
    var breaks = ReviewParagraphBreaks()
    breaks.insert(before: paragraphTurn("T2", "S1", 2, 4), runID: "R1")
    breaks.join(paragraphTurn("T3", "S1", 9, 12), runID: "R1")
    breaks.beginCarryOver()
    // A new run while a revert is in flight, not shown to keep the turns (a relabel may have landed): the break
    // carries over, the join does not.
    let turns = [paragraphTurn("T1", "S1", 0, 1.9), paragraphTurn("T2", "S1", 2, 4), paragraphTurn("T3", "S1", 9, 12)]
    #expect(breaks.active(in: turns, runID: "R2") == ["T2"])
    #expect(breaks.joins.isEmpty)
    // A run shown to keep them carries both.
    breaks.join(paragraphTurn("T3", "S1", 9, 12), runID: "R2")
    #expect(breaks.active(in: turns, runID: "R3", keepsTurnsOf: { $0 == "R2" }) == ["T2"])
    #expect(breaks.joins == ["T3"])
}

// MARK: - Joining a row to the row before it

@Test func joiningARowGivesItsTurnsTheSpeakerBeforeIt() {
    let rows = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S2", 2.5, 4),
                                       paragraphTurn("T3", "S2", 4.5, 6)])
    #expect(paragraphIDs(rows) == [["T1"], ["T2", "T3"]])
    // Every turn of the later row takes the earlier row's speaker, as its pop-up would give them.
    #expect(ReviewParagraphs.join(rows[1], to: rows[0])
        == ReviewParagraphJoin(reassign: ["T2", "T3"], speakerID: "S1", turnIDs: ["T2", "T3"]))
    // The unknown speaker before it: they become unknown.
    let unknown = ReviewParagraphs.group([paragraphTurn("T1", nil, 0, 2), paragraphTurn("T2", "S2", 2.5, 4)])
    #expect(ReviewParagraphs.join(unknown[1], to: unknown[0])
        == ReviewParagraphJoin(reassign: ["T2"], speakerID: nil, turnIDs: ["T2"]))
    // The same speaker already (a break, a split's second part, the time gap): nothing to reassign.
    let apart = ReviewParagraphs.group([paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S1", 9, 10)])
    #expect(ReviewParagraphs.join(apart[1], to: apart[0])
        == ReviewParagraphJoin(reassign: [], speakerID: "S1", turnIDs: ["T2"]))
}

@Test func aJoinedTurnReadsOnInTheParagraphBeforeItWhateverKeptThemApart() {
    let turns = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T1/E1", "S1", 2, 3),
                 paragraphTurn("T2", "S1", 20, 22), paragraphTurn("T3", "S1", 22.5, 24)]
    #expect(paragraphIDs(ReviewParagraphs.group(turns)) == [["T1"], ["T1/E1"], ["T2", "T3"]])
    // A split's second part, and a turn past the time gap: joined, each reads on in the paragraph before it.
    #expect(paragraphIDs(ReviewParagraphs.group(turns, joins: ["T1/E1"])) == [["T1", "T1/E1"], ["T2", "T3"]])
    #expect(paragraphIDs(ReviewParagraphs.group(turns, joins: ["T1/E1", "T2"])) == [["T1", "T1/E1", "T2", "T3"]])
    // Another speaker never joins (the join made, its speaker change undone).
    let other = [paragraphTurn("T1", "S1", 0, 2), paragraphTurn("T2", "S2", 2.5, 4)]
    #expect(paragraphIDs(ReviewParagraphs.group(other, joins: ["T2"])) == [["T1"], ["T2"]])
    // The unknown speaker's turns on two tracks, joined by hand.
    let unknown = [paragraphTurn("T1", nil, 0, 2, track: "mic"), paragraphTurn("T2", nil, 2.5, 4, track: "system")]
    #expect(paragraphIDs(ReviewParagraphs.group(unknown, joins: ["T2"])) == [["T1", "T2"]])
}

@Test func aJoinReplacesABreakAndABreakAJoin() {
    let t1 = paragraphTurn("T1", "S1", 0, 2), t2 = paragraphTurn("T2", "S1", 2.5, 4)
    var breaks = ReviewParagraphBreaks()
    breaks.insert(before: t2, runID: "R1")
    #expect(breaks.active(in: [t1, t2], runID: "R1") == ["T2"] && breaks.joins.isEmpty)
    // Backspace at the row's start: the break goes, the turn joins.
    breaks.join(t2, runID: "R1")
    let active = breaks.active(in: [t1, t2], runID: "R1")
    #expect(active.isEmpty && breaks.joins == ["T2"] && !breaks.isEmpty)
    #expect(paragraphIDs(ReviewParagraphs.group([t1, t2], breaks: active, joins: breaks.joins)) == [["T1", "T2"]])
    // Return there again: the join goes, the row breaks.
    breaks.insert(before: t2, runID: "R1")
    #expect(breaks.active(in: [t1, t2], runID: "R1") == ["T2"] && breaks.joins.isEmpty)
}

@Test func aJoinBelongsToItsRunAndGoesWithItsTurn() {
    let t1 = paragraphTurn("T1", "S1", 0, 2), t2 = paragraphTurn("T2", "S1", 9, 10)
    var breaks = ReviewParagraphBreaks()
    breaks.join(t2, runID: "R1")
    // Kept within the run, and on a run that kept its turns (a word edit's).
    _ = breaks.active(in: [t1, t2], runID: "R1")
    #expect(breaks.joins == ["T2"])
    _ = breaks.active(in: [t1, t2], runID: "R2", keepsTurnsOf: { $0 == "R1" })
    #expect(breaks.joins == ["T2"])
    // Its turn gone (or on another track): it goes, and does not come back.
    _ = breaks.active(in: [t1, paragraphTurn("T2", "S1", 9, 10, track: "mic")], runID: "R2")
    #expect(breaks.joins.isEmpty && breaks.isEmpty)
    // A relabel drops it.
    breaks.join(t2, runID: "R2")
    _ = breaks.active(in: [t1, t2], runID: "R3")
    #expect(breaks.joins.isEmpty)
    // A break made on another run than a join held starts afresh.
    breaks.join(t2, runID: "R3")
    breaks.insert(before: t1, runID: "R4")
    #expect(breaks.joins.isEmpty)
}

@Test func aJoinOrBreakOnASplitPartStillSavingFollowsItsSavedID() {
    let t1 = paragraphTurn("T1", "S1", 0, 2)
    var breaks = ReviewParagraphBreaks()
    breaks.join(paragraphTurn("T1/tmp", "S1", 2, 3), runID: "R1")
    breaks.insert(before: paragraphTurn("T2/tmp", "S1", 5, 6), runID: "R1")
    // Saved: the parts are "T1/e1" and "T2/e2" now.
    let saved = [t1, paragraphTurn("T1/e1", "S1", 2, 3), paragraphTurn("T2", "S1", 3.5, 5),
                 paragraphTurn("T2/e2", "S1", 5, 6)]
    let ids = ["T1/tmp": "T1/e1", "T2/tmp": "T2/e2"]
    let active = breaks.active(in: saved, runID: "R1", resolve: { ids[$0] ?? $0 })
    #expect(active == ["T2/e2"] && breaks.joins == ["T1/e1"])
    #expect(paragraphIDs(ReviewParagraphs.group(saved, breaks: active, joins: breaks.joins))
        == [["T1", "T1/e1", "T2"], ["T2/e2"]])
}

@Test func aRowJoinedToTheUnknownSpeakerKeepsItsTracksTogether() {
    let rows = ReviewParagraphs.group([paragraphTurn("T1", nil, 0, 2), paragraphTurn("T2", "S2", 2.5, 4),
                                       paragraphTurn("T3", "S2", 4.5, 6, track: "mic")])
    #expect(paragraphIDs(rows) == [["T1"], ["T2", "T3"]])
    let join = ReviewParagraphs.join(rows[1], to: rows[0])
    #expect(join.turnIDs == ["T2", "T3"] && join.turnID == "T2")
    // Given to the unknown speaker, T3 (microphone) would part from T2 (system audio) by track: every turn is joined.
    let given = [paragraphTurn("T1", nil, 0, 2), paragraphTurn("T2", nil, 2.5, 4),
                 paragraphTurn("T3", nil, 4.5, 6, track: "mic")]
    #expect(paragraphIDs(ReviewParagraphs.group(given, joins: ["T2"])) == [["T1", "T2"], ["T3"]])
    #expect(paragraphIDs(ReviewParagraphs.group(given, joins: Set(join.turnIDs))) == [["T1", "T2", "T3"]])
}

@Test func clearingJoinsKeepsTheBreaks() {
    let t1 = paragraphTurn("T1", "S1", 0, 2), t2 = paragraphTurn("T2", "S1", 2.5, 4), t3 = paragraphTurn("T3", "S1", 9, 10)
    var breaks = ReviewParagraphBreaks()
    breaks.insert(before: t2, runID: "R1")
    breaks.join(t3, runID: "R1")
    #expect(breaks.active(in: [t1, t2, t3], runID: "R1") == ["T2"] && breaks.joins == ["T3"])
    breaks.clearJoins()
    #expect(breaks.joins.isEmpty && breaks.active(in: [t1, t2, t3], runID: "R1") == ["T2"])
    #expect(paragraphIDs(ReviewParagraphs.group([t1, t2, t3], breaks: ["T2"], joins: breaks.joins))
        == [["T1"], ["T2"], ["T3"]])
}

