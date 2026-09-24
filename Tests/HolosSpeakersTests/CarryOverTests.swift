import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

private let fixedDate = Date(timeIntervalSince1970: 1_000_000)

/// One turn of `speaker` on `track` over [start, end).
private struct Speech {
    var speaker: String
    var start: Double
    var end: Double
    var track: String
}

private func speech(_ speaker: String, _ start: Double, _ end: Double, track: String = "system") -> Speech {
    Speech(speaker: speaker, start: start, end: end, track: track)
}

/// A run with one turn per entry (IDs T1… in (start, track) order), each over its own segment of one-second
/// measured words; speakers are diarizer speakers numbered by first turn.
private func timedRun(_ id: String, _ parts: [Speech]) -> (run: DiarizationRun, transcript: Transcript) {
    let ordered = parts.sorted { ($0.start, $0.track) < ($1.start, $1.track) }
    var segments: [TranscriptSegment] = []
    var turns: [SpeakerTurn] = []
    var speakers: [SessionSpeaker] = []
    for (index, part) in ordered.enumerated() {
        let segmentID = "\(id)-seg\(index + 1)"
        let count = max(1, Int((part.end - part.start).rounded()))
        var text = ""
        var words: [TimedWord] = []
        for word in 0..<count {
            if word > 0 { text += " " }
            words.append(TimedWord(text: "w", start: part.start + Double(word), end: part.start + Double(word + 1),
                                   utf16Offset: text.utf16.count, utf16Length: 1))
            text += "w"
        }
        segments.append(TranscriptSegment(id: segmentID, start: part.start, end: part.end, text: text, words: words,
                                          track: part.track))
        turns.append(SpeakerTurn(id: "T\(index + 1)", track: part.track, start: part.start, end: part.end,
                                 speakerID: part.speaker, clusterID: part.speaker,
                                 spans: [WordSpan(segmentID: segmentID, first: 0, end: count)],
                                 assignmentScore: 0.9, timing: .measured))
        if !speakers.contains(where: { $0.id == part.speaker }) {
            speakers.append(SessionSpeaker(id: part.speaker, ordinal: speakers.count + 1, provenance: .diarizer,
                                           clusterIDs: [part.speaker]))
        }
    }
    let transcript = Transcript(id: "TRANSCRIPT-\(id)", createdAt: fixedDate, source: "mic+system", locale: "en-US",
                                backend: .speech, segments: segments)
    let run = DiarizationRun(id: id, sessionID: "SESSION", createdAt: fixedDate, transcriptID: transcript.id,
                             engine: nil, alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: [],
                             speakers: speakers, turns: turns)
    return (run, transcript)
}

/// The run's projection after `actions`, applied in order as edits E1, E2, ….
private func projection(_ fixture: (run: DiarizationRun, transcript: Transcript), _ actions: [SpeakerEditAction],
                        recognition: RecognitionResult? = nil, names: [String: String] = [:]) -> SpeakerProjection {
    var result = SpeakerProjection.make(run: fixture.run, transcript: fixture.transcript, edits: [],
                                        recognition: recognition, profileNames: names)
    for (index, action) in actions.enumerated() {
        result = result.applying(action, editID: "E\(index + 1)")
    }
    return result
}

@Test func carryNamesByOverlap() throws {
    let old = timedRun("OLD", [speech("system:S1", 0, 30), speech("system:S1", 30, 60),
                               speech("system:S2", 60, 90), speech("system:S2", 90, 120)])
    let before = projection(old, [.rename(speakerID: "system:S1", name: "Jim"),
                                  .linkProfile(speakerID: "system:S1", profileID: "P-JIM"),
                                  .rename(speakerID: "system:S2", name: "Maria"),
                                  .linkProfile(speakerID: "system:S2", profileID: "P-MARIA")])
    // The new run numbers its speakers the other way round; only time decides.
    let new = timedRun("NEW", [speech("system:S2", 0, 58), speech("system:S1", 58, 120)])
    let result = SpeakerCarryOver.carry(from: before, to: new.run)
    #expect(result.actions == [
        .rename(speakerID: "system:S2", name: "Jim"), .linkProfile(speakerID: "system:S2", profileID: "P-JIM"),
        .rename(speakerID: "system:S1", name: "Maria"), .linkProfile(speakerID: "system:S1", profileID: "P-MARIA"),
    ])
    #expect(result.unmatchedSpeakers.isEmpty)
    #expect(result.droppedTurnEdits == 0)

    // Appended to the new run, the actions give the old names back.
    let after = projection(new, result.actions, names: ["P-JIM": "Jim", "P-MARIA": "Maria"])
    #expect(after.staleEdits.isEmpty)
    #expect(after.speakers.map(\.name) == ["Jim", "Maria"])
    #expect(after.speakers.map(\.profileID) == ["P-JIM", "P-MARIA"])
}

@Test func carryNeedsHalfTheTalkTime() {
    let old = timedRun("OLD", [speech("system:S1", 0, 100)])
    let before = projection(old, [.rename(speakerID: "system:S1", name: "Jim")])

    let far = SpeakerCarryOver.carry(from: before, to: timedRun("NEW", [speech("system:S1", 70, 170)]).run)
    #expect(far.actions.isEmpty)
    #expect(far.unmatchedSpeakers == ["system:S1"])

    let half = SpeakerCarryOver.carry(from: before, to: timedRun("NEW", [speech("system:S7", 50, 150)]).run)
    #expect(half.actions == [.rename(speakerID: "system:S7", name: "Jim")])
    #expect(half.unmatchedSpeakers.isEmpty)
}

@Test func carryIsOneToOne() {
    // Ann spoke 0–50; Bob 50–70 and 100–110. New X covers 0–70 (50 s of Ann, 20 s of Bob); Y covers 98–115.
    let old = timedRun("OLD", [speech("system:S1", 0, 50), speech("system:S2", 50, 70), speech("system:S2", 100, 110)])
    let before = projection(old, [.rename(speakerID: "system:S1", name: "Ann"),
                                  .rename(speakerID: "system:S2", name: "Bob")])

    let withNextChoice = timedRun("NEW", [speech("system:X", 0, 70), speech("system:Y", 98, 115)]).run
    let result = SpeakerCarryOver.carry(from: before, to: withNextChoice)
    #expect(result.actions == [.rename(speakerID: "system:X", name: "Ann"), .rename(speakerID: "system:Y", name: "Bob")])
    #expect(result.unmatchedSpeakers.isEmpty)

    let withoutNextChoice = timedRun("NEW", [speech("system:X", 0, 70)]).run
    let alone = SpeakerCarryOver.carry(from: before, to: withoutNextChoice)
    #expect(alone.actions == [.rename(speakerID: "system:X", name: "Ann")])
    #expect(alone.unmatchedSpeakers == ["system:S2"])
}

@Test func carryTiesBreakByID() {
    let old = timedRun("OLD", [speech("system:S1", 0, 10), speech("system:S2", 10, 20)])
    let before = projection(old, [.rename(speakerID: "system:S2", name: "Bob"),
                                  .rename(speakerID: "system:S1", name: "Ann")])
    let result = SpeakerCarryOver.carry(from: before, to: timedRun("NEW", [speech("system:X", 5, 15)]).run)
    #expect(result.actions == [.rename(speakerID: "system:X", name: "Ann")])
    #expect(result.unmatchedSpeakers == ["system:S2"])
}

@Test func carryCountsDroppedTurnEdits() {
    let old = timedRun("OLD", [speech("system:S1", 0, 10), speech("system:S2", 10, 20),
                               speech("system:S1", 20, 30), speech("system:S2", 30, 40)])
    let before = projection(old, [
        .reassignTurns(turnIDs: ["T1"], to: "system:S2"),
        .reassignTurns(turnIDs: ["T4"], to: "system:S1"),
        .splitTurn(turnID: "T2", at: WordRef(segmentID: "OLD-seg2", word: 5)),
        .rename(speakerID: "system:S1", name: "Jim"),
        .excludeFromEnrollment(turnIDs: ["T3"]),
        .revert(editID: "E5"),                                    // the exclusion never counts
        .reassignTurns(turnIDs: ["T99"], to: "system:S1"),        // stale
    ])
    #expect(before.appliedEditIDs == ["E1", "E2", "E3", "E4"])
    let result = SpeakerCarryOver.carry(from: before, to: old.run)
    #expect(result.droppedTurnEdits == 3)
    #expect(result.actions == [.rename(speakerID: "system:S1", name: "Jim")])
}

@Test func carryKeepsRejectionsAndUserCreatedSpeakers() {
    let old = timedRun("OLD", [speech("system:S1", 0, 60), speech("system:S2", 60, 120)])
    let before = projection(old, [
        .rejectProfile(speakerID: "system:S1", profileID: "P-BOB"),
        .rejectProfile(speakerID: "system:S1", profileID: "P-AL"),
        .newSpeaker(speakerID: "user:G", name: "Guest", turnIDs: ["T2"]),
        .linkProfile(speakerID: "user:G", profileID: "P-GUEST"),
    ])
    let new = timedRun("NEW", [speech("system:A", 0, 60), speech("system:B", 60, 120)]).run
    let result = SpeakerCarryOver.carry(from: before, to: new)
    #expect(result.actions == [
        .rejectProfile(speakerID: "system:A", profileID: "P-BOB"), .rejectProfile(speakerID: "system:A", profileID: "P-AL"),
        .rename(speakerID: "system:B", name: "Guest"), .linkProfile(speakerID: "system:B", profileID: "P-GUEST"),
    ])
    #expect(result.unmatchedSpeakers.isEmpty)
    #expect(result.droppedTurnEdits == 1)
}

@Test func carryMatchesOnTheSameTrackOnly() {
    let old = timedRun("OLD", [speech("mic:me", 0, 60, track: "mic")])
    let before = projection(old, [.rename(speakerID: "mic:me", name: "Vlad")])
    let new = timedRun("NEW", [speech("system:S1", 0, 60), speech("mic:S1", 10, 40, track: "mic")]).run
    let result = SpeakerCarryOver.carry(from: before, to: new)
    #expect(result.actions == [.rename(speakerID: "mic:S1", name: "Vlad")])

    let systemOnly = timedRun("NEW", [speech("system:S1", 0, 60)]).run
    #expect(SpeakerCarryOver.carry(from: before, to: systemOnly).unmatchedSpeakers == ["mic:me"])
}

@Test func carryFollowsEditedAssignment() {
    // S3 was merged into Jim's S1, so Jim's speech includes 60–90 and maps to the new speaker that has it.
    let old = timedRun("OLD", [speech("system:S1", 0, 20), speech("system:S2", 20, 60), speech("system:S3", 60, 90)])
    let before = projection(old, [.merge(from: "system:S3", into: "system:S1"),
                                  .rename(speakerID: "system:S1", name: "Jim")])
    let new = timedRun("NEW", [speech("system:A", 0, 20), speech("system:B", 20, 60), speech("system:C", 60, 90)]).run
    let result = SpeakerCarryOver.carry(from: before, to: new)
    // Jim (50 s) shares 30 s with C (30 s) and 20 s with A (20 s): C has the most shared time.
    #expect(result.actions == [.rename(speakerID: "system:C", name: "Jim")])
    // The merge is not carried (A keeps its own label), so it is reported.
    #expect(result.droppedTurnEdits == 1)
}

@Test func carryReportsMergesItCannotCarry() {
    let old = timedRun("OLD", [speech("system:S1", 0, 30), speech("system:S3", 30, 60)])
    let merged = projection(old, [.merge(from: "system:S3", into: "system:S1"),
                                  .rename(speakerID: "system:S1", name: "Jim")])
    let new = timedRun("NEW", [speech("system:X", 0, 30), speech("system:Y", 30, 60)]).run
    let result = SpeakerCarryOver.carry(from: merged, to: new)
    // Jim shares 30 s with each; the tie goes to X, and Y (half of Jim's merged speech) is left unnamed.
    #expect(result.actions == [.rename(speakerID: "system:X", name: "Jim")])
    #expect(result.unmatchedSpeakers.isEmpty)
    #expect(result.droppedTurnEdits == 1)

    // A reverted merge never took effect and is not counted.
    let undone = projection(old, [.merge(from: "system:S3", into: "system:S1"), .revert(editID: "E1"),
                                  .rename(speakerID: "system:S1", name: "Jim")])
    #expect(SpeakerCarryOver.carry(from: undone, to: new).droppedTurnEdits == 0)
}

@Test func carryRefusesWhenTheBestMatchFailsTheHalfRule() {
    // Jim spoke 0–100. X (200 s) shares 40 s with him: the most, but under half of the smaller talk time (100 s).
    // Y (20 s) shares 15 s, which alone would pass. §4.9 accepts or refuses the speaker with the most shared time.
    let old = timedRun("OLD", [speech("system:S1", 0, 100)])
    let before = projection(old, [.rename(speakerID: "system:S1", name: "Jim")])
    let new = timedRun("NEW", [speech("system:Y", 0, 15), speech("system:X", 60, 260), speech("system:Y", 300, 305)])
    let result = SpeakerCarryOver.carry(from: before, to: new.run)
    #expect(result.actions.isEmpty)
    #expect(result.unmatchedSpeakers == ["system:S1"])

    // The refused new speaker stays free: Bob, who spoke 100–280, still maps to X.
    let two = timedRun("OLD", [speech("system:S1", 0, 100), speech("system:S2", 100, 280)])
    let both = projection(two, [.rename(speakerID: "system:S1", name: "Jim"),
                                .rename(speakerID: "system:S2", name: "Bob")])
    let mapped = SpeakerCarryOver.carry(from: both, to: new.run)
    // Bob–X (160 s) goes first; Jim's best left is Y (15 s of Y's 20 s), which passes.
    #expect(mapped.actions == [.rename(speakerID: "system:Y", name: "Jim"), .rename(speakerID: "system:X", name: "Bob")])
    #expect(mapped.unmatchedSpeakers.isEmpty)
}

@Test func carryIgnoresUnlabelledAndAutomaticSpeakers() {
    let old = timedRun("OLD", [speech("system:S1", 0, 60), speech("system:S2", 60, 120)])
    let recognition = RecognitionResult(
        runID: "OLD", createdAt: fixedDate, embeddingModel: EmbeddingModelID(id: "wespeaker", revision: "1"),
        thresholds: RecognitionThresholds(likelyMaxDistance: 0.2, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                          minSampleSeconds: 20),
        matches: [SpeakerMatch(speakerID: "system:S1", profileID: "P-JIM", profileName: "Jim", distance: 0.1,
                               tier: .likely)])
    let before = projection(old, [], recognition: recognition, names: ["P-JIM": "Jim"])
    #expect(before.speakers.first?.label == "Jim (auto)")
    let result = SpeakerCarryOver.carry(from: before, to: timedRun("NEW", [speech("system:S1", 0, 120)]).run)
    #expect(result == SpeakerCarryOver.Result())
}

@Test func carryOfAnEmptyNewRunReportsEveryLabel() {
    let old = timedRun("OLD", [speech("system:S1", 0, 60), speech("system:S2", 60, 120)])
    let before = projection(old, [.rename(speakerID: "system:S2", name: "Maria"),
                                  .rename(speakerID: "system:S1", name: "Jim")])
    let empty = DiarizationRun(id: "NEW", sessionID: "SESSION", createdAt: fixedDate, transcriptID: "T", engine: nil,
                               alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: [], speakers: [],
                               turns: [])
    let result = SpeakerCarryOver.carry(from: before, to: empty)
    #expect(result.actions.isEmpty)
    #expect(result.unmatchedSpeakers == ["system:S1", "system:S2"])
}
