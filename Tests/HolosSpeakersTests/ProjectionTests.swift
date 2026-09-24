import CryptoKit
import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// MARK: - Fixture

private let runID = "RUN-A"
private let fixedDate = Date(timeIntervalSince1970: 1_000_000)

/// Six measured words "w0 … w5", word i at [start + i, start + i + 0.8).
private func segment(_ id: String, start: Double, track: String) -> TranscriptSegment {
    var text = ""
    var words: [TimedWord] = []
    for index in 0..<6 {
        if index > 0 { text += " " }
        let token = "w\(index)"
        words.append(TimedWord(text: token, start: start + Double(index), end: start + Double(index) + 0.8,
                               utf16Offset: text.utf16.count, utf16Length: token.utf16.count))
        text += token
    }
    return TranscriptSegment(id: id, start: start, end: start + 5.8, text: text, words: words, track: track)
}

/// Seven system turns of three diarized speakers and one microphone turn of the channel speaker, one segment
/// "seg-Tn" per turn: T1 S1 0, T2 S2 10, T3 S3 20, T4 S1 30, T5 S2 40, T6 S3 50, T7 S1 60 (system); T8 mic:me 65.
private let fixtureTurns: [(id: String, track: String, start: Double, speaker: String)] = [
    ("T1", "system", 0, "system:S1"), ("T2", "system", 10, "system:S2"), ("T3", "system", 20, "system:S3"),
    ("T4", "system", 30, "system:S1"), ("T5", "system", 40, "system:S2"), ("T6", "system", 50, "system:S3"),
    ("T7", "system", 60, "system:S1"), ("T8", "mic", 65, "mic:me"),
]

private let fixtureTranscript = Transcript(
    id: "TRANSCRIPT", createdAt: fixedDate, source: "mic+system", locale: "en-US", backend: .speech,
    segments: fixtureTurns.map { segment("seg-\($0.id)", start: $0.start, track: $0.track) })

private let fixtureRun = DiarizationRun(
    id: runID, sessionID: "SESSION", createdAt: fixedDate, transcriptID: "TRANSCRIPT", engine: nil,
    alignment: AlignmentInfo(version: 1, parameters: .v1),
    tracks: [TrackDiarization(track: "system", policy: .diarized),
             TrackDiarization(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me"))],
    speakers: [
        SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"]),
        SessionSpeaker(id: "system:S2", ordinal: 2, provenance: .diarizer, clusterIDs: ["system:S2"]),
        SessionSpeaker(id: "system:S3", ordinal: 3, provenance: .diarizer, clusterIDs: ["system:S3"]),
        SessionSpeaker(id: "mic:me", ordinal: 4, displayName: "Me", provenance: .channelAssumption),
    ],
    turns: fixtureTurns.map { turn in
        let channel = turn.track == "mic"
        return SpeakerTurn(id: turn.id, track: turn.track, start: turn.start, end: turn.start + 5.8,
                           speakerID: turn.speaker, clusterID: channel ? nil : turn.speaker,
                           spans: [WordSpan(segmentID: "seg-\(turn.id)", first: 0, end: 6)],
                           assignmentScore: channel ? 1 : 0.9, timing: .measured)
    })

private func project(_ edits: [SpeakerEdit] = [], recognition: RecognitionResult? = nil,
                     names: [String: String] = [:]) -> SpeakerProjection {
    SpeakerProjection.make(run: fixtureRun, transcript: fixtureTranscript, edits: edits, recognition: recognition,
                           profileNames: names)
}

private func edit(_ action: SpeakerEditAction, id: String, expected: String? = nil, batch: String? = nil,
                  run: String = runID) -> SpeakerEdit {
    SpeakerEdit(id: id, baseRunID: run, at: fixedDate, source: "cli", action: action, expected: expected,
                batchID: batch)
}

/// Appends edits the way `SpeakerEditor` does: each carries the fingerprint of the projection it was made on.
private struct Journal {
    var edits: [SpeakerEdit] = []
    var recognition: RecognitionResult?
    var names: [String: String] = [:]

    var view: SpeakerProjection { project(edits, recognition: recognition, names: names) }

    mutating func append(_ action: SpeakerEditAction, id: String, batch: String? = nil) {
        edits.append(edit(action, id: id, expected: view.fingerprint(for: action), batch: batch))
    }

    /// An edit made on an older view (another window), appended now.
    mutating func append(_ action: SpeakerEditAction, id: String, madeOn older: SpeakerProjection) {
        edits.append(edit(action, id: id, expected: older.fingerprint(for: action)))
    }
}

private func recognition(_ matches: [SpeakerMatch], run: String = runID,
                         merges: [MergeSuggestion] = []) -> RecognitionResult {
    RecognitionResult(runID: run, createdAt: fixedDate, embeddingModel: EmbeddingModelID(id: "wespeaker", revision: "1"),
                      thresholds: RecognitionThresholds(likelyMaxDistance: 0.2, likelyMinMargin: 0.1,
                                                        possibleMaxDistance: 0.4, minSampleSeconds: 20),
                      matches: matches, mergeSuggestions: merges)
}

private let likelyJim = SpeakerMatch(speakerID: "system:S1", profileID: "P-JIM", profileName: "Jim (old)",
                                     distance: 0.12, tier: .likely)
private let possibleMaria = SpeakerMatch(speakerID: "system:S2", profileID: "P-MARIA", profileName: "Maria",
                                         distance: 0.31, tier: .possible)
private let people = ["P-JIM": "Jim", "P-MARIA": "Maria"]

private func speaker(_ projection: SpeakerProjection, _ id: String) -> ProjectedSpeaker? {
    projection.speakers.first { $0.id == id }
}

private func turn(_ projection: SpeakerProjection, _ id: String) -> ProjectedTurn? {
    projection.turns.first { $0.id == id }
}

// MARK: - Base projection

@Test func unchangedRunProjectsMachineLabels() throws {
    let projection = project()
    #expect(projection.runID == runID)
    #expect(projection.transcriptID == "TRANSCRIPT")
    #expect(projection.speakers.map(\.id) == ["system:S1", "system:S2", "system:S3", "mic:me"])
    #expect(projection.speakers.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3", "Me"])
    #expect(projection.speakers.map(\.provenance) == [.diarizer, .diarizer, .diarizer, .channelAssumption])
    #expect(projection.turns.map(\.id) == ["T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8"])
    #expect(projection.turns.allSatisfy { !$0.reassigned && !$0.modified && !$0.excludedFromEnrollment && !$0.uncertain })
    let s1 = try #require(speaker(projection, "system:S1"))
    #expect(s1.turnCount == 3)
    #expect(abs(s1.talkSeconds - 3 * 5.8) < 1e-9)
    #expect(s1.clusterIDs == ["system:S1"])
    #expect(projection.appliedEditIDs.isEmpty && projection.staleEdits.isEmpty && projection.revertedEditIDs.isEmpty)
    #expect(projection.editCount == 0)
    #expect(projection.lastUndoableBatchID == nil)
    #expect(projection.mergeSuggestions.isEmpty)
}

// MARK: - Actions

/// What `fingerprint(for:)` returns for `raw`, compacted independently with CryptoKit.
private func compacted(_ raw: String) -> String {
    guard raw.unicodeScalars.count > 256 else { return raw }
    return "fp1:sha256:" + SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test func renameApplies() throws {
    let projection = project([edit(.rename(speakerID: "system:S2", name: "Maria"), id: "E1",
                                   expected: "fp1:rename:speaker=9:system:S2=present;ordinal=2;name=none")])
    let s2 = try #require(speaker(projection, "system:S2"))
    #expect(s2.name == "Maria")
    #expect(s2.label == "Maria")
    #expect(s2.explicitName == "Maria")
    #expect(s2.provenance == .userRenamed)
    #expect(!s2.isAutomatic)
    #expect(projection.appliedEditIDs == ["E1"])
    #expect(projection.staleEdits.isEmpty)
    #expect(projection.editCount == 1)
}

@Test func renameTrimsAndBlankClears() throws {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S2", name: "  Maria \n"), id: "E1")
    #expect(speaker(journal.view, "system:S2")?.explicitName == "Maria")
    journal.append(.rename(speakerID: "system:S2", name: "   "), id: "E2")
    let s2 = try #require(speaker(journal.view, "system:S2"))
    #expect(s2.explicitName == nil)
    #expect(s2.name == "Speaker 2")
    #expect(s2.provenance == .diarizer)
    #expect(journal.view.appliedEditIDs == ["E1", "E2"])
}

@Test func staleRenameIsSkipped() {
    let projection = project([edit(.rename(speakerID: "system:S2", name: "Maria"), id: "E1", expected: "Jim")])
    #expect(projection.staleEdits == [StaleEdit(editID: "E1", reason: "changed since the edit was made")])
    #expect(projection.appliedEditIDs.isEmpty)
    #expect(speaker(projection, "system:S2")?.name == "Speaker 2")
}

@Test func otherRunEditsCounted() {
    let projection = project([edit(.rename(speakerID: "system:S2", name: "Maria"), id: "E1", expected: "", run: "RUN-B")])
    #expect(projection.otherRunEditCount == 1)
    #expect(projection.editCount == 0)
    #expect(projection.appliedEditIDs.isEmpty)
    #expect(projection.staleEdits.isEmpty)
    #expect(speaker(projection, "system:S2")?.name == "Speaker 2")
}

@Test func mergeMovesTurnsAndRemovesSpeaker() throws {
    let before = project()
    var journal = Journal()
    journal.append(.merge(from: "system:S3", into: "system:S1"), id: "E1")
    journal.append(.rename(speakerID: "system:S3", name: "Sam"), id: "E2", madeOn: before)
    let projection = journal.view
    #expect(speaker(projection, "system:S3") == nil)
    #expect(turn(projection, "T3")?.speakerID == "system:S1")
    #expect(turn(projection, "T6")?.speakerID == "system:S1")
    let s1 = try #require(speaker(projection, "system:S1"))
    #expect(s1.clusterIDs == ["system:S1", "system:S3"])
    #expect(s1.turnCount == 5)
    #expect(s1.name == "Speaker 1")
    #expect(projection.appliedEditIDs == ["E1"])
    #expect(projection.staleEdits == [StaleEdit(editID: "E2", reason: "speaker not found")])
}

@Test func mergedTurnsAreNotReassigned() throws {
    var journal = Journal()
    journal.append(.merge(from: "system:S3", into: "system:S1"), id: "E1")
    let projection = journal.view
    for id in ["T3", "T6"] {
        let merged = try #require(turn(projection, id))
        #expect(merged.speakerID == "system:S1")
        #expect(!merged.reassigned)
        #expect(merged.clusterID == "system:S3")
    }
}

@Test func mergeKeepsTheTargetsName() throws {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "Jim"), id: "E1")
    journal.append(.rename(speakerID: "system:S3", name: "Sam"), id: "E2")
    journal.append(.merge(from: "system:S3", into: "system:S1"), id: "E3")
    #expect(speaker(journal.view, "system:S1")?.name == "Jim")
    #expect(!journal.view.speakers.contains { $0.name == "Sam" })
}

@Test func reassignTurnsToUnknown() throws {
    var journal = Journal()
    journal.append(.reassignTurns(turnIDs: ["T4"], to: nil), id: "E1")
    let projection = journal.view
    let t4 = try #require(turn(projection, "T4"))
    #expect(t4.speakerID == nil)
    #expect(t4.uncertain)
    #expect(t4.reassigned)
    #expect(t4.clusterID == "system:S1")
    #expect(speaker(projection, "system:S1")?.turnCount == 2)
}

@Test func reassignedTurnIsFlaggedAndCountsForItsNewSpeaker() throws {
    var journal = Journal()
    journal.append(.reassignTurns(turnIDs: ["T4", "T8"], to: "system:S2"), id: "E1")
    let projection = journal.view
    #expect(turn(projection, "T4")?.reassigned == true)
    #expect(turn(projection, "T8")?.reassigned == true)   // channel turn: the speaker differs
    #expect(turn(projection, "T8")?.uncertain == false)
    #expect(speaker(projection, "system:S2")?.turnCount == 4)
    // A speaker left without turns is hidden; a channel speaker is no exception.
    #expect(speaker(projection, "mic:me") == nil)
    journal.append(.reassignTurns(turnIDs: ["T4"], to: "system:S1"), id: "E2")
    #expect(turn(journal.view, "T4")?.reassigned == false)
}

@Test func splitTurnCreatesSuffixTurn() throws {
    var journal = Journal()
    journal.append(.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 3)), id: "E1")
    let projection = journal.view
    #expect(projection.turns.map(\.id) == ["T1", "T2", "T3", "T4", "T5", "T5/E1", "T6", "T7", "T8"])
    let head = try #require(turn(projection, "T5"))
    let tail = try #require(turn(projection, "T5/E1"))
    #expect(head.spans == [WordSpan(segmentID: "seg-T5", first: 0, end: 3)])
    #expect(tail.spans == [WordSpan(segmentID: "seg-T5", first: 3, end: 6)])
    #expect(head.modified && tail.modified)
    #expect(head.start == 40 && abs(head.end - 42.8) < 1e-9)
    #expect(tail.start == 43 && abs(tail.end - 45.8) < 1e-9)
    #expect(head.speakerID == "system:S2" && tail.speakerID == "system:S2")
    #expect(!head.reassigned && !tail.reassigned)
    #expect(tail.clusterID == "system:S2")
    #expect(tail.timing == .measured)
    #expect(speaker(projection, "system:S2")?.turnCount == 3)
    #expect(projection.turns.filter(\.modified).count == 2)

    // The new part can be edited like any turn.
    journal.append(.reassignTurns(turnIDs: ["T5/E1"], to: "system:S3"), id: "E2")
    #expect(turn(journal.view, "T5/E1")?.speakerID == "system:S3")
    #expect(turn(journal.view, "T5")?.speakerID == "system:S2")
}

@Test func splitAcrossSpansAndEstimatedWords() throws {
    // One turn over two segments; the second has no measured words, so its times are spread evenly.
    let measured = segment("seg-A", start: 0, track: "system")
    let untimed = TranscriptSegment(id: "seg-B", start: 6, end: 10, text: "one two three four", track: "system")
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: fixedDate, source: "system", locale: "en-US",
                                backend: .speech, segments: [measured, untimed])
    let run = DiarizationRun(
        id: runID, sessionID: "SESSION", createdAt: fixedDate, transcriptID: "TRANSCRIPT", engine: nil,
        alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: [],
        speakers: [SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])],
        turns: [SpeakerTurn(id: "T1", track: "system", start: 0, end: 10, speakerID: "system:S1",
                            clusterID: "system:S1",
                            spans: [WordSpan(segmentID: "seg-A", first: 0, end: 6),
                                    WordSpan(segmentID: "seg-B", first: 0, end: 4)],
                            assignmentScore: 0.9, timing: .mixed)])
    let base = SpeakerProjection.make(run: run, transcript: transcript, edits: [], recognition: nil, profileNames: [:])

    let between = base.applying(.splitTurn(turnID: "T1", at: WordRef(segmentID: "seg-B", word: 0)), editID: "E1")
    #expect(between.turns.map(\.spans) == [[WordSpan(segmentID: "seg-A", first: 0, end: 6)],
                                           [WordSpan(segmentID: "seg-B", first: 0, end: 4)]])
    #expect(between.turns.map(\.timing) == [.measured, .estimated])
    #expect(between.turns.map(\.start) == [0, 6])

    let inside = base.applying(.splitTurn(turnID: "T1", at: WordRef(segmentID: "seg-B", word: 2)), editID: "E1")
    #expect(inside.turns.map(\.spans) == [[WordSpan(segmentID: "seg-A", first: 0, end: 6),
                                           WordSpan(segmentID: "seg-B", first: 0, end: 2)],
                                          [WordSpan(segmentID: "seg-B", first: 2, end: 4)]])
    #expect(inside.turns.map(\.timing) == [.mixed, .estimated])
    #expect(inside.turns.map(\.start) == [0, 8])
    #expect(inside.turns.map(\.end) == [8, 10])
}

@Test func newSpeakerGetsNextOrdinal() throws {
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:X", name: "Guest", turnIDs: ["T7"]), id: "E1")
    let projection = journal.view
    let guest = try #require(speaker(projection, "user:X"))
    #expect(guest.ordinal == 5)
    #expect(guest.name == "Guest")
    #expect(guest.explicitName == "Guest")
    #expect(guest.provenance == .userRenamed)
    #expect(guest.turnCount == 1)
    #expect(guest.clusterIDs.isEmpty)
    #expect(projection.speakers.last?.id == "user:X")
    #expect(turn(projection, "T7")?.speakerID == "user:X")
    #expect(turn(projection, "T7")?.reassigned == true)
}

@Test func userCreatedSpeakerIsListedWithoutTurns() throws {
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:Y", name: nil, turnIDs: []), id: "E1")
    let empty = try #require(speaker(journal.view, "user:Y"))
    #expect(empty.turnCount == 0)
    #expect(empty.name == "Speaker 5")
    // A diarizer speaker without turns is hidden, and a new speaker never reuses its ordinal.
    journal.append(.merge(from: "system:S3", into: "system:S1"), id: "E2")
    journal.append(.newSpeaker(speakerID: "user:Z", name: "Zoe", turnIDs: ["T2"]), id: "E3")
    #expect(speaker(journal.view, "user:Z")?.ordinal == 6)
    #expect(journal.view.speakers.map(\.id) == ["system:S1", "system:S2", "mic:me", "user:Y", "user:Z"])
}

@Test func excludeFlagsTurns() {
    var journal = Journal()
    journal.append(.excludeFromEnrollment(turnIDs: ["T2", "T5"]), id: "E1")
    #expect(journal.view.turns.filter(\.excludedFromEnrollment).map(\.id) == ["T2", "T5"])
    // The second part of a split keeps the flag.
    journal.append(.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 2)), id: "E2")
    #expect(journal.view.turns.filter(\.excludedFromEnrollment).map(\.id) == ["T2", "T5", "T5/E2"])
}

@Test func linkUsesTheProfileNameAndConfirms() throws {
    var journal = Journal(names: people)
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E1")
    let jim = try #require(speaker(journal.view, "system:S1"))
    #expect(jim.name == "Jim")
    #expect(jim.profileID == "P-JIM")
    #expect(jim.provenance == .userConfirmed)
    #expect(!jim.isAutomatic)
    // Without the profile's name (forgotten, or no profile store) the link stays but the name falls back.
    let nameless = project(journal.edits)
    #expect(speaker(nameless, "system:S1")?.name == "Speaker 1")
    #expect(speaker(nameless, "system:S1")?.provenance == .userConfirmed)
}

@Test func linkAndRejectUpdateEachOther() throws {
    var journal = Journal(names: people)
    journal.append(.rejectProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E1")
    journal.append(.rejectProfile(speakerID: "system:S1", profileID: "P-MARIA"), id: "E2")
    #expect(speaker(journal.view, "system:S1")?.rejectedProfileIDs == ["P-JIM", "P-MARIA"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E3")
    #expect(speaker(journal.view, "system:S1")?.rejectedProfileIDs == ["P-MARIA"])
    #expect(speaker(journal.view, "system:S1")?.profileID == "P-JIM")
    journal.append(.rejectProfile(speakerID: "system:S1", profileID: "P-MARIA"), id: "E4")   // not the link
    #expect(speaker(journal.view, "system:S1")?.profileID == "P-JIM")
    journal.append(.rejectProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E5")
    let s1 = try #require(speaker(journal.view, "system:S1"))
    #expect(s1.profileID == nil)
    #expect(s1.rejectedProfileIDs == ["P-MARIA", "P-JIM"])
    #expect(s1.name == "Speaker 1")
}

// MARK: - Reverts and undo

@Test func revertSkipsEdit() throws {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "Jim"), id: "E1")
    journal.append(.revert(editID: "E1"), id: "E2")
    let projection = journal.view
    let s1 = try #require(speaker(projection, "system:S1"))
    #expect(s1.explicitName == nil)
    #expect(s1.name == "Speaker 1")
    #expect(projection.revertedEditIDs == ["E1"])
    #expect(projection.appliedEditIDs.isEmpty)
    #expect(projection.staleEdits.isEmpty)
    #expect(projection.editCount == 2)
}

@Test func revertKeepsLaterEditsThatStillApply() throws {
    var journal = Journal()
    journal.append(.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 3)), id: "E1")
    journal.append(.rename(speakerID: "system:S2", name: "Maria"), id: "E2")
    journal.append(.reassignTurns(turnIDs: ["T5/E1"], to: "system:S3"), id: "E3")
    journal.append(.revert(editID: "E1"), id: "E4")
    let projection = journal.view
    // Without the split, T5/E1 does not exist: the reassign that named it becomes stale; the rename stays.
    #expect(projection.turns.map(\.id) == ["T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8"])
    #expect(projection.appliedEditIDs == ["E2"])
    #expect(projection.revertedEditIDs == ["E1"])
    #expect(projection.staleEdits == [StaleEdit(editID: "E3", reason: "turn not found")])
    #expect(speaker(projection, "system:S2")?.name == "Maria")
}

@Test func revertOfRevertIsStale() throws {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "Jim"), id: "E1")
    journal.append(.revert(editID: "E1"), id: "E2")
    journal.append(.revert(editID: "E2"), id: "E3")
    let projection = journal.view
    #expect(projection.staleEdits == [StaleEdit(editID: "E3", reason: "cannot revert an undo")])
    #expect(projection.revertedEditIDs == ["E1"])
    #expect(speaker(projection, "system:S1")?.name == "Speaker 1")
}

@Test func invalidRevertsAreStale() {
    var journal = Journal()
    journal.append(.revert(editID: "E-MISSING"), id: "E1")
    journal.append(.rename(speakerID: "system:S1", name: "Jim"), id: "E2")
    journal.append(.revert(editID: "E2"), id: "E3")
    journal.append(.revert(editID: "E2"), id: "E4")
    journal.edits.insert(edit(.revert(editID: "E6"), id: "E5"), at: 0)   // before the edit it names
    journal.append(.rename(speakerID: "system:S2", name: "Maria"), id: "E6")
    journal.append(.revert(editID: "E-OTHER"), id: "E7")
    journal.edits.append(edit(.rename(speakerID: "system:S3", name: "Sam"), id: "E-OTHER", expected: "", run: "RUN-B"))
    let projection = journal.view
    #expect(projection.staleEdits == [
        StaleEdit(editID: "E5", reason: "edit not found"),
        StaleEdit(editID: "E1", reason: "edit not found"),
        StaleEdit(editID: "E4", reason: "already reverted"),
        StaleEdit(editID: "E7", reason: "edit not found"),
    ])
    #expect(projection.revertedEditIDs == ["E2"])
    #expect(projection.appliedEditIDs == ["E6"])
    #expect(projection.otherRunEditCount == 1)
}

@Test func lastUndoableBatchIsNewestBatch() {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "A"), id: "E1", batch: "B1")
    journal.append(.rename(speakerID: "system:S2", name: "B"), id: "E2", batch: "B1")
    journal.append(.rename(speakerID: "system:S3", name: "C"), id: "E3", batch: "B2")
    #expect(journal.view.lastUndoableBatchID == "B2")
    journal.append(.revert(editID: "E3"), id: "E4", batch: "B3")
    #expect(journal.view.lastUndoableBatchID == "B1")
    journal.append(.revert(editID: "E1"), id: "E5", batch: "B4")
    journal.append(.revert(editID: "E2"), id: "E6", batch: "B4")
    #expect(journal.view.lastUndoableBatchID == nil)
    // An edit without a batch ID is a batch of its own.
    journal.append(.rename(speakerID: "system:S1", name: "D"), id: "E7")
    #expect(journal.view.lastUndoableBatchID == "E7")
}

// MARK: - Recognition

@Test func likelyMatchIsAutomatic() throws {
    let projection = project(recognition: recognition([likelyJim]), names: people)
    let s1 = try #require(speaker(projection, "system:S1"))
    #expect(s1.name == "Jim")
    #expect(s1.label == "Jim (auto)")
    #expect(s1.isAutomatic)
    #expect(s1.provenance == .recognized(distance: 0.12, tier: .likely))
    #expect(s1.profileID == nil)
    #expect(s1.suggestion == nil)
}

@Test func forgottenProfileMatchIsIgnored() throws {
    let projection = project(recognition: recognition([likelyJim, possibleMaria]), names: ["P-OTHER": "Other"])
    let s1 = try #require(speaker(projection, "system:S1"))
    #expect(s1.label == "Speaker 1")
    #expect(!s1.isAutomatic)
    #expect(s1.suggestion == nil)
    #expect(speaker(projection, "system:S2")?.suggestion == nil)
    // A blank name counts as forgotten too.
    #expect(speaker(project(recognition: recognition([likelyJim]), names: ["P-JIM": " "]), "system:S1")?.label == "Speaker 1")
}

@Test func recognitionOfAnotherRunIsIgnored() {
    let projection = project(recognition: recognition([likelyJim, possibleMaria], run: "RUN-B"), names: people)
    #expect(projection.speakers.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3", "Me"])
    #expect(projection.speakers.allSatisfy { $0.suggestion == nil })
}

@Test func fingerprintIgnoresRecognition() {
    let projection = project(recognition: recognition([likelyJim]), names: people)
    #expect(projection.fingerprint(for: .linkProfile(speakerID: "system:S1", profileID: "P-JIM"))
        == "fp1:linkProfile:profile=5:P-JIM;speaker=9:system:S1=present;ordinal=1;link=none;rejected=0")
    #expect(projection.fingerprint(for: .rename(speakerID: "system:S1", name: "Jim"))
        == "fp1:rename:speaker=9:system:S1=present;ordinal=1;name=none")
    #expect(projection.fingerprint(for: .rejectProfile(speakerID: "system:S1", profileID: "P-JIM"))
        == "fp1:rejectProfile:profile=5:P-JIM;speaker=9:system:S1=present;ordinal=1;link=none;rejected=0")
    #expect(projection.fingerprint(for: .merge(from: "system:S1", into: "system:S2"))
        == project().fingerprint(for: .merge(from: "system:S1", into: "system:S2")))
}

@Test func rejectProfileSuppressesMatch() throws {
    var journal = Journal(recognition: recognition([likelyJim, possibleMaria]), names: people)
    journal.append(.rejectProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E1")
    journal.append(.rejectProfile(speakerID: "system:S2", profileID: "P-MARIA"), id: "E2")
    let s1 = try #require(speaker(journal.view, "system:S1"))
    #expect(s1.label == "Speaker 1")
    #expect(!s1.isAutomatic)
    #expect(s1.provenance == .diarizer)
    #expect(s1.rejectedProfileIDs == ["P-JIM"])
    #expect(speaker(journal.view, "system:S2")?.suggestion == nil)
}

@Test func possibleMatchIsSuggestionOnly() throws {
    let projection = project(recognition: recognition([possibleMaria]), names: ["P-MARIA": "Maria R."])
    let s2 = try #require(speaker(projection, "system:S2"))
    #expect(s2.label == "Speaker 2")
    #expect(!s2.isAutomatic)
    #expect(s2.provenance == .diarizer)
    #expect(s2.suggestion?.profileID == "P-MARIA")
    #expect(s2.suggestion?.tier == .possible)
    #expect(s2.suggestion?.profileName == "Maria R.")   // the current name
}

@Test func userRenameBeatsRecognition() throws {
    var journal = Journal(recognition: recognition([likelyJim, possibleMaria]), names: people)
    journal.append(.rename(speakerID: "system:S1", name: "James"), id: "E1")
    journal.append(.linkProfile(speakerID: "system:S2", profileID: "P-JIM"), id: "E2")
    let s1 = try #require(speaker(journal.view, "system:S1"))
    #expect(s1.name == "James")
    #expect(s1.label == "James")
    #expect(s1.provenance == .userRenamed)
    #expect(!s1.isAutomatic)
    // A confirmed link also replaces a suggestion.
    let s2 = try #require(speaker(journal.view, "system:S2"))
    #expect(s2.name == "Jim")
    #expect(s2.suggestion == nil)
}

@Test func speakersLinkedToOneProfileSuggestAMerge() {
    var journal = Journal(names: people)
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-JIM"), id: "E1")
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E2")
    #expect(journal.view.mergeSuggestions == [MergeSuggestion(speakerIDs: ["system:S1", "system:S3"], profileID: "P-JIM")])
    journal.append(.merge(from: "system:S3", into: "system:S1"), id: "E3")
    #expect(journal.view.mergeSuggestions.isEmpty)
}

@Test func recognitionMergeSuggestionsFollowEdits() {
    let merges = [MergeSuggestion(speakerIDs: ["system:S1", "system:S2", "system:S3"], profileID: "P-JIM"),
                  MergeSuggestion(speakerIDs: ["system:S2", "system:S3"], profileID: "P-GONE")]
    var journal = Journal(recognition: recognition([likelyJim], merges: merges), names: people)
    #expect(journal.view.mergeSuggestions
        == [MergeSuggestion(speakerIDs: ["system:S1", "system:S2", "system:S3"], profileID: "P-JIM")])
    journal.append(.rejectProfile(speakerID: "system:S2", profileID: "P-JIM"), id: "E1")
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-MARIA"), id: "E2")
    #expect(journal.view.mergeSuggestions.isEmpty)
}

// MARK: - Fingerprints and stale views

@Test func fingerprintsDescribeTheStateAnEditActsOn() {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "Jim"), id: "E1")
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E2")
    journal.append(.rejectProfile(speakerID: "system:S2", profileID: "P-BOB"), id: "E3")
    journal.append(.reassignTurns(turnIDs: ["T6"], to: nil), id: "E4")
    journal.append(.excludeFromEnrollment(turnIDs: ["T2"]), id: "E5")
    let view = journal.view
    #expect(view.fingerprint(for: .rename(speakerID: "system:S1", name: "X"))
        == "fp1:rename:speaker=9:system:S1=present;ordinal=1;name=3:Jim")
    #expect(view.fingerprint(for: .rename(speakerID: "system:S9", name: "X")) == "fp1:rename:speaker=9:system:S9=absent")
    #expect(view.fingerprint(for: .linkProfile(speakerID: "system:S1", profileID: "P"))
        == "fp1:linkProfile:profile=1:P;speaker=9:system:S1=present;ordinal=1;link=5:P-JIM;rejected=0")
    #expect(view.fingerprint(for: .linkProfile(speakerID: "system:S2", profileID: "P-BOB"))
        == "fp1:linkProfile:profile=5:P-BOB;speaker=9:system:S2=present;ordinal=2;link=none;rejected=1")
    #expect(view.fingerprint(for: .reassignTurns(turnIDs: ["T1", "T6", "T99"], to: "system:S2"))
        == "fp1:reassignTurns:to=9:system:S2=present;ordinal=2;turns=3["
            + "2:T1=present;speaker=9:system:S1;words=1[6:seg-T1@0..<6],"
            + "2:T6=present;speaker=none;words=1[6:seg-T6@0..<6],3:T99=absent]")
    #expect(view.fingerprint(for: .reassignTurns(turnIDs: ["T8"], to: nil))
        == "fp1:reassignTurns:to=none;turns=1[2:T8=present;speaker=6:mic:me;words=1[6:seg-T8@0..<6]]")
    #expect(view.fingerprint(for: .reassignTurns(turnIDs: ["T8"], to: "system:S9"))
        == "fp1:reassignTurns:to=9:system:S9=absent;turns=1[2:T8=present;speaker=6:mic:me;words=1[6:seg-T8@0..<6]]")
    #expect(view.fingerprint(for: .rejectProfile(speakerID: "system:S1", profileID: "P-BOB"))
        == "fp1:rejectProfile:profile=5:P-BOB;speaker=9:system:S1=present;ordinal=1;link=5:P-JIM;rejected=0")
    #expect(view.fingerprint(for: .rejectProfile(speakerID: "system:S2", profileID: "P-BOB"))
        == "fp1:rejectProfile:profile=5:P-BOB;speaker=9:system:S2=present;ordinal=2;link=none;rejected=1")
    #expect(view.fingerprint(for: .rejectProfile(speakerID: "system:S9", profileID: "P-BOB"))
        == "fp1:rejectProfile:profile=5:P-BOB;speaker=9:system:S9=absent")
    // Merges describe both speakers in full, so these are long enough to be hashed.
    #expect(view.fingerprint(for: .merge(from: "system:S3", into: "system:S1")) == compacted(
        "fp1:merge:from=9:system:S3=present;ordinal=3;name=none;link=none;rejected=0[];clusters=1[9:system:S3];"
            + "turns=1[2:T3:words=1[6:seg-T3@0..<6];excluded=0]"
            + ";into=9:system:S1=present;ordinal=1;name=3:Jim;link=5:P-JIM;rejected=0[];clusters=1[9:system:S1];"
            + "turns=3[2:T1:words=1[6:seg-T1@0..<6];excluded=0,2:T4:words=1[6:seg-T4@0..<6];excluded=0,"
            + "2:T7:words=1[6:seg-T7@0..<6];excluded=0]"))
    #expect(view.fingerprint(for: .merge(from: "system:S2", into: "system:S3")) == compacted(
        "fp1:merge:from=9:system:S2=present;ordinal=2;name=none;link=none;rejected=1[5:P-BOB];"
            + "clusters=1[9:system:S2];turns=2[2:T2:words=1[6:seg-T2@0..<6];excluded=1,"
            + "2:T5:words=1[6:seg-T5@0..<6];excluded=0]"
            + ";into=9:system:S3=present;ordinal=3;name=none;link=none;rejected=0[];clusters=1[9:system:S3];"
            + "turns=1[2:T3:words=1[6:seg-T3@0..<6];excluded=0]"))
    #expect(view.fingerprint(for: .merge(from: "system:S9", into: "mic:me")) == compacted(
        "fp1:merge:from=9:system:S9=absent;into=6:mic:me=present;ordinal=4;name=none;link=none;rejected=0[];"
            + "clusters=0[];turns=1[2:T8:words=1[6:seg-T8@0..<6];excluded=0]"))
    #expect(view.fingerprint(for: .splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 3)))
        == "fp1:splitTurn:turn=2:T5=present;speaker=9:system:S2;words=1[6:seg-T5@0..<6]")
    #expect(view.fingerprint(for: .newSpeaker(speakerID: "user:X", name: nil, turnIDs: ["T2", "T6"]))
        == "fp1:newSpeaker:speaker=6:user:X=absent;turns=2[2:T2=present;speaker=9:system:S2;words=1[6:seg-T2@0..<6],"
            + "2:T6=present;speaker=none;words=1[6:seg-T6@0..<6]]")
    #expect(view.fingerprint(for: .excludeFromEnrollment(turnIDs: ["T2", "T99"]))
        == "fp1:excludeFromEnrollment:turns=2[2:T2=present;speaker=9:system:S2;words=1[6:seg-T2@0..<6];excluded=1,"
            + "3:T99=absent]")
    #expect(view.fingerprint(for: .revert(editID: "E1")) == nil)
    #expect(view.appliedEditIDs == ["E1", "E2", "E3", "E4", "E5"])
}

@Test func longFingerprintsAreHashed() throws {
    let longName = String(repeating: "Jimmy ", count: 50) + "Jones"    // 305 characters
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: longName), id: "E1")
    let fingerprint = try #require(journal.view.fingerprint(for: .rename(speakerID: "system:S1", name: nil)))
    let prefix = "fp1:rename:speaker=9:system:S1=present;ordinal=1;name="
    let raw = prefix + "305:" + longName
    let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(fingerprint == "fp1:sha256:" + digest)
    // The hashed value still protects the edit.
    journal.append(.rename(speakerID: "system:S1", name: "Jim"), id: "E2")
    #expect(journal.view.appliedEditIDs == ["E1", "E2"])
    journal.edits.append(edit(.rename(speakerID: "system:S1", name: "Bob"), id: "E3", expected: fingerprint))
    #expect(journal.view.staleEdits == [StaleEdit(editID: "E3", reason: "changed since the edit was made")])
    // A raw fingerprint of exactly 256 scalars stays as it is; one more is hashed.
    #expect(prefix.unicodeScalars.count == 54)
    let limit = String(repeating: "\u{E9}", count: 198)            // 54 + "198:" + 198 = 256 scalars
    var short = Journal()
    short.append(.rename(speakerID: "system:S1", name: limit), id: "E1")
    #expect(short.view.fingerprint(for: .rename(speakerID: "system:S1", name: nil)) == prefix + "198:" + limit)
    let over = limit + "\u{E9}"
    short.append(.rename(speakerID: "system:S1", name: over), id: "E2")
    let overRaw = prefix + "199:" + over
    #expect(overRaw.unicodeScalars.count == 257)
    #expect(short.view.fingerprint(for: .rename(speakerID: "system:S1", name: nil)) == compacted(overRaw))
    #expect(compacted(overRaw) != overRaw)
}

@Test func hashedFingerprintNeverEqualsARawOne() throws {
    // Window B loads S1 with a long name, whose fingerprint is hashed. Window A renames S1 to that exact hashed
    // text. B's rename, made on the long name, must not overwrite A's.
    let longName = String(repeating: "Jimmy ", count: 50) + "Jones"
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: longName), id: "E1")
    let older = journal.view
    let hashed = try #require(older.fingerprint(for: .rename(speakerID: "system:S1", name: nil)))
    #expect(hashed.hasPrefix("fp1:sha256:"))
    journal.append(.rename(speakerID: "system:S1", name: hashed), id: "E2")
    #expect(journal.view.fingerprint(for: .rename(speakerID: "system:S1", name: nil)) != hashed)
    journal.append(.rename(speakerID: "system:S1", name: "Bob"), id: "E3", madeOn: older)
    #expect(journal.view.staleEdits == [StaleEdit(editID: "E3", reason: "changed since the edit was made")])
    #expect(speaker(journal.view, "system:S1")?.explicitName == hashed)
}

@Test func deletedSpeakerFingerprintDiffersFromAnUnnamedOne() throws {
    // Window B loads unnamed S3; window A merges S3 into S1. The editor compares B's fingerprint with the current
    // one, so every action naming S3 must fingerprint differently now that S3 is gone.
    let older = project()
    var journal = Journal()
    journal.append(.merge(from: "system:S3", into: "system:S1"), id: "E1")
    let current = journal.view
    let actions: [SpeakerEditAction] = [
        .rename(speakerID: "system:S3", name: "Sam"),
        .linkProfile(speakerID: "system:S3", profileID: "P-JIM"),
        .rejectProfile(speakerID: "system:S3", profileID: "P-JIM"),
        .merge(from: "system:S3", into: "system:S2"),
        .merge(from: "system:S2", into: "system:S3"),
        .reassignTurns(turnIDs: ["T2"], to: "system:S3"),
    ]
    for action in actions {
        #expect(older.fingerprint(for: action) != current.fingerprint(for: action), "\(action)")
    }
    #expect(current.fingerprint(for: .rename(speakerID: "system:S3", name: "Sam")) == "fp1:rename:speaker=9:system:S3=absent")
    // A turn removed by reverting its split is absent, not an empty description.
    var split = Journal()
    split.append(.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 3)), id: "E1")
    let withPart = split.view
    split.append(.revert(editID: "E1"), id: "E2")
    let partActions: [SpeakerEditAction] = [
        .excludeFromEnrollment(turnIDs: ["T5/E1"]),
        .splitTurn(turnID: "T5/E1", at: WordRef(segmentID: "seg-T5", word: 4)),
        .reassignTurns(turnIDs: ["T5/E1"], to: nil),
        .newSpeaker(speakerID: "user:X", name: nil, turnIDs: ["T5/E1"]),
    ]
    for action in partActions {
        #expect(withPart.fingerprint(for: action) != split.view.fingerprint(for: action), "\(action)")
    }
    // A speaker re-created with the same ID after a merge removed it is a different speaker.
    var recreated = Journal()
    recreated.append(.newSpeaker(speakerID: "user:X", name: nil, turnIDs: ["T1"]), id: "E1")
    let first = recreated.view
    recreated.append(.merge(from: "user:X", into: "system:S2"), id: "E2")
    recreated.append(.newSpeaker(speakerID: "user:X", name: nil, turnIDs: ["T4"]), id: "E3")
    #expect(first.fingerprint(for: .rename(speakerID: "user:X", name: "Guest"))
        != recreated.view.fingerprint(for: .rename(speakerID: "user:X", name: "Guest")))
}

@Test func longTurnFingerprintsAreHashedAndStillRefuseStaleEdits() throws {
    var journal = Journal()
    for number in 1...7 {
        journal.append(.splitTurn(turnID: "T\(number)", at: WordRef(segmentID: "seg-T\(number)", word: 3)),
                       id: "X\(number)")
    }
    let older = journal.view
    let turnIDs = older.turns.map(\.id)
    #expect(turnIDs.count == 15)
    // 15 turn descriptions are well over 256 characters, so the exclude carries a tagged SHA-256.
    let exclude = SpeakerEditAction.excludeFromEnrollment(turnIDs: turnIDs)
    let fingerprint = try #require(older.fingerprint(for: exclude))
    #expect(fingerprint.hasPrefix("fp1:sha256:"))
    #expect(fingerprint.dropFirst(11).count == 64 && fingerprint.dropFirst(11).allSatisfy(\.isHexDigit))
    // Each action has its own tag, so the same turns hash differently for another action.
    let newSpeaker = SpeakerEditAction.newSpeaker(speakerID: "user:X", name: nil, turnIDs: turnIDs)
    let newSpeakerFingerprint = try #require(older.fingerprint(for: newSpeaker))
    #expect(newSpeakerFingerprint.hasPrefix("fp1:sha256:") && newSpeakerFingerprint != fingerprint)
    // Another window splits T8; the exclusion made before that split is refused and flags nothing.
    journal.append(.splitTurn(turnID: "T8", at: WordRef(segmentID: "seg-T8", word: 2)), id: "X8")
    journal.append(exclude, id: "E1", madeOn: older)
    #expect(journal.view.staleEdits == [StaleEdit(editID: "E1", reason: "changed since the edit was made")])
    #expect(journal.view.turns.allSatisfy { !$0.excludedFromEnrollment })
    // Made on the current view, the same exclusion applies.
    journal.append(exclude, id: "E2")
    #expect(journal.view.appliedEditIDs.last == "E2")
    #expect(journal.view.turns.filter(\.excludedFromEnrollment).map(\.id).sorted() == turnIDs.sorted())
}

@Test func fingerprintDigestMatchesCryptoKit() {
    #expect(FingerprintSHA256.hexDigest(Array("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(FingerprintSHA256.hexDigest([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    // Every padding case: lengths around the 56- and 64-byte block boundaries and several blocks.
    for length in 0...300 {
        let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let expected = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        #expect(FingerprintSHA256.hexDigest(bytes) == expected, "length \(length)")
    }
}

@Test func staleExcludeAfterSplitIsRefused() throws {
    let older = project()
    var journal = Journal()
    // Window A splits T5; window B, still showing the whole T5, excludes it.
    journal.append(.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 3)), id: "E1")
    journal.append(.excludeFromEnrollment(turnIDs: ["T5"]), id: "E2", madeOn: older)
    let projection = journal.view
    #expect(projection.appliedEditIDs == ["E1"])
    #expect(projection.staleEdits == [StaleEdit(editID: "E2", reason: "changed since the edit was made")])
    #expect(projection.turns.allSatisfy { !$0.excludedFromEnrollment })
    // Made on the current view, the same exclusion applies.
    journal.append(.excludeFromEnrollment(turnIDs: ["T5"]), id: "E3")
    #expect(journal.view.appliedEditIDs == ["E1", "E3"])
}

@Test func staleMergeAfterReassignIsRefused() throws {
    let older = project()
    var journal = Journal()
    // Window A moves S3's T3 to S2; window B, still showing T3 as S3, merges S3 into S1.
    journal.append(.reassignTurns(turnIDs: ["T3"], to: "system:S2"), id: "E1")
    journal.append(.merge(from: "system:S3", into: "system:S1"), id: "E2", madeOn: older)
    let projection = journal.view
    #expect(projection.staleEdits == [StaleEdit(editID: "E2", reason: "changed since the edit was made")])
    #expect(speaker(projection, "system:S3") != nil)
    #expect(turn(projection, "T6")?.speakerID == "system:S3")
    #expect(turn(projection, "T3")?.speakerID == "system:S2")
}

@Test func staleMergeAfterChangeToEitherSpeakerIsRefused() throws {
    let split = { (turnID: String) -> [SpeakerEditAction] in
        // The speaker keeps the same turn IDs, but one of them now covers fewer words.
        [.splitTurn(turnID: turnID, at: WordRef(segmentID: "seg-\(turnID)", word: 3)),
         .reassignTurns(turnIDs: ["\(turnID)/C0"], to: "system:S2")]
    }
    // Window B, still showing the run as made, merges S3 into S1 after window A changed one of them.
    let concurrent: [(String, [SpeakerEditAction])] = [
        ("rename from", [.rename(speakerID: "system:S3", name: "Ann")]),
        ("link from", [.linkProfile(speakerID: "system:S3", profileID: "P-JIM")]),
        ("reject from", [.rejectProfile(speakerID: "system:S3", profileID: "P-JIM")]),
        ("exclude from's turn", [.excludeFromEnrollment(turnIDs: ["T3"])]),
        ("shrink from's turn", split("T3")),
        ("rename into", [.rename(speakerID: "system:S1", name: "Jim")]),
        ("link into", [.linkProfile(speakerID: "system:S1", profileID: "P-JIM")]),
        ("reject into", [.rejectProfile(speakerID: "system:S1", profileID: "P-BOB")]),
        ("exclude into's turn", [.excludeFromEnrollment(turnIDs: ["T1"])]),
        ("shrink into's turn", split("T1")),
    ]
    let merge = SpeakerEditAction.merge(from: "system:S3", into: "system:S1")
    for (label, actions) in concurrent {
        let older = project()
        var journal = Journal()
        for (index, action) in actions.enumerated() { journal.append(action, id: "C\(index)") }
        let changed = journal.view
        journal.append(merge, id: "M", madeOn: older)
        let projection = journal.view
        #expect(projection.staleEdits == [StaleEdit(editID: "M", reason: "changed since the edit was made")], "\(label)")
        #expect(projection.appliedEditIDs == actions.indices.map { "C\($0)" }, "\(label)")
        #expect(projection.speakers == changed.speakers && projection.turns == changed.turns, "\(label)")
        // Made on the current view, the same merge applies.
        journal.append(merge, id: "M2")
        #expect(journal.view.appliedEditIDs.last == "M2", "\(label)")
        #expect(speaker(journal.view, "system:S3") == nil, "\(label)")
    }
    // A change to a third speaker leaves the merge valid.
    let older = project()
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S2", name: "Bob"), id: "C0")
    journal.append(merge, id: "M", madeOn: older)
    #expect(journal.view.appliedEditIDs == ["C0", "M"])
}

@Test func staleLinkAfterRejectionIsRefused() throws {
    var journal = Journal(names: people)
    let older = journal.view
    // Window A says S1 is "Not Jim"; window B, still showing no rejection, links S1 to Jim.
    journal.append(.rejectProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E1")
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E2", madeOn: older)
    let projection = journal.view
    #expect(projection.staleEdits == [StaleEdit(editID: "E2", reason: "changed since the edit was made")])
    let s1 = try #require(speaker(projection, "system:S1"))
    #expect(s1.profileID == nil)
    #expect(s1.rejectedProfileIDs == ["P-JIM"])
    // Made on the current view, the link applies and lifts the rejection.
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E3")
    let linked = try #require(speaker(journal.view, "system:S1"))
    #expect(linked.profileID == "P-JIM" && linked.rejectedProfileIDs.isEmpty)
}

@Test func staleRejectAfterRelinkIsRefused() throws {
    var journal = Journal(names: people)
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E1")
    let older = journal.view
    // Window A relinks S1 to Maria; window B, still showing Jim, says "Not Jim".
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-MARIA"), id: "E2")
    journal.append(.rejectProfile(speakerID: "system:S1", profileID: "P-JIM"), id: "E3", madeOn: older)
    let projection = journal.view
    #expect(projection.staleEdits == [StaleEdit(editID: "E3", reason: "changed since the edit was made")])
    let s1 = try #require(speaker(projection, "system:S1"))
    #expect(s1.profileID == "P-MARIA")
    #expect(s1.rejectedProfileIDs.isEmpty)
}

@Test func staleReassignAndSplitAreRefused() {
    let older = project()
    var journal = Journal()
    journal.append(.reassignTurns(turnIDs: ["T4"], to: "system:S2"), id: "E1")
    journal.append(.reassignTurns(turnIDs: ["T4"], to: "system:S3"), id: "E2", madeOn: older)
    journal.append(.splitTurn(turnID: "T4", at: WordRef(segmentID: "seg-T4", word: 2)), id: "E3", madeOn: older)
    journal.append(.newSpeaker(speakerID: "user:X", name: "X", turnIDs: ["T4"]), id: "E4", madeOn: older)
    #expect(journal.view.staleEdits.map(\.editID) == ["E2", "E3", "E4"])
    #expect(journal.view.staleEdits.allSatisfy { $0.reason == "changed since the edit was made" })
}

@Test func staleReassignAfterSplitIsRefused() throws {
    let older = project()
    var journal = Journal()
    // Window A splits T2; window B, still showing the whole T2, moves it to S1.
    journal.append(.splitTurn(turnID: "T2", at: WordRef(segmentID: "seg-T2", word: 3)), id: "E1")
    journal.append(.reassignTurns(turnIDs: ["T2"], to: "system:S1"), id: "E2", madeOn: older)
    let projection = journal.view
    #expect(projection.appliedEditIDs == ["E1"])
    #expect(projection.staleEdits == [StaleEdit(editID: "E2", reason: "changed since the edit was made")])
    #expect(turn(projection, "T2")?.speakerID == "system:S2")
    #expect(turn(projection, "T2/E1")?.speakerID == "system:S2")
    // Made on the current view, the same reassign applies to the part it names.
    journal.append(.reassignTurns(turnIDs: ["T2"], to: "system:S1"), id: "E3")
    #expect(journal.view.appliedEditIDs == ["E1", "E3"])
    #expect(turn(journal.view, "T2")?.speakerID == "system:S1")
}

@Test func invalidActionsAreStaleAndChangeNothing() {
    let base = project()
    let cases: [(SpeakerEditAction, String)] = [
        (.rename(speakerID: "system:S9", name: "X"), "speaker not found"),
        (.merge(from: "system:S1", into: "system:S9"), "speaker not found"),
        (.merge(from: "system:S1", into: "system:S1"), "cannot merge a speaker into itself"),
        (.reassignTurns(turnIDs: ["T1"], to: "system:S9"), "speaker not found"),
        (.reassignTurns(turnIDs: ["T1", "T99"], to: "system:S2"), "turn not found"),
        (.splitTurn(turnID: "T99", at: WordRef(segmentID: "seg-T5", word: 3)), "turn not found"),
        (.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 0)), "cannot split at the first word of a turn"),
        (.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 6)), "word not in turn"),
        (.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T4", word: 3)), "word not in turn"),
        (.newSpeaker(speakerID: "system:S9", name: "X", turnIDs: ["T1"]), "new speaker IDs start with user:"),
        (.newSpeaker(speakerID: "user:", name: "X", turnIDs: ["T1"]), "new speaker IDs start with user:"),
        (.newSpeaker(speakerID: "user:X", name: "X", turnIDs: ["T99"]), "turn not found"),
        (.excludeFromEnrollment(turnIDs: ["T99"]), "turn not found"),
        (.revert(editID: "E-MISSING"), "edit not found"),
    ]
    for (action, reason) in cases {
        let result = base.applying(action, editID: "E1")
        #expect(result.staleEdits == [StaleEdit(editID: "E1", reason: reason)], "\(action)")
        #expect(result.speakers == base.speakers, "\(action)")
        #expect(result.turns == base.turns, "\(action)")
        #expect(result.editCount == 1)
    }
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:X", name: "X", turnIDs: []), id: "E1")
    journal.append(.newSpeaker(speakerID: "user:X", name: "Y", turnIDs: ["T1"]), id: "E2")
    #expect(journal.view.staleEdits == [StaleEdit(editID: "E2", reason: "speaker already exists")])
    // A split whose words are not in the transcript (a mismatched transcript) is refused, not trapped on.
    let mismatched = SpeakerProjection.make(
        run: fixtureRun, transcript: Transcript(id: "OTHER", source: "system", locale: "en-US", backend: .speech),
        edits: [], recognition: nil, profileNames: [:])
    #expect(mismatched.applying(.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 3)), editID: "E1")
        .staleEdits == [StaleEdit(editID: "E1", reason: "turn words not in the transcript")])
}

// MARK: - applying

/// Deterministic pseudo-random numbers in [0, 1) (64-bit LCG), so the property test is reproducible.
private struct SeededNumbers {
    var state: UInt64

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[min(Int(next() * Double(items.count)), items.count - 1)]
    }
}

/// Mostly valid actions on `view`'s current speakers and turns, with some invalid ones and reverts.
private func randomAction(on view: SpeakerProjection, step: Int, editIDs: [String], random: inout SeededNumbers,
                          names: [String?] = ["Jim", " Maria ", "", nil],
                          profiles: [String] = ["P-JIM", "P-MARIA"]) -> SpeakerEditAction {
    let speakers = view.speakers.map(\.id) + ["system:S9"]
    let turns = view.turns.map(\.id) + ["T99"]
    switch Int(random.next() * 9) {
    case 0:
        return .rename(speakerID: random.pick(speakers), name: random.pick(names))
    case 1:
        return .linkProfile(speakerID: random.pick(speakers), profileID: random.pick(profiles))
    case 2:
        return .rejectProfile(speakerID: random.pick(speakers), profileID: random.pick(profiles))
    case 3:
        return .merge(from: random.pick(speakers), into: random.pick(speakers))
    case 4:
        let to: String? = random.next() < 0.2 ? nil : random.pick(speakers)
        return .reassignTurns(turnIDs: [random.pick(turns), random.pick(turns)], to: to)
    case 5:
        let turn = random.pick(view.turns)
        let words = turn.spans.flatMap { span in (span.first..<span.end).map { WordRef(segmentID: span.segmentID, word: $0) } }
        return .splitTurn(turnID: turn.id, at: random.pick(words))
    case 6:
        return .newSpeaker(speakerID: random.pick(["user:U\(step)", "user:U0", "system:S1"]),
                           name: random.pick(names), turnIDs: [random.pick(turns)])
    case 7:
        return .excludeFromEnrollment(turnIDs: [random.pick(turns)])
    default:
        return .revert(editID: random.pick(editIDs + ["E-MISSING"]))
    }
}

@Test func applyingMatchesMake() {
    let rec = recognition([likelyJim, possibleMaria],
                          merges: [MergeSuggestion(speakerIDs: ["system:S1", "system:S3"], profileID: "P-JIM")])
    let earlier = [edit(.rename(speakerID: "system:S1", name: "Old"), id: "E-OLD", expected: "", run: "RUN-OLD")]
    var applied = 0, stale = 0, reverted = 0, splits = 0, merges = 0, created = 0
    for seed in UInt64(1)...40 {
        var random = SeededNumbers(state: seed)
        var edits = earlier
        var chained = project(edits, recognition: rec, names: people)
        for step in 0..<10 {
            let action = randomAction(on: chained, step: step, editIDs: edits.map(\.id), random: &random)
            let id = "E\(step)"
            edits.append(edit(action, id: id, expected: chained.fingerprint(for: action)))
            chained = chained.applying(action, editID: id)
        }
        let made = project(edits, recognition: rec, names: people)
        #expect(chained.speakers == made.speakers, "seed \(seed)")
        #expect(chained.turns == made.turns, "seed \(seed)")
        #expect(chained.staleEdits == made.staleEdits, "seed \(seed)")
        #expect(chained.appliedEditIDs == made.appliedEditIDs, "seed \(seed)")
        #expect(chained == made, "seed \(seed)")
        #expect(made.editCount == 10)
        #expect(made.otherRunEditCount == 1)

        applied += made.appliedEditIDs.count
        stale += made.staleEdits.count
        reverted += made.revertedEditIDs.count
        splits += made.turns.filter { $0.id.contains("/") }.count
        merges += made.speakers.filter { $0.clusterIDs.count > 1 }.count
        created += made.speakers.filter { $0.id.hasPrefix("user:") }.count
    }
    // The generator reaches every outcome, so the equalities above cover both the replay and incremental paths.
    #expect(applied > 100 && stale > 20 && reverted > 5 && splits > 5 && merges > 5 && created > 5,
            "applied \(applied), stale \(stale), reverted \(reverted), splits \(splits), merges \(merges), new \(created)")
}

// MARK: - Fingerprint injectivity

/// The state an action reads, built from the projection's state as plain Swift values (never from the fingerprint
/// encoding), so two states give equal facts exactly when the action sees the same thing. Text compares by Unicode
/// scalars, as the length prefixes do.
private indirect enum Fact: Hashable {
    case absent
    case nothing
    case number(Int)
    case text([Unicode.Scalar])
    case list([Fact])
    case bag([Fact: Int])
}

private func textFact(_ value: String?) -> Fact {
    value.map { .text(Array($0.unicodeScalars)) } ?? .nothing
}

private func spansFact(_ spans: [WordSpan]) -> Fact {
    .list(spans.map { .list([textFact($0.segmentID), .number($0.first), .number($0.end)]) })
}

private func speakerFact(_ state: SpeakerProjection.State, _ id: String,
                         _ fields: (SpeakerProjection.SpeakerState) -> [Fact] = { _ in [] }) -> Fact {
    guard let speaker = state.speakers[id] else { return .absent }
    return .list([.number(speaker.ordinal)] + fields(speaker))
}

private func turnFact(_ state: SpeakerProjection.State, _ id: String, exclusion: Bool) -> Fact {
    guard let index = state.turnIndex[id] else { return .absent }
    let turn = state.turns[index]
    var facts = [textFact(turn.speakerID), spansFact(turn.spans)]
    if exclusion { facts.append(.number(turn.excluded ? 1 : 0)) }
    return .list(facts)
}

/// What each action reads or discards, per the fingerprint table: whether each named speaker and turn exists (and a
/// speaker's ordinal), plus the fields listed there.
private func relevantState(for action: SpeakerEditAction, in state: SpeakerProjection.State) -> Fact {
    switch action {
    case .rename(let speakerID, _):
        return speakerFact(state, speakerID) { [textFact($0.explicitName)] }
    case .linkProfile(let speakerID, let profileID), .rejectProfile(let speakerID, let profileID):
        return speakerFact(state, speakerID) {
            [textFact($0.profileID), .number($0.rejectedProfileIDs.contains(profileID) ? 1 : 0)]
        }
    case .reassignTurns(let turnIDs, let to):
        return .list([to.map { speakerFact(state, $0) } ?? .nothing,
                      .list(turnIDs.map { turnFact(state, $0, exclusion: false) })])
    case .merge(let from, let into):
        let full = { (speakerID: String) -> Fact in
            speakerFact(state, speakerID) { speaker in
                var owned: [Fact: Int] = [:]
                for turn in state.turns where turn.speakerID == speaker.id {
                    let fact = Fact.list([textFact(turn.id), spansFact(turn.spans), .number(turn.excluded ? 1 : 0)])
                    owned[fact, default: 0] += 1
                }
                return [textFact(speaker.explicitName), textFact(speaker.profileID),
                        .list(speaker.rejectedProfileIDs.map { textFact($0) }),
                        .list(speaker.clusterIDs.map { textFact($0) }), .bag(owned)]
            }
        }
        return .list([full(from), full(into)])
    case .splitTurn(let turnID, _):
        return turnFact(state, turnID, exclusion: false)
    case .newSpeaker(let speakerID, _, let turnIDs):
        return .list([speakerFact(state, speakerID), .list(turnIDs.map { turnFact(state, $0, exclusion: false) })])
    case .excludeFromEnrollment(let turnIDs):
        return .list(turnIDs.map { turnFact(state, $0, exclusion: true) })
    case .revert:
        return .nothing
    }
}

private func mentionsAbsent(_ fact: Fact) -> Bool {
    switch fact {
    case .absent: return true
    case .list(let facts): return facts.contains(where: mentionsAbsent)
    case .bag(let facts): return facts.keys.contains(where: mentionsAbsent)
    case .nothing, .number, .text: return false
    }
}

private func actionName(_ action: SpeakerEditAction) -> String {
    switch action {
    case .rename: return "rename"
    case .linkProfile: return "linkProfile"
    case .rejectProfile: return "rejectProfile"
    case .reassignTurns: return "reassignTurns"
    case .merge: return "merge"
    case .splitTurn: return "splitTurn"
    case .newSpeaker: return "newSpeaker"
    case .excludeFromEnrollment: return "excludeFromEnrollment"
    case .revert: return "revert"
    }
}

@Test func fingerprintsAreInjectiveOverTheStateEachActionReads() throws {
    // Names and profile IDs that look like the encoding: separators, length prefixes, hex digests, a hashed
    // fingerprint, long names (hashed), and two spellings of é with different scalar counts.
    let longName = String(repeating: "Jimmy ", count: 50) + "Jones"
    let longTwin = String(repeating: "Jimmy ", count: 50) + "Jonas"
    let hexName = String(repeating: "0123456789abcdef", count: 4)
    var longJournal = Journal()
    longJournal.append(.rename(speakerID: "system:S1", name: longName), id: "E1")
    let hashed = try #require(longJournal.view.fingerprint(for: .rename(speakerID: "system:S1", name: nil)))
    let names: [String?] = [
        "Jim", " Maria ", "", nil, longName, longTwin, hexName, String(hexName.prefix(32)), "fp1:sha256:" + hexName,
        hashed, "3:Jim", "Jim;link=none", "none", "=absent", "a,b]", "x=present;ordinal=1;name=none", "\u{E9}",
        "e\u{301}",
    ]
    let profiles = ["P-JIM", "P-MARIA", "P;rejected=1", "5:P-JIM", ""]

    // Every prefix of random journals over the fixture: merged-away and re-created speakers, links, rejections,
    // splits (and reverted splits), reassigns, and exclusions.
    var states = [project(), longJournal.view]
    for seed in UInt64(1)...24 {
        var random = SeededNumbers(state: seed &* 7_919)
        var edits: [SpeakerEdit] = []
        var chained = project()
        for step in 0..<12 {
            let action = randomAction(on: chained, step: step, editIDs: edits.map(\.id), random: &random,
                                      names: names, profiles: profiles)
            let id = "E\(step)"
            edits.append(edit(action, id: id, expected: chained.fingerprint(for: action)))
            chained = chained.applying(action, editID: id)
            states.append(chained)
        }
    }

    // Probes over every speaker and turn ID seen in any state (so each is present in some states and absent in
    // others), plus IDs that never exist.
    let speakerIDs = Set(states.flatMap { $0.state.speakers.keys }).union(["system:S9"]).sorted()
    let turnIDs = Set(states.flatMap { $0.state.turns.map(\.id) }).union(["T99"]).sorted()
    let mergeIDs = ["system:S1", "system:S2", "system:S3", "mic:me", "user:U0", "user:U3", "system:S9"]
    var probes: [SpeakerEditAction] = []
    for speakerID in speakerIDs {
        probes.append(.rename(speakerID: speakerID, name: nil))
        for profileID in profiles {
            probes.append(.linkProfile(speakerID: speakerID, profileID: profileID))
            probes.append(.rejectProfile(speakerID: speakerID, profileID: profileID))
        }
    }
    for from in mergeIDs {
        for into in mergeIDs { probes.append(.merge(from: from, into: into)) }
    }
    for ids in turnIDs.map({ [$0] }) + [["T1", "T5"], ["T5", "T99"], ["T2", "T2"]] {
        for to in [nil, "system:S1", "user:U0", "system:S9"] as [String?] {
            probes.append(.reassignTurns(turnIDs: ids, to: to))
        }
        probes.append(.newSpeaker(speakerID: "user:U0", name: nil, turnIDs: ids))
        probes.append(.newSpeaker(speakerID: "user:U3", name: nil, turnIDs: ids))
        probes.append(.excludeFromEnrollment(turnIDs: ids))
    }
    for turnID in turnIDs {
        probes.append(.splitTurn(turnID: turnID, at: WordRef(segmentID: "seg-T1", word: 1)))
    }

    // For each probe: equal facts give equal fingerprints and different facts give different fingerprints.
    var failures: [String] = []
    var variedProbes: [String: Int] = [:]      // probes that saw at least three different states
    var absentAndPresent = Set<String>()
    var hashedCount = 0
    for probe in probes {
        let name = actionName(probe)
        var factByFingerprint: [String: Fact] = [:]
        var fingerprintByFact: [Fact: String] = [:]
        for projection in states {
            guard let fingerprint = projection.fingerprint(for: probe) else {
                failures.append("no fingerprint: \(probe)")
                continue
            }
            if fingerprint.hasPrefix("fp1:sha256:") {
                hashedCount += 1
            } else if !fingerprint.hasPrefix("fp1:\(name):") {
                failures.append("untagged: \(probe)")
            }
            let fact = relevantState(for: probe, in: projection.state)
            if let seen = factByFingerprint[fingerprint], seen != fact {
                failures.append("different states, same fingerprint: \(probe)")
            }
            if let seen = fingerprintByFact[fact], seen != fingerprint {
                failures.append("same state, different fingerprints: \(probe)")
            }
            if factByFingerprint[fingerprint] == nil { factByFingerprint[fingerprint] = fact }
            if fingerprintByFact[fact] == nil { fingerprintByFact[fact] = fingerprint }
        }
        if fingerprintByFact.count >= 3 { variedProbes[name, default: 0] += 1 }
        let absent = fingerprintByFact.keys.filter(mentionsAbsent).count
        if absent > 0 && absent < fingerprintByFact.count { absentAndPresent.insert(name) }
    }
    let failureCount = failures.count
    let firstFailures = Array(Set(failures)).sorted().prefix(5)
    #expect(failureCount == 0, "\(failureCount) failures, first: \(firstFailures)")

    // The generator reaches enough variety for the check above to mean something.
    for name in ["rename", "linkProfile", "rejectProfile", "reassignTurns", "merge", "splitTurn", "newSpeaker",
                 "excludeFromEnrollment"] {
        #expect(variedProbes[name, default: 0] >= 3, "\(name): \(variedProbes[name, default: 0]) probes varied")
    }
    // Each action saw a named speaker or turn both missing and present.
    #expect(absentAndPresent.count == 8, "\(absentAndPresent.sorted())")
    #expect(hashedCount > 100, "hashed \(hashedCount)")
}

@Test func applyingARevertUndoesTheEdit() throws {
    let base = project()
    let renamed = base.applying(.rename(speakerID: "system:S1", name: "Jim"), editID: "E1")
    #expect(speaker(renamed, "system:S1")?.name == "Jim")
    #expect(renamed.lastUndoableBatchID == "E1")
    let undone = renamed.applying(.revert(editID: "E1"), editID: "E2")
    #expect(speaker(undone, "system:S1")?.name == "Speaker 1")
    #expect(undone.revertedEditIDs == ["E1"])
    #expect(undone.lastUndoableBatchID == nil)
    #expect(undone.speakers == base.speakers)
}

@Test func applyingARepeatedEditIDMatchesMake() throws {
    // The same ID twice: both lines apply, in order.
    var twice = Journal()
    var chained = project()
    for (action, id) in [(SpeakerEditAction.rename(speakerID: "system:S1", name: "Jim"), "E1"),
                         (.rename(speakerID: "system:S1", name: "Bob"), "E1")] {
        twice.append(action, id: id)
        chained = chained.applying(action, editID: id)
    }
    #expect(chained == twice.view)
    #expect(chained.appliedEditIDs == ["E1", "E1"])
    #expect(speaker(chained, "system:S1")?.name == "Bob")

    // A reused ID whose first line was reverted: the revert names the ID, so the new line is reverted too.
    var reverted = Journal()
    chained = project()
    for (action, id) in [(SpeakerEditAction.rename(speakerID: "system:S1", name: "Jim"), "E1"),
                         (.revert(editID: "E1"), "E2"),
                         (.rename(speakerID: "system:S1", name: "Bob"), "E1")] {
        reverted.append(action, id: id)
        chained = chained.applying(action, editID: id)
    }
    #expect(chained == reverted.view)
    #expect(chained.revertedEditIDs == ["E1", "E1"])
    #expect(chained.appliedEditIDs.isEmpty)
    #expect(speaker(chained, "system:S1")?.name == "Speaker 1")
}

@Test func printingAProjectionShowsNoTranscriptText() {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "Jim"), id: "E1")
    let projection = journal.view
    var dumped = ""
    dump(projection, to: &dumped)
    for text in [String(describing: projection), String(reflecting: projection), dumped] {
        #expect(!text.contains("w0 w1"))
        #expect(!text.contains("w3"))
    }
    #expect(String(describing: projection).contains("speakers: 4"))
    #expect(dumped.contains("Jim"))
}

@Test func extremeOrdinalsDoNotTrap() throws {
    var run = fixtureRun
    run.speakers.removeAll { $0.id == "mic:me" }       // T8's speaker is not listed
    run.speakers[2].ordinal = Int.max
    let base = SpeakerProjection.make(run: run, transcript: fixtureTranscript, edits: [], recognition: nil,
                                      profileNames: [:])
    #expect(speaker(base, "mic:me")?.ordinal == Int.max)
    let created = base.applying(.newSpeaker(speakerID: "user:X", name: "Guest", turnIDs: ["T1"]), editID: "E1")
    #expect(created.appliedEditIDs == ["E1"])
    #expect(speaker(created, "user:X")?.ordinal == Int.max)
    #expect(created.speakers.map(\.id) == ["system:S1", "system:S2", "mic:me", "system:S3", "user:X"])
}

@Test func projectionOrdersTurnsByStartTrackAndNumericID() {
    let turns = [("T10", "system", 5.0), ("T9", "system", 5.0), ("T2", "mic", 5.0), ("T1", "system", 1.0)]
    let run = DiarizationRun(
        id: runID, sessionID: "SESSION", createdAt: fixedDate, transcriptID: "TRANSCRIPT", engine: nil,
        alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: [],
        speakers: [SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])],
        turns: turns.map { SpeakerTurn(id: $0.0, track: $0.1, start: $0.2, end: $0.2 + 1, speakerID: "system:S1",
                                       clusterID: "system:S1", spans: [], assignmentScore: 1, timing: .measured) })
    let projection = SpeakerProjection.make(run: run, transcript: fixtureTranscript, edits: [], recognition: nil,
                                            profileNames: [:])
    #expect(projection.turns.map(\.id) == ["T1", "T2", "T9", "T10"])
}

@Test func turnSpeakerMissingFromTheRunIsStillListed() throws {
    var run = fixtureRun
    run.speakers.removeAll { $0.id == "system:S3" }
    let projection = SpeakerProjection.make(run: run, transcript: fixtureTranscript, edits: [], recognition: nil,
                                            profileNames: [:])
    let s3 = try #require(speaker(projection, "system:S3"))
    #expect(s3.ordinal == 5)
    #expect(s3.clusterIDs == ["system:S3"])
    #expect(s3.turnCount == 2)
    #expect(projection.turns.allSatisfy { !$0.reassigned })
}
