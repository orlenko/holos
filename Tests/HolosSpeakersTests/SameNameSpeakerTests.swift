import Foundation
import Testing
import HolosCore
import HolosTestSupport
@testable import HolosSpeakers

// Same name, same person (docs/meeting-design.md §4.9, "Speakers with the same name"). Names are made up.

// MARK: - Fixture

private let runID = "RUN-NAMES"
private let fixedDate = Date(timeIntervalSince1970: 1_000_000)

/// A turn of `words` measured words of one second each, in its own segment "seg-<id>".
private struct TurnSpec {
    var id: String
    var start: Double
    var speaker: String?
    var words: Int
    var track = "system"
}

/// System: T1 S1 (4 s), T2 S2 (3 s), T3 S3 (2 s), T4 S1 (4 s), T5 unknown (5 s); microphone: T6 mic:me (2 s).
private let specs = [
    TurnSpec(id: "T1", start: 0, speaker: "system:S1", words: 4),
    TurnSpec(id: "T2", start: 10, speaker: "system:S2", words: 3),
    TurnSpec(id: "T3", start: 20, speaker: "system:S3", words: 2),
    TurnSpec(id: "T4", start: 30, speaker: "system:S1", words: 4),
    TurnSpec(id: "T5", start: 40, speaker: nil, words: 5),
    TurnSpec(id: "T6", start: 50, speaker: "mic:me", words: 2, track: "mic"),
]

/// Words "w0", "w1", … of one second each from the turn's start.
private func segment(_ spec: TurnSpec) -> TranscriptSegment {
    TranscriptFixtures.segment(TranscriptFixtures.numberedWords("", count: spec.words), id: "seg-\(spec.id)",
                               track: spec.track, start: spec.start, every: 1, lasting: 1)
}

private let transcript = Transcript(id: "TRANSCRIPT", createdAt: fixedDate, source: "mic+system", locale: "en-US",
                                    backend: .speech, segments: specs.map(segment))

private let run = DiarizationRun(
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
    turns: specs.map { spec in
        let channel = spec.track == "mic"
        return SpeakerTurn(id: spec.id, track: spec.track, start: spec.start, end: spec.start + Double(spec.words),
                           speakerID: spec.speaker, clusterID: channel ? nil : spec.speaker,
                           spans: [WordSpan(segmentID: "seg-\(spec.id)", first: 0, end: spec.words)],
                           assignmentScore: spec.speaker == nil ? 0 : 0.9, timing: .measured)
    })

/// Appends edits as `SpeakerEditor` does, each with the fingerprint of the view it was made on.
private struct Journal {
    var edits: [SpeakerEdit] = []
    var names: [String: String] = [:]
    var recognition: RecognitionResult?

    var view: SpeakerProjection {
        SpeakerProjection.make(run: run, transcript: transcript, edits: edits, recognition: recognition,
                               profileNames: names)
    }

    mutating func append(_ action: SpeakerEditAction, batch: String? = nil) {
        edits.append(SpeakerEdit(id: "E\(edits.count + 1)", baseRunID: runID, at: fixedDate, source: "cli",
                                 action: action, expected: view.fingerprint(for: action), batchID: batch))
    }

    /// A batch as `SpeakerEditor` saves it: `view.fanningOut(actions)`, one batch ID.
    @discardableResult
    mutating func save(_ actions: [SpeakerEditAction]) -> [SpeakerEditAction] {
        let saved = view.fanningOut(actions)
        let batch = "B\(edits.count + 1)"
        for action in saved { append(action, batch: batch) }
        return saved
    }
}

private func speaker(_ projection: SpeakerProjection, _ id: String) -> ProjectedSpeaker? {
    projection.speakers.first { $0.id == id }
}

private func turnSpeaker(_ projection: SpeakerProjection, _ id: String) -> String? {
    projection.turns.first { $0.id == id }?.speakerID
}

// MARK: - Comparing names

@Test func namesCompareIgnoringCaseAccentsWidthAndSpaces() {
    #expect(SameNameSpeakers.key("  Zoë   Smith ") == SameNameSpeakers.key("zoe smith"))
    #expect(SameNameSpeakers.key("ALICE") == SameNameSpeakers.key("alice"))
    #expect(SameNameSpeakers.key("Ａｌｉｃｅ") == SameNameSpeakers.key("Alice"))
    #expect(SameNameSpeakers.key("Bob\nJones") == SameNameSpeakers.key("Bob Jones"))
    #expect(SameNameSpeakers.key("Alice") != SameNameSpeakers.key("Alicia"))
    #expect(SameNameSpeakers.key("Bob Jones") != SameNameSpeakers.key("BobJones"))
    #expect(SameNameSpeakers.key(" \t ") == nil)
}

// MARK: - Read side: the projection lists one person

@Test func aNewSpeakerAndARenamedClusterOfOneNameAreListedAsOne() throws {
    // The journal of a meeting saved before the rule: "Alice" picked for the unknown turn, then the cluster renamed.
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:A", name: "Alice", turnIDs: ["T5"]))
    journal.append(.rename(speakerID: "system:S1", name: "alice"))
    let view = journal.view
    #expect(view.speakers.map(\.id) == ["system:S1", "system:S2", "system:S3", "mic:me"])
    let alice = try #require(speaker(view, "system:S1"))
    // S1 talks longer (8 s against 5 s), so it stays: its ID, ordinal and spelling.
    #expect(alice.name == "alice")
    #expect(alice.memberIDs == ["system:S1", "user:A"])
    #expect(alice.talkSeconds == 13)
    #expect(alice.turnCount == 3)
    #expect(alice.ordinal == 1)
    #expect(turnSpeaker(view, "T5") == "system:S1")
    #expect(view.shownTurns.first { $0.id == "T5" }?.speakerID == "system:S1")
    // Edits still see both stored speakers.
    #expect(view.fingerprint(for: .rename(speakerID: "user:A", name: nil))?.contains("present") == true)
}

@Test func theLowestOrdinalStaysAndTakesTheGroupsLink() throws {
    // S3 (the person's link) and S1 (the lowest ordinal) are both Alice: S1 is shown, linked to the person.
    var journal = Journal(names: ["P-ALICE": "Alice"])
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALICE"))
    journal.append(.rename(speakerID: "system:S3", name: "Alice"))
    journal.append(.rename(speakerID: "system:S1", name: "ALICE"))
    let alice = try #require(speaker(journal.view, "system:S1"))
    #expect(alice.name == "ALICE")
    #expect(alice.profileID == "P-ALICE")
    #expect(alice.memberIDs == ["system:S1", "system:S3"])
    #expect(alice.clusterIDs == ["system:S1", "system:S3"])
    #expect(alice.talkSeconds == 10)
    #expect(speaker(journal.view, "system:S3") == nil)
    #expect(turnSpeaker(journal.view, "T3") == "system:S1")
}

@Test func eachStoredSpeakerStaysReadableForVoiceData() {
    var journal = Journal(names: ["P-ALICE": "Alice"])
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALICE"))
    journal.append(.rename(speakerID: "system:S3", name: "Alice"))
    journal.append(.rename(speakerID: "system:S1", name: "ALICE"))
    let stored = journal.view.unjoined
    #expect(!stored.joinsSameNames)
    #expect(stored.speakers.map(\.id) == ["system:S1", "system:S2", "system:S3", "mic:me"])
    #expect(stored.speakers.first { $0.id == "system:S3" }?.profileID == "P-ALICE")
    #expect(stored.speakers.first { $0.id == "system:S1" }?.profileID == nil)
    #expect(stored.turns.first { $0.id == "T3" }?.speakerID == "system:S3")
    #expect(stored.unjoined == stored)
}

@Test func whoIsShownNeverDependsOnTalkTime() {
    // S3 (2 s, ordinal 3) and a new speaker (5 s, ordinal 5) are both Bob: S3 is shown, whoever talks longer.
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:B", name: "Bob", turnIDs: ["T5"]))
    journal.append(.rename(speakerID: "system:S3", name: "Bob"))
    #expect(journal.view.speakers.first { $0.name == "Bob" }?.id == "system:S3")
    #expect(journal.view.speakers.first { $0.name == "Bob" }?.memberIDs == ["system:S3", "user:B"])
}

@Test func whoIsShownIsTheSameWithAndWithoutTheEchoMask() throws {
    // A reader without the echo mask (the post-processor's) and one with it (Review) must show the same speaker:
    // S1 (4 s) and the microphone's speaker (6 s, 4 of them echo) are both called Me.
    let system = TurnSpec(id: "A1", start: 0, speaker: "system:S1", words: 4)
    let microphone = TurnSpec(id: "M1", start: 10, speaker: "mic:me", words: 6, track: "mic")
    let callTranscript = Transcript(id: "CALL", createdAt: fixedDate, source: "mic+system", locale: "en-US",
                                    backend: .speech, segments: [segment(system), segment(microphone)])
    let callRun = DiarizationRun(
        id: "RUN-CALL", sessionID: "SESSION", createdAt: fixedDate, transcriptID: "CALL", engine: nil,
        alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized),
                 TrackDiarization(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me"))],
        speakers: [SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"]),
                   SessionSpeaker(id: "mic:me", ordinal: 2, displayName: "Me", provenance: .channelAssumption)],
        turns: [system, microphone].map { spec in
            SpeakerTurn(id: spec.id, track: spec.track, start: spec.start, end: spec.start + Double(spec.words),
                        speakerID: spec.speaker, clusterID: spec.track == "mic" ? nil : spec.speaker,
                        spans: [WordSpan(segmentID: "seg-\(spec.id)", first: 0, end: spec.words)],
                        assignmentScore: 0.9, timing: .measured)
        })
    let edits = [SpeakerEdit(id: "E1", baseRunID: "RUN-CALL", at: fixedDate, source: "cli",
                             action: .rename(speakerID: "system:S1", name: "me"))]
    // Echo over the microphone's first four words (10–14 s), the microphone's own voice elsewhere.
    let frames = Int(17 / AcousticEchoMask.hopSeconds)
    let classes: [AcousticEchoMask.FrameClass] = (0..<frames).map { frame in
        let centre = AcousticEchoMask.firstCentreSeconds + Double(frame) * AcousticEchoMask.hopSeconds
        return centre >= 10 && centre < 14 ? .echo : .local
    }
    let mask = try #require(AcousticEchoMask(classes: classes.map(\.rawValue),
                                             echoLevels: [Int8](repeating: -40, count: frames)))
    let plain = SpeakerProjection.make(run: callRun, transcript: callTranscript, edits: edits, recognition: nil,
                                       profileNames: [:])
    let masked = SpeakerProjection.make(run: callRun, transcript: callTranscript, edits: edits, recognition: nil,
                                        profileNames: [:], acousticEcho: mask)
    // The mask does hide the microphone's echo, so the talk times compare the other way round with it.
    let micPlain = try #require(plain.turns.first { $0.id == "M1" }.map { $0.end - $0.start })
    let micMasked = try #require(masked.turns.first { $0.id == "M1" }.map { $0.end - $0.start })
    #expect(micPlain > 4 && micMasked < 4)
    #expect(plain.speakers.map(\.id) == ["system:S1"])
    #expect(masked.speakers.map(\.id) == ["system:S1"])
    #expect(plain.speakers.map(\.memberIDs) == masked.speakers.map(\.memberIDs))
}

@Test func aSpeakerWhoseWordsAreAllEchoStaysAmongTheStoredOnes() throws {
    // The microphone's speaker (linked to a person) has every word masked as echo; S1 is also called Me. Shown, the
    // microphone's speaker has no turn; stored, it is still there with its link, for edits and voice data.
    let system = TurnSpec(id: "A1", start: 0, speaker: "system:S1", words: 4)
    let microphone = TurnSpec(id: "M1", start: 10, speaker: "mic:me", words: 6, track: "mic")
    let callTranscript = Transcript(id: "CALL", createdAt: fixedDate, source: "mic+system", locale: "en-US",
                                    backend: .speech, segments: [segment(system), segment(microphone)])
    let callRun = DiarizationRun(
        id: "RUN-CALL", sessionID: "SESSION", createdAt: fixedDate, transcriptID: "CALL", engine: nil,
        alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized),
                 TrackDiarization(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me"))],
        speakers: [SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"]),
                   SessionSpeaker(id: "mic:me", ordinal: 2, displayName: "Me", provenance: .channelAssumption)],
        turns: [system, microphone].map { spec in
            SpeakerTurn(id: spec.id, track: spec.track, start: spec.start, end: spec.start + Double(spec.words),
                        speakerID: spec.speaker, clusterID: spec.track == "mic" ? nil : spec.speaker,
                        spans: [WordSpan(segmentID: "seg-\(spec.id)", first: 0, end: spec.words)],
                        assignmentScore: 0.9, timing: .measured)
        })
    let edits = [SpeakerEdit(id: "E1", baseRunID: "RUN-CALL", at: fixedDate, source: "cli",
                             action: .linkProfile(speakerID: "mic:me", profileID: "P-SAM")),
                 SpeakerEdit(id: "E2", baseRunID: "RUN-CALL", at: fixedDate, source: "cli",
                             action: .rename(speakerID: "system:S1", name: "me"))]
    let frames = Int(17 / AcousticEchoMask.hopSeconds)
    let classes: [AcousticEchoMask.FrameClass] = (0..<frames).map { frame in
        let centre = AcousticEchoMask.firstCentreSeconds + Double(frame) * AcousticEchoMask.hopSeconds
        return centre >= 10 ? .echo : .local
    }
    let mask = try #require(AcousticEchoMask(classes: classes.map(\.rawValue),
                                             echoLevels: [Int8](repeating: -40, count: frames)))
    let masked = SpeakerProjection.make(run: callRun, transcript: callTranscript, edits: edits, recognition: nil,
                                        profileNames: ["P-SAM": "Sam"], acousticEcho: mask)
    #expect(!masked.turns.contains { $0.id == "M1" })
    #expect(masked.speakers.map(\.memberIDs) == [["system:S1", "mic:me"]])
    let stored = masked.unjoined.speakers
    #expect(stored.map(\.id) == ["system:S1", "mic:me"])
    #expect(stored.first { $0.id == "mic:me" }?.profileID == "P-SAM")
    #expect(stored.first { $0.id == "mic:me" }?.turnCount == 0)
}

@Test func aLinkedChannelSpeakerIsStillFoundByItsOwnName() {
    // The microphone's speaker linked to a person and shown under their name is still "Me" for joining and lookups.
    var journal = Journal(names: ["P-SAM": "Sam"])
    journal.append(.linkProfile(speakerID: "mic:me", profileID: "P-SAM"))
    #expect(journal.view.speakers.first { $0.id == "mic:me" }?.name == "Sam")
    #expect(journal.view.speaker(named: " me ")?.id == "mic:me")
}

@Test func differentNamesStaySeparate() {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    journal.append(.rename(speakerID: "system:S2", name: "Alicia"))
    journal.append(.rename(speakerID: "system:S3", name: "Alice Jones"))
    #expect(journal.view.speakers.map(\.name) == ["Alice", "Alicia", "Alice Jones", "Me"])
    #expect(journal.view.speakers.allSatisfy { $0.memberIDs == [$0.id] })
}

@Test func onlyNamesSomeoneStandsByJoin() {
    // "Speaker 2" typed as a name is not the diarizer's Speaker 2, and an automatic match ("Bob (auto)") is a guess
    // that never joins a confirmed Bob.
    let automatic = RecognitionResult(
        runID: runID, createdAt: fixedDate, embeddingModel: EmbeddingModelID(id: "fake", revision: "1"),
        thresholds: RecognitionThresholds(likelyMaxDistance: 0.2, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                          minSampleSeconds: 20),
        matches: [SpeakerMatch(speakerID: "system:S3", profileID: "P-BOB", profileName: "Bob", distance: 0.1,
                               tier: .likely)])
    var journal = Journal(names: ["P-BOB": "Bob"], recognition: automatic)
    journal.append(.rename(speakerID: "system:S1", name: "Speaker 2"))
    journal.append(.newSpeaker(speakerID: "user:B", name: "Bob", turnIDs: ["T5"]))
    let view = journal.view
    #expect(view.speakers.map(\.label) == ["Speaker 2", "Speaker 2", "Bob (auto)", "Me", "Bob"])
    #expect(view.speakers.allSatisfy { $0.memberIDs == [$0.id] })
}

@Test func aNameGivenToTheChannelSpeakerJoinsIt() throws {
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S2", name: "me"))
    let me = try #require(speaker(journal.view, "system:S2"))
    // S2 talks 3 s against the microphone's 2 s.
    #expect(me.memberIDs == ["system:S2", "mic:me"])
    #expect(speaker(journal.view, "mic:me") == nil)
    #expect(turnSpeaker(journal.view, "T6") == "system:S2")
}

@Test func joiningNeverReadsThePeopleStore() {
    // The same journal joins the same speakers whatever people a builder knows.
    var journal = Journal(names: ["P-ALEX": "Alex"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-ALEX"))
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.rename(speakerID: "system:S3", name: "alex"))
    let withPeople = journal.view
    journal.names = [:]
    let withoutPeople = journal.view
    #expect(withPeople.speakers.map(\.memberIDs) == withoutPeople.speakers.map(\.memberIDs))
    #expect(withPeople.speakers.first?.memberIDs == ["system:S1", "system:S3"])
    #expect(withPeople.speakers.first?.profileID == "P-ALEX")
    #expect(withPeople.turns.map(\.speakerID) == withoutPeople.turns.map(\.speakerID))
}

@Test func speakersLinkedToOnePersonUnderDifferentNamesStayTwo() {
    var journal = Journal(names: ["P-BOB": "Bob"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-BOB"))
    journal.append(.rename(speakerID: "system:S1", name: "Bob"))
    journal.append(.linkProfile(speakerID: "system:S2", profileID: "P-BOB"))
    journal.append(.rename(speakerID: "system:S2", name: "Robert"))
    #expect(journal.view.speakers.map(\.name) == ["Bob", "Robert", "Speaker 3", "Me"])
    #expect(journal.view.speakers.allSatisfy { $0.memberIDs == [$0.id] })
}

@Test func speakersOfOneNameLinkedToTwoPeopleAreShownApart() {
    // S1 linked to one Alex, S3 to another, both named Alex: the journal says they are two people, so they are shown
    // apart, each with its own person (and its own voice), and nothing reaches from one to the other.
    var journal = Journal(names: ["P-ALEX1": "Alex", "P-ALEX2": "Alex"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-ALEX1"))
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALEX2"))
    journal.append(.rename(speakerID: "system:S3", name: "Alex"))
    journal.append(.rename(speakerID: "system:S2", name: "alex"))
    let view = journal.view
    #expect(view.speakers.filter { $0.name.lowercased() == "alex" }.map(\.id) == ["system:S1", "system:S2", "system:S3"])
    #expect(view.speakers.allSatisfy { $0.memberIDs == [$0.id] })
    #expect(view.speakers.map(\.profileID) == ["P-ALEX1", nil, "P-ALEX2", nil])
    #expect(view.turns.first { $0.id == "T3" }?.speakerID == "system:S3")
    // "Alex" names none of them in particular.
    #expect(view.speaker(named: "Alex") == nil)
    #expect(view.fanningOut([.rename(speakerID: "system:S1", name: "Alexander")])
        == [.rename(speakerID: "system:S1", name: "Alexander")])
}

// MARK: - Write side: edits of a speaker shown joined reach every stored one

@Test func namingASpeakerAsAnotherIsNamedOnlyRenamesIt() throws {
    var journal = Journal()
    journal.save([.rename(speakerID: "system:S1", name: "Alice")])
    let saved = journal.save([.rename(speakerID: "system:S3", name: "  alice ")])
    #expect(saved == [.rename(speakerID: "system:S3", name: "  alice ")])
    let view = journal.view
    #expect(speaker(view, "system:S1")?.memberIDs == ["system:S1", "system:S3"])
    #expect(view.unjoined.speakers.map(\.id).contains("system:S3"))
    let saved2 = journal.save([.newSpeaker(speakerID: "user:A", name: "ALICE", turnIDs: ["T5"])])
    #expect(saved2 == [.newSpeaker(speakerID: "user:A", name: "ALICE", turnIDs: ["T5"])])
    #expect(speaker(journal.view, "system:S1")?.memberIDs == ["system:S1", "system:S3", "user:A"])
}

@Test func renamingASpeakerShownJoinedRenamesEachStoredOneAndMergesNothing() {
    // S1 (linked to Alex) and S3 (only named Alex) are shown as one: renaming him renames both; each keeps its link.
    var journal = Journal(names: ["P-ALEX": "Alex"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-ALEX"))
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.rename(speakerID: "system:S3", name: "Alex"))
    let saved = journal.save([.rename(speakerID: "system:S1", name: "Alexander")])
    #expect(saved == [.rename(speakerID: "system:S1", name: "Alexander"),
                      .rename(speakerID: "system:S3", name: "Alexander")])
    let view = journal.view
    #expect(view.speakers.filter { $0.name == "Alexander" }.map(\.memberIDs) == [["system:S1", "system:S3"]])
    #expect(view.unjoined.speakers.first { $0.id == "system:S3" }?.profileID == nil)
    #expect(view.staleEdits.isEmpty)
}

@Test func linkingRejectingAndClearingASpeakerShownJoinedReachEachStoredOne() {
    var journal = Journal(names: ["P-ALEX": "Alex"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-ALEX"))
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALEX"))
    journal.append(.rename(speakerID: "system:S3", name: "Alex"))
    // Clearing the name as Review's name field does: the name cleared and the person rejected, for each.
    let saved = journal.save([.rename(speakerID: "system:S1", name: nil),
                              .rejectProfile(speakerID: "system:S1", profileID: "P-ALEX")])
    #expect(saved == [.rename(speakerID: "system:S1", name: nil),
                      .rejectProfile(speakerID: "system:S1", profileID: "P-ALEX"),
                      .rename(speakerID: "system:S3", name: nil),
                      .rejectProfile(speakerID: "system:S3", profileID: "P-ALEX")])
    let view = journal.view
    #expect(view.speakers.map(\.name) == ["Speaker 1", "Speaker 2", "Speaker 3", "Me"])
    #expect(view.speakers.allSatisfy { $0.profileID == nil })
}

@Test func mergingASpeakerShownJoinedIntoAnotherMovesEachStoredOne() {
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:A", name: "Alice", turnIDs: ["T5"]))
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    let saved = journal.save([.merge(from: "system:S1", into: "system:S2")])
    #expect(saved == [.merge(from: "system:S1", into: "system:S2"), .merge(from: "user:A", into: "system:S2")])
    let view = journal.view
    #expect(view.staleEdits.isEmpty)
    #expect(Set(view.turns.filter { $0.speakerID == "system:S2" }.map(\.id)) == ["T1", "T2", "T4", "T5"])
    #expect(!view.speakers.contains { $0.name == "Alice" })
}

@Test func turnsGivenToASpeakerShownJoinedGoToTheOneShown() {
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:A", name: "Alice", turnIDs: ["T5"]))
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    let asked: [SpeakerEditAction] = [.reassignTurns(turnIDs: ["T2"], to: "system:S1"),
                                      .splitTurn(turnID: "T1", at: WordRef(segmentID: "seg-T1", word: 2))]
    #expect(journal.view.fanningOut(asked) == asked)
    let undo: [SpeakerEditAction] = [.revert(editID: "E1")]
    #expect(journal.view.fanningOut(undo) == undo)
}

@Test func undoOfAFannedOutRenameBringsTheGroupBack() throws {
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:A", name: "Alice", turnIDs: ["T5"]))
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    let before = journal.view
    journal.save([.rename(speakerID: "system:S1", name: "Alicia")])
    let batch = try #require(journal.view.lastUndoableBatchID)
    for edit in journal.edits where edit.batchID == batch {
        journal.edits.append(SpeakerEdit(id: "R-\(edit.id)", baseRunID: runID, at: fixedDate, source: "cli",
                                         action: .revert(editID: edit.id), batchID: "UNDO"))
    }
    #expect(journal.view.speakers == before.speakers)
    #expect(journal.view.turns == before.turns)
}

@Test func speakerNamedMatchesTheShownGroupNeverALinkedName() throws {
    var journal = Journal(names: ["P-BOB": "Bob"])
    journal.save([.rename(speakerID: "system:S2", name: "Zoë")])
    journal.append(.newSpeaker(speakerID: "user:Z", name: "zoe", turnIDs: ["T5"]))
    // Two stored Zoës, shown as S2: the name names that group.
    #expect(journal.view.speaker(named: " zoe ")?.id == "system:S2")
    #expect(journal.view.speaker(named: "Speaker 1") == nil)
    #expect(journal.view.speaker(named: "Zoey") == nil)
    // Two speakers linked to Bob but given no name are not joined: "Bob" names neither.
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-BOB"))
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-BOB"))
    #expect(journal.view.speakers.filter { $0.name == "Bob" }.count == 2)
    #expect(journal.view.speaker(named: "Bob") == nil)
}


// MARK: - Label Again

@Test func speakersOfOneNameLinkedToTwoPeopleEachCarryTheirOwnNameAndLink() {
    // Two Alexes linked to two people (shown apart): Label Again carries each name and link to the new speaker its
    // own speech lands in (here the same run), never one person onto the other's speech.
    var journal = Journal(names: ["P-ALEX1": "Alex", "P-ALEX2": "Alex"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-ALEX1"))
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALEX2"))
    journal.append(.rename(speakerID: "system:S3", name: "Alex"))
    let carried = SpeakerCarryOver.carry(from: journal.view, to: run)
    #expect(carried.actions == [.rename(speakerID: "system:S1", name: "Alex"),
                                .linkProfile(speakerID: "system:S1", profileID: "P-ALEX1"),
                                .rename(speakerID: "system:S3", name: "Alex"),
                                .linkProfile(speakerID: "system:S3", profileID: "P-ALEX2")])
    #expect(carried.unmatchedSpeakers.isEmpty)
}

@Test func aJoinedGroupCarriesItsWholeIdentityToEveryNewSpeakerItsSpeechLandsIn() {
    // S1 has the name, S3 the link (and is called alex too): one person, shown as one.
    var journal = Journal(names: ["P-ALEX": "Alex"])
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALEX"))
    journal.append(.rename(speakerID: "system:S3", name: "alex"))
    #expect(journal.view.speakers.first?.memberIDs == ["system:S1", "system:S3"])

    // Labelled again into two speakers again: both get the name and the link.
    let two = SpeakerCarryOver.carry(from: journal.view, to: run)
    #expect(two.actions == [.rename(speakerID: "system:S1", name: "Alex"),
                            .linkProfile(speakerID: "system:S1", profileID: "P-ALEX"),
                            .rename(speakerID: "system:S3", name: "Alex"),
                            .linkProfile(speakerID: "system:S3", profileID: "P-ALEX")])
    #expect(two.unmatchedSpeakers.isEmpty)

    // Labelled again into one speaker (S3's speech now S1's): it gets the name and the link, and S3, whose
    // group-mate carried them, is not reported unmatched.
    var one = run
    one.turns = run.turns.map { turn in
        var turn = turn
        if turn.speakerID == "system:S3" { turn.speakerID = "system:S1"; turn.clusterID = "system:S1" }
        return turn
    }
    one.speakers = run.speakers.filter { $0.id != "system:S3" }
    let merged = SpeakerCarryOver.carry(from: journal.view, to: one)
    #expect(merged.actions == [.rename(speakerID: "system:S1", name: "Alex"),
                               .linkProfile(speakerID: "system:S1", profileID: "P-ALEX")])
    #expect(merged.unmatchedSpeakers.isEmpty)
}
