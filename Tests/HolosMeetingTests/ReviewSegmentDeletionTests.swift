import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import HolosTestSupport
import Testing

// Deleting every word of a segment in Review (docs/meeting/review-window.md §5.10, "Editing words"): the segment loses its
// words, the turn its text, an emptied turn goes, and the deletion is undone or restored exactly. Helpers are prefixed
// `deletion`; the text is made up.

private struct DeletionTurn {
    var speaker: String
    /// The turn's segments: ID, start, words (a second apart, 0.8 s long).
    var segments: [(id: String, start: Double, words: [String])]
}

/// A finished call whose head run has one turn per spec (T1, T2, … in order), each holding every word of its segments.
/// `fixes`: marks of segments by ID.
private func deletionSession(in temp: TemporaryDirectory, _ specs: [DeletionTurn],
                             fixes: [String: [TranscriptWordFix]] = [:]) async throws -> URL {
    let segments = specs.flatMap { spec in
        spec.segments.map { piece in
            var segment = SessionFixtures.segment(piece.words, track: "system", start: piece.start, wordSeconds: 1,
                                                  id: piece.id)
            segment.fixes = fixes[piece.id]
            return segment
        }
    }
    let transcript = SessionFixtures.transcript(segments)
    let total = (segments.map(\.end).max() ?? 0) + 1
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": total],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    var ordinals: [String: Int] = [:]
    for spec in specs where ordinals[spec.speaker] == nil { ordinals[spec.speaker] = ordinals.count + 1 }
    let speakers = ordinals.sorted { $0.value < $1.value }.map {
        SessionSpeaker(id: $0.key, ordinal: $0.value, provenance: .diarizer, clusterIDs: [$0.key])
    }
    let turns = specs.enumerated().map { index, spec in
        let start = spec.segments.map(\.start).min() ?? 0
        let end = spec.segments.map { $0.start + Double($0.words.count) }.max() ?? start
        return SpeakerTurn(id: "T\(index + 1)", track: "system", start: start, end: end, speakerID: spec.speaker,
                           clusterID: spec.speaker,
                           spans: spec.segments.map { WordSpan(segmentID: $0.id, first: 0, end: $0.words.count) },
                           assignmentScore: 1, timing: .measured)
    }
    let clusters = speakers.map { ClusterSummary(clusterID: $0.id, track: "system", speechSeconds: 10) }
    let run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                             alignment: AlignmentInfo(version: 1, parameters: .v1),
                             tracks: [TrackDiarization(track: "system", policy: .diarized, clusters: clusters)],
                             speakers: speakers, turns: turns)
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    return session
}

/// T1 (S1): "That sounds fine?" (A), "Thanks," (B), "Right then." (C); T2 (S2): "Cheers." (D); T3 (S1): "We will
/// see." (E).
private let deletionTurns = [
    DeletionTurn(speaker: "system:S1", segments: [("A", 0, ["That", "sounds", "fine?"]), ("B", 3, ["Thanks,"]),
                                                  ("C", 4, ["Right", "then."])]),
    DeletionTurn(speaker: "system:S2", segments: [("D", 10, ["Cheers."])]),
    DeletionTurn(speaker: "system:S1", segments: [("E", 12, ["We", "will", "see."])]),
]

@MainActor
private func deletionOpen(_ session: URL) async throws -> ReviewSession {
    try await ReviewSession(session: session, profiles: nil, maintenance: nil, exportDelay: .seconds(60))
}

private func deletionCurrent(_ session: URL) throws -> Transcript {
    try #require(try SessionFiles.currentTranscript(session: session))
}

private func deletionHeadRun(_ session: URL) throws -> DiarizationRun {
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    return try SessionSpeakerStore.readRun(id: runID, session: session)
}

/// The text lines of the text export (every other line is a speaker header, "<label>  <time>").
private func deletionTextLines(_ session: URL) throws -> [String] {
    let text = String(decoding: try SessionExports.render(.txt, session: session), as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return lines.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
}

/// The JSON export's turns: ID and text.
private func deletionJSONTurns(_ session: URL) throws -> [String: String] {
    let object = try JSONSerialization.jsonObject(with: try SessionExports.render(.json, session: session))
    let turns = try #require((object as? [String: Any])?["turns"] as? [[String: Any]])
    var result: [String: String] = [:]
    for turn in turns {
        if let id = turn["id"] as? String, let text = turn["text"] as? String { result[id] = text }
    }
    return result
}

/// The run's record of deleted segments: segment ID → the turns that held them.
private func deletionHolders(_ records: [RemovedSegmentTurns]) -> [String: [String]] {
    Dictionary(records.map { ($0.segmentID, $0.turnIDs) }, uniquingKeysWith: { first, _ in first })
}

/// The head run's turns as times go: ID, spans, start, end, timing quality.
private func deletionTurnTimes(_ session: URL) throws -> [SpeakerTurnTimes] {
    try deletionHeadRun(session).turns.map {
        SpeakerTurnTimes(turnID: $0.id, spans: $0.spans, start: $0.start, end: $0.end, timing: $0.timing)
    }
}

@MainActor
private func deletionRefs(_ review: ReviewSession, _ turnID: String, segment: String) -> [WordRef] {
    review.words(of: turnID).map(\.ref).filter { $0.segmentID == segment }
}

/// The first, middle, and last segment of a turn deleted whole: the turn reads without it (no stray space or
/// punctuation), the exports too, and the undo brings the recognizer's words back exactly.
@Test(.timeLimit(.minutes(1))) @MainActor
func aTurnsFirstMiddleOrLastSegmentDeletedWholeLeavesTheRestAndUndoes() async throws {
    let expected = ["A": "Thanks, Right then.", "B": "That sounds fine? Right then.",
                    "C": "That sounds fine? Thanks,"]
    for segmentID in ["A", "B", "C"] {
        let temp = try TemporaryDirectory("review", permissions: 0o700)
        defer { temp.remove() }
        let session = try await deletionSession(in: temp, deletionTurns)
        let original = try deletionCurrent(session)
        let review = try await deletionOpen(session)
        let refs = deletionRefs(review, "T1", segment: segmentID)
        #expect(review.wordEditRefusal(refs) == nil)

        let edit = try #require(try await review.editWords(refs, to: ""))
        #expect(edit.deletion && edit.meant.isEmpty)
        let edited = try deletionCurrent(session)
        let emptied = try #require(edited.segments.first { $0.id == segmentID })
        #expect(emptied.text.isEmpty && emptied.words.isEmpty && emptied.removed != nil)
        let turn = try #require(review.turn("T1"))
        #expect(review.text(of: turn) == expected[segmentID], "\(segmentID)")
        #expect(!turn.spans.contains { $0.segmentID == segmentID })
        #expect(review.projection.turns.map(\.id) == ["T1", "T2", "T3"])
        #expect(review.speaker("system:S1")?.turnCount == 2)
        // The exports: the turn's text without the words, no double space.
        let lines = try deletionTextLines(session)
        #expect(lines == [try #require(expected[segmentID]), "Cheers.", "We will see."])
        #expect(try deletionJSONTurns(session)["T1"] == expected[segmentID])
        let run = try deletionHeadRun(session)
        #expect(run.removedSegments.map(deletionHolders) == [segmentID: ["T1"]])

        try await review.undo()
        #expect(try deletionCurrent(session).segments == original.segments,
                "The recognizer's words, their times, and their marks come back exactly.")
        #expect(review.text(of: try #require(review.turn("T1"))) == "That sounds fine? Thanks, Right then.")
        #expect(try deletionHeadRun(session).removedSegments == nil)
        #expect(try deletionTextLines(session).first == "That sounds fine? Thanks, Right then.")
        await review.close()
    }
}

/// The turn's only segment deleted: the turn is not shown, its speaker (with no other turn) is not listed, and the
/// exports have neither. Speaker edits made before and after carry over, and the undo brings the turn back with them.
@Test(.timeLimit(.minutes(1))) @MainActor
func aTurnsOnlySegmentDeletedTakesTheTurnAwayUntilUndone() async throws {
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    let session = try await deletionSession(in: temp, deletionTurns)
    let original = try deletionCurrent(session)
    let review = try await deletionOpen(session)
    // A speaker edit naming the turn: it carries over while the turn has no words, and back.
    try await review.assign(["T2"], to: .newSpeaker(name: "Guest"))
    let guest = try #require(review.turn("T2")?.speakerID)
    #expect(review.speaker(guest)?.turnCount == 1)

    try await review.editWords(deletionRefs(review, "T2", segment: "D"), to: "")
    #expect(review.projection.turns.map(\.id) == ["T1", "T3"])
    #expect(review.turn("T2") == nil && review.shownTurns.allSatisfy { $0.id != "T2" })
    #expect(review.speaker(guest)?.turnCount == 0, "The speaker made here stays listed, with no turn.")
    // The run keeps the turn, with no words, and says which turns held the deleted words.
    let run = try deletionHeadRun(session)
    let kept = try #require(run.turns.first { $0.id == "T2" })
    #expect(kept.spans.isEmpty)
    #expect(run.removedSegments.map(deletionHolders) == ["D": ["T2"]])
    // A speaker change after it, on the labels without the turn.
    try await review.apply([.rename(speakerID: "system:S1", name: "Alice")])
    #expect(review.speaker("system:S1")?.name == "Alice")

    // Undo: the rename, then the deletion: the turn is back with its words, its edits, and its speaker.
    try await review.undo()
    try await review.undo()
    #expect(try deletionCurrent(session).segments == original.segments)
    let back = try #require(review.turn("T2"))
    #expect(back.spans == [WordSpan(segmentID: "D", first: 0, end: 1)] && back.speakerID == guest)
    #expect(review.text(of: back) == "Cheers.")
    #expect(review.speaker(guest)?.turnCount == 1 && review.speaker("system:S1")?.name == "Speaker 1")
    #expect(try deletionHeadRun(session).removedSegments == nil)
    #expect(try deletionHeadRun(session).turns.first { $0.id == "T2" }?.start == 10)
    await review.close()
}

/// The exports of a meeting with a turn's only segment deleted: no block for it, the speaker's name nowhere, and the
/// blocks around it as they were.
@Test(.timeLimit(.minutes(1))) @MainActor
func theExportsLeaveOutATurnWhoseOnlySegmentWasDeleted() async throws {
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    let session = try await deletionSession(in: temp, deletionTurns)
    let review = try await deletionOpen(session)
    try await review.apply([.rename(speakerID: "system:S2", name: "Bob")])
    try await review.editWords(deletionRefs(review, "T2", segment: "D"), to: "")
    await review.close()
    let text = String(decoding: try SessionExports.render(.txt, session: session), as: UTF8.self)
    #expect(!text.contains("Cheers") && !text.contains("Bob"))
    #expect(try deletionTextLines(session) == ["That sounds fine? Thanks, Right then. We will see."])
    let markdown = String(decoding: try SessionExports.render(.md, session: session), as: UTF8.self)
    #expect(!markdown.contains("Cheers") && !markdown.contains("Bob"))
    let turns = try deletionJSONTurns(session)
    #expect(Set(turns.keys) == ["T1", "T3"])
}

/// Read again from disk (a new window, the labels' plan onto the transcript itself as every revert check makes it),
/// the deletion stands, and Restore (offered from the nearest turn shown) brings the words back to the turn that held
/// them; its undo deletes them again.
@Test(.timeLimit(.minutes(1))) @MainActor
func deletedWordsAreRestoredFromTheNearestTurnAndTheRestoreUndoes() async throws {
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    let session = try await deletionSession(in: temp, deletionTurns)
    let original = try deletionCurrent(session)
    let first = try await deletionOpen(session)
    try await first.editWords(deletionRefs(first, "T2", segment: "D"), to: "")
    await first.close()

    let review = try await deletionOpen(session)
    await review.wordChecksSettled()
    #expect(review.projection.turns.map(\.id) == ["T1", "T3"])
    // The labels' plan onto the same words keeps the emptied turn (no revert is refused for it).
    let snapshot = review.snapshot
    let plan = try #require(try SpeakerTranscriptRetarget.plan(session: session, from: snapshot,
                                                               to: snapshot.transcript, voiceData: false))
    #expect(plan.run.turns.first { $0.id == "T2" }?.spans == [])
    #expect(plan.run.removedSegments.map(deletionHolders) == ["D": ["T2"]])
    // "Cheers." at 10 s: T3 (12 s) is nearer than T1 (ends at 6 s).
    let offered = ReviewDeletedWords(segmentID: "D", text: "Cheers.", start: 10, end: 11, track: "system")
    #expect(review.deletedWords(near: "T3") == [offered])
    #expect(review.deletedWords(near: "T1").isEmpty)

    try await review.restoreDeletedWords(segmentID: "D")
    #expect(try deletionCurrent(session).segments == original.segments)
    #expect(review.turn("T2")?.speakerID == "system:S2")
    #expect(review.text(of: try #require(review.turn("T2"))) == "Cheers.")
    #expect(review.deletedWords(near: "T3").isEmpty)
    #expect(review.canUndo)
    try await review.undo()
    #expect(review.turn("T2") == nil)
    #expect(review.deletedWords(near: "T3") == [offered])
    #expect(try deletionCurrent(session).segments.first { $0.id == "D" }?.removed != nil)
    await review.close()
}

/// A deletion and its undo, or its Restore in a later window, leave every turn's times exactly as the labelling gave
/// them (they are not worked out again from the words, whose span is shorter than the turn's): the turn that lost a
/// segment, and the one left with no words.
@Test(.timeLimit(.minutes(1))) @MainActor
func aDeletionAndItsUndoOrRestoreLeaveEveryTurnsTimesAsTheyWere() async throws {
    for segmentID in ["B", "D", "C"] {
        let temp = try TemporaryDirectory("review", permissions: 0o700)
        defer { temp.remove() }
        let session = try await deletionSession(in: temp, deletionTurns)
        let before = try deletionTurnTimes(session)
        let turnID = segmentID == "D" ? "T2" : "T1"
        let review = try await deletionOpen(session)
        try await review.editWords(deletionRefs(review, turnID, segment: segmentID), to: "")
        #expect(try deletionTurnTimes(session) != before, "\(segmentID): the deletion changed something")
        try await review.undo()
        #expect(try deletionTurnTimes(session) == before, "\(segmentID): undone")

        try await review.editWords(deletionRefs(review, turnID, segment: segmentID), to: "")
        await review.close()
        let later = try await deletionOpen(session)
        try await later.restoreDeletedWords(segmentID: segmentID)
        #expect(try deletionTurnTimes(session) == before, "\(segmentID): restored")
        await later.close()
    }
}

/// Every turn's words deleted: no turn is shown to offer a Restore, and, read again in a new window, there is no undo
/// either. Every deleted segment can still be restored (Edit ▸ Restore Deleted Words lists them all).
@Test(.timeLimit(.minutes(1))) @MainActor
func wordsDeletedFromEveryTurnCanStillBeRestored() async throws {
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    let session = try await deletionSession(in: temp, deletionTurns)
    let original = try deletionCurrent(session)
    let review = try await deletionOpen(session)
    for (turnID, segmentID) in [("T1", "A"), ("T1", "B"), ("T1", "C"), ("T2", "D"), ("T3", "E")] {
        try await review.editWords(deletionRefs(review, turnID, segment: segmentID), to: "")
    }
    #expect(review.projection.turns.isEmpty && review.shownTurns.isEmpty)
    await review.close()

    let later = try await deletionOpen(session)
    #expect(later.shownTurns.isEmpty && !later.canUndo)
    #expect(later.deletedWords().map(\.segmentID) == ["A", "B", "C", "D", "E"])
    #expect(later.deletedWords().map(\.text) == ["That sounds fine?", "Thanks,", "Right then.", "Cheers.",
                                                 "We will see."])
    try await later.restoreDeletedWords(segmentID: "E")
    #expect(later.shownTurns.map(\.id) == ["T3"])
    #expect(later.deletedWords().map(\.segmentID) == ["A", "B", "C", "D"])
    // Now T3 is shown, the per-turn offers come from it.
    #expect(later.deletedWords(near: "T3").map(\.segmentID) == ["A", "B", "C", "D"])
    for segmentID in ["A", "B", "C", "D"] { try await later.restoreDeletedWords(segmentID: segmentID) }
    #expect(try deletionCurrent(session).segments == original.segments)
    #expect(later.shownTurns.map(\.id) == ["T1", "T2", "T3"] && later.deletedWords().isEmpty)
    await later.close()
}

/// Every segment of one turn deleted, then brought back in any order (the same, the reverse, mixed, an undo among the
/// Restores): once all its words are back, the turn has the times it had before the first deletion, never times worked
/// out from the words (its last word ends at 5.8 s, the turn at 6 s).
@Test(.timeLimit(.minutes(1))) @MainActor
func aTurnsDeletionsRestoredInAnyOrderGiveItsTimesBack() async throws {
    let orders: [(name: String, deleted: [String], undoFirst: Bool, restores: [String])] = [
        ("same order", ["A", "B", "C"], false, ["A", "B", "C"]),
        ("reverse order", ["A", "B", "C"], false, ["C", "B", "A"]),
        ("mixed order", ["A", "B", "C"], false, ["B", "A", "C"]),
        ("undo then Restore", ["A", "B", "C"], true, ["A", "B"]),
        ("two, same order", ["A", "B"], false, ["A", "B"]),
        ("two, reverse order", ["A", "B"], false, ["B", "A"]),
    ]
    for order in orders {
        let temp = try TemporaryDirectory("review", permissions: 0o700)
        defer { temp.remove() }
        let session = try await deletionSession(in: temp, deletionTurns)
        let before = try deletionTurnTimes(session)
        #expect(before.first?.end == 6)
        let review = try await deletionOpen(session)
        for segmentID in order.deleted {
            try await review.editWords(deletionRefs(review, "T1", segment: segmentID), to: "")
        }
        #expect((review.turn("T1") == nil) == (order.deleted.count == 3), "\(order.name)")
        // An undo restores the last deletion (C); the others are restored from the list, in this window.
        if order.undoFirst { try await review.undo() }
        for segmentID in order.restores { try await review.restoreDeletedWords(segmentID: segmentID) }
        #expect(try deletionTurnTimes(session) == before, "\(order.name)")
        #expect(review.turn("T1")?.end == 6, "\(order.name)")
        #expect(try deletionHeadRun(session).removedSegments == nil, "\(order.name)")
        await review.close()
    }
}

/// Deleting a word that was heard from line noise teaches nothing: no correction maps it to nothing, while an edit
/// beside it still teaches its own.
@Test(.timeLimit(.minutes(1))) @MainActor
func aDeletedSegmentTeachesNothingWhenTheReviewCloses() async throws {
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    let session = try await deletionSession(in: temp, deletionTurns)
    let review = try await deletionOpen(session)
    let taught = SharedValue<[ReviewWordEdit]>([])
    let stored = SharedValue(CorrectionList())
    review.correctionsToLearn = { edit in
        taught.update { $0.append(edit) }
        return [Correction(heard: edit.heard, meant: edit.meant)]
    }
    review.correctionsWriter = {
        { change in
            var list = stored.value
            try change(&list)
            stored.set(list)
        }
    }
    try await review.editWords(deletionRefs(review, "T1", segment: "B"), to: "")
    try await review.editWords(deletionRefs(review, "T2", segment: "D"), to: "")
    try await review.editWords([review.words(of: "T3")[1].ref], to: "shall")
    await review.close()
    #expect(taught.value.map(\.meant) == ["shall"], "Only the edit that changed words is learned from.")
    #expect(stored.value.entries == [Correction(heard: "will", meant: "shall")])
    #expect(stored.value.entries.allSatisfy { !$0.meant.isEmpty })
}

/// A segment holding a word corrected while the meeting was recording is not deleted whole, saying why, before any
/// field opens; and nothing typed is shown as “” in the message.
@Test(.timeLimit(.minutes(1))) @MainActor
func aSegmentWithALiveCorrectionIsNotDeletedWhole() async throws {
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    // "Cheers." was corrected while recording.
    let session = try await deletionSession(in: temp, deletionTurns, fixes: [
        "D": [TranscriptWordFix(first: 0, end: 1, heard: "Cheer", kind: .liveCorrection, heardWords: 1)],
    ])
    let review = try await deletionOpen(session)
    await review.wordChecksSettled()
    let refs = deletionRefs(review, "T2", segment: "D")
    #expect(review.wordEditRefusal(refs) == TranscriptWordEdit.liveCorrected.localizedDescription)
    let refusal = await #expect(throws: HolosError.self) { try await review.editWords(refs, to: "") }
    #expect(refusal?.localizedDescription.contains("“”") == false)
    await review.close()
}

/// A deletion whose speaker head could not be published (the app quit in between) is repaired from the move its
/// journal event records ("0-1" replaced by "0-0"), and so is a Restore's.
@Test(.timeLimit(.minutes(1)))
func aDeletionsOwedSpeakerHeadIsRepairedFromItsRecordedMove() async throws {
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    let session = try await deletionSession(in: temp, deletionTurns)
    let original = try deletionCurrent(session)
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    struct HeadNotWritten: Error {}
    let request = TranscriptWordEdit.Request(segmentID: "D", first: 0, end: 1, text: "")
    await #expect(throws: SessionWordEdit.IncompletePublication.self) {
        try await SpeakerTranscriptRetarget.$beforePublishHead.withValue({ throw HeadNotWritten() }) {
            try await SessionWordEdit.run(session: session, request: request, expectedTranscriptID: original.id,
                                          expectedRunID: runID)
        }
    }
    let edited = try deletionCurrent(session)
    let event = try #require(try SessionWordEdit.editedEvent(of: edited.id, session: session))
    #expect(event.move == ReviewWordMove(segmentID: "D", replaced: 0..<1, replacement: 0..<0) && !event.undo)
    try await SessionWordEdit.repairCurrentHead(session: session, expectedTranscriptID: original.id,
                                                expectedRunID: runID)
    var snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(!snapshot.transcriptChanged && snapshot.projection?.turns.map(\.id) == ["T1", "T3"])
    #expect(snapshot.run?.removedSegments.map(deletionHolders) == ["D": ["T2"]])

    // The Restore, owed the same way.
    let repairedRun = try #require(snapshot.run?.id)
    await #expect(throws: SessionWordEdit.IncompletePublication.self) {
        try await SpeakerTranscriptRetarget.$beforePublishHead.withValue({ throw HeadNotWritten() }) {
            try await SessionWordEdit.run(session: session, request: .restoring(segmentID: "D"),
                                          expectedTranscriptID: edited.id, expectedRunID: repairedRun)
        }
    }
    try await SessionWordEdit.repairCurrentHead(session: session, expectedTranscriptID: edited.id,
                                                expectedRunID: repairedRun)
    snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.transcript.segments == original.segments)
    #expect(snapshot.projection?.turns.map(\.id) == ["T1", "T2", "T3"] && snapshot.run?.removedSegments == nil)
}

@Test func whatWasTypedIsSaidOnlyWhenSomethingWas() {
    #expect(TranscriptWordEdit.typedNote("") == "" && TranscriptWordEdit.typedAside("  ") == "")
    #expect(TranscriptWordEdit.typedNote(" Claude ") == " What you typed: “Claude”.")
    #expect(TranscriptWordEdit.typedAside("Claude") == " (what you typed: “Claude”)")
    #expect(TranscriptWordEdit.withTyped("Refused.", "") == "Refused.")
    #expect(TranscriptWordEdit.withTyped("Refused.", "x") == "Refused. What you typed: “x”.")
    #expect(TranscriptWordEdit.withTyped("Refused “x”.", "x") == "Refused “x”.")
}
