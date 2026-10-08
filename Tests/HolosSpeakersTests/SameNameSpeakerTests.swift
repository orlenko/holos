import Foundation
import Testing
import HolosCore
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

private func segment(_ spec: TurnSpec) -> TranscriptSegment {
    var text = ""
    var words: [TimedWord] = []
    for index in 0..<spec.words {
        if index > 0 { text += " " }
        let token = "w\(index)"
        words.append(TimedWord(text: token, start: spec.start + Double(index), end: spec.start + Double(index) + 1,
                               utf16Offset: text.utf16.count, utf16Length: token.utf16.count))
        text += token
    }
    return TranscriptSegment(id: "seg-\(spec.id)", start: spec.start, end: spec.start + Double(spec.words), text: text,
                             words: words, track: spec.track)
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

    /// A batch as `SpeakerEditor` saves it: `view.joiningSameNames(actions)`, one batch ID.
    @discardableResult
    mutating func save(_ actions: [SpeakerEditAction]) -> [SpeakerEditAction] {
        let saved = view.joiningSameNames(actions)
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

@Test func theSpeakerLinkedToAPersonStaysWhateverItsTalkTime() throws {
    var journal = Journal(names: ["P-ALICE": "Alice"])
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALICE"))
    journal.append(.rename(speakerID: "system:S3", name: "Alice"))
    journal.append(.rename(speakerID: "system:S1", name: "ALICE"))
    let alice = try #require(speaker(journal.view, "system:S3"))
    #expect(alice.name == "Alice")
    #expect(alice.profileID == "P-ALICE")
    #expect(alice.memberIDs == ["system:S3", "system:S1"])
    #expect(alice.clusterIDs == ["system:S3", "system:S1"])
    #expect(alice.talkSeconds == 10)
    #expect(speaker(journal.view, "system:S1") == nil)
    #expect(turnSpeaker(journal.view, "T1") == "system:S3")
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

// MARK: - Write side: a batch keeps one stored speaker per name

@Test func renameToANameAnotherSpeakerHasMergesThem() throws {
    var journal = Journal()
    journal.save([.rename(speakerID: "system:S1", name: "Alice")])
    let saved = journal.save([.rename(speakerID: "system:S3", name: "  alice ")])
    // S1 talks longer, so S3 merges into it after the rename, in the same batch.
    #expect(saved == [.rename(speakerID: "system:S3", name: "  alice "), .merge(from: "system:S3", into: "system:S1")])
    let view = journal.view
    #expect(view.staleEdits.isEmpty)
    #expect(speaker(view, "system:S1")?.memberIDs == ["system:S1"])
    #expect(speaker(view, "system:S1")?.clusterIDs == ["system:S1", "system:S3"])
    #expect(turnSpeaker(view, "T3") == "system:S1")
}

@Test func aNewSpeakerWithANameAnotherSpeakerHasMergesIntoIt() {
    var journal = Journal()
    journal.save([.rename(speakerID: "system:S2", name: "Bob")])
    let saved = journal.save([.newSpeaker(speakerID: "user:B", name: "BOB", turnIDs: ["T3"])])
    // The new speaker (2 s) joins S2 (3 s).
    #expect(saved == [.newSpeaker(speakerID: "user:B", name: "BOB", turnIDs: ["T3"]),
                      .merge(from: "user:B", into: "system:S2")])
    #expect(journal.view.speakers.map(\.id) == ["system:S1", "system:S2", "mic:me"])
    #expect(turnSpeaker(journal.view, "T3") == "system:S2")
}

@Test func linkingASpeakerToAPersonOthersAreNamedAsKeepsTheShownOneAndLinksIt() {
    var journal = Journal(names: ["P-ALICE": "Alice"])
    journal.save([.rename(speakerID: "system:S1", name: "Alice")])
    let saved = journal.save([.linkProfile(speakerID: "system:S3", profileID: "P-ALICE"),
                              .rename(speakerID: "system:S3", name: "Alice")])
    // S1 was the Alice shown before the batch, so it stays; the person the batch linked goes with it.
    #expect(saved.suffix(2) == [.merge(from: "system:S3", into: "system:S1"),
                                .linkProfile(speakerID: "system:S1", profileID: "P-ALICE")])
    #expect(speaker(journal.view, "system:S1")?.profileID == "P-ALICE")
    #expect(speaker(journal.view, "system:S1")?.memberIDs == ["system:S1"])
    #expect(turnSpeaker(journal.view, "T3") == "system:S1")
}

@Test func theBatchsOwnLinkNeverChangesWhoStays() {
    // The name field's link to a person it is creating shows as a rename before it is saved (the person is not
    // known yet); the shown change and the saved one must keep the same speaker.
    var journal = Journal()
    journal.save([.rename(speakerID: "system:S2", name: "Alice")])
    let view = journal.view
    let shown = view.joiningSameNames([.rename(speakerID: "system:S3", name: "Alice")])
    let saved = view.joiningSameNames([.linkProfile(speakerID: "system:S3", profileID: "P-NEW"),
                                       .rename(speakerID: "system:S3", name: "Alice")])
    #expect(shown == [.rename(speakerID: "system:S3", name: "Alice"), .merge(from: "system:S3", into: "system:S2")])
    #expect(saved == [.linkProfile(speakerID: "system:S3", profileID: "P-NEW"),
                      .rename(speakerID: "system:S3", name: "Alice"),
                      .merge(from: "system:S3", into: "system:S2"),
                      .linkProfile(speakerID: "system:S2", profileID: "P-NEW")])
}

@Test func theNewestLinkIsKeptAndTheOtherPersonsVoiceStaysOut() throws {
    // S1 (8 s) was linked to a person since forgotten; S3 (2 s) is now linked to a new Alice. The newest link wins,
    // and S1's turns, said to be the other person's, are kept out of voice learning.
    var journal = Journal(names: ["P-NEW": "Alice"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-GONE"))
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    let saved = journal.save([.linkProfile(speakerID: "system:S3", profileID: "P-NEW"),
                              .rename(speakerID: "system:S3", name: "Alice")])
    #expect(saved.suffix(3) == [.excludeFromEnrollment(turnIDs: ["T1", "T4"]),
                                .merge(from: "system:S3", into: "system:S1"),
                                .linkProfile(speakerID: "system:S1", profileID: "P-NEW")])
    let alice = try #require(speaker(journal.view, "system:S1"))
    #expect(alice.profileID == "P-NEW")
    #expect(alice.memberIDs == ["system:S1"])
    let turns = journal.view.turns.filter { $0.speakerID == "system:S1" }
    #expect(turns.map(\.id) == ["T1", "T3", "T4"])
    #expect(turns.filter(\.excludedFromEnrollment).map(\.id) == ["T1", "T4"])
}

@Test func joiningNeverReadsThePeopleStore() {
    // The same journal joins the same speakers whatever people a builder knows: links count as written.
    var journal = Journal(names: ["P-ALEX1": "Alex", "P-ALEX2": "Alex"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-ALEX1"))
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALEX2"))
    journal.append(.rename(speakerID: "system:S3", name: "alex"))
    let withPeople = journal.view
    journal.names = [:]
    let withoutPeople = journal.view
    #expect(withPeople.speakers.map(\.memberIDs) == withoutPeople.speakers.map(\.memberIDs))
    #expect(withPeople.speakers.first?.memberIDs == ["system:S1", "system:S3"])
    #expect(withPeople.turns.map(\.speakerID) == withoutPeople.turns.map(\.speakerID))
}

@Test func aLinkOfTheOthersIsKeptWhenTheOneThatStaysHasNone() {
    var journal = Journal(names: ["P-ALICE": "Alice"])
    journal.save([.rename(speakerID: "system:S1", name: "Alice")])
    // S3 is linked to Alice under another name, then renamed Alice: S1 stays, and takes the link.
    journal.save([.linkProfile(speakerID: "system:S3", profileID: "P-ALICE"),
                  .rename(speakerID: "system:S3", name: "Al")])
    let saved = journal.save([.rename(speakerID: "system:S3", name: "alice")])
    #expect(saved == [.rename(speakerID: "system:S3", name: "alice"), .merge(from: "system:S3", into: "system:S1"),
                      .linkProfile(speakerID: "system:S1", profileID: "P-ALICE")])
}

@Test func anEditOfASpeakerShownJoinedMergesTheJoinedOnesFirst() throws {
    // Saved before the rule: two stored "Alice"s, shown as one.
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:A", name: "Alice", turnIDs: ["T5"]))
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    let saved = journal.save([.rename(speakerID: "system:S1", name: "Alicia")])
    #expect(saved == [.merge(from: "user:A", into: "system:S1"), .rename(speakerID: "system:S1", name: "Alicia")])
    let view = journal.view
    #expect(view.staleEdits.isEmpty)
    #expect(view.speakers.filter { $0.name.hasPrefix("Ali") }.map(\.name) == ["Alicia"])
    #expect(turnSpeaker(view, "T5") == "system:S1")
}

@Test func mergingTwoSpeakersShownAsOneOnlyMergesTheStoredOnes() {
    var journal = Journal()
    journal.append(.newSpeaker(speakerID: "user:A", name: "Alice", turnIDs: ["T5"]))
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    let saved = journal.save([.merge(from: "user:A", into: "system:S1")])
    #expect(saved == [.merge(from: "user:A", into: "system:S1")])
    #expect(journal.view.staleEdits.isEmpty)
}

@Test func undoOfTheBatchBringsBothSpeakersBack() throws {
    var journal = Journal()
    journal.save([.rename(speakerID: "system:S1", name: "Alice")])
    let before = journal.view
    journal.save([.rename(speakerID: "system:S3", name: "Alice")])
    let batch = try #require(journal.view.lastUndoableBatchID)
    for edit in journal.edits where edit.batchID == batch {
        journal.edits.append(SpeakerEdit(id: "R-\(edit.id)", baseRunID: runID, at: fixedDate, source: "cli",
                                         action: .revert(editID: edit.id), batchID: "UNDO"))
    }
    #expect(journal.view.speakers == before.speakers)
    #expect(journal.view.turns == before.turns)
}

@Test func batchesThatNameNobodyTwiceAreUnchanged() {
    var journal = Journal()
    journal.save([.rename(speakerID: "system:S1", name: "Alice")])
    let view = journal.view
    let asked: [SpeakerEditAction] = [.rename(speakerID: "system:S2", name: "Bob"),
                                      .reassignTurns(turnIDs: ["T5"], to: "system:S1"),
                                      .splitTurn(turnID: "T1", at: WordRef(segmentID: "seg-T1", word: 2))]
    #expect(view.joiningSameNames(asked) == asked)
    let undo: [SpeakerEditAction] = [.revert(editID: "E1")]
    #expect(view.joiningSameNames(undo) == undo)
}

@Test func speakerNamedFindsThePersonNotAGuess() {
    var journal = Journal()
    journal.save([.rename(speakerID: "system:S2", name: "Zoë")])
    #expect(journal.view.speaker(named: " zoe ")?.id == "system:S2")
    #expect(journal.view.speaker(named: "Speaker 1") == nil)
    #expect(journal.view.speaker(named: "Zoey") == nil)
}

// MARK: - Links of two people

@Test func speakersSavedLinkedToTwoPeopleOfOneNameAreOneSpeakerAndKeepTheirVoicesApart() throws {
    // Saved before the rule: S1 (8 s) linked to one Alex, S3 (2 s) to another Alex, both named Alex.
    var journal = Journal(names: ["P-ALEX1": "Alex", "P-ALEX2": "Alex"])
    journal.append(.linkProfile(speakerID: "system:S1", profileID: "P-ALEX1"))
    journal.append(.rename(speakerID: "system:S1", name: "Alex"))
    journal.append(.linkProfile(speakerID: "system:S3", profileID: "P-ALEX2"))
    journal.append(.rename(speakerID: "system:S3", name: "Alex"))
    let alex = try #require(speaker(journal.view, "system:S1"))
    #expect(alex.memberIDs == ["system:S1", "system:S3"])
    #expect(alex.profileID == "P-ALEX1")
    // S3's turn is shown as S1's, but its voice is the other Alex's: kept out of the first Alex's sample.
    let t3 = try #require(journal.view.turns.first { $0.id == "T3" })
    #expect(t3.speakerID == "system:S1")
    #expect(t3.excludedFromEnrollment)
    #expect(journal.view.turns.first { $0.id == "T1" }?.excludedFromEnrollment == false)

    // An edit of him makes them one stored speaker the same way: S3's turns are kept out first.
    let saved = journal.save([.rename(speakerID: "system:S1", name: "Alexander")])
    #expect(saved == [.excludeFromEnrollment(turnIDs: ["T3"]), .merge(from: "system:S3", into: "system:S1"),
                      .rename(speakerID: "system:S1", name: "Alexander")])
    #expect(journal.view.speakers.first?.profileID == "P-ALEX1")
    #expect(journal.view.turns.first { $0.id == "T3" }?.excludedFromEnrollment == true)
}

@Test func linkingASpeakerToAnotherPersonOfTheNameKeepsOneSpeakerAndTheNewestLink() {
    var journal = Journal(names: ["P-ALEX1": "Alex", "P-ALEX2": "Alex"])
    journal.save([.linkProfile(speakerID: "system:S1", profileID: "P-ALEX1"),
                  .rename(speakerID: "system:S1", name: "Alex")])
    let saved = journal.save([.linkProfile(speakerID: "system:S3", profileID: "P-ALEX2"),
                              .rename(speakerID: "system:S3", name: "Alex")])
    // S1, the Alex shown, stays; the newest link names the person, and S1's own turns stay out of their sample.
    #expect(saved == [.linkProfile(speakerID: "system:S3", profileID: "P-ALEX2"),
                      .rename(speakerID: "system:S3", name: "Alex"),
                      .excludeFromEnrollment(turnIDs: ["T1", "T4"]),
                      .merge(from: "system:S3", into: "system:S1"),
                      .linkProfile(speakerID: "system:S1", profileID: "P-ALEX2")])
    #expect(journal.view.speakers.filter { $0.name == "Alex" }.map(\.id) == ["system:S1"])
    #expect(journal.view.staleEdits.isEmpty)
}

@Test func notThisPersonDoesNotKeepOneNameApart() {
    // "Not Alex" keeps suggestions away; a speaker then named Alex is still Alex.
    var journal = Journal(names: ["P-ALEX": "Alex"])
    journal.save([.linkProfile(speakerID: "system:S1", profileID: "P-ALEX"),
                  .rename(speakerID: "system:S1", name: "Alex")])
    journal.save([.rejectProfile(speakerID: "system:S2", profileID: "P-ALEX")])
    let saved = journal.save([.rename(speakerID: "system:S2", name: "Alex")])
    #expect(saved == [.rename(speakerID: "system:S2", name: "Alex"), .merge(from: "system:S2", into: "system:S1")])
    #expect(journal.view.speakers.filter { $0.name == "Alex" }.map(\.id) == ["system:S1"])
}


// MARK: - Label Again

@Test func namesCarriedOverFromSpeakersShownAsOneNameOneSpeaker() {
    // Two stored "Alice"s shown as one carry one name: the joined speaker's turns all count for it.
    var journal = Journal()
    journal.append(.rename(speakerID: "system:S1", name: "Alice"))
    journal.append(.rename(speakerID: "system:S3", name: "Alice"))
    let carried = SpeakerCarryOver.carry(from: journal.view, to: run)
    #expect(carried.actions == [.rename(speakerID: "system:S1", name: "Alice")])
}
