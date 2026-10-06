import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import os
import Testing

// Voices within one meeting (docs/meeting-design.md §4.10): the review window's in-memory voice cache, its matches
// after a name is given, and voice learning off the edit queue. Helpers are prefixed `voice`.

// MARK: - Helpers

/// A gate a fake extractor waits at until `open`, or until its task is cancelled.
private final class VoiceGate: Sendable {
    private struct State {
        var open = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(open: Bool = false) { state.withLock { $0.open = open } }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    guard !state.open, !Task.isCancelled else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

/// An extractor that gives each turn the voice `voices` names (none for others), records each call's turn IDs, and
/// waits at `gate` first; a call cancelled while it waits is counted and throws `CancellationError`.
private final class VoiceFakeExtractor: VoiceSampleExtractor {
    let voices: [String: [Float]]
    let gate: VoiceGate
    let calls = SharedValue<[[String]]>([])
    let cancelled = SharedValue(0)

    init(voices: [String: [Float]], gate: VoiceGate = VoiceGate(open: true)) {
        self.voices = voices; self.gate = gate
    }

    var callCount: Int { calls.value.count }

    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        calls.update { $0.append(turns.map(\.id)) }
        await gate.wait()
        if Task.isCancelled {
            cancelled.update { $0 += 1 }
            throw CancellationError()
        }
        return turns.compactMap { turn in
            voices[turn.id].map {
                TurnEmbedding(turnID: turn.id, speechSeconds: turn.end - turn.start,
                              vector: FloatVector(VectorMath.normalized($0)))
            }
        }
    }
}

private let voiceJim: [Float] = [1, 0, 0, 0]
private let voiceA: [Float] = [0, 1, 0, 0]
private let voiceB: [Float] = [0, 0, 1, 0]

/// Turns T1, T2, … of S1…S4 in turn (the fixture's 5 s slots, 3 s of words each). S1 and S3 are one voice (Jim's,
/// split by the diarizer); S2 is someone else except T10, which sounds like Jim; S4 is a third person.
private let voiceMap: [String: [Float]] = {
    var map: [String: [Float]] = [:]
    for index in 1...40 {
        switch (index - 1) % 4 {
        case 0, 2: map["T\(index)"] = voiceJim
        case 1: map["T\(index)"] = index == 10 ? voiceJim : voiceA
        default: map["T\(index)"] = voiceB
        }
    }
    return map
}()

private func voiceStore(_ temp: TemporaryDirectory, remember: Bool = true) throws -> SpeakerProfileStore {
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
    try store.update { $0.chooseRememberVoices(remember) }
    return store
}

@MainActor
private func voiceOpen(_ session: URL, store: SpeakerProfileStore?, extractor: VoiceFakeExtractor,
                       analyse: Bool = true, sampleDelay: Duration = .zero) async throws -> ReviewSession {
    try await ReviewSession(session: session, profiles: store, maintenance: nil, exportDelay: .seconds(60),
                            extractor: extractor, analyseVoices: analyse, sampleDelay: sampleDelay)
}

/// Polls `condition` on the main actor, yielding between tries, for at most `budget` tries (no wall-clock bound; the
/// test's time limit is the backstop).
@MainActor
private func voiceWait(_ what: String, budget: Int = 20_000, _ condition: () -> Bool) async throws {
    for _ in 0..<budget {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Gave up waiting: \(what)")
    throw CancellationError()
}

private func voiceSamples(_ store: SpeakerProfileStore, named name: String) throws -> Int {
    try store.load().profiles.first { $0.displayName == name }?.samples.count ?? 0
}

private let s1 = "system:S1"
private let s2 = "system:S2"
private let s3 = "system:S3"
private let s4 = "system:S4"

// MARK: - Cache

@Test(.timeLimit(.minutes(1)))
func theCacheServesCoveredTurnsOfTheHeadRunAndFallsBackOtherwise() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let turns = try SessionFixtures.view(fixture.session).turns.map(TurnRef.init)
    let cache = MeetingVoiceCache()
    let fallback = VoiceFakeExtractor(voices: voiceMap)
    let extractor = CachedVoiceSampleExtractor(cache: cache, fallback: fallback)

    let epoch = cache.begin(session: fixture.session, runID: fixture.run.id)
    // T2 had no clean speech in the pass: covered, without an embedding.
    cache.store([TurnEmbedding(turnID: "T1", speechSeconds: 5, vector: FloatVector(voiceJim))],
                asked: Array(turns.prefix(2)), track: "system", epoch: epoch)
    cache.finish(epoch: epoch)

    let served = try await extractor.turnEmbeddings(session: fixture.session, track: "system",
                                                    turns: Array(turns.prefix(2)))
    #expect(served.map(\.turnID) == ["T1"])
    #expect(fallback.callCount == 0, "Every turn asked about was covered: no pass of its own.")

    _ = try await extractor.turnEmbeddings(session: fixture.session, track: "system", turns: Array(turns.prefix(3)))
    #expect(fallback.calls.value == [["T1", "T2", "T3"]], "T3 was not covered: the whole request falls back.")

    var trimmed = turns[0]
    trimmed.end -= 1
    _ = try await extractor.turnEmbeddings(session: fixture.session, track: "system", turns: [trimmed])
    #expect(fallback.callCount == 2, "A turn whose times changed (a split) is not served.")

    _ = try await extractor.turnEmbeddings(session: fixture.session, track: "mic", turns: [turns[0]])
    #expect(fallback.callCount == 3, "Another track is not served.")

    // Another run's voices are never served for this one.
    let other = cache.begin(session: fixture.session, runID: "ANOTHER-RUN")
    cache.store([TurnEmbedding(turnID: "T1", speechSeconds: 5, vector: FloatVector(voiceJim))],
                asked: [turns[0]], track: "system", epoch: other)
    cache.finish(epoch: other)
    _ = try await extractor.turnEmbeddings(session: fixture.session, track: "system", turns: [turns[0]])
    #expect(fallback.callCount == 4)
    #expect(cache.embeddings(runID: fixture.run.id).isEmpty)

    cache.clear()
    #expect(cache.coveredTurns == 0 && cache.embeddings(runID: "ANOTHER-RUN").isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aLateStoreOfAnEarlierPassIsIgnored() {
    let cache = MeetingVoiceCache()
    let session = URL(fileURLWithPath: "/tmp/voice-cache.holos")
    let first = cache.begin(session: session, runID: "RUN")
    let second = cache.begin(session: session, runID: "RUN")
    cache.store([TurnEmbedding(turnID: "T1", speechSeconds: 5, vector: FloatVector(voiceJim))],
                asked: [TurnRef(id: "T1", start: 0, end: 5)], track: "system", epoch: first)
    #expect(cache.coveredTurns == 0)
    cache.store([TurnEmbedding(turnID: "T1", speechSeconds: 5, vector: FloatVector(voiceJim))],
                asked: [TurnRef(id: "T1", start: 0, end: 5)], track: "system", epoch: second)
    #expect(cache.embeddings(runID: "RUN").keys.sorted() == ["T1"])
}

@Test(.timeLimit(.minutes(1)))
func aLearnerWaitsForThePassOrStopsWhenCancelled() async throws {
    let cache = MeetingVoiceCache()
    let session = URL(fileURLWithPath: "/tmp/voice-cache.holos")
    let epoch = cache.begin(session: session, runID: "RUN")
    #expect(cache.isComputing)
    let finished = SharedValue(false)
    let waiter = Task {
        await cache.waitForPass()
        finished.set(true)
    }
    for _ in 0..<50 { await Task.yield() }
    #expect(!finished.value, "The pass is still running.")
    cache.finish(epoch: epoch)
    await waiter.value
    #expect(finished.value)

    _ = cache.begin(session: session, runID: "RUN")
    let cancelledWaiter = Task { await cache.waitForPass() }
    cancelledWaiter.cancel()
    await cancelledWaiter.value
    #expect(cache.isComputing, "Cancelling a learner leaves the pass running.")
}

// MARK: - Matches in the review

@Test(.timeLimit(.minutes(1))) @MainActor
func namingASpeakerSuggestsTheSpeakersWithItsVoice() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3", "S4"],
                                                            duration: 60)
    let extractor = VoiceFakeExtractor(voices: voiceMap)
    let review = try await voiceOpen(fixture.session, store: store, extractor: extractor)
    try await voiceWait("the voices") { review.voiceAnalysis == .ready }
    #expect(extractor.calls.value.map { Set($0) } == [Set((1...12).map { "T\($0)" })],
            "One pass over every turn of the track.")
    #expect(review.suggestionCount == 0, "Nobody is named yet.")

    try await review.setName("Jim", speakerID: s1)
    let suggestion = review.suggestion(for: s3)
    #expect(suggestion?.profileName == "Jim")
    #expect(review.voiceSuggestion(for: s3)?.anchorSpeakerID == s1)
    #expect(review.suggestion(for: s2) == nil && review.suggestion(for: s4) == nil)
    #expect(review.suggestionCount == 1)
    #expect(review.turnHint("T10")?.speakerID == s1, "T10 sounds like Jim inside S2.")
    #expect(review.turnHint("T10")?.name == "Jim")
    #expect(review.turnHint("T2") == nil)

    await review.close()
    #expect(try voiceSamples(store, named: "Jim") == 1, "Jim's voice was learned…")
    #expect(extractor.callCount == 1, "…from the cached pass, with no pass of its own.")
    #expect(review.voiceMatches == .empty && review.voiceCache.coveredTurns == 0, "Closing drops the voices.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func notJimOnAVoiceSuggestionIsSavedAndConfirmAllTakesTheRest() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3", "S4"],
                                                            duration: 60)
    let review = try await voiceOpen(fixture.session, store: store,
                                     extractor: VoiceFakeExtractor(voices: voiceMap))
    try await voiceWait("the voices") { review.voiceAnalysis == .ready }
    try await review.setName("Jim", speakerID: s1)
    #expect(review.suggestion(for: s3) != nil)

    try await review.rejectSuggestion(speakerID: s3)
    let jim = try #require(try store.load().profiles.first { $0.displayName == "Jim" })
    let rejected = try SessionSpeakerStore.readEdits(session: fixture.session).edits.contains {
        $0.action == .rejectProfile(speakerID: s3, profileID: jim.id)
    }
    #expect(rejected, "Not Jim is saved in the meeting, so it lasts.")
    #expect(review.suggestion(for: s3) == nil, "…and Jim is not suggested again.")

    try await review.undo()
    #expect(review.suggestion(for: s3)?.profileID == jim.id)
    try await review.confirmAllSuggestions()
    #expect(review.speaker(s3)?.profileID == jim.id, "Confirm All links the voice suggestion.")
    #expect(review.suggestionCount == 0)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aTurnHintGivesTheTurnToTheNamedSpeaker() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp, remember: false)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3", "S4"],
                                                            duration: 60)
    let review = try await voiceOpen(fixture.session, store: store,
                                     extractor: VoiceFakeExtractor(voices: voiceMap))
    try await voiceWait("the voices") { review.voiceAnalysis == .ready }
    try await review.setName("Jim", speakerID: s1)
    try await review.acceptTurnHint("T10")
    #expect(review.turn("T10")?.speakerID == s1)
    #expect(review.turnHint("T10") == nil)
    await #expect(throws: HolosError.self) { try await review.acceptTurnHint("T2") }
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func matchingVoicesAreMergedOnlyWhenAsked() async throws {
    for automatic in [false, true] {
        let temp = try TemporaryDirectory("voice")
        defer { temp.remove() }
        let store = try voiceStore(temp, remember: false)
        // Five turns of 3 s each: enough speech (10 s) on both sides to merge without asking.
        let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3", "S4"],
                                                                duration: 100)
        let review = try await voiceOpen(fixture.session, store: store,
                                         extractor: VoiceFakeExtractor(voices: voiceMap))
        review.autoMergeVoices = automatic
        try await voiceWait("the voices") { review.voiceAnalysis == .ready }
        try await review.setName("Jim", speakerID: s1)
        if automatic {
            try await voiceWait("the merge") { review.speaker(s3) == nil && !review.isWorking }
            #expect(review.turn("T3")?.speakerID == s1)
            #expect(review.turn("T3")?.excludedFromEnrollment == true,
                    "Nobody confirmed the merged turns, so they are kept out of Jim's voice sample.")
            #expect(review.turn("T1")?.excludedFromEnrollment == false)
            try await review.undo()
            #expect(review.speaker(s3) != nil, "One undo takes the merge back.")
        } else {
            for _ in 0..<50 { await Task.yield() }
            #expect(review.speaker(s3) != nil, "Off: only suggested.")
            #expect(review.voiceSuggestion(for: s3)?.mergeable == true)
        }
        await review.close()
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nothingIsSuggestedWhileTheJournalHasAnUnreadableLine() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp, remember: false)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3", "S4"],
                                                            duration: 60)
    let review = try await voiceOpen(fixture.session, store: store, extractor: VoiceFakeExtractor(voices: voiceMap))
    try await voiceWait("the voices") { review.voiceAnalysis == .ready }
    try await review.setName("Jim", speakerID: s1)
    #expect(review.suggestionCount == 1)

    let journal = try FileHandle(forWritingTo: SessionPaths.edits(fixture.session))
    try journal.seekToEnd()
    try journal.write(contentsOf: Data("{\"schemaVersion\": 99, \"something\": \"newer\"}\n".utf8))
    try journal.close()
    await review.reload()
    #expect(!review.snapshot.journal.isComplete)
    #expect(review.suggestionCount == 0 && review.turnHint("T10") == nil,
            "A line this build cannot read may be a rejection or a reassignment the matches would contradict.")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aVoiceAskedForBeforeAForgetIsNotLearned() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let extractor = VoiceFakeExtractor(voices: voiceMap)
    let review = try await voiceOpen(fixture.session, store: store, extractor: extractor, analyse: false,
                                     sampleDelay: .seconds(3600))
    try await review.setName("Jim", speakerID: s1)
    // People forgets voices (another window) before the delay is up.
    try store.update { $0.forgetEpoch = ($0.forgetEpoch ?? 0) + 1 }
    await review.close()
    #expect(try voiceSamples(store, named: "Jim") == 0, "The forget came later, so it wins.")
    #expect(review.voiceProblem?.contains("forgotten") == true)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anUndoneOrNewerLinkTakesBackAVoiceNotLearnedYet() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let review = try await voiceOpen(fixture.session, store: store, extractor: VoiceFakeExtractor(voices: voiceMap),
                                     analyse: false, sampleDelay: .seconds(3600))
    try await review.setName("Jim", speakerID: s1)
    try await review.undo()
    review.learnVoices = false
    try await review.setName("Jim", speakerID: s1)
    #expect(review.speaker(s1)?.name == "Jim")
    await review.close()
    #expect(try voiceSamples(store, named: "Jim") == 0,
            "The link that asked for the voice was undone; the one saved with learning off does not learn it.")

    // Without the undo, a newer link with learning off withdraws the request too.
    let other = try await voiceOpen(fixture.session, store: store, extractor: VoiceFakeExtractor(voices: voiceMap),
                                    analyse: false, sampleDelay: .seconds(3600))
    other.learnVoices = true
    try await other.setName("Sam", speakerID: s2)
    other.learnVoices = false
    try await other.setName("", speakerID: s2)
    try await other.setName("Sam", speakerID: s2)
    await other.close()
    #expect(try voiceSamples(store, named: "Sam") == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func undoingOneLinkKeepsAnotherLinksRequestToLearnTheVoice() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let review = try await voiceOpen(fixture.session, store: store, extractor: VoiceFakeExtractor(voices: voiceMap),
                                     analyse: false, sampleDelay: .seconds(3600))
    try await review.setName("Jim", speakerID: s1)
    try await review.setName("Jim", speakerID: s2)
    try await review.undo()
    #expect(review.speaker(s2)?.profileID == nil && review.speaker(s1)?.profileID != nil)
    await review.close()
    #expect(try voiceSamples(store, named: "Jim") == 1, "S1's link still asks for Jim's voice.")
}

@Test(.timeLimit(.minutes(1)))
func aDeferredLinkRecordsWhoItLinkedAndLearnsNothing() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let extractor = VoiceFakeExtractor(voices: voiceMap)
    let deferred = DeferredSamples()
    #expect(deferred.linkedPeople == nil)
    _ = try await VoiceProfileService.link(session: fixture.session, speakerID: s1, to: .new(name: "Jim"),
                                           view: try SessionFixtures.view(fixture.session), learnVoice: true,
                                           extractor: extractor, store: store, deferSamples: deferred)
    let jim = try #require(try store.load().profiles.first { $0.displayName == "Jim" })
    #expect(deferred.linkedPeople == [jim.id])
    #expect(extractor.callCount == 0 && jim.samples.isEmpty, "The caller learns the voice afterwards.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func noVoicesAreWorkedOutUnlessAsked() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let extractor = VoiceFakeExtractor(voices: voiceMap)
    let review = try await voiceOpen(fixture.session, store: try voiceStore(temp), extractor: extractor,
                                     analyse: false)
    for _ in 0..<50 { await Task.yield() }
    #expect(review.voiceAnalysis == .off)
    #expect(extractor.callCount == 0)
    await review.close()
}

// MARK: - Voice learning off the edit queue

@Test(.timeLimit(.minutes(1))) @MainActor
func aNameIsSavedWhileItsVoiceIsStillBeingLearned() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let gate = VoiceGate()
    let extractor = VoiceFakeExtractor(voices: voiceMap, gate: gate)
    let review = try await voiceOpen(fixture.session, store: store, extractor: extractor, analyse: false)

    try await review.setName("Jim", speakerID: s1)
    #expect(review.speaker(s1)?.profileID != nil, "The name is saved without waiting for the voice.")
    try await voiceWait("the sync to start") { extractor.callCount == 1 }
    #expect(review.isSyncingSamples)
    #expect(try voiceSamples(store, named: "Jim") == 0)
    // The window stays editable meanwhile.
    try await review.apply([.rename(speakerID: s2, name: "Sam")])
    #expect(review.speaker(s2)?.name == "Sam")

    gate.open()
    try await voiceWait("the sample") { !review.isSyncingSamples && (try? voiceSamples(store, named: "Jim")) == 1 }
    #expect(review.voiceProblem == nil)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aNewerChangeStopsAVoiceBeingLearnedAndItIsLearnedAfter() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let gate = VoiceGate()
    let extractor = VoiceFakeExtractor(voices: voiceMap, gate: gate)
    let review = try await voiceOpen(fixture.session, store: store, extractor: extractor, analyse: false)

    try await review.setName("Jim", speakerID: s1)
    try await voiceWait("the first sync") { extractor.callCount == 1 }
    try await review.apply([.rename(speakerID: s2, name: "Sam")])
    try await voiceWait("the first sync to stop") { extractor.cancelled.value == 1 }
    try await voiceWait("the sync after the change") { extractor.callCount == 2 }
    gate.open()
    try await voiceWait("the sample") { !review.isSyncingSamples && (try? voiceSamples(store, named: "Jim")) == 1 }
    #expect(extractor.cancelled.value == 1)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func closingLearnsAVoiceStillWaitingForItsDelay() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let extractor = VoiceFakeExtractor(voices: voiceMap)
    let review = try await voiceOpen(fixture.session, store: store, extractor: extractor, analyse: false,
                                     sampleDelay: .seconds(3600))
    try await review.markSelf(speakerID: s1)
    #expect(extractor.callCount == 0, "Still waiting for the delay.")
    await review.close()
    #expect(extractor.callCount == 1)
    #expect(try store.load().profiles.first(where: \.isSelf)?.samples.count == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aSampleSyncThatFailsSaysSoAndKeepsTheName() async throws {
    struct Broken: VoiceSampleExtractor {
        func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
            throw HolosError.unavailable("The speaker models are missing.")
        }
    }
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let review = try await ReviewSession(session: fixture.session, profiles: store, maintenance: nil,
                                         exportDelay: .seconds(60), extractor: Broken(), sampleDelay: .zero)
    try await review.setName("Jim", speakerID: s1)
    try await voiceWait("the failure") { review.voiceProblem != nil }
    #expect(review.voiceProblem?.contains("The name was saved, but the voice could not be learned") == true)
    #expect(review.speaker(s1)?.name == "Jim")
    await review.close()
}

/// Gives each turn a voice by its 5 s slot (slots 0 and 2 of every 4 are Jim's, as `voiceMap`), and fails on the
/// `failing` track.
private struct VoiceSlotExtractor: VoiceSampleExtractor {
    let failing: String?

    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        if track == failing { throw HolosError.unavailable("The \(track) track could not be read.") }
        return turns.map { turn in
            let voice: [Float] = switch Int((turn.start / 5).rounded(.down)) % 4 {
            case 0, 2: voiceJim
            case 1: voiceA
            default: voiceB
            }
            return TurnEmbedding(turnID: turn.id, speechSeconds: turn.end - turn.start,
                                 vector: FloatVector(VectorMath.normalized(voice)))
        }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aPassThatFailsOnOneTrackMatchesNothing() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let store = try voiceStore(temp)
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "system", duration: 60)
        + SessionFixtures.alternatingSegments(track: "mic", duration: 60))
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 60, "system": 60], mode: .call,
                                                        othersInRoom: true, transcript: transcript)
    let speakers = FakeDiarizer.alternating(speakers: ["S1", "S2", "S3", "S4"], turnSeconds: 5, duration: 60)
    _ = try SessionFixtures.writeHeadRun(session: session, transcript: transcript,
                                         outputs: ["mic": speakers, "system": speakers])

    // Both tracks worked: naming S1 suggests S3, which has the same voice.
    let working = try await ReviewSession(session: session, profiles: store, maintenance: nil,
                                          exportDelay: .seconds(60), extractor: VoiceSlotExtractor(failing: nil),
                                          analyseVoices: true, sampleDelay: .seconds(3600))
    try await voiceWait("the voices") { working.voiceAnalysis == .ready }
    try await working.setName("Jim", speakerID: s1)
    #expect(working.suggestion(for: s3)?.profileName == "Jim")
    try await working.undo()
    await working.close()

    // The mic pass failed: nothing is matched on the system track either, and the footer says why.
    let review = try await ReviewSession(session: session, profiles: store, maintenance: nil,
                                         exportDelay: .seconds(60), extractor: VoiceSlotExtractor(failing: "mic"),
                                         analyseVoices: true, sampleDelay: .seconds(3600))
    try await voiceWait("the pass to end") {
        if case .failed = review.voiceAnalysis { return true }
        return review.voiceAnalysis == .ready
    }
    #expect(review.voiceAnalysis == .failed("The mic track could not be read."))
    try await review.setName("Jim", speakerID: s1)
    #expect(review.voiceMatches == .empty)
    #expect(review.suggestion(for: s3) == nil)
    await review.close()
}

/// Fails with "The speaker models are missing." while `broken`, else gives each turn the voice `voiceMap` names.
private final class VoiceFlakyExtractor: VoiceSampleExtractor {
    let broken: SharedValue<Bool>
    let working = VoiceFakeExtractor(voices: voiceMap)

    init(broken: Bool) { self.broken = SharedValue(broken) }

    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        if broken.value { throw HolosError.unavailable("The speaker models are missing.") }
        return try await working.turnEmbeddings(session: session, track: track, turns: turns)
    }
}

/// A `PendingVoiceSamples` of its own (removed by `done`).
private func voicePending() -> (pending: PendingVoiceSamples, done: () -> Void) {
    let name = "holos-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (PendingVoiceSamples(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aVoiceThatFailsWhileTheReviewClosesIsLearnedWhenItOpensAgain() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let (pending, done) = voicePending()
    defer { done() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let sessionID = try SessionArchive.readManifest(at: fixture.session).id
    let extractor = VoiceFlakyExtractor(broken: true)

    let first = try await ReviewSession(session: fixture.session, profiles: store, maintenance: nil,
                                        exportDelay: .seconds(60), extractor: extractor,
                                        sampleDelay: .seconds(3600), pendingVoices: pending)
    try await first.setName("Jim", speakerID: s1)
    let jim = try #require(first.speaker(s1)?.profileID)
    #expect(pending.entry(sessionID) == nil, "Nothing is recorded while the sync can still run in this window.")
    // The sync still owed runs as the window closes, and fails where nobody sees the footer.
    await first.close()
    #expect(try voiceSamples(store, named: "Jim") == 0)
    let epoch = try store.load().forgetEpoch ?? 0
    #expect(pending.entry(sessionID) == PendingVoiceSamples.Entry(enroll: [jim: epoch],
                                                                   problem: "The speaker models are missing."))

    // The next review says so and learns the voice.
    extractor.broken.set(false)
    let second = try await ReviewSession(session: fixture.session, profiles: store, maintenance: nil,
                                         exportDelay: .seconds(60), extractor: extractor,
                                         sampleDelay: .seconds(3600), pendingVoices: pending)
    #expect(second.voiceProblem?.contains("When this meeting's review last closed, a voice could not be learned")
        == true)
    #expect(second.voiceProblem?.contains("The speaker models are missing.") == true)
    await second.close()
    #expect(try voiceSamples(store, named: "Jim") == 1)
    #expect(second.voiceProblem == nil)
    #expect(pending.entry(sessionID) == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aVoiceStoppedByQuittingIsTriedAgainAndAFailureThenShows() async throws {
    let temp = try TemporaryDirectory("voice")
    defer { temp.remove() }
    let (pending, done) = voicePending()
    defer { done() }
    let store = try voiceStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 20)
    let sessionID = try SessionArchive.readManifest(at: fixture.session).id
    let extractor = VoiceFlakyExtractor(broken: false)

    let first = try await ReviewSession(session: fixture.session, profiles: store, maintenance: nil,
                                        exportDelay: .seconds(60), extractor: extractor,
                                        sampleDelay: .seconds(3600), pendingVoices: pending)
    try await first.markSelf(speakerID: s1)
    let me = try #require(first.speaker(s1)?.profileID)
    // Quitting gave up waiting for the review: the voice is not learned now, and that is recorded.
    first.stopBackgroundWork()
    await first.close()
    #expect(extractor.working.callCount == 0)
    #expect(pending.entry(sessionID)?.enroll.keys.sorted() == [me])
    #expect(pending.entry(sessionID)?.problem == nil)

    // The next review tries again; a failure then shows in its footer, and is not recorded again.
    extractor.broken.set(true)
    let second = try await ReviewSession(session: fixture.session, profiles: store, maintenance: nil,
                                         exportDelay: .seconds(60), extractor: extractor,
                                         sampleDelay: .zero, pendingVoices: pending)
    #expect(second.voiceProblem?.contains("trying again") == true)
    try await voiceWait("the retry to fail") { second.voiceProblem?.contains("could not be learned:") == true }
    #expect(second.voiceProblem?.contains("The speaker models are missing.") == true)
    #expect(pending.entry(sessionID) == nil, "The footer said so; confirming the person again asks again.")
    await second.close()
    #expect(pending.entry(sessionID) == nil)
    #expect(try store.load().profiles.first(where: \.isSelf)?.samples.count == 0)
}
