import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The review window's model (docs/meeting-design.md §5.10, PR9): ReviewSession on fixture sessions, with the people
// store in the test's temporary folder. Helpers are prefixed `review`.

// MARK: - Helpers

/// A people store inside the test's temporary folder.
private func reviewStore(_ temp: TemporaryDirectory) -> SpeakerProfileStore {
    SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
}

/// One turn of a hand-built run on the system track: `words` spread evenly over `seconds` from `start`.
private struct ReviewTurnSpec {
    var speaker: String?
    var start: Double
    var seconds: Double
    var words: [String]
    var overlap = false
    var score = 1.0
}

/// A finished call session whose head run has exactly the turns of `specs` (T1, T2, … in the order given, which
/// must be time order), one transcript segment per turn. Speakers are numbered by their first turn.
private func reviewCustomSession(in temp: TemporaryDirectory,
                                 turns specs: [ReviewTurnSpec]) async throws -> (session: URL, run: DiarizationRun) {
    let segments = specs.map { spec in
        SessionFixtures.segment(spec.words, track: "system", start: spec.start,
                                wordSeconds: spec.seconds / Double(max(1, spec.words.count)))
    }
    let transcript = SessionFixtures.transcript(segments)
    let total = (specs.map { $0.start + $0.seconds }.max() ?? 0) + 1
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": total],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    var ordinals: [String: Int] = [:]
    for spec in specs {
        if let speaker = spec.speaker, ordinals[speaker] == nil { ordinals[speaker] = ordinals.count + 1 }
    }
    let speakers = ordinals.sorted { $0.value < $1.value }.map {
        SessionSpeaker(id: $0.key, ordinal: $0.value, provenance: .diarizer, clusterIDs: [$0.key])
    }
    let turns = zip(specs, segments).enumerated().map { index, pair in
        let (spec, segment) = pair
        let others = spec.overlap ? speakers.map(\.id).filter { $0 != spec.speaker }.prefix(1).map { $0 } : []
        return SpeakerTurn(id: "T\(index + 1)", track: "system", start: spec.start, end: spec.start + spec.seconds,
                           speakerID: spec.speaker, clusterID: spec.speaker,
                           spans: [WordSpan(segmentID: segment.id, first: 0, end: spec.words.count)],
                           overlap: spec.overlap, otherClusters: others, assignmentScore: spec.score,
                           timing: .measured)
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
    return (session, run)
}

/// `count` words "w1" … "wN".
private func reviewWords(_ count: Int, prefix: String = "w") -> [String] {
    (1...count).map { "\(prefix)\($0)" }
}

@MainActor
private func reviewOpen(_ session: URL, store: SpeakerProfileStore? = nil,
                        exportDelay: Duration = .seconds(60)) async throws -> ReviewSession {
    try await ReviewSession(session: session, profiles: store, maintenance: nil, exportDelay: exportDelay)
}

private func reviewJournal(_ session: URL) throws -> [SpeakerEdit] {
    try SessionSpeakerStore.readEdits(session: session).edits
}

/// A hook that holds every save back until `release` finishes the stream; `entered` counts the saves that reached it.
private func reviewGate() -> (hook: @Sendable () async -> Void, entered: SharedValue<Int>,
                              release: AsyncStream<Void>.Continuation) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    return ({
        entered.update { $0 += 1 }
        for await _ in stream {}
    }, entered, continuation)
}

private func reviewName(_ review: ReviewSession, _ speakerID: String) -> String? {
    MainActor.assumeIsolated { review.projection.speakers.first { $0.id == speakerID }?.name }
}

// MARK: - Reading

@Test(.timeLimit(.minutes(1))) @MainActor
func nextUncertainWrapsInTimeOrder() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    var specs = (0..<10).map { index in
        ReviewTurnSpec(speaker: index % 2 == 0 ? "system:S1" : "system:S2", start: Double(index) * 3, seconds: 2.5,
                       words: reviewWords(4))
    }
    specs[2].score = 0.4        // T3: a weak assignment
    specs[8].overlap = true     // T9: overlapped speech
    let (session, _) = try await reviewCustomSession(in: temp, turns: specs)
    let review = try await reviewOpen(session)

    #expect(review.projection.turns.filter(\.uncertain).map(\.id) == ["T3", "T9"])
    #expect(review.nextUncertain(after: nil)?.id == "T3")
    #expect(review.nextUncertain(after: "T3")?.id == "T9")
    #expect(review.nextUncertain(after: "T5")?.id == "T9")
    #expect(review.nextUncertain(after: "T9")?.id == "T3")
    #expect(review.nextUncertain(after: "T10")?.id == "T3")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func searchIsCaseInsensitive() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let (session, _) = try await reviewCustomSession(in: temp, turns: [
        ReviewTurnSpec(speaker: "system:S1", start: 0, seconds: 3, words: ["We", "discuss", "the", "budget"]),
        ReviewTurnSpec(speaker: "system:S2", start: 4, seconds: 3, words: ["Nothing", "to", "see"]),
        ReviewTurnSpec(speaker: "system:S1", start: 8, seconds: 3, words: ["Budget", "vote", "now"]),
    ])
    let review = try await reviewOpen(session)

    #expect(review.turns(matching: "BUDGET").map(\.id) == ["T1", "T3"])
    #expect(review.turns(matching: "  budget ").map(\.id) == ["T1", "T3"])
    #expect(review.turns(matching: "nothing").map(\.id) == ["T2"])
    #expect(review.turns(matching: "absent").isEmpty)
    #expect(review.turns(matching: "").count == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func sampleClipsPickLongestNonOverlapped() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let (session, _) = try await reviewCustomSession(in: temp, turns: [
        ReviewTurnSpec(speaker: "system:S1", start: 0, seconds: 10, words: reviewWords(12)),
        ReviewTurnSpec(speaker: "system:S1", start: 12, seconds: 6, words: reviewWords(8), overlap: true),
        ReviewTurnSpec(speaker: "system:S1", start: 20, seconds: 3, words: reviewWords(4)),
        ReviewTurnSpec(speaker: "system:S1", start: 25, seconds: 8, words: reviewWords(10)),
        ReviewTurnSpec(speaker: "system:S2", start: 35, seconds: 20, words: reviewWords(20)),
    ])
    let review = try await reviewOpen(session)

    let clips = review.sampleClips(for: "system:S1")
    #expect(clips == [0.25...4.25, 25.25...29.25, 20.0...23.0])
    #expect(clips.map { $0.upperBound - $0.lowerBound } == [4, 4, 3])
    #expect(review.sampleClips(for: "system:S9").isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func previewsShowTwoLongestTurns() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let long = reviewWords(30, prefix: "long")
    let medium = ["medium", "turn", "text"]
    let (session, _) = try await reviewCustomSession(in: temp, turns: [
        ReviewTurnSpec(speaker: "system:S1", start: 0, seconds: 2, words: ["short", "one"]),
        ReviewTurnSpec(speaker: "system:S1", start: 3, seconds: 9, words: long),
        ReviewTurnSpec(speaker: "system:S2", start: 13, seconds: 12, words: reviewWords(5)),
        ReviewTurnSpec(speaker: "system:S1", start: 26, seconds: 5, words: medium),
    ])
    let review = try await reviewOpen(session)

    let previews = review.previews(for: "system:S1")
    #expect(previews.count == 2)
    #expect(previews.allSatisfy { $0.count <= 60 })
    #expect(previews.first == String(long.joined(separator: " ").prefix(60)))
    #expect(previews.last == medium.joined(separator: " "))
}

// MARK: - Editing

@Test(.timeLimit(.minutes(1))) @MainActor
func assignSelectionIsOneBatch() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, duration: 30)
    let review = try await reviewOpen(fixture.session)

    try await review.assign(["T4", "T5", "T6"], to: .speaker("system:S1"))

    let edits = try reviewJournal(fixture.session)
    #expect(edits.count == 1)
    #expect(edits.first?.action == .reassignTurns(turnIDs: ["T4", "T5", "T6"], to: "system:S1"))
    #expect(edits.first?.source == "app")
    #expect(review.projection.turns.filter { ["T4", "T5", "T6"].contains($0.id) }
        .allSatisfy { $0.speakerID == "system:S1" })
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func projectionUpdatesBeforeWriteCompletes() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)
    // The editor is held back (a slow disk) until the test lets it go.
    let gate = reviewGate()
    review.beforeEdit = gate.hook

    let edit = Task { @MainActor in try await review.apply([.rename(speakerID: "system:S1", name: "Jim")]) }
    #expect(await eventually { reviewName(review, "system:S1") == "Jim" && gate.entered.value == 1 })
    // Shown at once; not saved yet.
    try await Task.sleep(for: .milliseconds(500))
    #expect(review.snapshot.projection?.speakers.first { $0.id == "system:S1" }?.name == "Speaker 1")
    #expect(SessionFixtures.journalBytes(fixture.session) == nil)
    #expect(review.isWorking)

    gate.release.finish()
    try await edit.value
    #expect(review.snapshot.projection?.speakers.first { $0.id == "system:S1" }?.name == "Jim")
    #expect(reviewName(review, "system:S1") == "Jim")
    #expect(try reviewJournal(fixture.session).count == 1)
    #expect(!review.isWorking)
    #expect(review.lastSavedAt != nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func refusedEditReloads() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)
    #expect(review.projection.runID == fixture.run.id)

    // Labelled again underneath the window (another process), with three speakers.
    let newer = try SessionFixtures.writeHeadRun(
        session: fixture.session, transcript: fixture.transcript,
        outputs: ["system": FakeDiarizer.alternating(speakers: ["S1", "S2", "S3"], turnSeconds: 5, duration: 20)])

    let refusal = await #expect(throws: HolosError.self) {
        try await review.apply([.rename(speakerID: "system:S1", name: "Jim")])
    }
    #expect(refusal?.errorDescription == ReviewSession.changedElsewhere)
    #expect(SessionFixtures.journalBytes(fixture.session) == nil)
    #expect(review.snapshot.run?.id == newer.id)
    #expect(review.projection.runID == newer.id)
    #expect(review.projection.speakers.count == 3)

    // The reloaded labels take edits.
    try await review.apply([.rename(speakerID: "system:S3", name: "Maria")])
    #expect(try reviewJournal(fixture.session).map(\.baseRunID) == [newer.id])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func undoIsLastInFirstOut() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)

    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    try await review.apply([.rename(speakerID: "system:S2", name: "Bob")])
    #expect(review.canUndo)

    try await review.undo()
    #expect(reviewName(review, "system:S1") == "Ann")
    #expect(reviewName(review, "system:S2") == "Speaker 2")

    try await review.undo()
    #expect(reviewName(review, "system:S1") == "Speaker 1")
    #expect(reviewName(review, "system:S2") == "Speaker 2")
    #expect(!review.canUndo)
    await #expect(throws: HolosError.self) { try await review.undo() }

    let edits = try reviewJournal(fixture.session)
    #expect(edits.count == 4)
    #expect(edits[2].action == .revert(editID: edits[1].id))
    #expect(edits[3].action == .revert(editID: edits[0].id))
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func undoTakesBackOnlyTheWindowsChange() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)

    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    // A command renames S2 after the window's change.
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S2", name: "Bob")], session: fixture.session)
    await review.reload()
    #expect(reviewName(review, "system:S2") == "Bob")

    try await review.undo()
    #expect(reviewName(review, "system:S1") == "Speaker 1")
    #expect(reviewName(review, "system:S2") == "Bob", "The other command's change stays.")
    #expect(!review.canUndo)
    let edits = try reviewJournal(fixture.session)
    #expect(edits.last?.action == .revert(editID: edits[0].id))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func confirmAllIsOneUndo() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    try store.update {
        $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim"), SpeakerProfile(id: "MARIA", displayName: "Maria"),
                       SpeakerProfile(id: "SAM", displayName: "Sam")]
    }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"], duration: 30)
    let matches = [("system:S1", "JIM", "Jim"), ("system:S2", "MARIA", "Maria"), ("system:S3", "SAM", "Sam")].map {
        SpeakerMatch(speakerID: $0.0, profileID: $0.1, profileName: $0.2, distance: 0.2, tier: .possible)
    }
    try SessionArchive.withSpeakerLock(at: fixture.session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: fixture.run.id, embeddingModel: DiarizationEngineInfo.fake.embeddingModel,
                              thresholds: SpeakerRecognizer.defaultThresholds, matches: matches),
            session: fixture.session)
    }
    let review = try await reviewOpen(fixture.session, store: store)
    #expect(review.projection.speakers.compactMap(\.suggestion).count == 3)
    #expect(!review.learnVoices, "Remember voices is off, so the footer box starts off.")

    try await review.confirmAllSuggestions()
    #expect(review.projection.speakers.map(\.profileID) == ["JIM", "MARIA", "SAM"])
    #expect(review.projection.speakers.map(\.name) == ["Jim", "Maria", "Sam"])
    #expect(Set(try reviewJournal(fixture.session).compactMap(\.batchID)).count == 1)
    #expect(review.changeCount == 1)

    try await review.undo()
    #expect(review.projection.speakers.allSatisfy { $0.profileID == nil && $0.explicitName == nil })
    #expect(review.projection.speakers.compactMap(\.suggestion).count == 3)
    #expect(try reviewJournal(fixture.session).count == 12)
    #expect(!review.canUndo)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func exportsRegenerateAfterDelayAndOnClose() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let markdown = SessionPaths.export("md", in: fixture.session)

    // A short delay: the exports follow on their own.
    let quick = try await reviewOpen(fixture.session, exportDelay: .milliseconds(100))
    try await quick.apply([.rename(speakerID: "system:S1", name: "Jim")])
    #expect(quick.exportsPending)
    #expect(await eventually { SessionFixtures.text(markdown).contains("**Jim**") })
    #expect(await eventually { !quick.exportsPending })
    await quick.close()

    // A long delay: closing writes them.
    let slow = try await reviewOpen(fixture.session, exportDelay: .seconds(60))
    try await slow.apply([.rename(speakerID: "system:S2", name: "Maria")])
    try await Task.sleep(for: .milliseconds(200))
    #expect(!SessionFixtures.text(markdown).contains("**Maria**"))
    #expect(slow.exportsPending)
    await slow.close()
    #expect(SessionFixtures.text(markdown).contains("**Maria**"))
    #expect(SessionFixtures.text(markdown).contains("**Jim**"))
    #expect(!slow.exportsPending)
    await #expect(throws: HolosError.self) {
        try await slow.apply([.rename(speakerID: "system:S2", name: "Late")])
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func splitPartCanBeAssignedBeforeTheSplitIsSaved() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)
    let gate = reviewGate()
    review.beforeEdit = gate.hook

    let words = review.words(of: "T1")
    #expect(words.count == 6)
    let split = Task { @MainActor in try await review.split(turnID: "T1", at: words[3].ref) }
    #expect(await eventually { review.projection.turns.count == 5 })
    let part = try #require(review.projection.turns.first { $0.id.hasPrefix("T1/") })
    let assign = Task { @MainActor in try await review.assign([part.id], to: .speaker("system:S2")) }
    #expect(await eventually { review.turn(part.id)?.speakerID == "system:S2" })
    gate.release.finish()
    try await split.value
    try await assign.value

    let saved = try #require(review.snapshot.projection)
    let savedPart = try #require(saved.turns.first { $0.id.hasPrefix("T1/") })
    #expect(savedPart.id != part.id)
    #expect(savedPart.speakerID == "system:S2")
    #expect(review.resolvedTurnID(part.id) == savedPart.id)
    #expect(review.turn(part.id)?.id == savedPart.id)
    #expect(try reviewJournal(fixture.session).count == 2)
    #expect(saved == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func undoDropsOrRevertsUnsavedChanges() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)
    let gate = reviewGate()
    review.beforeEdit = gate.hook

    let first = Task { @MainActor in try await review.apply([.rename(speakerID: "system:S1", name: "Ann")]) }
    #expect(await eventually { reviewName(review, "system:S1") == "Ann" && gate.entered.value == 1 })
    let second = Task { @MainActor in try await review.apply([.rename(speakerID: "system:S2", name: "Bob")]) }
    #expect(await eventually { reviewName(review, "system:S2") == "Bob" })

    // The second change has not started saving: undo drops it.
    try await review.undo()
    #expect(reviewName(review, "system:S2") == "Speaker 2")
    try await second.value
    // The first is being saved: undo hides it now and reverts it once saved.
    let undo = Task { @MainActor in try await review.undo() }
    #expect(await eventually { reviewName(review, "system:S1") == "Speaker 1" })
    gate.release.finish()
    try await first.value
    try await undo.value

    let edits = try reviewJournal(fixture.session)
    #expect(edits.map(\.action) == [.rename(speakerID: "system:S1", name: "Ann"), .revert(editID: edits[0].id)])
    #expect(reviewName(review, "system:S1") == "Speaker 1")
    #expect(!review.canUndo)
    #expect(review.snapshot.projection == review.projection)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func changesQueuedBehindARefusalAreRefused() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)
    let gate = reviewGate()
    review.beforeEdit = gate.hook

    let first = Task { @MainActor in try await review.apply([.rename(speakerID: "system:S1", name: "Ann")]) }
    let second = Task { @MainActor in try await review.apply([.rename(speakerID: "system:S2", name: "Bob")]) }
    #expect(await eventually { reviewName(review, "system:S2") == "Bob" && gate.entered.value == 1 })
    // Another command renames S1 while the window's first change waits.
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Elsewhere")], session: fixture.session)
    gate.release.finish()

    let firstError = await #expect(throws: HolosError.self) { try await first.value }
    let secondError = await #expect(throws: HolosError.self) { try await second.value }
    #expect(firstError?.errorDescription == ReviewSession.changedElsewhere)
    #expect(secondError?.errorDescription == ReviewSession.changedElsewhere)
    #expect(try reviewJournal(fixture.session).count == 1)
    #expect(reviewName(review, "system:S1") == "Elsewhere")
    #expect(reviewName(review, "system:S2") == "Speaker 2")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nameFieldLinksOrCreatesPeople() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"], duration: 30)
    let review = try await reviewOpen(fixture.session, store: store)

    try await review.setName("  Jim  ", speakerID: "system:S1")
    let jim = try #require(try store.load().profiles.first)
    #expect(jim.displayName == "Jim")
    #expect(review.speaker("system:S1")?.profileID == jim.id)
    #expect(review.knownPeople().map(\.id) == [jim.id])

    // A known name, typed in another case, links the same person.
    try await review.setName("jim", speakerID: "system:S2")
    #expect(try store.load().profiles.count == 1)
    #expect(review.speaker("system:S2")?.profileID == jim.id)
    #expect(review.projection.mergeSuggestions.map(\.speakerIDs) == [["system:S1", "system:S2"]])

    // The same name again changes nothing.
    let lines = try reviewJournal(fixture.session).count
    try await review.setName("Jim", speakerID: "system:S1")
    #expect(try reviewJournal(fixture.session).count == lines)

    // An empty name clears the speaker's name, and unlinks the person it came from.
    try await review.setName("", speakerID: "system:S3")
    try await review.setName("Sam", speakerID: "system:S3")
    #expect(review.speaker("system:S3")?.name == "Sam")
    #expect(review.speaker("system:S3")?.profileID != nil)
    try await review.setName(" ", speakerID: "system:S3")
    #expect(review.speaker("system:S3")?.explicitName == nil)
    #expect(review.speaker("system:S3")?.profileID == nil)
    #expect(review.speaker("system:S3")?.name == "Speaker 3")
    #expect(review.snapshot.projection == review.projection)
    // One change: one undo brings Sam back.
    try await review.undo()
    #expect(review.speaker("system:S3")?.name == "Sam")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func sameNewNameWhileTheFirstIsSavingMakesOnePerson() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"], duration: 30)
    let review = try await reviewOpen(fixture.session, store: store)
    let gate = reviewGate()
    review.beforeEdit = gate.hook

    // "Jim" on S1 is held while it saves (a voice being learned); meanwhile "jim" on S2, and Return again on S1.
    let first = Task { @MainActor in try await review.setName("Jim", speakerID: "system:S1") }
    #expect(await eventually { gate.entered.value == 1 })
    let second = Task { @MainActor in try await review.setName("jim", speakerID: "system:S2") }
    #expect(await eventually { reviewName(review, "system:S2") == "jim" })
    try await review.setName("Jim", speakerID: "system:S1")
    gate.release.finish()
    try await first.value
    try await second.value

    let people = try store.load().profiles
    #expect(people.count == 1)
    let jim = try #require(people.first)
    #expect(jim.displayName == "Jim")
    #expect(review.speaker("system:S1")?.profileID == jim.id)
    #expect(review.speaker("system:S2")?.profileID == jim.id)
    #expect(review.speaker("system:S2")?.name == "Jim")
    #expect(review.projection.mergeSuggestions.map(\.speakerIDs) == [["system:S1", "system:S2"]])
    #expect(try reviewJournal(fixture.session).count == 4, "Two links of two lines each; Return again saved nothing.")
    #expect(review.snapshot.projection == review.projection)
}

/// A voice extractor that counts the turns it is asked about and returns one fixed embedding for each.
private final class ReviewFakeExtractor: VoiceSampleExtractor {
    private let asked = SharedValue<[String]>([])
    var turnIDs: [String] { asked.value }

    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        asked.update { $0 += turns.map(\.id) }
        return turns.map { turn in
            TurnEmbedding(turnID: turn.id, speechSeconds: turn.end - turn.start,
                          vector: FloatVector([0.6, 0.8, 0, 0, 0, 0, 0, 0]))
        }
    }
}

/// With Remember voices on: names S1 "Jim", marks S2 as you, confirms S3's suggestion (Sam), and gives T8 to Maria,
/// with the footer box set to `learn`. Returns the turns the extractor was asked about and each person's samples
/// from this meeting ("Jim", "Me" for the person who is you, "Sam", "Maria"). T8 is reassigned, so it never qualifies
/// (§4.10); giving it to Maria checks only that assigning to a person asks for nothing it may not.
@MainActor
private func reviewLearning(_ learn: Bool) async throws -> (asked: [String], samples: [String: Int]) {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [SpeakerProfile(id: "SAM", displayName: "Sam"), SpeakerProfile(id: "MARIA", displayName: "Maria")]
    }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3", "S4"],
                                                            duration: 40)
    try SessionArchive.withSpeakerLock(at: fixture.session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: fixture.run.id, embeddingModel: DiarizationEngineInfo.fake.embeddingModel,
                              thresholds: SpeakerRecognizer.defaultThresholds,
                              matches: [SpeakerMatch(speakerID: "system:S3", profileID: "SAM", profileName: "Sam",
                                                     distance: 0.2, tier: .possible)]),
            session: fixture.session)
    }
    let extractor = ReviewFakeExtractor()
    let review = try await ReviewSession(session: fixture.session, profiles: store, maintenance: nil,
                                         exportDelay: .seconds(60), extractor: extractor)
    #expect(review.learnVoices, "Remember voices is on, so the footer box starts on.")
    review.learnVoices = learn

    try await review.setName("Jim", speakerID: "system:S1")
    try await review.markSelf(speakerID: "system:S2")
    try await review.confirmAllSuggestions()
    try await review.assign(["T8"], to: .person(profileID: "MARIA"))
    await review.close()

    let sessionID = try SessionArchive.readManifest(at: fixture.session).id
    var samples: [String: Int] = [:]
    for person in try store.load().profiles {
        samples[person.isSelf ? "Me" : person.displayName] = person.samples.filter { $0.sessionID == sessionID }.count
    }
    return (extractor.turnIDs, samples)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func learnVoicesOffStoresNoSample() async throws {
    let result = try await reviewLearning(false)
    #expect(result.asked.isEmpty, "No turn is sent to the extractor when the box is off.")
    #expect(result.samples == ["Jim": 0, "Me": 0, "Sam": 0, "Maria": 0])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func learnVoicesOnStoresASampleForEachPersonNamed() async throws {
    let result = try await reviewLearning(true)
    // A reassigned turn never qualifies (§4.10), so Maria's T8 gives no sample either way.
    #expect(Set(result.asked) == ["T1", "T5", "T2", "T6", "T3", "T7"])
    #expect(result.samples == ["Jim": 1, "Me": 1, "Sam": 1, "Maria": 0])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedRelabelKeepsTheExportsPending() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let markdown = SessionPaths.export("md", in: fixture.session)
    // `holos session diarize` that could do nothing (exit 1) and wrote no export.
    let script = temp.url.appendingPathComponent("fake-holos.sh")
    try Data("#!/bin/sh\necho '{\"message\": \"Nothing could be done.\"}'\nexit 1\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let review = try await ReviewSession(session: fixture.session, profiles: nil,
                                         maintenance: MaintenanceLauncher(executable: script),
                                         exportDelay: .seconds(60))

    try await review.apply([.rename(speakerID: "system:S1", name: "Jim")])
    #expect(review.exportsPending)
    let failure = await #expect(throws: HolosError.self) { try await review.labelAgain() }
    #expect(failure?.errorDescription == "Nothing could be done.")
    #expect(review.exportsPending, "The relabel wrote no export, so the window's change still needs them.")
    #expect(!review.isRelabelling)

    await review.close()
    #expect(SessionFixtures.text(markdown).contains("**Jim**"))
    #expect(!review.exportsPending)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func assigningToAPersonCreatesALinkedSpeakerAsOneChange() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    try store.update { $0.profiles = [SpeakerProfile(id: "MARIA", displayName: "Maria")] }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session, store: store)

    try await review.assign(["T2"], to: .person(profileID: "MARIA"))
    let maria = try #require(review.projection.speakers.first { $0.profileID == "MARIA" })
    #expect(maria.id.hasPrefix("user:"))
    #expect(maria.name == "Maria")
    #expect(review.turn("T2")?.speakerID == maria.id)

    // Maria now has a speaker: assigning to her moves turns to it.
    try await review.assign(["T4"], to: .person(profileID: "MARIA"))
    #expect(review.turn("T4")?.speakerID == maria.id)

    try await review.undo()
    #expect(review.turn("T4")?.speakerID == "system:S2")
    try await review.undo()
    #expect(review.turn("T2")?.speakerID == "system:S2")
    #expect(!review.projection.speakers.contains { $0.profileID == "MARIA" })
    #expect(!review.canUndo)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func invalidChangeIsRefusedBeforeItIsQueued() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)
    let first = try #require(review.words(of: "T1").first)

    await #expect(throws: HolosError.self) { try await review.split(turnID: "T1", at: first.ref) }
    await #expect(throws: HolosError.self) { try await review.merge("system:S1", into: "system:S1") }
    await #expect(throws: HolosError.self) { try await review.apply([.rename(speakerID: "system:S9", name: "X")]) }
    // Assigning turns to the speaker they already have saves nothing.
    try await review.assign(["T1", "T3"], to: .speaker("system:S1"))
    #expect(SessionFixtures.journalBytes(fixture.session) == nil)
    #expect(!review.canUndo)
}

@Test func relabelArgumentsKeepTheRoomChoice() {
    let session = URL(fileURLWithPath: "/tmp/A.holos")
    #expect(ReviewSession.relabelArguments(session: session, force: true, minimumSpeakers: 4, othersInRoom: false)
        == ["session", "diarize", "/tmp/A.holos", "--force", "--min-speakers", "4", "--no-others-in-room", "--json"])
    #expect(ReviewSession.relabelArguments(session: session, force: true, minimumSpeakers: nil, othersInRoom: true)
        == ["session", "diarize", "/tmp/A.holos", "--force", "--others-in-room", "--json"])
    #expect(ReviewSession.relabelArguments(session: session, force: false, minimumSpeakers: nil, othersInRoom: nil)
        == ["session", "diarize", "/tmp/A.holos", "--json"])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func clearingAnAutomaticNameRejectsItsPerson() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")] }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    try SessionArchive.withSpeakerLock(at: fixture.session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: fixture.run.id, embeddingModel: DiarizationEngineInfo.fake.embeddingModel,
                              thresholds: SpeakerRecognizer.defaultThresholds,
                              matches: [SpeakerMatch(speakerID: "system:S1", profileID: "JIM", profileName: "Jim",
                                                     distance: 0.1, tier: .likely)]),
            session: fixture.session)
    }
    let review = try await reviewOpen(fixture.session, store: store)
    #expect(review.speaker("system:S1")?.isAutomatic == true)
    #expect(review.automaticProfileID(for: "system:S1") == "JIM")

    // An empty name on "Jim (auto)" is "Not Jim": the automatic name goes, in one change.
    try await review.setName("", speakerID: "system:S1")
    let speaker = try #require(review.speaker("system:S1"))
    #expect(!speaker.isAutomatic)
    #expect(speaker.name == "Speaker 1")
    #expect(speaker.rejectedProfileIDs == ["JIM"])
    #expect(review.snapshot.projection == review.projection)
    let edits = try reviewJournal(fixture.session)
    #expect(edits.map(\.action) == [.rename(speakerID: "system:S1", name: nil),
                                    .rejectProfile(speakerID: "system:S1", profileID: "JIM")])
    #expect(Set(edits.map { $0.batchID ?? $0.id }).count == 1)
    try await review.undo()
    #expect(review.speaker("system:S1")?.isAutomatic == true)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func maintenancePauseSavesEarlierChangesAndRefusesNewOnes() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let markdown = SessionPaths.export("md", in: fixture.session)
    let review = try await reviewOpen(fixture.session, exportDelay: .seconds(60))
    let gate = reviewGate()
    review.beforeEdit = gate.hook

    // A change is saving when Label Speakers starts from Meetings.
    let edit = Task { @MainActor in try await review.apply([.rename(speakerID: "system:S1", name: "Jim")]) }
    #expect(await eventually { gate.entered.value == 1 })
    let paused = SharedValue(false)
    let hold = ReviewMaintenance.Hold(.labelSpeakers)
    let pause = Task { @MainActor in
        await review.pause(hold, reason: "Holos is labelling this meeting's speakers.")
        paused.update { $0 = true }
    }
    // Read-only at once: a new change is refused, whatever the timing.
    #expect(await eventually { review.pauseReason != nil })
    #expect(!review.isEditable)
    let refusal = await #expect(throws: HolosError.self) {
        try await review.apply([.rename(speakerID: "system:S2", name: "Bob")])
    }
    #expect(refusal?.errorDescription?.hasSuffix(ReviewSession.pausedSuffix) == true)
    await #expect(throws: HolosError.self) { try await review.undo() }
    // The command waits until the earlier change is saved and the transcript files show it.
    try await Task.sleep(for: .milliseconds(200))
    #expect(!paused.value)
    gate.release.finish()
    try await edit.value
    await pause.value
    #expect(try reviewJournal(fixture.session).map(\.action) == [.rename(speakerID: "system:S1", name: "Jim")])
    #expect(SessionFixtures.text(markdown).contains("**Jim**"))
    #expect(!review.exportsPending)

    // Pausing again for the same command changes nothing; its end makes the review editable.
    await review.pause(hold, reason: "again")
    await review.resume(hold)
    #expect(review.pauseReason == nil)
    #expect(review.isEditable)
    try await review.apply([.rename(speakerID: "system:S2", name: "Bob")])
    #expect(reviewName(review, "system:S2") == "Bob")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func resumeRereadsTranscriptAndLabels() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    #expect(review.canUndo)
    #expect(review.words(of: "T1").count == 6)

    let hold = ReviewMaintenance.Hold(.recover)
    await review.pause(hold, reason: "Holos is recovering this meeting.")
    // Recover rebuilds the transcript and labels the speakers again, as `holos session recover` would.
    let rebuilt = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "system", wordsPerTurn: 4))
    try await SessionFixtures.saveTranscript(rebuilt, in: fixture.session)
    let newer = try SessionFixtures.writeHeadRun(session: fixture.session, transcript: rebuilt,
                                                 outputs: ["system": SessionFixtures.alternatingOutput()])
    // Nothing is reread while the command runs.
    #expect(review.projection.runID == fixture.run.id)

    await review.resume(hold)
    #expect(review.projection.runID == newer.id)
    #expect(review.snapshot.transcript.id == rebuilt.id)
    #expect(review.words(of: "T1").count == 4)
    #expect(!review.canUndo, "Undo does not reach past a new labelling.")
    #expect(review.isEditable)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func eachCommandRunHoldsTheReviewUntilItsOwnResume() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let review = try await reviewOpen(fixture.session)

    // Two runs of the same command overlap: the second starts before the first one's end is handled.
    let first = ReviewMaintenance.Hold(.labelSpeakers)
    let second = ReviewMaintenance.Hold(.labelSpeakers)
    await review.pause(first, reason: "first")
    await review.pause(second, reason: "second")
    await review.resume(first)
    #expect(review.pauseReason == "second", "The first run's end does not release the second run.")
    #expect(!review.isEditable)
    await #expect(throws: HolosError.self) {
        try await review.apply([.rename(speakerID: "system:S1", name: "Jim")])
    }
    await review.resume(first)
    #expect(!review.isEditable, "Resuming a run twice changes nothing.")
    await review.resume(second)
    #expect(review.pauseReason == nil)
    #expect(review.isEditable)

    // The next run starts while the previous run's resume is still rereading the meeting.
    let third = ReviewMaintenance.Hold(.recover)
    let fourth = ReviewMaintenance.Hold(.deleteAudio)
    await review.pause(third, reason: "third")
    let resuming = Task { @MainActor in await review.resume(third) }
    // Lets the resume start its reread (it waits off the main actor) before the next run pauses.
    for _ in 0..<5 { await Task.yield() }
    await review.pause(fourth, reason: "fourth")
    await resuming.value
    #expect(review.pauseReason == "fourth")
    #expect(!review.isEditable, "A run started during an earlier run's resume keeps the review read-only.")
    await review.resume(fourth)
    #expect(review.isEditable)
    try await review.apply([.rename(speakerID: "system:S1", name: "Jim")])
    #expect(reviewName(review, "system:S1") == "Jim")
}

@Test func peopleComeFromOneReadOfTheStore() {
    let older = SpeakerProfileDatabase(rememberVoices: false, profiles: [SpeakerProfile(id: "P1", displayName: "Old")])
    let newer = SpeakerProfileDatabase(rememberVoices: true, profiles: [
        SpeakerProfile(id: "P1", displayName: "New"), SpeakerProfile(id: "P2", displayName: "Other"),
    ])
    // Every further read sees the store as rewritten meanwhile (by People or the CLI).
    var reads = 0
    let known = ReviewSession.people {
        reads += 1
        return reads == 1 ? older : newer
    }
    #expect(reads == 1)
    #expect(known.people.map(\.id) == ["P1"])
    #expect(known.people.map(\.displayName) == ["Old"])
    #expect(known.names == ["P1": "Old"])
    #expect(!known.remember)

    struct Unreadable: Error {}
    let none = ReviewSession.people { throw Unreadable() }
    #expect(none.people.isEmpty && none.names.isEmpty && !none.remember)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func exportsNotWrittenAtCloseStayPendingForTheNextReview() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let markdown = SessionPaths.export("md", in: fixture.session)
    // Something in the way of transcript.md (a full disk would fail the same way).
    try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: true)

    let first = try await reviewOpen(fixture.session)
    try await first.apply([.rename(speakerID: "system:S1", name: "Jim")])
    await first.close()
    #expect(first.exportsPending, "The caller learns that the files were not rewritten.")
    #expect(first.exportProblem != nil)

    // The next review of the meeting is told (PendingExports) and rewrites them without any new change.
    try FileManager.default.removeItem(at: markdown)
    let second = try await reviewOpen(fixture.session, exportDelay: .milliseconds(100))
    #expect(!second.exportsPending)
    second.markExportsPending()
    #expect(second.exportsPending)
    #expect(await eventually { SessionFixtures.text(markdown).contains("**Jim**") })
    await second.close()
    #expect(!second.exportsPending)
    #expect(second.exportProblem == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func sessionWithoutLabelsDoesNotOpen() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "system"))
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 20],
                                                        mode: .call, transcript: transcript)
    await #expect(throws: HolosError.self) { _ = try await reviewOpen(session) }
}

// MARK: - Failed saves and rereads

/// Makes `url` read-only (a journal that cannot be appended to) or writable again.
private func reviewSetWritable(_ url: URL, _ writable: Bool) {
    try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o600 : 0o400], ofItemAtPath: url.path)
}

/// Makes the session's event journal unreadable (read when labels are loaded, not when a change is saved), so a
/// change is saved and its labels cannot be reread; or readable again.
private func reviewBlockRereads(_ session: URL, _ blocked: Bool) {
    let events = SessionPaths.events(session)
    var isFolder: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: events.path, isDirectory: &isFolder)
    if blocked {
        if exists {
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: events.path)
        } else {
            try? FileManager.default.createDirectory(at: events, withIntermediateDirectories: false)
        }
    } else if exists {
        if isFolder.boolValue {
            try? FileManager.default.removeItem(at: events)
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: events.path)
        }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedUndoKeepsTheChangeUndoable() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let journal = SessionPaths.edits(fixture.session)
    let review = try await reviewOpen(fixture.session)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    try await review.apply([.rename(speakerID: "system:S2", name: "Bob")])

    // The journal cannot be written for a moment: the undo saves nothing.
    reviewSetWritable(journal, false)
    await #expect(throws: HolosError.self) { try await review.undo() }
    reviewSetWritable(journal, true)
    #expect(try reviewJournal(fixture.session).count == 2)
    #expect(reviewName(review, "system:S2") == "Bob", "The change is still saved, so it is still shown.")
    #expect(review.canUndo, "and it can still be undone.")
    #expect(review.snapshot.projection == review.projection)

    // Undo takes back the same change, then the one before it, in order.
    try await review.undo()
    #expect(reviewName(review, "system:S2") == "Speaker 2")
    #expect(reviewName(review, "system:S1") == "Ann")
    try await review.undo()
    #expect(reviewName(review, "system:S1") == "Speaker 1")
    #expect(!review.canUndo)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedUndoOfATwoBatchChangeCanBeFinished() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    try store.update { $0.profiles = [SpeakerProfile(id: "MARIA", displayName: "Maria")] }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let journal = SessionPaths.edits(fixture.session)
    let review = try await reviewOpen(fixture.session, store: store)
    // One change, two batches: a new speaker for T2, then its link to Maria.
    try await review.assign(["T2"], to: .person(profileID: "MARIA"))
    #expect(Set(try reviewJournal(fixture.session).compactMap(\.batchID)).count == 2)

    // The first revert is saved; the journal then refuses the second.
    let saves = SharedValue(0)
    review.beforeEdit = {
        if saves.update({ $0 += 1; return $0 }) == 2 { reviewSetWritable(journal, false) }
    }
    await #expect(throws: HolosError.self) { try await review.undo() }
    reviewSetWritable(journal, true)
    review.beforeEdit = nil
    #expect(!review.projection.speakers.contains { $0.profileID == "MARIA" }, "The link was taken back.")
    #expect(review.turn("T2")?.speakerID?.hasPrefix("user:") == true, "The new speaker is still saved.")
    #expect(review.canUndo)
    #expect(review.snapshot.projection == review.projection)

    // Undo finishes the job.
    try await review.undo()
    #expect(review.turn("T2")?.speakerID == "system:S2")
    #expect(!review.projection.speakers.contains { $0.id.hasPrefix("user:") })
    #expect(!review.canUndo)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedUndoOfASavingChangeShowsItAgain() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let journal = SessionPaths.edits(fixture.session)
    let review = try await reviewOpen(fixture.session)
    // The change is held back while saving; the undo made meanwhile then cannot write its revert.
    let (stream, release) = AsyncStream<Void>.makeStream()
    let saves = SharedValue(0)
    review.beforeEdit = {
        let call = saves.update { $0 += 1; return $0 }
        if call == 1 { for await _ in stream {} }
        if call == 2 { reviewSetWritable(journal, false) }
    }

    let edit = Task { @MainActor in try await review.apply([.rename(speakerID: "system:S1", name: "Ann")]) }
    #expect(await eventually { saves.value == 1 })
    let undo = Task { @MainActor in try await review.undo() }
    #expect(await eventually { reviewName(review, "system:S1") == "Speaker 1" })
    release.finish()
    try await edit.value
    await #expect(throws: HolosError.self) { try await undo.value }
    reviewSetWritable(journal, true)
    review.beforeEdit = nil

    #expect(try reviewJournal(fixture.session).map(\.action) == [.rename(speakerID: "system:S1", name: "Ann")])
    #expect(reviewName(review, "system:S1") == "Ann", "The saved change is shown again.")
    #expect(review.canUndo)
    try await review.undo()
    #expect(reviewName(review, "system:S1") == "Speaker 1")
    #expect(!review.canUndo)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func savedChangeThatCannotBeRereadMakesTheReviewReadOnly() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let session = fixture.session
    let review = try await reviewOpen(session)
    // Rereads fail from just before the save: the line is appended, and the labels cannot be reread.
    review.beforeEdit = { reviewBlockRereads(session, true) }
    defer { reviewBlockRereads(session, false) }

    let failure = await #expect(throws: HolosError.self) {
        try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    }
    review.beforeEdit = nil
    if case .incomplete? = failure {} else { Issue.record("Expected incomplete, got \(String(describing: failure))") }
    #expect(try reviewJournal(fixture.session).map(\.action) == [.rename(speakerID: "system:S1", name: "Ann")])
    #expect(reviewName(review, "system:S1") == "Ann", "The saved change stays shown.")
    #expect(review.snapshot.projection?.speakers.first { $0.id == "system:S1" }?.name == "Speaker 1")
    #expect(review.reloadProblem != nil)
    #expect(!review.isEditable)
    await #expect(throws: HolosError.self) { try await review.apply([.rename(speakerID: "system:S2", name: "Bob")]) }
    await #expect(throws: HolosError.self) { try await review.undo() }

    // A reread that fails keeps it read-only.
    await review.reload()
    #expect(review.reloadProblem != nil)
    #expect(reviewName(review, "system:S1") == "Ann")

    // A reread that works shows the saved labels, and the change is the window's again.
    reviewBlockRereads(session, false)
    await review.reload()
    #expect(review.reloadProblem == nil)
    #expect(review.isEditable)
    #expect(review.snapshot.projection == review.projection)
    #expect(reviewName(review, "system:S1") == "Ann")
    #expect(review.changeCount == 1)
    #expect(review.canUndo)
    try await review.undo()
    #expect(reviewName(review, "system:S1") == "Speaker 1")
    #expect(!review.canUndo)
}

// MARK: - People renamed while the review is open

@Test(.timeLimit(.minutes(1))) @MainActor
func reloadsRereadPeopleBeforeTheLabels() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let store = reviewStore(temp)
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")] }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    try SessionArchive.withSpeakerLock(at: fixture.session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: fixture.run.id, embeddingModel: DiarizationEngineInfo.fake.embeddingModel,
                              thresholds: SpeakerRecognizer.defaultThresholds,
                              matches: [SpeakerMatch(speakerID: "system:S1", profileID: "JIM", profileName: "Jim",
                                                     distance: 0.1, tier: .likely)]),
            session: fixture.session)
    }
    let review = try await reviewOpen(fixture.session, store: store)
    #expect(review.speaker("system:S1")?.name == "Jim")

    // The People window renames him; the review rereads (a reload from Meetings).
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "James")] }
    await review.reload()
    #expect(review.knownPeople().map(\.displayName) == ["James"])
    #expect(review.speaker("system:S1")?.name == "James", "The automatic name follows the people just reread.")
    #expect(review.speaker("system:S1")?.isAutomatic == true)

    // Renamed again: the labels a saved change brings back are built with the new name too.
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jimmy")] }
    try await review.apply([.rename(speakerID: "system:S2", name: "Bob")])
    #expect(review.knownPeople().map(\.displayName) == ["Jimmy"])
    #expect(review.speaker("system:S1")?.name == "Jimmy")
    #expect(review.snapshot.projection == review.projection)
}
