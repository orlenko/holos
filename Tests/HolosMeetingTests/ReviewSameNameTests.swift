import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// Same name, same person in the review window (docs/meeting-design.md §4.9, "Speakers with the same name"). Names are
// made up. Helpers are prefixed `sameName`.

@MainActor
private func sameNameOpen(_ session: URL, store: SpeakerProfileStore? = nil) async throws -> ReviewSession {
    try await ReviewSession(session: session, profiles: store, maintenance: nil, exportDelay: .seconds(60))
}

private func sameNameJournal(_ session: URL) throws -> [SpeakerEdit] {
    try SessionSpeakerStore.readEdits(session: session).edits
}

private func sameNameStore(_ temp: TemporaryDirectory) -> SpeakerProfileStore {
    SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
}

/// T1 S1, T2 S2, T3 S3, T4 S1, T5 S2, T6 S3: five seconds each.
private func sameNameSession(_ temp: TemporaryDirectory) async throws -> URL {
    try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"], duration: 30).session
}

@Test(.timeLimit(.minutes(1))) @MainActor
func newSpeakerWithANameInTheMeetingGivesTheTurnsToThatSpeaker() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await sameNameSession(temp)
    let review = try await sameNameOpen(session)
    try await review.setName("Alice", speakerID: "system:S1")
    let before = review.projection

    // "New Speaker…" in a turn's speaker menu, typed with a name S1 already has.
    try await review.assign(["T2"], to: .newSpeaker(name: " ALICE "))
    #expect(try sameNameJournal(session).last?.action == .reassignTurns(turnIDs: ["T2"], to: "system:S1"))
    #expect(review.projection.turns.first { $0.id == "T2" }?.speakerID == "system:S1")
    #expect(review.projection.speakers.map(\.id) == ["system:S1", "system:S2", "system:S3"])

    // One undo gives the turn back.
    try await review.undo()
    #expect(review.projection.turns == before.turns)

    // Another name still makes a new speaker.
    try await review.assign(["T2"], to: .newSpeaker(name: "Bob"))
    #expect(review.projection.speakers.map(\.name) == ["Alice", "Speaker 2", "Speaker 3", "Bob"])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func speakersSavedWithOneNameShowAsOneAndRenameAsOne() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await sameNameSession(temp)
    // Saved before the rule: "Alice" picked for T2 (a new speaker), and S1 renamed Alice too.
    try appendWithoutJoining([.newSpeaker(speakerID: "user:A", name: "Alice", turnIDs: ["T2"]),
                              .rename(speakerID: "system:S1", name: "alice")], session: session)
    let review = try await sameNameOpen(session)
    let speakers = review.projection.speakers
    #expect(speakers.map(\.id) == ["system:S1", "system:S2", "system:S3"])
    let alice = try #require(speakers.first)
    #expect(alice.memberIDs == ["system:S1", "user:A"])
    #expect(alice.turnCount == 3)
    let hers = review.projection.turns.filter { $0.speakerID == "system:S1" }
    #expect(hers.map(\.id) == ["T1", "T2", "T4"])
    #expect(abs(alice.talkSeconds - hers.reduce(0) { $0 + $1.end - $1.start }) < 1e-9)
    let before = review.projection

    // A rename of the one shown renames her whole, as one change.
    try await review.setName("Alicia", speakerID: "system:S1")
    let lines = try sameNameJournal(session)
    #expect(lines.suffix(2).map(\.action) == [.merge(from: "user:A", into: "system:S1"),
                                                .rename(speakerID: "system:S1", name: "Alicia")])
    #expect(review.projection.speakers.map(\.name) == ["Alicia", "Speaker 2", "Speaker 3"])
    try await review.undo()
    #expect(review.projection.speakers == before.speakers)
    #expect(review.projection.turns == before.turns)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func assigningAPersonCalledLikeASpeakerGivesTheTurnsToThatSpeakerAndLinksIt() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = sameNameStore(temp)
    let alice = SpeakerProfile(displayName: "Alice")
    try store.update { $0.profiles.append(alice) }
    let session = try await sameNameSession(temp)
    let review = try await sameNameOpen(session, store: store)
    try await review.apply([.rename(speakerID: "system:S2", name: "alice")])

    try await review.assign(["T3"], to: .person(profileID: alice.id))
    #expect(review.projection.turns.first { $0.id == "T3" }?.speakerID == "system:S2")
    #expect(review.speaker("system:S2")?.profileID == alice.id)
    #expect(review.projection.speakers.filter { $0.name.lowercased() == "alice" }.count == 1)
    #expect(try store.load().profiles.count == 1)

    // One undo takes back the move and the link.
    try await review.undo()
    #expect(review.projection.turns.first { $0.id == "T3" }?.speakerID == "system:S3")
    #expect(review.speaker("system:S2")?.profileID == nil)
    #expect(review.speaker("system:S2")?.name == "alice")
}

/// A hook that holds every save back until `release` finishes the stream; `entered` counts the saves that reached it.
private func sameNameGate() -> (hook: @Sendable () async -> Void, entered: SharedValue<Int>,
                                release: AsyncStream<Void>.Continuation) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    return ({
        entered.update { $0 += 1 }
        for await _ in stream {}
    }, entered, continuation)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func linkingASpeakerShownJoinedShowsOneSpeakerWhileItSaves() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = sameNameStore(temp)
    let bob = SpeakerProfile(displayName: "Bob")
    try store.update { $0.profiles.append(bob) }
    let session = try await sameNameSession(temp)
    // Saved before the rule: S1 and S2 both named Alice, shown as one (their talk times tie; S1 stays).
    try appendWithoutJoining([.rename(speakerID: "system:S1", name: "Alice"),
                              .rename(speakerID: "system:S2", name: "alice")], session: session)
    let review = try await sameNameOpen(session, store: store)
    #expect(review.projection.speakers.map(\.id) == ["system:S1", "system:S3"])
    let gate = sameNameGate()
    review.beforeEdit = gate.hook

    // The name field links her to Bob, a known person; the save is held.
    let linking = Task { @MainActor in try await review.setName("Bob", speakerID: "system:S1") }
    #expect(await eventually { gate.entered.value == 1 })
    // Shown as it will be saved: S2 merged into S1, so no second "Alice" comes back meanwhile.
    #expect(review.projection.speakers.map(\.id) == ["system:S1", "system:S3"])
    #expect(review.projection.speakers.map(\.name) == ["Bob", "Speaker 3"])
    #expect(review.projection.turns.first { $0.id == "T2" }?.speakerID == "system:S1")
    gate.release.finish()
    try await linking.value

    #expect(review.projection.speakers.map(\.name) == ["Bob", "Speaker 3"])
    #expect(review.speaker("system:S1")?.profileID == bob.id)
    #expect(try sameNameJournal(session).contains { $0.action == .merge(from: "system:S2", into: "system:S1") })
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func namingASpeakerAsAnotherIsNamedKeepsTheShownSpeakerWhenItCreatesThePerson() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = sameNameStore(temp)
    let session = try await sameNameSession(temp)
    let review = try await sameNameOpen(session, store: store)
    // S1 is called Alice, with no person behind the name.
    try await review.apply([.rename(speakerID: "system:S1", name: "Alice")])
    let gate = sameNameGate()
    review.beforeEdit = gate.hook

    // The name field names S3 Alice too: nobody is called Alice in People, so the save creates her and links S3.
    let naming = Task { @MainActor in try await review.setName("alice", speakerID: "system:S3") }
    #expect(await eventually { gate.entered.value == 1 })
    #expect(review.projection.speakers.map(\.id) == ["system:S1", "system:S2"])
    // A change made on the row shown meanwhile: it must still find its speaker once the name is saved.
    let moving = Task { @MainActor in try await review.assign(["T2"], to: .speaker("system:S1")) }
    gate.release.finish()
    try await naming.value
    try await moving.value

    let alice = try #require(try store.load().profiles.first { $0.displayName == "alice" })
    #expect(review.projection.speakers.map(\.id) == ["system:S1", "system:S2"])
    #expect(review.speaker("system:S1")?.profileID == alice.id)
    #expect(review.projection.turns.first { $0.id == "T2" }?.speakerID == "system:S1")
    #expect(review.projection.turns.first { $0.id == "T3" }?.speakerID == "system:S1")
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func thisIsMeOnASpeakerShownJoinedShowsOneSpeakerWhileItSaves() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = sameNameStore(temp)
    let session = try await sameNameSession(temp)
    try appendWithoutJoining([.rename(speakerID: "system:S1", name: "Alice"),
                              .rename(speakerID: "system:S2", name: "alice")], session: session)
    let review = try await sameNameOpen(session, store: store)
    let gate = sameNameGate()
    review.beforeEdit = gate.hook

    let marking = Task { @MainActor in try await review.markSelf(speakerID: "system:S1") }
    #expect(await eventually { gate.entered.value == 1 })
    #expect(review.projection.speakers.map(\.id) == ["system:S1", "system:S3"])
    #expect(!review.projection.speakers.contains { $0.name == "alice" || $0.name == "Alice" })
    gate.release.finish()
    try await marking.value
    #expect(review.projection.speakers.map(\.id) == ["system:S1", "system:S3"])
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func assigningAnotherPersonOfTheSameNameMakesTheirOwnSpeaker() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = sameNameStore(temp)
    // Two remembered people called Alex.
    let first = SpeakerProfile(displayName: "Alex")
    let second = SpeakerProfile(displayName: "Alex")
    try store.update { $0.profiles += [first, second] }
    let session = try await sameNameSession(temp)
    let review = try await sameNameOpen(session, store: store)
    try await review.link(speakerID: "system:S1", to: .existing(profileID: first.id))

    // T2 is the other Alex: it goes to a speaker of their own, linked to them, not to S1.
    try await review.assign(["T2"], to: .person(profileID: second.id))
    let moved = try #require(review.projection.turns.first { $0.id == "T2" }?.speakerID)
    #expect(moved != "system:S1")
    #expect(review.speaker(moved)?.profileID == second.id)
    #expect(review.speaker(moved)?.name == "Alex")
    #expect(review.speaker("system:S1")?.profileID == first.id)
    #expect(review.speaker("system:S1")?.memberIDs == ["system:S1"])
    #expect(!(try sameNameJournal(session).contains { if case .merge = $0.action { true } else { false } }))
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func assigningAPersonASpeakerOfTheirNameSaidNotToMakesTheirOwnSpeaker() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = sameNameStore(temp)
    let alex = SpeakerProfile(displayName: "Alex")
    try store.update { $0.profiles.append(alex) }
    let session = try await sameNameSession(temp)
    let review = try await sameNameOpen(session, store: store)
    // S2 is called Alex, but is not this Alex ("Not Alex").
    try await review.apply([.rename(speakerID: "system:S2", name: "Alex"),
                            .rejectProfile(speakerID: "system:S2", profileID: alex.id)])

    try await review.assign(["T3"], to: .person(profileID: alex.id))
    let moved = try #require(review.projection.turns.first { $0.id == "T3" }?.speakerID)
    #expect(moved != "system:S2")
    #expect(review.speaker(moved)?.profileID == alex.id)
    #expect(review.speaker("system:S2")?.profileID == nil)
    #expect(review.projection.turns.first { $0.id == "T2" }?.speakerID == "system:S2")
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func namingASpeakerLikeAPersonIgnoresAccentsAndSpaces() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = sameNameStore(temp)
    let zoe = SpeakerProfile(displayName: "Zoë Smith")
    try store.update { $0.profiles.append(zoe) }
    let session = try await sameNameSession(temp)
    let review = try await sameNameOpen(session, store: store)

    try await review.setName(" zoe   smith ", speakerID: "system:S3")
    #expect(review.speaker("system:S3")?.profileID == zoe.id)
    #expect(review.speaker("system:S3")?.name == "Zoë Smith")
    #expect(try store.load().profiles.count == 1)
}
